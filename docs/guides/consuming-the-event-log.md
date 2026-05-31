# Consuming The Event Log

This is the comprehensive guide to **reading events continuously** — reacting to
each append as it happens and resuming where you left off across restarts. It
walks the whole subscription system end to end: choosing an approach, the
catch-up→live lifecycle, filtering by event type, the at-least-once contract,
retry and dead-letter dispositions, backpressure, the effectful and Streamly
APIs, and driving subscriptions from the [Shibuya](../user/shibuya-adapter.md)
processing framework.

It composes the reference docs rather than restating them — keep
[Subscriptions](../user/subscriptions.md),
[Consumer Groups](../user/consumer-groups.md), and
[Shibuya Adapter](../user/shibuya-adapter.md) open alongside it. If your goal is
specifically to build a read model or drive a workflow, the
[Building A Projection](building-a-projection.md) and
[Process Managers And Sagas](process-managers-and-sagas.md) guides apply the
patterns below to those ends.

## Choosing An Approach

Kiroku gives you several ways to consume events, from a one-shot read to a
supervised fleet of processors. Pick the *least* machinery that meets the need:

| Approach | Use when | Entry point |
| --- | --- | --- |
| **One-shot read** | You need history *now*, not a live feed — a report, a backfill, an on-demand rebuild. No checkpoint, no worker. | `readAllForward` / `readCategory` / `readStreamForwardStream` (see [Reading Events](../user/reading-events.md)). |
| **Native subscription** | You want a single in-process consumer that catches up and follows live appends with a durable checkpoint. The default choice. | `subscribe` / `withSubscription` (`MonadIO`). |
| **Effectful subscription** | The handler must run in your `Eff` stack and use other effects (state, reader, logging, the `Store` effect itself). | `Kiroku.Store.Subscription.Effect`. |
| **Streamly bridge** | You want to consume events as a pull-based `Stream` and compose Streamly combinators, or you need per-event acknowledgement coupling. | `subscriptionStream` / `subscriptionAckStream`. |
| **Shibuya adapter** | You run several supervised subscriptions together, want failure isolation, per-subscription metrics, ack-coupled checkpointing, and coordinated shutdown. | `kirokuAdapter` (`shibuya-kiroku-adapter`). |
| **Consumer group** | One consumer cannot keep up; split the source across `N` members, each per-stream-ordered. Composes with all of the above. | `consumerGroup` field on the config. |

Everything below the one-shot read shares the same engine and the same
guarantees — catch-up from a durable checkpoint, live `NOTIFY`-driven delivery,
at-least-once semantics. The rows differ only in *how the handler runs* and *who
supervises it*.

## The Lifecycle Of A Subscription

Every subscription — native, effectful, Streamly, or Shibuya-driven — runs the
same worker, which moves through an explicit finite state machine. Understanding
these states is the key to operating subscriptions:

```text
  start ──▶ CatchingUp ──▶ Live ──▶ (Stopped)
              ▲   │          │  ▲
              │   │          │  │
              └───┴──────────┘  └── Retrying / Paused / Reconnecting
              (re-catch-up after pause, reconnect, or pending retry)
```

| State | Meaning |
| --- | --- |
| `CatchingUp` | Reading history directly from the database in `batchSize` pages, from the saved checkpoint up to the publisher's last-published position. |
| `Live` | Caught up; waiting for new events via `NOTIFY` / the publisher queue. |
| `Paused` | Recoverable backpressure under `PauseAndResume`: the queue filled, the worker drains it and re-catches-up from its checkpoint. |
| `Reconnecting` | A `Category` / consumer-group worker lost its DB connection on a live fetch; it backs off and re-catches-up rather than dying. |
| `Retrying` | Redelivering a single event whose handler returned `Retry`, bounded by `retryPolicy`. |
| `Stopped` | Terminal: handler `Stop`, cancellation, overflow under `DropSubscription`, or a crash. |

