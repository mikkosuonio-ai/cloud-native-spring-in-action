# Plan for testing polar-ui

Plan for testing the browser UI, polar-ui, as part of the system: in the smoke tests, locally and
in CI. It also covers whether polar-ui's own tests are worth improving. Written 2026-10-23,
against `mikkosuonio/development` at 9e6a015 and polar-ui's `main` at df287df.

Each step is a separate change that leaves CI green and is useful on its own. The first steps
need no new tooling.

## Where testing of polar-ui is now

**polar-ui is not in this repository.** It is the book's Angular 13 SPA from
[PolarBookshop/polar-ui](https://github.com/PolarBookshop/polar-ui), and the stack runs its
prebuilt image `ghcr.io/polarbookshop/polar-ui:v1` (compose file, line 154). No commit here can
change it, and nothing here builds it.

**The smoke test barely touches it.** `smoke-test.sh all edge` starts the image, waits for
`http://localhost:9004/`, and `test_edge` checks two things: `GET /` through edge-service
returns 200, and the body contains `<html`. It never loads the JavaScript or CSS, never runs the
app, and never uses a browser. Every other edge check is curl acting as a browser would: the
OAuth2 login (`edge_login` parses Keycloak's form), CSRF (the XSRF-TOKEN cookie sent back as a
header), the token relay, logout and the circuit breaker. Those checks test the gateway's side
of the contract, and they assume what the SPA does rather than check it.

The review plan already lists this as a gap: the deferred check for finding 1, "How polar-ui
reacts to the 401 in a browser", needs a browser and is still open.

**polar-ui's own tests don't run and wouldn't pass.**
- Its CI (`.github/workflows/commit-stage.yml` in that repository) runs only `./gradlew
  buildAngular`. The Gradle tasks `testAngular` and `lintAngular` exist but no workflow calls
  them.
- The 12 `*.spec.ts` files are the Angular CLI's generated stubs: `should create` /
  `should be created`. Most would fail: the component specs declare the component without its
  dependencies (`HttpClient`, `MatDialog`, `MAT_DIALOG_DATA`, `ActivatedRoute`, the Material
  modules), and `AppComponent`'s spec expects the CLI's welcome text "Polar Bookshop app is
  running!", which the template doesn't have.
- `karma.conf.js` starts a visible Chrome in watch mode (`browsers: ['Chrome']`,
  `singleRun: false`), so it can't run in CI as it is.
- `e2e/` is the CLI's Protractor stub, which expects "ui-application app is running!".
  Protractor is deprecated and left the Angular CLI in version 15.
- `tslint` is deprecated too, and `ng lint` has no builder configured in Angular 13.

## What a browser test would catch that curl can't

From reading polar-ui's source, the parts that can break between the services and the browser:

| What | Where | Why curl misses it |
|---|---|---|
| The app's files load through edge-service | `spa-route` only matches `/`, `/*.css`, `/*.js`, `/favicon.ico` | curl only fetches `/`. A build that emits files in a subdirectory, or another extension, gets 401 (the path isn't permitted) |
| Login works in a real browser | Keycloak 24 marks its login-session cookies `Secure`, over plain http, on `host.docker.internal` | curl stores them by hand (see `edge_login`). Browsers refuse `Secure` cookies from an insecure origin other than localhost, and Keycloak 24 no longer sends the `_LEGACY` fallback cookies. **Login in a browser may not work at all; see step 0** |
| Angular's own CSRF handling | `HttpClientModule`'s XSRF interceptor; the logout `<form>` posting `_csrf` from the cookie | The smoke test sends the header itself. Spring Security 6 (with Boot 3) masks CSRF tokens by default, which breaks SPAs that send the raw cookie value. The update needs this guarded |
| The 401 handling | `HttpInterceptorImpl`: a 401 on anything but `/user` sends the browser to `/oauth2/authorization/keycloak` | Finding 1's deferred check. Before its fix, a catalog outage would send the user to the login page |
| Role-dependent UI | "Add Book" for `employee`, "My Orders" when logged in | The `/user` response is checked, not what the UI makes of it |
| Hash routes and deep links | `useHash: true`, so `/#/my-orders` | n/a |
| Error and fallback states | `GET /books` fallback body `""` (finding 32) | Angular parses an empty JSON body as `null`, so `books` becomes `null` and the book list shows only a spinner. Unverified |

Likely bugs, found by reading the code and to be confirmed by the tests:
- **Remove doesn't update the list.** `removeBook` deletes and then navigates to
  `/browse-books`, the page it's on. Angular ignores navigation to the current URL by default, so
  the removed book stays on screen until a reload.
- **The spinner never shows while loading**, since `books` starts as `[]`, not `undefined`.
- **The order total is formatted with `toPrecision(4)`:** 7.5 shows as `7.500`, and totals of
  10000 or more in exponent notation.
