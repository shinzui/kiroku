# Shibuya Adapter

The `shibuya-kiroku-adapter` package lets you drive Kiroku subscriptions from
[Shibuya](../../shibuya-kiroku-adapter), a queue-processing framework. It
wraps Kiroku's push-based subscriptions into Shibuya's pull-based `Adapter`
interface, so you get Shibuya's supervised multi-subscription processing,
failure isolation, per-subscription metrics, and coordinated graceful
shutdown over an event log.

Use this when you already run Shibuya processors, or when you want several
independent subscriptions supervised together. For a single in-process
subscription, the native API in [Subscriptions](subscriptions.md) is simpler.

## Creating An Adapter

```haskell
kirokuAdapter ::
  (IOE :> es) =>
  KirokuStore ->
  KirokuAdapterConfig ->
  Eff es (Adapter es RecordedEvent)
```

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Effectful (runEff)
import Kiroku.Store (withStore, defaultConnectionSettings)
import Shibuya.Adapter.Kiroku
import Shibuya.App
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)

main :: IO ()
main = withStore (defaultConnectionSettings connStr) $ \store ->
  runEff $ runTracingNoop $ do
    adapter <-
      kirokuAdapter store
        (defaultKirokuAdapterConfig
          (SubscriptionName "my-projection")
          AllStreams)

    let handler ingested = do
          -- process ingested.envelope.payload :: RecordedEvent
          pure AckOk

    Right appHandle <-
      runApp IgnoreFailures 100
        [(ProcessorId "my-projection", mkProcessor adapter handler)]

    waitApp appHandle
```

Build the config with `defaultKirokuAdapterConfig name target` and override
individual fields with record-update syntax — prefer this over a full record
literal so a field added later is inherited at its default automatically.

`KirokuAdapterConfig`:

| Field | Default | Meaning |
| --- | --- | --- |
| `subscriptionName :: SubscriptionName` | (required) | Unique subscription identifier — the checkpoint key in the `subscriptions` table. Must be unique across active subscriptions. |
| `subscriptionTarget :: SubscriptionTarget` | (required) | `AllStreams` or `Category categoryName`. |
| `batchSize :: Int32` | `100` | Events per database fetch during catch-up. |
| `bufferSize :: Natural` | `256` | `TBQueue` capacity — the backpressure threshold. |
| `consumerGroup :: Maybe ConsumerGroup` | `Nothing` | `Nothing` = ordinary subscription. `Just (ConsumerGroup { member, size })` = this adapter is member `member` of a size-`size` consumer group (see below). |
| `eventTypeFilter :: EventTypeFilter` | `AllEventTypes` | Deliver only chosen event types. Forwarded into the underlying subscription; filtering is worker-side, so a filtered-out event never reaches the Shibuya handler yet the checkpoint still advances past it. |
| `selector :: Maybe (RecordedEvent -> Bool)` | `Nothing` | Optional opaque per-event predicate for filtering `eventTypeFilter` cannot express; composed with it as a logical AND. Also worker-side. |

`SubscriptionName`, `SubscriptionTarget`, `ConsumerGroup`, and `EventTypeFilter`
are re-exported from the adapter module, so you do not need a separate
`kiroku-store` import for them.

## Consumer Groups

A consumer group splits one logical subscription across `N` members, each
handling a disjoint, per-stream-ordered slice. To run a whole group in one
process, use `kirokuConsumerGroupProcessors`: one call yields `N` ready-to-run
Shibuya processors — one per member, each pinned to the group-level
`(PartitionedInOrder, Serial)` policy — with no manual `[0 .. N - 1]` wiring:

```haskell
import Shibuya.Adapter.Kiroku (defaultConsumerGroupConfig, kirokuConsumerGroupProcessors)

let cfg = defaultConsumerGroupConfig
            (SubscriptionName "my-projection")
            (Category (CategoryName "orders"))
            4   -- group size

