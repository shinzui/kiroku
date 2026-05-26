# Subscription Architecture

This document explains Kiroku's subscription runtime as an implementation
guide for maintainers. The user-facing API is documented in
[`docs/user/subscriptions.md`](../user/subscriptions.md), the Shibuya adapter
API is documented in [`docs/user/shibuya-adapter.md`](../user/shibuya-adapter.md),
and the schema reference is documented in [`docs/user/schema.md`](../user/schema.md).

The subscription system turns the append-only event log into an in-process,
at-least-once event feed. A subscription has a stable name, reads from either
`$all` or a stream category, persists a global-position checkpoint, catches up
from PostgreSQL, and then switches to a live loop driven by PostgreSQL
`LISTEN`/`NOTIFY` plus bounded in-memory queues.

## Source Map

The main implementation is split across these modules:

| Area | File | Responsibility |
| --- | --- | --- |
| Public native API | `kiroku-store/src/Kiroku/Store/Subscription.hs` | `subscribe`, `withSubscription`, lifecycle contract, worker startup. |
| Public types | `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` | `SubscriptionConfig`, targets, overflow policy, handles, consumer groups. |
| PostgreSQL listener | `kiroku-store/src/Kiroku/Store/Notification.hs` | Dedicated `LISTEN` connection, reconnect loop, global ticks, category wake counters. |
| Shared publisher | `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` | Reads new `$all` events once and broadcasts batches to all-stream subscribers. |
| Worker runtime | `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` | Checkpoint load/save, catch-up, live loops, event handler execution. |
| Streamly bridge | `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` | Converts the push handler API into a pull-based `Stream IO RecordedEvent`. |
| Effectful API | `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` | `Subscription` effect and interpreter for handlers that run in `Eff`. |
| SQL | `kiroku-store/src/Kiroku/Store/SQL.hs` | `$all`, category, consumer-group, and checkpoint statements. |
| Schema | `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` | `subscriptions` table and `notify_events()` trigger. |
| Shibuya adapter | `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` | Shibuya `Adapter` backed by `subscriptionStream`. |
| Shibuya conversion | `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` | `RecordedEvent` to Shibuya `Ingested`/`Envelope` mapping. |

## Runtime Shape

Opening a `KirokuStore` starts two long-lived subscription services:

1. `Notifier`: owns one dedicated PostgreSQL connection and issues
   `LISTEN <schema>.events`.
2. `EventPublisher`: owns one background thread that consumes notifier ticks,
   reads newly appended `$all` events, and fans those batches out to registered
   subscribers.

Each call to `subscribe` then registers a subscriber queue with the
`EventPublisher` and starts one worker thread.

```text
PostgreSQL append
  |
  v
streams INSERT/UPDATE trigger
  |
  v
pg_notify('<schema>.events', 'stream_name,stream_id,stream_version')
  |
  v
Notifier dedicated LISTEN connection
  |                         |
  | writes () to tick TChan | bumps categoryGenerations[category]
  v                         v
EventPublisher              Category workers
  |
  | reads $all after lastPublished
  v
per-subscriber TBQueue (Vector RecordedEvent)
  |
  v
AllStreams workers
```

The `Notifier` is the only part that waits directly on PostgreSQL
notifications. It writes unit ticks to a broadcast `TChan`, preserving a simple
global wake-up path for the publisher, and also increments a per-category
generation counter. The payload is comma-delimited as
`stream_name,stream_id,stream_version`; the notifier recovers the category from
the stream name prefix before the first `-`.

The `EventPublisher` is deliberately centralised. Without it, every all-stream
subscription would run its own live SQL poll after each notification. With it,
the process reads each new `$all` batch once and shares that vector with all
currently registered all-stream subscribers.

## Durable Cursor Model

Every subscription cursor is a `$all` global position. This is true even for a
category subscription. A category worker skips non-matching events, but its
checkpoint still says "the last global position this worker has safely
processed".

The checkpoint lives in the `subscriptions` table:

| Column | Meaning for subscriptions |
| --- | --- |
| `subscription_name` | Stable logical subscription name. Reuse this name to resume after restart. |
| `consumer_group_member` | Member index for grouped subscriptions. Non-group subscriptions use member `0`. |
| `last_seen` | Last successfully processed global position. |
| `updated_at` | Last checkpoint write time. |
| `stream_name` | Present for historical/schema compatibility; current checkpoint helpers rely on the default `'$all'`. |
| `consumer_group_size` | Present in the schema, but the current checkpoint save statement does not write it, so it remains the default unless a future path updates it. |

