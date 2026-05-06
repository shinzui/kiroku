# Scaling Analysis: Maintaining Read Performance at Billion-Row Scale

> Deep analysis of how kiroku's schema and access patterns behave as `events` and `stream_events` grow to billions of rows, and which scaling strategies preserve correctness without introducing read regressions. Based on study of Marten (source at `hub/event-sourcing/marten`), Commanded EventStore (source at `hub/event-sourcing/eventstore`), and the original design research (`rei collection collection_01kj3w0dnvex9s582d5xvdncz2`).

---

## The Question

Kiroku's throughput ceiling has been validated (~50K events/s with Strategy E batching). But throughput is only half the story. The other half is: **what happens to read performance when the tables are large?** At 5M events/day, after 1-2 years the database holds billions of rows. Do the existing indexes and query plans hold up, or do we need structural changes?

---

## Growth Projections

At 5M events/day sustained:

| Table | Rows (1 year) | Rows (2 years) | Estimated Size (2yr) |
|---|---|---|---|
| `events` | ~1.8B | ~3.6B | ~500GB (avg ~200B JSONB payload) |
| `stream_events` | ~3.6B | ~7.2B | ~400GB (40 bytes/row, 2+ rows per event) |
| `streams` | Low thousands | Low thousands | Negligible |
| `subscriptions` | Low hundreds | Low hundreds | Negligible |

Index sizes (estimated at 2 years):

| Index | Estimated Size |
|---|---|
| `events_pkey` (uuid) | ~60GB |
| `ix_events_event_type` (text) | ~30GB |
| `ix_events_correlation_id` (uuid, partial) | ~20GB |
| `ix_events_causation_id` (uuid, partial) | ~20GB |
| `stream_events_pkey` (uuid, bigint) | ~120GB |
| `ix_stream_events_stream_version` (bigint, bigint) | ~80GB |
| `ix_stream_events_all_by_origin` (bigint, bigint, partial) | ~40GB |
| **Total indexes** | **~370GB** |

**Total database size at 2 years: ~1.2-1.3TB.**

With typical production `shared_buffers` of 32GB, most index pages reside on disk. SSD random I/O is sub-ms per lookup, but the working set exceeds memory.

---

## Read Path Analysis at Scale

### Stream reads (the primary access pattern)

    SELECT e.event_id, e.event_type, se.stream_version, ...
    FROM stream_events se
    JOIN events e ON e.event_id = se.event_id
    WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1)
      AND se.stream_version > $2
    ORDER BY se.stream_version ASC
    LIMIT $3

This uses `ix_stream_events_stream_version` on `(stream_id, stream_version)`. B-tree depth grows logarithmically: 1B to 3.6B rows adds ~1-2 tree levels (~10-20us extra per lookup). The range scan on `stream_version > $2` hits contiguous leaf pages for a given `stream_id`. **This scales well.** The join to `events` by `event_id` (PK lookup) adds one B-tree traversal per event in the batch.

**Estimated degradation at 3.6B rows vs 1M rows:** +20-50us per query on SSD. Still sub-ms for 100-event batches.

### $all reads

    WHERE se.stream_id = 0 AND se.stream_version > $1
    ORDER BY se.stream_version ASC LIMIT $2

Same index, same analysis. Reads start from a specific global position and scan forward. The B-tree range scan touches contiguous leaf pages. **Scales well.**

### Category reads

    WHERE se.stream_id = 0 AND se.stream_version > $1 AND s.category = $2
    ORDER BY se.stream_version ASC LIMIT $3

Uses `ix_stream_events_all_by_origin` partial index and the LATERAL join pattern. This is the most complex read path. The query finds streams in the category, then scans each stream's `$all` entries via the partial index. Performance depends on the number of active streams per category. **Scales with category stream count, not total event count.** Already validated at about 1.03ms for a 100-event page with 100K events across 100 categories. The focused reliability-and-scale audit also added an `exhausted-category` benchmark at about 21.6us for a high cursor after a category has no newer events; this guards against accidentally scanning the rest of `$all` looking for category matches.

### Writes (append CTE)

UUIDv7 event_ids are time-ordered, so `events` PK inserts are mostly rightmost (minimal page splits). `stream_events` inserts are at the end of each stream's version range. The hot `$all` row (stream_id=0 in `streams`) is a single-row UPDATE. **Write throughput is not affected by table size** — the bottleneck remains the `$all` row lock cycle (~0.2ms).