Read the current state at any instant through the handle:
`h ^. #currentState :: m (Maybe SubscriptionState)` (a point-in-time read resolved
through the store's central registry). It returns `Just s` while the worker is
live, and `Nothing` once the subscription is not currently live (stopped,
cancelled, crashed, not started, or superseded) — so a not-live subscription is
"stopped = absent", never a `Just (Stopped …)`. To read **every** live
subscription's state at once without holding each handle, call
`subscriptionStates store`. For the *history* of transitions — and the errors
behind them — wire the `KirokuEvent` lifecycle stream (see
[Observability](#observability) below). The critical takeaway: a healthy
subscription spends almost all its time in `Live`, dipping to `CatchingUp` only
at startup; sustained `Paused` or `Reconnecting` is a signal to investigate
(slow handler, flaky connection).

## Building A Native Subscriber

The native API is the baseline. Build a config with `defaultSubscriptionConfig`,
override fields with record-update syntax, and run it under `withSubscription`,
which cancels the worker on normal exit *or* exception:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Kiroku.Store
import Kiroku.Store.Subscription

consume :: KirokuStore -> IO ()
consume store = do
  let cfg =
        defaultSubscriptionConfig
          (SubscriptionName "shipping-notifier")     -- the durable cursor
          (Category (CategoryName "orders"))
          handler
  withSubscription store cfg $ \h -> do
    result <- wait h        -- blocks until Stop, cancel, or failure
    print result
  where
    handler :: RecordedEvent -> IO SubscriptionResult
    handler event = do
      react (event ^. #payload)
      pure Continue
```

Three fields define *what* you consume; the rest tune *how*:

- `name :: SubscriptionName` — the checkpoint key. Reuse it across restarts to
  resume; change it to start over (see [Catch-Up](#catch-up-and-reprocessing)).
- `target :: SubscriptionTarget` — `AllStreams` or `Category categoryName`.
- `handler :: RecordedEvent -> m SubscriptionResult` — invoked once per event,
  in order.

The tuning fields (`batchSize`, `queueCapacity`, `overflowPolicy`, `retryPolicy`,
`eventTypeFilter`, `selector`, `consumerGroup`) are documented in full in
[Configuration](../user/subscriptions.md#configuration); the important ones get
their own sections below.

Prefer `withSubscription` over the bare `subscribe` for any non-trivial path —
`subscribe` returns a handle whose worker thread runs until you `cancel` it or
the handler returns `Stop`, and forgetting to cancel leaks the thread.

## Catch-Up And Reprocessing

"Catch-up" is the phase where a worker reads history from its checkpoint forward
until it reaches the live edge. It is automatic and central to two everyday
operations.

**Resuming.** On restart, a worker reads the saved checkpoint for its
`SubscriptionName` and catches up from there — processing only what it missed
while down. This is why the name must be stable: it *is* the resume point.

**Full reprocessing.** To replay the entire log — a new read model, a corrected
handler, a backfill — start the subscription under a **fresh
`SubscriptionName`**. A name with no checkpoint starts at `globalPosition` 0 and
catches up over all of history:

```haskell
-- a brand-new name → catch-up runs from the very beginning of the log
let cfg = defaultSubscriptionConfig
            (SubscriptionName "shipping-notifier-v2")    -- new name → full replay
            (Category (CategoryName "orders"))
            handler
```

Bumping the name (`-v2`) is the cleanest, most auditable trigger for a full
reprocess — it leaves the old checkpoint intact for rollback. Keep the name in
configuration so a reprocess is a config change, not a code change.

How catch-up works under the hood: the worker queries the database directly in
`batchSize`-sized pages (default `100`) until its cursor reaches the publisher's
last-published position, then switches to `Live`. For a large backfill, raise
`batchSize` to cut round-trips; to parallelize the apply, run a
[consumer group](#scaling-out-with-consumer-groups). Transient database errors
during catch-up are surfaced as `KirokuEventSubscriptionDbError` and retried at
the same cursor with capped backoff, so a blip does not lose your place.

**One-off scoped reprocess.** When you want to replay *some* events without a
permanent filter — reprocess only one tenant's events during a migration, say —
use the opaque `selector` (below) on a throwaway subscription name. Filtered-out
events still advance the checkpoint, so the catch-up runs to completion quickly
even when few events match.

## Filtering By Event Type

Most subscriptions care about a handful of event types out of many. Push that
filter into the subscription rather than branching in the handler — it is
clearer, and filtered-out events never reach your code.

```haskell
import Data.Set qualified as Set
import Kiroku.Store.Subscription (EventTypeFilter (..))

let cfg =
      (defaultSubscriptionConfig name AllStreams handler)
        { eventTypeFilter =
            OnlyEventTypes (Set.fromList [EventType "OrderPlaced", EventType "OrderShipped"]) }
```

The semantics that make this safe to rely on:

- `AllEventTypes` (the default) delivers everything; `OnlyEventTypes s` delivers
  only types in `s`.
- **Filtered-out events still advance the checkpoint.** A highly selective
  subscription never stalls on a long run of non-matching events — the worker
  moves its cursor past them. This is what lets a subscription that wants two
  types out of fifty stay caught up cheaply.
- **Filtering is worker-side, before the handler.** A filtered-out event never
  reaches the handler and is therefore never retried or dead-lettered. The filter
  applies in both catch-up and live phases.

For predicates a closed type set cannot express — metadata, stream name, a
tenant id in the payload — set the opaque `selector :: Maybe (RecordedEvent ->
Bool)`. It composes with `eventTypeFilter` as a logical **AND** (an event must
pass both) and obeys the same no-stall / never-retried guarantees:

```haskell
let cfg =
      (defaultSubscriptionConfig name AllStreams handler)
        { eventTypeFilter = OnlyEventTypes (Set.singleton (EventType "OrderPlaced"))
        , selector = Just (\e -> tenantOf e == Just "acme") }
```

Prefer `eventTypeFilter` for the steady state: a `Set EventType` is
introspectable, `Eq`/`Show`-able, and can be pushed into SQL, which an opaque
closure cannot. Reach for `selector` as the escape hatch — especially for one-off
catch-up reprocesses (above).

## At-Least-Once And Idempotency

Delivery is **at-least-once**, and the checkpoint is saved **per batch**, not per
event. When the handler returns `Continue` for a whole batch, the checkpoint
saves at the batch tail; if the worker is cancelled or crashes mid-batch, the
already-processed events redeliver alongside the rest on the next start. A
transient publisher pool error can also trigger a re-fetch and re-broadcast.

The consequence is non-negotiable: **handlers must be idempotent** — processing a
duplicate must not produce a wrong-on-replay result. Either make the side effect
naturally idempotent (upsert by a natural key) or guard it with a domain check (a
unique constraint, a "have I seen this `globalPosition`?" check). The
[projection guide](building-a-projection.md#step-3-write-an-idempotent-handler)
and [process-manager guide](process-managers-and-sagas.md#step-2-make-each-reaction-idempotent)
work this through for read models and workflows respectively. This contract holds
identically across the native, effectful, Streamly, and Shibuya paths.

## Retry And Dead-Letter

Beyond `Continue` / `Stop`, a handler can dispose of a single problematic event
without blocking the whole subscription:

| Return | Effect |
| --- | --- |
| `Continue` | Process the next event. |
| `Stop` | Stop gracefully; checkpoint saved at this event; `wait` resolves `Right ()`. |
| `Retry delay` | Redeliver **this same event** after `delay`, before the checkpoint advances past it. Bounded by `retryPolicy` (default five attempts); on exhaustion the worker dead-letters the event and moves on. State shows `Retrying`. |
| `DeadLetter reason` | Record the event in `kiroku.dead_letters` and **atomically advance the checkpoint past it**, then continue. The event stays immutable in `kiroku.events`; the dead-letter row references it by `event_id` and `global_position`. |

Use `Retry` for *transient* per-event failures (a downstream blip, a lock
timeout) and `DeadLetter` for *permanent* ones (an undecodable payload, a
violated invariant) — `DeadLetter` is what keeps one poison event from stalling
the subscription forever. Reserve a *thrown exception* for "this subscription
cannot proceed safely at all": the worker does **not** catch handler exceptions,
so the thread dies and the exception propagates through `wait`. See
[Per-Event Retry And Dead-Letter](../user/subscriptions.md#per-event-retry-and-dead-letter).

## Backpressure And Overflow

When a subscriber's bounded queue fills because the handler is slower than the
append rate, the publisher applies the `overflowPolicy`:

- `PauseAndResume` (default) — **lossless** recoverable backpressure. The worker
  is marked `Paused`, the publisher stops pushing (it does not drop), and the
  worker drains and re-catches-up from its checkpoint. No event is lost, the
  checkpoint stays monotonic, other subscribers are unaffected.
- `DropSubscription` — fail fast. The worker surfaces `SubscriptionOverflowed`
  through `wait` and terminates. Choose when a slow consumer should be a hard
  error to investigate.
- `DropOldest` — drop the oldest queued batch to admit the new one. The
  subscription continues but **loses events** — choose only for telemetry-style
  consumers where at-least-once is not required.

The default is almost always right: a transient slowdown pauses and recovers
instead of killing the subscription. `queueCapacity` (in *batches*) sets how much
slack the queue holds before the policy engages. See
[Overflow Policy](../user/subscriptions.md#overflow-policy).

## The Effectful API

When the handler must run inside your application's `Eff` stack — to use `State`,
`Reader`, logging, or the `Store` effect itself (the natural choice for a
[process manager](process-managers-and-sagas.md) that reads and appends) — use
the effectful API:

```haskell
import Kiroku.Store.Subscription.Effect (Subscription, withSubscription, subscribe)

-- interpret with `runSubscription store` (re-exported from Kiroku.Store)
runConsumer :: (IOE :> es, Store :> es, Subscription :> es) => Eff es ()
runConsumer = do
  let cfg = defaultSubscriptionConfig name AllStreams handler   -- handler :: RecordedEvent -> Eff es SubscriptionResult
  withSubscription cfg $ \h -> wait h >> pure ()
```

The handler runs in the caller's `Eff` environment, which the interpreter keeps
alive for the worker's lifetime with a `ConcUnlift Persistent (Limited 1)`
strategy: handler calls are single-threaded (one in flight at a time) and
`State`/`Reader` contents stay consistent across the whole subscription. Same
at-least-once, per-batch-checkpoint semantics apply.

Two import facts to remember: the `Subscription` effect and its interpreters
(`runSubscription`, `runSubscriptionResource`) *are* re-exported from
`Kiroku.Store`, but the effectful `subscribe` / `withSubscription` wrappers are
**not** — import `Kiroku.Store.Subscription.Effect` explicitly to avoid clashing
with the `MonadIO` versions. See
[The Effectful API](../user/subscriptions.md#the-effectful-api).

## The Streamly Bridge

To consume events as a pull-based stream and compose Streamly combinators, turn a
subscription into a `Stream` with a bounded `TBQueue` for backpressure:

```haskell
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Streamly.Data.Stream qualified as Stream

(stream, cancelAction) <- subscriptionStream store cfg 256   -- (Stream IO RecordedEvent, IO ())
```

The config's `handler` field is ignored — the bridge installs its own. Note
`subscriptionStream` checkpoints *independently* of the downstream consumer: the
bridge handler returns `Continue` as soon as it enqueues, so the checkpoint can
advance before your stream consumer has actually processed the event.

When the checkpoint **must not** advance until the consumer is done — and the
consumer needs to ask for `Retry` / `DeadLetter` — use the **ack-coupled**
variant `subscriptionAckStream`, which emits `AckItem` values each carrying a
one-shot reply variable. This is the mechanism the Shibuya adapter builds on, so
a downstream acknowledgement drives a real Kiroku checkpoint/retry/dead-letter
decision. See [The Streamly Bridge](../user/subscriptions.md#the-streamly-bridge).

## Driving Subscriptions With The Shibuya Adapter

When you run *several* subscriptions and want them supervised together — failure
isolation, per-subscription metrics, coordinated graceful shutdown, and ack-
coupled checkpointing — drive them through [Shibuya](../user/shibuya-adapter.md),
a queue-processing framework. The `shibuya-kiroku-adapter` package wraps Kiroku's
push-based subscriptions into Shibuya's pull-based `Adapter` interface.

### Creating An Adapter

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
          -- ingested.envelope.payload :: RecordedEvent
          pure AckOk

    Right appHandle <-
      runApp IgnoreFailures 100
        [(ProcessorId "my-projection", mkProcessor adapter handler)]

    waitApp appHandle
```

Build `KirokuAdapterConfig` with `defaultKirokuAdapterConfig name target` and
override fields with record-update syntax. It exposes the same knobs as a native
subscription — `batchSize`, `consumerGroup`, `eventTypeFilter`, `selector` — plus
`bufferSize` (the `TBQueue` capacity). `eventTypeFilter` and `selector` are
forwarded into the underlying subscription and filter **worker-side**, exactly as
above: a filtered-out event never reaches the Shibuya handler, yet the checkpoint
still advances past it. `SubscriptionName`, `SubscriptionTarget`, `ConsumerGroup`,
and `EventTypeFilter` are re-exported from the adapter module, so no separate
`kiroku-store` import is needed. See
[KirokuAdapterConfig](../user/shibuya-adapter.md#creating-an-adapter) for the
full field table.

### Ack Semantics — The Key Difference

The adapter uses the **ack-coupled** bridge, which changes *where the checkpoint
boundary sits*. Unlike the native handler (whose checkpoint advances per batch),
the Kiroku worker here **blocks on each event until the Shibuya handler's
`AckDecision` is finalized**, and only then checkpoints, retries, or
dead-letters. The handler's decision drives Kiroku checkpointing **per event**:

| `AckDecision` | Effect |
| --- | --- |
| `AckOk` | Checkpoint past the event (the normal case). |
| `AckRetry delay` | Redeliver the **same** event after `delay`, bounded by `retryPolicy`; on exhaustion, dead-letter it. |
| `AckDeadLetter reason` | Record in `kiroku.dead_letters` (with `reason` translated to a native `DeadLetterReason`) and advance the checkpoint past it. |
| `AckHalt` | Cancel the subscription **without advancing the checkpoint**, so the halting event replays on restart. |

Return `AckHalt` to stop from inside a handler. This per-event ack coupling makes
the Shibuya path a good fit when "processed" must mean "the downstream handler
genuinely finished," not "handed to an in-memory queue." The usual contract still
holds: at-least-once, idempotent handlers required. See
[Ack Semantics](../user/shibuya-adapter.md#ack-semantics).

### Backpressure And Trace Context

Because delivery is ack-coupled, the Kiroku worker blocks until each decision is
finalized, which **throttles database polling to the handler's consumption
rate** — natural backpressure with no event loss; `bufferSize` sets the slack.
The adapter also maps each `RecordedEvent` into a Shibuya `Envelope`
(`eventId`→`messageId`, `globalPosition`→`cursor`, redelivery count→`attempt`,
and `metadata.traceparent`→`traceContext`), so W3C trace context propagates from
append into Shibuya processing when the producer populates it (see
[OpenTelemetry](../user/opentelemetry.md)). Details in
[Backpressure](../user/shibuya-adapter.md#backpressure) and
[Envelope Mapping](../user/shibuya-adapter.md#envelope-mapping).

## Scaling Out With Consumer Groups

When a single consumer cannot keep up, a **consumer group** splits one logical
subscription across `N` members, each processing a disjoint, per-stream-ordered
slice in parallel — one thread each, in one process or across many. It composes
with every approach above: set the `consumerGroup` field on a native or effectful
config, or use `kirokuConsumerGroupProcessors` to spin up a whole group of
Shibuya processors in one call.

```haskell
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- run m = 0..3, same SubscriptionName, same size, distinct member
let cfg = (defaultSubscriptionConfig name (Category (CategoryName "orders")) handler)
            { consumerGroup = Just ConsumerGroup { member = m, size = 4 } }
```

Partitioning is by originating `stream_id`, so every event from a given stream
always lands on the same member, in order. Three rules govern correctness, all
detailed in [Consumer Groups](../user/consumer-groups.md): uphold the operational
invariant (exactly one live process per member index, all on the same `size`);
treat resizing as stop-the-world; and set `consumerGroupGuard = True` in
production to fail fast on a duplicated member. A size-1 group is exactly an
ordinary subscription.

## Observability

Operating subscriptions in production rests on two complementary signals:

- **Point-in-time state** — `h ^. #currentState` returns `Maybe SubscriptionState`
  (the FSM above): `Just s` while live, `Nothing` once not live. Good for health
  checks and dashboards ("is this subscriber `Just Live`?"). For the aggregate
  view of every live subscription at once, `subscriptionStates store` returns a
  snapshot map of `SubscriptionStateView` records (name, member, state,
  `statePhase` label, `cursor`) without needing each handle — the cheap
  always-available live-state signal, and the substrate for a future Prometheus
  exporter / admin tool.
- **Lifecycle event stream** — the `KirokuEvent` handler (wired via
  `ConnectionSettings.eventHandler`) emits every transition and error:
  `KirokuEventSubscriptionDbError`, `KirokuEventSubscriptionReconnecting`,
  overflow, retry/dead-letter, and consumer-group member/size context
  (`SubscriptionGroupContext`). Route it to your logs and metrics. The Shibuya
  adapter additionally exposes per-subscription metrics through Shibuya itself.

See [Observability](../user/observability.md) for wiring both, and the
[worker-state table](../user/subscriptions.md#worker-states) for what each
transition means. The operational rule of thumb: a healthy subscriber sits in
`Live`; persistent `Paused` means a slow handler, persistent `Reconnecting` means
a flaky connection, and a growing `kiroku.dead_letters` table means poison events
to triage.

## Testing Subscriptions

Subscriptions are deterministic over an input sequence, so they test without
mocks: against an ephemeral PostgreSQL, seed events with `appendToStream`, run
the subscription, and poll an `IO Bool` predicate until the expected events
arrive (a worker is asynchronous, so assert with a bounded wait rather than
immediately). The repository's tests
(`kiroku-store/test/Test/ConsumerGroup.hs`,
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs`) show the seed-run-poll
mechanics, the `Retry` / `DeadLetter` paths, and per-member checkpoint assertions
to model on. Test the replay case explicitly — deliver a duplicate and assert the
handler's effect did not double-apply.

## See Also

- [Subscriptions](../user/subscriptions.md) — the reference for delivery
  semantics, configuration, states, and the Streamly bridge.
- [Consumer Groups](../user/consumer-groups.md) — horizontal scaling, the
  operational invariant, resizing, and the hash caveat.
- [Shibuya Adapter](../user/shibuya-adapter.md) — the full adapter reference:
  config, ack semantics, envelope mapping, dependencies.
- [Reading Events](../user/reading-events.md) — one-shot and streaming reads for
  when you do *not* need a live subscription.
- [Observability](../user/observability.md) — wiring `KirokuEvent` and the pool
  observation handler to logs and metrics.
- [Building A Projection](building-a-projection.md) /
  [Process Managers And Sagas](process-managers-and-sagas.md) — applying these
  consumption patterns to read models and workflows.
