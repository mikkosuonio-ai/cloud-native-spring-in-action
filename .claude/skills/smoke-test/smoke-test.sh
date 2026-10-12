#!/usr/bin/env bash
# Smoke test for PolarBookshop services running under Podman, or on MicroK8s with --k8s.
#
# Usage: smoke-test.sh [up|test|down|all] [catalog] [order] [dispatcher] [config] [edge] [quote]
#                      [quote-function] [observability] [--rebuild] [--k8s]
#   up      build missing images (or all selected with --rebuild), start backing services + apps
#   test    run the HTTP smoke tests against the running stack
#   down    remove the app containers and the compose backing services (--k8s: the namespace)
#   all     up + test (default); leaves the stack running
#
# Services default to "catalog order dispatcher config"; edge, quote and quote-function must
# be asked for, since the whole set doesn't fit in this machine's memory. order needs catalog,
# and edge needs catalog, order and polar-ui; those are added automatically. observability adds
# Prometheus, Tempo and Grafana and exports traces, on top of the default services if no other
# service is given. --k8s deploys the services' k8s/ manifests to the namespace polar-smoke
# instead; it supports catalog, order, dispatcher and config.
# Run from anywhere inside a worktree of the repository.
set -uo pipefail

CMD=all
REBUILD=0
K8S=0
SELECTED=()
for a in "$@"; do
  case $a in
    up|test|down|all)        CMD=$a ;;
    --rebuild)               REBUILD=1 ;;
    --k8s)                   K8S=1 ;;
    catalog|order|dispatcher|config|edge|quote|quote-function|observability) SELECTED+=("$a") ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
  esac
done
[[ " ${SELECTED[*]} " == *[a-z]* && " ${SELECTED[*]} " != " observability " ]] \
  || SELECTED+=(catalog order dispatcher config)
selected() { [[ " ${SELECTED[*]} " == *" $1 "* ]]; }
if (( K8S )); then
  for a in edge quote quote-function observability; do
    selected $a && { echo "$a isn't supported with --k8s yet" >&2; exit 2; }
  done
fi
SERVICES=()
selected config && SERVICES+=(config-service)
selected catalog || selected order || selected edge && SERVICES+=(catalog-service)
selected order || selected edge && SERVICES+=(order-service)
selected dispatcher && SERVICES+=(dispatcher-service)
selected edge && SERVICES+=(polar-ui edge-service)
selected quote && SERVICES+=(quote-service)
selected quote-function && SERVICES+=(quote-function)
ALL_APPS=(catalog-service order-service dispatcher-service config-service polar-ui edge-service
          quote-service quote-function)
# Services absent from the compose file: published port for `podman run`.
declare -A STANDALONE_PORT=([quote-service]=9101 [quote-function]=9102)
# Services whose build.gradle asks for a GraalVM native image; built as JVM images instead,
# because native compilation needs more memory than this machine has.
JVM_INSTEAD_OF_NATIVE=" quote-service quote-function "
# JDK each build runs on, installed with sdkman. Spring Native 0.12 (quote-service, quote-function) can't read
# Java 21 class files during AOT processing, so it builds on 17. Interim until every project is
# on the same JDK and builds can use a preset JAVA_HOME.
JDKS=$HOME/.sdkman/candidates/java
declare -A JDK=([quote-service]=$JDKS/17.0.20-tem [quote-function]=$JDKS/17.0.20-tem)
DEFAULT_JDK=$JDKS/21.0.12+1.1-tem
has() { [[ " ${SERVICES[*]} " == *" $1 "* ]]; }
needs_keycloak() { has catalog-service; }
needs_rabbit() { has order-service || has dispatcher-service; }
needs_redis() { has edge-service; }
needs_observability() { selected observability; }
# Services with actuator metrics and the OpenTelemetry agent.
TRACED=(catalog-service order-service dispatcher-service config-service edge-service)
# With config-service selected, catalog-service reads its configuration from it. Not on
# Kubernetes, where its k8s/ manifests give it a ConfigMap instead.
config_client() { (( ! K8S )) && [[ $1 == catalog-service ]] && has "$1" && has config-service; }

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git worktree" >&2; exit 2; }
PB=$ROOT/PolarBookshop
COMPOSE=$PB/polar-deployment/docker/docker-compose.yml
[[ -f $COMPOSE ]] || { echo "Compose file not found: $COMPOSE" >&2; exit 2; }
SOCK=/run/user/$(id -u)/podman/podman.sock
NET=docker_default   # network podman-compose creates for project "docker"
declare -A READY_URL=(
  [catalog-service]=http://localhost:9001/actuator/health/readiness
  [order-service]=http://localhost:9002/actuator/health/readiness
  [dispatcher-service]=http://localhost:9003/actuator/health/readiness
  [config-service]=http://localhost:8888/actuator/health/readiness
  [polar-ui]=http://localhost:9004/
  [edge-service]=http://localhost:9000/actuator/health/readiness
  [quote-service]=http://localhost:9101/quotes
  [quote-function]=http://localhost:9102/randomQuote
)
QUOTE=http://localhost:9101
QUOTE_FN=http://localhost:9102
EDGE=http://localhost:9000
CATALOG=http://localhost:9001
ORDER=http://localhost:9002
DISPATCHER=http://localhost:9003
CONFIG=http://localhost:8888
KEYCLOAK=http://localhost:8080
RABBIT=http://localhost:15672/api
RABBIT_AUTH=user:password
PROMETHEUS=http://localhost:9090
TEMPO=http://localhost:3110
GRAFANA=http://localhost:3000
GRAFANA_AUTH=user:password
# Host part of the JWT issuer the services expect; tokens are requested with it as Host header.
KC_HOST=host.docker.internal:8080
# --k8s: the services are reached on their ClusterIPs (see k8s_urls), which MicroK8s routes from
# the host. kubectl is MicroK8s' own unless KUBECTL names another one.
NS=polar-smoke
REGISTRY=localhost:32000   # MicroK8s registry addon
read -ra KUBECTL <<<"${KUBECTL:-microk8s kubectl}"
K8S_SERVICES=$PB/polar-deployment/kubernetes/platform/development/services
# Production overlays' memory limit; without one the buildpack memory calculator sizes the
# heap from the node's RAM. The request is lower so that pods fit on a small node.
K8S_MEMORY_LIMIT=756Mi
K8S_MEMORY_REQUEST=256Mi
declare -A BASE_URL=([catalog-service]=$CATALOG [order-service]=$ORDER [dispatcher-service]=$DISPATCHER
                     [config-service]=$CONFIG [edge-service]=$EDGE)
