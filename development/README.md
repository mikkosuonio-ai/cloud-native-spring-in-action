# Development

Material for developing and testing PolarBookshop in this repository, beyond the book's code: the
smoke tests, the browser tests, the CI build, and the decisions behind them. Open findings and
future work are in [findings.md](findings.md).

## Contents

- **`script/smoke-test.sh`** starts the services under Podman, or deploys them to MicroK8s with
  `--k8s`, and runs the HTTP smoke tests. `smoke-test.sh help` prints its usage. The `smoke-test`
  skill (`.claude/skills/smoke-test/SKILL.md`) describes how to run it on the development server.
- **`script/watch-run.sh`** follows a GitHub Actions run until it completes.
- **`ui-test/`** has the browser tests of polar-ui (Playwright), run by `smoke-test.sh … ui`.
- **`findings.md`:** open findings, deferred checks and future work.

## Where things are

- **CI** (`.github/workflows/commit-stage.yml`) runs on every push, weekly and by hand:
  - the Gradle builds of the seven services;
  - kubeconform on the services' `k8s/` and the development platform manifests;
  - one image build per service, shared with the smoke jobs as artifacts and deleted after them;
  - the smoke tests on Podman (default, `edge ui`, `quote quote-function`,
    `order dispatcher observability`) and on MicroK8s (`all --k8s`);
  - a summary of the test, coverage and smoke results.
- **The browser tests** run the full stack: 10 tests, 100 checks with edge's.
- **polar-ui** is the public fork mikkosuonio-ai/polar-ui (clone `/home/ai/devel/polar-ui`), and
  this repository pins `ghcr.io/mikkosuonio-ai/polar-ui:v1.3.0`.
  - The fork's CI runs 35 Karma unit tests and 16 mocked Playwright e2e tests (`e2e/`), scans the
    code and the image with Anchore, and publishes `sha-<7>` from `mikkosuonio/development` and
    `:<tag>` from a `v*` tag on that branch.
  - A change that touches both the UI and the backend needs a release of the fork first, then a
    tag bump here.
  - Commits in the fork come from a Claude session started in its clone, since a session in a
    worktree here runs git only in that worktree.
- **Versions:** catalog-service is on Spring Boot 3.5.6 and JDK 21; the other services are on
  Boot 2.7.18 and JDK 17. Everything except production runs PostgreSQL 17.11 and Keycloak 26.8.1.

## Decisions

From the CI build plan (2026-10-18/19), the polar-ui testing plan (2026-10-23 to 2026-10-28) and
the review of 2026-10-19. The plans are in git history:
`git show 6a9cd2a:development/plan/<ci-build|ui-testing|review-2026-10-19>.md`.

### CI

- **One workflow, on every push,** with the Gradle builds and the smoke tests together. The smoke
  jobs start only when the Gradle builds pass. A push to a branch other than the default cancels
  that branch's older run; runs on the default branch, scheduled and manual runs are never
  cancelled. If the smoke tests make pushes too slow, they move to a workflow of their own.
- **`ubuntu-24.04` runners,** the development server's Ubuntu release, with the same Podman
  (4.9.3) and podman-compose (1.0.6). `ubuntu-26.04` waits until it's generally available or
  the server moves to it.
- **Podman in CI too,** not Docker, so that the smoke script has one code path.
- **The script is the single source of the smoke tests.** It lives in `development/script/`, CI
  and the skill both call it, and changes made for CI leave its local behaviour unchanged.
- **MicroK8s, not kind,** on the runner as on the server (snap, `1.35/stable`). The script's
  `--k8s` mode reaches the ClusterIPs from the host and pushes to the `localhost:32000` registry,
  which kind doesn't offer: its cluster runs inside a Docker container, and its Podman support is
  experimental, so CI would test another setup than the local runs. The job uses MicroK8s' own
  kubectl, since the runner's is too new for the cluster.
- **The Podman selections are a matrix,** one runner each. Running them one after another in one
  job would reuse the images, but the runner's disk can't take them all.
- **The images are built once per run,** one job per service beside the Gradle builds, and shared
  as artifacts kept for a day, not through a registry. A job deletes them when the smoke jobs are
  done, so a failed smoke job can't be re-run on its own. One job building all images into one
  archive would save half of the transfer, but takes 8–10 minutes.