The unique checkpoint key is `(subscription_name, consumer_group_member)`.
This lets ordinary subscriptions have one row and consumer groups have one row
per member under one shared `subscription_name`.

Checkpoint writes use `GREATEST(existing.last_seen, new.last_seen)`, so a stale
batch, retry boundary, or duplicate save cannot move the durable checkpoint
backward. The worker normally processes events in increasing global-position
order, but this SQL invariant is the final guardrail.

## Worker Lifecycle

`subscribe store config` performs these steps:

1. Validate `consumerGroup`, if present: `size >= 1` and
   `0 <= member < size`.
2. Register a bounded `TBQueue (Vector RecordedEvent)` with the
   `EventPublisher`, receiving the queue, a status `TVar`, and an
   `unsubscribe` action.
3. Start `runWorker` in an async thread.
4. Return `SubscriptionHandle { cancel, wait }`.

The worker itself has two phases:

1. Catch-up: load checkpoint and query PostgreSQL directly until the cursor
   reaches the publisher's `lastPublished` position.
2. Live: wait for new work using the strategy appropriate for the target and
   consumer-group mode.

The worker always invokes the configured handler sequentially. There is no
parallel handler execution inside a single subscription. After a full batch
returns `Continue`, the worker saves the checkpoint at the batch tail. If a
handler returns `Stop`, the worker saves the checkpoint at that event and exits.

Cancellation and crashes are at-least-once boundaries. If the process stops
after the handler has seen an event but before the checkpoint is saved, that
event is replayed on restart.

## `TBQueue` Usage

There are two separate `TBQueue` roles in the architecture.

### Publisher Subscriber Queues

The `EventPublisher` creates one bounded `TBQueue (Vector RecordedEvent)` for
each native subscription. The capacity is `SubscriptionConfig.queueCapacity`,
measured in batches, not individual events. Publisher batches are currently up
to `1000` events, so a capacity of `16` means a subscriber can buffer roughly
`16 * 1000` live all-stream events.

These queues protect the process from unbounded memory growth. If a subscriber
falls behind, the publisher applies that subscriber's `OverflowPolicy`:

| Policy | Behavior | When to use |
| --- | --- | --- |
| `DropSubscription` | Mark the subscriber status as `Overflowed`. The worker observes this and throws `SubscriptionOverflowed`, which surfaces through `wait`. | Default for correctness-preserving projections. |
| `DropOldest` | Remove the oldest queued batch and enqueue the new batch. The subscription keeps running but loses events. | Only for telemetry or best-effort consumers that can tolerate loss. |

All-stream live workers read these publisher queues. Category live workers do
not use them after catch-up; see "Category Subscriptions".

### Streamly/Shibuya Bridge Queue

`subscriptionStream` creates another bounded `TBQueue`, this time containing
`Maybe RecordedEvent`. It replaces the caller's handler with a bridge handler
that writes `Just event` to the queue and returns `Continue`. The returned
Streamly stream reads from that queue. Cancellation writes a `Nothing` sentinel
so a blocked stream reader wakes and terminates.

This bridge queue provides backpressure between Kiroku's push-style
subscription worker and pull-style stream consumers. If the stream consumer is
slow, the bridge handler blocks on `writeTBQueue`, which slows the worker and
therefore slows catch-up/live reads.

The bridge queue is in-memory. The Kiroku worker considers an event processed
once the bridge handler has successfully written it to the queue and the batch
checkpoint has been saved. It does not know whether a downstream Streamly or
Shibuya consumer has processed the event yet. This is acceptable for stream
consumers that treat the stream as an in-process handoff, but it is not the same
end-to-end durability boundary as a native subscription whose handler performs
the projection work directly.

The Shibuya adapter builds on this second queue, not directly on the
publisher's queue.

## `LISTEN`/`NOTIFY`

The schema installs `notify_events()` and `stream_events_notify` on the
`streams` table. The trigger publishes to `TG_TABLE_SCHEMA || '.events'` with a
payload containing stream name, stream id, and stream version.

The `Notifier` listens on `ConnectionSettings.schema <> ".events"`. For
notifications to wake subscriptions promptly, the configured schema and the
actual schema containing Kiroku tables must match. If they do not match,
subscriptions still have safety polls, but they will no longer wake promptly on
append.

The listener loop is designed for long-running production processes:

- It uses a dedicated PostgreSQL connection, separate from the Hasql pool.
- It tags the connection with `application_name = 'kiroku-listener'` when
  possible.
- If the listener connection fails, it reconnects with capped exponential
  backoff.
