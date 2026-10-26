---
name: smoke-test
description: Start PolarBookshop services (catalog, order, dispatcher, config, edge with polar-ui, quote, quote-function) with Podman, or deploy catalog, order, dispatcher and config to a MicroK8s Kubernetes cluster from their k8s/ manifests, and run HTTP smoke tests covering health, auth/role checks, book CRUD, order placement, order-accepted/order-dispatched messaging, config serving and catalog-service reading its configuration from config-service, and the edge gateway's OAuth2 login, token relay, CSRF and circuit breaker, polar-ui in a headless browser (Playwright: login, book management, ordering, logout, outages), the quote endpoints of quote-service and quote-function's Spring Cloud Function endpoints, actuator metrics, and (with observability) Prometheus scraping, Tempo traces across services and Grafana provisioning. Use when asked to smoke test, run, or verify any of those services end to end.
---

# PolarBookshop smoke test (Podman, MicroK8s)

This server has Podman 4.9 and podman-compose, and no Docker. The script
`development/script/smoke-test.sh` does the whole job. Run it from the worktree root:

```bash
bash development/script/smoke-test.sh all              # up + test catalog, order, dispatcher, config
bash development/script/smoke-test.sh all edge         # edge-service (+ catalog, order, polar-ui)
bash development/script/smoke-test.sh all ui           # edge, then polar-ui's browser tests
bash development/script/smoke-test.sh all catalog      # catalog-service only (postgres + keycloak)
bash development/script/smoke-test.sh all dispatcher   # dispatcher-service only (rabbitmq)
bash development/script/smoke-test.sh all config       # config-service only (no backing services)
bash development/script/smoke-test.sh all quote        # quote-service only (no backing services)
bash development/script/smoke-test.sh all quote-function  # quote-function only (no backing services)
bash development/script/smoke-test.sh all order dispatcher observability  # + Prometheus, Tempo, Grafana
bash development/script/smoke-test.sh all --rebuild    # rebuild the selected images from this worktree's code first
bash development/script/smoke-test.sh test             # rerun the tests against a running stack
bash development/script/smoke-test.sh down             # remove all the containers
bash development/script/smoke-test.sh logs DIR         # write the containers' state and logs to DIR
bash development/script/smoke-test.sh build order      # (re)build order-service's image only, without catalog's
bash development/script/smoke-test.sh help             # usage; a call without a command prints it too
bash development/script/smoke-test.sh all catalog --k8s  # on MicroK8s instead, see "Kubernetes"
```

Services default to `catalog order dispatcher config`, and any combination can be given. `edge` is
not in the default because everything together doesn't fit in memory. Dependencies are added
automatically:
- `order` adds `catalog`, because order-service looks books up in catalog-service;
- `edge` adds `catalog`, `order` and the prebuilt `polar-ui` image, because the gateway routes to
  them;
- `ui` adds `edge`. It runs the browser tests of polar-ui in `development/ui-test/` after edge's
  checks (see "Browser tests").

With both `catalog` and `config` selected, as in the default, catalog-service reads its
configuration from config-service. Without `config`, it uses its own `application.yml`.

`observability` adds Prometheus, Tempo and Grafana and switches on trace export. It goes on top of
the given services, or the default ones if none are given, but the default set plus observability
doesn't fit in memory. `order dispatcher observability` covers the whole order flow, and
`edge observability` the gateway.

`test` and `all` use the same selection, so run `test edge` against a stack started with
`all edge`.

Pass `--rebuild` when the user wants to test the current code in the worktree. Without it, the
script reuses an existing image, which may be from an older commit. It rebuilds an image that it
built from another worktree, but not one it didn't build, such as one built with `bootBuildImage`
by hand.

CI runs the same script. It builds each image once with `build`, in a job of its own, and the
smoke test jobs run without `--rebuild` on those images. Three environment variables are for CI,
and for machines set up differently from this one (a fourth, `SMOKE_POLAR_UI_IMAGE`, is in
"Browser tests"):
- `SMOKE_JDK_17` and `SMOKE_JDK_21` name the JDKs for the image builds instead of the sdkman ones.
- `SMOKE_JUNIT=<file>` makes `test` and `all` also write every check to the file as a JUnit test
  case. A run that stops before its tests finish, such as one whose `up` fails, gets an error
  case named after the step it stopped in.

## Other worktrees

Every worktree's runs share one stack: the container names, ports, network, image tags and the
`polar-smoke` namespace are the same. So:
- Runs take turns. A run that finds another one running says which worktree and command hold the
  lock, and waits until that run has finished. The wait counts towards a foreground Bash call's
  10-minute limit, so run in the background when another session may be running smoke tests.
