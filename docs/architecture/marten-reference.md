# Marten event-store internals — reference study

- **Status:** Reference — researched 2026-06-11 against the local checkout at
  `/Users/shinzui/Keikaku/hub/event-sourcing/marten` (read-only; never modify it).
- **Why this exists:** Kiroku's potential migration away from Strategy E (the
  `$all` row counter) targets a Marten-style sequence-allocated global position
  with a high-water-mark daemon. This document records how Marten actually
  implements that machinery, at file-path granularity, so the future migration
  masterplan does not have to re-derive it. Companion analysis:
  `docs/architecture/global-position-migration-path.md`; decision benchmark:
  `docs/plans/63-decide-the-marten-style-global-position-migration-with-durable-fsync-benchmarks-and-option-preserving-contract-changes.md`.

## Schema

**`mt_events`** (`src/Marten/Events/Schema/EventsTable.cs`) — one row per event,
carrying *both* orderings; there is no junction table and no materialized `$all`:

- `seq_id BIGINT PRIMARY KEY` — global position, from sequence `mt_events_sequence`
- `id UUID`, `stream_id` (UUID or VARCHAR), `version INT` — stream-local version
- `data JSONB`, `type VARCHAR`, `timestamp TIMESTAMPTZ DEFAULT now()`
- `is_archived BOOL DEFAULT FALSE` — drives optional list partitioning
  (`UseArchivedStreamPartitioning`: active vs "archived" partitions on both
  `mt_events` and `mt_streams`)
- optional: `tenant_id`, `correlation_id`, `causation_id`, `headers`,
  `user_name`, `is_skipped`, `dotnet_type`
- unique index on `(stream_id, version)` (plus `tenant_id`/`is_archived`
  variants) — this index, not a lock, is the optimistic-concurrency enforcement
- FK to `mt_streams` with cascade delete

**`mt_streams`** (`src/Marten/Events/Schema/StreamsTable.cs`) — `id`, `type`,
`version` (current stream version), `timestamp`, `created`, `snapshot JSONB` +
`snapshot_version` (inline aggregate snapshots — a feature kiroku does not have),
`is_archived`, optional `tenant_id`.

**`mt_event_progression`** (`src/Marten/Events/Schema/EventProgressionTable.cs`)
— daemon checkpoints: `name VARCHAR PRIMARY KEY` (shard id; the high-water mark
itself is the row named `HighWaterMark`), `last_seq_id BIGINT`,
`last_updated TIMESTAMPTZ`. Kiroku's `subscriptions` table is the analogous
structure for consumer checkpoints; Marten additionally checkpoints the HWM here.

**`mt_high_water_skips`** (`EventProgressionSkippingTable.cs`, only with
`EnableAdvancedAsyncTracking`) — audit log of skipped gap ranges:
`starting_sequence`, `ending_sequence PRIMARY KEY`, `timestamp`.

## Append path

Appends go through a generated PL/pgSQL function `mt_quick_append_events`
(`src/Marten/Events/Schema/QuickAppendEventFunction.cs:76-126`). Shape:

```sql
select version into event_version from mt_streams where id = stream;
if event_version IS NULL then          -- first append creates the stream
    event_version = 0;
    insert into mt_streams (id, type, version, timestamp) values (stream, stream_type, 0, now());
end if;
foreach event_id in ARRAY event_ids loop
    seq := nextval('mt_events_sequence');     -- global position, per event
    event_version := event_version + 1;
    insert into mt_events (seq_id, id, stream_id, version, data, type, ...) values (seq, ...);
end loop;
update mt_streams set version = event_version, timestamp = now() where id = stream;
```

Load-bearing properties:

- **No store-wide lock of any kind.** Appends to different streams commit fully
  in parallel and share WAL flushes via PostgreSQL group commit. This is the
  entire throughput advantage over kiroku's Strategy E, where the `$all` row
  lock is held through the commit's WAL flush and serializes every append in
  the store.
- **No explicit stream row lock either** (no `FOR UPDATE`, no advisory locks).
  Concurrent same-stream appends race; the loser fails on the unique
  `(stream_id, version)` index. Kiroku instead takes the stream row lock
  up-front, which is a *stronger* per-stream serialization — a kiroku migration
  would keep its stream lock and change only the global allocator.
