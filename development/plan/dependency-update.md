# Plan: PolarBookshop's dependency update

## Context

Six of the seven services run Spring Boot 2.7 (2.7.18, or 2.7.15 for the quote services) with
Spring Cloud 2021.0.9, JDK 17 and Gradle 8.8. Free support for Boot 2.7 ended in 2023. catalog-service
runs Boot 3.5.6, whose free support ended on 2026-06-30. quote-service and quote-function still
use the archived Spring Native 0.12. Several images and tools are also out of support: RabbitMQ
3.13, Prometheus 3.5 and the Node 20 GitHub Actions.

Two reviews (2026-10-19, 2026-11-04) fixed the findings that make the safety net reliable, so the
update can now rest on it:
- the Gradle tests with JaCoCo;
- the smoke tests on Podman and MicroK8s;
- the browser tests;
- CI on every push.

polar-ui's Angular update, which this plan used to interleave with, is finished: the fork's
v2.1.1 (Angular 22, Node.js 24) is pinned here since 8afafad. The backend update therefore runs
against one fixed SPA.

The plan:
- moves every service to Boot 4.1 and JDK 25 one step at a time, using catalog-service's earlier move
  as the pattern;
- brings the images, CI and platform to supported releases;
- takes in findings 12, 14, 17, 20, 22, 25 and 29.

Approved on 2026-11-07. Paths are relative to `PolarBookshop/` unless they start with
`development/` or `.github/`.

## Facts checked (2026-10-29, Spring, Node.js and Playwright again 2026-11-07)

Sources: spring.io's API (`api.spring.io/projects/*/releases` and `/generations`), endoflife.date,
GitHub releases, Maven Central POMs, Docker Hub and quay.io tags, nodejs.org's release index, npm,
the Snap Store and the vendors' support pages.

| Component | Now | Latest | Support |
|---|---|---|---|
| Spring Boot | 2.7.18/2.7.15, 3.5.6 | 3.5.16 (last free 3.5), 4.0.9, **4.1.2** | 3.5 OSS ended 2026-06-30; 4.0 to 2026-12-31; **4.1 to 2027-07-31**; 4.2 at RC2, GA 2026-11-30 |
| Spring Cloud | 2021.0.9, 2025.0.0 | 2025.0.3 (Boot 3.5), **2025.1.4** (Boot 4.0, and 4.1 from 2025.1.2) | 2025.0 OSS ended 2026-06-30; 2025.1 to 2027-07-31; 2026.0 (Boot 4.2) at RC2 |
| JDK | 17, 21 | Temurin 21.0.13, **25.0.5** | Temurin 21 to ≥ 2029-12, 25 to ≥ 2031-09. Boot 4 supports 17–27. Paketo's Liberica buildpack has 25.0.5 and defaults to 21 |
| Gradle | 8.8, 8.14.3 | 8.14.6, **9.8.2** | Boot 3.5: 7.6.4+/8.4+ (Gradle 9 not listed); Boot 4: 8.14+ or 9; Gradle 9 runs on Java 17–27 |
| Testcontainers | 1.21.4, pinned in catalog, order and edge (46) | 1.21.4 (managed by Boot 3.5.16), 2.0.5 (Boot 4.x) | 2.x renames the modules (`testcontainers-postgresql`, …) and their packages |
| testcontainers-keycloak | 3.9.0 | 4.4.0 (Keycloak 26.8, Testcontainers 2 only) | 3.9.x is the last line on Testcontainers 1 |
| Flyway | Boot 2.7's 8.x | Boot 3.5: 11.7.2; 4.1: 12.4.0 | 11.7.2 is fine with PostgreSQL 17 but warns on 18; Boot 4 needs `spring-boot-starter-flyway` |
| Native | Spring Native 0.12.2 (archived 2023) | Boot AOT and Native Build Tools | Boot 4: GraalVM 25+ |
| PostgreSQL | 17.11 | 17.11, 18.6 | 17 to 2029-11-08 |
| Keycloak | 26.8.1 | 26.8.1 | only 26.8 supported |
| Redis | 7.2 | 7.2.17, 7.4.12, 8.10.3 | 7.2 to 2029-12-01 |
| RabbitMQ | 3.13 | 4.3.7, **4.4.0** | 3.13 community support ended 2024-09-30; 4.4 to 2027-07-31 |
| Grafana | 12.1.1 | 12.4.14 (13.3.0) | 12.4 security fixes to 2027-05-24 |
| Loki, plugin | 3.5.4 | 3.7.9 | |
| Prometheus | 3.5.0 | 3.15.1; LTS 3.13.5 | 3.5 LTS ended 2026-07-31; 3.13 LTS to 2027-07-31 |
| Tempo | 2.8.2 | 2.10.10 (3.1.1) | |
| OpenTelemetry agent | 1.33.3, 2.20.1 | 2.33.1 | |
| Paketo builders | jammy-base (unpinned), jammy-tiny, noble-java-tiny 0.0.200 | noble-java-tiny 0.0.204, jammy-base 0.4.674 | |
| MicroK8s | 1.35/stable | 1.36.2 (latest/stable) | |
| GitHub Actions | checkout v4/v5, setup-java v4/v5 | checkout v7, setup-java v6, setup-node v7, upload v7, download v8 | Node 20 removed from runners 2026-09-23 |
| Browser tests' tools | Node.js 24 (`.nvmrc`), Playwright 1.63.0 | Node.js 26.13.0, 24.22.2; Playwright 1.65.0 | Node.js 26 Active LTS since 2026-10-28; 24 in maintenance to 2028-04-30 |
| polar-ui | fork v2.1.1 (compose, development); upstream v1 (production) | fork v2.1.1 | built and scanned in the fork |