- The stack belongs to the worktree whose `up` or `all` started it. Another worktree's `up` or
  `all` takes it over, and then `test` and `logs` refuse to run against it: rerun `all`. `down`
  leaves another worktree's stack running, unless that worktree has been removed.
- An image another worktree built is rebuilt, so that a run doesn't test another worktree's code.

The lock and the records are in `~/.local/state/polar-smoke-test/`.

## Steps

1. **Check memory first.** The machine has ~4 GB RAM and no swap. Run `free -h` and make sure no
   Gradle daemons or other containers are holding memory.
   - The default stack needs about 2.7 GiB available and leaves only ~0.5 GiB free.
   - `edge` needs about 2.5 GiB and leaves ~0.7 GiB free. `ui` adds about 0.3 GiB for the
     browser, so stop MicroK8s first if it runs.
   - Catalog alone needs about 1.5 GiB, dispatcher or config alone about 0.6 GiB, and quote or
     quote-function about 0.55 GiB each (they use only ~110-130 MB once running).
   - `observability` adds about 0.3 GiB. `order dispatcher observability` leaves ~0.35 GiB free
     and `edge observability` ~0.4 GiB.
   - An image build needs more.

   The script removes the selected app containers before building. Its estimate doesn't account
   for backing services that are already running, so its warning can be overcautious on a rerun.
2. Run `smoke-test.sh all` (add a selection and/or `--rebuild` if needed). A run that builds
   images, with `--rebuild`, `build` or images still missing, can take longer than a foreground
   Bash call's 10-minute limit, which would kill it midway, so run it in the background and wait
   for it to finish. The first build of each service also pulls its Paketo builder. A run
   without builds takes a few minutes.
3. Report the PASS/FAIL lines to the user. The script exits non-zero if any check fails. On a
   failure, run `smoke-test.sh logs <dir>` (with `--k8s` for the cluster) and look at the logs
   before reporting. It writes each container's log, their state including exit codes and OOM
   kills, and the memory use. With `--k8s` it writes the namespace's resources, events, pod
   descriptions, and each deployment's log, including the log before a restart.
4. Ask the user whether to keep the stack running or run `smoke-test.sh down`.

## What the script does (and why)

- Builds missing images with `bootBuildImage`. It points Gradle at Podman's API socket with
  `bindHostToBuilder = true` through a temporary init script, so `build.gradle` is not changed. It
  asks Podman for the socket's path and starts `podman.socket` with systemd. Without a systemd
  user session, as on CI runners, it runs `podman system service` for the length of the run
  instead.
- Runs each build on a JDK installed with sdkman (`~/.sdkman/candidates/java`): 21 by default and
  17 for quote-service and quote-function. Both use Spring Native 0.12, whose AOT step can't read Java 21
  class files. This is an interim setup until all projects move to the same JDK and builds use a
  preset `JAVA_HOME`. If a JDK is missing, install it with `sdk install java <version>`, or point
  `SMOKE_JDK_17`/`SMOKE_JDK_21` at another installation.
- Builds quote-service and quote-function as JVM images, although their `build.gradle` asks for a native one
  (`BP_NATIVE_IMAGE=true`). Native compilation needs more memory than this machine has. The init
  script overrides the variable to `false` in `afterEvaluate`, so it runs after `build.gradle` sets it.
- Pulls missing backing-service images with a `docker.io/` prefix. Podman here has no
  unqualified-search registries, so short names such as `rabbitmq:3.13-management` only resolve
  once the image is in local storage.
- Starts only the backing services the selection needs with podman-compose:
  - `polar-postgres` and `polar-keycloak` for catalog, order and edge;
  - `polar-rabbitmq` for order and dispatcher;
  - `polar-redis` for edge.

  If none are needed it skips compose entirely, because `podman-compose up` with no service names
  starts every service in the file. Otherwise it checks that each container is running, because
  podman-compose exits 0 even when a container fails to start.
- Sets the MAC address of the network's bridge, to the one it has, as soon as the first container
  has joined the network. It starts the first backing service on its own for this. netavark
  before 1.9 (this server and the CI runners have 1.4) leaves the bridge's MAC to the kernel,
  which gives the bridge the lowest MAC of its ports, so it can change when a container starts.
  The containers started before then send to the old MAC, and their DNS lookups and connections
  through the gateway, such as to `host.docker.internal`, get no answer for up to a minute. In CI
  this failed about one edge job in five (review finding 34).
- Starts quote-service (port 9101) and quote-function (port 9102) with `podman run`. Neither is
  in the compose file.
