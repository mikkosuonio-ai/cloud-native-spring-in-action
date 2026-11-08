# Open findings and future work

The open findings, deferred checks and future work for PolarBookshop in this repository. How the
development setup works, and why, is in `development/README.md`.

The findings come from the review of 2026-10-19, whose numbers are kept, from the CI build and
polar-ui testing plans, from the smoke tests (`PolarBookshop/findings.md` until 2026-10-29), and
from the review of 2026-11-04 (43-53; its plan, with each step's commit and CI run, is
`git show d82740e:development/plan/review-2026-11-04.md`).
Fixed findings are left out. They are in git history, with how each was verified and its CI runs:
`git show 6a9cd2a:development/plan/review-2026-10-19.md`, and `PolarBookshop/findings.md` at the
same commit. Code comments that cite a fixed finding, such as "review finding 37", point there.

Paths are relative to `PolarBookshop/` unless they start with `development/` or `.github/`.

## The dependency update

Done on 2026-11-07/08 as `development/plan/dependency-update.md` describes: every service on
Spring Boot 4.1, Spring Cloud 2025.1 and JDK 25, the images and CI on supported releases. 12, 17,
14, 20, 22, 25 and 29 were fixed with it; 54 came up in it. The plan's progress table has the commit,
CI run and checks of each step; it stays until what's left below is done.

**Left from it:**
- **MicroK8s 1.36 on the development server** (`sudo snap refresh microk8s --channel=1.36/stable`;
  CI runs 1.36), and deferred check 4 again on it.
- **JDK 25 warns that Netty calls a restricted method** (`System::loadLibrary`), which a future
  JDK blocks unless native access is enabled (`--enable-native-access=ALL-UNNAMED`).
- **Gradle 9.9** (released 2026-11-06) and **Spring Boot 4.2 with Spring Cloud 2026.0** (planned
  for 2026-11-30); PostgreSQL 18, Redis 8, Tempo 3; `@ServiceConnection` in place of
  `@DynamicPropertySource`.

**After the update,** as planned:
- 24, 38: on the new Spring Cloud Function web layer and gateway.
- 3's outbox, 26: on the new R2DBC and Stream APIs.
- 23, 27, 31: application code that doesn't depend on versions.
- 9, 28, 30, 50, 52.
- 33, 42, 43: a task of their own. Until the overlays use this repository's `k8s/` directories,
  the update doesn't reach staging and production.

**polar-ui's Angular and Node update is finished.** It went first, in the fork, one major
version at a time: releases v1.3.0 to v2.1.1 (2026-10-29 and 30) took it from Angular 13 and
Node.js 16 to Angular 22 and Node.js 24, and fixed 39, 40 and 41. Each was a tag bump here,
verified by the browser tests. Its plan is in the fork's history
(`git show fbf8cec:plan/angular-update.md`), and what it left is in the fork's
`plan/future-work.md`. The backend update runs against v2.1.1, which needs from edge-service:
- the raw `XSRF-TOKEN` cookie value accepted as `X-XSRF-TOKEN` on writes, and as `_csrf` in the
  logout form, a plain HTML form POST. Spring Security 6 expects masked tokens by default, so
  edge-service's `SecurityConfig` sets a handler that accepts both raw;
- `GET /user` answering 401 for an anonymous visitor, which v2.1.1 handles quietly;
- the `[]` catalog fallback for `GET /books`, without which its book list spins for good;
- `/`, `/*.css`, `/*.js`, `/favicon.ico` and `/media/**` permitted and routed to polar-ui (50).

Production's polar-ui stays on upstream's v1 with upstream's edge-service (33, 43), so the update
doesn't reach it.

## Open findings

### 3. A broker outage leaves orders without their event (interim fix)

- **Problem:** with RabbitMQ down, `POST /orders` answered 500 after the 5 s connection timeout,
  but the order was saved as ACCEPTED and its order-accepted event never sent, so it was never
  dispatched. A client's retry added a second ACCEPTED order. `submitOrder` commits the order
  before it sends the event, so that an order-dispatched event can't arrive before the order is
  visible, and nothing sends a failed event again.
- **Interim fix:** an order whose event can't be sent is saved as FAILED and returned so, with
  200, as a REJECTED order is. It isn't left ACCEPTED, and a retry is a new order. The trade-off
  is described in `OrderService`.
- **Left open:** the event still isn't sent later. **Fix:** a transactional outbox, after the
  update. The send also still blocks the R2DBC thread until the connection timeout (26).