Right processors <- kirokuConsumerGroupProcessors store cfg handler
Right appHandle  <- runApp IgnoreFailures 100 processors
waitApp appHandle
```

`KirokuConsumerGroupConfig` (built by `defaultConsumerGroupConfig name target
size`) describes the whole group; its `eventTypeFilter` / `selector` apply to
every member, and `memberConcurrency` must be `Serial` (any `Ahead` / `Async`
is rejected before any subscription opens, because Shibuya does not route by
partition key — member identity rides each processor's `ProcessorId`,
`"<name>-member-<m>"`).

To run members across separate processes instead, give each process one
`kirokuAdapter` whose `consumerGroup` is `Just (ConsumerGroup { member = m, size
= N })` with the same `subscriptionName`. The validity invariant (`size >= 1`,
`0 <= member < size`) is enforced by the underlying subscription and throws
`InvalidConsumerGroup` on violation. For the mental model, the
one-process-per-member operational invariant, the resize procedure, and the hash
caveat, see [Consumer Groups](consumer-groups.md).

## How It Works

The adapter:

1. Starts a Kiroku subscription via the **ack-coupled** bridge
   `subscriptionAckStream`, with a bounded `TBQueue`.
2. Lifts the stream into the effect stack with `Stream.morphInner liftIO`.
3. Wraps each event in a Shibuya `Ingested` value — an `Envelope` plus an
   `AckHandle` whose `finalize` maps the handler's `AckDecision` onto a Kiroku
   disposition (below).

Because the bridge is ack-coupled, the Kiroku worker blocks on each event until
the Shibuya handler's decision is finalized, and **only then** checkpoints,
retries, or dead-letters. The checkpoint boundary is the Shibuya handler's
acknowledgement, not the in-memory queue handoff. The usual delivery contract
still holds: at-least-once delivery, idempotent handlers required (see
[Subscriptions](subscriptions.md)).

## Ack Semantics

Delivery is ack-coupled: for each event the Kiroku worker blocks until the
Shibuya handler's `AckDecision` is finalized, then acts on it. The handler's
decision therefore drives Kiroku checkpointing **per event**:

| `AckDecision` | Effect |
| --- | --- |
| `AckOk` | The worker checkpoints past the event (the normal case). |
| `AckRetry delay` | The worker redelivers the **same** event after `delay`, bounded by the subscription's `retryPolicy` (default five attempts); on exhaustion the event is dead-lettered. |
| `AckDeadLetter reason` | The worker records the event in `kiroku.dead_letters` (with `reason` translated to a Kiroku-native `DeadLetterReason`) and atomically advances the checkpoint past it. |
| `AckHalt` | Cancels the underlying Kiroku subscription **without advancing the checkpoint**, so the halting event replays on restart. |

To stop processing from inside a handler, return `AckHalt`. The adapter's
`shutdown` action also cancels the subscription and flushes the queue
sentinel so any blocked stream reader terminates. The retry / dead-letter
behaviour is the same as the native `Retry` / `DeadLetter` dispositions
documented in [Subscriptions](subscriptions.md#per-event-retry-and-dead-letter).

## Backpressure

`bufferSize` sets the `TBQueue` capacity. Because delivery is ack-coupled, the
Kiroku subscription worker **blocks** on each event until the Shibuya handler
finalizes its decision. This throttles database polling to match the handler's
consumption rate — natural backpressure with no event loss.

## Envelope Mapping

Each `RecordedEvent` becomes a Shibuya `Envelope`:

| `RecordedEvent` | `Envelope` |
| --- | --- |
| `eventId` (UUID) | `messageId` (text) |
| `globalPosition` | `cursor` (`CursorInt`) |
| `createdAt` | `enqueuedAt` |
| `metadata.traceparent` (+ `tracestate`) | `traceContext` |
| the event itself | `payload` |
| redelivery counter | `attempt = Just (Attempt n)` (zero-based; how many times Kiroku has redelivered this event) |
| the kiroku identity | `attributes` (`messaging.system`, `messaging.destination.name`, `kiroku.subscription.name`, `kiroku.event.type`, `kiroku.event.global_position`, and `kiroku.consumer_group.member` for a group) |
| — | `partition = Nothing` |

The adapter preserves W3C trace context when `metadata` is a JSON object with
a string `traceparent` key (and optional `tracestate`), so traces propagate
from append into Shibuya processing. See [OpenTelemetry](opentelemetry.md)
for how to populate that metadata on the append side.

The `attributes` map carries the kiroku identity onto the per-message span that
Shibuya opens (Shibuya merges `Envelope.attributes` into that span). The adapter
sets current OpenTelemetry messaging semantic-convention attributes
`messaging.system = "kiroku"` and `messaging.destination.name` to the
subscription name, while preserving Kiroku-specific `kiroku.*` attributes for
event-store state. Combined with the native subscription spans from
`Kiroku.Otel.Subscription`, a single trace is followable from a kiroku
subscription into Shibuya's processing — see
[OpenTelemetry → Tracing Subscription State](opentelemetry.md#tracing-subscription-state).
The keys match the native spans' keys, so both sides of the trace read
consistently.

## Dependencies

The adapter depends on `shibuya-core` (`>=0.6 && <0.7`) and `kiroku-store`.
It does **not** pull in `kiroku-otel`; trace-context propagation works on the
raw `metadata` JSON regardless of whether the producer uses `kiroku-otel`.

## See Also

- [Subscriptions](subscriptions.md) — the underlying subscription mechanism.
- [OpenTelemetry](opentelemetry.md) — populating trace context on append.
