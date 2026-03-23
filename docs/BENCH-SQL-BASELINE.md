# Track 1: SQL Benchmark Baseline

> Results from pgbench benchmarks against PostgreSQL 18 on local SSD (macOS, unix socket).
> Run date: 2026-03-20. Schema: Strategy E (atomic row-level counter on `$all`).

## Summary

Strategy E is validated. The `$all` row contention ceiling is within acceptable bounds for the target use cases. One action item: category reads need index work before building `readCategory` in Haskell.

### Gate 1 Decision: **Proceed with Strategy E.**

---

## Results

### Benchmark 1: Single-stream sequential appends

| Metric | Value |
|---|---|
| TPS | 2,620 |
| p50 | 0.328ms |
| p95 | 0.548ms |
| p99 | 0.767ms |

Single-event append latency is well under the 0.5ms p50 / 2ms p99 targets. This is the baseline for Haskell overhead comparison at Milestone 2.

### Benchmark 2: Batched appends

| Batch size | TPS | Events/s | p50 | p95 | p99 |
|---|---|---|---|---|---|
| 10 | 1,494 | 14,939 | 0.586ms | 1.395ms | 1.867ms |
| 100 | 432 | 43,166 | 2.279ms | 2.555ms | 3.537ms |
| 1,000 | 58 | 57,872 | 17.0ms | 17.6ms | 17.6ms |

Batch amortization scales well up to 100 events/CTE. The 100→1000 jump shows diminishing returns — `unnest` + bulk INSERT overhead dominates at that size. Recommend capping batch size at 100-200 in the Haskell API unless callers explicitly opt in to larger batches.

### Benchmark 3: Cross-stream concurrent appends (`$all` contention)

| Connections | TPS | p50 | p95 | p99 |
|---|---|---|---|---|
| 4 | 5,407 | 0.637ms | 0.998ms | 2.071ms |
| 8 | 4,889 | 1.081ms | 3.787ms | 7.128ms |
| 16 | 4,185 | 2.629ms | 10.0ms | 18.1ms |
| 32 | 3,592 | 5.443ms | 27.1ms | 53.1ms |
| 64 | 3,015 | 13.2ms | 65.4ms | 112.5ms |

**This is the critical test.** The `$all` row lock cycle is ~0.28ms at 32 connections (1/3592), within the 0.5ms design ceiling. Throughput degrades gracefully from 5.4K→3.0K TPS as concurrency rises 4→64. The bottleneck is queueing, not the lock itself — latency grows linearly with writer count while throughput stays above 3K TPS.

At 32 connections, p99=53ms. For request-response APIs that append before responding, this is the write latency floor under heavy concurrent load.

### Benchmark 4: Cross-stream concurrent batched appends

| Connections | TPS | Events/s | p50 | p95 | p99 |
|---|---|---|---|---|---|
| 4 | 1,882 | 18,817 | 1.762ms | 3.203ms | 7.059ms |
| 8 | 1,831 | 18,308 | 2.972ms | 11.6ms | 19.2ms |
| 16 | 1,651 | 16,508 | 7.026ms | 25.8ms | 43.4ms |
| 32 | 1,461 | 14,612 | 15.2ms | 61.9ms | 98.5ms |

Below the 30K events/s target at 16 connections. Each 10-event batch holds the `$all` row lock ~0.6ms (vs ~0.28ms for single events), amplifying contention. This is the realistic ceiling for Strategy E under concurrent batched writes — roughly 15-19K events/s depending on concurrency.

### Benchmark 5: Read throughput

| Read type | Pages/s | p50 | p95 | p99 |
|---|---|---|---|---|
| Stream read | 1,102 | 0.832ms | 1.255ms | 2.210ms |
| `$all` read | 2,190 | 0.337ms | 0.527ms | 1.765ms |
| Category read | 1,100 | 1.061ms | 1.694ms | 3.257ms |

All read paths meet targets. `$all` reads are fastest — clean range scan on `(stream_id=0, stream_version)`. Category reads use a LATERAL join + partial index (`ix_stream_events_all_by_origin`) to avoid scanning all of `$all` — the planner finds category streams first, then fetches per-stream from the partial index and merges.

### Benchmark 6: Mixed read/write

| Component | Metric | Value |
|---|---|---|
| Writers (8c, 10/batch) | TPS | 1,664 |
| | Events/s | 16,638 |
| | p50 / p99 | 3.2ms / 22.5ms |
| Readers (8c, `$all` pages) | Pages/s | 14,097 |
| | p50 / p99 | 0.445ms / 1.830ms |