- **Seen in deferred check 3** (dependency update, steps 4a and 4b, and with RabbitMQ 4.4): after
  one of three RabbitMQ restarts (the first, or with 4.4 the third), order-service's sends failed
  for about 20 s more, though RabbitMQ was up ("Connect timed out", "UnknownHost"); after the
  others they worked at once. Podman gives the restarted container a new IP each time, so
  probably the JVM's DNS cache. Orders were FAILED, never
  REJECTED, and order-service recovered by itself. Not compared with the version before the
  update.

### 9. compose: order-service can't resolve `host.docker.internal` on Docker Engine

order-service's JWT issuer is at `host.docker.internal`, but unlike catalog-service and
edge-service it has no `extra_hosts` entry in `polar-deployment/docker/docker-compose.yml`. Podman
adds the name by itself, so neither local runs nor CI show it. **Fix:**
`extra_hosts: ["host.docker.internal:host-gateway"]`.

### 23. Unknown order ids in order-dispatched events are dropped silently

`OrderService` ignores an id it doesn't know, and `OrderServiceTests` locks in the silence.
**Fix:** log a warning, and change the test.

### 54. Spring Cloud Function fails a reactive function composed with a plain Consumer

From Spring Cloud Function 4.3 on (still in 5.0.5), composing a function with a `Mono` output and
a non-reactive `Consumer` (`/genreQuote,logQuote`) fails with a ClassCastException: the framework
wraps the consumer (its GH-1141 code) in a `Consumer<Flux>` and passes it the `Mono`. The request
got 500; 3.2 composed them. Since the dependency update (step 7a) `logQuote` is a
`Consumer<Mono<Quote>>`, which the framework doesn't wrap, and
`QuoteFunctionApplicationTests` checks that the composed call logs the quote. Also seen: a
composed call whose body isn't valid JSON (`FANTASY` without quotes) now answers 202 and only logs
the conversion failure; 3.2 accepted it. **Left:** reporting it upstream (not done, an outward
action for the user to decide), and a plain `Consumer` again once fixed.

### 24. quote-function logs client errors as server errors

Every 400 (an unknown or missing genre) logs ERROR "Failed to invoke function" with a stack trace.
`FunctionInputExceptionHandler` is global, so any `ConversionFailedException` in a cause chain
becomes 400. A genre without quotes would give 500 (`nextInt(0)`), but none exists. **Fix:** scope
the handler to `FunctionController`, and log client errors below ERROR.

### 26. order-service messaging gaps

- Order-accepted events sent before dispatcher-service has ever created its queue go nowhere, since
  there's no `required-groups`.
- The blocking Rabbit send runs on the R2DBC I/O thread (3). Move it to
  `Schedulers.boundedElastic()`.
- No dead-letter queue for order-dispatched messages (2's fix tries a message three times and drops
  it). Binding one changes the queue's arguments, which RabbitMQ refuses on an existing queue.

### 27. `RateLimiterConfigTests`' test name is misleading

"KeyIsUsername" isn't true in production: the key is the OIDC `sub`, since no
`user-name-attribute` is set. **Fix:** rename the test, or set the attribute.

### 28. Observability gaps

