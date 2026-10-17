# CI build plan for PolarBookshop

Plan for extending the GitHub Actions build so that it builds the container images, runs the
smoke tests against a Podman stack and a MicroK8s cluster, and keeps the test and coverage
reports. Only `PolarBookshop/` is in scope; the `Chapter*` snapshots stay out of CI.

Each step is a separate change that leaves CI green and is useful on its own. Cheap, low-risk
steps come first, and the steps that need new tooling on the runner come later.

## Where CI is now

- One workflow, `.github/workflows/commit-stage.yml`, runs on every push to any branch and weekly
  on Mondays. The workflows under `PolarBookshop/*/.github/` are the book's per-repository copies
  and never run.
- Two matrix jobs run `./gradlew build` for the seven services: `build-java-21` for
  catalog-service on `ubuntu-24.04`, and `build` (Java 17) on `ubuntu-22.04` for quote-service,
  quote-function, dispatcher-service, config-service, order-service and edge-service. That covers
  compilation, the unit and slice tests, and the Testcontainers integration tests (PostgreSQL,
  Keycloak, Redis).
- The JaCoCo and test reports are generated but discarded with the runner.
- Nothing builds container images, deploys anything or runs the services together. The smoke
  tests (`.claude/skills/smoke-test/smoke-test.sh`) only run on the development server.

## Target pipeline

```
push / weekly / manual
 ├── build-java-21 (catalog-service) ──┐
 ├── build (6 services, Java 17) ──────┼──► images ──┬──► smoke-podman   whole system on Podman + compose
 │                                     │             └──► smoke-k8s      catalog, order, dispatcher, config on MicroK8s
 └── k8s-manifests (kustomize + kubeconform) ──────────► smoke-k8s
                                          reports ◄── all of the above: test, coverage and smoke summary
```

Everything stays in one workflow and runs on every push. The smoke jobs start only when the
Gradle builds pass; with a failing unit test their result is noise. Until step 9, each smoke job
builds its own images and there is no `images` job.

## Assumptions

- **Runner image.** All jobs run on `ubuntu-24.04`, the same Ubuntu release as the development
  server (24.04.5). Its image includes Podman 4.9.3, and Ubuntu 24.04's `podman-compose` package
  is 1.0.6, the same versions as on the server. `ubuntu-26.04` is only in public preview, with
  newer tool versions than the server; see Future work.
- **Runner size.** GitHub's standard Linux runner has 4 vCPUs and 16 GB RAM for public
  repositories, and 2 vCPUs and 7 GB for private ones. Either is more than the 4 GB development
  server, so every selection the smoke tests run locally fits. No larger runners are needed.
- **Podman in CI.** Running the script with Podman keeps one code path; porting it to Docker is
  not part of this plan.
- **MicroK8s on the runner.** It installs with snap, as on the server (1.35/stable), so the
  script's `--k8s` mode, which reaches ClusterIPs from the host and pushes to the
  `localhost:32000` registry addon, works unchanged. kind is preinstalled on the runner, but its
  ClusterIPs aren't reachable from the host, so the script would need changes for it.
- **The script stays the single source of the smoke tests.** CI and the smoke test skill call
  the same script, at `development/script/smoke-test.sh` from step 3 on. Changes made for CI must
  leave its local behaviour unchanged.

## Step 1: Keep the test and coverage reports

**Goal:** every run has downloadable test and JaCoCo reports, and one table with the results of
all seven services.

Changes:
- Keep the matrices as lists of project paths, so that other projects, such as the `Chapter*`
  snapshots, can be added to them. The steps run in `${{ matrix.project }}` through
  `defaults.run.working-directory`.
- Move the `build` job from `ubuntu-22.04` to `ubuntu-24.04`. GitHub began deprecating the Ubuntu
  22.04 images in September 2026 and stops supporting them in April 2027, and every job then runs
  on the server's Ubuntu release.
- After `./gradlew build`, upload `build/test-results/test/`, `build/reports/tests/test/` and
  `build/reports/jacoco/test/` with `actions/upload-artifact@v7`. Artifact names can't contain
  `/`, so a step names the artifact after the project path with `-` for `/`, for example
  `reports-PolarBookshop-catalog-service`. It also adds a `project.txt` with the project's
  path, which the summary shows, and which keeps the artifact from being empty when the build
  fails before the tests. Use
  `if: ${{ !cancelled() }}`, so that a failing test still keeps its report (Gradle writes the
  test reports and, through `finalizedBy`, the JaCoCo report even when a test fails), and a
  short retention, for example 14 days.
- Add a small script, `.github/scripts/report-summary.py` (standard library only). It reads the
  JUnit XML files (tests, failures, errors, skipped) and `jacocoTestReport.xml` (line and branch
  counters) and prints a Markdown table.
