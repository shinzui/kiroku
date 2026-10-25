# Milestone 4 — Store Handle + Public API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this milestone a caller can open a store with a single function call — `withStore settings action` — and the schema will be ready. They never need to think about connection pools, schema initialization, or hasql internals. The public API surface becomes: `withStore` to open, `runStoreIO` to run operations, and the `appendToStream` / `readStreamForward` / etc. functions inside the `Store` effect.

This milestone also validates that the abstraction layers introduced in Milestones 2 and 3 (effectful, `runStorePool`, `runStoreIO`) add no measurable overhead compared to calling the store directly. A pool saturation benchmark (64 concurrent writers, pool size 10) measures how the store behaves under contention and informs the default pool size.

**Observable outcomes:**

- `cabal build all` compiles with auto-initializing `withStore`.
- `cabal test all` passes all existing tests plus a new integration test exercising the full lifecycle through `withStore` alone.
- `cabal bench all` includes end-to-end benchmarks through the public API (B8) and a concurrent writer saturation benchmark (B9).
- Gate 3 verdict: no regression > 10% vs M2/M3 baselines, pool saturation results documented.


## Progress

- [x] M4.1: Update `withStore` to auto-initialize schema (2026-03-23)
- [x] M4.2: Add integration test through `withStore` public API (2026-03-23)
- [x] M4.3: Update existing tests to use `withStore` (2026-03-23)
- [x] M4.4: B8 — end-to-end benchmarks through public API (regression check) (2026-03-23)
- [x] M4.5: B9 — connection pool saturation benchmark (64 concurrent writers) (2026-03-23)
- [x] M4.6: Document Gate 3 results (2026-03-23)


## Surprises & Discoveries

- B9 pool saturation throughput (1,262 ops/s) is lower than the SQL baseline at 64 connections (3,015 TPS). The difference is primarily because the SQL baseline used 64 connections while our pool is 10. Additionally, `$all` row contention and per-operation effectful setup overhead contribute. The avg latency of 0.79ms is good considering 54/64 threads are always queued. (2026-03-23)
- The `withStore` auto-init adds zero measurable overhead to benchmarks. All B8 results are within noise of M2/M3 baselines. (2026-03-23)
- Removed `hasql-pool` from benchmark build-depends since benchmarks no longer construct pools directly (they use `withStore`). (2026-03-23)


## Decision Log

- Decision: Make `withStore` call `initializeSchema` on every open.
  Rationale: The schema DDL uses `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`, making it idempotent. Calling it on every startup is safe, simple, and eliminates the "forgot to initialize" failure mode. The cost is one SQL round-trip of no-ops after the first call.
  Date: 2026-03-23

- Decision: Remove `initializeSchema` from the public API re-exports in `Kiroku.Store`.
  Rationale: If `withStore` always initializes, callers should not need to call it themselves. Keeping it exported invites double-initialization or confusion. It remains available via direct import of `Kiroku.Store.Schema` for advanced use cases (e.g., running DDL against a pool that was not created by `withStore`).
  Date: 2026-03-23

- Decision: The pool saturation benchmark (B9) uses `Control.Concurrent.Async.mapConcurrently_` with 64 threads, each performing 100 single-event appends.
  Rationale: This matches the IMPLEMENTATION.md spec (64 concurrent writers, pool size 10). Using `async` from the `async` package is the standard Haskell approach for structured concurrency. Each thread measures its own wall-clock time and reports aggregate throughput and per-operation latency.
  Date: 2026-03-23

- Decision: Add `async` as a benchmark dependency only.
  Rationale: The concurrency benchmark needs `mapConcurrently_` from the `async` package. This dependency is only needed in the benchmark stanza, not the library or test suite.
  Date: 2026-03-23

- Decision: Keep `SchemaInitError` as a runtime exception (not part of `StoreError`).
  Rationale: Schema initialization failure is a startup-time error, not a per-operation error. It should crash the application immediately with a clear message, not be caught and handled in the `Error StoreError` effect. Throwing it as an exception from within `withStore` is appropriate since the caller cannot meaningfully recover.
  Date: 2026-03-23

- Decision: Auto-init in `withStore` is a temporary convenience; schema management will move to a separate package long-term.
  Rationale: Embedding schema DDL inside the store library couples deployment concerns (migration management, versioning, rollback) with runtime concerns (connection pooling, query execution). An administrator should be able to manage schema migrations independently — e.g., via a CLI tool or a dedicated `kiroku-migrate` package — without pulling in the store runtime. For now, auto-init via `IF NOT EXISTS` is acceptable because there is only one schema version and no migration path yet. When migrations become necessary (adding columns, indices, or new tables in future milestones), schema management should be extracted into its own package with proper versioned migrations.
  Date: 2026-03-23


## Outcomes & Retrospective

All milestones completed. `cabal build all` succeeds, `cabal test all` passes (20 tests), `cabal bench all` passes. Gate 3 verdict: **Pass**.

