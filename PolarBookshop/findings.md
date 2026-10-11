# Findings

Issues found while running the smoke tests (`.claude/skills/smoke-test/`).

## Open

None.

## Resolved

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
