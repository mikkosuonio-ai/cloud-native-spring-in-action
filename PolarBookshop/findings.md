# Findings

Open issues found while running the smoke tests (`.claude/skills/smoke-test/`).

## order-service can lose an order-dispatched event

**Seen:** 2026-10-11, in four of about ten runs that include order-service and
dispatcher-service, cold starts and warm stacks alike.

**Pattern:** the lost order is always the one placed right after order-service consumed an
`order-dispatched` event for an order that doesn't exist. The dispatcher-service smoke test sends
one (id above 900000000) just before the order-service test places its order, 0.3–2 s apart. In one
`order dispatcher observability` run, orders 1 and 4 (each right after such an event) were lost,
while orders 3 and 6 (placed later, with no unknown id in between) were dispatched. Not every
unknown id leads to a loss.

**What happened:** the check "order DISPATCHED by dispatcher-service" failed: the order stayed
ACCEPTED for good.

- order-service saved order 1 and published `order-accepted` (13:28:23.633).
- dispatcher-service packed and labelled order 1 and published `order-dispatched` (13:28:23.706).
- RabbitMQ delivered that message to `order-dispatched.order-service`, and order-service
  acknowledged it. The queue stats showed 2 delivered, 2 acked, 0 redelivered, 0 unacked.
- order-service never logged "The order with id 1 is dispatched" and logged no error. The row in
  `polardb_order.orders` stayed ACCEPTED.

The message just before it, `order-dispatched` for id 900006869 (from the dispatcher-service
smoke test, an order that doesn't exist), was the first message order-service consumed after
startup. It was also the first R2DBC query on the consumer side.

**Not lost for good:** the consumer was still alive. Rerunning the tests against the same stack
dispatched the new order normally (72/72), and a second cold start passed too.

**Where to look:** what `findById` returning empty for the unknown id does to the next element
of the reactive pipeline. `OrderFunctions.dispatchOrder` subscribes to the stream itself
(`Consumer<Flux<OrderDispatchedMessage>>` ending in `.subscribe()`), and
`OrderService.consumeOrderDispatchedEvent` does `flatMap(findById)`, then `map`, then
`flatMap(save)`. Messages are acknowledged as soon as they enter the Flux, so if processing drops
a message, nothing redelivers it. Possible causes:

- a race between saving the new order and the dispatched event arriving;
- the first R2DBC connection being set up on the consumer path;
- an error swallowed inside the reactive pipeline.

**How to reproduce:** `smoke-test.sh down && smoke-test.sh all`, repeated. Look at
`podman logs order-service` for the missing "is dispatched" line.
