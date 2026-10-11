---
name: smoke-test
description: Start PolarBookshop services (catalog, order, dispatcher, config, edge with polar-ui, quote, quote-function) with Podman and run HTTP smoke tests covering health, auth/role checks, book CRUD, order placement, order-accepted/order-dispatched messaging, config serving and catalog-service reading its configuration from config-service, and the edge gateway's OAuth2 login, token relay, CSRF and circuit breaker, the quote endpoints of quote-service and quote-function's Spring Cloud Function endpoints, actuator metrics, and (with observability) Prometheus scraping, Tempo traces across services and Grafana provisioning. Use when asked to smoke test, run, or verify any of those services end to end.
---

# PolarBookshop smoke test (Podman)

This server has Podman 4.9 and podman-compose, and no Docker. The script `smoke-test.sh` in this
skill directory does the whole job. Run it from the worktree root:

```bash
bash .claude/skills/smoke-test/smoke-test.sh all              # up + test catalog, order, dispatcher, config
bash .claude/skills/smoke-test/smoke-test.sh all edge         # edge-service (+ catalog, order, polar-ui)
bash .claude/skills/smoke-test/smoke-test.sh all catalog      # catalog-service only (postgres + keycloak)
bash .claude/skills/smoke-test/smoke-test.sh all dispatcher   # dispatcher-service only (rabbitmq)
bash .claude/skills/smoke-test/smoke-test.sh all config       # config-service only (no backing services)
bash .claude/skills/smoke-test/smoke-test.sh all quote        # quote-service only (no backing services)
bash .claude/skills/smoke-test/smoke-test.sh all quote-function  # quote-function only (no backing services)
bash .claude/skills/smoke-test/smoke-test.sh all order dispatcher observability  # + Prometheus, Tempo, Grafana
bash .claude/skills/smoke-test/smoke-test.sh all --rebuild    # rebuild the selected images from this worktree's code first
bash .claude/skills/smoke-test/smoke-test.sh test             # rerun the tests against a running stack
bash .claude/skills/smoke-test/smoke-test.sh down             # remove all the containers
```

Services default to `catalog order dispatcher config`, and any combination can be given. `edge` is
not in the default because everything together doesn't fit in memory. Dependencies are added
automatically:
- `order` adds `catalog`, because order-service looks books up in catalog-service;
- `edge` adds `catalog`, `order` and the prebuilt `polar-ui` image, because the gateway routes to
  them.

With both `catalog` and `config` selected, as in the default, catalog-service reads its
configuration from config-service. Without `config`, it uses its own `application.yml`.

`observability` adds Prometheus, Tempo and Grafana and switches on trace export. It goes on top of
the given services, or the default ones if none are given, but the default set plus observability
doesn't fit in memory. `order dispatcher observability` covers the whole order flow, and
`edge observability` the gateway.

`test` and `all` use the same selection, so run `test edge` against a stack started with
`all edge`.

Pass `--rebuild` when the user wants to test the current code in the worktree. Without it, the
script reuses existing images, which may have been built from another worktree or an older commit.

## Steps

1. **Check memory first.** The machine has ~4 GB RAM and no swap. Run `free -h` and make sure no
   Gradle daemons or other containers are holding memory.
   - The default stack needs about 2.7 GiB available and leaves only ~0.5 GiB free.
   - `edge` needs about 2.5 GiB and leaves ~0.7 GiB free.
   - Catalog alone needs about 1.5 GiB, dispatcher or config alone about 0.6 GiB, and quote or
     quote-function about 0.55 GiB each (they use only ~110-130 MB once running).
   - `observability` adds about 0.3 GiB. `order dispatcher observability` leaves ~0.35 GiB free
     and `edge observability` ~0.4 GiB.
   - An image build needs more.

   The script removes the selected app containers before building. Its estimate doesn't account
   for backing services that are already running, so its warning can be overcautious on a rerun.
2. Run `smoke-test.sh all` (add a selection and/or `--rebuild` if needed) with a Bash timeout of
   about 10 minutes. The first build of each service pulls its Paketo builder.
3. Report the PASS/FAIL lines to the user. The script exits non-zero if any check fails. On a
   failure, look at `podman logs <service>` before reporting.
4. Ask the user whether to keep the stack running or run `smoke-test.sh down`.

## What the script does (and why)

- Starts `podman.socket` and builds missing images with `bootBuildImage`. It points Gradle at the
  Podman socket with `bindHostToBuilder = true` through a temporary init script, so `build.gradle`
  is not changed.
- Runs each build on a JDK installed with sdkman (`~/.sdkman/candidates/java`): 21 by default and
  17 for quote-service and quote-function. Both use Spring Native 0.12, whose AOT step can't read Java 21
  class files. This is an interim setup until all projects move to the same JDK and builds use a
  preset `JAVA_HOME`. If a JDK is missing, install it with `sdk install java <version>`.
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

  Keycloak marks its login-session cookies `Secure`, and curl won't store those when they come
  over plain HTTP from a host other than localhost. The script therefore copies them from the
  login page's `Set-Cookie` headers into the POST by hand. Requests that change state send the
  `XSRF-TOKEN` cookie back as `X-XSRF-TOKEN`.
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
6. **Kubernetes and Knative manifests** (`polar-deployment/kubernetes/`, `quote-function/knative/`).
   Nothing checks these. Running them needs a local cluster such as kind or minikube, which
   probably won't fit in 4 GB next to the apps. A realistic option is a static check
   (`kubectl kustomize` plus kubeconform) rather than deploying.
7. **Native images.** Both quote services are meant to ship as native images but are tested as JVM
   images. Native compilation doesn't fit in this machine's memory, so it belongs in CI or on a
   bigger machine.

4 is small and checks something the design depends on. 6 and 7 need more resources than this
machine has.
