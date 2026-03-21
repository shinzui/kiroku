# Kiroku-Store — Implementation & Benchmarking Plan

> Build order designed to validate performance assumptions early, before investing in the full API surface.

## Guiding Principle

The riskiest assumption in Kiroku's design is the `$all` row contention ceiling — Strategy E's throughput depends on how fast PostgreSQL can serialize `UPDATE ... RETURNING` on a single row under concurrent load. We validate this **before** building the full Haskell API, using a two-track approach: raw SQL benchmarks on Day 1, then Haskell layer benchmarks as modules come online. Full kiroku-store implementation in ~5 days.

---

## Track 1: SQL Validation (Day 1)

Validate the CTE and schema performance with pure SQL before writing any Haskell. This catches schema-level problems early (bad indexes, lock contention surprises, CTE plan regressions) with minimal investment.

### 1.1 — Schema Setup

Stand up the schema from DESIGN.md against a local PostgreSQL 18 instance:

- `streams`, `events`, `stream_events` tables
- All indexes
- Immutability and deletion triggers
- Seed `$all` stream (stream_id = 0)

**Deliverable:** A `schema.sql` file that can be applied to a fresh database.

### 1.2 — SQL Benchmark Script

A `pgbench`-compatible or plain SQL script that exercises the critical paths:

#### Benchmark 1: Single-stream sequential appends
```
- 1 connection, 1 stream
- Append 1 event per CTE, 10,000 iterations
- Measures: baseline single-append latency (should be < 1ms)
```

#### Benchmark 2: Single-stream batched appends
```
- 1 connection, 1 stream
- Append 10 events per CTE, 1,000 iterations
- Append 100 events per CTE, 100 iterations
- Append 1,000 events per CTE, 10 iterations
- Measures: batch amortization curve, parameter array overhead
```

#### Benchmark 3: Cross-stream concurrent appends ($all contention)
```
- N connections (4, 8, 16, 32, 64), each writing to a unique stream
- 1 event per CTE, 1,000 iterations each
- Measures: $all row contention — this is the critical test
- Target: > 5K batches/s sustained at 32 connections
```

#### Benchmark 4: Cross-stream batched concurrent appends
```
- N connections (4, 8, 16, 32), each writing to a unique stream
- 10 events per CTE, 1,000 iterations each
- Measures: realistic throughput ceiling (batched writes × concurrent streams)
- Target: > 30K events/s at 16 connections
```

#### Benchmark 5: Read throughput
```
- Pre-populate 100K events across 100 streams + $all
- 1 connection, sequential reads of 100-event pages
- Measures: read latency per page (stream read, $all read, category read)
- Target: < 2ms per 100-event page
```

#### Benchmark 6: Mixed read/write
```
- N writer connections (8), M reader connections (8)
- Writers: 10 events per CTE, continuous
- Readers: 100-event pages from $all, continuous
- Measures: read latency under write load, write throughput under read load
```

### 1.3 — What to Look For

| Signal | Action |
|---|---|
| `$all` contention > 0.5ms per lock cycle at 32 connections | Investigate `pg_stat_activity` wait events. If row lock is the bottleneck, this confirms the ~5K batch/s ceiling. Acceptable. |
| `$all` contention > 2ms per lock cycle | Schema or CTE problem. Check `EXPLAIN ANALYZE` for sequential scans, missing indexes, or plan regressions. |
| Batch append doesn't scale linearly with batch size | Check `unnest` performance, parameter marshaling overhead. May need to tune batch limit. |
| Read latency degrades under write load | Check for lock contention on `stream_events` index. READ COMMITTED should prevent this — investigate if seen. |
| Category read > 10x stream read | The `LIKE` prefix match may not use the index well. Consider a GIN trigram index or a separate `category` column. |

### 1.4 — EXPLAIN ANALYZE Catalog

Capture and store `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` output for each CTE variant:
- `append_expected_version` (the main CTE)
- `append_any_version`
- `append_no_stream`
- `readStreamForward` (100 events)
- `readAllForward` (100 events)
- `readCategory` (100 events)