---

## Why Time-Based Partitioning Hurts This Schema

The PG-PARTMAN research doc (`docs/PG-PARTMAN.md`) proposed RANGE partitioning on `created_at` for both `events` and `stream_events`. This analysis shows why that approach introduces read path regressions that outweigh the maintenance benefits.

### Problem 1: Stream reads cannot prune partitions

Stream read queries filter on `stream_id` and `stream_version`, not `created_at`. With `stream_events` partitioned by `created_at` into daily partitions, PostgreSQL cannot determine which partitions contain a given stream's events. After 2 years of daily partitions (~730 partitions), every stream read would scan 730 per-partition indexes instead of 1.

A stream with 10,000 events spread across 300 days of partitions would require 300+ per-partition index lookups instead of a single contiguous B-tree range scan. For the LIMIT 100 batch, the planner must merge results from multiple partitions and sort — a significant overhead compared to the current single-index scan.

### Problem 2: $all reads cannot prune partitions

$all reads filter on `stream_id = 0 AND stream_version > $1`. The partition key `created_at` does not appear in the query. No pruning. Same 730-partition scan problem.

### Problem 3: The events join is broken

Read queries join `stream_events` to `events` on `event_id`. If `events` is partitioned by `created_at` with PK `(event_id, created_at)`, a lookup by `event_id` alone cannot use partition pruning. For a 100-event read batch, the join would probe up to 730 partitions per event_id. Most probes miss (the event exists in exactly one partition). The aggregate cost: up to 73,000 per-partition index probes instead of 100 single-index lookups.

Even though each probe is fast (sub-us in memory), the overhead is 730x for the join step alone.

### Problem 4: Planning overhead

PostgreSQL's query planner must consider all partitions even if it cannot prune them. At 730 partitions, planning time alone can reach 1-2ms — comparable to the entire query execution time today.

### Problem 5: The composite PK is wider for no benefit

Changing `events` PK from `(event_id)` to `(event_id, created_at)` adds 8 bytes per index entry. At 3.6B rows, that's ~29GB of additional index storage. The wider key also makes non-covering index scans slightly more expensive.

---

## What Marten Actually Does (Source Code Evidence)

Marten is the most battle-tested PostgreSQL event store (validated against "hundreds of millions of events"). Their scaling strategy does **not** include time-based partitioning.

### Hot/Cold LIST Partitioning by `is_archived`

**Source:** `src/Marten/Events/Schema/EventsTable.cs`, `src/Marten/Events/Archiving/IsArchivedColumn.cs`

Both `mt_events` and `mt_streams` support LIST partitioning on a boolean `is_archived` column. Two partitions: active events (`is_archived = false`, the default partition) and archived events (`is_archived = true`).

When enabled (`UseArchivedStreamPartitioning = true`), the archiving function (`mt_archive_stream()` in `src/Marten/Events/Archiving/ArchiveStreamFunction.cs`) physically moves events from the active partition to the archived partition:

    -- With partitioning enabled, archiving is INSERT + DELETE (physical move):
    INSERT INTO mt_events SELECT [...columns...], TRUE FROM mt_events WHERE stream_id = $1;
    DELETE FROM mt_events WHERE stream_id = $1 AND is_archived = FALSE;

    -- Without partitioning, archiving is a simple flag update:
    UPDATE mt_events SET is_archived = TRUE WHERE stream_id = $1;

The active partition stays small as completed streams are archived. All existing query patterns work without modification because the planner prunes the archived partition on `is_archived = false`.

### Stream Compacting

**Source:** `src/Marten/Events/EventStore.StreamCompacting.cs`

For aggregates with long event histories, Marten can replace old events with a single `Compacted<T>` snapshot event:

1. Fetch all events up to a version or timestamp
2. Build aggregate state by replaying events
3. Insert a `Compacted<T>` event containing the aggregate snapshot
4. Delete the original events by `seq_id`

On replay, the aggregator sees the `Compacted<T>` event and applies the snapshot state directly, skipping all compacted events. This reduces total row count without partitioning.

### Tenant-Based Partitioning

**Source:** `src/Marten/Events/Schema/EventsTable.cs`

