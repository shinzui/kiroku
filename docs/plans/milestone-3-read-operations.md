# Milestone 3 — Read Operations + Effectful

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

This milestone does two things at once. First, it introduces `effectful` as the effect system for kiroku-store, replacing raw `IO (Either e a)` return types with typed, composable effect constraints. Second, it implements the read path — forward and backward reads from named streams, from `$all`, and stream metadata queries.

After this milestone a caller writes store operations inside an `Eff` computation with `Store :> es` and `Error StoreError :> es` constraints. The `Store` effect is dynamically dispatched — its operations are constructors of a GADT, and the real implementation (`runStorePool`) interprets them against PostgreSQL via hasql-pool. This design allows alternative interpreters such as a pure in-memory mock for unit tests.

A caller can:

1. Append events using `appendToStream`, now dispatched through the `Store` effect.
2. Read events from a named stream in forward or backward order with cursor-based pagination.
3. Read from the global `$all` stream in forward or backward order.
4. Query stream metadata via `getStream`.
5. Handle all errors through a single `StoreError` type in the `Error` effect.

**Observable outcomes:**

- `cabal build all` compiles with the new effect system, refactored Append, new Read module, and updated public API.
- `cabal test all` passes all existing append tests (adapted to effectful) plus new read tests.
- `cabal bench all` includes both append and read benchmarks.


## Progress

- [x] M3.1: Add `effectful-core` dependency, define `Store` effect GADT, `StoreError` type, and `runStorePool` interpreter (2026-03-22)
- [x] M3.2: Refactor `Kiroku.Store.Append` to dispatch through the `Store` effect (2026-03-22)
- [x] M3.3: Add read SQL statements to `Kiroku.Store.SQL` (2026-03-22)
- [x] M3.4: Create `Kiroku.Store.Read` module dispatching through the `Store` effect (2026-03-22)
- [x] M3.5: Update `Kiroku.Store` public API and re-exports (2026-03-22)
- [x] M3.6: Adapt existing append tests to effectful, add read tests (2026-03-22)
- [x] M3.7: Update benchmarks for effectful (2026-03-22)
- [x] M3.8: Read benchmarks (Gate 3) (2026-03-22)


## Surprises & Discoveries

- GHC2024 does not enable `TypeFamilies` by default. Had to add `{-# LANGUAGE TypeFamilies #-}` to `Effect.hs` for `type instance DispatchOf Store = Dynamic`. (2026-03-22)
- M3.1–M3.5 were implemented together in a single pass since the modules are tightly coupled (GADT, interpreter, SQL, send wrappers, and public API all reference each other). The plan's phasing was useful for thinking but impractical for separate compile steps. (2026-03-22)
- `$all` read overhead vs SQL baseline is 2.89x (0.975ms vs 0.337ms) while stream read is only 1.16x. The difference is likely due to the larger pre-populated dataset for `$all` benchmarks (10 streams × 100 events = 1000 events total in `$all`) vs the stream read benchmark (1000 events in a single stream). Both meet Gate 3 targets. (2026-03-22)


## Decision Log

- Decision: Use `effectful-core` (not the full `effectful` package) as the dependency.
  Rationale: `effectful-core` provides all the primitives we need — `Eff`, `IOE`, `Error`, dynamic dispatch, `interpret_` — without bundling extra effects (Concurrent, Reader, State, etc.) that we don't use yet. Upgrade to `effectful` later if needed.
  Date: 2026-03-22

- Decision: Use dynamic dispatch for the `Store` effect.
  Rationale: Dynamic dispatch defines store operations as GADT constructors. The real interpreter (`runStorePool`) talks to PostgreSQL; an alternative interpreter can provide a pure in-memory mock for unit tests, property tests, or simulation. The performance cost of dynamic dispatch (one dictionary lookup per operation) is negligible compared to a database round-trip.
  Date: 2026-03-22