- **Reports:** every build and smoke job uploads its test, coverage or smoke results with a
  `project.txt`, and the `reports` job writes one table, a row per project, with a link to each
  artifact.

### Browser tests

- **Full stack, no mocks:** the tests drive the stack that `smoke-test.sh up edge` starts, through
  edge-service at `http://localhost:9000`: SPA, gateway, Keycloak, catalog and order.
- **Playwright,** with its Chromium headless shell. Selenium needs a WebDriver server, and Cypress
  can't cross origins (edge → Keycloak → edge) as easily.
- **In this repository,** not in polar-ui, since they test the system against a released image.
- **The smoke script is the entry point.** The `ui` selection adds edge and runs the tests after
  the curl checks; each test is one check in the summary and in `SMOKE_JUNIT`.
- **An open bug is an expected failure:** a test for it is marked `test.fail` with a link to its
  finding. It passes as "expected failure", and fails once the bug is fixed, as a reminder to
  remove the mark.
- **The tests clean up after themselves.** Their books' ISBNs start with 97, and a fixture deletes
  such books in PostgreSQL before and after each test. Outages they cause are undone in a
  `finally`, and noted in an undo file that the script runs if the tests are killed.

### polar-ui

- **A public fork** (2026-10-26), not a copy in this repository. Public repositories run on
  GitHub's standard runners for free, so this repository was made public too (2026-10-25, after a
  scan of its history found no secrets). The fork builds with the book's buildpacks on
  `builder-jammy-base`, pinned to a version.
- **Its own tests** (2026-10-28): Karma unit tests where there is logic, and e2e tests with the API
  mocked in the browser, in Playwright, the same tool as here. The full-stack tests stay here,
  with no smoke script changes. Any e2e framework works with every Angular version, since it
  drives the built app. Rejected:
  - moving the full-stack tests to the fork, where they would carry this repository's containers,
    database and users;
  - the full stack in the fork's CI, which needs published backend images;
  - Cypress and WebdriverIO, as a second framework.

### Settings that look odd

Each came from a fixed finding: the review's number, or one of `PolarBookshop/findings.md`, both
in git history at 6a9cd2a.
- **Keycloak gets `-XX:MaxRAM` from its own memory limit** (`keycloak.yml`, through the Downward
  API). On the runners' kernel 6.17, the image's JVM didn't detect the container's limit and sized
  its heap from the runner's RAM, and Keycloak was OOM-killed (5).
- **The compose realm has `sslRequired: none`.** With `external`, Keycloak marked its login
  cookies `Secure` for `host.docker.internal`, and no browser could log in over http (35).
- **The apps' deployments have startup probes** allowing 150 s, and liveness probes with a 3 s
  timeout. Started together on 2 CPUs, the apps took longer than the liveness probe allowed and
  were restarted (13).
- **The preStop hooks use `sleep`,** not `sh -c "sleep 5"`: catalog's tiny image has no shell (4).
- **catalog-service's builder is pinned to a version,** since Paketo once pushed its `latest` as
  an arm64-only image.
- **The smoke script sets the network bridge's MAC address.** netavark 1.4 lets it change when a
  container joins, and the containers started before then lose DNS for up to a minute (34).
- **RabbitMQ on Kubernetes** has an absolute memory watermark (200 MiB) under a 300Mi limit, and
  only `rabbitmq.conf` mounted, with `subPath` (6).
- **`OrderService.submitOrder` isn't `@Transactional`,** so the order-accepted event goes out only
  after the order is committed; before, dispatcher-service's answer could beat the commit and be
  dropped. An order whose event can't be sent is saved as FAILED (3).
- **order-service's order-dispatched consumer isn't reactive,** so one failed message doesn't end
  the stream (2).
- **catalog-service permits error dispatches,** so server errors aren't turned into 401 (1).
- **The OpenTelemetry agent has a fixed name,** `opentelemetry-javaagent.jar` at the jar's root,
  and `OTEL_LOGS_EXPORTER=none`, since agent 2.x exports logs that Tempo doesn't accept (7).
- **The `testdata` profile isn't active by default,** since it deletes the catalog at startup (8).
- **Smoke runs from different worktrees take turns** through a lock, since they share container
  names, ports and image tags (10).
