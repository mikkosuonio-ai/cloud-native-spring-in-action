---
name: smoke-test
description: Start PolarBookshop catalog-service with Podman (postgres + keycloak + the catalog-service image) and run an HTTP smoke test covering health, book reads, auth/role checks and CRUD. Use when asked to smoke test, run, or verify catalog-service end to end.
---

# catalog-service smoke test (Podman)

This server has Podman 4.9 and podman-compose, and no Docker. The script `smoke-test.sh` in this
skill directory does the whole job. Run it from the worktree root:

```bash
bash .claude/skills/smoke-test/smoke-test.sh all            # up + test, leaves the stack running
bash .claude/skills/smoke-test/smoke-test.sh all --rebuild  # rebuild the image from this worktree's code first
bash .claude/skills/smoke-test/smoke-test.sh test           # rerun the tests against a running stack
bash .claude/skills/smoke-test/smoke-test.sh down           # remove the containers
```

Pass `--rebuild` when the user wants to test the current code in the worktree. Without it, the
script reuses any existing `catalog-service` image, which may have been built from another
worktree or an older commit.

## Steps

1. **Check memory first.** The machine has ~4 GB RAM and no swap. Run `free -h` and make sure no
   Gradle daemons or other containers are holding memory. The stack needs about 1.5 GiB available,
   and an image build needs more.
2. Run `smoke-test.sh all` (add `--rebuild` if needed) with a Bash timeout of about 10 minutes.
   The first build pulls the Paketo builder.
3. Report the PASS/FAIL lines to the user. The script exits non-zero if any check fails. On a
   failure, look at `podman logs catalog-service` before reporting.
4. Ask the user whether to keep the stack running or run `smoke-test.sh down`.

## What the script does (and why)

- Starts `podman.socket` and builds the image with `bootBuildImage`. It points Gradle at the Podman
  socket with `bindHostToBuilder = true` through a temporary init script, so `build.gradle` is not
  changed.
- Starts only `polar-postgres` and `polar-keycloak` with podman-compose.
- Starts `catalog-service` with `podman run` on the `docker_default` network, copying the compose
  environment. It can't use compose for this service because:
  - the compose file uses the `fluentd` log driver, which Podman 4.9 rejects;
  - podman-compose merges `depends_on` from override files instead of replacing them, so an
    override can't drop tempo and fluent-bit.

  Tempo and fluent-bit are therefore not started, and OTel exporters are set to `none`. If
  environment variables for catalog-service change in the compose file, update the script to match.
- Adds the public `polar-test` client to Keycloak through the admin API, the same client the
  integration tests use. The imported realm has no password-grant client. The change exists only
  inside the dev container.
- Requests tokens with `Host: host.docker.internal:8080`, so the token issuer matches the
  service's configured `issuer-uri`.

## Checks

GET `/` greeting; health, db, liveness and readiness are UP; GET `/books` returns the testdata
books; GET a known and an unknown ISBN (200/404); POST without a token (401); POST and DELETE as
customer bjorn (403); POST as employee isabelle (201, `createdBy` set); GET the created book; PUT
(200, version 2); POST an invalid book (400); DELETE as isabelle (204); then GET returns 404.
