# Open findings and future work

The open findings, deferred checks and future work for PolarBookshop in this repository. How the
development setup works, and why, is in `development/README.md`.

The findings come from the review of 2026-10-19, whose numbers are kept, from the CI build and
polar-ui testing plans, and from the smoke tests (`PolarBookshop/findings.md` until 2026-10-29).
Fixed findings are left out. They are in git history, with how each was verified and its CI runs:
`git show 6a9cd2a:development/plan/review-2026-10-19.md`, and `PolarBookshop/findings.md` at the
same commit. Code comments that cite a fixed finding, such as "review finding 37", point there.

Paths are relative to `PolarBookshop/` unless they start with `development/` or `.github/`.

## The dependency update

All components are to be updated, Spring Boot and the JDK above all, in a plan of its own. The
findings that make its safety net reliable were fixed first. What the review left for the
update, and for after it:

**The order is partly forced.** Spring Boot 3 first, then the JDK:
- quote-service and quote-function can't go past JDK 17 while they use Spring Native 0.12, whose
  AOT step can't read Java 21 class files;
- order-service's tests break on JDK 21 under Boot 2.7 (22).

**Risks to guard:**
- Spring Security 6, with Boot 3, masks CSRF tokens by default, which breaks SPAs that send the
  raw XSRF-TOKEN cookie value, as polar-ui does through Angular's interceptor. The browser tests
  cover the writes and the logout form.
- Flyway 8 warns that PostgreSQL 17 is newer than it has been tested with. A newer Flyway comes
  with Boot 3.
- Keycloak 26 on Kubernetes has little room under its 750Mi limit: 525 MiB of its own memory
  after a smoke run, plus about 200 MiB of page cache.