- Starts the app services and polar-ui with `podman run` on the `docker_default` network. It
  generates the arguments (env, ports, extra hosts, image) from the compose file with PyYAML. It
  can't use compose for these because:
  - the compose file uses the `fluentd` log driver, which Podman 4.9 rejects;
  - podman-compose merges `depends_on` from override files instead of replacing them, so an
    override can't drop tempo and fluent-bit.

  On top of the compose settings it:
  - sets the OTel log and metric exporters to `none` (logs go through fluent-bit in compose and
    metrics through Prometheus scraping), and the trace exporter too unless `observability` is
    selected;
  - always adds `host.docker.internal:host-gateway`, because order-service's compose entry lacks it
    but its JWT issuer uses that host;
  - sets `--memory 1g`, because otherwise the buildpack memory calculator sizes the heap from host
    RAM (over 2 GB).
- Starts edge-service only once the Keycloak realm responds. edge-service fetches the issuer's
  OpenID configuration at startup and exits if Keycloak isn't up; the other services only contact
  Keycloak on first use.
- Waits until each service's RabbitMQ consumer is attached: `order-dispatched.order-service` and
  `order-accepted.dispatcher-service`. The services report ready even before RabbitMQ is reachable.
- Reads messages through temporary `smoke-test.*` queues bound to the `order-accepted` and
  `order-dispatched` exchanges, and deletes the queues afterwards.
- Adds the public `polar-test` client to Keycloak through the admin API, the same client the
  integration tests use. The imported realm has no password-grant client. The change exists only
  inside the dev container.
- Requests tokens with `Host: host.docker.internal:8080`, so the token issuer matches the
  services' configured `issuer-uri`.
- Logs users in to edge-service with curl, following the browser flow:
  1. `/oauth2/authorization/keycloak`;
  2. the Keycloak login form at `host.docker.internal:8080`, reached through
     `--connect-to ...:localhost:8080`;
  3. the credentials POST;
  4. the redirect back to `/login/oauth2/code/keycloak`.

  Keycloak marks its `AUTH_SESSION_ID` cookie `Secure` (with `sslRequired: external`, which the
  compose realm had until review finding 35, all its login-session cookies), and curl won't
  store those when they come over plain HTTP from a host other than localhost. The script
  therefore copies them from the login page's `Set-Cookie` headers into the POST by hand.
  Browsers drop them, so a browser logs in only with the realm's `sslRequired: none`. Requests
  that change state send the `XSRF-TOKEN` cookie back as `X-XSRF-TOKEN`.
- Reads the scripts, stylesheets and icon that polar-ui's page references, and fetches each
  through edge-service anonymously, as a browser loading the page does: each must answer 200
  with the content type of its kind. The file names carry content hashes, so the checks are
  named after the kinds, and a failure lists the files.
- Tests config-service against https://github.com/PolarBookshop/config-repo, which it clones at
  startup (so it needs network access), not the local `PolarBookshop/config-repo/` directory. The
  two differ in `catalog-service.yml`'s greeting, so the tests check structure rather than exact
  values.
- Starts catalog-service as a config client when config-service is selected. The compose file only
  sets `SPRING_CLOUD_CONFIG_URI`, and the client is off in `application.yml`, so the script adds
  `SPRING_CONFIG_IMPORT=optional:configserver:`, `SPRING_CLOUD_CONFIG_ENABLED=true` and
  `SPRING_CLOUD_CONFIG_FAIL_FAST=true`. Fail-fast makes catalog-service fail to start, instead of
  silently using local defaults, if config-service is unreachable. config-service starts first,
  and catalog-service waits for it to be ready. The checks:
  - GET `/` returns the `polar.greeting` that config-service serves for catalog-service's active
    profile, compared at test time because the upstream repo can change;
  - `/actuator/env` has a `configserver:` property source for `catalog-service.yml`, and it is the
    first source defining `polar.greeting` (values are masked, the source names are not).

  Without config-service, the greeting must be `application.yml`'s "Welcome to the local book
  catalog!".
- Checks each running service's `/actuator/prometheus` (catalog, order, dispatcher, config, edge),
  whether or not `observability` is selected: it returns 200 and has JVM metrics tagged with the
  service's `application` name.