- Add a `reports` job (`needs` both build jobs, `if: ${{ !cancelled() }}`) that downloads the
  `reports-*` artifacts with `actions/download-artifact@v8` and writes the table to
  `$GITHUB_STEP_SUMMARY`, one row per project. A project without test results, such as one that
  failed to compile, still gets a row, and failed tests are listed by name. Each row links to
  its artifact: the job lists the run's artifacts with `gh api` (`actions: read` permission),
  and the link downloads the artifact as a zip. GitHub shows only single-file artifacts uploaded
  with `archive: false` in the browser, and the HTML reports are directories with CSS and
  JavaScript.

Optional: annotations for failing tests with a JUnit report action such as
`mikepenz/action-junit-report`. It needs the `checks: write` permission.

**Done when:** a run's summary page shows the test counts and line/branch coverage of all seven
services, and a deliberately failing test (on a branch) shows up in the table, with its HTML
report in the artifact.

## Step 2: Validate the Kubernetes manifests

**Goal:** a broken manifest fails CI within seconds, before any cluster is involved.

Changes:
- Add a `k8s-manifests` job without Java. It renders each `PolarBookshop/<service>/k8s` with
  `kubectl kustomize` (preinstalled on the runner) and pipes it through
  `kubeconform -strict -summary`, and validates the files of the backing services in
  `polar-deployment/kubernetes/platform/development/services/` directly. All of them use only
  built-in kinds, so no CRD schemas are needed.
- Install kubeconform from its release tarball, pinned to a version (v0.8.0) and its SHA-256.
  Validate against `-kubernetes-version 1.35.0`, the release of the MicroK8s channel of step 8.
  kubeconform downloads the schemas from the `yannh/kubernetes-json-schema` repository.
- Run the step with `shell: bash`, which adds `-o pipefail`: when kustomize fails, kubeconform
  finds no resources and exits 0. The step checks every directory and fails at the end, so one
  run reports all broken manifests.
- Leave out the staging and production overlays in `polar-deployment/kubernetes/applications/`.
  Their base is `github.com/polarbookshop/<service>/k8s?ref=main`, the book's upstream
  repositories, so they would validate those instead of this repository (see Future work).

**Done when:** the job is green, and an unknown field added to a `deployment.yml` makes it fail.

## Step 3: Move the smoke test script to `development/script/`

**Goal:** the script lives next to the other development material, where CI and the skill both
call it.

Changes:
- `git mv .claude/skills/smoke-test/smoke-test.sh development/script/smoke-test.sh`. The script
  finds the repository root with git and prints its usage from `$0`, so its code doesn't change.
- `SKILL.md` stays in `.claude/skills/smoke-test/`, because that's where Claude Code finds skills,
  and its commands call `bash development/script/smoke-test.sh`.
- Update the other references to the old path, such as the introduction of
  `PolarBookshop/findings.md`.

**Done when:** the skill's commands work from the new path, and no file refers to the old one.

## Step 4: Make the smoke test script runnable in CI

**Goal:** the script runs on a fresh runner, and its results and diagnostics can be kept, with
no change to local runs.

Changes in `development/script/smoke-test.sh`:
- **JDKs.** Read the build JDKs from `SMOKE_JDK_17` and `SMOKE_JDK_21`, defaulting to today's
  sdkman paths. In CI, `actions/setup-java` installs both and exports `JAVA_HOME_17_X64` and
  `JAVA_HOME_21_X64`.
- **Podman socket.** Ask Podman for the socket path
  (`podman info --format '{{.Host.RemoteSocket.Path}}'`) instead of hard-coding
  `/run/user/<uid>/podman/podman.sock`, and set it up only when an image is built. If the API
  doesn't answer and `systemctl --user start podman.socket` doesn't help (the runner may have no
  user session), start `podman system service --time=0` on that path in the background for the
  length of the run. The systemd unit runs the same command, so bootBuildImage gets the same API.
- **Diagnostics.** Add a `logs <dir>` command. It writes `podman ps -a`, `free` and
  `podman stats`, each smoke container's state (exit code, OOM kill) and log to the directory.
  With `--k8s` it writes the namespace's resources, events and pod descriptions, and each
  deployment's log, including the log before a restart. CI uploads the directory when a run
  fails, and it's useful locally too.
- **JUnit output.** When `SMOKE_JUNIT=<file>` is set, `check` also records each check, with the
  section heading as the class name, and the script writes them as JUnit XML when it exits. A
  run that stops before its tests finish, such as one whose `up` fails, gets an error case named
  after the section it stopped in. The step 1 summary then covers the smoke tests too.
- On exit, kill the background processes together with their children. The Keycloak
  port-forward runs under MicroK8s' wrapper scripts, and killing only the subshell left kubectl
  running and holding port 38080 after every `--k8s` test run.