Gateway 5 (Spring Cloud 2025.1):
- `spring-cloud-starter-gateway` has no 5.x release. Use `spring-cloud-starter-gateway-server-webflux`.
- The properties live under `spring.cloud.gateway.server.webflux.*`. Gateway 4.3 (2025.0) still
  maps the old names, 5.0 doesn't (from its source, not stated in the docs).
- Gateway 5 ignores `X-Forwarded-*` unless `trusted-proxies` is set.

Spring Security 7 has `csrf.spa()` for servlet apps only. WebFlux, and so edge-service, still
configures the request handler itself.

Re-check versions at the start of each step: patch releases will move on.

## Targets

- **Spring Boot 4.1.x with Spring Cloud 2025.1.x.**
  - 3.5.16 is a step on the way, not a stopping point. Boot 4's migration guide asks for the
    latest 3.5 first, and 3.5's deprecation warnings point at what Boot 4 removes.
  - 4.0 isn't worth stopping at, with under two months of support left.
  - 4.2 (GA planned 2026-11-30) and Spring Cloud 2026.0 come later, as an ordinary minor update,
    not by changing targets during this update.
- **JDK 25.**
  - Boot 4's native support needs GraalVM 25, so the quote services' native images and the JVM
    images then run the same Java.
  - Temurin supports 25 two years longer than 21.
  - JDK 21 isn't an intermediate step: the services on 17 go straight to 25, after Boot 4.
- **Gradle 9.8.x,** with a Java toolchain in every `build.gradle`.
- **Builders:** `paketobuildpacks/builder-noble-java-tiny`, pinned to a version as catalog's is,
  for every service. The quote services build native images on it.
- **Testcontainers** managed by Boot: 1.21.4 on Boot 3.5, then 2.0.x. **testcontainers-keycloak**
  stays on 3.9.0 for Boot 3.5 and moves to 4.4.x for Boot 4. **OpenTelemetry agent** at the latest
  2.x.
- **Images:**
  - RabbitMQ 4.4.x;
  - Prometheus 3.13 LTS;
  - Grafana 12.4.x, Loki and its plugin 3.7.x, Tempo 2.10.x.
  - Unchanged: PostgreSQL 17.11, Keycloak 26.8.1 and Redis 7.2, all supported until 2029, and
    Keycloak already the latest.
  - PostgreSQL 18, Redis 8 and Tempo 3 are left for later.
- **The browser tests' tools:** Node.js 26 and the latest Playwright.
- **MicroK8s 1.36,** and the GitHub Actions at their latest majors.

## polar-ui during the update