- With `observability`, starts `prometheus`, `tempo` and `grafana` from the compose file. Grafana's
  `depends_on` also brings up `loki` and `fluent-bit`, which receive nothing. The compose images
  are pinned by tag and digest; the pull adds `docker.io/` like for the other images. Tempo logs
  errors about a `memcached` host its config names but compose doesn't define; they're harmless.
  The checks:
  - Prometheus has each running service's target up, with its JVM metrics;
  - Tempo has a trace from each running service. The test sends its own W3C `traceparent` header
    and fetches the trace by id, instead of searching;
  - an order placed with a `traceparent` becomes one trace across order-service and
    catalog-service, and dispatcher-service when it runs (the context travels through RabbitMQ);
  - with edge-service, GET `/books` through the gateway is one trace across edge-service and
    catalog-service;
  - Tempo's metrics generator remote-writes span metrics and a service graph to Prometheus. The
    compose file starts Prometheus with `--web.enable-remote-write-receiver` and
    `--enable-feature=native-histograms`; without the latter Prometheus rejects every write,
    because Tempo sends native histograms. The test checks span metrics for each running service
    and the service-graph edges order → catalog, order ↔ dispatcher (over RabbitMQ) and
    edge → catalog. They take up to a minute to arrive;
  - Grafana's database is ok, it has the Prometheus, Tempo and Loki datasources and the three
    dashboards from `observability/grafana/`, and it can query Prometheus and fetch the order
    trace from Tempo through its datasource proxy.
- Treats a 200 from `/quotes` (quote-service) or `/randomQuote` (quote-function) as ready, because
  neither has an actuator.
- Leaves the orders it creates in the database, because order-service has no delete endpoint.

## Browser tests (`ui`)

`ui` runs the Playwright tests in `development/ui-test/` against edge-service, in headless
Chromium. They need Node.js and npm; without them the section fails with one check that says so,
and the rest of the run goes on. The script:
- runs `npm ci` there when `node_modules` is missing or older than the lock file, and
  `playwright install chromium-headless-shell`, which downloads the browser only once;
- turns each test into one check in the "polar-ui (browser)" section, and so into a JUnit test
  case. A failure's detail is the first line of its error. A test marked `test.fail` for an open
  review finding passes as "expected failure", and fails once it passes, so that the finding's
  fix also removes the mark;
- leaves the list reporter's output (`output.log`) and the traces and screenshots of failed tests
  in `development/ui-test/test-results/`, which `logs DIR` copies to `DIR/ui/`. Open a trace with
  `npx playwright show-trace <trace.zip>`;
- runs the undo commands the outage tests note in a file while catalog-service is paused or its
  database closed, after the tests and when the script exits, so that a killed test doesn't leave
  the stack broken.

The tests run one at a time, under the script's lock, because some of them break parts of the
stack for a while. Each test's books have ISBNs starting with 97, and a fixture deletes them from
catalog's database before and after each test. `npx playwright test` in that directory runs them
by hand against a running edge stack, but without the lock.

polar-ui's source isn't in this repository. It is developed in the fork
[mikkosuonio-ai/polar-ui](https://github.com/mikkosuonio-ai/polar-ui), cloned at
`/home/ai/devel/polar-ui`, whose CI publishes its image. To test a change there before it is
released, build the image in the fork and pass it to the script:
`SMOKE_POLAR_UI_IMAGE=localhost/polar-ui:dev bash development/script/smoke-test.sh all ui`.

## Kubernetes (`--k8s`)

With `--k8s` the script deploys to a MicroK8s cluster instead of starting Podman containers. It
supports catalog, order, dispatcher and config, the services with a `k8s/` directory; it refuses
edge, quote, quote-function and observability (see Future work 6). The selection, the commands and
the HTTP checks are the same as with Podman.

### Prerequisites

Once per machine:

```bash
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER   # then log in again, or run `newgrp microk8s`
microk8s status --wait-ready
microk8s enable dns
microk8s enable registry
```

`dns` gives the pods the Service names the manifests use (`polar-postgres`, `polar-rabbitmq`,
...). `registry` runs an image registry at `localhost:32000`, which the script pushes the Podman
images to. Podman is still needed, to build the images.

Starting and stopping the cluster needs sudo, so ask the user to do it:

```bash
sudo microk8s start
sudo microk8s stop    # when done; the idle cluster holds about 0.6 GiB
```

The Podman stack and the cluster shouldn't run at the same time on this machine. A session that
started before the user joined the `microk8s` group doesn't have the group yet; run the script
with `sg microk8s -c 'bash development/script/smoke-test.sh all catalog --k8s'`. To use
another cluster, set `KUBECTL` to its kubectl command (it needs the same registry setup).

### Memory on this machine

With the idle cluster, about 2.1 GiB is available.
- dispatcher, config or catalog (with PostgreSQL and Keycloak) alone each start cleanly.
- `order dispatcher` and the default set fit when added to a running namespace one step at a time
  (catalog, then order, then dispatcher, then config); the default set leaves ~0.65 GiB.
- A cold `all --k8s` passes too, with no restarts. The four JVMs and Keycloak starting together
  on 2 CPUs take 36-43 seconds. That's longer than the liveness probes allow, but the apps'
  startup probes give them up to 150 seconds (see `PolarBookshop/findings.md`). Starting with
  ~2.2 GiB available, it left at least ~0.75 GiB.

### What it does

- Deploys into its own namespace, `polar-smoke`; `down` deletes the namespace.
- Deploys the backing services from `polar-deployment/kubernetes/platform/development/services/`:
  PostgreSQL and Keycloak for catalog and order, RabbitMQ for order and dispatcher. The apps are
  deployed once PostgreSQL and RabbitMQ have rolled out; Keycloak is only used on first request,
  so it's waited for afterwards.
- Builds missing images with Podman as usual, pushes them to `localhost:32000` and deploys each
  app from its own `k8s/` kustomization through a generated overlay. The overlay changes only two
  things:
  - the image, referenced by the pushed digest, so a `--rebuild` always rolls out;
  - a memory limit of 756Mi, the production overlays' value, with a 256Mi request. Without a
    limit the buildpack memory calculator sizes the heap from the node's RAM.
- Reaches the services on their ClusterIPs, which MicroK8s routes from the host, except Keycloak:
  its master realm requires HTTPS for requests from non-private addresses, and requests from the
  host to a ClusterIP come from the node's public address. During `test` the script reaches
  Keycloak through a `kubectl port-forward` on `localhost:38080` instead, and requests tokens with
  `Host: polar-keycloak`, the issuer the `k8s/` configs use.
- Adds checks for each app's pod: ready, no container restarts (a failing liveness probe shows up
  here), running the pushed image, and the memory limit. catalog-service's greeting must be the one
  in its `k8s/application.yml` ConfigMap. catalog-service isn't a config client on Kubernetes,
  because its manifests don't make it one.