- A call without a command prints the usage instead of running `all` (done before this step).
- Update `SKILL.md` for the new variables and the `logs` command.

**Done when:** `all`, `all edge` and `all catalog --k8s` give the same results as before on the
development server, and `SMOKE_JUNIT` writes a file with one test case per check.

## Step 5: Smoke test the default stack on Podman

**Goal:** catalog, order, dispatcher and config are built as images from the pushed commit and
tested together on every push.

Changes:
- Add a `smoke-podman` job on `ubuntu-24.04` with `needs: [build-java-21, build]`. Give it
  `timeout-minutes` (for example 45), so a hung stack doesn't run for the default six hours.
- Setup: `actions/setup-java` with both 17 and 21 and the Gradle cache, and
  `sudo apt-get install -y podman-compose python3-yaml`. The cache gets its own key
  (`cache-dependency-path` over the `PolarBookshop/*` build files), because the image builds need
  other dependencies than the build jobs, which all share the default key.
- Run `bash development/script/smoke-test.sh all --rebuild` with `SMOKE_JDK_*` (from setup-java's
  `JAVA_HOME_17_X64` and `JAVA_HOME_21_X64`) and `SMOKE_JUNIT` set, saving the output with `tee`
  under `shell: bash`, whose `pipefail` keeps the script's exit status.
- Always upload one `reports-smoke-podman` artifact with the output, the JUnit file and a
  `project.txt`. On failure, also run `smoke-test.sh logs` into it. These steps use `always()`
  and `!success()`, because a timeout cancels the job, and a hung stack needs the logs most. The `reports` job also
  `needs` this job, so the summary gets a smoke test row, and its Reports link downloads the
  output and logs.
- Print `df -h` and `free -h` before the run, and `df -h` and `podman system df` after it, for
  the risks below.
- Give the workflow a `concurrency` group per branch with `cancel-in-progress: true`: runs now
  take much longer, and a newer push makes the older run pointless. Also add the
  `workflow_dispatch` trigger, so a run can be started by hand.

**Done when:** the job is green on a branch push, and a deliberately failing check fails the job
and leaves the diagnostics artifact.

Risks to check in the first runs:
- rootless Podman on the runner: user namespaces, `subuid` ranges, and
  `host.docker.internal:host-gateway`;
- disk space: the Paketo builders, run images and app images take several GB of the runner's
  disk. If it runs out, remove unused preinstalled tooling or Docker images first;
- Docker Hub's limits on anonymous pulls. If pulls start failing, log in with a token from a
  repository secret;
- the job's duration, mostly image builds and builder pulls. Record it, so that steps 6, 8 and 9
  can be compared against it.

## Step 6: Smoke test the rest of the system on Podman

**Goal:** edge-service with polar-ui, quote-service, quote-function and the observability stack
are tested too.

Changes:
- In the same job, run the selections that already pass on the development server one after
  another, with `down` in between: the default set (step 5), `edge`, `quote quote-function`, and
  `order dispatcher observability`. Each later run reuses the images built earlier in the job and
  builds only the missing ones, so every image is still built from the pushed commit.
- Collect the JUnit files of all the runs.

Running everything at once would fit in the runner's memory too, but that has never been run,
even locally. Try it once the separate runs are stable: it would shorten the job and test the
whole system together, including edge-service with observability.

**Done when:** all four selections pass in CI.

## Step 7: Fix the slow-start restarts on Kubernetes

**Goal:** a cold start of all the services on Kubernetes passes the smoke test's no-restarts
check.

This is the open finding in `PolarBookshop/findings.md`: when the apps start together with
Keycloak, the liveness probe kills them before they're up, and each one is restarted 3-4 times.
In CI every deployment is a cold start, so without this fix the Kubernetes job would fail or be
flaky.

Changes:
- Add a `startupProbe` on `/actuator/health/liveness` to each `k8s/deployment.yml` (catalog,
  order, dispatcher, config and edge), with room for a slow start (for example
  `periodSeconds: 5`, `failureThreshold: 30`), as `polar-keycloak` already has.
- Check it with a cold `smoke-test.sh all --k8s` on the development server, and move the finding
  to Resolved.

**Done when:** a cold `all --k8s` passes with no restarts on the development server.

## Step 8: Smoke test on MicroK8s

**Goal:** the services' own `k8s/` manifests are deployed to a real cluster and tested on every
push.

Changes:
- Add a `smoke-k8s` job on `ubuntu-24.04` with a timeout. It `needs` the build jobs and
  `k8s-manifests`, and runs in parallel with `smoke-podman` on its own runner.
- Setup as in step 5, plus MicroK8s from the channel the development server uses:
  ```bash
  sudo snap install microk8s --classic --channel=1.35/stable
  sudo microk8s status --wait-ready
  sudo microk8s enable dns registry
  ```
  Then wait until the registry answers at `http://localhost:32000/v2/`.