The fork's update is finished: v1.3.0 to v2.1.1 (2026-10-29 and 30), Angular 13 and Node.js 16
to Angular 22 and Node.js 24. The fork's `plan/future-work.md` lists what it may do next (Node.js
26, zoneless and signals, Material 3), none of it scheduled. So:

- **polar-ui stays at v2.1.1.** Every backend step is tested against it, and a failing browser
  test has one suspect: the backend step.
- **What v2.1.1 needs from the backend,** which each step keeps (also in `development/findings.md`):
  - edge-service accepts the raw `XSRF-TOKEN` cookie value as `X-XSRF-TOKEN` on `POST`, `PUT`
    and `DELETE` (Angular's interceptor), and as the `_csrf` field of the logout form, a plain
    HTML form POST (`app.component.html`);
  - `GET /user` answers 401 for an anonymous visitor, and 200 with `username`, `firstName`,
    `lastName` and `roles` once logged in;
  - the catalog fallback for `GET /books` is `[]`, not an empty body;
  - `/`, `/*.css`, `/*.js`, `/favicon.ico` and `/media/**` are permitted and routed to polar-ui
    (50);
  - the book and order JSON keep their field names and types, and the error statuses stay as
    v2.1.0's messages expect: 4xx and 5xx on writes, 5xx or the 503 fallback on reads.
- **The API snapshot** (step 0) checks the last two points mechanically, through edge-service, so
  that a change shows up as a diff and not only as a browser test that happens to touch it. A diff
  that remains after a step goes to the commit message, and, if it changes what the fork's
  mocked e2e tests (`e2e/`) assume, to the fork's session as information.
- **If the fork releases during the update,** its tag bump is handled as before, without asking
  the user (memory `polar-ui-session-requests`):
  - a commit of its own, between two service steps, never while a service is half moved;
  - verified with `all ui` and CI, with the backend as it is at that moment;
  - compose, development's `polar-ui.yml` and `development/README.md` only.
- **Production's polar-ui** stays on upstream's v1, with upstream's edge-service (33, 43). The
  update doesn't reach production; 33 moves both together, after it.
- **edge-service still goes second,** after catalog-service. Not for polar-ui's release schedule,
  which is no longer a factor, but because CSRF and the gateway are the changes most likely to
  break the SPA, and finding that early is cheaper than at the end.

## Step 0: before the first service

Each item is a commit of its own, verified, and pushed when the user says so.

1. **The plan:** this file, linked from `development/README.md` and from
   `development/findings.md`'s "The dependency update".
2. **17 and part of 20 in CI:**
   - every job moves to `actions/checkout@v7`, `actions/setup-java@v6`, `actions/setup-node@v7`,
     `upload-artifact@v7` and `download-artifact@v8`;
   - the unused `security-events: write` goes;
   - each build job gets its own Gradle cache key, with `cache-dependency-path` as the images job
     has it.
3. **12's opt-outs:** `usage_report.reporting_enabled: false` in `tempo.yml`, and
   `-reporting.enabled=false` for Loki. Verify with `all order dispatcher observability`.
4. **A baseline,** in the plan's progress notes, of what each step compares with:
   - each service's test count and coverage (from the CI summary);
   - the smoke runs' check counts;
   - `podman stats` memory per container after `all` and `all ui`;
   - pod memory after `all --k8s`;
   - image sizes and startup times;
   - the API snapshot.

   The snapshot comes from a new `development/script/api-snapshot.sh`. It runs against a stack
   that `smoke-test.sh all edge` started, and logs in as `test_edge` does (the smoke script's
   `edge_login`, through Keycloak's form, into a cookie jar). Through edge-service, anonymous and
   as isabelle (employee) and bjorn (customer), it records status, `Content-Type`, the
   `Set-Cookie` names and attributes, and the body of:
   - `GET /user`, `POST /logout`;
   - `GET`, `POST`, `PUT` and `DELETE` on `/books` and `/books/{isbn}`, valid and invalid;
   - `GET` and `POST /orders`;
   - the catalog fallback, with catalog-service paused.

   Dates, ids and tokens are masked, and each response goes to a file in a directory to diff.
5. **A tag, `pre-dependency-update`,** on the last commit of step 0, to compare with and to go back
   to. Pushed only when the user agrees.

## The order of the services

Boot first, then the JDK, as `development/findings.md` says. One service at a time:
1. catalog-service;
2. edge-service;
3. dispatcher-service;
4. order-service;
5. config-service;
6. quote-service;
7. quote-function.

Why this order:
- catalog-service is already on 3.5. It sets the Boot 4 pattern (modular starters,
  Testcontainers 2, testcontainers-keycloak 4, Jackson 3, Security 7) on the service that changes
  least.
- edge-service carries the changes most likely to break the SPA (see above).
- dispatcher-service sets the Spring Cloud Stream and Function pattern before order-service,
  which adds R2DBC, Flyway and security to it.
- The quote services are self-contained and come last, with the native job.

Each service passes through four steps, each a commit verified on its own, as catalog-service's
move went (Gradle wrapper, Boot, then Java 21):

- **a. Boot 3.5.16 and Spring Cloud 2025.0.3**:
  - Gradle wrapper 8.14.6 first, as its own commit: Boot 2.7's plugin works with it.
  - `javax` to `jakarta`, Spring Security 6, the property renames.
  - A Java toolchain in place of `sourceCompatibility`, needed by Gradle 9.
  - The Testcontainers pins (1.21.4) and BOM removed, so Boot manages the same version (14).
  - `@MockBean` to `@MockitoBean`, deprecated since 3.4 and gone in 4.
  - The OpenTelemetry agent at the latest 2.x.
  - `spring-boot-properties-migrator`, added at runtime for the step and removed before the
    commit, reports the renamed properties at startup in the smoke run.
- **b. Boot 4.1.x and Spring Cloud 2025.1.x:**
  - the modular starters (`spring-boot-starter-webmvc`, `-flyway`, the per-technology test
    starters);
  - Jackson 3;
  - Security 7;
  - Testcontainers 2 artifacts and packages, testcontainers-keycloak 4.4.x;
  - versions Boot no longer manages: Spring Retry, used by the config clients, and probably
    OkHttp's `mockwebserver` (check both).

  If the step gets too big, `spring-boot-starter-classic` and `-test-classic` split it: Boot 4
  on the classic starters first, then the modular ones.
- **c. Gradle 9.8.x:**
  - `junit-platform-launcher` as `testRuntimeOnly`;
  - the gradle-versions plugin's compatibility (catalog);
  - a JaCoCo version that reads Java 25 classes, for step d.
- **d. JDK 25:**
  - the toolchain;
  - `BP_JVM_VERSION`;
  - the pinned `builder-noble-java-tiny`, which has no shell, like catalog's image (the `sleep`
    preStop hooks already allow for that);
  - the smoke script's JDK for the service.

For config-service and quote-service, c and d may go in one commit if a and b went through
cleanly. A combined step that fails is split.

## Per service

**catalog-service** (Boot 3.5.6, JDK 21, Gradle 8.14.3):
- a:
  - 3.5.16 and 2025.0.3, with 25's fix: a toolchain, `oauth2.jwt(Customizer.withDefaults())`, and
    the stale `ext.springBootVersion` and the redundant `-parameters` removed;
  - Testcontainers unpinned (14).
- b:
  - `spring-boot-starter-webmvc`, `spring-boot-starter-flyway` with `flyway-database-postgresql`;
  - the test starters for `@WebMvcTest`, `@DataJdbcTest` and `@JsonTest`, whose packages move;
  - `WebTestClient` for the integration tests;
  - Testcontainers 2 and testcontainers-keycloak 4.4.x;
  - `BookJsonTests` on Jackson 3;
  - Security 7's resource server, keeping the error-dispatch permit (1).
- d: JDK 21 to 25, builder 0.0.200 to the current version.

**edge-service:**
- a:
  - **CSRF:** Security 6 resolves tokens with `XorServerCsrfTokenRequestAttributeHandler`, which
    expects masked values, and polar-ui sends the raw cookie value in both the header and the
    logout form. Set `csrf.csrfTokenRequestHandler(new ServerCsrfTokenRequestAttributeHandler())`
    in `SecurityConfig`: it resolves `_csrf` form fields and `X-XSRF-TOKEN` headers unmasked, as
    Boot 2.7 did. BREACH masking protects tokens rendered into server-side pages, and
    edge-service renders none. Keep `csrfWebFilter`, which subscribes to the token so the cookie
    is still written. Cover it in `SecurityConfigTests`: a write with the raw cookie value in
    `X-XSRF-TOKEN`, and `POST /logout` with it as a `_csrf` form field, both accepted; a wrong
    value refused with 403.
  - **Gateway:** `spring-cloud-starter-gateway-server-webflux`, and the routes, default filters
    and `httpclient` moved under `spring.cloud.gateway.server.webflux.*` already here, while
    Gateway 4.3 still maps the old names. Check `/actuator/gateway/routes` after each step:
    every route with its `SaveSession`, `TokenRelay`, `RequestRateLimiter`, `Retry` and
    `CircuitBreaker` filters, and spa-route's paths (50). A dropped filter fails no request.
  - **Properties:** `spring.redis.*` to `spring.data.redis.*` in `application.yml`,
    `edge-service/k8s/application.yml` and compose's `SPRING_REDIS_HOST`, and
    `spring.session.store-type` removed.
  - The Testcontainers Redis tag matches compose.
- b:
  - `spring.session.redis.*` to `spring.session.data.redis.*`;
  - Gateway 5's `trusted-proxies` (unset: edge-service isn't behind a proxy in compose or
    development);
  - Security 7 (the same request handler), Jackson 3, Testcontainers 2.

  Spring Session's Redis format may change, which ends the sessions open at the time. That's
  harmless in development; note it for production (33).
