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
        (defaultSubscriptionConfig
          (SubscriptionName "inventory-projection")
          AllStreams
          handler)
          { missingCheckpointPolicy = FromBeginning }
  withSubscription store cfg $ \h -> do
    result <- wait h        -- block until Stop, cancel, or failure
    print result
  where
    handler :: RecordedEvent -> IO SubscriptionResult
    handler event = do
      apply (event ^. #payload)   -- your projection update
      pure Continue
```

This projection chooses `FromBeginning` explicitly because it can rebuild from
retained history. That is also the compatibility default, but spelling it out
makes the intended recovery behavior visible at the call site.

Prefer `withSubscription` for any non-trivial path. The bare `subscribe`
returns a `SubscriptionHandle` whose worker thread runs until you `cancel` it
or the handler returns `Stop`; forgetting to cancel leaks the thread.

The handler returns `SubscriptionResult`:

- `Continue` — process the next event.
- `Stop` — stop the subscription gracefully; the checkpoint is saved at this
  event and `wait` resolves with `Right ()`.
- `Retry delay` — redeliver **this same event** after `delay`, before the
  checkpoint advances past it. Redelivery is bounded by the subscription's
  `retryPolicy` (default five attempts); on exhaustion the worker dead-letters
  the event and moves on. See [Per-Event Retry And Dead-Letter](#per-event-retry-and-dead-letter).
- `DeadLetter reason` — record this event in the `kiroku.dead_letters` table
  with `reason` and **atomically advance the checkpoint past it**, then continue
  with the next event.

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
| `overflowPolicy :: OverflowPolicy` | `PauseAndResume` | What the publisher does when this subscriber's queue is full (see below). |
| `retryPolicy :: RetryPolicy` | `defaultRetryPolicy` (5 attempts) | Bounds how many times an event for which the handler returned `Retry` is redelivered before it is dead-lettered. Handlers that never return `Retry` are unaffected. |
| `eventTypeFilter :: EventTypeFilter` | `AllEventTypes` | Restrict delivery to chosen event types. See [Event-Type Filtering](#event-type-filtering). |
| `selector :: Maybe (RecordedEvent -> Bool)` | `Nothing` | Optional opaque per-event predicate, the escape hatch for filtering the type set cannot express (e.g. metadata). Composed with `eventTypeFilter` as a logical AND. See [Event-Type Filtering](#event-type-filtering). |
| `consumerGroup :: Maybe ConsumerGroup` | `Nothing` | Run this worker as one member of a hash-partitioned group. See [Consumer Groups](consumer-groups.md). |
| `missingCheckpointPolicy :: MissingCheckpointPolicy` | `FromBeginning` | What startup does when the exact `(name, consumer-group member)` checkpoint row is absent: seed zero, atomically seed the authoritative current append frontier, or fail. Existing rows always win. See [Choosing A Startup Checkpoint](#choosing-a-startup-checkpoint). |

`SubscriptionTarget` is `AllStreams` (every event in global position order)
or `Category !CategoryName` (events whose source stream's name prefix matches
the category). Category subscriptions still use `$all` global positions as
their cursor.

## How It Works

The worker thread:

1. Resolves the exact `(name, consumer-group member)` checkpoint according to
   `missingCheckpointPolicy`. An existing row is unchanged; a new row is
   durably seeded before any handler call, or startup fails.
2. **Catches up** by querying the database directly in `batchSize` pages
   until it reaches the publisher's last-published cursor.
3. Switches to **live** mode. For `AllStreams` it reads pre-broadcast events
   from the publisher's bounded per-subscriber queue. For ordinary `Category`
   subscriptions it bypasses the broadcast and re-queries the database when
   that category receives a `NOTIFY` signal, with a 30-second safety poll for
   missed notifications. Consumer-group members use a DB-driven live loop gated
   by the publisher's global cursor because their partition predicate is computed
   in SQL.

Live wake-ups are driven by PostgreSQL `LISTEN`/`NOTIFY`; a 30-second safety
poll covers any missed notification. Transient database errors during catch-up
or DB-driven live fetches are surfaced through `KirokuEventSubscriptionDbError`
and retried at the same cursor with capped backoff. The checkpoint advances per
batch (see below).

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

## Worker States

The worker is driven by an explicit finite state machine: at any instant it is
in exactly one named `SubscriptionState`, readable through the handle's
`currentState :: m (Maybe SubscriptionState)` accessor (a point-in-time
observability read resolved through the store's central subscription-state
registry):

| State | Meaning |
| --- | --- |
| `CatchingUp` | Reading history directly from the database until the cursor reaches the publisher's last-published position. |
| `Live` | Caught up; waiting for new events via `NOTIFY` / the publisher queue. |
| `Paused` | Recoverable backpressure: the queue filled under `PauseAndResume`; the worker drains it and re-catches-up from its checkpoint (see [Overflow Policy](#overflow-policy)). |
| `Reconnecting` | A `Category` / consumer-group worker lost its database connection on a live fetch; it backs off and re-catches-up from its checkpoint instead of dying. |
| `Retrying` | Redelivering a single event for which the handler returned `Retry`, bounded by `retryPolicy`. |
| `Stopped` | Terminal (handler `Stop`, cancellation, overflow, or crash). |

`currentState` returns `Just s` while the worker is live and still owns its
registry entry, and `Nothing` once the subscription is **not currently live** —
it has stopped, been cancelled, crashed, was never started, or has been
superseded by a newer worker registered under the same `(name, member)` key.
Note that `Stopped` is never observed through `currentState`: a not-live
subscription is represented by `Nothing` ("stopped = absent"), the same rule the
registry snapshot follows. For the **aggregate** state of every live
subscription at once — without holding individual handles — read
`subscriptionStates store`, which returns a snapshot map of `SubscriptionStateView`
records (name, member, live state, a stable `statePhase` label, and the FSM
`cursor` position); see [Observability](observability.md). For the stream of
*past* transitions (including the terminal stop reason), wire the `KirokuEvent`
lifecycle events instead.

## Reading Durable Checkpoints

`subscriptionStates` answers which workers are live in this process. To answer
which checkpoints have actually been committed to PostgreSQL, use the mockable
`Store` operation `subscriptionCheckpointInventory`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeOperators #-}

import Control.Lens ((^.))
import Data.Int (Int32, Int64)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Kiroku.Store

durablePositionDistances ::
  (Store :> es) =>
  Eff es (Vector (SubscriptionName, Int32, Int64))
durablePositionDistances = do
  inventory <- subscriptionCheckpointInventory
  let GlobalPosition headPosition = inventory ^. #storePosition
  pure $ flip fmap (inventory ^. #checkpoints) $ \checkpoint ->
    let GlobalPosition checkpointPosition = checkpoint ^. #checkpointPosition
     in ( checkpoint ^. #subscriptionName
        , checkpoint ^. #consumerGroupMember
        , headPosition - checkpointPosition
        )
```

The operation captures `storePosition` and all persisted checkpoint rows in one
SQL statement snapshot and one database round trip. `storePosition` is the
**authoritative append frontier**: the greatest `$all` position ever allocated.
It remains monotonic after hard deletion and can therefore be greater than
every event still visible in `$all`. Rows are sorted by subscription name and
numeric member. An empty vector means no checkpoint has yet been written; it
does not mean no subscription is configured. A stopped, cancelled, or crashed
worker disappears from `subscriptionStates` but its durable row remains here.
Call the operation again to observe later commits.

Member zero is ambiguous: it can mean an ordinary subscription or member zero
of a consumer group. The checkpoint row does not preserve the configured target
or group size, so do not infer topology from it. `checkpointUpdatedAt` is the
time of the latest successful checkpoint upsert, including a lower monotonic
save that left the position unchanged; it is not proof that progress advanced.

The subtraction in the example is a **distance to the authoritative append
frontier**, not an exact or necessarily actionable event backlog. Global
positions include events skipped by category and event-type filters, and a
consumer-group member handles only its hash-assigned shard. Tail hard deletion
can also leave `storePosition` above every visible event. When a caller needs a
currently reachable global target, read `visibleGlobalHeadPosition` separately.
That call is its own statement-time observation and does not share the
inventory's one-statement snapshot. A target-specific lag calculation may need
a category head or an event-count query instead. Capturing bounded replay pages
is a separate proposed capability described by
[Expose bounded fan-in replay windows](../improvement-requests/expose-bounded-fan-in-replay-windows.md).

## Choosing A Startup Checkpoint

`missingCheckpointPolicy` is consulted only when the exact
`(SubscriptionName, consumer-group member)` key has no durable row:

- `FromBeginning` inserts position zero and replays retained history. Use it for
  rebuildable projections.
- `FromCurrentHead` captures and inserts the authoritative current append
  frontier atomically. Use it for a future-only worker whose external effects
  must not be applied to any position allocated before initialization,
  including positions whose events were already hard-deleted. The seeded
  position is a future-only boundary; it does not promise that an event is
  currently visible there.
- `FailIfMissing` inserts nothing and terminates startup with the typed
  `SubscriptionCheckpointMissing` exception before the handler runs. Use it
  when checkpoint provisioning is an operational prerequisite.

For example, a future-only side-effect worker can deliberately ignore history:

```haskell
let cfg =
      (defaultSubscriptionConfig
        (SubscriptionName "customer-email-notifications")
        AllStreams
        sendEmail)
        { missingCheckpointPolicy = FromCurrentHead }

withSubscription store cfg $ \handle -> wait handle
```

The authoritative-frontier read and row insertion are one atomic database
boundary. An append is therefore either included in the durable seed or
delivered afterward; it cannot fall into a gap between a separate frontier read
and insert. Concurrent starters converge on the first row that commits. This is
deliberately different from `visibleGlobalHeadPosition`, whose reachability
observation may regress and is not part of the initialization statement.

An existing row always takes precedence for all three policies. Changing a
deployed configuration from `FromBeginning` to `FromCurrentHead` or
`FailIfMissing` does not rewind, fast-forward, or delete durable progress.

### Explicit Transactional Reset

Ordinary worker saves are monotonic. A coordinating application that must move
durable progress to an exact position can use the separately named
`resetSubscriptionCheckpointsTx` combinator inside its own transaction:

```haskell
import Data.List.NonEmpty (NonEmpty (..))
import Kiroku.Store

result <- runStoreIO store $ runTransaction $
  resetSubscriptionCheckpointsTx
    ( SubscriptionName "orders-projection"
        :| [SubscriptionName "inventory-projection"]
    )
    (GlobalPosition 1200)
```

The result is a `SubscriptionCheckpointResetReport` with sorted
`resetCheckpointKeys` for every persisted member updated and sorted
`missingSubscriptionNames` for requested names with no rows. Duplicate input
names are treated as one name. Reset updates every existing member directly,
can move progress backward, and never invents consumer-group members or creates
rows for missing names. Because it is a `Hasql.Transaction.Transaction`
combinator, `Tx.condemn` rolls it back together with the caller's projection
fence and target-table writes.

## Lifecycle And Failure Modes

`SubscriptionHandle` carries `cancel :: m ()`,
`wait :: m (Either SomeException ())`, and `currentState` (above). `wait`
resolves with one of:

| Result | Meaning |
| --- | --- |
| `Right ()` | The handler returned `Stop`; the worker exited cleanly, checkpoint saved at that event. |
| `Left AsyncCancelled` | The caller invoked `cancel`. No checkpoint advance is guaranteed; in-flight events replay on the next start. |
| `Left SubscriptionOverflowed` | The publisher dropped this subscriber under the (non-default) `DropSubscription` policy. Under the default `PauseAndResume` the worker recovers rather than failing. |
| `Left SubscriptionCheckpointMissing` | The exact checkpoint key was absent under `FailIfMissing`. No row was inserted and the handler did not run. |
| `Left e` (any other) | The handler threw. Exceptions are **not** caught — the worker thread dies and the exception propagates. A throwing handler signals the subscription cannot proceed safely. |

## Overflow Policy

When a subscriber's bounded queue fills (the handler is slower than the
append rate), the publisher applies the `overflowPolicy`:

- `PauseAndResume` (default) — recoverable backpressure, lossless. The publisher
  marks the subscriber `Paused` and **stops pushing** (it does not drop). The
  worker enters the `Paused` state, drains the stale queue, and re-catches-up
  from its checkpoint, re-reading the events it missed directly from the
  database. No event is lost, the checkpoint stays monotonic, and other
  subscribers are unaffected — a transient slowdown pauses and recovers instead
  of killing the subscription.
- `DropSubscription` — mark the subscription overflowed; the worker surfaces
  `SubscriptionOverflowed` through `wait` and terminates. Choose this when a
  slow consumer should be a hard, fail-fast error rather than a silent pause.
  Investigate the slow handler, raise `queueCapacity`, or switch policy.
- `DropOldest` — drop the oldest queued batch and enqueue the new one. The
  subscription continues but **loses events**. Choose only for
  telemetry-style consumers where at-least-once is not required.

## Per-Event Retry And Dead-Letter

Beyond `Continue` / `Stop`, a handler can dispose of a single problematic event
without blocking the whole subscription:

- `Retry delay` redelivers **the same event** after `delay`. The worker keeps
  the checkpoint pinned at that event and counts attempts; once
  `retryPolicy.retryMaxAttempts` (default `5`) is reached, the worker
  dead-letters the event and advances. While retrying, `currentState` reports
  `Retrying`.