Under Podman the apps' logs can't reach fluent-bit (Podman 4.9 has no `fluentd` log driver); the
smoke test checks neither Loki nor fluent-bit; exemplars are dropped because Prometheus' exemplar
storage is off (the `exemplar-storage` feature flag); some dashboard panels have no data in this
setup: Jetty's, the Tomcat thread panels (Tomcat's MBean registry is off), `process_memory_*` and
`process_threads` (from a library the services don't use), and Resilience4j's retries
(edge-service retries with the gateway's Retry filter). **Fix:** exemplar storage if exemplars are
wanted, Loki checks in the observability smoke test, and dashboards without the dead panels.

### 30. The README doesn't say to clean up after Testcontainers without Ryuk

Its Podman section disables Ryuk, which normally removes the test containers. **Fix:** a note on
removing them by hand.

### 31. `PUT /books/{isbn}` for a missing book uses the body's ISBN

The book is created with the body's ISBN, not the path's; untested. polar-ui's edit form lets the
ISBN change, which leads here. **Fix:** use the path's ISBN, or reject a mismatch, with a test.

### 33. Kustomize overlays use a deprecated field and upstream bases

Every staging and production overlay in `polar-deployment/kubernetes/applications/` uses
`patchesStrategicMerge`, and their bases are the book's upstream repositories
(`github.com/polarbookshop/<service>/k8s?ref=main`). So fixes to this repository's `k8s/` (such as
4's preStop hooks and 13's probe timeouts) don't reach them, and CI can't validate them. **Fix:**
`kustomize edit fix`, and point the bases at this repository's `k8s/`. Then also:
- the production `patch-tracing.yml` files still name
  `BOOT-INF/lib/opentelemetry-javaagent-<version>.jar`, as upstream's images have it; since 7 the
  agent is `/workspace/opentelemetry-javaagent.jar`;
- catalog-service's `patch-tracing.yml` isn't listed in its overlay's `kustomization.yml`;
- the per-service workflows under `*/.github/workflows`, which don't run here, use `ubuntu-22.04`,
  unsupported from 2027-04-17.
- production's polar-ui (`kubernetes/platform/production/polar-ui/resources/polar-ui.yml`) stays
  on upstream's `ghcr.io/polarbookshop/polar-ui:v1` until then (43): the fork's v2 needs
  this repository's edge-service, for `/media/**` and the `[]` catalog fallback, and production's
  edge-service is upstream's `latest`. Both move in the same change.

### 36. order-service answers the first orders after a PostgreSQL restart with 500

After a PostgreSQL restart, its R2DBC pool hands out the dead idle connections ("Connection
validation failed"): one failed request for each idle connection (`initial-size: 5`).
catalog-service, on Hikari, recovers without failures. **Fix:** r2dbc-pool's `acquireRetry`,
`maxIdleTime` and `backgroundEvictionInterval`, and a test that restarts the database container.

### 38. edge-service's catalog fallback answers every other request as a list read

The catalog route's circuit breaker sends every request under `/books/**` to
`forward:/catalog-fallback`, but `WebEndpoints` answers only GET (200 with `[]`) and POST (503).
With catalog-service down, `GET /books/{isbn}` gets 200 with `[]`, and polar-ui's edit page shows
an empty form; `PUT` and `DELETE` probably get 404. Found by reading the code, not tested.
**Fix:**
- split the route: `GET /books` keeps the `[]` fallback, the rest of `/books/**` falls back to an
  endpoint answering 503 for every method, covered in `WebEndpointsTests`;
- check `GET /books/{isbn}`, `PUT` and `DELETE` in the smoke test's catalog pause;
- a browser test for the edit page: with the 503, polar-ui (since v2.1.0) shows "The book can't
  be loaded. Please try again later." in place of the form.

### 42. Production's Keycloak can't be deployed, and deploys differently from development

- `kubernetes/platform/production/keycloak/deploy.sh` installs Bitnami's Helm chart 21.4.1 with
  image 24.0.5. Broadcom stopped Bitnami's free images in 2025: `docker.io/bitnami/keycloak` has
  no tags left, and 24.0.5 is only in `docker.io/bitnamilegacy`, without updates (checked
  2026-10-29). So `deploy.sh` would fail to pull it (deduced, not run). By default the chart also
  deploys its own Bitnami PostgreSQL; not checked.
- Development (plain manifests) and compose run the official `quay.io/keycloak` 26.8.1 with
  `start-dev`, so production differs in image, packaging and version.
- The realm is in three copies: compose's `docker/keycloak/`, and development's and production's
  `keycloak-config.yml`. Compose and production set `sslRequired: none`, development `external`
  (see "edge-service and polar-ui on Kubernetes" below).
- **Production has no TLS (44).** Its realm has `sslRequired: none`, and `values.yml` sets
  `KC_HTTP_ENABLED=true` and `KC_HOSTNAME_STRICT_HTTPS=false` behind a plain HTTP LoadBalancer on
  port 80; edge-service's ingress has no `tls` section. Passwords, session cookies and tokens
  cross the internet unencrypted. `external` alone would lock everyone out of the login page,
  since no request reaches Keycloak over HTTPS. Comments in the three files point here.

**Fix,** to be decided: one way to deploy Keycloak in development and production, with the
official image.
- **Kustomize, with the development manifests as the base** (recommended). Production's overlay
  switches to `start` with a database, and adds the hostname, the secrets, its resources and the
  LoadBalancer. No new tool, CI tests the base, and CI could build the production overlay with
  kubeconform.
- **The Keycloak Operator** (`Keycloak` and `KeycloakRealmImport` resources), as production uses
  an operator for RabbitMQ. One more pod on the 4 GB development server, a database for Keycloak
  in development too, and the smoke script and CI have to install it.
- **One Helm chart everywhere,** such as codecentric's `keycloakx`. Adds Helm to the smoke script
  and CI just for Keycloak.
- With any of them, one copy of the realm for Kubernetes, and compose's generated from it or
  checked against it.
- With any of them, TLS for Keycloak and edge-service in production (44): certificates at the
  ingress, for example from cert-manager with Let's Encrypt, Keycloak behind the ingress instead of
  its own LoadBalancer, and then the realm's `sslRequired: external` and Keycloak's proxy
  settings (`KC_PROXY_HEADERS=xforwarded`, the public `KC_HOSTNAME`) in place of the HTTP-only
  flags. Only compose keeps `none` (35).

### 50. edge-service routes only listed SPA paths

spa-route (`edge-service/src/main/resources/application.yml`) and `SecurityConfig` list `/`,
`/*.css`, `/*.js`, `/favicon.ico` and `/media/**`. A polar-ui release that adds files elsewhere,
such as under `assets/` or from Angular's `public/` directory, gets 401 for them. The browser
tests would catch it, since they fail on any response of 400 or more. **Fix,** when it comes up:
add the path to both lists, or route every path that isn't an API's to polar-ui. From the review
of 2026-11-04.

### 52. The browser tests time out under memory pressure

`8afafad` records local `all ui` runs passing 99 and 98 of 100 checks, a different test timing
out each time, while the machine stalled with three Claude sessions besides the stack. CI passed.
**Next time:** keep the traces of the timed-out tests (`logs DIR`) and record the memory pressure
(`/proc/pressure/memory`) during the run, to see whether the same steps time out.

## Deferred checks

Checks that couldn't run on the development server (about 4 GB RAM, shared with other sessions)
or need a push. Run heavy ones one at a time, after `free -h`.

| Check | For | What it needs |
|---|---|---|
| order-service on Docker Engine without `extra_hosts` | 9 | A CI runner or another Docker Engine host: order-service with the compose env but without `--add-host`, then `GET /orders` with a token |
| Exemplars, native histograms, and the apps' logs in Loki | 28 | The full observability stack (about 2.65 GiB), or CI |
| order-service's book lookups after a broker outage | 3 | `smoke-test.sh up order`, then stop and start `polar-rabbitmq` a few times with orders in between. Seen once (REJECTED orders until order-service restarted), before the bridge MAC fix (34); a recurrence would have another cause |
| Runs on the default branch aren't cancelled | 18 | Two pushes to `mikkosuonio/development`, the default branch, in quick succession: both runs finish |
| Smoke tests from two worktrees at once | 10 | `smoke-test.sh all config` in two worktrees at about the same time. The second waits, takes the stack over and rebuilds config-service's image, and the first's `test config` then refuses the stack |

## Future work

### CI

- config-service's `contextLoads` test and the smoke tests clone
  `https://github.com/PolarBookshop/config-repo`, a repository outside this one that can change,
  over the network.
- **The whole system in one smoke job,** as a fifth matrix entry: never run, even locally, but
  it would test edge-service with observability.
- **A separate smoke workflow** (`workflow_run`, downloading the images from the triggering run),
  if the smoke tests make every push too slow. A run now takes about 15 minutes, the native jobs
  being the longest. `workflow_run` always uses the default branch's workflow file.
- **`ubuntu-26.04` runners,** once the development server moves to 26.04: their newer Podman
  would differ from the local runs. The build jobs passed on them (deferred check 14, in the
  dependency update).
- Coverage thresholds with `jacocoTestCoverageVerification`.
- Vulnerability scanning of this repository's code and images (the book uses grype; the fork has
  Anchore's scans back).
- Publishing the images to GHCR, and the book's acceptance and production stages.
- Path filters, so that a push changing one service doesn't rebuild and test all of them.

### Kubernetes

- **edge-service and polar-ui on Kubernetes** (`--k8s`), and observability, and quote-service and
  quote-function on Knative (future work 6 in the smoke-test skill). The browser tests take
  `UI_BASE_URL`, but the rest of `development/ui-test/tests/polar.ts` assumes the Podman stack
  (47): the cleanup and the closed database run `podman exec polar-postgres psql`, the outage
  tests `podman pause catalog-service`, the undo file holds podman arguments, and Keycloak is
  `host.docker.internal:8080`, mapped to 127.0.0.1. On the cluster these need a helper that runs
  the same operations with kubectl (`exec` into PostgreSQL's pod; scaling catalog-service to 0, or
  a NetworkPolicy, in place of the pause), chosen by an environment variable the smoke script
  sets, and Keycloak's address from the environment too.
  - The Kubernetes development realm has `sslRequired: external` with the issuer host
    `polar-keycloak`, so a browser very likely can't log in there, as with compose before finding
    35. Check it then.
- The staging and production overlays (33, 42).

### polar-ui and the browser tests

- The fork's `e2e/tests/polar.ts` copies the `problems` fixture, `failedCall` and the card and menu
  helpers from `development/ui-test/tests/polar.ts`. The copies can drift apart.
- `npx playwright test` by hand in `development/ui-test/` runs without the smoke script's lock.
- Visual or accessibility checks (Playwright screenshots, axe-core). The fork's e2e tests fail on
  serious axe-core findings since v2.0.1; the full-stack tests here have neither.