- **The edit form lets the ISBN change**, which leads to finding 31 (`PUT /books/{isbn}` with
  another ISBN in the body).
- **The page title is still "UiApplication".**
- **index.html loads fonts and icons from Google Fonts.** The tests should block those requests,
  so that they don't depend on an external service. The icons then show as their ligature names,
  which matters for text selectors.

## Approach

- **Browser tests drive the real stack** that `smoke-test.sh up edge` starts, through
  edge-service at `http://localhost:9000`. No mocks. They are system tests of the whole chain:
  SPA, gateway, Keycloak, catalog-service, order-service.
- **Playwright** (Node), with its bundled Chromium headless shell.
  - Node 24 and npm are installed on the server.
  - `~/.cache/ms-playwright` already has Chromium builds for recent Playwright versions; pin
    the version (exact, in `package-lock.json`) to one of those.
  - Playwright handles the Keycloak redirects, waits for Angular, records traces and
    screenshots on failure, and writes JUnit.
  - Selenium would need a WebDriver server, and Cypress can't cross origins as easily
    (edge → Keycloak → edge).
- **The tests live in this repository**, in `development/ui-test/`, next to the smoke script,
  not in polar-ui. They test the system, and they must work against the prebuilt image. If
  polar-ui moves into the repository later (step 5), they don't move.
- **The smoke script stays the single entry point.** A new selection, `ui`, adds edge (and with
  it catalog, order and polar-ui), and runs the browser tests after `test_edge`. Each browser
  test becomes one check in the summary and in `SMOKE_JUNIT`, as the curl checks are.
- **Memory.**
  - `all edge` takes about 2.5 GiB, and a headless shell with one page about 150–300 MiB
    more. That is close to the server's limit with other sessions running (2.2 GiB available
    when this was written). Check `free -h` first, and run it when the other worktrees are
    idle.
  - One worker, one browser, one context per user.
  - CI's runner (7 GiB) has room.

## Step 0: Find out whether a browser can log in

**Goal:** know before writing the tests whether login through Keycloak works in a headless
browser with this setup, and what it costs in memory.

- `smoke-test.sh up edge`, then a throwaway Playwright script in the scratchpad that opens
  `http://localhost:9000/`, clicks "Log In", fills in isabelle's credentials and expects the
  "Log Out" button.
- The browser resolves `host.docker.internal` with Chromium's
  `--host-resolver-rules="MAP host.docker.internal 127.0.0.1"`, as `edge_login` does with
  `--connect-to`.
- If Keycloak's `Secure` cookies are dropped (Keycloak shows "Cookie not found"), try in order:
  - `--unsafely-treat-insecure-origin-as-secure=http://host.docker.internal:8080`;
  - Firefox's `network.cookie.sameSite.schemeful` and secure-context prefs;
  - as a last resort, a change to the stack, such as Keycloak behind a self-signed TLS proxy.
    That would be a finding of its own: it would mean the book's setup can't be used from a
    browser with Keycloak 24.
- Record the browser's peak memory (`podman stats` for the stack, `ps` RSS for the browser).

**Done when:** the result is written down here: works / works with flag X / doesn't work.

Result (2026-10-23): **it didn't work, and now works after a change to the stack** (review
finding 35).
- Headless Chromium 153 (Playwright 1.63.0) reached Keycloak's form through the host resolver
  rule, but the login ended on "Cookie not found" (400). Keycloak 24 marked all its
  login-session cookies `Secure`, because the realm's `sslRequired: external` counts the host
  name `host.docker.internal` as external. `--unsafely-treat-insecure-origin-as-secure` didn't
  help.
- With `sslRequired: none` in the compose realm, the login worked and the page showed
  "Log Out".
- No browser could have logged in before. The curl checks passed only because `edge_login`
  passes the cookies on by hand.
- Memory: the whole `all edge` stack used 2.98 GiB of 3.7 GiB (Keycloak 920 MiB, each Spring
  app 300–330 MiB), and the browser added 290 MiB (PSS over its processes). 767 MiB stayed
  available, with MicroK8s stopped and no other session running.
- Seen on the way: the anonymous `GET /user` 401 also logs an Angular `ERROR` to the console,
  since `AppComponent` subscribes to it without an error handler. The tests have to expect it.

## Step 1: Check the SPA's files with curl

**Goal:** the smoke test catches a gateway route or a build that stops serving the app's files.
No new tooling, so it can go in before the browser tests.

