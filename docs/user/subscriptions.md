# Subscriptions

A subscription delivers events to a handler as they are appended, picking up
where it left off across restarts. Kiroku subscriptions are in-process: they
spawn a worker thread, catch up from a durable checkpoint, then switch to
live delivery driven by PostgreSQL `NOTIFY`. This guide covers the
`MonadIO` API, delivery semantics, overflow policy, the effectful API, and
the Streamly bridge. To drive subscriptions from the Shibuya framework, see
[Shibuya Adapter](shibuya-adapter.md).

## Starting A Subscription

```haskell
subscribe ::
  (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle

withSubscription ::
  (MonadUnliftIO m) =>
  KirokuStore -> SubscriptionConfig -> (SubscriptionHandle -> m a) -> m a
```

Build a config with `defaultSubscriptionConfig` and run it with
`withSubscription`, which cancels the worker on either normal exit or an
exception:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Kiroku.Store
import Kiroku.Store.Subscription

runProjection :: KirokuStore -> IO ()
runProjection store = do
  let cfg =
        defaultSubscriptionConfig
          (SubscriptionName "inventory-projection")
          AllStreams
          handler
  withSubscription store cfg $ \h -> do
    result <- wait h        -- block until Stop, cancel, or failure
    print result
  where
    handler :: RecordedEvent -> IO SubscriptionResult
    handler event = do
      apply (event ^. #payload)   -- your projection update
      pure Continue
```

Prefer `withSubscription` for any non-trivial path. The bare `subscribe`
returns a `SubscriptionHandle` whose worker thread runs until you `cancel` it
or the handler returns `Stop`; forgetting to cancel leaks the thread.

The handler returns `SubscriptionResult`:

- `Continue` — process the next event.
- `Stop` — stop the subscription gracefully; the checkpoint is saved at this
  event and `wait` resolves with `Right ()`.

## Configuration

`SubscriptionConfig` (built by `defaultSubscriptionConfig name target
handler`):

| Field | Default | Meaning |
| --- | --- | --- |
| `name :: SubscriptionName` | (required) | Stable name. This is the **checkpoint key** in the `subscriptions` table; reuse the same name across restarts to resume. |
| `target :: SubscriptionTarget` | (required) | `AllStreams` or `Category categoryName`. |
| `handler` | (required) | `RecordedEvent -> m SubscriptionResult`, invoked once per event in order. |
| `batchSize :: Int32` | `100` | Events fetched per database round-trip during catch-up. |
| `queueCapacity :: Natural` | `16` | Maximum number of *batches* the publisher may enqueue for this subscriber before applying the overflow policy. Effective event capacity is `queueCapacity * publisherBatchSize`. |
| `overflowPolicy :: OverflowPolicy` | `DropSubscription` | What the publisher does when this subscriber's queue is full (see below). |

`SubscriptionTarget` is `AllStreams` (every event in global position order)
or `Category !CategoryName` (events whose source stream's name prefix matches
the category). Category subscriptions still use `$all` global positions as
their cursor.

## How It Works

The worker thread:

1. Reads the saved checkpoint for `name`, or starts at global position 0 for
   a fresh name.
2. **Catches up** by querying the database directly in `batchSize` pages
   until it reaches the publisher's last-published cursor.
3. Switches to **live** mode. For `AllStreams` it reads pre-broadcast events
   from the publisher's bounded per-subscriber queue. For `Category` it
   bypasses the broadcast and re-queries the database with the category
   filter whenever the publisher advances.

Live wake-ups are driven by PostgreSQL `LISTEN`/`NOTIFY`; a 30-second safety
poll covers any missed notification. The checkpoint advances per batch (see
below).

## Delivery Semantics

Events are delivered **at least once**. The checkpoint is saved **per
batch**, not per event: when the handler returns `Continue` for every event
in a batch, the checkpoint is saved at the batch tail; when it returns `Stop`,
the checkpoint is saved at that event.

Because of this, some events **replay** on a subsequent subscription with the
same `SubscriptionName`:

- The handler returned `Continue` but the worker was cancelled or the process
  crashed before the checkpoint was saved.
- The worker was interrupted mid-batch; already-processed events re-deliver
  alongside the not-yet-processed ones.
- A transient publisher pool error caused a re-fetch and re-broadcast.

**Handlers must be idempotent** — process a duplicate without producing a
wrong-on-replay result — or tolerate duplicates by a domain check (e.g. a
unique key on the projection table).

## Lifecycle And Failure Modes

`SubscriptionHandle` carries `cancel :: m ()` and
`wait :: m (Either SomeException ())`. `wait` resolves with one of:

| Result | Meaning |
| --- | --- |
| `Right ()` | The handler returned `Stop`; the worker exited cleanly, checkpoint saved at that event. |
| `Left AsyncCancelled` | The caller invoked `cancel`. No checkpoint advance is guaranteed; in-flight events replay on the next start. |
| `Left SubscriptionOverflowed` | The publisher dropped this subscriber under `DropSubscription` (its queue overflowed). |
| `Left e` (any other) | The handler threw. Exceptions are **not** caught — the worker thread dies and the exception propagates. A throwing handler signals the subscription cannot proceed safely. |

## Overflow Policy

When a subscriber's bounded queue fills (the handler is slower than the
append rate), the publisher applies the `overflowPolicy`:

- `DropSubscription` (default) — mark the subscription overflowed; the worker
  surfaces `SubscriptionOverflowed` through `wait` and terminates. Other
  subscribers are unaffected. This chooses correctness: you learn explicitly
  that a consumer fell behind. Investigate the slow handler, raise
  `queueCapacity`, or switch policy.
- `DropOldest` — drop the oldest queued batch and enqueue the new one. The
  subscription continues but **loses events**. Choose only for
  telemetry-style consumers where at-least-once is not required.

## The Effectful API

`Kiroku.Store.Subscription.Effect` exposes a `Subscription` effect whose
handler runs in the **caller's** `Eff` stack, so it can use any effects in
scope (state, reader, logging):

```haskell
import Kiroku.Store.Subscription.Effect (Subscription, subscribe, withSubscription)
```

The `Subscription` effect and its interpreters (`runSubscription store`,
`runSubscriptionResource`) are re-exported from `Kiroku.Store`, but the
effectful `subscribe`/`withSubscription` wrappers are **not** — that would
clash with the `MonadIO` `subscribe`. Import the `Effect` module explicitly.

The interpreter runs the handler with a `ConcUnlift Persistent (Limited 1)`
unlift strategy: handler calls are single-threaded (one in flight at a time)
and the effect environment outlives them, so `State`/`Reader` contents stay
consistent across the whole subscription. The same at-least-once,
per-batch-checkpoint semantics apply. As with the `MonadIO` API, the
`Eff`-based `subscribe` captures the caller's effect environment in the worker
thread — prefer the effectful `withSubscription` so a leaking thread cannot
outlive a torn-down environment.

## The Streamly Bridge

`subscriptionStream` turns a subscription into a pull-based Streamly stream,
with a bounded `TBQueue` providing backpressure:

```haskell
import Kiroku.Store.Subscription.Stream (subscriptionStream)

(stream, cancelAction) <- subscriptionStream store cfg 256
```

It returns `(Stream IO RecordedEvent, IO ())`. The `handler` field in the
config is ignored — the bridge installs its own. The returned cancel action
stops the subscription and unblocks any reader waiting on the queue. This is
the mechanism the [Shibuya Adapter](shibuya-adapter.md) builds on.

## See Also

- [Shibuya Adapter](shibuya-adapter.md) — supervised multi-subscription
  processing.
- [Observability](observability.md) — subscription lifecycle and error
  events (`KirokuEvent`).
- [Reading Events](reading-events.md) — one-shot reads versus continuous
  delivery.