- d: as catalog.

**dispatcher-service:**
- a: the Stream test binder moves from the `test-binder` test-jar classifier to
  `spring-cloud-stream-test-binder`; Function's `pack|label` composition and the bindings are
  checked in the smoke run.
- b: Stream 5 and Function 5, Testcontainers not used.

**order-service:**
- a:
  - `jakarta.validation`;
  - Security 6's resource server (`jwt(Customizer.withDefaults())`);
  - R2DBC on Spring Data 3 with r2dbc-postgresql 1.x;
  - Flyway 11 with `flyway-database-postgresql`, which removes Flyway 8's PostgreSQL 17 warning;
  - the test binder as in dispatcher-service;
  - Testcontainers unpinned (14).

  22 goes away with Boot 3.5's Byte Buddy: no pin, since order-service doesn't run JDK 21 on 2.7.
  The "Settings that look odd" entries (no `@Transactional` on `submitOrder`, the non-reactive
  consumer, FAILED orders) stay as they are, and `OrderAcceptedEventTests` and
  `OrderAcceptedEventFailureTests` guard them.
- b:
  - `spring-boot-starter-flyway`;
  - Testcontainers 2 (`testcontainers-postgresql`, `testcontainers-r2dbc`) and
    testcontainers-keycloak 4.4.x;
  - `OrderJsonTests` on Jackson 3;
  - OkHttp's `mockwebserver` version.