- Leaves the cluster running; ask the user whether to stop it.

## Future work

Not verified yet, roughly in order of value:

1. **Other config clients and profiles.** Only catalog-service is tested as a config client.
   order-service, dispatcher-service and edge-service include the client too, but the config-repo
   has no files for them, so enabling it would change nothing visible. The client is also only
   checked with the `testdata` profile; `prod` is checked on config-service alone. Refreshing
   configuration at runtime isn't covered either: no service exposes `/actuator/refresh`.
2. **Logs and the rest of observability.** Logs don't reach Loki: the apps' compose entries use
   the `fluentd` log driver, which Podman 4.9 rejects, so fluent-bit gets nothing. A workaround
   could ship `podman logs` output to fluent-bit's forward port, or use Podman's journald driver
   with a fluent-bit input for it. Also not covered:
   - whether the Grafana dashboards' panels actually show data;
   - the full default set together with observability, which doesn't fit in memory.
3. **Behaviour after a restart or a broker outage:**
   - restart rabbitmq while an order is in flight and check it still reaches DISPATCHED;
   - restart postgres or catalog-service and check the services recover.

   The edge test already pauses catalog-service; these would extend that.
4. **Edge rate limiting and sessions.** The test only checks that the `X-RateLimit-Remaining`
   header is there. Exhausting the limit to get a 429, and checking that the login session lives in
   Redis (it survives an edge-service restart), would cover the Redis side properly.
5. **Actuator exposure.** The services expose `env`, `heapdump` and `configprops`. A check that none
   of these can be reached through edge-service (port 9000) would catch an accidental route.
6. **The rest of Kubernetes.** `--k8s` covers catalog, order, dispatcher and config with the
   development manifests. Still missing:
   - edge-service and polar-ui, for the whole system on a bigger machine. That needs the
     `ingress` addon for `polar-ingress`, the browser login flow pointed at `polar-keycloak`
     (`--connect-to polar-keycloak:80:localhost:38080` over the port-forward), and the circuit
     breaker test freezing catalog-service some other way than `podman pause`;
   - observability on Kubernetes (the book installs Grafana's stack with Helm);
   - the staging and production overlays in `polar-deployment/kubernetes/applications/`, which
     pull ghcr images and need secrets; rendering them with `kubectl kustomize` and validating with
     `kubectl apply --dry-run=server` would be cheap;
   - graceful shutdown through the `preStop` hook, with a `kubectl rollout restart` during traffic;
   - the Knative services of quote-service and quote-function, which need more memory than this
     machine has.
7. **Native images.** Both quote services are meant to ship as native images but are tested as JVM
   images. Native compilation doesn't fit in this machine's memory, so it belongs in CI or on a
   bigger machine.

4 is small and checks something the design depends on. 7 and most of 6 need more resources
than this machine has.