- `DeadLetter reason` records the event in the `kiroku.dead_letters` table and
  **atomically advances the checkpoint past it** in the same statement, so the
  subscription never stalls on a poison event. The event itself stays immutable
  in `kiroku.events`; the dead-letter row references it by `event_id` and
  `global_position`. See [Schema](schema.md#dead_letters) for the table.

These dispositions also back the Shibuya adapter's `AckRetry` / `AckDeadLetter`
decisions — see [Shibuya Adapter](shibuya-adapter.md#ack-semantics).

## Event-Type Filtering

Set `eventTypeFilter` to deliver only the event types a subscription cares
about:

```haskell
import qualified Data.Set as Set
import Kiroku.Store.Subscription (EventTypeFilter (..))

let cfg =
      (defaultSubscriptionConfig name AllStreams handler)
        { eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "OrderPlaced"]) }
```

`AllEventTypes` (the default) delivers everything. `OnlyEventTypes s` delivers
only events whose type is in `s`; **filtered-out events still advance the
checkpoint** (the worker moves its cursor past them) so a highly selective
subscription never stalls on a long run of non-matching events. The filter is
applied **worker-side, before the handler**, so a filtered-out event never
reaches the handler and is never retried or dead-lettered.

For filtering the type set cannot express — for example on metadata or stream
name during a one-off catch-up reprocess — set the opaque `selector ::
Maybe (RecordedEvent -> Bool)`. It composes with `eventTypeFilter` as a logical
AND (an event must pass both) and obeys the same no-stall / never-retried
guarantees. Prefer `eventTypeFilter` for the steady-state case: a closed
`Set EventType` is introspectable, `Eq`/`Show`-able, and can be pushed into SQL,
which an opaque closure cannot.

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
stops the subscription and unblocks any reader waiting on the queue.

`subscriptionStream` checkpoints independently of the downstream consumer (the
bridge handler returns `Continue` as soon as it enqueues). For per-event
acknowledgement — where the checkpoint must not advance until the consumer has
processed the event, and the consumer can ask for `Retry` / `DeadLetter` — use
the **ack-coupled** variant `subscriptionAckStream`, which emits `AckItem`
values each carrying a one-shot reply variable. This is the mechanism the
[Shibuya Adapter](shibuya-adapter.md) builds on so a Shibuya `AckRetry` /
`AckDeadLetter` drives a real Kiroku disposition.

## See Also

- [Shibuya Adapter](shibuya-adapter.md) — supervised multi-subscription
  processing.
- [Observability](observability.md) — subscription lifecycle and error
  events (`KirokuEvent`).
- [Reading Events](reading-events.md) — one-shot reads versus continuous
  delivery.
- [Consumer Groups](consumer-groups.md) — horizontal scaling with
  hash-partitioned members, per-member checkpoints, and the resize procedure.
