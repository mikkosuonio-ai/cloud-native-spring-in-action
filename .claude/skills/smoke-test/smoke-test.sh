#!/usr/bin/env bash
# Smoke test for PolarBookshop catalog-service running under Podman.
#
# Usage: smoke-test.sh [up|test|down|all] [--rebuild]
#   up      build the image if missing (or --rebuild), start postgres + keycloak + catalog-service
#   test    run the HTTP smoke tests against the running stack
#   down    remove catalog-service and the compose backing services
#   all     up + test (default); leaves the stack running
#
# Run from anywhere inside a worktree of the repository.
set -uo pipefail

CMD=${1:-all}
REBUILD=0
for a in "$@"; do [[ $a == --rebuild ]] && REBUILD=1; done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git worktree" >&2; exit 2; }
PB=$ROOT/PolarBookshop
COMPOSE=$PB/polar-deployment/docker/docker-compose.yml
[[ -f $COMPOSE ]] || { echo "Compose file not found: $COMPOSE" >&2; exit 2; }
SOCK=/run/user/$(id -u)/podman/podman.sock
NET=docker_default   # network podman-compose creates for project "docker"
CATALOG=http://localhost:9001
KEYCLOAK=http://localhost:8080
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n== %s\n' "$*"; }

wait_for() { # url timeout-seconds description
  local url=$1 t=$2 what=$3 i=0
  printf 'Waiting for %s ' "$what"
  until curl -sf -o /dev/null "$url"; do
    (( i += 3 )); (( i > t )) && { echo " TIMEOUT"; return 1; }
    printf '.'; sleep 3
  done
  echo " ok"
}

up() {
  command -v podman >/dev/null && command -v podman-compose >/dev/null \
    || { echo "podman and podman-compose are required" >&2; exit 2; }

  local avail_mb
  avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  echo "Available memory: ${avail_mb} MiB"
  (( avail_mb < 1500 )) && echo "WARNING: under 1.5 GiB available; stack may be OOM-killed. Stop other containers / Gradle daemons first."

  log "Podman API socket"
  systemctl --user start podman.socket && echo "podman.socket active ($SOCK)"

  if (( REBUILD )) || ! podman image exists catalog-service; then
    log "Building catalog-service image (bootBuildImage via Podman)"
    cat > "$WORK/podman.init.gradle" <<EOF
allprojects {
  tasks.matching { it.name == 'bootBuildImage' }.configureEach {
    docker {
      host = "unix://$SOCK"
      bindHostToBuilder = true
    }
  }
}
EOF
    "$PB/catalog-service/gradlew" --no-daemon -q -p "$PB/catalog-service" -I "$WORK/podman.init.gradle" bootBuildImage \
      > "$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; echo "Image build FAILED" >&2; exit 1; }
    echo "Image built"
  else
    echo "Using existing catalog-service image (pass --rebuild to rebuild)"
  fi

  log "Starting polar-postgres and polar-keycloak"
  podman-compose -f "$COMPOSE" up -d polar-postgres polar-keycloak >"$WORK/compose.log" 2>&1 \
    || { cat "$WORK/compose.log"; exit 1; }

  # The compose definition of catalog-service uses the fluentd log driver (unsupported
  # by Podman 4.9) and depends on tempo/fluent-bit, so run it directly with the same env.
  log "Starting catalog-service"
  podman rm -f catalog-service >/dev/null 2>&1
  podman run -d --name catalog-service --net "$NET" --network-alias catalog-service \
    -p 9001:9001 -p 8001:8001 \
    --add-host host.docker.internal:host-gateway \
    -e BPL_JVM_THREAD_COUNT=50 \
    -e BPL_DEBUG_ENABLED=true -e BPL_DEBUG_PORT=8001 \
    -e JAVA_TOOL_OPTIONS="$(grep -m1 -o 'JAVA_TOOL_OPTIONS=.*opentelemetry-javaagent-[0-9.]*\.jar' "$COMPOSE" | cut -d= -f2-)" \
    -e OTEL_SERVICE_NAME=catalog-service \
    -e OTEL_TRACES_EXPORTER=none -e OTEL_LOGS_EXPORTER=none -e OTEL_METRICS_EXPORTER=none \
    -e SPRING_CLOUD_CONFIG_URI=http://config-service:8888 \
    -e SPRING_DATASOURCE_URL=jdbc:postgresql://polar-postgres:5432/polardb_catalog \
    -e SPRING_PROFILES_ACTIVE=testdata \
    -e SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI=http://host.docker.internal:8080/realms/PolarBookshop \
    catalog-service >/dev/null || exit 1

  wait_for "$CATALOG/actuator/health/readiness" 180 "catalog-service readiness" \
    || { podman logs --tail 40 catalog-service; exit 1; }
  wait_for "$KEYCLOAK/realms/PolarBookshop" 180 "Keycloak realm" || exit 1
}

