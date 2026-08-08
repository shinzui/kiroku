---
title: "Live catch-up subscriptions"
type: Capability
description: "Subscribe to the global log or a category, catch up from a durable checkpoint and switch to live delivery, with at-least-once, per-batch checkpointing and a Streamly bridge."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-11
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Subscription
  - Kiroku.Store.Subscription.Effect
  - Kiroku.Store.Subscription.Stream
requires:
  - CAP-3
evidence:
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionState.hs
    proves: The catch-up to live FSM transitions and the currentState/subscriptionStates observability surface.
  - kind: test
    resource: kiroku-store/test/Test/CatchupDbErrorNoPrematureSwitch.hs
    proves: Catch-up retries transient DB errors instead of switching to live at a stale cursor, so no pre-live events are missed.
  - kind: test
    resource: kiroku-store/test/Test/StreamBridgeTermination.hs
    proves: The Streamly subscriptionStream bridge terminates cleanly on stop and rethrows the worker's exception on failure.
  - kind: guide
    resource: docs/user/subscriptions.md
    proves: Subscribing, targets, checkpoints, and idempotency requirements.
---

# Live catch-up subscriptions

Subscribe to the totally ordered `$all` log or a category. A worker catches up from a durable
per-subscription checkpoint, then switches to live delivery driven by PostgreSQL NOTIFY.
Delivery is **at-least-once** with the checkpoint advanced per batch, so handlers must be
idempotent. Available through the `MonadIO` `subscribe`/`withSubscription`, the effectful
`Subscription` effect, and the Streamly `subscriptionStream` bridge. Subscriptions deliver
[appended](append-with-optimistic-concurrency.md) events.

## Usage

```haskell
withSubscription store defaultSubscriptionConfig handler $ \h ->
  wait h
```

## Limits

- At-least-once means replays across restart, reconnect, and overflow-recovery boundaries; the
  handler must tolerate re-delivery of already-processed events.
- Live `$all` delivery is publisher-fed; `Category` and consumer-group members are DB-driven in
  live mode, so `queueCapacity` / `overflowPolicy` do not apply to them (since `0.3.0.0`).
- A checkpoint-load failure at startup fails the subscription loudly (surfaced through `wait`); it
  no longer silently falls back to reprocessing the whole history.
- Delivery-outcome control (retry, dead-letter, filtering, backpressure recovery) is a separate,
  later capability — resilient delivery (CAP-12), which requires this one.
