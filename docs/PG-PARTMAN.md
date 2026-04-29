# pg_partman Readiness Assessment

> Analysis of schema compatibility with [pg_partman](https://github.com/pgpartman/pg_partman) for time-based partitioning at high event volumes (millions of events/day).

## Target Tables

Only the two event-data tables need partitioning. `streams` (one row per stream) and `subscriptions` (one row per subscriber) remain small and unpartitioned.

| Table | Growth Rate | Partition Strategy |
|---|---|---|
| `events` | 1 row per event | Range on `created_at` (daily or weekly) |
| `stream_events` | 2+ rows per event | Range on `created_at` (requires adding column) |

At 5M events/day, `stream_events` accumulates ~10M+ rows/day. Time-based range partitioning lets old partitions be detached, archived, or dropped without touching active data.

---

## Friction Points

### 1. Primary keys must include the partition key

PostgreSQL declarative partitioning requires the partition key to appear in every unique constraint (including the primary key). The current PKs do not include a time column.

**Current:**

```sql
-- events
PRIMARY KEY (event_id)

-- stream_events
PRIMARY KEY (event_id, stream_id)
```

**Required for partitioning by `created_at`:**

```sql
-- events
PRIMARY KEY (event_id, created_at)

-- stream_events (created_at column must be added first)
PRIMARY KEY (event_id, stream_id, created_at)
```

`event_id` uniqueness is still guaranteed in practice by UUIDv7 generation — the composite PK just satisfies PostgreSQL's partitioning constraint.

### 2. `stream_events` has no `created_at` column

The junction table currently has no timestamp. A `created_at` column must be added before it can be range-partitioned by time.

This column would be populated from the event's `created_at` during the append CTE (available in the `new_events` CTE since the Haskell layer pre-generates timestamps). It adds 8 bytes per row.

### 3. Foreign key from `stream_events` to `events`

```sql
event_id UUID NOT NULL REFERENCES events(event_id)
```

On a partitioned `events` table, `UNIQUE(event_id)` alone is not possible — only `UNIQUE(event_id, created_at)` satisfies the partition-key-in-unique-constraint rule. This breaks the existing single-column FK.

**Recommended: drop the FK.** The append CTEs insert into both `events` and `stream_events` atomically within a single CTE. Referential integrity is guaranteed by application logic, not constraints. Dropping the FK also removes a write-time lookup that becomes increasingly expensive as the `events` table grows — at millions of events/day, this is a meaningful throughput gain.

The FK from `stream_events` to `streams` (`stream_id REFERENCES streams(stream_id)`) is unaffected since `streams` is not partitioned.

---

## What Already Works

### Queries require no changes

All read queries join `stream_events` to `events` via `ON e.event_id = se.event_id` with a `LIMIT` clause. PostgreSQL handles partition routing transparently — the join produces the same results whether the tables are partitioned or not.

Partition pruning on the `events` side won't engage (no `created_at` in the WHERE clause), but this is acceptable:
- Read batches are small (bounded by LIMIT, typically 100-1000)
- UUIDv7-ordered events in a read batch cluster in time, so in practice the planner touches 1-2 partitions
- The `stream_events` side benefits from pruning when the query includes `created_at` ranges

### Append CTEs require no structural changes

The `new_events` CTE already carries `created_at` values. Adding `created_at` to the `stream_events` INSERT is a one-line change per CTE variant — the value is already available from the unnested arrays.

### Triggers inherit to child partitions

Since PostgreSQL 11, triggers defined on a partitioned parent table are automatically inherited by all child partitions. The immutability triggers (`prevent_mutation`, `protect_deletion`) and the NOTIFY trigger on `streams` all work without modification.

### Indexes are per-partition

PostgreSQL automatically creates per-partition copies of all indexes defined on the parent. The existing indexes (`ix_stream_events_stream_version`, `ix_events_event_type`, etc.) benefit from partitioning — each partition's index is smaller and fits more easily in memory.

### Hard delete CTE works across partitions

The cascading hard delete CTE (`DELETE FROM stream_events ... DELETE FROM events ...`) works transparently with declarative partitioning — PostgreSQL routes deletes to the correct partitions.

---

## Schema Changes Required

### Adding `created_at` to `stream_events`

The `stream_events` INSERT in each append CTE variant needs `created_at` propagated from `new_events`. Example diff for `source_links`:

```sql
-- Before
source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version,
                               original_stream_id, original_stream_version)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx,
           su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN stream_update su
)

-- After
source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version,
                               original_stream_id, original_stream_version,
                               created_at)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx,
           su.stream_id, su.initial_version + ne.idx,
           ne.created_at
    FROM new_events ne
    CROSS JOIN stream_update su
)
```

The same change applies to `all_links` (the `$all` stream insertion) and the link CTE.

### Migration DDL

```sql
-- 1. Add created_at to stream_events
ALTER TABLE stream_events
    ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- 2. Backfill from events table (for existing data)
UPDATE stream_events se
SET created_at = e.created_at
FROM events e
WHERE se.event_id = e.event_id;

-- 3. Drop FK to events (cannot reference partitioned table by event_id alone)
ALTER TABLE stream_events DROP CONSTRAINT stream_events_event_id_fkey;

-- 4. Alter PKs to include partition key
ALTER TABLE events DROP CONSTRAINT events_pkey;
ALTER TABLE events ADD PRIMARY KEY (event_id, created_at);

ALTER TABLE stream_events DROP CONSTRAINT stream_events_pkey;
ALTER TABLE stream_events ADD PRIMARY KEY (event_id, stream_id, created_at);

-- 5. Convert to partitioned tables via pg_partman
-- (requires pg_partman extension and empty-table conversion or online migration)
CREATE EXTENSION IF NOT EXISTS pg_partman;

SELECT partman.create_parent(
    p_parent_table := 'public.events',
    p_control := 'created_at',
    p_interval := 'daily',
    p_type := 'native'
);

SELECT partman.create_parent(
    p_parent_table := 'public.stream_events',
    p_control := 'created_at',
    p_interval := 'daily',
    p_type := 'native'
);
```

> **Note:** Converting an existing non-partitioned table to a partitioned one requires either pg_partman's migration tooling or a `CREATE TABLE ... (LIKE original) PARTITION BY RANGE (created_at)` with data copy. This should be done before the tables are large — ideally before production traffic ramps up.

### Haskell Code Changes

The only application code change is adding `ne.created_at` to the `stream_events` INSERT columns in each CTE variant in `Kiroku.Store.SQL`. No changes to types, encoders, decoders, effect interpreters, or the public API.

---

## Operational Considerations

### Partition interval

Daily partitions are a reasonable starting point for millions of events/day. At 5M events/day, a daily partition holds ~5M rows in `events` and ~10M+ in `stream_events` — small enough for efficient index scans, large enough to avoid excessive partition counts.

pg_partman's `run_maintenance()` (called via `pg_cron` or external scheduler) handles creating future partitions and optionally detaching/dropping old ones.

### Retention and archival

Time-based partitioning enables efficient retention policies:
- **Detach** old partitions to stop them appearing in queries
- **Move** detached partitions to cheaper tablespaces
- **Drop** partitions past retention window — instantaneous compared to row-level DELETE

This pairs well with the existing soft-delete mechanism: soft-deleted streams prevent new appends, and old partitions containing their events can be archived independently.

### Subscription catch-up across partitions

Catch-up subscriptions scan `stream_events WHERE stream_id = 0 AND stream_version > $last_seen ORDER BY stream_version ASC LIMIT $batch`. This naturally starts from the oldest unprocessed partition and advances forward. The planner will scan partitions sequentially — no performance concern since catch-up is inherently sequential.

### Monitoring

Key metrics to watch after enabling partitioning:
- Partition count (pg_partman manages this, but verify with `SELECT count(*) FROM pg_catalog.pg_inherits WHERE inhparent = 'events'::regclass`)
- Index bloat per partition (smaller indexes = less bloat, but more of them)
- `run_maintenance()` execution time and failures
- Query plans for read operations (verify partition pruning engages where expected)

---

## Summary

| Aspect | Status | Action Needed |
|---|---|---|
| `events` PK | Needs `created_at` in composite PK | Schema migration |
| `stream_events` PK | Needs `created_at` column + composite PK | Schema migration |
| FK `stream_events` -> `events` | Incompatible with partitioned `events` | Drop FK |
| FK `stream_events` -> `streams` | Compatible | None |
| Read queries | Compatible (no code changes) | None |
| Append CTEs | Need `created_at` in `stream_events` INSERT | One-line change per CTE variant |
| Triggers | Inherited by child partitions | None |
| Indexes | Per-partition automatically | None |
| Haskell types/API | Unaffected | None |

The schema is close to pg_partman-ready. The changes are mechanical (composite PKs, one new column, drop one FK) and can be made proactively before the tables grow large. The application code change is minimal — adding `created_at` to the `stream_events` INSERT in `SQL.hs`.