For conjoined multi-tenancy (`TenancyStyle.Conjoined`), Marten supports LIST, HASH, or RANGE partitioning on `tenant_id`. This provides natural isolation between tenants while keeping them in the same database.

### What Marten Rejected

GitHub issue #770 discussed several partitioning strategies. Time-based partitioning was discussed but not implemented as a first-class feature. The team chose hot/cold + tenant-based partitioning instead, because event store access patterns are stream-centric, not time-centric.

---

## What Commanded EventStore Does (Source Code Evidence)

Commanded EventStore (Elixir, at `hub/event-sourcing/eventstore`) uses the same architecture as kiroku: Strategy E with `$all` as stream_id=0, `stream_events` junction table, CTE-based atomic appends, trigger-based immutability with gated hard deletes, LISTEN/NOTIFY on the `streams` table.

**Commanded has no partitioning support at all.** After 10 schema migrations (v0.9.0 through v1.3.2) and years of production use, the schema remains unpartitioned. They rely on:

- PostgreSQL B-trees scaling well with good indexes
- Schema-per-tenant for multi-tenant deployments (`schema` config, schema-scoped NOTIFY channels)
- The same index strategy kiroku uses: `(stream_id, stream_version)` on `stream_events`

This is strong evidence that B-trees at billion-row scale, with good index design and SSD storage, are sufficient for event store workloads.

---

## The Real Scaling Threats (and Mitigations)

### 1. VACUUM pressure

**Threat:** autovacuum on 500GB+ tables takes hours. The hot `$all` row in `streams` generates dead tuples on every append. If autovacuum can't keep up, dead tuple bloat grows, causing index bloat and slower scans.

**Mitigation:**
- Aggressive autovacuum tuning for the `streams` table: set `autovacuum_vacuum_scale_factor = 0` and `autovacuum_vacuum_threshold` to a low value (e.g., 50). This ensures the `$all` row is vacuumed frequently.
- PostgreSQL's HOT (Heap Only Tuple) optimization handles the `$all` row well because only `stream_version` changes and the row stays on the same page.
- For `events` and `stream_events` (append-only, no updates except hard deletes), vacuum pressure is minimal — no dead tuples under normal operation.

### 2. Index memory pressure

**Threat:** With ~370GB of indexes and 32GB `shared_buffers`, most index pages reside on disk. Cold-start queries after restart or cache eviction hit disk I/O.

**Mitigation:**
- Size `shared_buffers` appropriately (25% of available RAM). With 128GB RAM, `shared_buffers` = 32GB covers the most frequently accessed index pages.
- The OS filesystem cache (remaining RAM) provides a second layer of caching.
- SSD storage ensures sub-ms random I/O even for cache misses.
- Read replicas can distribute read load across multiple caches.
- The `ix_stream_events_stream_version` index is the most critical. Its access pattern (range scans on `(stream_id, stream_version)`) benefits from sequential readahead — once the starting leaf page is found, subsequent pages are contiguous.

### 3. Backup and restore time

**Threat:** pg_dump/pg_restore of a 1TB+ database takes hours. Full restores for disaster recovery are slow.

**Mitigation:**
- Use pgbackrest or barman for incremental/differential backups. WAL archiving enables point-in-time recovery without full dumps.
- Streaming replication provides hot standby for immediate failover.
- pg_dump is only needed for logical backup (schema migration testing, etc.), not operational backup.

### 4. Schema DDL on large tables

**Threat:** Some ALTER TABLE operations acquire ACCESS EXCLUSIVE locks, blocking all queries. On billion-row tables, operations like adding an index or changing a column type can take minutes to hours.

**Mitigation:**
- `CREATE INDEX CONCURRENTLY` for new indexes (no lock).
- `ALTER TABLE ... ADD COLUMN ... DEFAULT ...` is fast in PostgreSQL 11+ (metadata-only change for non-volatile defaults).
- `REINDEX CONCURRENTLY` (PostgreSQL 12+) for index rebuilds.
- For operations that require table rewrites, plan maintenance windows.

### 5. Index bloat over time

**Threat:** B-tree indexes can accumulate empty or partially-filled pages over time, especially after bulk deletes (hard delete operations).

