# The Notifier: `LISTEN`/`NOTIFY` Wake-Up Architecture

This document explains how Kiroku subscriptions learn that new events exist
*without polling the database on a per-subscriber timer*. It is a focused
companion to [`subscriptions.md`](subscriptions.md), which covers the full
subscription runtime (checkpoints, catch-up, FSM, overflow, Shibuya). Read this
one when you care specifically about the **notification / wake-up layer**: the
PostgreSQL `LISTEN`/`NOTIFY` notifier, what it guarantees, what it deliberately
does not, and why the design is what it is.

## Background: the notifier pattern

The design follows the pattern Brandur Leach describes in
["Notifier — using Postgres `LISTEN`/`NOTIFY` as a queue's backbone"](https://brandur.org/notifier).
The core idea of that pattern is:

1. A database **trigger** emits `NOTIFY` on every relevant write.
2. A **single dedicated `LISTEN` connection** receives those notifications —
   not one connection per worker.
3. That one listener **fans the signal out in-process** so any number of
   workers wake and read on demand, instead of each worker running its own
   timed `SELECT` poll.

The payoff is the same as in the article: you avoid the "N workers each polling
every K milliseconds" load, you get near-instant wake-up on write, and you keep
exactly one extra database connection regardless of how many subscriptions are
running.

Kiroku implements all three parts, and then hardens the pattern against
`NOTIFY`'s well-known weakness — notifications are **at-most-once** and are
silently lost if the listener connection drops — with a safety-poll backstop and
per-category wake counters. The rest of this document is that implementation.

> **One-line summary.** `LISTEN`/`NOTIFY` is a *wake-up bell*, never a data
> source. Workers always read real event rows from PostgreSQL before invoking a
> handler. The bell can be missed; the safety poll guarantees the bell is never
> the *only* way work gets noticed.

## The three parts, mapped to code

### 1. The trigger emits `NOTIFY`

A row-level trigger on the `streams` table fires once per append (per stream
row touched), not once per event. It publishes a comma-delimited payload to a
schema-scoped channel.

`kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql:146-159`

```sql
CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '.events',
        NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER stream_events_notify
    AFTER INSERT OR UPDATE ON streams
    FOR EACH ROW EXECUTE FUNCTION notify_events();
```

- **Channel:** `<schema>.events` (e.g. `kiroku.events`). Scoping the channel by
  schema lets multiple logical stores coexist on one PostgreSQL instance.
- **Payload:** `stream_name,stream_id,stream_version`. The payload exists only
  so the listener can cheaply recover the *category* of the originating stream
  (see [per-category wake counters](#per-category-wake-counters)). It is **not**
  trusted as event data.
- **Fires on `streams`, not `events`.** Appends bump a stream row's
  `stream_version`, so one trigger firing covers the whole batch appended to
  that stream — far fewer notifications than firing per event row.

### 2. One dedicated `LISTEN` connection

The `Notifier` owns a single PostgreSQL connection — separate from the Hasql
pool the rest of the store uses — and issues `LISTEN <schema>.events` on it.

`kiroku-store/src/Kiroku/Store/Notification.hs:122-140`

```haskell
startNotifier connString schema mHandler = liftIO $ do
    chan <- newBroadcastTChanIO
    catGenVar <- newTVarIO Map.empty
    let channel = toPgIdentifier (schema <> ".events")
    bracketOnError (acquireOrThrow connString) Connection.release $ \conn -> do
        Notifications.listen conn channel
            `catch` ...
        connRef <- newTVarIO conn
        thread <- Async.async (listenerLoop chan catGenVar connRef channel connString mHandler)
        pure Notifier{ tickChan = chan, listenerThread = thread, ... }
```

Key properties of the dedicated connection:

- **Separate from the pool.** Blocking on `waitForNotifications` for minutes at
  a time must not consume a pool slot needed for real queries.
- **Tagged for operators.** It sets `application_name = 'kiroku-listener'` so it
  is identifiable in `pg_stat_activity`. Tagging failure is non-fatal.
  (`Notification.hs:256-270`)
- **The live connection is held in a `TVar`** (`listenerConnRef`). Reconnection
  replaces it, and `stopNotifier` releases whichever connection the loop is
  *currently* holding, not the original one. (`Notification.hs:44-53,145-150`)

### 3. In-process fan-out

The listener loop blocks on `waitForNotifications`. Each notification runs
`handleNotification`, which does two things in one STM transaction: writes a
bare `()` tick to a **broadcast `TChan`**, and bumps a per-category counter.

`kiroku-store/src/Kiroku/Store/Notification.hs:225-229`

```haskell
handleNotification :: TChan () -> TVar (Map Text Word64) -> ByteString -> ByteString -> IO ()
handleNotification chan catGenVar _channel payload =
    atomically $ do
        writeTChan chan ()
        modifyTVar' catGenVar (Map.insertWith (+) (categoryFromPayload payload) 1)
```

The `TChan` is a **broadcast** channel: consumers call `dupTChan` to get their
own private read cursor, so one notification wakes every consumer exactly once.
There are two distinct fan-out paths off this single listener, because
different subscription targets need different wake signals:

| Wake signal | Consumer | Used by |
| --- | --- | --- |
| `()` tick on broadcast `TChan` | `EventPublisher` (one process-wide consumer) | `$all` (non-group) subscriptions |
| `categoryGenerations[cat]` counter bump | each `Category` worker, blocked on its own category | category (non-group) subscriptions |
| (neither — gated on publisher position) | each consumer-group member worker | all consumer-group subscriptions |

The third row is the deliberate opt-out explained in
[Why consumer groups bypass `NOTIFY`](#why-consumer-groups-bypass-notify).

## The full wake-up path

```text
PostgreSQL append (INSERT/UPDATE on streams)
  │
  ▼
notify_events() trigger
  │
  ▼
pg_notify('<schema>.events', 'stream_name,stream_id,stream_version')
  │
  ▼
Notifier — single dedicated LISTEN connection (waitForNotifications)
  │
  ├── writeTChan () ──────────────► EventPublisher
  │                                   │ reads $all once after lastPublished
  │                                   │ decodes batch, fans out
  │                                   ▼
  │                                 per-subscriber TBQueue ──► $all workers
  │
  └── bump categoryGenerations[cat] ─► Category workers (block on their counter)
```

The `EventPublisher` is the centralizing piece that makes the notifier pattern
pay off for `$all`. Without it, every `$all` subscription would run its own live
`SELECT` after each tick. With it, the process reads each new `$all` batch
**once** and shares the resulting `Vector RecordedEvent` with every registered
`$all` subscriber.

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs:212-233` shows the
loop: wait for a tick, drain pending ticks (debounce), then fetch-and-broadcast.

```haskell
publisherLoop pool tickChan subsVar posVar mHandler stSettings = loop
  where
    loop = do
        waitForWakeup tickChan      -- tick OR 30s safety poll
        drainTicks tickChan         -- debounce a burst of ticks into one fetch
        fetchAndBroadcast `catch` ...
        loop
```

Debouncing matters: a burst of 50 appends produces 50 ticks, but
`drainTicks` collapses them so the publisher does one fetch covering the whole
range rather than 50 fetches.

## Hardening the pattern

`NOTIFY` is at-most-once. PostgreSQL does not persist notifications, and any
notification in flight when the listener connection drops is gone — the article
calls this out, and Kiroku treats it as a first-class failure mode rather than
an edge case. Three mechanisms close the gap.

### Safety poll (the critical backstop)

Every component that waits on a notification *also* waits on a 30-second timer,
whichever fires first. A missed `NOTIFY` therefore costs **at most 30 seconds of
latency**, never a permanently stuck subscription.

`EventPublisher.hs:320-326`:

```haskell
waitForWakeup :: TChan () -> IO ()
waitForWakeup tickChan = do
    timerVar <- registerDelay safetyPollMicros   -- 30_000_000 µs
    atomically $
        (readTChan tickChan)
            `STM.orElse` (readTVar timerVar >>= STM.check)
```

The same 30-second backstop exists for category workers
(`Worker.hs:79-80,515-518`). This is what turns an at-most-once wake bell into a
**no-missed-work** system: the bell makes things fast; the poll makes things
correct.

### Reconnect with capped exponential backoff

When the listener connection dies, the loop releases the dead socket, backs off,
acquires a replacement, re-issues `LISTEN`, and resumes. The backoff schedule is
`1s, 2s, 4s, 8s, 16s, 30s, 30s, …`, capped at 30 seconds.

`kiroku-store/src/Kiroku/Store/Notification.hs:84-89,188-215`

The cap is deliberately the same 30 seconds as the safety poll: under a
sustained outage, the worst-case latency between a recovered database and a
re-armed subscription is already bounded by the safety poll, so backing off
longer than that would only add latency for no benefit.

Two subtle correctness points in the reconnect path:

- `waitForNotifications` can **return without throwing** when
  `hasql-notifications` converts a connection error into a `Left` and drops the
  diagnostic. The loop treats a plain return as a failure and reconnects (with a
  synthetic `ListenerWaitReturned` cause for observability) rather than
  spin-re-invoking the dead connection. (`Notification.hs:173-186,245-251`)
- `bracketOnError` guards the acquire→`LISTEN`→`TVar`-write sequence so an async
  exception landing mid-reconnect cannot leak a connection that `stopNotifier`
  can no longer see. (`Notification.hs:197-206`)

### Per-category wake counters

A naive category subscription, woken by the global tick, would re-query the
database on *every* unrelated append. Instead, the listener bumps a per-category
generation counter (`categoryGenerations :: TVar (Map Text Word64)`), and a
category worker blocks until *its* category's counter advances.

The category is recovered from the payload by `categoryFromPayload`, which
applies the same "prefix before the first `-`" rule as the
`streams.category GENERATED ALWAYS AS split_part(stream_name,'-',1)` column —
one Haskell definition (`categoryName`) shared with the schema.
(`Notification.hs:231-243`)

The worker's gate (`Worker.hs:507-518`):

```haskell
gen0 <- atomically readGen
-- ... drain all currently-available category events from PostgreSQL ...
timer <- registerDelay categorySafetyPollMicros
atomically $
    (readGen >>= \g -> check (g > gen0))   -- woken by a NOTIFY for THIS category
        `orElse` (readTVar timer >>= check) -- or the 30s safety poll
```

The result: **an idle category does zero live database work** except its
safety poll, even while other categories receive heavy traffic. This is the
property exercised by the `CategoryIdleNoSpin` architecture test.

## Why consumer groups bypass `NOTIFY`

Consumer-group members partition events by a PostgreSQL-side hash of the
originating stream id:

```text
slot(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

The `NOTIFY` payload carries `stream_id`, but a member cannot cheaply or
reliably replicate `hashtextextended` from Haskell to decide "is this mine?"
from the payload alone. So consumer-group workers do **not** consume the tick or
the category counter. They instead gate on the **publisher's global
`lastPublished` position** advancing past the last position they have observed,
then re-query with the partition predicate in SQL as the source of truth.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:564-571`

```haskell
go cursor waitFrom = do
    p <- atomically $ do
        p <- readTVar pubPosVar
        check (p > waitFrom)   -- wake only when NEW global work exists
        pure p
    -- ... drain this member's partition from PostgreSQL ...
```

The gate is `p > waitFrom` (last *observed* global position), not
`p > memberCursor`. A member's cursor can lag unrelated partitions forever; if
it gated on its own cursor it would busy-loop whenever some *other* member owns
the latest events. Even here the publisher position is itself advanced off the
notifier tick (or the publisher's safety poll), so consumer groups still
benefit from the notifier indirectly — they just don't read its channels
directly.

## What this buys vs. naive polling

| Scenario | This design | Naive per-subscriber polling |
| --- | --- | --- |
| Normal append | All interested workers wake within one notification round-trip | Up to one poll-interval of latency |
| 100 subscriptions | 1 extra DB connection (the listener); `$all` read once and shared | Up to 100 independent polling queries per interval |
| Idle category | Zero live DB work (counter never moves) | One wasted query per interval, forever |
| Missed `NOTIFY` (reconnect, overflow) | Repaired by the 30s safety poll | N/A (already polling) |
| Listener connection lost | Capped-backoff reconnect; safety poll bounds delay meanwhile | N/A |

## Invariants to preserve

These are the notifier-layer slice of the invariants in
[`subscriptions.md`](subscriptions.md#design-invariants); a change here must keep
all of them:

- **`LISTEN`/`NOTIFY` wakes the system but is never the data source.** Workers
  always read real rows from PostgreSQL before invoking a handler.
- **Safety polls stay as a backstop for missed notifications.** Removing them
  reintroduces the at-most-once gap as a correctness bug.
- **One dedicated listener connection**, separate from the pool, replaced (not
  duplicated) on reconnect, and released by `stopNotifier`.
- **Category live mode must not query the database for every unrelated append.**
  The per-category counter is what enforces this.
- **The configured schema must match the schema holding Kiroku tables**, or the
  `<schema>.events` channel won't line up and subscriptions fall back to waking
  only on the safety poll (correct, but no longer prompt).

## Known sharp edges / improvement areas

- **Comma-delimited payload.** `categoryFromPayload` rejoins all-but-the-last-
  two comma-separated fields to tolerate commas in stream names
  (`Notification.hs:238-243`), but a JSON payload would be more robust if
  external listeners ever consume this channel. Tracked in
  [`subscriptions.md`](subscriptions.md#improvement-areas).
- **8000-byte `NOTIFY` payload limit.** Not a problem today (the payload is
  small), but any future enrichment of the payload must stay well under it.
- **Schema/channel mismatch is silent.** It degrades to safety-poll-only wake-up
  rather than erroring; only the loss of promptness signals the misconfiguration.

## See also

- [`subscriptions.md`](subscriptions.md) — full subscription runtime: durable
  cursors, catch-up, the worker FSM, overflow policies, the Shibuya adapter, and
  delivery guarantees.
- [`docs/user/subscriptions.md`](../user/subscriptions.md) — user-facing
  subscription API.
- Brandur Leach, ["Notifier"](https://brandur.org/notifier) — the reference
  pattern this layer is modeled on.