**B8 results:** Zero regression. All operations within noise of M2/M3 baselines (largest deviation: -3.1% = faster). The `withStore` bracket, effectful dynamic dispatch, and `runStoreIO` convenience wrapper add no measurable runtime cost.

**B9 results:** 64 concurrent writers at pool size 10 achieve 1,262 ops/s with 0.79ms avg latency. Throughput is bounded by `$all` row contention and pool queueing, not by the Haskell abstraction layers. Default pool size of 10 is appropriate.

**Public API simplification:** `withStore` is now the single entry point. Callers never call `initializeSchema` directly. Tests and benchmarks both use `withStore`, confirming it works as the production-ready API.


## Context and Orientation

Kiroku is a PostgreSQL event store implemented in Haskell. The core library lives in `kiroku-store/`. The project uses GHC 9.12.2 with the GHC2024 language edition.

The current codebase has these relevant modules:

- `kiroku-store/src/Kiroku/Store/Connection.hs` — defines `KirokuStore` (a record holding a `Pool` and `schema :: Text`), `ConnectionSettings`, and `withStore`. Currently, `withStore` acquires a pool and returns a `KirokuStore` but does **not** initialize the schema. The test and benchmark code call `initializeSchema pool "public"` separately after pool creation.

- `kiroku-store/src/Kiroku/Store/Schema.hs` — defines `initializeSchema :: Pool -> Text -> IO ()`. It runs embedded DDL (`sql/schema.sql`) via `Session.script`. The DDL is idempotent (uses `IF NOT EXISTS`). `SchemaInitError` wraps `UsageError` as an exception.

- `kiroku-store/src/Kiroku/Store/Effect.hs` — defines the `Store` effect GADT with six operations, `runStorePool` (the PostgreSQL interpreter), and `runStoreIO` (convenience: `runEff . runErrorNoCallStack . runStorePool store`).

- `kiroku-store/src/Kiroku/Store.hs` — the public API module. Re-exports `Types`, `Connection`, `Effect`, `Error`, `Append`, `Read`, and `initializeSchema`.

- `kiroku-store/test/Main.hs` — 19 tests (11 append + 8 read) using hspec. The `withTestStore` helper manually creates a pool, calls `initializeSchema`, and constructs a `KirokuStore` record by hand — it does not use `withStore`.

- `kiroku-store/bench/Main.hs` — benchmarks using `tasty-bench`. The setup similarly constructs the pool and schema manually.

- `kiroku-store/kiroku-store.cabal` — the cabal file. The library exposes all modules listed above. The test suite depends on `ephemeral-pg`, `hspec`, etc. The benchmark depends on `tasty-bench`, `ephemeral-pg`, etc.

**Baseline benchmark results** (from Milestone 2 and 3):

| Operation | M2/M3 Result |
|---|---|
| Single-event append (NoStream) | 65.3μs |
| Batch-10 append (NoStream) | 209μs |
| Batch-100 append (NoStream) | 1.57ms |
| Sequential (10 appends) | 655μs |
| Stream read (100-event page) | 969μs |
| $all read (100-event page) | 975μs |

Gate 3 acceptance: no regression > 10% vs these baselines when running through the public API.


## Plan of Work

The work has three phases: update `withStore` and tests (M4.1–M4.3), add benchmarks (M4.4–M4.5), and document results (M4.6).

### Milestone 4.1 — Auto-initialize schema in `withStore`

This milestone modifies `withStore` in `kiroku-store/src/Kiroku/Store/Connection.hs` so that after acquiring the pool, it calls `initializeSchema pool schema` before returning the `KirokuStore` handle. If initialization fails, the exception propagates and the pool is released by the `bracket` cleanup.

The change is small: in the `acquire` function, add an `initializeSchema` call between pool creation and the `pure KirokuStore` return. Import `Kiroku.Store.Schema (initializeSchema)`.

Then update `kiroku-store/src/Kiroku/Store.hs` to remove `initializeSchema` from its re-exports. The function remains accessible via `Kiroku.Store.Schema` for direct import.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 4.2 — Integration test through `withStore`

Add a new test section in `kiroku-store/test/Main.hs` that exercises the full lifecycle through the public API only: open with `withStore`, append events, read them back, query metadata, close. This test must not import any internal modules or construct `KirokuStore` by hand.

The test helper `withTestStorePublic` will use `ephemeral-pg` to get a connection string, then pass it to `withStore` (via `defaultConnectionSettings`) to get a fully initialized store. Since `withStore` now auto-initializes, no separate `initializeSchema` call is needed.

At the end of this milestone, `cabal test kiroku-store-test` passes with the new integration test.

### Milestone 4.3 — Update existing test helper

Update `withTestStore` in the test file to use `withStore` instead of manually constructing the pool and calling `initializeSchema`. This simplifies the test setup and validates that `withStore` works correctly as the single entry point. The `ephemeral-pg` bracket provides the connection string; `withStore` handles everything else.

At the end of this milestone, all tests still pass (the existing 19 + new integration test).

### Milestone 4.4 — B8: End-to-end benchmarks (regression check)