**Mitigation:**
- `REINDEX CONCURRENTLY` periodically (e.g., monthly) for indexes that have seen significant churn.
- Monitor index bloat with `pgstattuple` extension or `pg_stat_user_indexes`.
- For `events` and `stream_events` (append-only), index bloat is minimal under normal operation. Only hard delete operations cause significant churn.

---

## Recommended Scaling Strategy

### Near-term (current implementation)

1. **Add `created_at` to `stream_events`** — Useful for debugging, monitoring, and time-range queries regardless of partitioning strategy. Propagate from `new_events.created_at` in the append CTEs. This is the one piece of the original PG-PARTMAN plan worth keeping. Low risk, 8 bytes/row overhead.

2. **Do NOT change PKs or drop FKs** — The composite PK `(event_id, created_at)` and FK removal are only needed for time-based partitioning, which this analysis shows is harmful. Keep the current PKs and FK as safety nets.

3. **Document operational tuning** — VACUUM settings for the `streams` table, `shared_buffers` sizing guidance, monitoring thresholds (dead tuple ratio, index bloat, checkpoint frequency).

### Medium-term (when total data exceeds ~500GB)

4. **Hot/cold archival (Marten's approach)** — Add an `is_archived` boolean to `stream_events` (and optionally `events`). Streams with a natural lifecycle (completed orders, closed sessions) can be archived. LIST partitioning on `is_archived` keeps the active partition small without affecting read paths.

    This requires designing an archive API:
    - Which streams are archivable (domain-driven, not time-driven)
    - Archive trigger: explicit API call, age-based policy, or event-driven
    - Read behavior: archived streams readable by default or require explicit opt-in
    - `is_archived` must be included in unique constraints if using LIST partitioning

5. **Schema-per-tenant** (already designed for) — For multi-tenant deployments, each tenant's schema has its own `$all` row, its own indexes, and its own VACUUM cycle. Already identified as escape hatch #2 in `docs/BENCH-SQL-BASELINE.md`.

### Long-term (when specific aggregates have very long histories)

6. **Stream compacting** — For aggregates with 10K+ events, replace old events with a snapshot. Marten's `Compacted<T>` pattern: aggregate the events, insert a snapshot event, delete the originals. Reduces total row count for specific streams without affecting the global schema.

7. **Read replicas** — Distribute read load. The write path (single primary) is unaffected. Already identified as escape hatch #4.

---

## Why Not Time-Based Partitioning

To be explicit about why the original PG-PARTMAN approach should be set aside:

| Benefit claimed | Reality for kiroku |
|---|---|
| Partition pruning on reads | No pruning possible — queries filter on `stream_id`/`stream_version`, not `created_at` |
| Smaller per-partition indexes | True, but 730 small index scans > 1 large index scan |
| Drop old partitions for archival | True, but dropping by time destroys active streams' old events — archival should be stream-driven, not time-driven |
| Faster VACUUM per partition | True, but `events`/`stream_events` are append-only — VACUUM pressure is already minimal |

The fundamental mismatch: **event stores have stream-centric access patterns, not time-centric ones.** Time-based partitioning optimizes for time-range queries that kiroku never performs.

---

## Summary

| Concern | Threat Level | Mitigation |
|---|---|---|
| Read performance at scale | **Low** | B-trees scale logarithmically. SSD + appropriate `shared_buffers` keeps sub-ms latency |
| VACUUM on hot `$all` row | **Medium** | Aggressive autovacuum tuning. HOT optimization covers single-row updates |
| Table size / archival | **Medium** | Hot/cold partitioning (Marten-style) when domain supports stream lifecycle |
| Index memory pressure | **Medium** | Size `shared_buffers` to RAM. Read replicas for read scaling |
| Backup/restore | **Medium** | pgbackrest for incremental backups. Streaming replication for failover |
| Write throughput ceiling | **Low** | Already validated at ~50K events/s. Schema-per-tenant or Strategy D as escape hatches |

The store's architecture is sound for billion-row scale. A focused May 2026 audit captured plans on 100K representative events and confirmed the intended index paths for stream reads, `$all` reads, category reads, and subscription checkpoints after switching category reads back to the LATERAL partial-index shape. The primary investment should be in operational practices (VACUUM tuning, monitoring, incremental backups) and domain-driven archival (hot/cold partitioning), not time-based table partitioning.