- It emits observability events for reconnect attempts and successes when an
  event hook is configured.
- `stopNotifier` cancels the listener thread and releases the current
  connection, including a replacement connection acquired after reconnect.

`LISTEN`/`NOTIFY` is only a wake-up mechanism. The event payload is not trusted
as the source of event data. Workers always read real event rows from
PostgreSQL before invoking handlers.

Safety polls cover missed notifications:

- `EventPublisher` wakes every 30 seconds even without a tick.
- Category workers wake every 30 seconds even if their category generation
  counter has not changed.
- Fetch errors retry at the same cursor with capped backoff, so transient
  database failures do not advance checkpoints.

## `$all` Subscriptions

`AllStreams` means every event in global position order. The source of truth is
the `$all` stream, represented by `stream_events.stream_id = 0`. For `$all`
rows, `stream_events.stream_version` is the global position.

The all-stream path is:

1. The worker registers its publisher queue before catch-up starts.
2. Catch-up reads via `SQL.readAllForwardStmt` from the durable checkpoint.
3. When the cursor reaches the publisher's `lastPublished` value, the worker
   switches to live mode.
4. Live mode reads vectors from the publisher queue.
5. The worker filters out queued events with `globalPosition <= cursor`.

That last filter matters. The worker registers with the publisher before
catch-up so it does not miss live events appended during catch-up. Those same
events may also be read by the catch-up SQL query. Filtering stale queue
entries prevents duplicate live delivery and prevents an old batch from trying
to move the checkpoint backward.

The publisher's own cursor, `lastPublished`, starts at the current database tail
when the store opens. This avoids rebroadcasting the whole historical log on
process start. Catch-up remains each worker's responsibility.

## Category Subscriptions

`Category categoryName` means events whose source stream belongs to a category.
Kiroku derives a stream's category from the prefix before the first `-`, and
stores it in `streams.category`.

Category reads use `SQL.readCategoryForwardStmt`:

- Find streams with `streams.category = category`.
- For each stream, find matching `$all` rows by `original_stream_id`.
- Return the matching events ordered by `$all` global position.
- Use the subscription cursor as a global-position lower bound.

Category subscriptions keep global-position checkpoints, so their observed
positions may have gaps relative to `$all`. For example, if positions 10 and 13
belong to category `invoice`, the category checkpoint moves from 10 to 13 after
processing 13; positions 11 and 12 are irrelevant to that subscription.

Ordinary non-group category live mode does not consume the publisher's
broadcast queue. Instead, the `Notifier` increments
`categoryGenerations[category]` when a notification payload identifies that
category. The category worker:

1. Snapshots the current category generation.
2. Drains all currently available category events from PostgreSQL.
3. Blocks until that category's generation increases, or the 30-second safety
   timer fires.
4. Drains again.

This avoids the earlier bad shape where an idle category could re-query the
database on every unrelated global append. An idle category now costs no live
database work except the safety poll.

## Consumer-Group Subscriptions

Consumer groups split one logical subscription across statically configured
members. A config with `consumerGroup = Just (ConsumerGroup member size)` means
"this worker owns member `member` out of `size` members".

Partitioning is stream-based, not event-based:

```text
slot(stream_id) =
  (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

A member receives an event only when the originating stream's slot equals that
member. This preserves per-stream order because all events for one originating
stream go to the same member.

Consumer groups use member-aware SQL:

- `$all`: `SQL.readAllForwardConsumerGroupStmt`
- category: `SQL.readCategoryForwardConsumerGroupStmt`
- checkpoint load: `SQL.getCheckpointMemberStmt`
- checkpoint save: `SQL.saveCheckpointMemberStmt`

Consumer-group live mode is DB-driven for both `$all` and category targets. It
does not use the all-stream publisher queue, because that queue contains
unpartitioned `$all` batches and the partition predicate is PostgreSQL's hash
over the originating stream id. Re-querying with the partition predicate in SQL
is the current source of truth.

The DB-driven live loop waits for the publisher's global `lastPublished` value
to advance beyond the last observed global position, then drains this member's
partition from PostgreSQL. It does not wait for `lastPublished > memberCursor`,
because a member cursor may lag behind unrelated partitions forever; that shape
causes busy loops when other members own the latest events.

`consumerGroupGuard` is an optional startup probe. When enabled, the worker
uses a transaction-scoped advisory lock to detect a concurrently starting
process with the same `(subscription_name, member)`. This is only a startup
detection check; it is not a lifetime-held lock. Operationally, deployments
must still ensure exactly one live process owns each member index at a time.

## Subscription Types And APIs

Kiroku currently exposes the same underlying worker through several API shapes.

### Native `MonadIO` API

`Kiroku.Store.Subscription.subscribe` starts the worker and returns a
`SubscriptionHandle`. `withSubscription` brackets startup and cancellation and
is the preferred shape for application code.

Use this when a process has one or a small number of direct in-process
projection workers and does not need a stream abstraction or Shibuya
supervision.

### Effectful API

`Kiroku.Store.Subscription.Effect` exposes a higher-order `Subscription` effect.
The handler runs in the caller's `Eff` stack, so it can use local reader, state,
logging, tracing, or other effects.

The interpreter uses `ConcUnlift Persistent (Limited 1)`. This matches the
worker's execution model: one handler call at a time, with an effect
environment that survives repeated calls. Do not relax this without changing
the worker's sequential processing contract.

### Streamly Bridge

`subscriptionStream` adapts a native subscription into
`Stream IO RecordedEvent`. The bridge installs its own handler, writes events
to a bounded `TBQueue`, and returns a stream plus a cancel action.

Use this when downstream code wants a pull-based stream rather than a callback.
The Shibuya adapter uses this path.

### Shibuya Adapter

`shibuya-kiroku-adapter` exposes `kirokuAdapter`, which returns a Shibuya
`Adapter es RecordedEvent`.

The adapter:

1. Builds a `SubscriptionConfig` from `defaultSubscriptionConfig`.
2. Overrides `batchSize`, `queueCapacity = 16`, `overflowPolicy =
   DropSubscription`, and `consumerGroup`.
3. Calls `subscriptionStream store subConfig bufferSize`.
4. Lifts `Stream IO RecordedEvent` into `Stream (Eff es) RecordedEvent` with
   `Stream.morphInner liftIO`.
5. Converts each `RecordedEvent` into Shibuya `Ingested`.

There are therefore three buffering layers in a Shibuya-backed subscription:

```text
EventPublisher TBQueue
  - batches for Kiroku all-stream live mode
  - governed by queueCapacity and OverflowPolicy

subscriptionStream TBQueue
  - individual RecordedEvent values for Streamly/Shibuya
  - governed by KirokuAdapterConfig.bufferSize

Shibuya bounded inbox
  - Ingested messages between Shibuya ingester and processor
  - governed by runApp inboxSize