- Run `development/script/smoke-test.sh all --k8s --rebuild` with
  `KUBECTL="sudo microk8s kubectl"`. The script already reads `KUBECTL`, and with sudo the runner
  user doesn't need to join the `microk8s` group and log in again.
- On failure, upload the output of `smoke-test.sh logs --k8s`.

**Done when:** the job is green, with no restarts, on a branch push.

Risks:
- Reaching ClusterIPs from the host and the Keycloak port-forward work on the development server,
  where MicroK8s also runs directly on the host, so they should work on the runner too.
- The runner also runs Docker, which sets the iptables `FORWARD` policy to `DROP`;
  `microk8s inspect` warns about this. If pods can't reach each other or the cluster DNS, run
  `sudo iptables -P FORWARD ACCEPT` before deploying.
- The snap install and the addons add a few minutes.

If MicroK8s turns out to be unreliable or slow on the runner, kind is the fallback. It is
preinstalled and starts faster, but it would need its own code path in the script's `--k8s` mode,
because:
- its cluster runs inside a Docker container, so the host can't reach the ClusterIPs. Every
  service would need a port-forward, as Keycloak has now, or a NodePort with a port mapping;
- it has no registry at `localhost:32000`. The images built with Podman would be loaded with
  `kind load image-archive`, and the check that each pod runs the pushed image would change;
- this server has no Docker, and kind's Podman support is experimental, so local runs would stay
  on MicroK8s. CI would then test a different Kubernetes setup from the local runs.

## Step 9: Build the images once and share them as artifacts

**Goal:** the images are built once per run, and every testing job uses those same images.

An artifact uploaded by one job can be downloaded by any later job of the same workflow run, so
both smoke jobs, and any testing job added later, can load the images without a registry. The
images never leave the run.

Changes:
- Add a `build` command to the script that only builds the selected images, so the JDK choice
  and the native-image override stay in one place.
- Add an `images` job, `needs` the Gradle build jobs, that builds the images with it. It saves
  them with `podman save` into one archive (layers the images share are stored once) and uploads
  it with `retention-days: 1`. polar-ui and the backing services aren't built, so they are pulled
  as before.
- The smoke jobs `need` the `images` job, download the archive, `podman load` it and run without
  `--rebuild`, so the script uses the loaded images.

If the single `images` job takes too long, a matrix job per service can build them in parallel,
each uploading its own artifact.

**Done when:** the smoke jobs don't run Gradle, both test the images from the `images` job, and a
run takes less time than with step 8 alone.

## Decisions

1. **The script moves to `development/script/`** (step 3). The skill stays in
   `.claude/skills/smoke-test/` and calls it there.
2. **The smoke tests run on every push**, in the same workflow as the Gradle builds, with
   cancel-in-progress per branch. If that turns out too slow, they move into a separate workflow;
   see Future work.
3. **The images are shared as artifacts inside the run** (step 9), not through a registry.

## Future work

Smaller issues found in the current workflow:
- config-service's `contextLoads` test and the smoke tests clone
  `https://github.com/PolarBookshop/config-repo`. They need network access and depend on a
  repository outside this one, which can change.
- Both build jobs grant `security-events: write`, which nothing uses.
- `actions/setup-java`'s Gradle cache key is the same for every job, so probably only one
  project's dependencies end up in the cache.
- The disabled `native-build` job still points at `Chapter16/16-end`.
- The two build jobs use different action versions (v4 and v5).

Further steps, out of scope for now:
- **A separate smoke test workflow**, if running the smoke tests on every push is too slow. It
  would start with `workflow_run` when the build workflow completes, and download the images from
  the triggering run (`actions/download-artifact` with `run-id` and a token). Note that
  `workflow_run` always uses the workflow file from the default branch, so changes to the smoke
  workflow on a branch only take effect after they're merged.
- **`ubuntu-26.04` runners**, once the image is generally available, or when the development
  server moves to 26.04. The image is in public preview and has newer tool versions, Podman among
  them, than the server, so the smoke tests would run against a different setup than the local
  runs.
- Native images of quote-service and quote-function. The smoke tests build them as JVM images
  because the development server lacks the memory; a runner has enough.
- Coverage thresholds with `jacocoTestCoverageVerification`, once the step 1 reports show where
  the numbers are.
- Vulnerability scanning of the code and the images; the book uses Anchore's grype.
- Publishing the images to GHCR, and the book's acceptance and production stages.
- The staging and production overlays. Their bases have to point at this repository's `k8s/`
  directories before they can be validated or deployed.
- The parts of Kubernetes the smoke test doesn't cover yet: edge-service and polar-ui,
  observability, and quote-service and quote-function on Knative (Future work 6 in the smoke test
  skill).
- Path filters, so that a push changing only one service doesn't rebuild and test all of them.