**As part of the update:** 14, 22, 25, 29, 12 (with Tempo and Loki), 20 (the native job, after
Spring Native 0.12 is replaced by Boot 3's native support), 17.

**After the update:**
- 24, 38: the update changes the Spring Cloud Function web layer and the gateway.
- 3's outbox, 26: they touch the R2DBC and Stream APIs that change.
- 23, 27, 31: application code that doesn't depend on versions.
- 39, 40: polar-ui's code, in the fork.
- 9, 28, 30.
- 33, 42: a task of their own. Until the overlays use this repository's `k8s/` directories, the
  update doesn't reach staging and production.

**polar-ui's Angular and Node update** (Angular 13 and Node 16, both out of support) is part of
it, one major version at a time, verified by the fork's tests and the browser tests here:
- Playwright then joins the fork's root `package.json`, with `ng e2e`
  (`playwright-ng-schematics`), and `angular-eslint` replaces the dropped tslint.
- Vitest replaces Karma from Angular 21. The specs (TestBed, `HttpTestingController`) carry over.
- The fork's first scans (2026-10-28):
  - **Angular 13.2.6: 23 advisories** (13 high). Most concern SSR, hydration and
    `HttpTransferCache`, which the app doesn't use; the rest need features `src/` doesn't use. The
    update fixes them.
  - **nginx 1.31.6 in the image: 3 critical, 1 high, 1 medium,** none applying to the fork's
    `nginx/nginx.conf`. The nginx buildpack v1.3.4 has 1.31.7, but no `builder-jammy-base`
    release includes it yet; the fork pins `0.4.673`. Raise the pin once one does.
  - **Ubuntu 22.04 packages: 132 alerts,** none critical or high, none with a fix yet.
  - **About 620 in build tools,** scanned on purpose: Go 1.17 in esbuild's binaries and the
    Node.js 16.14.0 that Gradle downloads. The update clears them.

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

### 9. compose: order-service can't resolve `host.docker.internal` on Docker Engine

order-service's JWT issuer is at `host.docker.internal`, but unlike catalog-service and
edge-service it has no `extra_hosts` entry in `polar-deployment/docker/docker-compose.yml`. Podman
adds the name by itself, so neither local runs nor CI show it. **Fix:**
`extra_hosts: ["host.docker.internal:host-gateway"]`.

### 12. `tempo.yml` is Grafana's demo config, and Tempo and Loki report usage

`polar-deployment/docker/observability/tempo/tempo.yml` points at a memcached that compose doesn't
define (a DNS error every minute), turns on cost attribution, demo retention and the local-blocks
processor, and dropped `usage_report.reporting_enabled: false`, so every CI run reports usage to
Grafana Labs. Loki gets no config, and its `analytics` module is on. **Fix:** trim `tempo.yml`,
restore the opt-out, start Loki with `-reporting.enabled=false`, and bind the OTLP receivers to
`0.0.0.0:4317` and `0.0.0.0:4318` (needed since Tempo 2.7). The opt-outs can go in before the
update.

### 14. Testcontainers is too old for `ubuntu-26.04` runners

`ubuntu-latest` moves to `ubuntu-26.04` (Docker 29, minimum API 1.44) in November 2026, where
Testcontainers before 1.21.4 fails with "client version 1.32 is too old". catalog pins 1.21.3,
order and edge 1.19.8. **Fix:** remove the pins and let Spring Boot manage the version, or 1.21.4
(which works with the local Podman 4.9) before moving runners. The per-service workflows under
`*/.github/workflows`, which don't run here, use `ubuntu-22.04`, unsupported from 2027-04-17.

### 17. The `build` job uses deprecated action versions

`actions/checkout@v4` and `actions/setup-java@v4` in the `build` job (and the native job); the
other jobs use v5. Every run warns that Node.js 20 is deprecated.

### 20. Other CI cleanup

- The build jobs grant `security-events: write`, which nothing uses.
- The disabled `native-build` job calls a `nativeBuild` task that doesn't exist, and targets the
  book's Chapter16 copies.
- All build jobs share one Gradle cache key, so probably only one project's dependencies are
  cached.
- The smoke tests build quote-service and quote-function as JVM images even in CI, so their
  native images are never tested. A runner has the memory for a native build.

### 22. `OrderServiceTests` breaks on JDK 21

It passes `null` for `StreamBridge`, which Boot 2.7's Byte Buddy 1.12.23 can't mock on JDK 21.
**Fix:** `ext['byte-buddy.version'] = '1.17.7'` if order-service moves to JDK 21 before Boot 3.
Goes away with Boot 3.

### 23. Unknown order ids in order-dispatched events are dropped silently

`OrderService` ignores an id it doesn't know, and `OrderServiceTests` locks in the silence.
**Fix:** log a warning, and change the test.

### 24. quote-function logs client errors as server errors

Every 400 (an unknown or missing genre) logs ERROR "Failed to invoke function" with a stack trace.
`FunctionInputExceptionHandler` is global, so any `ConversionFailedException` in a cause chain
becomes 400. A genre without quotes would give 500 (`nextInt(0)`), but none exists. **Fix:** scope
the handler to `FunctionController`, and log client errors below ERROR.

### 25. catalog-service build hygiene

`sourceCompatibility` goes through `JavaPluginConvention`, which Gradle 9 removes;
`SecurityConfig` uses the deprecated `jwt()` (through `OAuth2ResourceServerConfigurer::jwt`); the
unused `ext.springBootVersion = "3.5.5"` disagrees with the plugin's 3.5.6; `-parameters` is
redundant. **Fix:** a Java toolchain, `oauth2.jwt(Customizer.withDefaults())`, and remove the rest.
(The builder is pinned since b7e0d4f.)

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
storage is off; the native-histograms flag is experimental. **Fix:** exemplar storage if exemplars
are wanted, and Loki checks in the observability smoke test.

### 29. The smoke test hard-codes JDK versions

The default JDKs are exact sdkman versions, though `SMOKE_JDK_17` and `SMOKE_JDK_21` override
them. **Fix:** a preset `JAVA_HOME` once every project is on one JDK.

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
- catalog-service's `patch-tracing.yml` isn't listed in its overlay's `kustomization.yml`.

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
- a browser test for the edit page. The fork's e2e test of the page with a failing
  `GET /books/{isbn}` is a `test.fail` until 39.

### 39. polar-ui shows no HTTP errors

No `subscribe` in polar-ui has an error callback, so a failed call only reaches the browser
console. A failing `GET /books` or `GET /orders` shows an empty list, a failing
`GET /books/{isbn}` a spinner for good; a failed DELETE, PUT, POST or `POST /orders` leaves the
page as it was. **Fix,** in the fork: an error callback with a message for each call (for example
a `MatSnackBar`, and on the edit page in place of the spinner), e2e tests for the failing writes,
and remove the edit page test's `test.fail`. Its message has to match
`/can't be loaded|cannot be loaded|try again/i`, or the test changes. Then a release and a tag
bump here.

### 40. polar-ui's "My Orders" formats totals with `toPrecision(4)`

$9.90 shows as `$9.900`, $1234.50 as `$1235`, and from $10,000 up in exponential notation. The
fork's e2e tests pin it. **Fix:** Angular's `currency` pipe, and change those tests.

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

## Deferred checks

Checks that couldn't run on the development server (about 4 GB RAM, shared with other sessions)
or need a push. Run heavy ones one at a time, after `free -h`.

| Check | For | What it needs |
|---|---|---|
| order-service on Docker Engine without `extra_hosts` | 9 | A CI runner or another Docker Engine host: order-service with the compose env but without `--add-host`, then `GET /orders` with a token |
| Exemplars, native histograms, and the apps' logs in Loki | 28 | The full observability stack (about 2.65 GiB), or CI |
| Testcontainers 1.21.4 on an `ubuntu-26.04` runner | 14 | A CI run on `ubuntu-26.04` |
| order-service's book lookups after a broker outage | 3 | `smoke-test.sh up order`, then stop and start `polar-rabbitmq` a few times with orders in between. Seen once (REJECTED orders until order-service restarted), before the bridge MAC fix (34); a recurrence would have another cause |
| A rolling restart under load with the sleep preStop hook | 4 | MicroK8s: `kubectl rollout restart` of catalog-service under 20 requests/s fails no requests and gives no FailedPreStopHook events |
| Runs on the default branch aren't cancelled | 18 | Two pushes to `mikkosuonio/development`, the default branch, in quick succession: both runs finish |
| Smoke tests from two worktrees at once | 10 | `smoke-test.sh all config` in two worktrees at about the same time. The second waits, takes the stack over and rebuilds config-service's image, and the first's `test config` then refuses the stack |
| Native images of quote-service and quote-function, `FunctionInputExceptionHandler` among them | 20, 24 | More memory than the development server has; a CI runner may do. `./gradlew bootBuildImage` without the smoke test's JVM override, then the POETRY request |

## Future work

### CI

- config-service's `contextLoads` test and the smoke tests clone
  `https://github.com/PolarBookshop/config-repo`, a repository outside this one that can change,
  over the network.
- **The whole system in one smoke job,** as a fifth matrix entry: never run, even locally, but
  it would test edge-service with observability.
- **A separate smoke workflow** (`workflow_run`, downloading the images from the triggering run),
  if the smoke tests make every push too slow. A run now takes about 6–9 minutes. `workflow_run`
  always uses the default branch's workflow file.
- **`ubuntu-26.04` runners,** once generally available or when the development server moves to
  26.04. Their newer Podman would differ from the local runs (and 14 first).
- Coverage thresholds with `jacocoTestCoverageVerification`.
- Vulnerability scanning of this repository's code and images (the book uses grype; the fork has
  Anchore's scans back).
- Publishing the images to GHCR, and the book's acceptance and production stages.
- Path filters, so that a push changing one service doesn't rebuild and test all of them.

### Kubernetes

- **edge-service and polar-ui on Kubernetes** (`--k8s`), and observability, and quote-service and
  quote-function on Knative (future work 6 in the smoke-test skill). The browser tests take
  `UI_BASE_URL`, so they can run against the cluster too.
  - The Kubernetes development realm has `sslRequired: external` with the issuer host
    `polar-keycloak`, so a browser very likely can't log in there, as with compose before finding
    35. Check it then.
- The staging and production overlays (33, 42).

### polar-ui and the browser tests

- A small issue seen in polar-ui's code, not recorded as a finding: the spinner never shows while
  loading, since `books` starts as `[]`.
- The anonymous `GET /user` 401 logs an Angular `ERROR` to the console, since `AppComponent`
  subscribes without an error handler. Both test suites allow it; 39's fix can remove it.
- The fork's `e2e/tests/polar.ts` copies the `problems` fixture, `failedCall` and the card and menu
  helpers from `development/ui-test/tests/polar.ts`. The copies can drift apart.
- `npx playwright test` by hand in `development/ui-test/` runs without the smoke script's lock.
- Visual or accessibility checks (Playwright screenshots, axe-core), maybe with the Angular update,
  whose Material changes alter the look.
