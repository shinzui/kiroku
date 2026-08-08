---
title: "Resilient delivery: retry, dead-letter, filtering, and backpressure recovery"
type: Capability
description: "Drive per-event dispositions (retry with backoff, dead-letter) through an ack-coupled stream, filter deliveries by event type or predicate, and recover from backpressure and live DB errors without losing events."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-12
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.2.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Subscription.Types
  - Kiroku.Store.Subscription.Stream
  - Kiroku.Store.Subscription.Fsm
requires:
  - CAP-11
evidence:
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs
    proves: Retry redelivers under the retry policy and DeadLetter records to kiroku.dead_letters while atomically advancing the checkpoint.
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionPauseResume.hs
    proves: The PauseAndResume overflow policy drains and re-catches-up from the checkpoint without losing events.
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionReconnect.hs
    proves: A live DB error moves a Category/group worker into Reconnecting and it re-catches-up from its checkpoint.
  - kind: test
    resource: kiroku-store/test/Test/EventTypeFilter.hs
    proves: eventTypeFilter delivers only matching types while the checkpoint still advances past filtered-out events (no stall).
---

# Resilient delivery: retry, dead-letter, filtering, and backpressure recovery

Extends [live subscriptions](live-subscriptions.md) with per-event delivery control, all added in
`0.2.0.0`. Handlers return `Retry RetryDelay` (redeliver under `retryPolicy`) or
`DeadLetter DeadLetterReason` (record in `kiroku.dead_letters` and atomically advance past the
event) through the ack-coupled `subscriptionAckStream`. `eventTypeFilter` / `selector` restrict
what is delivered worker-side. The `PauseAndResume` overflow policy (now the default) and the
`Reconnecting` state recover from backpressure and live DB errors without event loss.

## Usage

```haskell
defaultSubscriptionConfig
  & #eventTypeFilter .~ OnlyEventTypes (Set.fromList [EventType "OrderPlaced"])
  & #retryPolicy     .~ defaultRetryPolicy   -- 5 total deliveries, then dead-letter
```

## Limits

- Filtered-out events never reach the handler (so they are never retried or dead-lettered), but the
  checkpoint still advances past them — a highly selective subscription never stalls.
- `retryMaxAttempts` bounds *total deliveries*, not redeliveries: `defaultRetryPolicy` (5) is the
  first delivery plus four redeliveries before `DeadLetterMaxAttempts`.
- `selector` is an opaque predicate — not introspectable, `Eq`/`Show`-able, or SQL-pushdown-able,
  unlike the closed `eventTypeFilter`; prefer the filter and use the selector only for what it
  cannot express.
- These dispositions require the ack-coupled bridge; a plain `subscriptionStream` always replies
  `Continue`.
