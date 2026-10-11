---
name: smoke-test
description: Start PolarBookshop catalog-service, order-service and dispatcher-service with Podman (with postgres, keycloak and rabbitmq) and run HTTP smoke tests covering health, auth/role checks, book CRUD, order placement and the order-accepted/order-dispatched messaging. Use when asked to smoke test, run, or verify catalog-service, order-service or dispatcher-service end to end.
---

# PolarBookshop smoke test (Podman)

This server has Podman 4.9 and podman-compose, and no Docker. The script `smoke-test.sh` in this
skill directory does the whole job. Run it from the worktree root:

```bash
bash .claude/skills/smoke-test/smoke-test.sh all              # up + test all services, leaves the stack running
bash .claude/skills/smoke-test/smoke-test.sh all catalog      # catalog-service only (postgres + keycloak)
bash .claude/skills/smoke-test/smoke-test.sh all dispatcher   # dispatcher-service only (rabbitmq)
bash .claude/skills/smoke-test/smoke-test.sh all --rebuild    # rebuild the selected images from this worktree's code first
bash .claude/skills/smoke-test/smoke-test.sh test             # rerun the tests against a running stack
bash .claude/skills/smoke-test/smoke-test.sh down             # remove all the containers
```

Services default to `catalog order dispatcher`; any combination can be given. Selecting `order`
also selects `catalog`, because order-service looks books up in catalog-service.

Pass `--rebuild` when the user wants to test the current code in the worktree. Without it, the
script reuses existing images, which may have been built from another worktree or an older commit.

## Steps

1. **Check memory first.** The machine has ~4 GB RAM and no swap. Run `free -h` and make sure no
   Gradle daemons or other containers are holding memory. The full stack needs about 2.3 GiB
   available (catalog only: about 1.5 GiB, dispatcher only: about 0.7 GiB), and an image build
   needs more. The script removes the selected app containers before building. Its estimate
   doesn't account for backing services that are already running, so its warning can be
   overcautious on a rerun.
2. Run `smoke-test.sh all` (add `--rebuild` if needed) with a Bash timeout of about 10 minutes.
   The first build of each service pulls its Paketo builder.
3. Report the PASS/FAIL lines to the user. The script exits non-zero if any check fails. On a
   failure, look at `podman logs <service>` before reporting.
4. Ask the user whether to keep the stack running or run `smoke-test.sh down`.

## What the script does (and why)

- Starts `podman.socket` and builds missing images with `bootBuildImage`. It points Gradle at the
  Podman socket with `bindHostToBuilder = true` through a temporary init script, so `build.gradle`
  is not changed.
- Pulls missing backing-service images with a `docker.io/` prefix. Podman here has no
  unqualified-search registries, so short names such as `rabbitmq:3.13-management` only resolve
  once the image is in local storage.
- Starts only the backing services the selection needs with podman-compose: `polar-postgres` and
  `polar-keycloak` for catalog and order, and `polar-rabbitmq` for order and dispatcher. It then checks that each container is running, because podman-compose exits 0
  even when a container fails to start.
- Starts the app services with `podman run` on the `docker_default` network. It generates the
  arguments (env, ports, extra hosts, image) from the compose file with PyYAML. It can't use
  compose for the apps because:
  - the compose file uses the `fluentd` log driver, which Podman 4.9 rejects;
  - podman-compose merges `depends_on` from override files instead of replacing them, so an
    override can't drop tempo and fluent-bit.

  On top of the compose settings it:
  - sets the OTel exporters to `none`, since tempo and fluent-bit aren't started;
  - always adds `host.docker.internal:host-gateway`, because order-service's compose entry lacks it
    but its JWT issuer uses that host;
  - sets `--memory 1g`, because otherwise the buildpack memory calculator sizes the heap from host
    RAM (over 2 GB).
- Waits until each service's RabbitMQ consumer is attached: `order-dispatched.order-service` and
  `order-accepted.dispatcher-service`. The services report ready even before RabbitMQ is reachable.
- Reads messages through temporary `smoke-test.*` queues bound to the `order-accepted` and
  `order-dispatched` exchanges, and deletes the queues afterwards.
- Adds the public `polar-test` client to Keycloak through the admin API, the same client the
  integration tests use. The imported realm has no password-grant client. The change exists only
  inside the dev container.
- Requests tokens with `Host: host.docker.internal:8080`, so the token issuer matches the
  services' configured `issuer-uri`.

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

Orders created by the tests stay in the database; order-service has no delete endpoint.
