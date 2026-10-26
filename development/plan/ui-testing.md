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
| Login works in a real browser | Keycloak 24 marks its login-session cookies `Secure`, over plain http, on `host.docker.internal` | curl stores them by hand (see `edge_login`). Browsers refuse `Secure` cookies from an insecure origin other than localhost, and Keycloak 24 no longer sends the `_LEGACY` fallback cookies. **Step 0 confirmed it: no browser could log in (finding 35, fixed)** |
| Angular's own CSRF handling | `HttpClientModule`'s XSRF interceptor; the logout `<form>` posting `_csrf` from the cookie | The smoke test sends the header itself. Spring Security 6 (with Boot 3) masks CSRF tokens by default, which breaks SPAs that send the raw cookie value. The update needs this guarded |
| The 401 handling | `HttpInterceptorImpl`: a 401 on anything but `/user` sends the browser to `/oauth2/authorization/keycloak` | Finding 1's deferred check. Before its fix, a catalog outage would send the user to the login page |
| Role-dependent UI | "Add Book" for `employee`, "My Orders" when logged in | The `/user` response is checked, not what the UI makes of it |
| Hash routes and deep links | `useHash: true`, so `/#/my-orders` | n/a |
| Error and fallback states | `GET /books` fallback body `""` (finding 32) | Angular parses an empty JSON body as `null`, so `books` becomes `null` and the book list shows only a spinner. Confirmed by step 2 |

Likely bugs, found by reading the code and to be confirmed by the tests:
- **Remove doesn't update the list.** `removeBook` deletes and then navigates to
  `/browse-books`, the page it's on. Angular ignores navigation to the current URL by default, so
  the removed book stays on screen until a reload. Confirmed by step 2: review finding 37.
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

Result (2026-10-23): done.
- Two checks in `test_edge`:
  - "SPA page references scripts and CSS" (at least one of each);
  - "SPA's files served through edge", whose failure lists each file with its status and
    content type.

  The page of the `v1` image references three scripts, a stylesheet and the favicon.
- `all edge` passed with 89 checks.
- With edge-service restarted with `spa-route` narrowed to `Path=/,/favicon.ico` (through
  `SPRING_CLOUD_GATEWAY_ROUTES_0_*`, which also drops the other routes), the two old SPA checks
  still passed, and the new one failed with the four files at 404.

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

Result (2026-10-23): done. Ten tests in `development/ui-test/` (Playwright 1.63.0, its
Chromium headless shell). They passed in three full runs against `smoke-test.sh all edge`, in
about 50 s each. Two of them are expected failures, each failing for its finding's reason. The
curl smoke checks passed afterwards (89).

| File | Tests |
|---|---|
| `01-anonymous` | "Log In" and only "Browse Books" in the menu; the catalog's cards with their details |
| `02-employee` | isabelle adds, edits and removes a book through the forms and the card menu (201, 200, 204, CSRF by Angular itself); **expected failure:** the list drops a removed book (finding 37) |
| `03-customer` | bjorn orders 2 copies in the dialog and finds the order in "My Orders", with its status and total |
| `04-session` | "Log Out" goes through Keycloak's logout and ends both sessions; a 401 from `GET /orders` sends an anonymous visitor to Keycloak's login page |
| `05-outages` | a catalog 500 on "Create Book" leaves the employee logged in (finding 1); the fallback answers without books while catalog-service is paused; **expected failure:** the list shows an empty list then, not a spinner (finding 32) |

How it differs from the list above:
- **Test 6 closes catalog-service's database** (`ALTER DATABASE ... ALLOW_CONNECTIONS false`,
  plus ending its sessions) instead of pausing `polar-postgres`.
  - Pausing gives no 500: catalog's queries hang, and edge-service's time limit serves the
    fallback.
  - Stopping PostgreSQL gives catalog's 500, but order-service then fails its first orders
    after the restart (new finding 36).
  - A GET never shows the 500 in the browser either way: edge-service's Retry filter repeats it
    until the fallback. So the test uses a write, "Create Book".