Read latency is unaffected by concurrent writes — READ COMMITTED isolation and the index-only scan on `stream_events` prevent interference. This confirms the schema design: writers contend on the `$all` row, but readers never wait for that lock.

---

## Analysis

### `$all` contention is acceptable

The lock cycle at 32 concurrent writers is 0.28ms — well within the 0.5ms design ceiling. The theoretical ceiling of ~3,500 batches/s (single events) or ~1,500 batches/s (10-event batches) translates to:

- **Single events:** ~3.5K events/s at 32 writers → ~300M events/day
- **10-event batches:** ~15K events/s at 32 writers → ~1.3B events/day
- **100-event batches (sequential):** ~43K events/s → ~3.7B events/day

These numbers serve mid-size to large systems comfortably. The escape hatches (schema partitioning, larger batches, Strategy D) are graduated and don't require architectural changes.

### Batch amortization is strong

The cost per event drops significantly with batch size:

| Batch size | Cost per event |
|---|---|
| 1 | 0.382ms |
| 10 | 0.067ms |
| 100 | 0.023ms |
| 1,000 | 0.017ms |

The Haskell API should encourage batched appends as the default path. A sensible default batch limit of 100-200 events balances throughput with per-CTE overhead.

### Category reads are solved

Initial category reads using `LIKE 'prefix-%'` were p50=5.1ms / p99=42.3ms — unacceptable. Three changes brought them to p50=1.06ms / p99=3.26ms:

1. **Generated `category` column** on `streams`: `GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED` — enables `= $1` instead of `LIKE`, zero maintenance.
2. **Partial index** `ix_stream_events_all_by_origin ON stream_events (original_stream_id, stream_version) WHERE stream_id = 0` — allows the planner to scan `$all` entries per originating stream rather than scanning all of `$all`.
3. **LATERAL join query pattern** — forces the planner to: find category streams → index scan each via the partial index → merge and sort → LIMIT 100. Without LATERAL, the planner chose a full `$all` scan with post-hoc filtering.

The LATERAL pattern is the recommended query shape for `readCategory` in the Haskell API.

### Read-write isolation is excellent

Bench 6 readers maintained p99=1.8ms while 8 writers pushed 16.6K events/s. This confirms that the `$all` row lock does not block readers — exactly as designed with READ COMMITTED.

---

## Practical capacity guide

| System profile | Typical event rate | Headroom at 16c batched |
|---|---|---|
| E-commerce (~100K orders/day) | ~50-200 events/s | 80x+ |
| SaaS platform (100K DAU) | ~500-2K events/s | 8-30x |
| Multi-tenant platform (1K active tenants) | ~2-5K events/s | 3-8x |
| Regional financial exchange | ~5-20K events/s | Borderline |
| IoT telemetry (100K+ devices) | ~100K events/s | Needs partitioning or Strategy D |

---

## Escape hatches (if the ceiling is reached)

1. **Larger batches** — buffer events client-side and flush in batches of 100+. Trades latency for throughput.
2. **Schema partitioning** — separate high-traffic tenants into their own schema. Each schema has its own `$all` row. Zero cross-tenant contention.
3. **Strategy D (Hindsight/xid8)** — remove the `$all` row, use `pg_current_xact_id()` for global ordering. Eliminates write contention entirely but loses gap-free ordering and immediate read-your-writes on `$all`.
4. **Read replicas** — if reads are the bottleneck (they aren't yet), add replicas. Write path is unaffected.

---

## Schema changes from baseline

Two additions to `schema.sql` based on benchmark findings:

1. **`category` generated column** on `streams` — `split_part(stream_name, '-', 1)`, stored. Enables efficient category filtering without LIKE.
2. **`ix_stream_events_all_by_origin` partial index** — `(original_stream_id, stream_version) WHERE stream_id = 0`. Enables per-stream scanning within `$all` for category reads.

Both are additive — no changes to existing columns, indexes, or write path.

## Next steps

1. ~~Proceed to Milestone 2: implement Haskell append operations~~ **Done.** See `docs/BENCH-HASKELL-APPEND.md`.
2. ~~Compare Haskell append overhead against these SQL baselines (target: < 20% overhead)~~ **Done.** Gate 2 passed — negative overhead (Haskell is 1.5–5x faster).
3. Use LATERAL join pattern for `readCategory` in the Haskell API