- Sequence values are claimed inside the function per event; because sequences
  are non-transactional, a rollback burns its values permanently (gaps) and a
  slow transaction can commit a lower `seq_id` after a higher one is already
  visible (out-of-order visibility).

## Tombstones (explaining burned sequence values)

When an append transaction fails after claiming sequence values, Marten writes
"tombstone" events into a reserved Tombstone stream
(`src/Marten/Events/Operations/EstablishTombstoneStream.cs`,
`src/Marten/Events/EventGraph.Processing.cs:62-86`): each carries the burned
`seq_id` as both its `Sequence` and `Version` (the latter to dodge the unique
index). Effect: most gaps the daemon encounters are *explained* by a tombstone
row occupying the seq_id, so the HWM can advance without waiting out the stale
timeout. Only crashes (transaction never got to write tombstones) leave true
unexplained gaps.

## High-water mark and gap detection

The async daemon's HWM loop (`src/Marten/Events/Daemon/HighWater/HighWaterDetector.cs`):

1. Read `last_value` from `mt_events_sequence` (highest claimed position) and
   the persisted mark from `mt_event_progression` where `name = 'HighWaterMark'`
   (`HighWaterStatisticsDetector.cs:18-21`).
2. Scan for the first gap after the mark (`GapDetector.cs:23-34`):

   ```sql
   select seq_id
   from   (select seq_id,
                  lead(seq_id) over (order by seq_id) as no
           from mt_events where seq_id >= :start) ct
   where  no is not null and no - seq_id > 1
   limit 1;
   select max(seq_id) from mt_events where seq_id >= :start;
   ```

   Advance the mark to the last contiguous position (the gap edge, or max if no
   gap).
3. **Stale-gap escape** (`HighWaterDetector.cs:86-104`): if the mark hasn't
   moved for longer than `StaleSequenceThreshold` (configurable; tests use
   250ms) while the sequence head kept growing, assume the gap is a rollback
   with no tombstone and jump the mark to `highest_sequence - 32`. The `32` is a
   hardcoded safe-harbor buffer against advancing into transactions that are
   mid-flight *right now*. With `EnableAdvancedAsyncTracking`, the skipped range
   is recorded in `mt_high_water_skips` and the mark update is
   compare-and-swap-guarded (`src/Marten/Schema/SQL/mt_mark_progression_with_skip.sql`).
4. Persist the mark (`src/Marten/Schema/SQL/mt_mark_event_progression.sql`,
   upsert on `name`).

Consequence for delivery semantics: an event is *eligible* for projections only
once the HWM passes it, so `$all`-order consumers see settled history — at the
cost of HWM-poll latency on the live tail, and of a rare bounded skip
(`-32` harbor) if a gap goes stale at exactly the wrong moment.

## How projections read

(`src/Marten/Events/Daemon/Internals/EventLoader.cs:41-64`)

```sql
select <fields>, s.type as stream_type
from mt_events as d inner join mt_streams as s on d.stream_id = s.id
where d.seq_id > :floor and d.seq_id <= :high_water_mark
order by d.seq_id limit :batch;
```

Floor = the projection's own `mt_event_progression` row; ceiling = the HWM. This
is exactly kiroku's `readAllForward` exclusive-cursor shape plus a ceiling —
which is why kiroku's public read API survives the migration unchanged (see the
API-survival table in `global-position-migration-path.md`).

## What kiroku would and would not borrow

Borrow: the sequence allocator; the HWM concept with persisted mark; the
LEAD-window gap scan (adapted to `stream_events WHERE stream_id = 0`); the
stale-timeout + safe-harbor escape; tombstones as a gap-explanation
optimization (worth considering in a second phase — they shrink worst-case HWM
latency from "stale timeout" to "one poll").

Not borrow: the single-table event layout. Kiroku's `events` + `stream_events`
junction design carries `linkToStream` and the `$all`-as-stream model; the
migration swaps only the position allocator (one junction row per event for
stream 0 still holds the position). Also not borrowed: index-violation-based
stream concurrency (kiroku's up-front stream row lock is stronger and already
load-bearing for `ExpectedVersion` semantics), snapshot columns, and tenancy
columns (out of scope).