- **Test 7 is two tests:**
  - a plain one that checks the fallback happens;
  - the expected failure for what the page shows, which only fails for its finding's reason.

  The page has to be checked after the fallback's response: until then `books` is `[]` and
  the empty list shows.
- **The anonymous 401 test opens `#/my-orders`** rather than ordering: the same interceptor
  path, with fewer steps.

What the browser tests found:
- The login (finding 35, step 0).
- **Removing a book doesn't update the list** (new finding 37). It's in polar-ui, so it waits
  for step 5.
- **Finding 32's effect in the SPA:** the spinner stays for good.
- **The anonymous `GET /user` also logs an Angular `ERROR`.** It's allowed, as are the 401's
  own console line and response.
- **The build inlines Google's font CSS into index.html,** so the page also fetches from
  `fonts.gstatic.com`. The tests block both font hosts and ignore those requests.

How the tests check the browser:
- **Unexpected problems fail a test.** A fixture fails each test on any response ≥ 400, failed
  request, page error or console error that the test doesn't expect. The tests declare
  expected failures with `problems.allow(...failedCall(method, path, status))`.
- **Angular's error log is made readable.** An init script turns each `HttpErrorResponse` that
  Angular logs into its status and URL, so that the log can be matched. Reading the object
  afterwards fails when the page has navigated away, as on the 401 redirect.
- **Outages are undone.** `withPaused` and `withCatalogDatabaseClosed` undo their change in a
  `finally`, and note the undo command in `UI_UNDO_FILE` meanwhile. The smoke script runs what
  is left in that file (step 3).
- **The tests' books are removed.** Their ISBNs start with 97, and a fixture deletes every such
  book from catalog's database before and after each test. A test that fails before removing
  its book, or a killed run, leaves nothing for the next test or run, and ISBNs can't collide
  with leftovers. It deletes in PostgreSQL rather than through the API, because by the end a
  test may have logged out or broken catalog-service. A test that added a book and then failed
  left none behind, and neither did a run after a planted leftover.

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

Result (2026-10-23): done. `smoke-test.sh all ui` passes with 99 checks: edge's 89 and one per
browser test, 10. `SMOKE_JUNIT` has the 10 as test cases of the class `polar-ui`.
- **A test passes as "passed" or, when it's marked `test.fail` for an open finding, as "expected
  failure".** Such a test that passes fails its check, with a reminder to remove the mark.
- **A deliberately broken test was a FAIL** with the first line of its error
  (`expect(locator).toBeVisible() failed`). `logs DIR` copied its trace and screenshot to
  `DIR/ui/`.
- **Killing Playwright with SIGKILL** while catalog-service was paused, and again while catalog's
  database was closed: the script undid both, and the section failed with one check, "browser
  tests ran", giving Playwright's exit status 137 and where its output is.
- **Without Node.js** the section is a single FAIL, "Node.js and npm installed", and the other
  sections run.
- **Memory:** 2.8 GiB available before `all ui` (MicroK8s stopped), 0.7 GiB after it, with the
  stack still running.

How it differs from the list above:
- **Playwright runs from `node_modules/.bin`**, not through `npx`, which could fetch a package
  of its own.
- **The undo file replaces the `PAUSED` idea.** The tests already note the podman arguments that
  undo each change, which covers the closed database too. The script runs what is left in the
  file after the tests, and in `on_exit`.
- **The results stay in `development/ui-test/test-results/`**, Playwright's default, with the
  list reporter's output added as `output.log`, because `$WORK` is gone by the time `logs` runs.
- **A run without a report** (killed, or a configuration that doesn't load) gives one failing
  check, and errors outside the tests, such as a spec file that doesn't compile, one check each.

Left open: `npx playwright test` by hand runs without the script's lock. The config's header and
the skill say so.

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

Result (2026-10-24): **one green run, not three.** The user had 170 Actions minutes for this
step, and a full run takes about 60, so three green runs didn't fit after two that failed for
other reasons. Finding 1's deferred check was already marked done in step 2.
- **Run 40073295069 (18bc88c, about 36 minutes):** catalog-service's image didn't build, so no
  smoke test ran. Paketo had pushed `builder-noble-java-tiny:latest` as an arm64-only image the
  day before. Fixed by pinning catalog-service's builder to `0.0.200` (b7e0d4f; see
  `PolarBookshop/findings.md`).