# ---- test helpers -----------------------------------------------------------
PASS=0; FAIL=0
check() { # description expected actual [detail]
  if [[ $2 == "$3" ]]; then
    printf '  PASS  %-36s %s\n' "$1" "$3"; (( PASS++ ))
  else
    printf '  FAIL  %-36s expected %s, got %s %s\n' "$1" "$2" "$3" "${4:-}"; (( FAIL++ ))
  fi
}
# req METHOD PATH [TOKEN] [JSON] -> sets $CODE and $BODY
req() {
  local args=(-s -o "$WORK/body" -w '%{http_code}' -X "$1")
  [[ -n ${3:-} ]] && args+=(-H "Authorization: Bearer $3")
  [[ -n ${4:-} ]] && args+=(-H 'Content-Type: application/json' -d "$4")
  CODE=$(curl "${args[@]}" "$CATALOG$2"); BODY=$(cat "$WORK/body")
}
json() { python3 -I -c "import sys,json; d=json.load(sys.stdin); print($1)" <<<"$BODY" 2>/dev/null; }

token() { # username -> access token whose issuer matches what catalog-service expects
  curl -sf -H 'Host: host.docker.internal:8080' \
    -d grant_type=password -d client_id=polar-test -d username="$1" -d password=password \
    "$KEYCLOAK/realms/PolarBookshop/protocol/openid-connect/token" \
    | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
}

ensure_test_client() {
  # The imported realm has no password-grant client; add the public "polar-test" client
  # the integration tests use. Lives only in the dev Keycloak container's internal storage.
  local admin
  admin=$(curl -sf -d grant_type=password -d client_id=admin-cli -d username=user -d password=password \
    "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
    | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') \
    || { echo "Keycloak admin login failed" >&2; return 1; }
  if [[ $(curl -sf -H "Authorization: Bearer $admin" "$KEYCLOAK/admin/realms/PolarBookshop/clients?clientId=polar-test") == "[]" ]]; then
    curl -sf -o /dev/null -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' \
      -d '{"clientId":"polar-test","publicClient":true,"directAccessGrantsEnabled":true,"standardFlowEnabled":false}' \
      "$KEYCLOAK/admin/realms/PolarBookshop/clients" && echo "Created Keycloak client polar-test"
  else
    echo "Keycloak client polar-test already present"
  fi
}

run_tests() {
  log "Preparing tokens"
  ensure_test_client || exit 1
  local I B
  I=$(token isabelle) && B=$(token bjorn) || { echo "Could not obtain user tokens" >&2; exit 1; }

  local isbn="99$(date +%s | tail -c 9)"   # 10 digits, unique per run
  local book="{\"isbn\":\"$isbn\",\"title\":\"Smoke Test\",\"author\":\"Smoke Tester\",\"price\":12.5,\"publisher\":\"Polarsophia\"}"

  log "Smoke tests against $CATALOG"
  req GET /;                          check "GET / greeting"                 200 "$CODE" "$BODY"
  req GET /actuator/health;           check "health status"                  UP "$(json 'd["status"]')"
  check "health db component"         UP "$(json 'd["components"]["db"]["status"]')"
  req GET /actuator/health/liveness;  check "liveness probe"                 200 "$CODE"
  req GET /actuator/health/readiness; check "readiness probe"                200 "$CODE"
  req GET /books;                     check "GET /books"                     200 "$CODE"
  check "testdata books loaded"       True "$(json 'len(d) >= 2')"
  req GET /books/1234567891;          check "GET /books/{testdata isbn}"     200 "$CODE"
  req GET /books/0000000000;          check "GET unknown isbn"               404 "$CODE"
  req POST /books "" "$book";         check "POST without token"             401 "$CODE"
  req POST /books "$B" "$book";       check "POST as customer (bjorn)"       403 "$CODE"
  req POST /books "$I" "$book";       check "POST as employee (isabelle)"    201 "$CODE" "$BODY"
  check "createdBy audit populated"   True "$(json 'd.get("createdBy") is not None')"
  req GET "/books/$isbn";             check "GET created book"               200 "$CODE"
  req PUT "/books/$isbn" "$I" "${book/12.5/15.0}"
  check "PUT as employee"             200 "$CODE" "$BODY"
  check "PUT bumped version"          2 "$(json 'd["version"]')"
  req POST /books "$I" '{"isbn":"abc","title":"","author":"A","price":-1}'
  check "POST invalid book"           400 "$CODE"
  req DELETE "/books/$isbn" "$B";     check "DELETE as customer (bjorn)"     403 "$CODE"
  req DELETE "/books/$isbn" "$I";     check "DELETE as employee (isabelle)"  204 "$CODE"
  req GET "/books/$isbn";             check "GET after delete"               404 "$CODE"

  log "Result: $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}

down() {
  log "Stopping stack"
  podman rm -f catalog-service >/dev/null 2>&1 && echo "Removed catalog-service"
  podman-compose -f "$COMPOSE" down >/dev/null 2>&1 && echo "Compose services removed"
  podman ps --format '{{.Names}} {{.Status}}'
}

case $CMD in
  up)   up ;;
  test) run_tests ;;
  down) down ;;
  all)  up && run_tests ;;
  *)    sed -n '2,10p' "$0"; exit 2 ;;
esac
