#!/usr/bin/env bash
# Smoke test for PolarBookshop services running under Podman.
#
# Usage: smoke-test.sh [up|test|down|all] [catalog] [order] [--rebuild]
#   up      build missing images (or all selected with --rebuild), start backing services + apps
#   test    run the HTTP smoke tests against the running stack
#   down    remove the app containers and the compose backing services
#   all     up + test (default); leaves the stack running
#
# Services default to "catalog order". order-service needs catalog-service, so selecting
# order also selects catalog. Run from anywhere inside a worktree of the repository.
set -uo pipefail

CMD=all
REBUILD=0
SELECTED=()
for a in "$@"; do
  case $a in
    up|test|down|all) CMD=$a ;;
    --rebuild)        REBUILD=1 ;;
    catalog|order)    SELECTED+=("$a") ;;
    *) sed -n '2,11p' "$0"; exit 2 ;;
  esac
done
(( ${#SELECTED[@]} )) || SELECTED=(catalog order)
SERVICES=(catalog-service)
[[ " ${SELECTED[*]} " == *" order "* ]] && SERVICES+=(order-service)
has() { [[ " ${SERVICES[*]} " == *" $1 "* ]]; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git worktree" >&2; exit 2; }
PB=$ROOT/PolarBookshop
COMPOSE=$PB/polar-deployment/docker/docker-compose.yml
[[ -f $COMPOSE ]] || { echo "Compose file not found: $COMPOSE" >&2; exit 2; }
SOCK=/run/user/$(id -u)/podman/podman.sock
NET=docker_default   # network podman-compose creates for project "docker"
declare -A PORT=([catalog-service]=9001 [order-service]=9002)
CATALOG=http://localhost:9001
ORDER=http://localhost:9002
KEYCLOAK=http://localhost:8080
RABBIT=http://localhost:15672/api
RABBIT_AUTH=user:password
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n== %s\n' "$*"; }

wait_until() { # timeout-seconds description command...
  local t=$1 what=$2 i=0; shift 2
  printf 'Waiting for %s ' "$what"
  until "$@" >/dev/null 2>&1; do
    (( i += 3 )); (( i > t )) && { echo " TIMEOUT"; return 1; }
    printf '.'; sleep 3
  done
  echo " ok"
}

build_image() { # service
  log "Building $1 image (bootBuildImage via Podman)"
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
  "$PB/$1/gradlew" --no-daemon -q -p "$PB/$1" -I "$WORK/podman.init.gradle" bootBuildImage \
    > "$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; echo "$1 image build FAILED" >&2; exit 1; }
  echo "Image built"
}

# Prints NUL-separated `podman run` arguments for a compose service. The compose definitions
# use the fluentd log driver (unsupported by Podman 4.9) and depend on tempo/fluent-bit, and
# podman-compose can't drop those via an override file, so the apps are started directly.
run_args() { # service
  python3 -I - "$COMPOSE" "$1" "$NET" <<'EOF'
import sys, yaml
compose, name, net = sys.argv[1:]
svc = yaml.safe_load(open(compose))["services"][name]
env = svc.get("environment", [])
if isinstance(env, dict):
    env = [f"{k}={v}" for k, v in env.items()]
# No tempo here; keep the agent for instrumentation but don't export.
env += ["OTEL_TRACES_EXPORTER=none", "OTEL_LOGS_EXPORTER=none", "OTEL_METRICS_EXPORTER=none"]
# The JWT issuer is host.docker.internal; not every service declares the host entry.
hosts = set(svc.get("extra_hosts", [])) | {"host.docker.internal:host-gateway"}
args = ["--name", svc.get("container_name", name), "--net", net, "--network-alias", name,
        # Without a limit the buildpack memory calculator sizes the heap from host RAM.
        "--memory", "1g"]
for p in svc.get("ports", []): args += ["-p", str(p)]
for h in sorted(hosts): args += ["--add-host", h]
for e in env: args += ["-e", e]
args.append(svc["image"])
sys.stdout.write("\0".join(args) + "\0")
EOF
}

up() {
  command -v podman >/dev/null && command -v podman-compose >/dev/null \
    || { echo "podman and podman-compose are required" >&2; exit 2; }

  # Free the app containers' memory before any image build.
  podman rm -f "${SERVICES[@]}" >/dev/null 2>&1

  local avail_mb need_mb=1500
  has order-service && need_mb=2200
  avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  echo "Available memory: ${avail_mb} MiB (stack needs about ${need_mb} MiB)"
  (( avail_mb < need_mb )) && echo "WARNING: stack may be OOM-killed. Stop other containers / Gradle daemons first."

  log "Podman API socket"
  systemctl --user start podman.socket && echo "podman.socket active ($SOCK)"

  local s
  for s in "${SERVICES[@]}"; do
    if (( REBUILD )) || ! podman image exists "$s"; then
      build_image "$s"
    else
      echo "Using existing $s image (pass --rebuild to rebuild)"
    fi
  done

  local backing=(polar-postgres polar-keycloak)
  has order-service && backing+=(polar-rabbitmq)
  # Podman has no unqualified-search registries here, so short names like
  # "rabbitmq:3.13-management" only work once the image is in local storage.
  local img
  for s in "${backing[@]}"; do
    img=$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["services"][sys.argv[2]]["image"])' "$COMPOSE" "$s")
    podman image exists "$img" && continue
    if [[ $img != */* ]]; then img=docker.io/library/$img
    elif [[ ${img%%/*} != *[.:]* ]]; then img=docker.io/$img; fi
    echo "Pulling $img"
    podman pull -q "$img" >/dev/null || { echo "Pull of $img FAILED" >&2; exit 1; }
  done

  log "Starting ${backing[*]}"
  # podman-compose exits 0 even when a container fails to start, so check each one.
  podman-compose -f "$COMPOSE" up -d "${backing[@]}" >"$WORK/compose.log" 2>&1
  for s in "${backing[@]}"; do
    [[ $(podman inspect -f '{{.State.Running}}' "$s" 2>/dev/null) == true ]] \
      || { grep -i error "$WORK/compose.log"; echo "$s is not running" >&2; exit 1; }
  done

  local args
  for s in "${SERVICES[@]}"; do
    log "Starting $s"
    mapfile -d '' args < <(run_args "$s")
    podman run -d "${args[@]}" >/dev/null || exit 1
  done

  for s in "${SERVICES[@]}"; do
    wait_until 180 "$s readiness" curl -sf "http://localhost:${PORT[$s]}/actuator/health/readiness" \
      || { podman logs --tail 40 "$s"; exit 1; }
  done
  wait_until 180 "Keycloak realm" curl -sf "$KEYCLOAK/realms/PolarBookshop" || exit 1
  if has order-service; then
    wait_until 120 "order-service consumer on order-dispatched" consumer_bound || exit 1
  fi
}

# ---- test helpers -----------------------------------------------------------
PASS=0; FAIL=0
check() { # description expected actual [detail]
  if [[ $2 == "$3" ]]; then
    printf '  PASS  %-40s %s\n' "$1" "$3"; (( PASS++ ))
  else
    printf '  FAIL  %-40s expected %s, got %s %s\n' "$1" "$2" "$3" "${4:-}"; (( FAIL++ ))
  fi
}
# req METHOD URL [TOKEN] [JSON] -> sets $CODE and $BODY
req() {
  local args=(-s -o "$WORK/body" -w '%{http_code}' -X "$1")
  [[ -n ${3:-} ]] && args+=(-H "Authorization: Bearer $3")
  [[ -n ${4:-} ]] && args+=(-H 'Content-Type: application/json' -d "$4")
  CODE=$(curl "${args[@]}" "$2"); BODY=$(cat "$WORK/body")
}
# json EXPR -> evaluates EXPR with d = parsed $BODY
json() { python3 -I -c "import sys,json; d=json.load(sys.stdin); print($1)" <<<"$BODY" 2>/dev/null; }
rabbit() { # METHOD PATH [JSON] -> sets $CODE and $BODY
  local args=(-s -o "$WORK/body" -w '%{http_code}' -u "$RABBIT_AUTH" -X "$1")
  [[ -n ${3:-} ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  CODE=$(curl "${args[@]}" "$RABBIT$2"); BODY=$(cat "$WORK/body")
}
consumer_bound() {
  rabbit GET /queues/%2F/order-dispatched.order-service
  [[ $CODE == 200 && $(json 'd.get("consumers", 0) > 0') == True ]]
}

token() { # username -> access token whose issuer matches what the services expect
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

test_catalog() {
  local isbn="99$(date +%s | tail -c 9)"   # 10 digits, unique per run
  local book="{\"isbn\":\"$isbn\",\"title\":\"Smoke Test\",\"author\":\"Smoke Tester\",\"price\":12.5,\"publisher\":\"Polarsophia\"}"

  log "catalog-service ($CATALOG)"
  req GET $CATALOG/;                          check "GET / greeting"                 200 "$CODE" "$BODY"
  req GET $CATALOG/actuator/health;           check "health status"                  UP "$(json 'd["status"]')"
  check "health db component"                 UP "$(json 'd["components"]["db"]["status"]')"
  req GET $CATALOG/actuator/health/liveness;  check "liveness probe"                 200 "$CODE"
  req GET $CATALOG/actuator/health/readiness; check "readiness probe"                200 "$CODE"
  req GET $CATALOG/books;                     check "GET /books"                     200 "$CODE"
  check "testdata books loaded"               True "$(json 'len(d) >= 2')"
  req GET $CATALOG/books/1234567891;          check "GET /books/{testdata isbn}"     200 "$CODE"
  req GET $CATALOG/books/0000000000;          check "GET unknown isbn"               404 "$CODE"
  req POST $CATALOG/books "" "$book";         check "POST without token"             401 "$CODE"
  req POST $CATALOG/books "$B" "$book";       check "POST as customer (bjorn)"       403 "$CODE"
  req POST $CATALOG/books "$I" "$book";       check "POST as employee (isabelle)"    201 "$CODE" "$BODY"
  check "createdBy audit populated"           True "$(json 'd.get("createdBy") is not None')"
  req GET "$CATALOG/books/$isbn";             check "GET created book"               200 "$CODE"
  req PUT "$CATALOG/books/$isbn" "$I" "${book/12.5/15.0}"
  check "PUT as employee"                     200 "$CODE" "$BODY"
  check "PUT bumped version"                  2 "$(json 'd["version"]')"
  req POST $CATALOG/books "$I" '{"isbn":"abc","title":"","author":"A","price":-1}'
  check "POST invalid book"                   400 "$CODE"
  req DELETE "$CATALOG/books/$isbn" "$B";     check "DELETE as customer (bjorn)"     403 "$CODE"
  req DELETE "$CATALOG/books/$isbn" "$I";     check "DELETE as employee (isabelle)"  204 "$CODE"
  req GET "$CATALOG/books/$isbn";             check "GET after delete"               404 "$CODE"
}

test_order() {
  local capture=smoke-test.order-accepted
  local order='{"isbn":"1234567891","quantity":2}'

  log "order-service ($ORDER)"
  req GET $ORDER/actuator/health;           check "health status"                    UP "$(json 'd["status"]')"
  check "health r2dbc component"            UP "$(json 'd["components"]["r2dbc"]["status"]')"
  check "health rabbit component"           UP "$(json 'd["components"]["rabbit"]["status"]')"
  req GET $ORDER/actuator/health/liveness;  check "liveness probe"                   200 "$CODE"
  req GET $ORDER/actuator/health/readiness; check "readiness probe"                  200 "$CODE"
  req GET $ORDER/orders;                    check "GET /orders without token"        401 "$CODE"
  req POST $ORDER/orders "" "$order";       check "POST /orders without token"       401 "$CODE"

  # Capture order-accepted events in a temporary queue. The exchange is normally declared by
  # order-service on its first publish, so declare it here (same type) to bind before that.
  rabbit PUT /exchanges/%2F/order-accepted '{"type":"topic","durable":true}'
  rabbit PUT /queues/%2F/$capture '{"durable":false,"auto_delete":false}'
  rabbit POST /bindings/%2F/e/order-accepted/q/$capture '{"routing_key":"#"}'
  rabbit DELETE /queues/%2F/$capture/contents
  rabbit GET /exchanges/%2F/order-accepted/bindings/source
  check "capture queue bound to order-accepted" True "$(json "any(b['destination'] == '$capture' for b in d)")"

  req POST $ORDER/orders "$B" "$order";     check "POST order as bjorn"              200 "$CODE" "$BODY"
  local id; id=$(json 'd["id"]')
  check "order status"                      ACCEPTED "$(json 'd["status"]')"
  check "order bookName from catalog"       "Northern Lights - Lyra Silverstar" "$(json 'd["bookName"]')"
  check "order bookPrice from catalog"      9.9 "$(json 'd["bookPrice"]')"
  check "order createdBy populated"         True "$(json 'd.get("createdBy") is not None')"

  local got="" i
  for i in 1 2 3 4 5; do
    rabbit POST /queues/%2F/$capture/get '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}'
    got=$(json 'json.loads(d[0]["payload"])["orderId"] if d else ""'); [[ -n $got ]] && break; sleep 1
  done
  check "order-accepted event published"    "$id" "$got"
  rabbit DELETE /queues/%2F/$capture

  req POST $ORDER/orders "$B" '{"isbn":"0000000000","quantity":1}'
  check "POST unknown isbn"                 200 "$CODE"
  check "unknown isbn order status"         REJECTED "$(json 'd["status"]')"
  req POST $ORDER/orders "$B" '{"isbn":"1234567891","quantity":0}'
  check "POST quantity 0"                   400 "$CODE"
  req POST $ORDER/orders "$B" '{"isbn":"1234567891","quantity":6}'
  check "POST quantity 6"                   400 "$CODE"
  req POST $ORDER/orders "$B" '{"quantity":1}'
  check "POST missing isbn"                 400 "$CODE"

  req GET $ORDER/orders "$B";               check "GET /orders as bjorn"             200 "$CODE"
  check "bjorn sees own order"              True "$(json "any(o['id'] == $id for o in d)")"
  req GET $ORDER/orders "$I";               check "GET /orders as isabelle"          200 "$CODE"
  check "isabelle can't see bjorn's order"  False "$(json "any(o['id'] == $id for o in d)")"

  # Simulate dispatcher-service: send order-dispatched and expect the status to change.
  rabbit POST /exchanges/%2F/order-dispatched/publish \
    "{\"properties\":{\"content_type\":\"application/json\"},\"routing_key\":\"#\",\"payload\":\"{\\\"orderId\\\":$id}\",\"payload_encoding\":\"string\"}"
  check "order-dispatched message routed"   True "$(json 'd["routed"]')"
  local status=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    req GET $ORDER/orders "$B"
    status=$(json "next(o['status'] for o in d if o['id'] == $id)")
    [[ $status == DISPATCHED ]] && break; sleep 1
  done
  check "order status after dispatch"       DISPATCHED "$status"
}

run_tests() {
  log "Preparing tokens"
  ensure_test_client || exit 1
  I=$(token isabelle) && B=$(token bjorn) || { echo "Could not obtain user tokens" >&2; exit 1; }

  test_catalog
  has order-service && test_order

  log "Result: $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}

down() {
  log "Stopping stack"
  podman rm -f catalog-service order-service >/dev/null 2>&1 && echo "Removed app containers"
  podman-compose -f "$COMPOSE" down >/dev/null 2>&1 && echo "Compose services removed"
  podman ps --format '{{.Names}} {{.Status}}'
}

case $CMD in
  up)   up ;;
  test) run_tests ;;
  down) down ;;
  all)  up && run_tests ;;
esac
