# Building A Projection

A **projection** (or *read model*) is a queryable view derived from the event
log. Events are the source of truth; a projection is a disposable, rebuildable
cache shaped for one read pattern — an "orders awaiting shipment" table, a
running account balance, a search index. This guide builds a projection
end to end: subscribe to the relevant events, apply each one to a read model
with an **idempotent** write, and let the subscription's durable checkpoint
track progress across restarts. It then covers rebuilds, scaling, failure
handling, and the alternative of projecting *into the store itself* with links.

Read [Subscriptions](../user/subscriptions.md) and
[Reading Events](../user/reading-events.md) first — this guide composes those
primitives rather than re-deriving them.

## The Shape Of A Projection

Every Kiroku projection has the same three moving parts:

1. **A subscription** that delivers events in order, catching up from history
   and then following live appends. Its `SubscriptionName` *is* the projection's
   durable cursor — reuse the name across restarts to resume.
2. **A handler** that decodes each event and updates the read model. The handler
   is the only place projection-specific logic lives.
3. **A read model** — a table, document, or index you write to and your
   application queries. It is rebuildable from the log, so it carries no
   information the events do not.

```text
            ┌─────────────┐   RecordedEvent   ┌──────────┐   upsert   ┌────────────┐
  $all  ──▶ │ subscription │ ───────────────▶ │ handler  │ ─────────▶ │ read model │ ──▶ queries
            └─────────────┘                   └──────────┘            └────────────┘
                   │
              checkpoint (keyed by SubscriptionName)
```