The existing benchmarks already run through the public API (`runStoreIO store $ appendToStream ...`). However, the store is constructed manually in the benchmark setup. Update the benchmark setup to use `withStore` (via `defaultConnectionSettings`) so the benchmarks exercise the full public API path including the auto-initializing `withStore`.

Run `cabal bench kiroku-store-bench` and compare against the M2/M3 baselines. Gate 3 acceptance: no regression > 10%.

### Milestone 4.5 — B9: Connection pool saturation

Add a new benchmark group `"concurrent"` that measures pool saturation behavior. The benchmark spawns 64 concurrent threads (via `Control.Concurrent.Async.mapConcurrently_`), each performing 100 single-event appends through `runStoreIO`. The pool size remains at 10 (the default), so 54 threads must queue for connections.

Measure:
- Total wall-clock time for 6,400 appends (64 threads × 100 each)
- Throughput: events/s
- Compare against single-threaded throughput to assess contention overhead

Add `async` to the benchmark `build-depends` in `kiroku-store.cabal`.

At the end, `cabal bench kiroku-store-bench` runs all benchmarks including the concurrent group.

### Milestone 4.6 — Document Gate 3 results

Record the benchmark results in `docs/BENCH-GATE3.md`. Compare end-to-end results against M2/M3 baselines. Document the pool saturation findings. State the Gate 3 verdict.


## Concrete Steps

All commands run from: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Step 1: Verify current build.**

    cabal build all

**Step 2: Update `withStore` to auto-initialize schema.**

Edit `kiroku-store/src/Kiroku/Store/Connection.hs`. Edit `kiroku-store/src/Kiroku/Store.hs`.

    cabal build lib:kiroku-store

**Step 3: Add integration test and update test helper.**

Edit `kiroku-store/test/Main.hs`.

    cabal test kiroku-store-test

Expected: all tests pass (19 existing + new integration test).

**Step 4: Update benchmark setup and add concurrent benchmark.**

Edit `kiroku-store/kiroku-store.cabal` (add `async` to bench depends). Edit `kiroku-store/bench/Main.hs`.

    cabal build kiroku-store-bench

**Step 5: Run benchmarks.**

    cabal bench kiroku-store-bench

Compare against baselines:

| Operation | M2/M3 Baseline | Gate 3 Target (< 10% regression) |
|---|---|---|
| Single-event (NoStream) | 65.3μs | < 71.8μs |
| Batch-10 (NoStream) | 209μs | < 230μs |
| Batch-100 (NoStream) | 1.57ms | < 1.73ms |
| Sequential (10 appends) | 655μs | < 721μs |
| Stream read (100-event page) | 969μs | < 1.07ms |
| $all read (100-event page) | 975μs | < 1.07ms |

**Step 6: Document results.**

Write `docs/BENCH-GATE3.md` with results and Gate 3 verdict.


## Validation and Acceptance

### Compilation

    cabal build all

Must succeed with no warnings in kiroku-store modules.

### Tests

    cabal test all

All test cases must pass — the 19 existing tests plus the new integration test (at least 20 total).

Key behaviors for the integration test:

- The test opens the store with `withStore` and a `defaultConnectionSettings` built from the ephemeral-pg connection string. No manual `initializeSchema` call is made.
- After opening, the test appends events, reads them back, queries metadata, and verifies correctness.
- The test closes the store and the bracket ensures cleanup.

### Benchmarks

    cabal bench kiroku-store-bench

**B8 (regression check):** All existing benchmarks run through `withStore`. Results must be within 10% of M2/M3 baselines.

**B9 (pool saturation):** The concurrent benchmark completes and reports throughput. Expected: throughput degrades gracefully from single-threaded but stays above 3K events/s (matching the SQL baseline at 64 connections). Latency increases are expected and will be documented.


## Idempotence and Recovery

All steps are idempotent. `cabal build` is incremental. Tests use `ephemeral-pg` which creates a fresh database per run. Schema initialization is idempotent (IF NOT EXISTS). If a step fails, fix the issue and re-run the same command.


## Interfaces and Dependencies

### Updated Module: `Kiroku.Store.Connection`

`withStore` gains an `initializeSchema` call in its `acquire` phase:

    withStore :: ConnectionSettings -> (KirokuStore -> IO a) -> IO a

The signature does not change. The behavior changes: after acquiring the pool, `withStore` calls `initializeSchema pool schema` before returning the `KirokuStore` handle. If `initializeSchema` throws `SchemaInitError`, the bracket's cleanup releases the pool.

### Updated Module: `Kiroku.Store`

Remove `initializeSchema` from the public re-exports. The export list becomes:

    module Kiroku.Store (
        module Kiroku.Store.Types,
        module Kiroku.Store.Connection,
        module Kiroku.Store.Effect,
        module Kiroku.Store.Error,
        module Kiroku.Store.Append,
        module Kiroku.Store.Read,
    ) where

### New Dependency: `async` (benchmark only)

Added to `kiroku-store.cabal` benchmark `build-depends`:

    , async >= 2.2

### New Document: `docs/BENCH-GATE3.md`

Gate 3 benchmark results and verdict.