```

For category and consumer-group subscriptions, the first queue is still
registered today by `subscribe`, but those live loops bypass it after catch-up.
The bridge queue and Shibuya inbox still apply.

## Shibuya Envelope And Ack Semantics

The Shibuya adapter maps Kiroku events into Shibuya's generic processing model:

| Kiroku `RecordedEvent` | Shibuya field |
| --- | --- |
| `eventId` | `Envelope.messageId` |
| `globalPosition` | `Envelope.cursor = CursorInt position` |
| `createdAt` | `Envelope.enqueuedAt` |
| `metadata.traceparent` and optional `tracestate` | `Envelope.traceContext` |
| full `RecordedEvent` | `Envelope.payload` |
| no Kiroku partition value | `Envelope.partition = Nothing` |
| no Kiroku retry counter | `Envelope.attempt = Nothing` |

Kiroku is an event log, not a message queue. The event is already durable, and
the Kiroku worker owns checkpoint advancement. Shibuya acknowledgements are
therefore mostly semantic at this adapter boundary:

| Shibuya `AckDecision` | Adapter effect |
| --- | --- |
| `AckOk` | No-op. Kiroku checkpointing has already happened at the Kiroku worker/bridge boundary. |
| `AckRetry` | No-op. There is no per-message redelivery request in the current adapter. |
| `AckDeadLetter` | No-op. Kiroku does not currently have a dead-letter table in the implemented adapter path. |
| `AckHalt` | Calls the subscription cancel action. |

This has two important consequences:

- A Shibuya handler returning `AckRetry` does not cause Kiroku to replay that
  event immediately.
- The durable Kiroku checkpoint can advance after the event has been written to
  the in-memory `subscriptionStream` queue, before the Shibuya handler has
  completed. If the process crashes in that window, restart resumes after the
  saved checkpoint and the queued-but-unprocessed event can be skipped by the
  Shibuya handler.

In other words, the current Shibuya adapter is supervised and backpressured,
but its checkpoint boundary is the Kiroku-to-Streamly handoff, not Shibuya
`AckOk`. If a Shibuya-backed projection needs end-to-end at-least-once
semantics, the architecture needs an ack-aware Kiroku worker/adapter path where
checkpoint advancement happens after the Shibuya decision.

## Delivery Guarantees

The implemented guarantee is at-least-once, in increasing global-position order
within each worker's selected event set.

What the system guarantees:

- `$all` subscriptions see global positions in order.
- Category subscriptions see matching events in global-position order.
- Consumer-group members see their assigned events in global-position order.
- Checkpoints never move backward.
- A restart resumes from the durable checkpoint for the same
  `(subscription_name, consumer_group_member)`.
- Missed notifications are repaired by safety polls.

What callers must assume:

- Duplicates can happen around cancellation, crash, handler exception,
  checkpoint save failure, or catch-up/live race boundaries.
- Handlers must be idempotent or protected by domain-level uniqueness.
- `DropOldest` explicitly gives up at-least-once delivery for that subscriber.
- `AckRetry` in the Shibuya adapter does not currently perform a Kiroku retry.
- The Shibuya adapter's current checkpoint boundary is enqueue into an
  in-memory bridge queue, not downstream Shibuya handler acknowledgement.

## Observability And Failure Modes

The subscription runtime emits structured `KirokuEvent` values when an event
handler hook is configured on the store:

| Event family | Emitted by | Meaning |
| --- | --- | --- |
| notifier reconnecting/reconnected | `Notifier` | Dedicated `LISTEN` connection failed and is being restored. |
| publisher pool error | `EventPublisher` | Publisher could not read `$all`; it will retry on later wake/safety poll. |
| subscription started | `Worker` | Checkpoint was loaded and the worker is beginning catch-up. |
| subscription caught up | `Worker` | Catch-up completed and live mode is starting. |
| subscription DB error | `Worker` | Checkpoint load, fetch, or save failed. Fetches retry at same cursor; save failures mean replay on restart. |
| subscription fetched | `Worker` | DB-driven live loops fetched a batch. |
| subscription stopped | `Worker` | Worker exited due to handler stop, cancellation, overflow, or crash. |

Operator-visible failure modes:

- Listener connection loss: reconnect loop runs; safety polls bound delivery
  delay after recovery.
- Publisher database error: publisher logs an event and retries later without
  advancing `lastPublished`.
- Worker fetch error: worker logs an event and retries the same cursor with
  backoff.
- Checkpoint save error: worker logs an event and continues; restart may replay
  already handled events.
- Queue overflow with `DropSubscription`: worker fails with
  `SubscriptionOverflowed`.
- Handler exception: worker dies and `wait` returns the exception.

## Design Invariants

Future changes should preserve these invariants unless they deliberately change
the public contract and update the docs/tests with that change:

- `subscriptions.last_seen` is always a `$all` global position.
- Checkpoint writes are monotonic.
- A worker never invokes more than one handler call at a time.
- Live all-stream delivery must not miss appends that happen while catch-up is
  running.
- Live all-stream delivery must filter stale queued events after catch-up.
- Category live mode should not query the database for every unrelated append.
- Consumer-group partitioning must remain stream-stable.
- Consumer-group members must checkpoint independently.
- `LISTEN`/`NOTIFY` wakes the system but is not the data source.
- Safety polls remain as a backstop for missed notifications.
- Bounded queues must stay bounded; slow consumers need backpressure or an
  explicit overflow decision, not unbounded memory growth.

## Improvement Areas

These are the main places to improve the architecture without rediscovering
old decisions:

- Populate `subscriptions.consumer_group_size` from the current
  `ConsumerGroup.size`, or remove/document it as schema-only metadata. Today
  the column exists but the normal checkpoint writer does not update it.
- Consider avoiding publisher-queue registration for live paths that never read
  the queue, such as ordinary category subscriptions and consumer-group
  subscriptions. Any change must preserve the catch-up/live no-missed-event
  invariant.
- Replace the comma-delimited `notify_events()` payload with JSON if external
  listeners or stream names containing commas become important.
- Make `consumerGroupGuard` a lifetime-held session-level guard if the runtime
  should enforce one live owner per member rather than only detecting startup
  overlap.
- Add an ack-aware Shibuya adapter path if Shibuya-backed projections need
  end-to-end at-least-once semantics. That likely means moving checkpoint
  advancement after `AckOk`, and making `AckRetry`/`AckDeadLetter` first-class
  Kiroku worker outcomes.
- Revisit publisher batching and queue sizing with production metrics. The
  current publisher batch size is fixed at `1000`, while subscription catch-up
  batch size is configurable.
- Add architecture tests around any new live-loop strategy: no gaps,
  monotonic checkpoints, bounded memory, no idle category busy polling, and
  correct replay behavior after cancellation.