- In `test_edge`, after `GET /`, read the `<script src>` and `<link rel=stylesheet href>` paths
  from the body (Python, as `edge_login` parses Keycloak's form) and `GET` each through edge
  anonymously. Check 200 and the content type (`text/javascript` / `application/javascript`,
  `text/css`). Check `/favicon.ico` too.
- Check that there is at least one script, so that an empty or wrong page fails.

**Done when:** `smoke-test.sh all edge` passes locally with the new checks, and fails when the
`spa-route` predicate is narrowed by hand.

## Step 2: Browser tests

**Goal:** the user flows of polar-ui are tested in a real browser against the running stack.

`development/ui-test/`:
- `package.json` / `package-lock.json` with `@playwright/test` at an exact version.
- `playwright.config.ts`:
  - `baseURL` from `UI_BASE_URL` (default `http://localhost:9000`), one worker, Chromium
    only;
  - the host resolver rule from step 0;
  - traces and screenshots on failure, to `UI_TEST_OUTPUT`;
  - list and JSON reporters.
- A fixture that, for every test:
  - aborts requests to `fonts.googleapis.com` / `fonts.gstatic.com`;
  - collects console errors and responses with status ≥ 400;
  - fails the test on any it doesn't expect. The only expected one is the anonymous `GET /user`
    401 and its console log.
- A `login(page, user)` helper that goes through the Keycloak form, as a user would.
- Test data: a unique ISBN per run (as `test_edge` does), created and removed by the tests
  themselves; the seeded books for reading.

Tests, in the order a user would meet them:

1. **Anonymous browsing.**
   - The toolbar shows "Polar Bookshop" and "Log In".
   - `#/browse-books` lists at least two book cards with title, author, ISBN and price.
   - The menu has "Browse Books" only.
2. **An employee manages the catalog** (isabelle).
   - Logs in, with "Add Book" and "My Orders" in the menu.
   - Adds a book through the form: back on the list with the new card.
   - Edits its price: the card shows the new price.
   - Removes it: the card is gone (after a reload, if the list bug above is confirmed;
     the test then records the bug and doesn't hide it).
   - All writes pass CSRF through Angular's own interceptor.
3. **A customer orders** (bjorn).
   - Logs in; no "Add Book".
   - Orders a seeded book with quantity 2 in the dialog.
   - Lands on `#/my-orders`, with a card for the order: status ACCEPTED, quantity 2, the total.
4. **Logout.** "Log Out" posts the form with `_csrf`, goes through Keycloak's logout and comes
   back to edge with "Log In" shown; `#/my-orders` then gets no orders.
5. **A 401 sends the user to login** (finding 1's deferred check). Anonymously, ordering a book
   makes `POST /orders` answer 401, and the interceptor sends the browser to Keycloak's login
   page.
6. **A catalog failure doesn't look like a logout** (finding 1).
   - With `polar-postgres` paused, catalog-service answers 500, and `#/browse-books` stays on
     the page without a redirect to Keycloak.
   - The test unpauses it in a `finally`, as `test_edge` does with `PAUSED`, so the trap in
     the script must cover it too.
7. **Circuit breaker fallback** (finding 32).
   - With `catalog-service` paused, record what the list shows.
   - Expected today: a spinner and no error, because of the `""` body.
   - With finding 32's fix it becomes an empty list; the test changes with the fix.

Tests 6 and 7 pause containers, so they run last, in their own `describe` with `serial` mode.

**Done when:** all pass locally, or fail only on bugs that are recorded as findings in the
review plan (or a new one), with the test marked `test.fail()` and a link to the finding until
it's fixed.

## Step 3: Run them from the smoke script

**Goal:** `smoke-test.sh all edge ui` runs the curl checks and the browser tests together, with
one summary and one JUnit file.

- **New selection `ui`.** It implies edge. The usage text, the header comment and the skill's
  `SKILL.md` describe it, with its memory cost.
- **`test_ui`** after `test_edge`:
  - `npm ci` (when `node_modules` is older than the lock file);
  - `npx playwright install chromium-headless-shell` (a no-op when cached);
  - `npx playwright test` with the JSON reporter, its output parsed into one `check` per test.
    The section is "polar-ui (browser)", and a failure's detail is the first line of the
    error.
- `check_memory` adds the browser's share when `ui` is selected.
- `logs DIR` copies Playwright's traces and screenshots, if any, into `DIR/ui/`.
- The `PAUSED` trap also covers a container paused by the browser tests: they write its name to
  a file in `$WORK`, which `on_exit` reads.
- A missing Node fails the section with a clear message, not the whole run.

**Done when:** `smoke-test.sh all edge ui` passes locally, `SMOKE_JUNIT` has a case per browser
test, and a deliberately broken test shows up as a FAIL with its trace in `logs`.

## Step 4: Run them in CI

**Goal:** every push runs the browser tests in the existing edge smoke job, with no new job.

- **The smoke matrix's `edge` entry becomes `edge ui`.**
- **Setup:**
  - `actions/setup-node` with the Node version from `.nvmrc` in `development/ui-test/`;
  - `actions/cache` for `~/.cache/ms-playwright`, keyed on the Playwright version;
  - `npx playwright install-deps chromium-headless-shell` only if the runner lacks a library.
- **Reports:** traces and screenshots go into `smoke/logs/ui/`, which is already uploaded.
- **Cost:** about 1–2 runner-minutes per run (npm install, browser download when not cached,
  about 30 s of tests). Following the CI budget: verify locally first, push together with other
  work, and ask before any probe run.

**Done when:** a run is green with the browser checks in the summary, and the next two runs too,
so that flakiness shows early. The edge job has stalled before (finding 34).

Then mark finding 1's deferred check as done in `review-2026-10-19.md`, with what the browser
showed.

## Step 5 (decision): Bring polar-ui into the repository

Steps 0–4 test the image the book published in 2022. That is enough to guard the backend's
side during the Spring Boot 3 update. It isn't enough to change polar-ui itself: fixing the bugs
above, or updating Angular 13 and Node 16 (both out of support), as "all components are to be
updated" implies.

Options:
- **A. Leave polar-ui out.** Keep testing the `v1` image. Bugs in polar-ui are recorded but not
  fixed. Cheapest; the UI stays frozen at Angular 13.
- **B. Copy it into `PolarBookshop/polar-ui`**, as the other services were, and build its image
  from source in the smoke tests and CI. Fixes and updates become ordinary commits here, tested
  by steps 1–4.
- **C. Fork it on GitHub** and depend on the fork's image. Keeps it separate, but adds a second
  repository, a registry and cross-repository CI, and doesn't fit the CI minutes budget.

Recommendation: **B**, after steps 0–4, so the browser tests exist before anything in polar-ui
changes.

What B needs:
- **Image build.** The book uses `pack` with the Paketo nginx buildpack and
  `paketobuildpacks/builder:base`, which is deprecated, and `pack` isn't installed. Simpler: a
  `Containerfile` with an nginx base image, `podman build`, and `nginx.conf` with the port
  fixed at 9004 instead of the buildpack's `{{port}}` template.
- **Build cost.** `ng build` with Node 16 takes about 1 GiB; it runs one at a time like the
  other image builds, and in CI as a matrix entry of `images`.
- **The smoke script.** It builds `polar-ui` like the other services (`build polar-ui`, the
  `ALL_APPS` and `--rebuild` handling), and the compose file uses the local image.

## Step 6 (after step 5): Make polar-ui's own tests worth having

The app is small, about 300 lines of TypeScript, and mostly passes data between HTTP and
templates. Most of its risk is in integration (routes, cookies, redirects, CSRF), which only the
browser tests reach. So unit tests are worth a modest effort, not a large suite:

- **Make them run.**
  - `ng test --watch=false --browsers=ChromeHeadless`, with `singleRun: true` in CI;
  - JUnit output (`karma-junit-reporter`);
  - call `testAngular` from the build, and run it in CI before the image build.
- **Make the existing specs pass:** `HttpClientTestingModule`, `RouterTestingModule`, the
  Material modules or `NO_ERRORS_SCHEMA`, and a `MatDialogRef`/`MAT_DIALOG_DATA` stub. Delete
  the welcome-text expectation.
- **Add tests where there is logic:**
  - `HttpInterceptorImpl`: 401 on `/user` logs and doesn't redirect; 401 elsewhere calls
    `login()`; `X-Requested-With` is set.
  - `AppComponent`: "Log In" vs "Log Out", "Add Book" only for `employee`, from a stubbed
    `/user`.
  - `BookService`, `OrderService`: method and URL of each call (`HttpTestingController`).
  - `BookListComponent`: remove refreshes the list (the regression test for the bug above,
    once fixed).
  - `OrderListComponent`: the total's formatting.
  - `OrderDialogComponent`: submits the request and closes.
- **Delete `e2e/`** and Protractor; the browser tests of step 2 replace them.
- **Drop `tslint`** and `codelyzer`. Linting with `angular-eslint` can come with the Angular
  update, since its setup depends on the version.

Keep the test setup minimal before the Angular update. Newer Angular versions replace Karma
(Vitest is the default from Angular 21), so effort on Karma configuration is short-lived. The
specs themselves (TestBed, `HttpTestingController`) carry over.

## Later

- **The Angular and Node update**, one major version at a time, each verified by the unit tests
  and the browser tests. A plan of its own, part of the dependency update.
- **edge-service and polar-ui on Kubernetes** (`--k8s`), already in the CI plan's future work.
  The browser tests take `UI_BASE_URL`, so they can run against the cluster's ingress too.
- **Visual or accessibility checks** (Playwright screenshots, axe-core). Not needed for
  confidence that the system works; maybe with the Angular update, whose Material changes alter
  the look.

## Open questions

- Step 0's result decides whether the browser tests need a flag or a change to the stack.
- Step 5: A, B or C.
- Should the bugs found by reading the code go into the review plan now, as findings, or after
  the browser tests confirm them?