These form the baseline for detecting plan regressions as the schema or data volume changes.

---

## Track 2: Haskell Implementation (Days 1–5)

Build modules in an order that enables Haskell-level benchmarking at each milestone. Track 1 and Milestone 0 run in parallel on Day 1.

### Milestone 0 — Project Scaffolding (Day 1, morning)

**Goal:** Cabal project compiles, nix shell works, can connect to PostgreSQL.

- [ ] `kiroku-store.cabal` with dependencies: `hasql`, `hasql-pool`, `hasql-transaction`, `hasql-th`, `uuid`, `aeson`, `vector`
- [ ] Nix flake with PostgreSQL 18, GHC, cabal
- [ ] `Kiroku.Store.Connection` — `ConnectionSettings`, pool creation, `withPool` bracket
- [ ] Smoke test: acquire connection from pool, run `SELECT 1`

**No benchmarks yet.** Just confirm the toolchain works.

### Milestone 1 — Schema + Types (Day 1, afternoon)

**Goal:** Initialize database, core types defined.

- [ ] `Kiroku.Store.Types` — all domain types from DESIGN.md (`StreamName`, `EventId`, `EventData`, `RecordedEvent`, `StreamInfo`, `AppendResult`, `AppendError`, `ExpectedVersion`)
- [ ] `Kiroku.Store.Schema` — `initializeSchema :: Pool -> Text -> IO ()` (schema-parameterized DDL)
- [ ] Test: initialize schema, verify tables exist, verify `$all` stream seeded

**No benchmarks yet.** Foundation for everything that follows.

### Milestone 2 — Append (Day 2)

**Goal:** All append variants work. This is the performance-critical write path.

- [ ] `Kiroku.Store.SQL` — hasql statements for `append_expected_version`, `append_stream_exists`, `append_any_version`, `append_no_stream`
- [ ] `Kiroku.Store.Append` — public API functions wrapping SQL statements
- [ ] `Kiroku.Store.Error` — PostgreSQL error code mapping (23505 → `DuplicateEvent`/`StreamAlreadyExists`/`WrongExpectedVersion`, 23503 → `StreamNotFound`)
- [ ] Client-side UUIDv7 pre-generation for `EventData` with `eventId = Nothing`
- [ ] Tests:
  - Append with exact version check (happy path)
  - Version conflict returns `WrongExpectedVersion`
  - `append_no_stream` creates stream, fails on existing
  - `append_any_version` creates or appends
  - `append_stream_exists` fails on missing stream
  - Duplicate event ID returns `DuplicateEvent`

**Benchmark gate — Milestone 2:**

```
┌─────────────────────────────────────────────────────────┐
│  BENCHMARK: Append throughput via Haskell                │
│                                                          │
│  B1: Sequential single-event appends (1 thread)         │
│      → Compare against Track 1 SQL baseline              │
│      → Haskell overhead should be < 20% vs raw SQL       │
│                                                          │
│  B2: Sequential batch appends (1, 10, 100, 1000 events) │
│      → Verify batch amortization matches SQL baseline    │
│                                                          │
│  B3: Concurrent cross-stream appends (4, 8, 16 threads) │
│      → Each thread: own stream, 10 events/batch          │
│      → Verify $all contention matches SQL baseline       │
│      → This is the critical validation point             │
│                                                          │
│  STOP if Haskell overhead > 30% vs SQL baseline.         │
│  Investigate: hasql encoding, pool contention,           │
│  parameter marshaling, connection overhead.               │
└─────────────────────────────────────────────────────────┘
```

### Milestone 3 — Read (Day 3)

**Goal:** All read operations work. Performance-critical read path.

- [ ] `Kiroku.Store.SQL` — hasql statements for `readStreamForward`, `readAllForward`, `readStreamBackward`, `readAllBackward`, `getStream`
- [ ] `Kiroku.Store.Read` — public API functions
- [ ] Tests:
  - Read-your-own-writes (append then read in same test)
  - Forward/backward ordering
  - Cursor-based pagination
  - `getStream` returns correct version after appends
  - `getStream` returns `Nothing` for nonexistent stream