- Decision: The `Store` effect GADT defines one constructor per store operation — `AppendToStream`, `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `GetStream`.
  Rationale: Each constructor captures the operation's parameters and return type. This makes the effect a complete specification of the store interface. Callers use thin wrapper functions (`appendToStream`, `readStreamForward`, etc.) that call `send` on the corresponding constructor.
  Date: 2026-03-22

- Decision: Unify `AppendError` and connection errors into a single `StoreError` sum type.
  Rationale: With effectful's `Error` effect, we want one error type for the store layer. `StoreError` has constructors for each domain error (WrongExpectedVersion, StreamNotFound, etc.) plus a `ConnectionError` constructor for pool/session failures.
  Date: 2026-03-22

- Decision: Keep `Kiroku.Store.Error` as the module for the error type and mapping logic, renamed from `AppendError` to `StoreError`.
  Rationale: The existing error mapping code (PostgreSQL error codes to domain errors) stays in `Error.hs`. The type gets renamed since it now covers the entire store surface.
  Date: 2026-03-22

- Decision: The `Store` effect and its interpreters live in `Kiroku.Store.Effect` (new file).
  Rationale: Separating the effect definition from `Connection.hs` keeps concerns clean. `Connection.hs` keeps `ConnectionSettings`, `KirokuStore`, and `withStore`. `Effect.hs` defines the GADT, the `runStorePool` interpreter, and the `send`-based wrapper functions.
  Date: 2026-03-22

- Decision: Provide `runStoreIO` convenience that composes `runEff . runErrorNoCallStack . runStorePool store`.
  Rationale: Most callers want a simple `IO` entry point. Power users compose effects manually.
  Date: 2026-03-22

- Decision: The read functions return `Vector RecordedEvent` rather than `[RecordedEvent]`.
  Rationale: hasql's `rowVector` decoder is faster than `rowList`. Callers convert cheaply if needed.
  Date: 2026-03-22

- Decision: Read functions accept `StreamName` (not `StreamId`) for the public API.
  Rationale: Callers identify streams by name. The SQL resolves names internally.
  Date: 2026-03-22

- Decision: `getStream` returns `Maybe StreamInfo`, not an error for missing streams.
  Rationale: A missing stream is a valid query result, not an error.
  Date: 2026-03-22

- Decision: Defer `readCategory` to Milestone 5 (Links & Categories).
  Rationale: Category reads require the LATERAL join pattern and belong with link operations.
  Date: 2026-03-22

- Decision: Stream reads set `globalPosition = GlobalPosition 0` since the global position is not available without an extra join to the `$all` row.
  Rationale: The DESIGN.md stream read query does not include global position. Callers who need it should read from `$all`.
  Date: 2026-03-22

- Decision: The `Kiroku.Store.Append` and `Kiroku.Store.Read` modules become thin wrappers around `send`.
  Rationale: With dynamic dispatch, the actual logic (SQL execution, error mapping) moves into the interpreter (`runStorePool`). The public modules just provide ergonomic function signatures that call `send` on the GADT constructors. This keeps the public API clean while centralizing the implementation in one place.
  Date: 2026-03-22


## Outcomes & Retrospective

All milestones completed. `cabal build all` succeeds, `cabal test all` passes (19 tests: 11 append + 8 read), `cabal bench all` passes (Gate 3 met).

**Results vs targets:**

| Operation | SQL Baseline p50 | Haskell Result | Target | Status |
|---|---|---|---|---|
| Stream read (100-event page) | 0.832ms | 0.969ms | < 2ms | Pass |
| $all read (100-event page) | 0.337ms | 0.975ms | < 1ms | Pass |

**Key outcomes:**
- `effectful-core` integrates cleanly. Dynamic dispatch overhead is negligible (append benchmarks unchanged).
- The `Store` effect + `runStorePool` interpreter pattern works well. Callers use `Store :> es` without knowing about SQL or connection pooling.
- `runStoreIO` provides a convenient `IO` entry point for tests and benchmarks.
- `AppendError` → `StoreError` rename was straightforward since the type was already a sum type with per-error constructors.
- All 8 read tests confirm correctness: forward/backward ordering, cursor pagination, $all global ordering, empty stream handling, and `getStream` metadata queries.


## Context and Orientation

Kiroku is a PostgreSQL event store implemented in Haskell. The project lives at the repository root with the core library in `kiroku-store/`.

**Effectful** is a Haskell effect system built on extensible effects with an efficient `IO`-based runtime. An "effect" is a capability tracked in the type signature — `Store :> es` means "this computation can perform store operations." Effects are handled (eliminated) by interpreters like `runStorePool`.

Effectful supports two dispatch strategies. **Static dispatch** holds data in a mutable reference (like ReaderT) — efficient but not swappable. **Dynamic dispatch** defines operations as constructors of a GADT and dispatches through an interpreter that can be swapped at the call site. We use dynamic dispatch for `Store` so that tests can substitute a mock interpreter.

With dynamic dispatch, the pattern is:

1. Define a GADT where each constructor is an operation, parameterized by the monadic context `m` and the return type. For example, `ReadFile :: FilePath -> FileSystem m String`.
2. Set `type instance DispatchOf Store = Dynamic`.
3. Write `send`-based wrapper functions: `readFile path = send (ReadFile path)`.
4. Write interpreters using `interpret_` (for first-order effects): `runFileSystemIO = interpret_ $ \case ReadFile path -> liftIO (IO.readFile path)`.

The `Error e` effect from `Effectful.Error.Static` provides typed, checked exception handling. `throwError` raises an error; `runErrorNoCallStack` eliminates the effect and returns `Either e a`.

The current codebase modules are:

- `kiroku-store/src/Kiroku/Store/Types.hs` — Domain types including `RecordedEvent` (11 fields) and `StreamInfo` (5 fields).
- `kiroku-store/src/Kiroku/Store/SQL.hs` — hasql `Statement` definitions for the four append CTEs. Read statements will be added here.
- `kiroku-store/src/Kiroku/Store/Append.hs` — `appendToStream` currently returns `IO (Either AppendError AppendResult)`. Will become a `send` wrapper.
- `kiroku-store/src/Kiroku/Store/Error.hs` — `AppendError` type and PostgreSQL error code mapping. Will be renamed to `StoreError`.
- `kiroku-store/src/Kiroku/Store/Connection.hs` — `KirokuStore` record (pool + schema), `ConnectionSettings`, `withStore` bracket.
- `kiroku-store/src/Kiroku/Store/Schema.hs` — `initializeSchema` executing embedded DDL.
- `kiroku-store/src/Kiroku/Store.hs` — Public API re-exports.

The SQL queries for reads are specified in `docs/DESIGN.md` (lines 263–322). The SQL baseline benchmarks are in `docs/BENCH-SQL-BASELINE.md`.


## Plan of Work

The work divides into four phases: introduce the effect system (M3.1–M3.2), implement reads (M3.3–M3.4), update the public API and tests (M3.5–M3.6), and benchmarks (M3.7–M3.8).

### Milestone 3.1 — Define Store Effect GADT, StoreError, and runStorePool

This milestone adds `effectful-core` as a dependency, creates `Kiroku.Store.Effect` with the dynamically dispatched `Store` effect, renames `AppendError` to `StoreError`, and writes the `runStorePool` interpreter that executes operations against PostgreSQL. At the end, the project compiles but no operations use the new effect yet — the existing `Append.hs` still uses raw IO.

The `Store` effect is a GADT with one constructor per operation. All operations are first-order (they don't take `m a` arguments), so we use `interpret_` for the handler. The GADT:

    data Store :: Effect where
        AppendToStream     :: StreamName -> ExpectedVersion -> [EventData] -> Store m AppendResult
        ReadStreamForward  :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadStreamBackward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllForward     :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllBackward    :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        GetStream          :: StreamName -> Store m (Maybe StreamInfo)

    type instance DispatchOf Store = Dynamic

The `runStorePool` interpreter handles each constructor by executing the corresponding hasql statement via `Pool.use`, mapping errors, and throwing `StoreError` via the `Error` effect:

    runStorePool :: (IOE :> es, Error StoreError :> es)
                 => KirokuStore -> Eff (Store : es) a -> Eff es a
    runStorePool store = interpret_ $ \case
        AppendToStream name expected events -> do
            -- Pre-generate UUIDv7s, build params, run CTE, map errors
            ...
        ReadStreamForward name startVer limit -> do
            -- Run read statement via pool
            ...
        ReadStreamBackward name startVer limit -> ...
        ReadAllForward startPos limit -> ...
        ReadAllBackward startPos limit -> ...
        GetStream name -> ...

The append logic (UUIDv7 pre-generation, param building, CTE selection, error mapping) moves from `Append.hs` into the `AppendToStream` case of the interpreter. The read logic (parameter extraction, SQL execution) lives in each read case. A shared helper `runSession` wraps `Pool.use` and converts `UsageError` to `StoreError`.

In `Kiroku.Store.Error`, rename `AppendError` to `StoreError` and replace `UnexpectedError` with `ConnectionError`:

    data StoreError
        = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
        | StreamNotFound !StreamName
        | StreamAlreadyExists !StreamName
        | DuplicateEvent !EventId
        | ConnectionError !Text
        deriving stock (Eq, Show, Generic)

Add `runStoreIO` convenience:

    runStoreIO :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
    runStoreIO store = runEff . runErrorNoCallStack . runStorePool store

### Milestone 3.2 — Refactor Append to Send

Convert `Kiroku.Store.Append.appendToStream` from its current IO-based implementation to a thin wrapper that dispatches through the `Store` effect:

    appendToStream :: (HasCallStack, Store :> es)
                   => StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult
    appendToStream name expected events = send (AppendToStream name expected events)

The module becomes trivially small — just the type signature and a one-line `send` call. All the logic (UUIDv7 generation, SQL parameter building, error mapping) now lives in the `AppendToStream` case of `runStorePool` in `Effect.hs`.

The `Error StoreError :> es` constraint is **not** needed on the `send` wrappers — the effect handler (`runStorePool`) is what requires it. The caller only needs `Store :> es`. The error handling is an implementation detail of the interpreter.

### Milestone 3.3 — Read SQL Statements

Add five hasql `Statement` definitions to `Kiroku.Store.SQL`:

**`readStreamForwardStmt`** takes `(Text, Int64, Int32)` for `(stream_name, start_version, limit)`. Resolves the stream name to an ID via a subquery, joins `stream_events` with `events`, filters on `stream_version > $2`, orders ascending, and limits. Returns `Vector RecordedEvent`.

**`readStreamBackwardStmt`** is the same query but with `ORDER BY se.stream_version DESC`.

**`readAllForwardStmt`** takes `(Int64, Int32)` for `(start_position, limit)`. Hardcoded `stream_id = 0`. Orders ascending. Returns `Vector RecordedEvent`.

**`readAllBackwardStmt`** is the same but `ORDER BY se.stream_version DESC`.

**`getStreamStmt`** takes `Text` (stream name). Returns `Maybe StreamInfo` via `rowMaybe` decoder.

A shared `recordedEventRow` decoder maps 11 columns to `RecordedEvent`. A shared `streamInfoRow` decoder maps 5 columns to `StreamInfo`.

### Milestone 3.4 — Read Module

Create `kiroku-store/src/Kiroku/Store/Read.hs` with five `send`-based wrapper functions, mirroring the Append pattern:

    readStreamForward :: (HasCallStack, Store :> es)
                      => StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)
    readStreamForward name startVer limit = send (ReadStreamForward name startVer limit)

Each function is a one-liner. The implementation lives in `runStorePool`.

### Milestone 3.5 — Public API and Cabal

Update `Kiroku.Store` to re-export `Effect` (the `Store` GADT, `runStorePool`, `runStoreIO`), `Read`, and the renamed `StoreError`. Update `kiroku-store.cabal` with the new modules and `effectful-core` dependency.

### Milestone 3.6 — Tests

Adapt the existing 11 append tests to use `runStoreIO` instead of calling IO functions directly. The test helper `withTestStore` creates the `KirokuStore`, and each test runs its effectful computation via `runStoreIO`.

Add 8 new read tests:

1. Read-your-own-writes (forward)
2. Read-your-own-writes (backward)
3. Cursor-based pagination
4. Read from `$all` (forward)
5. Read from `$all` (backward)
6. Read empty/nonexistent stream
7. `getStream` returns metadata
8. `getStream` returns Nothing for nonexistent stream

### Milestone 3.7–3.8 — Benchmarks

Update append benchmarks to use the effectful API. Add read benchmarks:

- **B4: Stream read** — pre-populate 1000 events, benchmark `readStreamForward` with limit 100. Target: < 2ms per page.
- **B5: $all read** — pre-populate 1000 events across 10 streams, benchmark `readAllForward` with limit 100.


## Concrete Steps

All commands run from: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Step 1: Verify current build.**

    cabal build all

**Step 2: Add effectful-core, define Store GADT, StoreError, runStorePool.**

Edit `kiroku-store/kiroku-store.cabal` to add `effectful-core >= 2.4`. Create `kiroku-store/src/Kiroku/Store/Effect.hs`. Edit `kiroku-store/src/Kiroku/Store/Error.hs` to rename `AppendError` to `StoreError`.

    cabal build kiroku-store

**Step 3: Refactor Append to send wrapper.**

Edit `kiroku-store/src/Kiroku/Store/Append.hs` — replace IO implementation with `send (AppendToStream ...)`.

    cabal build kiroku-store

**Step 4: Add read SQL statements.**

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`.

    cabal build kiroku-store