The single most important property to internalize: **the subscription
checkpoint and your read-model write are not one atomic unit.** Delivery is
at-least-once and the checkpoint advances per *batch* (see
[Delivery Semantics](../user/subscriptions.md#delivery-semantics)). A crash
between applying an event and saving the checkpoint replays that event on the
next start. Therefore **every projection handler must be idempotent** — applying
the same event twice must leave the read model in the same state as applying it
once. Everything else in this guide follows from that one rule.

## Step 1: Choose The Target

A projection subscribes to either the whole log or one category:

- `AllStreams` — every event in global-position order. Use when the read model
  spans many categories (a global audit view, a cross-aggregate dashboard).
- `Category categoryName` — only events whose source stream's name prefix
  matches. Use when the read model is built from one aggregate type. A category
  is the substring of a stream name before the first `-`: `StreamName "orders-1"`
  lives in `CategoryName "orders"`.

Prefer the narrowest target that still feeds the read model: a `Category`
subscription does strictly less work than filtering `AllStreams` in the handler,
and it documents intent. When you need a subset of *types* within a target, set
`eventTypeFilter` rather than branching in the handler — filtered-out events
still advance the checkpoint, so a selective projection never stalls (see
[Event-Type Filtering](../user/subscriptions.md#event-type-filtering)).

## Step 2: Define The Read Model

The read model is plain application storage — Kiroku does not manage it. A
PostgreSQL table is the common choice; it can live in the same database as the
event store (in your own schema, *not* the `kiroku` schema) or in a separate
system entirely.

For a worked example, project `orders-*` events into an order-summary table:

```sql
CREATE TABLE IF NOT EXISTS read_model.order_summary
  ( order_id    text PRIMARY KEY
  , status      text        NOT NULL
  , total_cents bigint      NOT NULL DEFAULT 0
  , updated_at  timestamptz NOT NULL DEFAULT now()
  );
```

Give the read model a natural key from the event payload (`order_id` here), not
the event's `globalPosition`. The key is what makes writes idempotent.

## Step 3: Write An Idempotent Handler

The handler receives one `RecordedEvent` at a time and returns a
`SubscriptionResult`. For a projection the steady-state answer is `Continue`;
the read-model write happens as a side effect before returning.

The write must be idempotent. The two reliable techniques are:

- **Upsert by natural key** — `INSERT ... ON CONFLICT (order_id) DO UPDATE`.
  Re-applying `OrderPlaced` overwrites the same row; the result is identical.
- **Set, don't accumulate, where you can** — `status = 'shipped'` is replay-safe;
  `total_cents = total_cents + :delta` is *not*, because a replayed event double
  counts. When you must accumulate, make the accumulation itself idempotent — for
  example by recording which `globalPosition`s have already been folded in, or by
  recomputing the total from a set rather than incrementing.

The handler closes over a Hasql connection pool taken from the store handle
(`store ^. #pool`) and runs its write with `Hasql.Pool.use`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Aeson.Lens (key, _Integral, _String)
import Data.Text (Text)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Kiroku.Store
import Kiroku.Store.Subscription

-- | Apply one order event to the read model. Returns 'Continue' so the
-- subscription advances; any thrown exception stops the worker (see below).
orderSummaryHandler :: Pool.Pool -> RecordedEvent -> IO SubscriptionResult
orderSummaryHandler pool event = do
  case event ^. #eventType of
    EventType "OrderPlaced" -> do
      let oid   = event ^. #payload ^? key "orderId" . _String
          total = event ^. #payload ^? key "totalCents" . _Integral
      runWrite pool (upsertPlaced (orDie oid) (maybe 0 id total))
    EventType "OrderShipped" ->
      runWrite pool (setStatus (orderIdOf event) "shipped")
    EventType "OrderCancelled" ->
      runWrite pool (setStatus (orderIdOf event) "cancelled")
    _ -> pure ()             -- not ours; checkpoint still advances
  pure Continue

runWrite :: Pool.Pool -> Session.Session () -> IO ()
runWrite pool session = do
  result <- Pool.use pool session
  either (ioError . userError . show) pure result
```

`upsertPlaced` / `setStatus` are ordinary Hasql `Statement`s wrapped in a
`Session`; the SQL behind `upsertPlaced` is the idempotent upsert:

```sql
INSERT INTO read_model.order_summary (order_id, status, total_cents)
VALUES ($1, 'placed', $2)
ON CONFLICT (order_id)
  DO UPDATE SET status = EXCLUDED.status, total_cents = EXCLUDED.total_cents,
                updated_at = now();
```

Three handler facts worth stating plainly:

- **A thrown exception is fatal.** The worker does not catch handler exceptions;
  the thread dies and the exception surfaces through `wait` (see
  [Lifecycle And Failure Modes](../user/subscriptions.md#lifecycle-and-failure-modes)).
  This is deliberate: if the read-model write genuinely cannot proceed, halting is
  safer than skipping. For *expected, per-event* failures (a malformed payload,
  a transiently unavailable downstream) prefer returning `Retry` or `DeadLetter`
  over throwing — see [Handling Failure](#handling-failure).
- **Unrecognized types fall through to `Continue`.** Because the checkpoint
  advances past them, a projection that cares about three event types out of
  thirty does not stall on the other twenty-seven. If the target is a single
  category and you want the database to skip non-matching *types* entirely, set
  `eventTypeFilter` instead.
- **Decode defensively.** `RecordedEvent.payload` is arbitrary JSONB. Treat a
  missing or wrong-typed field as a real condition (dead-letter it), not an
  `error` call that takes the worker down.

## Step 4: Run The Subscription

Build the config with `defaultSubscriptionConfig name target handler` and run it
under `withSubscription`, which cancels the worker on normal exit or exception:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Kiroku.Store
import Kiroku.Store.Subscription

runOrderSummary :: KirokuStore -> IO ()
runOrderSummary store = do
  let pool = store ^. #pool
      cfg  =
        defaultSubscriptionConfig
          (SubscriptionName "order-summary")            -- the durable cursor
          (Category (CategoryName "orders"))
          (orderSummaryHandler pool)
  withSubscription store cfg $ \h -> do
    result <- wait h            -- blocks until Stop, cancel, or failure
    print result
```

On first start with a fresh `SubscriptionName`, the worker is in `CatchingUp`:
it reads history from `globalPosition` 0 in `batchSize` pages and applies every
matching event. When it reaches the publisher's live cursor it transitions to
`Live` and follows new appends via `NOTIFY`. Read the current phase at any time
with `h ^. #currentState` (see
[Worker States](../user/subscriptions.md#worker-states)); wire the `KirokuEvent`
lifecycle stream for the history of transitions (see
[Observability](../user/observability.md)).

That is a complete, restart-safe projection. Stop the process and start it again
with the same `SubscriptionName` and it resumes from its checkpoint, replaying at
most the last partially-checkpointed batch — which the idempotent upsert absorbs.

## Rebuilding A Projection

Because a projection holds no information the log does not, you can throw it away
and rebuild it from scratch. This is the routine answer to "the read model shape
changed" or "the read model is corrupt." There are two rebuild strategies.

**Rebuild in place under a new subscription name.** Truncate the read model and
start the subscription under a *fresh* `SubscriptionName`. The new name has no
checkpoint, so the worker catches up from `globalPosition` 0 over the whole
history:

```haskell
-- 1. TRUNCATE read_model.order_summary;
-- 2. Start with a new name so catch-up runs from the beginning:
let cfg = defaultSubscriptionConfig
            (SubscriptionName "order-summary-v2")        -- new name → full replay
            (Category (CategoryName "orders"))
            (orderSummaryHandler pool)
```

Bumping the name (`-v2`) is the cleanest trigger for a full rebuild and leaves
the old checkpoint row untouched for rollback. Keep the name in configuration so
a rebuild is a config change, not a code change.

**Blue/green rebuild with zero read downtime.** Build the new read model into a
*new* table under a new subscription name while the old projection keeps serving
queries. When the new subscription reaches `Live` (observe `currentState`), flip
your application's reads to the new table and retire the old subscription. This
is the standard way to ship a breaking read-model change without a maintenance
window.

Either way, the rebuild is bounded by how fast the handler can apply the full
history. For a large log, raise `batchSize` to cut round-trips during catch-up,
and consider a consumer group (below) to parallelize the apply.

## Scaling With A Consumer Group

A single worker applies events sequentially. When the apply rate cannot keep up
— a slow handler, a very high append rate — scale horizontally with a
[consumer group](../user/consumer-groups.md): `N` members split the source by
*originating stream*, each applying a disjoint slice in parallel while preserving
per-stream order.

```haskell
import Kiroku.Store.Subscription.Types (ConsumerGroup (..))

-- member m of a size-4 group; run m = 0..3, same SubscriptionName, same size
let cfg =
      (defaultSubscriptionConfig
        (SubscriptionName "order-summary")
        (Category (CategoryName "orders"))
        (orderSummaryHandler pool))
        { consumerGroup = Just ConsumerGroup { member = m, size = 4 } }
```

Partitioning is by source `stream_id`, so all events for one order always land
on the same member, in order — which is exactly what a per-order upsert needs.
Two consequences to design around:

- **The read model must tolerate concurrent writers.** Different members write
  different rows (different orders), so per-row upserts are safe. Avoid
  read-modify-write across *the same* row from logic that could span members; key
  every write by the partitioned stream's natural id.
- **Resizing is stop-the-world.** Changing `size` re-buckets every stream; never
  run two sizes at once. See
  [Resizing The Group](../user/consumer-groups.md#resizing-the-group).

Uphold the [operational invariant](../user/consumer-groups.md#operational-invariant):
exactly one live process per member index, all members on the same `size`. Set
`consumerGroupGuard = True` in production to fail fast on a duplicated member.

## Handling Failure

A projection handler has four dispositions beyond the implicit "throw to halt":

| Return | Use for |
| --- | --- |
| `Continue` | The normal path: applied successfully, advance. |
| `Retry delay` | A *transient* failure on this event — a downstream blip, a lock timeout. The same event redelivers after `delay`, bounded by `retryPolicy` (default five attempts); on exhaustion the worker dead-letters it and moves on. |
| `DeadLetter reason` | A *permanent* per-event failure — a payload the handler cannot decode, a violated invariant. The event is recorded in `kiroku.dead_letters` and the checkpoint advances past it, so one poison event never stalls the projection. |
| `Stop` | Shut the projection down cleanly at this event (checkpoint saved here). |

Reserve a *thrown exception* for "the projection cannot safely continue at all"
(the read-model database is unreachable). Use `Retry` / `DeadLetter` for
conditions scoped to a single event — they keep the rest of the projection
moving. See
[Per-Event Retry And Dead-Letter](../user/subscriptions.md#per-event-retry-and-dead-letter).

If the handler is slower than the append rate, the default `PauseAndResume`
overflow policy is lossless: the worker pauses, drains, and re-catches-up from
its checkpoint rather than dropping events. Only choose `DropOldest` for
telemetry-style projections where missing events is acceptable. See
[Overflow Policy](../user/subscriptions.md#overflow-policy).

## When You Need The Checkpoint And The Write To Be Atomic

The default model — idempotent handler, checkpoint advances independently — is
the right one for the vast majority of projections, because idempotent upserts
make at-least-once delivery harmless. Reach for transactional coupling only when
the read-model write genuinely *cannot* be made idempotent and a duplicate would
corrupt it.

Kiroku does not expose the subscription checkpoint for you to write inside your
own transaction, so true exactly-once across "save checkpoint + apply" is not
available through the subscription API. The supported atomic pattern is the
inverse: when the act of projecting is *itself an append* — you are deriving a
new event stream from existing ones — use `runTransactionAppending` to write the
derived event and any side-table row in one ACID transaction:

```haskell
import Kiroku.Store.Transaction (runTransactionAppending)
import Hasql.Transaction qualified as Tx

-- append a derived event AND a projection row atomically
runTransactionAppending stream AnyVersion derivedEvents $ \ar -> do
  let StreamId sid = ar ^. #streamId
  Tx.statement (sid, projectionRow) insertProjectionRowStmt
  pure ar
```

The continuation runs in the *same* transaction as the append and can `Tx.condemn`
to roll back both writes. See
[Transactional Appends](../user/appending-events.md#transactional-appends). For
the common case, stay with the idempotent-handler model — it is simpler and
fails safely.

## Projecting Into The Store With Links

When the read model is naturally "a curated stream of existing events" rather
than a derived table, you can project *inside* Kiroku with `linkToStream`
instead of an external store. Linking shares the original event into a new
stream — no copy, no new `$all` position — so a projection stream like
`account-activity-456` can gather the relevant `orders-*`, `payments-*`, and
`refunds-*` events into one ordered, durable, readable stream:

```haskell
-- inside a handler reacting to a relevant source event
linkToStream (StreamName "account-activity-456") [event ^. #eventId]
```

Treat the duplicate-link error as the idempotency signal on replay (the same
event is already linked into the same target). This is the right tool for
account timelines, review queues, and "close the books" period streams; see
[Linking Events](../user/linking.md) for the full model and the close-the-books
pattern. For a queryable, *shaped* read model (counts, statuses, aggregates),
project to an external table as above.

## Testing A Projection

Projections are deterministic functions of an event sequence, which makes them
straightforward to test: append a known sequence, run the subscription until it
catches up, and assert on the read model. The repository's subscription and
consumer-group tests (`kiroku-store/test/Test/ConsumerGroup.hs`,
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs`) show the mechanics —
seed events with `appendToStream`, run a handler that collects or writes results,
and poll until the expected count arrives. Drive it against an ephemeral
PostgreSQL so each test starts from an empty log.

## See Also

- [Consuming The Event Log](consuming-the-event-log.md) — the comprehensive
  subscriptions guide a projection's delivery rests on: catch-up, filtering,
  retry/dead-letter, backpressure, and the Shibuya adapter.
- [Subscriptions](../user/subscriptions.md) — delivery semantics, checkpoints,
  overflow, retry/dead-letter, and the effectful API the handler can run in.
- [Consumer Groups](../user/consumer-groups.md) — parallelize a projection while
  preserving per-stream order.
- [Reading Events](../user/reading-events.md) — the `RecordedEvent` fields a
  handler decodes, and `lookupStreamNames` for resolving source stream names.
- [Linking Events](../user/linking.md) — project into a curated in-store stream.
- [Appending Events › Transactional Appends](../user/appending-events.md#transactional-appends)
  — atomically couple a derived append with a side-table write.
- [Process Managers And Sagas](process-managers-and-sagas.md) — the companion
  pattern: react to events by *issuing commands*, not just updating a view.