**Benchmark gate — Milestone 3:**

```
┌─────────────────────────────────────────────────────────┐
│  BENCHMARK: Read throughput via Haskell                   │
│                                                          │
│  B4: Stream read (100-event pages, 1 thread)             │
│      → Target: < 2ms per page                            │
│                                                          │
│  B5: $all read (100-event pages, 1 thread)               │
│      → Compare against stream read                       │
│                                                          │
│  B6: Mixed read/write (8 writers, 8 readers)             │
│      → Writers: 10 events/batch to unique streams        │
│      → Readers: 100-event pages from $all                │
│      → Read p99 should stay < 5ms under write load       │
│                                                          │
│  B7: Read at scale (1M events pre-loaded)                │
│      → Same read benchmarks at realistic data volume     │
│      → Watch for index scan degradation                  │
└─────────────────────────────────────────────────────────┘
```

### Milestone 4 — Store Handle + Public API (Day 3, afternoon)

**Goal:** `KirokuStore` handle, `withStore` bracket, re-exports. The library is usable.

- [ ] `Kiroku.Store` — `KirokuStore` record, `withStore`, re-exports of Append/Read/Types/Error
- [ ] `withStore` initializes schema if needed (idempotent)
- [ ] Integration test: full lifecycle through public API only

**Benchmark gate — Milestone 4:**

```
┌─────────────────────────────────────────────────────────┐
│  BENCHMARK: End-to-end through public API                │
│                                                          │
│  B8: Repeat B1–B7 through KirokuStore public API         │
│      → Verify no performance regression from the          │
│        handle/bracket abstraction layer                   │
│                                                          │
│  B9: Connection pool saturation                          │
│      → 64 concurrent writers, pool size 10               │
│      → Measure queue time vs execution time              │
│      → Tune default pool size                            │
└─────────────────────────────────────────────────────────┘
```

### Milestone 5 — Links & Categories (Day 4)

**Goal:** Phase 1b complete.

- [ ] `Kiroku.Store.Link` — `linkToStream`
- [ ] `Kiroku.Store.Read` — `readCategory`
- [ ] Multi-stream transactions
- [ ] Tests: link events, category reads, multi-stream atomicity

**Benchmark: Category read performance at scale (1M events, 100 categories).**

### Milestone 6 — Lifecycle & Deletes (Day 5)

**Goal:** Phase 1c complete. kiroku-store is feature-complete.

- [ ] Soft delete, gated hard delete
- [ ] Connection health checks
- [ ] `idle_in_transaction_session_timeout`
- [ ] Metrics/observability hooks

**Final benchmark suite run — full regression against all previous gates.**

---

## Benchmark Infrastructure

### Tool Choice: `tasty-bench` + custom harness

```haskell
-- Benchmark harness sketch
data BenchEnv = BenchEnv
    { benchStore :: KirokuStore
    , benchPool  :: Pool          -- direct pool access for SQL-level benchmarks
    }

withBenchEnv :: (BenchEnv -> IO a) -> IO a
-- Creates a fresh schema per benchmark run (multi-tenant makes this easy)
-- Tears down after
```

Use `tasty-bench` for microbenchmarks (individual operations) — it's lightweight, depends only on `tasty`, and supports CSV/JSON output for trend tracking. Use a custom harness for concurrency/throughput tests that need to coordinate multiple threads and measure aggregate throughput.

### Benchmark Organization

```
kiroku-store/
  bench/
    Main.hs                        -- tasty-bench entry point
    Kiroku/
      Bench/
        SQL.hs                     -- Track 1: raw SQL benchmarks via hasql
        Append.hs                  -- Milestone 2: append throughput
        Read.hs                    -- Milestone 3: read throughput
        Concurrent.hs              -- Cross-stream contention, mixed r/w
        Scale.hs                   -- Large dataset benchmarks (1M+ events)
        Harness.hs                 -- BenchEnv, helpers, schema setup/teardown
```

### Environment Requirements