WORK=$(mktemp -d)
PIDS=()   # background kubectl port-forwards
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$WORK"' EXIT

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
  # afterEvaluate, so the environment override lands after build.gradle sets it.
  cat > "$WORK/podman.init.gradle" <<EOF
allprojects {
  afterEvaluate {
    tasks.matching { it.name == 'bootBuildImage' }.configureEach {
      docker {
        host = "unix://$SOCK"
        bindHostToBuilder = true
      }
      if (project.hasProperty('smokeTestJvmImage')) {
        environment(['BP_NATIVE_IMAGE': 'false'])
      }
    }
  }
}
EOF
  local props=()
  if [[ $JVM_INSTEAD_OF_NATIVE == *" $1 "* ]]; then
    echo "Building a JVM image instead of the configured native image"
    props+=(-PsmokeTestJvmImage)
  fi
  local jdk=${JDK[$1]:-$DEFAULT_JDK}
  [[ -x $jdk/bin/java ]] || { echo "JDK not found: $jdk (install it with sdkman)" >&2; exit 1; }
  echo "Using JDK $(basename "$jdk")"
  JAVA_HOME=$jdk "$PB/$1/gradlew" --no-daemon -q -p "$PB/$1" -I "$WORK/podman.init.gradle" "${props[@]}" bootBuildImage \
    > "$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log"; echo "$1 image build FAILED" >&2; exit 1; }
  echo "Image built"
}