**config-service:**
- a, b: Config Server 4.3, then 5.0, and the Tomcat properties. Its `contextLoads` still clones
  GitHub's config-repo.

**quote-service and quote-function:**
- a:
  - Spring Native 0.12 out: the `org.springframework.experimental.aot` plugin and
    `repo.spring.io/milestone` removed, and `org.graalvm.buildtools.native` added at the version
    Boot 3.5 names.
  - quote-function: `javax.servlet` to `jakarta.servlet` in `FunctionInputExceptionHandler`.
  - The smoke script's JVM override (`BP_NATIVE_IMAGE=false` in `afterEvaluate`) checked against
    Boot's native-aware `bootBuildImage`. The JDK 17 special case leaves the script.
- b:
  - Boot 4 with GraalVM 25;
  - Spring Cloud Function 5's web layer (24's behaviour checked, not fixed);
  - reflection hints for the `Quote` and `Genre` records if the native image needs them.
- d, together with **20:** the native job comes back, enabled.
  - It runs on this repository's quote services, with `graalvm/setup-graalvm` on Java 25 and
    `./gradlew nativeTest nativeCompile`.
  - It builds a native image with `bootBuildImage` and checks the POETRY request (deferred
    checks 20, 24).
  - The smoke jobs keep JVM images, since native builds don't fit on the server.