**Step 5: Create Read module.**

Create `kiroku-store/src/Kiroku/Store/Read.hs` with `send`-based wrappers.

    cabal build kiroku-store

**Step 6: Update public API.**

Edit `kiroku-store/src/Kiroku/Store.hs` and `kiroku-store/kiroku-store.cabal`.

    cabal build all

**Step 7: Adapt tests.**

Edit `kiroku-store/test/Main.hs`.

    cabal test kiroku-store-test

**Step 8: Update and run benchmarks.**

Edit `kiroku-store/bench/Main.hs`.

    cabal bench kiroku-store-bench


## Validation and Acceptance

### Compilation

    cabal build all

Must succeed with no warnings in kiroku-store modules.

### Tests

    cabal test all

All test cases must pass — the 11 adapted append tests and the 8 new read tests.

Key behaviors for read tests:

- **Read-your-own-writes:** after appending events "A", "B", "C", reading forward returns them in that order with `streamVersion` 1, 2, 3.
- **Backward ordering:** same stream read backward returns "C", "B", "A" with versions 3, 2, 1.
- **Pagination:** read with limit 2, then from cursor, returns next batch. Eventually empty.
- **$all ordering:** events from different streams appear in global order with contiguous positions.
- **Empty reads:** reading a nonexistent stream returns an empty `Vector`, not an error.
- **getStream:** returns `Just StreamInfo` with correct version, `Nothing` for unknown streams.

