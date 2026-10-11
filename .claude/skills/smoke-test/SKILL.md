---
name: smoke-test
description: Start PolarBookshop services (catalog, order, dispatcher, config, edge with polar-ui, quote, quote-function) with Podman and run HTTP smoke tests covering health, auth/role checks, book CRUD, order placement, order-accepted/order-dispatched messaging, config serving, and the edge gateway's OAuth2 login, token relay, CSRF and circuit breaker, and the quote endpoints of quote-service and quote-function's Spring Cloud Function endpoints. Use when asked to smoke test, run, or verify any of those services end to end.
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
  - sets the OTel exporters to `none`, since tempo and fluent-bit aren't started;
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

## Checks

**catalog-service:** GET `/` greeting; health, db, liveness and readiness are UP; GET `/books`
returns the testdata books; GET a known and an unknown ISBN (200/404); POST without a token (401);
POST and DELETE as customer bjorn (403); POST as employee isabelle (201, `createdBy` set); GET the
created book; PUT (200, version 2); POST an invalid book (400); DELETE as isabelle (204); then GET
returns 404.

**order-service:**
- health, r2dbc, rabbit, liveness and readiness are UP;
- GET and POST `/orders` without a token return 401;
- an order as bjorn for ISBN 1234567891 is ACCEPTED, with the book name and price taken from
  catalog-service and `createdBy` set;
- the `order-accepted` event carries the new order id (read from a temporary queue bound to the
  exchange);
- an unknown ISBN gives a REJECTED order;
- quantity 0, quantity 6 and a missing ISBN return 400;
- bjorn sees the order and isabelle doesn't;
- the order becomes DISPATCHED. With dispatcher-service running, this is the real end-to-end flow.
  Without it, the test stands in for dispatcher-service by publishing `{"orderId": id}` to the
  `order-dispatched` exchange.

**dispatcher-service:**
- health, rabbit, liveness and readiness are UP;
- the `packlabel-in-0` binding is running;
- publishing `{"orderId": id}` to `order-accepted` makes it emit `order-dispatched` with the same
  id. The id is above 900000000, so order-service ignores it if running.

**config-service:** It serves https://github.com/PolarBookshop/config-repo (cloned at startup, so
it needs network access), not the local `PolarBookshop/config-repo/` directory. The two differ in
`catalog-service.yml`'s greeting, so the tests check structure rather than exact values:
- health, liveness and readiness are UP;
- `/catalog-service/default` comes from `catalog-service.yml` with a `polar.greeting`;
- `/catalog-service/prod` puts `catalog-service-prod.yml` first, still includes the default
  source, and overrides the greeting;
- the `main` label returns 200 and an unknown label returns 404;
- an unknown application returns 200 with no property sources;
- `/catalog-service-default.yml` contains the greeting.

None of the other services use config-service here. Their `spring.cloud.config.enabled` is false,
and catalog-service doesn't include the config client.

**edge-service:**
- health, redis, liveness and readiness are UP, and the spa, catalog and order routes are
  configured;
- `/` serves polar-ui's HTML;
- `/books` works anonymously and carries `X-RateLimit-Remaining`;
- anonymous `/user`, `/orders` and POST `/books` return 401;
- isabelle and bjorn log in via Keycloak, and `/user` returns the right username and roles;
- a POST without the CSRF header returns 403;
- through token relay, isabelle creates and deletes a book (201/204), bjorn is refused (403), and
  bjorn places an order and sees it listed;
- logout returns 302 to Keycloak's end-session endpoint, after which `/user` returns 401;
- with catalog-service paused, GET `/books` falls back to an empty 200 and POST returns 503; after
  unpausing, books come back.

**quote-service:**
- GET `/quotes` returns the six quotes, each with content, author and genre, two per genre;
- `/quotes/random` returns a known author;
- `/quotes/random/{genre}` returns a quote of that genre for ADVENTURE, FANTASY and
  SCIENCE_FICTION, and an unknown genre (POETRY) returns 400;
- random quotes eventually include the last quote (Flora) and both FANTASY quotes. These are
  regression checks for an off-by-one in `nextInt(size - 1)` that never picked the last quote.

quote-service has no actuator, so readiness is a 200 from `/quotes`.

**quote-function** (Spring Cloud Function over HTTP, no actuator; readiness is a 200 from
`/randomQuote`):
- GET `/` runs the default function `allQuotes` and returns the six quotes, two per genre (allQuotes
  delays its output by one second); GET `/allQuotes` returns them too;
- GET `/randomQuote` returns a known author;
- POST `/genreQuote` with `"<GENRE>"` returns a quote of that genre for each of the three genres;
- an unknown genre (POETRY) returns 500, because the enum conversion fails. The check records this
  current behaviour; quote-service answers 400 for the same input;
- POST `/logQuote` and the composed `/genreQuote,logQuote` return 202 and each log one more quote
  line (checked in `podman logs`, so reruns against the same container still pass);
- randomQuote eventually returns the last quote (Flora) and genreQuote FANTASY returns both quotes,
  as regression checks for the same `nextInt(size - 1)` off-by-one.

Orders created by the tests stay in the database; order-service has no delete endpoint.