# Prints NUL-separated `podman run` arguments for a compose service. The compose definitions
# use the fluentd log driver (unsupported by Podman 4.9) and depend on tempo/fluent-bit, and
# podman-compose can't drop those via an override file, so the apps are started directly.
# Services not in the compose file get just their image and STANDALONE_PORT.
run_args() { # service
  local client= traces=; config_client "$1" && client=1; needs_observability && traces=1
  python3 -I - "$COMPOSE" "$1" "$NET" "${STANDALONE_PORT[$1]:-}" "$client" "$traces" <<'EOF'
import sys, yaml
compose, name, net, port, client, traces = sys.argv[1:]
svc = yaml.safe_load(open(compose))["services"].get(name) or {"image": name, "ports": [f"{port}:{port}"]}
env = svc.get("environment", [])
if isinstance(env, dict):
    env = [f"{k}={v}" for k, v in env.items()]
# Traces go to tempo only when it runs (observability). Logs go through fluent-bit in the
# compose setup, and metrics through Prometheus scraping, so the agent never exports those.
env += ["OTEL_LOGS_EXPORTER=none", "OTEL_METRICS_EXPORTER=none"]
if not traces:
    env += ["OTEL_TRACES_EXPORTER=none"]
# The compose file only sets the config-service URI; the client is off unless enabled.
# fail-fast, so a service that can't reach config-service fails instead of falling back.
if client:
    env += ["SPRING_CONFIG_IMPORT=optional:configserver:", "SPRING_CLOUD_CONFIG_ENABLED=true",
            "SPRING_CLOUD_CONFIG_FAIL_FAST=true"]
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

check_memory() {
  # Rough figures seen in practice: keycloak+postgres ~1 GB, each Spring app ~350 MB,
  # rabbitmq ~100 MB, polar-ui + redis ~100 MB.
  local avail_mb need_mb=$(( 200 + 350 * ${#SERVICES[@]} ))
  has polar-ui && (( need_mb -= 350 ))
  needs_keycloak && (( need_mb += 1000 ))
  needs_rabbit && (( need_mb += 100 ))
  needs_redis && (( need_mb += 100 ))
  needs_observability && (( need_mb += 300 ))
  avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  echo "Available memory: ${avail_mb} MiB (stack needs about ${need_mb} MiB)"
  (( avail_mb < need_mb )) && echo "WARNING: stack may be OOM-killed. Stop other containers / Gradle daemons first."
}

build_images() {
  log "Podman API socket"
  systemctl --user start podman.socket && echo "podman.socket active ($SOCK)"

  local s
  for s in "${SERVICES[@]}"; do
    [[ -d $PB/$s ]] || continue   # prebuilt image (polar-ui); podman run pulls it
    if (( REBUILD )) || ! podman image exists "$s"; then
      build_image "$s"
    else
      echo "Using existing $s image (pass --rebuild to rebuild)"
    fi
  done
}

# Waits until the services' RabbitMQ consumers are attached; the services report ready before.
wait_consumers() {
  if has order-service; then
    wait_until 120 "order-service consumer" consumer_bound order-dispatched.order-service || exit 1
  fi
  if has dispatcher-service; then
    wait_until 120 "dispatcher-service consumer" consumer_bound order-accepted.dispatcher-service || exit 1
  fi
}

up() {
  command -v podman >/dev/null && command -v podman-compose >/dev/null \
    || { echo "podman and podman-compose are required" >&2; exit 2; }

  # Free the app containers' memory before any image build.
  local s
  for s in "${SERVICES[@]}"; do podman rm -f "$s" >/dev/null 2>&1; done
  check_memory
  build_images

  local backing=()
  needs_keycloak && backing+=(polar-postgres polar-keycloak)
  needs_rabbit && backing+=(polar-rabbitmq)
  needs_redis && backing+=(polar-redis)
  # grafana's depends_on also brings up loki and fluent-bit; nothing sends logs to them.
  needs_observability && backing+=(prometheus tempo grafana)
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

  # Guard: `podman-compose up` with no service names starts every service in the file.
  if (( ${#backing[@]} )); then
    log "Starting ${backing[*]}"
    # podman-compose exits 0 even when a container fails to start, so check each one.
    podman-compose -f "$COMPOSE" up -d "${backing[@]}" >"$WORK/compose.log" 2>&1
    for s in "${backing[@]}"; do
      [[ $(podman inspect -f '{{.State.Running}}' "$s" 2>/dev/null) == true ]] \
        || { grep -i error "$WORK/compose.log"; echo "$s is not running" >&2; exit 1; }
    done
  fi
  podman network exists "$NET" || podman network create "$NET" >/dev/null

  local args
  for s in "${SERVICES[@]}"; do
    # edge-service fetches the issuer's OpenID configuration at startup and exits if
    # Keycloak isn't up yet; the other services only contact Keycloak on first use.
    if [[ $s == edge-service ]]; then
      wait_until 180 "Keycloak realm" curl -sf "$KEYCLOAK/realms/PolarBookshop" || exit 1
    fi
    if config_client "$s"; then
      wait_until 180 "config-service readiness" curl -sf "${READY_URL[config-service]}" \
        || { podman logs --tail 40 config-service; exit 1; }
    fi
    log "Starting $s"
    mapfile -d '' args < <(run_args "$s")
    podman run -d --replace "${args[@]}" >/dev/null || exit 1
  done

  for s in "${SERVICES[@]}"; do
    wait_until 180 "$s readiness" curl -sf "${READY_URL[$s]}" \
      || { podman logs --tail 40 "$s"; exit 1; }
  done
  if needs_keycloak; then
    wait_until 180 "Keycloak realm" curl -sf "$KEYCLOAK/realms/PolarBookshop" || exit 1
  fi
  wait_consumers
  if needs_observability; then
    wait_until 60 "Prometheus" curl -sf "$PROMETHEUS/-/ready" || exit 1
    wait_until 120 "Tempo" curl -sf "$TEMPO/ready" || exit 1
    wait_until 60 "Grafana" curl -sf "$GRAFANA/api/health" || exit 1
  fi
}

# ---- Kubernetes (--k8s) -----------------------------------------------------
k() { "${KUBECTL[@]}" -n "$NS" "$@"; }

# Points the URLs at the services' ClusterIPs, where they listen on port 80.
k8s_urls() {
  svc_url() { # service [port]
    local ip; ip=$(k get svc "$1" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [[ -n $ip ]] && echo "http://$ip${2:+:$2}"
  }
  CATALOG=$(svc_url catalog-service); ORDER=$(svc_url order-service)
  DISPATCHER=$(svc_url dispatcher-service); CONFIG=$(svc_url config-service)
  KEYCLOAK=$(svc_url polar-keycloak); RABBIT=$(svc_url polar-rabbitmq 15672)/api
  BASE_URL=([catalog-service]=$CATALOG [order-service]=$ORDER [dispatcher-service]=$DISPATCHER
            [config-service]=$CONFIG)
  KC_HOST=polar-keycloak
}

# Keycloak's master realm requires HTTPS from non-private addresses, and requests from the host
# to a ClusterIP arrive from the node's address. Through a port-forward they come from localhost.
k8s_forward_keycloak() {
  local port=38080
  k port-forward svc/polar-keycloak "$port:80" >"$WORK/port-forward.log" 2>&1 &
  PIDS+=($!)
  KEYCLOAK=http://localhost:$port
  wait_until 30 "Keycloak port-forward" curl -sf "$KEYCLOAK/realms/PolarBookshop" \
    || { cat "$WORK/port-forward.log"; exit 1; }
}

k8s_check_cluster() {
  "${KUBECTL[@]}" get --raw=/readyz >/dev/null 2>&1 \
    || { echo "Kubernetes isn't reachable with '${KUBECTL[*]}'. Start it with: sudo microk8s start" >&2; exit 2; }
  "${KUBECTL[@]}" -n kube-system get deployment coredns >/dev/null 2>&1 \
    || { echo "Cluster DNS is missing. Enable it with: microk8s enable dns" >&2; exit 2; }
  curl -sf "http://$REGISTRY/v2/" >/dev/null \
    || { echo "No registry at $REGISTRY. Enable it with: microk8s enable registry" >&2; exit 2; }
}

# Pushes the image to the cluster's registry and prints its digest there.
k8s_push() { # service
  podman push -q --tls-verify=false --digestfile "$WORK/$1.digest" "$1" "$REGISTRY/$1:smoke-test" >/dev/null \
    || { echo "Push of $1 to $REGISTRY FAILED" >&2; exit 1; }
  cat "$WORK/$1.digest"
}

# Writes a kustomization over the service's own k8s/ that only swaps in the pushed image and
# adds a memory limit, and prints its directory.
k8s_overlay() { # service digest
  local dir=$WORK/k8s/$1 base; mkdir -p "$dir"
  # Kustomize takes a base directory only as a relative path.
  base=$(realpath --relative-to="$dir" "$PB/$1/k8s")
  cat > "$dir/kustomization.yml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $base
images:
  - name: $1
    newName: $REGISTRY/$1
    digest: $2
patches:
  - target:
      kind: Deployment
      name: $1
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests:
            memory: $K8S_MEMORY_REQUEST
          limits:
            memory: $K8S_MEMORY_LIMIT
YAML
  echo "$dir"
}

k8s_rollout() { # deployment
  printf 'Waiting for %s rollout ' "$1"
  if k rollout status "deployment/$1" --timeout=300s >/dev/null 2>&1; then
    echo ok
  else
    echo TIMEOUT
    k get pods -o wide
    k logs "deployment/$1" --tail 40
    k describe pods | sed -n '/^Events:/,/^$/p' | tail -20
    exit 1
  fi
}

k8s_up() {
  command -v podman >/dev/null || { echo "podman is required to build the images" >&2; exit 2; }
  k8s_check_cluster
  check_memory
  build_images

  local backing=() files=() s
  needs_keycloak && { backing+=(polar-postgres polar-keycloak); files+=(postgresql keycloak-config keycloak); }
  needs_rabbit && { backing+=(polar-rabbitmq); files+=(rabbitmq); }

  log "Namespace $NS"
  "${KUBECTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null || exit 1
  echo "Namespace ready"
  if (( ${#files[@]} )); then
    log "Deploying ${backing[*]}"
    for s in "${files[@]}"; do k apply -f "$K8S_SERVICES/$s.yml" >/dev/null || exit 1; done
    # The apps connect to PostgreSQL and RabbitMQ at startup; Keycloak is used on first request.
    for s in "${backing[@]}"; do [[ $s == polar-keycloak ]] || k8s_rollout "$s"; done
  fi

  local digest
  for s in "${SERVICES[@]}"; do
    log "Deploying $s"
    digest=$(k8s_push "$s") || exit 1
    echo "Pushed $REGISTRY/$s@$digest"
    k apply -k "$(k8s_overlay "$s" "$digest")" >/dev/null || exit 1
  done
  for s in "${SERVICES[@]}" "${backing[@]}"; do k8s_rollout "$s"; done

  k8s_urls
  if needs_keycloak; then
    wait_until 180 "Keycloak realm" curl -sf "$KEYCLOAK/realms/PolarBookshop" || exit 1
  fi
  wait_consumers
}

k8s_down() {
  log "Deleting namespace $NS"
  "${KUBECTL[@]}" delete namespace "$NS" --ignore-not-found --wait=true >/dev/null && echo "Namespace deleted"
  echo "The cluster keeps running; stop it with: sudo microk8s stop"
}

# The deployments as Kubernetes sees them: ready, never restarted (a failing liveness probe
# restarts the container), running the pushed image, with the memory limit.
test_k8s() {
  log "Kubernetes deployments (namespace $NS)"
  local s
  for s in "${SERVICES[@]}"; do
    BODY=$(k get pods -l "app=$s" -o json)
    local cs='[c for p in d["items"] if not p["metadata"].get("deletionTimestamp") for c in p["status"].get("containerStatuses", [])]'
    check "$s pod ready"                    True "$(json "len($cs) == 1 and $cs[0]['ready']")"
    check "$s container restarts"           0 "$(json "sum(c['restartCount'] for c in $cs)")"
    check "$s image from $REGISTRY"         True "$(json "all(c['imageID'].startswith('$REGISTRY/$s@') for c in $cs)")"
    check "$s memory limit"                 "$K8S_MEMORY_LIMIT" \
      "$(json "[c['resources']['limits']['memory'] for p in d['items'] for c in p['spec']['containers']][0]")"
  done
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
consumer_bound() { # queue
  rabbit GET "/queues/%2F/$1"
  [[ $CODE == 200 && $(json 'd.get("consumers", 0) > 0') == True ]]
}
# Capture messages sent to an exchange in a temporary queue. The services' exchanges are
# normally declared on first use, so declare it here (same type) to bind before that.
capture_start() { # exchange queue -> prints True when the binding is in place
  rabbit PUT "/exchanges/%2F/$1" '{"type":"topic","durable":true}'
  rabbit PUT "/queues/%2F/$2" '{"durable":false,"auto_delete":false}'
  rabbit POST "/bindings/%2F/e/$1/q/$2" '{"routing_key":"#"}'
  rabbit DELETE "/queues/%2F/$2/contents"
  rabbit GET "/exchanges/%2F/$1/bindings/source"
  json "any(b['destination'] == '$2' for b in d)"
}
capture_take() { # queue -> prints orderId of the next message, waiting up to 5 s
  local got="" i
  for i in 1 2 3 4 5; do
    rabbit POST "/queues/%2F/$1/get" '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}'
    got=$(json 'json.loads(d[0]["payload"])["orderId"] if d else ""'); [[ -n $got ]] && break; sleep 1
  done
  echo "$got"
}
capture_stop() { rabbit DELETE "/queues/%2F/$1"; }
publish_order_message() { # exchange orderId -> prints whether the message was routed
  rabbit POST "/exchanges/%2F/$1/publish" \
    "{\"properties\":{\"content_type\":\"application/json\"},\"routing_key\":\"#\",\"payload\":\"{\\\"orderId\\\":$2}\",\"payload_encoding\":\"string\"}"
  json 'd["routed"]'
}

token() { # username -> access token whose issuer matches what the services expect
  curl -sf -H "Host: $KC_HOST" \
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
  if (( K8S )); then
    check "greeting from the k8s ConfigMap"   "$(python3 -I -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["polar"]["greeting"])' \
      "$PB/catalog-service/k8s/application.yml")" "$BODY"
  elif ! config_client catalog-service; then
    check "greeting from application.yml"     "Welcome to the local book catalog!" "$BODY"
  fi
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

  check "capture queue bound to order-accepted" True "$(capture_start order-accepted $capture)"

  req POST $ORDER/orders "$B" "$order";     check "POST order as bjorn"              200 "$CODE" "$BODY"
  local id; id=$(json 'd["id"]')
  check "order status"                      ACCEPTED "$(json 'd["status"]')"
  check "order bookName from catalog"       "Northern Lights - Lyra Silverstar" "$(json 'd["bookName"]')"
  check "order bookPrice from catalog"      9.9 "$(json 'd["bookPrice"]')"
  check "order createdBy populated"         True "$(json 'd.get("createdBy") is not None')"
  check "order-accepted event published"    "$id" "$(capture_take $capture)"
  capture_stop $capture

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

  # With dispatcher-service running, the accepted order is dispatched end to end. Without it,
  # stand in for the dispatcher by sending order-dispatched directly.
  local what="order DISPATCHED by dispatcher-service"
  if ! has dispatcher-service; then
    check "simulated order-dispatched routed" True "$(publish_order_message order-dispatched "$id")"
    what="order DISPATCHED after simulated message"
  fi
  local status="" i
  for i in $(seq 15); do
    req GET $ORDER/orders "$B"
    status=$(json "next(o['status'] for o in d if o['id'] == $id)")
    [[ $status == DISPATCHED ]] && break; sleep 1
  done
  check "$what"                             DISPATCHED "$status"
}

test_dispatcher() {
  local capture=smoke-test.order-dispatched
  # High enough not to match a real order, so order-service (if running) ignores it.
  local id=$(( 900000000 + RANDOM ))

  log "dispatcher-service ($DISPATCHER)"
  req GET $DISPATCHER/actuator/health;           check "health status"               UP "$(json 'd["status"]')"
  check "health rabbit component"                UP "$(json 'd["components"]["rabbit"]["status"]')"
  req GET $DISPATCHER/actuator/health/liveness;  check "liveness probe"              200 "$CODE"
  req GET $DISPATCHER/actuator/health/readiness; check "readiness probe"             200 "$CODE"
  req GET $DISPATCHER/actuator/bindings
  check "packlabel-in-0 binding running"         True "$(json "any(b['bindingName'] == 'packlabel-in-0' and b['state'] == 'running' for b in d)")"

  check "capture queue bound to order-dispatched" True "$(capture_start order-dispatched $capture)"
  check "order-accepted message routed"          True "$(publish_order_message order-accepted $id)"
  check "order-dispatched emitted for same id"   "$id" "$(capture_take $capture)"
  capture_stop $capture
}

test_config() {
  # config-service clones https://github.com/PolarBookshop/config-repo (not the local
  # config-repo/ directory), so check structure rather than exact property values.
  log "config-service ($CONFIG)"
  req GET $CONFIG/actuator/health;           check "health status"                    UP "$(json 'd["status"]')"
  req GET $CONFIG/actuator/health/liveness;  check "liveness probe"                   200 "$CODE"
  req GET $CONFIG/actuator/health/readiness; check "readiness probe"                  200 "$CODE"

  req GET $CONFIG/catalog-service/default;   check "GET catalog-service/default"      200 "$CODE"
  check "default source is catalog-service.yml" True "$(json 'd["propertySources"][0]["name"].endswith("/catalog-service.yml")')"
  local greeting; greeting=$(json 'd["propertySources"][0]["source"]["polar.greeting"]')
  check "default polar.greeting served"      True "$([[ -n $greeting ]] && echo True)"

  req GET $CONFIG/catalog-service/prod;      check "GET catalog-service/prod"         200 "$CODE"
  check "prod source first"                  True "$(json 'd["propertySources"][0]["name"].endswith("/catalog-service-prod.yml")')"
  check "prod also includes default source"  True "$(json 'any(s["name"].endswith("/catalog-service.yml") for s in d["propertySources"])')"
  local prod_greeting; prod_greeting=$(json 'd["propertySources"][0]["source"]["polar.greeting"]')
  check "prod overrides polar.greeting"      True "$([[ -n $prod_greeting && $prod_greeting != "$greeting" ]] && echo True)"

  req GET $CONFIG/catalog-service/default/main;  check "GET with label main"          200 "$CODE"
  req GET $CONFIG/catalog-service/default/no-such-label; check "GET with unknown label" 404 "$CODE"
  req GET $CONFIG/no-such-app/default;       check "GET unknown application"          200 "$CODE"
  check "unknown application has no sources" 0 "$(json 'len(d["propertySources"])')"
  req GET $CONFIG/catalog-service-default.yml; check "GET catalog-service-default.yml" 200 "$CODE"
  check "YAML contains the greeting"         True "$([[ $BODY == *"$greeting"* ]] && echo True)"
}

# edge METHOD PATH JAR [JSON] [nocsrf] -> request through edge-service with the session in cookie
# jar JAR; sets $CODE, $BODY and $LOCATION. Sends the XSRF-TOKEN cookie as X-XSRF-TOKEN unless
# "nocsrf" is given.
edge() {
  local args=(-s -c "$3" -b "$3" -o "$WORK/body" -D "$WORK/headers" -w '%{http_code} %{redirect_url}' -X "$1")
  [[ -n ${4:-} ]] && args+=(-H 'Content-Type: application/json' -d "$4")
  if [[ ${5:-} != nocsrf ]]; then
    local xsrf; xsrf=$(awk '$6 == "XSRF-TOKEN" {print $7}' "$3" 2>/dev/null | tail -1)
    [[ -n $xsrf ]] && args+=(-H "X-XSRF-TOKEN: $xsrf")
  fi
  read -r CODE LOCATION < <(curl "${args[@]}" "$EDGE$2"); BODY=$(cat "$WORK/body")
}

# Logs USER in through edge-service's OAuth2 authorization-code flow, as a browser would.
# Keycloak is addressed as host.docker.internal:8080 (the issuer edge-service uses), which
# curl connects to on localhost.
edge_login() { # user jar
  local jar=$2 url action cookies kc=(--connect-to host.docker.internal:8080:localhost:8080)
  rm -f "$jar"
  url=$(curl -s -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$EDGE/oauth2/authorization/keycloak")
  [[ $url == http://host.docker.internal:8080/* ]] || return 1
  curl -s "${kc[@]}" -D "$WORK/kc-headers" -o "$WORK/kc-login.html" "$url" || return 1
  action=$(python3 -I -c '
import sys, re, html
form = re.search(r"<form[^>]*id=\"kc-form-login\"[^>]*>", open(sys.argv[1]).read())
action = form and re.search(r"action=\"([^\"]+)\"", form.group(0))
print(html.unescape(action.group(1)) if action else "")' "$WORK/kc-login.html")
  [[ -n $action ]] || return 1
  # Keycloak marks its login-session cookies Secure, and curl won't store Secure cookies
  # received over plain http from a host other than localhost, so pass them on by hand.
  cookies=$(sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\);.*/\1/p' "$WORK/kc-headers" | paste -sd ';' -)
  url=$(curl -s "${kc[@]}" -H "Cookie: $cookies" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$1" --data-urlencode password=password -d credentialId= "$action")
  [[ $url == "$EDGE/login/oauth2/code/"* ]] || return 1
  url=$(curl -s -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$url")
  [[ $url == "$EDGE/" ]]
}

test_edge() {
  local anon=$WORK/anon.jar ij=$WORK/isabelle.jar bj=$WORK/bjorn.jar
  local isbn="98$(date +%s | tail -c 9)"
  local book="{\"isbn\":\"$isbn\",\"title\":\"Edge Smoke Test\",\"author\":\"Smoke Tester\",\"price\":7.5,\"publisher\":\"Polarsophia\"}"

  log "edge-service ($EDGE)"
  req GET $EDGE/actuator/health;            check "health status"                     UP "$(json 'd["status"]')"
  check "health redis component"            UP "$(json 'd["components"]["redis"]["status"]')"
  req GET $EDGE/actuator/health/liveness;   check "liveness probe"                    200 "$CODE"
  req GET $EDGE/actuator/health/readiness;  check "readiness probe (incl. redis)"     200 "$CODE"
  req GET $EDGE/actuator/gateway/routes
  check "gateway routes configured"         True "$(json '{"spa-route","catalog-route","order-route"} <= {r["route_id"] for r in d}')"

  edge GET / "$anon";                       check "GET / (polar-ui via spa-route)"    200 "$CODE"
  check "SPA page is HTML"                  True "$(grep -qi '<html' "$WORK/body" && echo True)"
  edge GET /books "$anon";                  check "GET /books anonymously"            200 "$CODE"
  check "books returned from catalog"       True "$(json 'len(d) >= 2')"
  check "rate limiter header present"       True "$(grep -qi '^X-RateLimit-Remaining:' "$WORK/headers" && echo True)"
  edge GET /user "$anon";                   check "GET /user anonymously"             401 "$CODE"
  edge GET /orders "$anon";                 check "GET /orders anonymously"           401 "$CODE"
  edge POST /books "$anon" "$book";         check "POST /books anonymously"           401 "$CODE"

  check "isabelle logs in via Keycloak"     True "$(edge_login isabelle "$ij" && echo True)"
  edge GET /user "$ij";                     check "GET /user as isabelle"             200 "$CODE" "$BODY"
  check "user is isabelle"                  isabelle "$(json 'd["username"]')"
  check "isabelle has employee role"        True "$(json '"employee" in d["roles"]')"
  edge POST /books "$ij" "$book" nocsrf;    check "POST /books without CSRF token"    403 "$CODE"
  edge POST /books "$ij" "$book";           check "POST /books as isabelle (relayed)" 201 "$CODE" "$BODY"
  edge DELETE "/books/$isbn" "$ij";         check "DELETE /books as isabelle"         204 "$CODE"

  check "bjorn logs in via Keycloak"        True "$(edge_login bjorn "$bj" && echo True)"
  edge GET /user "$bj";                     check "user is bjorn"                     bjorn "$(json 'd["username"]')"
  edge POST /books "$bj" "$book";           check "POST /books as bjorn (customer)"   403 "$CODE"
  edge POST /orders "$bj" '{"isbn":"1234567891","quantity":1}'
  check "POST /orders as bjorn (relayed)"   200 "$CODE" "$BODY"
  check "order accepted"                    ACCEPTED "$(json 'd["status"]')"
  local id; id=$(json 'd["id"]')
  edge GET /orders "$bj";                   check "GET /orders as bjorn"              200 "$CODE"
  check "bjorn's order listed"              True "$(json "any(o['id'] == $id for o in d)")"

  edge POST /logout "$ij";                  check "POST /logout as isabelle"          302 "$CODE"
  check "logout redirects to Keycloak"      True "$([[ $LOCATION == http://host.docker.internal:8080/realms/PolarBookshop/protocol/openid-connect/logout* ]] && echo True)"
  edge GET /user "$ij";                     check "GET /user after logout"            401 "$CODE"

  # Circuit breaker: with catalog-service frozen, reads fall back to an empty 200 and
  # writes to 503 (after the 5 s time limit).
  podman pause catalog-service >/dev/null
  edge GET /books "$anon";                  check "GET /books, catalog down: fallback" 200 "$CODE"
  check "fallback body is empty"            "" "$BODY"
  edge POST /books "$bj" "$book";           check "POST /books, catalog down"         503 "$CODE"
  podman unpause catalog-service >/dev/null
  edge GET /books "$anon";                  check "GET /books, catalog back"          200 "$CODE"
  check "books returned again"              True "$(json 'len(d) >= 2')"
}

# Collects the authors returned by N calls to URL, as a sorted, comma-separated list.
authors_from() { # url n [json-body to POST]
  local i args=(-s)
  [[ -n ${3:-} ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  for i in $(seq "$2"); do
    curl "${args[@]}" "$1" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["author"])' 2>/dev/null
  done | sort -u | paste -sd, -
}

test_quote() {
  log "quote-service ($QUOTE)"
  req GET $QUOTE/quotes;                    check "GET /quotes"                       200 "$CODE"
  check "six quotes"                        6 "$(json 'len(d)')"
  check "quotes have content/author/genre"  True "$(json 'all({"content","author","genre"} <= q.keys() for q in d)')"
  check "two quotes per genre"              True "$(json '{g: [q["genre"] for q in d].count(g) for g in ("ADVENTURE","FANTASY","SCIENCE_FICTION")} == {"ADVENTURE":2,"FANTASY":2,"SCIENCE_FICTION":2}')"

  req GET $QUOTE/quotes/random;             check "GET /quotes/random"                200 "$CODE"
  check "random quote is a known author"    True "$(json 'd["author"] in ("Abigail","Beatrix","Casper","Dobby","Eileen","Flora")')"
  local g
  for g in ADVENTURE FANTASY SCIENCE_FICTION; do
    req GET $QUOTE/quotes/random/$g;        check "GET /quotes/random/$g"             200 "$CODE"
    check "random $g quote has that genre"  $g "$(json 'd["genre"]')"
  done
  req GET $QUOTE/quotes/random/POETRY;      check "GET /quotes/random/POETRY"         400 "$CODE"

  # Regression checks for nextInt(size - 1), which never picked the last quote: the last
  # quote (Flora) and both FANTASY quotes should all turn up. A miss is ~0.07% likely.
  check "random covers the last quote"      True "$([[ $(authors_from $QUOTE/quotes/random 40) == *Flora* ]] && echo True)"
  check "random FANTASY covers both quotes" Casper,Dobby "$(authors_from $QUOTE/quotes/random/FANTASY 20)"
}

smoke_logged() { podman logs quote-function 2>&1 | grep -c "Quote: 'Smoke' by Tester"; }
logged_quotes() { podman logs quote-function 2>&1 | grep -c "QuoteFunctions *: Quote: '"; }

test_quote_function() {
  log "quote-function ($QUOTE_FN)"
  # GET / runs the configured default function, allQuotes (which delays its output by 1 s).
  req GET $QUOTE_FN/;                          check "GET / (default allQuotes)"            200 "$CODE"
  check "six quotes"                           6 "$(json 'len(d)')"
  check "quotes have content/author/genre"     True "$(json 'all({"content","author","genre"} <= q.keys() for q in d)')"
  check "two quotes per genre"                 True "$(json '{g: [q["genre"] for q in d].count(g) for g in ("ADVENTURE","FANTASY","SCIENCE_FICTION")} == {"ADVENTURE":2,"FANTASY":2,"SCIENCE_FICTION":2}')"
  req GET $QUOTE_FN/allQuotes;                 check "GET /allQuotes"                       200 "$CODE"
  check "allQuotes returns six quotes"         6 "$(json 'len(d)')"

  req GET $QUOTE_FN/randomQuote;               check "GET /randomQuote"                     200 "$CODE"
  check "random quote is a known author"       True "$(json 'd["author"] in ("Abigail","Beatrix","Casper","Dobby","Eileen","Flora")')"

  local g
  for g in ADVENTURE FANTASY SCIENCE_FICTION; do
    req POST $QUOTE_FN/genreQuote "" "\"$g\"";  check "POST /genreQuote $g"                   200 "$CODE"
    check "genreQuote $g has that genre"       $g "$(json 'd["genre"]')"
  done
  req POST $QUOTE_FN/genreQuote "" '"POETRY"'; check "POST /genreQuote POETRY"              400 "$CODE"
  check "error body names the path"            /genreQuote "$(json 'd["path"]')"
  req POST $QUOTE_FN/genreQuote;               check "POST /genreQuote without a genre"     400 "$CODE"
  req GET $QUOTE_FN/genreQuote;                check "GET /genreQuote without a genre"      400 "$CODE"

  # logQuote is a Consumer: 202 with no body, and the quote shows up in the log.
  local before=$(smoke_logged)
  req POST $QUOTE_FN/logQuote "" '{"content":"Smoke","author":"Tester","genre":"FANTASY"}'
  check "POST /logQuote"                       202 "$CODE"
  check "logQuote logs the quote"              $(( before + 1 )) "$(smoke_logged)"
  before=$(logged_quotes)
  req POST $QUOTE_FN/genreQuote,logQuote "" '"FANTASY"'
  check "POST /genreQuote,logQuote"            202 "$CODE"
  check "composed function logs one quote"     $(( before + 1 )) "$(logged_quotes)"

  # Regression checks for nextInt(size - 1), which never picked the last quote.
  check "randomQuote covers the last quote"    True "$([[ $(authors_from $QUOTE_FN/randomQuote 40) == *Flora* ]] && echo True)"
  check "genreQuote FANTASY covers both quotes" Casper,Dobby "$(authors_from $QUOTE_FN/genreQuote 20 '"FANTASY"')"
}

# catalog-service started as a config client (see config_client).
test_config_client() {
  log "catalog-service configuration from config-service"
  local profile; profile=$(podman inspect -f '{{range .Config.Env}}{{println .}}{{end}}' catalog-service \
    | sed -n 's/^SPRING_PROFILES_ACTIVE=//p')
  req GET "$CONFIG/catalog-service/${profile:-default}"
  local served; served=$(json 'next(s["source"]["polar.greeting"] for s in d["propertySources"] if "polar.greeting" in s["source"])')
  check "config-service serves a greeting"    True "$([[ -n $served ]] && echo True)" "profile ${profile:-default}"
  req GET $CATALOG/;                          check "GET / greeting is the served one" "$served" "$BODY"
  req GET $CATALOG/actuator/env
  check "env has the configserver source"     True "$(json 'any(s["name"].startswith("configserver:") and s["name"].endswith("/catalog-service.yml") for s in d["propertySources"])')"
  # Values are masked; the first source defining polar.greeting is the one in effect.
  check "polar.greeting comes from it"        True "$(json 'next(s["name"] for s in d["propertySources"] if "polar.greeting" in s.get("properties", {})).startswith("configserver:")')"
}

test_metrics() {
  log "Actuator metrics"
  local s
  for s in "${TRACED[@]}"; do
    has "$s" || continue
    CODE=$(curl -s -o "$WORK/body" -w '%{http_code}' "${BASE_URL[$s]}/actuator/prometheus")
    check "$s /actuator/prometheus"           200 "$CODE"
    check "$s JVM metrics tagged with its name" True \
      "$(grep -q "^jvm_memory_used_bytes{.*application=\"$s\"" "$WORK/body" && echo True)"
  done
}

prom_value() { # PromQL -> first sample's value
  curl -s --get --data-urlencode "query=$1" "$PROMETHEUS/api/v1/query" \
    | python3 -I -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")' 2>/dev/null
}
prom_positive() { local v; v=$(prom_value "$1"); [[ -n $v ]] && python3 -I -c "import sys; sys.exit(not float(sys.argv[1]) > 0)" "$v"; }
prom_up() { [[ $(prom_value "up{job=\"$1\"}") == 1 ]]; }
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
# Services that sent spans for a trace, sorted and comma-separated.
trace_services() { # trace-id
  curl -sf "$TEMPO/api/traces/$1" | python3 -I -c '
import sys, json
d = json.load(sys.stdin)
batches = d.get("batches") or d.get("resourceSpans") or d.get("trace", {}).get("resourceSpans", [])
names = {a["value"]["stringValue"] for b in batches for a in b["resource"]["attributes"]
         if a["key"] == "service.name"}
print(",".join(sorted(names)))' 2>/dev/null
}
trace_has() { # trace-id comma-separated-services
  local got; got=$(trace_services "$1")
  [[ $got == "$2" ]]
}

test_observability() {
  log "Observability (Prometheus, Tempo, Grafana)"
  local s id
  for s in "${TRACED[@]}"; do
    has "$s" || continue
    wait_until 30 "Prometheus to scrape $s" prom_up "$s" >/dev/null
    check "Prometheus target $s is up"        1 "$(prom_value "up{job=\"$s\"}")"
    check "Prometheus has $s JVM metrics"     True "$([[ $(prom_value "count(jvm_memory_used_bytes{application=\"$s\"})") -gt 0 ]] 2>/dev/null && echo True)"
  done

  # Requests carry our own W3C traceparent, so the trace can be fetched by id instead of searched.
  for s in "${TRACED[@]}"; do
    has "$s" || continue
    id=$(hex 16)
    curl -s -o /dev/null -H "traceparent: 00-$id-$(hex 8)-01" "${READY_URL[$s]}"
    wait_until 60 "Tempo to receive the $s trace" trace_has "$id" "$s" >/dev/null
    check "Tempo has a trace from $s"         "$s" "$(trace_services "$id")"
  done
  local flow_id= expected
  if has order-service; then
    # An order calls catalog-service, and its order-accepted event reaches dispatcher-service.
    flow_id=$(hex 16); expected=catalog-service,order-service
    has dispatcher-service && expected=catalog-service,dispatcher-service,order-service
    curl -s -o "$WORK/body" -H "traceparent: 00-$flow_id-$(hex 8)-01" -H "Authorization: Bearer $B" \
      -H 'Content-Type: application/json' -d '{"isbn":"1234567891","quantity":1}' "$ORDER/orders"
    wait_until 60 "Tempo to receive the order trace" trace_has "$flow_id" "$expected" >/dev/null
    check "order trace spans $expected"       "$expected" "$(trace_services "$flow_id")"
  fi
  if has edge-service; then
    id=$(hex 16)
    curl -s -o /dev/null -H "traceparent: 00-$id-$(hex 8)-01" "$EDGE/books"
    wait_until 60 "Tempo to receive the edge trace" trace_has "$id" catalog-service,edge-service >/dev/null
    check "edge /books trace spans catalog"   catalog-service,edge-service "$(trace_services "$id")"
  fi

  # Tempo's metrics generator remote-writes span metrics and the service graph to Prometheus
  # (needs --web.enable-remote-write-receiver and native histograms on Prometheus).
  for s in "${TRACED[@]}"; do
    has "$s" || continue
    wait_until 90 "span metrics for $s" prom_positive "sum(traces_spanmetrics_calls_total{service=\"$s\"})" >/dev/null
    check "Prometheus has Tempo span metrics for $s" True \
      "$(prom_positive "sum(traces_spanmetrics_calls_total{service=\"$s\"})" && echo True)"
  done
  local edges=()
  has order-service && edges+=(order-service:catalog-service)
  has order-service && has dispatcher-service && edges+=(order-service:dispatcher-service dispatcher-service:order-service)
  has edge-service && edges+=(edge-service:catalog-service)
  local e q
  for e in "${edges[@]}"; do
    q="sum(traces_service_graph_request_total{client=\"${e%%:*}\",server=\"${e#*:}\"})"
    wait_until 90 "service graph edge ${e/:/ -> }" prom_positive "$q" >/dev/null
    check "service graph has ${e/:/ -> }"     True "$(prom_positive "$q" && echo True)"
  done

  local g=(-s -u "$GRAFANA_AUTH")
  BODY=$(curl "${g[@]}" "$GRAFANA/api/health")
  check "Grafana database"                    ok "$(json 'd["database"]')"
  BODY=$(curl "${g[@]}" "$GRAFANA/api/datasources")
  check "Grafana datasources provisioned"     Loki,Prometheus,Tempo "$(json '",".join(sorted(x["name"] for x in d))')"
  BODY=$(curl "${g[@]}" "$GRAFANA/api/search?type=dash-db")
  check "Grafana dashboards provisioned"      "$(ls "$PB"/polar-deployment/docker/observability/grafana/dashboards/*.json | wc -l)" "$(json 'len(d)')"
  BODY=$(curl "${g[@]}" --get --data-urlencode 'query=up' "$GRAFANA/api/datasources/proxy/uid/prometheus-thomas-vitale/api/v1/query")
  check "Grafana queries Prometheus"          success "$(json 'd["status"]')"
  if [[ -n $flow_id ]]; then
    CODE=$(curl "${g[@]}" -o /dev/null -w '%{http_code}' "$GRAFANA/api/datasources/proxy/uid/tempo-thomas-vitale/api/traces/$flow_id")
    check "Grafana fetches the order trace from Tempo" 200 "$CODE"
  fi
}

run_tests() {
  if (( K8S )); then
    k8s_check_cluster
    k8s_urls
    needs_keycloak && k8s_forward_keycloak
    test_k8s
  fi
  if needs_keycloak; then
    log "Preparing tokens"
    ensure_test_client || exit 1
    I=$(token isabelle) && B=$(token bjorn) || { echo "Could not obtain user tokens" >&2; exit 1; }
  fi

  has config-service && test_config
  config_client catalog-service && test_config_client
  has catalog-service && test_catalog
  has dispatcher-service && test_dispatcher
  has order-service && test_order
  has edge-service && test_edge
  has quote-service && test_quote
  has quote-function && test_quote_function
  test_metrics
  needs_observability && test_observability

  log "Result: $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}

down() {
  log "Stopping stack"
  local s
  for s in "${ALL_APPS[@]}"; do podman rm -f "$s" >/dev/null 2>&1; done
  echo "Removed app containers"
  podman-compose -f "$COMPOSE" down >/dev/null 2>&1 && echo "Compose services removed"
  podman ps --format '{{.Names}} {{.Status}}'
}

if (( K8S )); then
  up() { k8s_up; }
  down() { k8s_down; }
fi
case $CMD in
  up)   up ;;
  test) run_tests ;;
  down) down ;;
  all)  up && run_tests ;;
esac