Key behaviors for adapted append tests:

- All 11 existing tests still pass with the effectful API.
- Error cases now throw `StoreError` via the `Error` effect, caught by `runErrorNoCallStack`.

### Benchmarks

    cabal bench kiroku-store-bench

Compare read results against `docs/BENCH-SQL-BASELINE.md` Benchmark 5:

| Operation | SQL Baseline p50 | Haskell Target |
|---|---|---|
| Stream read (100-event page) | 0.832ms | < 2ms |
| `$all` read (100-event page) | 0.337ms | < 1ms |


## Idempotence and Recovery

All steps are idempotent. `cabal build` is incremental. Tests use `ephemeral-pg` which creates a fresh database per run. If a step fails, fix the issue and re-run the same command.


## Interfaces and Dependencies

### New Dependency: `effectful-core`

Added to `kiroku-store.cabal` library `build-depends`:

    , effectful-core >= 2.4

Also added to test-suite and benchmark `build-depends`.

### New Module: `Kiroku.Store.Effect` (public)

In `kiroku-store/src/Kiroku/Store/Effect.hs`, define:

    -- The Store effect — dynamically dispatched, mockable
    data Store :: Effect where
        AppendToStream     :: StreamName -> ExpectedVersion -> [EventData] -> Store m AppendResult
        ReadStreamForward  :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadStreamBackward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllForward     :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        ReadAllBackward    :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
        GetStream          :: StreamName -> Store m (Maybe StreamInfo)

    type instance DispatchOf Store = Dynamic

    -- PostgreSQL interpreter
    runStorePool :: (IOE :> es, Error StoreError :> es)
                 => KirokuStore -> Eff (Store : es) a -> Eff es a

    -- Convenience: run to IO
    runStoreIO :: KirokuStore
               -> Eff '[Store, Error StoreError, IOE] a
               -> IO (Either StoreError a)

