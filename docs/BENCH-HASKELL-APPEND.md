# Gate 2: Haskell Append Benchmark Results

> See [`docs/perf-experiment-log.md`](perf-experiment-log.md) for the history
> of append-performance experiments and
> [`docs/PERF-METHODOLOGY.md`](PERF-METHODOLOGY.md) for the discipline future
> optimization plans must follow.

> Results from tasty-bench benchmarks via `appendToStream` against ephemeral PostgreSQL 18 (macOS, unix socket).
> Run date: 2026-03-22. Milestone 2 (Append Operations).

## Summary

The Haskell append layer adds **no measurable overhead** compared to the pgbench SQL baseline. In all cases the Haskell path is faster — hasql's prepared statements, binary protocol, and client-side UUIDv7 generation outperform pgbench's per-query SQL parsing and PL/pgSQL UUID generation.

### Gate 2 Decision: **Pass. Proceed to Milestone 3 (Read Operations).**

---

## Results

### Single-event appends (new stream per iteration)

| Variant | Mean | ± | TPS |
|---|---|---|---|
| NoStream | 64.8μs | 5.0μs | 15,432 |
| AnyVersion | 64.8μs | 4.0μs | 15,432 |

Both variants show identical performance — the `INSERT ON CONFLICT DO UPDATE` upsert in AnyVersion has the same cost as the plain `INSERT ... ON CONFLICT DO NOTHING` in NoStream. Each iteration creates a new stream and appends one event, exercising the full CTE: stream creation, event insert, source link, `$all` update, `$all` link.

### Batched appends (new stream per iteration)

| Batch size | Mean | ± | Events/s | Cost per event |
|---|---|---|---|---|
| 10 | 202μs | 19μs | 49,505 | 20.2μs |
| 100 | 1.55ms | 133μs | 64,516 | 15.5μs |

Batch amortization matches the SQL baseline pattern — cost per event drops with batch size. At 100 events, the throughput ceiling is ~64K events/s single-threaded.

### Sequential appends (10 appends to same stream)

| Metric | Value |
|---|---|
| Total (10 appends) | 659μs |
| Per append | 65.9μs |
| TPS | 15,175 |

This measures the realistic "aggregate" pattern: create stream (NoStream), then append 9 more events with ExactVersion checks. Per-append latency is consistent with the single-event benchmarks, confirming that the version check in the CTE adds negligible cost.

---

## Comparison with SQL Baseline (Track 1)

| Operation | SQL Baseline (pgbench) | Haskell (tasty-bench) | Speedup |
|---|---|---|---|
| Single-event append | 328μs / 2,620 TPS | 64.8μs / 15,432 TPS | **5.1x faster** |
| 10-event batch | 586μs / 14,939 ev/s | 202μs / 49,505 ev/s | **3.3x faster** |
| 100-event batch | 2.28ms / 43,166 ev/s | 1.55ms / 64,516 ev/s | **1.5x faster** |

The speedup is most pronounced for single-event appends (5.1x) and diminishes as batch size grows (1.5x at 100). This is expected: per-statement overhead (SQL parsing, parameter marshaling) is the dominant cost at small batch sizes, and the Haskell path eliminates most of it through prepared statements and binary encoding. At larger batch sizes, the PostgreSQL CTE execution dominates and the client-side overhead becomes proportionally smaller.

### Why Haskell is faster (not slower)

The Gate 2 target was "< 20% overhead vs SQL baseline." The Haskell path is instead faster because:

1. **Prepared statements.** hasql prepares the CTE once and reuses the execution plan. pgbench parses SQL text on every iteration.
2. **Binary protocol.** hasql sends parameters and receives results in PostgreSQL's binary format. pgbench uses text format, requiring serialization/deserialization on both sides.
3. **Client-side UUIDv7.** The Haskell path pre-generates UUIDs via `mmzk-typeid` before sending the query. The pgbench scripts used `gen_random_uuid()` in PL/pgSQL, which is server-side and per-row.
4. **Connection pooling.** hasql-pool maintains persistent connections. pgbench establishes connections per-test (though it reuses within a run).

These factors compound most at small batch sizes where per-statement overhead is proportionally larger.

---

## Cost per event

| Batch size | SQL Baseline | Haskell | Improvement |
|---|---|---|---|
| 1 | 382μs | 64.8μs | 5.9x |
| 10 | 66.9μs | 20.2μs | 3.3x |
| 100 | 23.2μs | 15.5μs | 1.5x |

The Haskell API's cost-per-event at batch size 10 (20.2μs) is already lower than the SQL baseline at batch size 100 (23.2μs). This means callers can use smaller, more frequent batches without paying a throughput penalty.

---

## Methodology notes

- **Tool:** `tasty-bench` with `whnfIO` (each iteration is a full IO action)
- **Database:** ephemeral-pg (temporary PostgreSQL 18 instance, unix socket, local SSD)
- **Pool size:** 10 connections
- **Stream isolation:** Each benchmark iteration creates a new stream (unique name via atomic counter), avoiding same-stream contention
- **Schema:** Full production schema including all triggers (NOTIFY, immutability, deletion protection)
- **UUIDv7:** Client-side generation via `mmzk-typeid` (`genUUIDs` for batches)
- **GHC:** 9.12.2, `-O1`, `-threaded -rtsopts -A32m`

### Caveats

These benchmarks measure **single-threaded, uncontended** append throughput — the Haskell layer overhead vs raw SQL. They do **not** measure concurrent `$all` row contention, which was validated in Track 1 (SQL Benchmark 3/4). Concurrent Haskell benchmarks are deferred to Milestone 4 (Public API).

The ephemeral-pg instance uses default PostgreSQL settings (no `fsync = off` tuning), so the numbers include fsync overhead. The SQL baseline used the same default settings, making the comparison valid.

---

## Next steps

1. Proceed to Milestone 3: implement read operations
2. Concurrent append benchmarks at Milestone 4 (through public API)
3. Mixed read/write benchmarks at Milestone 4