- **Run 40073825096 (b7e0d4f, about 59 minutes):** the edge job's Node.js, package and browser
  steps passed, but quay.io answered the Keycloak pull with 503, before any test ran. The other
  smoke jobs passed with the new catalog-service image. Fixed by retrying the script's image
  pulls three times (cf59230).
- **Run 40074491065 (cf59230, about 58 minutes):** every job passed. The edge job ("edge ui")
  passed all 99 checks, with the 10 browser tests. The Node.js setup, `npm ci` and the browser with its libraries took about 15 s,
  and the job about 4.5 minutes instead of 3.3.

How it differs from the list above:
- **No cache for the browser.** Downloading it with its libraries took seconds, about what
  restoring a cache would.
- **`playwright install --with-deps` always**, in a step of its own before the smoke test,
  rather than only once a library turns out to be missing: finding out would have cost a run.
  Whether the runner image has all the libraries wasn't checked. The script doesn't install
  them, since that needs sudo.

Still to do: two more green runs, to show flakiness early, when there are minutes for them.
They can go with the next pushes of other work.

- **Run 40248954904 (c66359e, the weekly schedule, 2026-10-26, about 9 minutes):** every job
  passed, the edge ui job in 4.4 minutes. The repository had gone public the day before, and
  the run billed 0 minutes.
- **Run 40303735772 (d9fa46a, 2026-10-26, about 6 minutes, 0 billed):** every job passed,
  edge ui too. That is the third green run in a row, so step 4 is done.

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

Decision (2026-10-26): **C, with public repositories.** The recommendation was B because of the
CI minutes. Public repositories run on GitHub's standard runners for free, so the user made this
repository public (2026-10-25, after a scan of its history found no secrets) and forked polar-ui
to the public [mikkosuonio-ai/polar-ui](https://github.com/mikkosuonio-ai/polar-ui), cloned at
`/home/ai/devel/polar-ui`. The cost that stays: a change that touches both the UI and the
backend needs a release of the fork and a tag bump here, in that order.

In the fork, first without changes to the UI:
- **`Containerfile`**, replacing the buildpack image:
  - a build stage on `node:16.14.0` running `npm ci` and `ng build`;
  - an nginx stage, with a pinned version, holding the build and `mime.types`;
  - `nginx.conf` as a template in `/etc/nginx/templates/`, where the image's `envsubst` fills in
    `listen ${PORT}`, instead of the buildpack's `{{port}}`;
  - `ENV PORT=9004`, so the compose file and the k8s manifests stay as they are.
- **`.github/workflows/commit-stage.yml`**, replacing upstream's (`pack`, the deprecated
  `builder:base`, old actions):
  - every push builds the SPA and the image;
  - `main` pushes `ghcr.io/mikkosuonio-ai/polar-ui:sha-<7>`, and a `v*` tag pushes the tag too;
  - the package is public, so this repository pulls it without credentials;
  - unit tests and lint wait for step 6.
- **A README note** that this is a fork, and how to build the image locally.
- **Verify:**
  - build `localhost/polar-ui:dev`;
  - here, `SMOKE_POLAR_UI_IMAGE=localhost/polar-ui:dev smoke-test.sh all ui` gives the same 99
    passes as `v1`.
- **Release** that as `v1.1`.

Then here:
- the compose file and the two k8s manifests under `polar-deployment/kubernetes/platform` use
  `ghcr.io/mikkosuonio-ai/polar-ui:v1.1`;
- `all ui` and CI's edge ui job pass on it.

Commits in the fork come from a Claude session started in its clone, since a session in a
worktree here runs git only in that worktree.

## Step 6 (after step 5): Make polar-ui's own tests worth having

In the fork (see step 5's decision).

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
- ~~Step 5: A, B or C.~~ C, with a public fork (2026-10-26).
- Should the bugs found by reading the code go into the review plan now, as findings, or after
  the browser tests confirm them?