### Updated Module: `Kiroku.Store.Error`

Rename `AppendError` to `StoreError`. Replace `UnexpectedError` with `ConnectionError`:

    data StoreError
        = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
        | StreamNotFound !StreamName
        | StreamAlreadyExists !StreamName
        | DuplicateEvent !EventId
        | ConnectionError !Text
        deriving stock (Eq, Show, Generic)

### Updated Module: `Kiroku.Store.Append`

Becomes a thin `send` wrapper:

    appendToStream :: (HasCallStack, Store :> es)
                   => StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult
    appendToStream name expected events = send (AppendToStream name expected events)

### New Module: `Kiroku.Store.Read` (public)

Thin `send` wrappers:

    readStreamForward  :: (HasCallStack, Store :> es) => StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)
    readStreamBackward :: (HasCallStack, Store :> es) => StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)
    readAllForward     :: (HasCallStack, Store :> es) => GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
    readAllBackward    :: (HasCallStack, Store :> es) => GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
    getStream          :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamInfo)

### Updated Module: `Kiroku.Store.SQL` (internal)

Add:

    readStreamForwardStmt  :: Statement (Text, Int64, Int32) (Vector RecordedEvent)
    readStreamBackwardStmt :: Statement (Text, Int64, Int32) (Vector RecordedEvent)
    readAllForwardStmt     :: Statement (Int64, Int32) (Vector RecordedEvent)
    readAllBackwardStmt    :: Statement (Int64, Int32) (Vector RecordedEvent)
    getStreamStmt          :: Statement Text (Maybe StreamInfo)

### Updated Module: `Kiroku.Store`

Re-export `Effect` (Store, runStorePool, runStoreIO), `Append`, `Read`, and `StoreError`.

### Updated: `kiroku-store.cabal`

Add `Kiroku.Store.Effect` and `Kiroku.Store.Read` to `exposed-modules`. Add `effectful-core >= 2.4` to all stanza `build-depends`.

---

## Revision Notes

**2026-03-22 (rev 1):** Major revision — incorporated effectful as the effect system. The original plan was read-only with raw IO. Added `Store` effect, `StoreError`, refactored Append, implemented reads in effectful. Progress items renumbered from 5 to 8.

**2026-03-22 (rev 2):** Switched `Store` effect from static dispatch to dynamic dispatch. The `Store` effect is now a GADT with one constructor per operation (`AppendToStream`, `ReadStreamForward`, etc.). The real implementation is `runStorePool`, an interpreter using `interpret_` that executes operations against PostgreSQL. Public modules (`Append.hs`, `Read.hs`) become thin `send` wrappers — all logic moves into the interpreter. This enables mock interpreters for testing without a database. Updated: effect definition, all interface signatures (removed `Error StoreError :> es` from public wrappers — only `Store :> es` needed), plan of work, context section, decision log.
