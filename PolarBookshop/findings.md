# Findings

Issues found while running the smoke tests (`development/script/smoke-test.sh`, run through the
`smoke-test` skill in `.claude/skills/smoke-test/`).

## Open

None.

## Resolved

### Keycloak ran out of memory on Kubernetes on GitHub's runners

Found and fixed 2026-10-19 with the `smoke-k8s` CI job, which runs `smoke-test.sh all --k8s` on
MicroK8s on a GitHub runner.

**Symptom:** `polar-keycloak` was OOM-killed at its 750Mi memory limit about 20 seconds after each
start, while it was still building its configuration, and ended up in CrashLoopBackOff. The apps
started without restarts. On the development server, the same image with the same limit started
without restarts.

**Cause:** `kc.sh` sizes Keycloak's heap as a percentage of the memory the JVM sees: in a
container, at most 70% and initially 50%. The image's JVM, OpenJDK 17.0.14, reads `/proc/cgroups`
to check that the memory and cpu controllers are enabled. On the runner's kernel, 6.17, it
concluded that they were disabled and ignored the container's limits. It sized the heap from the
runner's 7.75 GiB of RAM instead: 5.4 GiB at most and 3.9 GiB initially. On the development
server's kernel, 6.8, it detects the limit and sizes the heap to 526 MiB at most and 376 MiB
initially. Under Podman with the same limit, Keycloak was killed the same way on the runner.

**Fix:** the Deployment in `platform/development/services/keycloak.yml` passes its memory limit
to the JVM with `JAVA_OPTS_APPEND=-XX:MaxRAM=$(MEMORY_LIMIT)`, where `MEMORY_LIMIT` is the
container's `limits.memory` from the Downward API. The JVM then sizes the heap from the limit
whether or not it detects it. On the development server, the heap stays the same. Under Podman on
the runner, Keycloak then started within the 750Mi limit, with a peak of 622 MiB.

### Kubernetes restarted the apps when they started slowly

Found 2026-10-12 with `smoke-test.sh all --k8s` on MicroK8s, fixed 2026-10-18.

**Symptom:** when catalog, order, dispatcher and config started at the same time as Keycloak on a
2-CPU node, each app container was restarted 3-4 times ("failed liveness probe, will be
restarted", exit code 143) before it stayed up. Started one at a time they didn't restart, and
catalog-service then started in about 18 seconds.

**Cause:** the `k8s/deployment.yml` of each app had a liveness probe with
`initialDelaySeconds: 10` and `periodSeconds: 5`, and no startup probe. With the default failure
threshold of 3, a container whose actuator wasn't answering after about 25 seconds was killed,
and the restart started the slow JVM startup over. The readiness probe alone would have been
enough to keep traffic away during startup.

**Fix:** the `k8s/deployment.yml` of catalog, order, dispatcher, config and edge has a
`startupProbe` on `/actuator/health/liveness` with `periodSeconds: 5` and `failureThreshold: 30`,
as `polar-keycloak` has. The liveness probe starts only once the app is up, and a start may take
up to 150 seconds. A cold `smoke-test.sh all --k8s` then passed 93 checks with no restarts. The
apps took 36-43 seconds to start, longer than the old liveness probe allowed, and their startup
probes failed until they were up.

### RabbitMQ management was off in the Kubernetes development setup

Found and fixed 2026-10-12 with `smoke-test.sh all dispatcher --k8s`.

**Symptom:** nothing answered on port 15672 of `polar-rabbitmq`, although its Service exposes the
port as `management`.

**Cause:** `platform/development/services/rabbitmq.yml` mounts its ConfigMap over the whole of
`/etc/rabbitmq`, which hides the image's `enabled_plugins` file, so RabbitMQ ran with no plugins.

**Fix:** the ConfigMap also holds `enabled_plugins`, with the image's
`[rabbitmq_management,rabbitmq_prometheus]`.

### order-service could lose an order-dispatched event

Fixed in `81cd148`, 2026-10-11.

**Symptom:** in about four of ten smoke-test runs with order-service and dispatcher-service, an
order stayed ACCEPTED for good. dispatcher-service had dispatched it, and order-service had
received and acknowledged the order-dispatched event, but logged neither an update nor an error.

**Cause:** `OrderService.submitOrder` was `@Transactional` and sent the order-accepted event from
inside the transaction. With reactive transactions the RabbitMQ send isn't part of the database
transaction (the `transacted: true` producer has no thread-bound transaction to join), so the
event went out before the order was committed. dispatcher-service answers within milliseconds.
When its order-dispatched event got there first, `findById` found no order, and the event was
dropped silently. It hit most often right after an event for an unknown order id, because that
lookup had already warmed up the consumer's database connection, so the next lookup beat the
commit.

**Fix:** `submitOrder` is no longer `@Transactional`. Its single `save` commits on its own, so the
event is sent only after the order is visible. `OrderAcceptedEventTests` checks, from a separate
JDBC connection, that the order is committed at the moment the event is sent. It failed before
the fix. Afterwards, three cold and six warm smoke-test runs all passed.

**Still worth knowing:** messages enter order-service's reactive consumer already acknowledged, so
any message it drops (for example, if a database error ends the stream) isn't delivered again.
Future work item 3 in the smoke-test skill covers restart and broker-outage behaviour.
