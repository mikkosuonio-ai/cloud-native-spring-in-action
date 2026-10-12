# Findings

Issues found while running the smoke tests (`.claude/skills/smoke-test/`).

## Open

### Kubernetes restarts the apps when they start slowly

Found 2026-10-12 with `smoke-test.sh all --k8s` on MicroK8s.

**Symptom:** when catalog, order, dispatcher and config start at the same time as Keycloak on a
2-CPU node, each app container is restarted 3-4 times ("failed liveness probe, will be
restarted", exit code 143) before it stays up. Started one at a time they don't restart, and
catalog-service then starts in about 18 seconds.

**Cause:** the `k8s/deployment.yml` of each app has a liveness probe with
`initialDelaySeconds: 10` and `periodSeconds: 5`, and no startup probe. With the default failure
threshold of 3, a container whose actuator isn't answering after about 25 seconds is killed, and
the restart starts the slow JVM startup over. The readiness probe alone would have been enough to
keep traffic away during startup.

**Possible fix:** add a `startupProbe` on `/actuator/health/liveness` with room for a slow start
(for example `periodSeconds: 5`, `failureThreshold: 30`), as `polar-keycloak` already has, so the
liveness probe only starts once the app is up.

## Resolved

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