- PostgreSQL 18 (for `uuidv7()`)
- Dedicated test database (not shared)
- `fsync = off` for benchmarks (not realistic but isolates CPU/lock overhead from I/O)
- Repeat with `fsync = on` for production-realistic numbers
- Report both: "theoretical ceiling" and "production floor"

### Reporting

Each benchmark run produces:
1. **Summary table** — operation, p50, p95, p99, throughput (ops/s or events/s)
2. **Comparison** — vs previous run (regression detection)
3. **vs SQL baseline** — Haskell overhead percentage

Store results in `bench/results/` as JSON for trend tracking.

---

## Performance Targets

| Operation | Target (p50) | Target (p99) | Throughput |
|---|---|---|---|
| Single-event append (1 thread) | < 0.5ms | < 2ms | > 2K ops/s |
| 10-event batch append (1 thread) | < 1ms | < 3ms | > 10K events/s |
| Cross-stream append (16 threads, 10/batch) | < 2ms | < 10ms | > 30K events/s |
| Cross-stream append (32 threads, 10/batch) | < 5ms | < 20ms | > 50K events/s |
| Stream read (100-event page) | < 1ms | < 3ms | > 5K pages/s |
| $all read (100-event page) | < 1ms | < 3ms | > 5K pages/s |
| Read under write load (8w/8r) | < 2ms | < 5ms | — |
| Category read (100-event page) | < 3ms | < 10ms | > 1K pages/s |

These targets assume a single PostgreSQL instance on local SSD. Network latency adds to all numbers in production.

---

## Decision Points

### Gate 1: After Track 1 SQL benchmarks

| Result | Action |
|---|---|
| `$all` contention within bounds (< 0.5ms/lock cycle at 32 connections) | Proceed with Strategy E. |
| `$all` contention 0.5–2ms/lock cycle | Acceptable but document the ceiling. Consider advisory lock pre-serialization for hot streams. |
| `$all` contention > 2ms/lock cycle | Investigate. Possible causes: bloated `streams` table, bad plan, missing index. If unfixable, evaluate Strategy D fallback. |
| Category read unacceptably slow | Add `category` column or GIN index before building `readCategory` in Haskell. |

### Gate 2: After Milestone 2 (Haskell append benchmarks)

| Result | Action |
|---|---|
| Haskell overhead < 20% vs SQL | Proceed. hasql encoding is efficient. |
| Haskell overhead 20–30% | Profile. Likely causes: `vector` construction for parameter arrays, `aeson` JSONB encoding, pool acquisition. Optimize before proceeding. |
| Haskell overhead > 30% | Stop. Profile deeply. Consider: prepared statement caching, batch parameter encoding, pool tuning. Do not proceed to Milestone 3 until resolved. |

### Gate 3: After Milestone 4 (public API benchmarks)

| Result | Action |
|---|---|
| No regression vs Milestone 2/3 | Ship it. kiroku-store is performant. |
| Minor regression (< 10%) | Accept if from necessary abstractions (bracket, error wrapping). Document. |
| Major regression (> 10%) | The `KirokuStore` abstraction is too heavy. Simplify the handle, reduce indirection. |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `$all` row becomes a bottleneck earlier than predicted | Low | High | Track 1 validates this before any Haskell code. Strategy D is the documented escape hatch. |
| `hasql-th` compile-time SQL checking rejects the CTE | Medium | Medium | Fall back to `hasql` manual encoders/decoders. Less type safety but same runtime performance. |
| UUIDv7 client-side generation in Haskell is slow | Low | Low | Use `uuid` library's V7 support. If unavailable, generate from timestamp + random bytes directly. |
| `unnest` with 7 parallel arrays has unexpected overhead at batch size 1000 | Low | Medium | Track 1 Benchmark 2 catches this. If seen, reduce batch limit or switch to `COPY`. |
| JSONB encoding overhead dominates append latency | Medium | Medium | Profile at Milestone 2. If significant, consider pre-encoding to `ByteString` and passing as `jsonb` cast. |
| Pool exhaustion under burst load | Medium | Medium | Benchmark 9 at Milestone 4 sizes the pool. Consider bounded queue with backpressure. |