## Images and platform

Only the service's own dependencies move with it: the OpenTelemetry agent, the builder, and the
test images. The rest move as separate steps, once no service step is half done:
- **12 and the observability stack:**
  - trim `tempo.yml` (memcached, cost attribution, demo retention, local-blocks) and bind OTLP to
    `0.0.0.0:4317/4318`;
  - then Tempo 2.10, Loki and its plugin 3.7, Grafana 12.4 and Prometheus 3.13 LTS, with new
    digests. Check whether Prometheus still needs `--enable-feature=native-histograms` or reads a
    config setting instead.
  - After dispatcher- and order-service (agent 2.x, trace context through RabbitMQ), verified
    with `all order dispatcher observability` and `all edge observability`.
  - The Grafana dashboards are checked against Prometheus client 1.x's metric names (Boot 3.3+),
    which the smoke test doesn't check.
- **RabbitMQ 4.4,** after order- and dispatcher-service are on Boot 4, in compose and
  `kubernetes/platform/development/services/rabbitmq.yml`:
  - the 200 MiB absolute watermark and the `subPath` mount stay;
  - check that the smoke script's temporary `smoke-test.*` queues don't hit 4.x's deprecation
    of transient non-exclusive queues;
  - verify with `all`, `all --k8s` and deferred check 3.
- **The browser tests' tools:** Node.js 26 in `development/ui-test/.nvmrc` (CI reads it) and
  Playwright at its latest release, with `npm ci` and the browser install. One step, after
  edge-service, verified with `all ui` and CI. polar-ui itself isn't touched.
- **MicroK8s 1.36:** the CI snap channel and `KUBERNETES_VERSION` for kubeconform (and its latest
  release), then the server's MicroK8s (`sudo snap refresh`, by the user). Verify with
  `all --k8s` and deferred check 4.
- **Kubernetes manifests:**
  - the apps' 756Mi limit is checked against pod memory in every `--k8s` run, compared with the
    baseline, since Boot 4 and JDK 25 change memory use;
  - Keycloak's image doesn't change, so its 750Mi limit is only watched;
  - the startup probes and the `sleep` preStop hooks stay.
