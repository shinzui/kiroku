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
        KirokuAdapterConfig
          { subscriptionName = SubscriptionName "my-projection"
          , subscriptionTarget = AllStreams
          , batchSize = 100
          , bufferSize = 256
          }

    let handler ingested = do
          -- process ingested.envelope.payload :: RecordedEvent
          pure AckOk

    Right appHandle <-
      runApp IgnoreFailures 100
        [(ProcessorId "my-projection", mkProcessor adapter handler)]

    waitApp appHandle
```

`KirokuAdapterConfig`:

| Field | Meaning |
| --- | --- |
| `subscriptionName :: SubscriptionName` | Unique subscription identifier — the checkpoint key in the `subscriptions` table. Must be unique across active subscriptions. |
| `subscriptionTarget :: SubscriptionTarget` | `AllStreams` or `Category categoryName`. |
| `batchSize :: Int32` | Events per database fetch during catch-up. |
| `bufferSize :: Natural` | `TBQueue` capacity — the backpressure threshold. |

`SubscriptionName` and `SubscriptionTarget` are re-exported from the adapter
module, so you do not need a separate `kiroku-store` import for them.

## How It Works

The adapter:

1. Starts a Kiroku subscription via `subscriptionStream`, with a bounded
   `TBQueue` bridge.
2. Lifts the `Stream IO RecordedEvent` into the effect stack with
   `Stream.morphInner liftIO`.
3. Wraps each `RecordedEvent` in a Shibuya `Ingested` value — an `Envelope`
   plus an `AckHandle`.

Checkpoint advancement is handled internally by Kiroku's subscription worker,
exactly as in [Subscriptions](subscriptions.md): at-least-once delivery,
per-batch checkpoints, idempotent handlers required.

## Ack Semantics

Kiroku subscriptions are not message queues: events are immutable and
persistent, and the checkpoint is managed by the worker, not the handler. So
the ack decisions map as follows:

| `AckDecision` | Effect |
| --- | --- |
| `AckOk` | No-op (normal case; checkpoint advances automatically). |
| `AckRetry` | No-op (events cannot be redelivered; they are always available). |
| `AckDeadLetter` | No-op (there is no dead-letter concept for an event log). |
| `AckHalt` | Cancels the underlying Kiroku subscription. |

To stop processing from inside a handler, return `AckHalt`. The adapter's
`shutdown` action also cancels the subscription and flushes the queue
sentinel so any blocked stream reader terminates.

## Backpressure

`bufferSize` sets the `TBQueue` capacity. When the queue is full, the Kiroku
subscription worker **blocks** until the Shibuya handler drains events. This
throttles database polling to match the handler's consumption rate — natural
backpressure with no event loss.

## Envelope Mapping

Each `RecordedEvent` becomes a Shibuya `Envelope`:

| `RecordedEvent` | `Envelope` |
| --- | --- |
| `eventId` (UUID) | `messageId` (text) |
| `globalPosition` | `cursor` (`CursorInt`) |
| `createdAt` | `enqueuedAt` |
| `metadata.traceparent` (+ `tracestate`) | `traceContext` |
| the event itself | `payload` |
| — | `partition = Nothing` |

The adapter preserves W3C trace context when `metadata` is a JSON object with
a string `traceparent` key (and optional `tracestate`), so traces propagate
from append into Shibuya processing. See [OpenTelemetry](opentelemetry.md)
for how to populate that metadata on the append side.

## Dependencies

The adapter depends on `shibuya-core` (`>=0.5 && <0.6`) and `kiroku-store`.
It does **not** pull in `kiroku-otel`; trace-context propagation works on the
raw `metadata` JSON regardless of whether the producer uses `kiroku-otel`.

## See Also

- [Subscriptions](subscriptions.md) — the underlying subscription mechanism.
- [OpenTelemetry](opentelemetry.md) — populating trace context on append.