- **Compose:** `SPRING_REDIS_HOST` (edge-service's step a), the image tags above.

## CI

- **The JDK matrix:**
  - `build-java-21` and `build` become one `build` job whose matrix lists `{project, java}`, and
    each service's step d changes its entry;
  - the images job sets up 17, 21 and 25 while they're mixed;
  - at the end, one `java-version: 25`.
- **29, at the end:**
  - the smoke script's `SMOKE_JDK_17`/`SMOKE_JDK_21` and its per-service JDKs give way to a preset
    `JAVA_HOME`, or a `SMOKE_JDK` defaulting to it;
  - `SMOKE_JDK_25` is added while the JDKs are mixed;
  - the smoke-test skill and the script's help follow.
- **14:** every service on Boot-managed Testcontainers (1.21.4, then 2.0.x).
  - Then deferred check 14: one run of the build jobs on `ubuntu-26.04`, from a temporary branch.
  - The runners stay `ubuntu-24.04`, as decided.
  - The per-service `*/.github/workflows` (`ubuntu-22.04`, not run here) are left for 33.
- **20:** as in step 0 and the quote services' step d.

## Verification at every step

- **Gradle:** `./gradlew build` for the service, with
  `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock` and
  `TESTCONTAINERS_RYUK_DISABLED=true`. Compare the test count and coverage with the baseline:
  no test may disappear in a migration. Then `./gradlew --stop`, and remove leftover test
  containers.
- **Podman smoke selection, with `--rebuild`:**

  | Service | Selections |
  |---|---|
  | catalog | `all`, then `all ui`, and the API snapshot diff |
  | edge | `all ui`, `all edge observability`, and the API snapshot diff |
  | dispatcher | `all order dispatcher observability` |
  | order | `all order dispatcher observability`, `all ui`, the API snapshot diff |
  | config | `all` (catalog as config client) |
  | quote, quote-function | `all quote quote-function` |

- **The browser tests and memory (52):** before `all ui`, check that no other session holds
  memory (`free -h`, ListAgents), and record `/proc/pressure/memory` during the run. If tests
  time out, keep their traces (`smoke-test.sh logs DIR`). A local run that fails only by
  timeouts under memory pressure isn't the verdict: CI's `edge ui` job is, and the commit message
  says so.
- **MicroK8s `all --k8s`:**
  - for step b and d of catalog-, order-, dispatcher- and config-service (memory under 756Mi);
  - where manifests change;
  - with the MicroK8s and RabbitMQ steps.

  Stop MicroK8s for edge and the browser tests.
- **Deferred checks:**
  - 3 in order-service's a and b steps and the RabbitMQ step;
  - 4 after catalog-service's step d and the MicroK8s step;
  - 20 and 24 in the quote services' step d;
  - 14 at the end;
  - 18 whenever two pushes follow quickly.

  9, 10 and 28 remain after the update.
- **CI:** each pushed step, followed with `development/script/watch-run.sh RUN_ID`. If an image
  build fails on a download, re-run the whole run, since the run has already deleted the other
  image artifacts.
- **Recording:** each commit message carries its verification. Fixed findings leave
  `development/findings.md`. The plan's progress notes record each step, and
  `development/README.md` ("Versions", "Settings that look odd") follows at the end.

Memory: `free -h` before each heavy task. One task at a time. Then `./gradlew --stop`,
`smoke-test.sh down`, and MicroK8s stopped when it isn't needed. Take turns with other sessions
on the machine rather than skip a check.

## Risks, unknowns and backing out

**Known risks:**
- CSRF masking: `SecurityConfigTests`, browser tests 02, 03 and 04 (writes and the logout form),
  and the curl smoke tests' CSRF checks.
- Gateway property names silently not applying: checked through the actuator.
- JSON changes under Jackson 3 that polar-ui v2.1.1 reads: the API snapshot diff.
- Flyway on PostgreSQL 17: fixed by step a.
- Keycloak's 750Mi: unchanged image, watched.
- App memory under the 756Mi and `--memory 1g` limits, and the server's 2.7 GiB budget for the
  default stack.
- Prometheus client 1.x metric names in the dashboards.
- The OpenTelemetry agent 2.x's semantic conventions.
- Spring Retry and OkHttp no longer managed by Boot 4.
- Gradle 9's removed APIs.
- RabbitMQ 4's queue deprecations.
- Native images needing reflection hints.

**Unknown until tried:**
- Spring Cloud Function 5's web error mapping (24);
- Stream 5's test binder;
- Gateway 5 with Spring Session Redis;
- Jackson 3's output for `Instant` and records;
- the config client's retry in 2025.1;
- whether the smoke script's JVM override still yields JVM images for the quote services.

**Backing out:**
- Every step is its own commit, and services are separate builds, so a service can stay a step
  behind while the others go on.
- Before a push, drop the local commit (never a bare `git stash`). After a push, `git revert`
  it, then `--rebuild` the images.
- `pre-dependency-update` marks the state before the update.
- No step changes a Flyway migration, so there is no schema to undo.
- RabbitMQ 4 can't go back to 3.13 on the same data. The development containers are thrown away
  by `down`, so this doesn't matter here.
- Redis sessions are flushed.

## After the update

From `development/findings.md`:
- 24 and 38, on the new Spring Cloud Function web layer and gateway;
- 3's outbox and 26, on the new R2DBC and Stream APIs;
- 23, 27, 31;
- 50, if Gateway 5 makes routing every non-API path to polar-ui simpler;
- 9, 28, 30, 52;
- 33, 42 and 43 as a task of their own: until the staging and production overlays use this
  repository's `k8s/` directories, the update doesn't reach them, and production's polar-ui moves
  to the fork's release with them.

Later as well:
- Boot 4.2 and Spring Cloud 2026.0;
- PostgreSQL 18, Redis 8, Tempo 3;
- `@ServiceConnection` in place of `@DynamicPropertySource`.

`development/findings.md`'s "The dependency update" section is rewritten at the end to what
remains.

## Progress

| Step | Commit | Verification |
|---|---|---|
| 0.1 The plan | `1d168f2` | CI 42368287174 |
| 0.2 CI actions, permissions, cache keys (17, part of 20) | | |
