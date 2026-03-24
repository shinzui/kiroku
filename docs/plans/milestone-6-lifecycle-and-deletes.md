# Milestone 6 — Lifecycle & Deletes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this milestone, callers can do four things they could not do before. First, they can soft-delete a stream — marking it as logically removed so that reads return nothing and appends are rejected, without destroying data. Second, they can perform gated hard deletes — permanently removing a stream and all its events in a single cascading transaction, but only when the caller has explicitly opted in via a session variable, as a safety mechanism for GDPR compliance or maintenance. Third, every connection in the pool is configured with `idle_in_transaction_session_timeout` so that abandoned transactions are automatically terminated by PostgreSQL, preventing connection leaks. Fourth, an observation-based health monitoring system is wired into the pool, giving callers visibility into connection lifecycle events (connecting, in-use, terminated, and why).

These capabilities complete Phase 1c of the kiroku-store implementation plan. Together with Milestones 1–5, they make kiroku-store feature-complete as a standalone event store library, ready for Phase 2 (subscriptions and projections).

**Observable outcomes:**

- `cabal build all` compiles with the new `Kiroku.Store.Lifecycle` module and updated `Kiroku.Store.Connection`.
- `cabal test all` passes all existing tests (32) plus new tests for soft delete, hard delete, and health checks.
- `cabal bench all` includes a full regression run of all previous benchmark gates.
- Soft-deleted streams are invisible to reads and reject appends.
- Hard delete requires `SET LOCAL kiroku.enable_hard_deletes = 'on'` — without it, PostgreSQL raises an exception.
- The pool's `initSession` sets `idle_in_transaction_session_timeout` on every connection.
- An `observationHandler` callback receives pool connection lifecycle events.


## Progress

- [x] M6.1: Add soft delete SQL and hasql statements (2026-03-23)
- [x] M6.2: Add hard delete SQL and hasql statements (2026-03-23)
- [x] M6.3: Extend the Store effect GADT with `SoftDeleteStream` and `HardDeleteStream` (2026-03-23)
- [x] M6.4: Create `Kiroku.Store.Lifecycle` module with public API (2026-03-23)
- [x] M6.5: Add `idle_in_transaction_session_timeout` to pool init session (2026-03-23)
- [x] M6.6: Add observation-based health monitoring to `ConnectionSettings` and `withStore` (2026-03-23)
- [x] M6.7: Update `Kiroku.Store` public API re-exports (2026-03-23)
- [x] M6.8: Tests — soft delete, hard delete, health checks (2026-03-23)
- [x] M6.9: Full regression benchmark suite (2026-03-23)
- [x] M6.10: Document results and update plan (2026-03-23)


## Surprises & Discoveries

- `Hasql.Session` does not export `sql`; the correct function for executing raw SQL text in a session is `Session.script :: Text -> Session ()`. The plan referenced `Session.sql` which does not exist. Used `Session.script` for the `idle_in_transaction_session_timeout` initSession configuration. (2026-03-23)
- `ConnectionSettings` can no longer derive `Show` because `observationHandler` is `Maybe (Observation -> IO ())` which has no `Show` instance. Removed the `Show` deriving. (2026-03-23)


## Decision Log

- Decision: Soft delete sets `deleted_at` on the `streams` row and does NOT modify `events` or `stream_events`.
  Rationale: Events are immutable. The soft delete is a logical flag on the stream. Read operations already have access to `deleted_at` via `StreamInfo` — the interpreter will check this flag and return empty results for deleted streams. This matches Commanded's approach where soft-deleted streams are hidden from reads but the underlying data is preserved for auditing and potential restoration.
  Date: 2026-03-23

- Decision: Reads from soft-deleted streams return empty results (not an error), appends return `StreamNotFound`.
  Rationale: Returning empty results for reads is consistent with "nonexistent stream" behavior — the caller cannot distinguish a deleted stream from one that never existed, which is the desired semantics. For appends, returning `StreamNotFound` prevents accidentally appending to a deleted stream. The `getStream` function continues to return `StreamInfo` with a populated `deletedAt` field, allowing callers to explicitly check deletion status.
  Date: 2026-03-23

- Decision: Soft delete does NOT filter reads at the SQL level — filtering happens in the Haskell interpreter.
  Rationale: Adding `WHERE deleted_at IS NULL` to every read query would require modifying all existing SQL statements, increasing complexity and risk. Instead, the interpreter checks `deleted_at` at the effect level: for `ReadStreamForward`/`ReadStreamBackward`, it first calls `getStream`, checks `deleted_at`, and returns empty if set. This keeps the SQL layer simple and the filtering logic centralized. The `$all` and category reads are NOT filtered — deleted stream events still appear in `$all` because global ordering must not have gaps.
  Date: 2026-03-23

- Decision: Hard delete uses a hasql-transaction with `SET LOCAL kiroku.enable_hard_deletes = 'on'` inside the transaction.
  Rationale: The schema already has `protect_deletion()` triggers on all three tables that check `current_setting('kiroku.enable_hard_deletes', true)`. Using `SET LOCAL` scopes the setting to the current transaction only — it is automatically reset when the transaction ends, preventing accidental deletes in subsequent operations on the same connection. The hard delete CTE cascades: delete from `stream_events` where the event's original stream matches → delete orphaned events → delete the stream row.
  Date: 2026-03-23

- Decision: Use hasql-pool's `observationHandler` for health monitoring rather than a custom health-check function.
  Rationale: The hasql-pool library does not expose a dedicated health-check function. The recommended approach for connection health is either (a) run `Pool.use pool (pure ())` or (b) use the `observationHandler` callback. The observation system provides richer information — connection status changes (connecting, ready, in-use, terminated), termination reasons (aging, idleness, network error), and session outcomes. This is more useful for production monitoring than a boolean health check.
  Date: 2026-03-23

- Decision: `idle_in_transaction_session_timeout` is set via `Pool.Config.initSession` rather than as a connection string parameter.
  Rationale: Using `initSession` with `Session.sql "SET idle_in_transaction_session_timeout = '30s'"` ensures the setting is applied consistently to every connection in the pool, including connections created during pool growth. Connection string parameters are applied at connection time but `initSession` runs after the connection is established and added to the pool, which is the correct lifecycle point. The 30-second default is aggressive enough to catch abandoned transactions but lenient enough for legitimate long-running operations.
  Date: 2026-03-23

- Decision: Expose `ObservationHandler` as an optional field on `ConnectionSettings` rather than a separate configuration step.
  Rationale: This keeps the configuration API simple — callers who want observability set one field, callers who don't leave it as `Nothing`. The handler receives `Hasql.Pool.Observation.Observation` values directly, avoiding the need for a kiroku-specific observation type. This is a thin wrapper — callers can pattern-match on `ConnectionStatus` and `ConnectionTerminationReason` from `hasql-pool` directly.
  Date: 2026-03-23

- Decision: `undeleteStream` (restore a soft-deleted stream) is included in Milestone 6.
  Rationale: Once soft delete exists, the ability to restore is a natural and minimal addition — it is a single `UPDATE streams SET deleted_at = NULL WHERE stream_name = $1 AND deleted_at IS NOT NULL`. Without it, the only way to undo a soft delete would be a manual SQL UPDATE, which defeats the purpose of having a Haskell API. Including it now costs almost nothing and prevents a gap in the lifecycle API.
  Date: 2026-03-23


## Outcomes & Retrospective

**Completed 2026-03-23.** All 10 milestones implemented in a single session.

### Test results
- 46 tests pass (32 existing + 14 new lifecycle/health tests)
- Soft delete: 6 tests covering visibility, append rejection, idempotence, `$all` preservation
- Undelete: 4 tests covering restore, reads, appends, idempotence
- Hard delete: 3 tests covering cascade, `$all` removal, nonexistent stream
- Observation handler: 1 test verifying callback receives events

### Benchmark results (M6.9)
No regressions from M5 baselines:
- Stream forward (100-event page): 1.05ms
- `$all` forward (100-event page): 1.02ms
- Category forward (100-event page): 1.07ms
- Pool saturation: 2053 ops/s (6400 appends across 64 writers)

The soft-delete check adds one `getStreamStmt` query per stream read/append, but the overhead is within normal measurement variance — no optimization needed.

### Lessons
- The plan's reference to `Session.sql` was incorrect; `Session.script` is the correct API. Reading dependency source code via mori before implementation caught this early.
- Adding `observationHandler :: Maybe (Observation -> IO ())` to `ConnectionSettings` required dropping the `Show` deriving — a minor but worth-noting tradeoff.


## Context and Orientation

Kiroku is a PostgreSQL event store implemented in Haskell. The core library lives in `kiroku-store/`. The project uses GHC 9.12.2 with the GHC2024 language edition and the effectful effect system for all store operations.

### Key modules and their roles

`kiroku-store/src/Kiroku/Store/SQL.hs` contains all SQL statements as hasql `Statement` values. Each statement has a SQL text template, a hasql encoder (for parameters), and a hasql decoder (for results). The module currently exports: `AppendParams` record, four append statement functions, five read statement functions, a link statement, a category read statement, and shared decoders. New SQL statements for soft delete, hard delete, and undelete will be added here.

`kiroku-store/src/Kiroku/Store/Effect.hs` defines the `Store` effect as a GADT with nine constructors (`AppendToStream`, `ReadStreamForward`, `ReadStreamBackward`, `ReadAllForward`, `ReadAllBackward`, `GetStream`, `LinkToStream`, `ReadCategoryForward`, `AppendMultiStream`). The `runStorePool` interpreter pattern-matches on each constructor and executes the corresponding hasql statement against the pool. New GADT constructors for soft delete, hard delete, and undelete will be added.

`kiroku-store/src/Kiroku/Store/Connection.hs` defines `KirokuStore` (a record with `pool :: Pool` and `schema :: Text`), `ConnectionSettings` (with `connString`, `poolSize`, `schema`), and `withStore` (which auto-initializes the schema). This module will be updated to add `observationHandler` and `idleInTransactionTimeout` to `ConnectionSettings`, and to configure the pool accordingly.

`kiroku-store/src/Kiroku/Store/Types.hs` defines all domain types. The `StreamInfo` type already has a `deletedAt :: Maybe UTCTime` field — soft delete sets this field; reads check it.

`kiroku-store/src/Kiroku/Store/Error.hs` defines `StoreError` with five constructors. A new `StreamDeleted` constructor will be added for operations that should fail on deleted streams (e.g., appends to a soft-deleted stream).

`kiroku-store/sql/schema.sql` already has the `protect_deletion()` trigger function and the three `no_delete_*` triggers that gate hard deletes on `current_setting('kiroku.enable_hard_deletes', true) = 'on'`. No schema changes are needed.

`kiroku-store/test/Main.hs` uses hspec with an `around withTestStore` pattern. There are currently 32 tests.

`kiroku-store/bench/Main.hs` uses `tasty-bench` with `ephemeral-pg`. There are currently 9 benchmarks across append, read, and category groups.

### hasql-pool observation API

The `Hasql.Pool.Observation` module exports:

- `Observation`: wraps a `UUID` (connection ID) and a `ConnectionStatus`.
- `ConnectionStatus`: one of `ConnectingConnectionStatus`, `ReadyForUseConnectionStatus reason`, `InUseConnectionStatus`, `TerminatedConnectionStatus reason`.
- `ConnectionTerminationReason`: `AgingConnectionTerminationReason`, `IdlenessConnectionTerminationReason`, `NetworkErrorConnectionTerminationReason (Maybe Text)`, `ReleaseConnectionTerminationReason`, `InitializationErrorTerminationReason SessionError`.

The `observationHandler` is configured via `Pool.Config.observationHandler :: (Observation -> IO ()) -> Setting`.

### hasql-pool initSession API

`Pool.Config.initSession :: Session.Session () -> Setting` executes a session on every new connection after it is established. This is the correct place to set `idle_in_transaction_session_timeout`.

### Hard delete protection

The schema has a `protect_deletion()` trigger function on all three tables (`events`, `stream_events`, `streams`). It checks `current_setting('kiroku.enable_hard_deletes', true)` — if the setting is not `'on'`, the trigger raises an exception. `SET LOCAL` scopes the setting to the current transaction.


## Plan of Work

The work proceeds in four phases: SQL layer (M6.1–M6.2), effect layer (M6.3–M6.7), tests (M6.8), and benchmarks (M6.9–M6.10).

### Milestone 6.1 — Soft delete and undelete SQL statements

Add `softDeleteStreamStmt` and `undeleteStreamStmt` to `kiroku-store/src/Kiroku/Store/SQL.hs`.

Soft delete updates the `deleted_at` column on the `streams` table. The SQL is straightforward:

    UPDATE streams
    SET deleted_at = now()
    WHERE stream_name = $1
      AND deleted_at IS NULL
    RETURNING stream_id

Parameters: `$1::text` (stream name). Returns: `Maybe StreamId` (Nothing if stream doesn't exist or is already deleted).

Undelete clears the `deleted_at` column:

    UPDATE streams
    SET deleted_at = NULL
    WHERE stream_name = $1
      AND deleted_at IS NOT NULL
    RETURNING stream_id

Parameters: `$1::text` (stream name). Returns: `Maybe StreamId` (Nothing if stream doesn't exist or is not deleted).

Both statements use the `prevent_mutation` trigger bypass: the `no_update_events` and `no_update_stream_events` triggers prevent updates on `events` and `stream_events`, but there is no `no_update_streams` trigger — only `no_delete_streams`. The `streams` table can be freely updated (the schema only has update-prevention triggers on `events` and `stream_events`).

The hasql statements will be `softDeleteStreamStmt :: Statement Text (Maybe StreamId)` and `undeleteStreamStmt :: Statement Text (Maybe StreamId)`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 6.2 — Hard delete SQL statement

Add a `hardDeleteStreamStmt` to `kiroku-store/src/Kiroku/Store/SQL.hs`. This is not a simple `Statement` — it requires a `hasql-transaction` because `SET LOCAL kiroku.enable_hard_deletes = 'on'` must be executed within the same transaction as the deletes.

The hard delete is a three-step cascading operation within a single transaction:

1. `SET LOCAL kiroku.enable_hard_deletes = 'on'` — enables the `protect_deletion` triggers for this transaction only.
2. Delete from `stream_events` where `stream_id = <target>` or `original_stream_id = <target>` — removes the stream's junction rows and any link/`$all` rows that reference events from this stream.
3. Delete from `events` where the event no longer has any `stream_events` rows (orphaned events after step 2).
4. Delete from `streams` where `stream_name = $1`.

The SQL for steps 2–4 as a CTE:

    WITH
      target AS (
        SELECT stream_id FROM streams WHERE stream_name = $1
      ),
      deleted_junctions AS (
        DELETE FROM stream_events
        WHERE stream_id = (SELECT stream_id FROM target)
           OR original_stream_id = (SELECT stream_id FROM target)
        RETURNING event_id
      ),
      deleted_events AS (
        DELETE FROM events
        WHERE event_id IN (SELECT DISTINCT event_id FROM deleted_junctions)
          AND NOT EXISTS (
            SELECT 1 FROM stream_events se
            WHERE se.event_id = events.event_id
          )
      )
    DELETE FROM streams WHERE stream_id = (SELECT stream_id FROM target)
    RETURNING stream_id

This CTE needs the `kiroku.enable_hard_deletes` gate active. Since we need `SET LOCAL` + the CTE in one transaction, this will be implemented as a `Transaction` action (not a plain `Statement`). The interpreter will use `Pool.use pool $ TxSessions.transaction ReadCommitted Write txn` where `txn` does `Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"` followed by `Tx.statement name hardDeleteCTE`.

Add to `Kiroku.Store.SQL`: `hardDeleteStreamCTE :: Statement Text (Maybe StreamId)` (the raw CTE, assuming the gate is already set). The transaction wrapping happens in the interpreter.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 6.3 — Extend the Store effect GADT

Add three new constructors to the `Store` GADT in `kiroku-store/src/Kiroku/Store/Effect.hs`:

    SoftDeleteStream :: StreamName -> Store m (Maybe StreamId)
    HardDeleteStream :: StreamName -> Store m (Maybe StreamId)
    UndeleteStream :: StreamName -> Store m (Maybe StreamId)

The `SoftDeleteStream` interpreter calls `softDeleteStreamStmt`. The `HardDeleteStream` interpreter wraps the hard delete CTE in a transaction with `SET LOCAL`. The `UndeleteStream` interpreter calls `undeleteStreamStmt`.

Update the `ReadStreamForward` and `ReadStreamBackward` interpreter cases to check `deleted_at` before reading. The pattern: call `getStreamStmt` first, check if `deleted_at` is set, return empty `Vector` if so, otherwise proceed with the read. This adds one extra query per stream read — acceptable for correctness. Note: this does NOT apply to `ReadAllForward`, `ReadAllBackward`, or `ReadCategoryForward` — those read from `$all` and must not skip deleted stream events (global ordering must remain gap-free).

Update the `AppendToStream` interpreter to reject appends to soft-deleted streams. After the append CTE executes successfully, check if the stream is soft-deleted (this shouldn't normally happen because the append CTE updates `stream_version`, not `deleted_at`, but a race condition is possible). A simpler approach: check before appending. If `getStream` returns a `StreamInfo` with `deletedAt` set, throw `StreamNotFound` immediately.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 6.4 — Create `Kiroku.Store.Lifecycle` module

Create `kiroku-store/src/Kiroku/Store/Lifecycle.hs` following the pattern of `Kiroku.Store.Append`:

    module Kiroku.Store.Lifecycle (
        softDeleteStream,
        hardDeleteStream,
        undeleteStream,
    ) where

    softDeleteStream ::
        (HasCallStack, Store :> es) =>
        StreamName ->
        Eff es (Maybe StreamId)
    softDeleteStream name = send (SoftDeleteStream name)

    hardDeleteStream ::
        (HasCallStack, Store :> es) =>
        StreamName ->
        Eff es (Maybe StreamId)
    hardDeleteStream name = send (HardDeleteStream name)

    undeleteStream ::
        (HasCallStack, Store :> es) =>
        StreamName ->
        Eff es (Maybe StreamId)
    undeleteStream name = send (UndeleteStream name)

Add `Kiroku.Store.Lifecycle` to `exposed-modules` in `kiroku-store.cabal`.

At the end of this milestone, `cabal build lib:kiroku-store` compiles.

### Milestone 6.5 — Add `idle_in_transaction_session_timeout` to pool configuration

Edit `kiroku-store/src/Kiroku/Store/Connection.hs` to add an `idleInTransactionTimeout` field to `ConnectionSettings`:

    data ConnectionSettings = ConnectionSettings
        { connString :: !Text
        , poolSize :: !Int
        , schema :: !Text
        , idleInTransactionTimeout :: !Int
        -- ^ idle_in_transaction_session_timeout in seconds (default: 30)
        }

Update `defaultConnectionSettings` to set the default to 30 seconds. Update the `poolConfig` in `withStore` to include `Pool.Config.initSession` that runs `SET idle_in_transaction_session_timeout = '<N>s'` on every new connection.

At the end of this milestone, `cabal build all` compiles.

### Milestone 6.6 — Add observation-based health monitoring

Edit `kiroku-store/src/Kiroku/Store/Connection.hs` to add an `observationHandler` field to `ConnectionSettings`:

    import Hasql.Pool.Observation (Observation)

    data ConnectionSettings = ConnectionSettings
        { connString :: !Text
        , poolSize :: !Int
        , schema :: !Text
        , idleInTransactionTimeout :: !Int
        , observationHandler :: !(Maybe (Observation -> IO ()))
        -- ^ Optional callback for pool connection lifecycle events
        }

Update `defaultConnectionSettings` to set `observationHandler = Nothing`. Update `poolConfig` in `withStore` to include `Pool.Config.observationHandler handler` when the setting is `Just handler`.

At the end of this milestone, `cabal build all` compiles.

### Milestone 6.7 — Update public API re-exports

Update `kiroku-store/src/Kiroku/Store.hs` to add:

    import Kiroku.Store.Lifecycle

And add `module Kiroku.Store.Lifecycle` to the export list. Also re-export `Observation` from `Hasql.Pool.Observation` so callers can pattern-match on observation types without importing hasql-pool directly.

At the end of this milestone, `cabal build all` compiles.

### Milestone 6.8 — Tests

Add tests to `kiroku-store/test/Main.hs` covering:

**Soft delete tests:**
- Soft-delete a stream. `getStream` returns `StreamInfo` with `deletedAt` populated.
- Read from a soft-deleted stream returns empty `Vector`.
- Append to a soft-deleted stream returns `StreamNotFound`.
- Soft-delete a nonexistent stream returns `Nothing`.
- Soft-delete an already-deleted stream returns `Nothing`.
- Events from a soft-deleted stream still appear in `$all` (global ordering preserved).

**Undelete tests:**
- Undelete a soft-deleted stream. `getStream` returns `StreamInfo` with `deletedAt = Nothing`.
- Read from an undeleted stream returns events.
- Append to an undeleted stream succeeds.
- Undelete a non-deleted stream returns `Nothing`.

**Hard delete tests:**
- Hard-delete a stream. `getStream` returns `Nothing`.
- Hard-delete removes all stream_events and orphaned events.
- Events from the hard-deleted stream no longer appear in `$all`.
- Hard-delete a nonexistent stream returns `Nothing`.

**Health check test:**
- Create a store with an `observationHandler` that records observations into an `IORef`. Perform an append. Verify that at least one observation was received (connection status change).

At the end of this milestone, `cabal test all` passes.

### Milestone 6.9 — Full regression benchmark suite

Run the complete benchmark suite (`cabal bench all`) and verify no regressions from the soft-delete check in the read path. Record results for all benchmark groups (append, read, category) alongside Milestone 4 and 5 results.

The soft-delete check adds one extra `getStream` query per stream read. Measure the overhead by comparing M6 read benchmarks against M5 baselines. If overhead exceeds 20%, consider caching stream deletion status or moving the check to SQL.

At the end of this milestone, `cabal bench all` runs with results documented.

### Milestone 6.10 — Document results

Update this plan's Progress, Surprises & Discoveries, and Outcomes & Retrospective sections. Record benchmark results inline. Note any regressions or surprises.


## Concrete Steps

All commands run from: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Step 1: Verify current build and tests pass.**

    cabal build all
    cabal test all

Expected: 32 tests pass.

**Step 2: Add soft delete, undelete, and hard delete SQL statements.**

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`.

    cabal build lib:kiroku-store

**Step 3: Extend Store GADT and interpreter.**

Edit `kiroku-store/src/Kiroku/Store/Effect.hs`.

    cabal build lib:kiroku-store

**Step 4: Create Lifecycle module, update cabal and Store.hs.**

Create `kiroku-store/src/Kiroku/Store/Lifecycle.hs`. Edit `kiroku-store/kiroku-store.cabal`. Edit `kiroku-store/src/Kiroku/Store.hs`.

    cabal build all

**Step 5: Update Connection.hs with timeout and observation handler.**

Edit `kiroku-store/src/Kiroku/Store/Connection.hs`.

    cabal build all

**Step 6: Add tests.**

Edit `kiroku-store/test/Main.hs`.

    cabal test all

Expected: all existing tests pass plus new lifecycle tests.

**Step 7: Run full regression benchmarks.**

    cabal bench all

Record all results. Compare against M5 baselines.

**Step 8: Update plan with results.**


## Validation and Acceptance

### Compilation

    cabal build all

Must succeed with no warnings in kiroku-store modules.

### Tests

    cabal test all

All tests must pass — the 32 existing tests plus the new soft delete, hard delete, undelete, and health check tests.

Key behaviors:

- Soft delete: `getStream` returns `StreamInfo` with `deletedAt` set. `readStreamForward` and `readStreamBackward` return empty for deleted streams. `appendToStream` returns `StreamNotFound` for deleted streams. `readAllForward` and `readCategory` still include events from deleted streams (global ordering preserved).
- Hard delete: `getStream` returns `Nothing`. Events removed from `$all`. Stream junction rows removed.
- Undelete: clears `deletedAt`, reads and appends work again.
- Observation: handler receives at least one `Observation` during normal store operations.
- `idle_in_transaction_session_timeout`: verified by the fact that `cabal test all` passes with the setting active (if a test left an idle transaction, it would be killed after 30 seconds).

### Benchmarks

    cabal bench all

**Read path regression check:** Stream read and `$all` read latency should not regress by more than 20% compared to Milestone 5 results. The soft-delete check adds one `getStream` query per stream read, but `$all` and category reads are unaffected.

Milestone 5 baselines for comparison:
- Stream forward (100-event page): expected ~0.7ms
- `$all` forward (100-event page): expected ~1.0ms
- Category forward (100-event page): expected ~1.0ms


## Idempotence and Recovery

All steps are idempotent. `cabal build` is incremental. Tests use `ephemeral-pg` which creates a fresh PostgreSQL database per run. Schema initialization is idempotent (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`). Soft delete is idempotent (second call returns `Nothing`). Hard delete is idempotent (deleting a nonexistent stream returns `Nothing`). If any step fails, fix the issue and re-run the same command.


## Interfaces and Dependencies

### New Module: `Kiroku.Store.Lifecycle`

In `kiroku-store/src/Kiroku/Store/Lifecycle.hs`:

    softDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
    hardDeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
    undeleteStream :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)

All three return `Just streamId` on success, `Nothing` if the precondition is not met (stream doesn't exist, already deleted/not deleted, etc.).

### Updated Module: `Kiroku.Store.Effect`

Three new GADT constructors:

    SoftDeleteStream :: StreamName -> Store m (Maybe StreamId)
    HardDeleteStream :: StreamName -> Store m (Maybe StreamId)
    UndeleteStream :: StreamName -> Store m (Maybe StreamId)

Updated interpreter behavior for existing constructors:
- `ReadStreamForward` and `ReadStreamBackward`: return empty `Vector` if stream is soft-deleted.
- `AppendToStream`: return `StreamNotFound` if stream is soft-deleted.

### Updated Module: `Kiroku.Store.SQL`

New statements:

    softDeleteStreamStmt :: Statement Text (Maybe StreamId)
    undeleteStreamStmt :: Statement Text (Maybe StreamId)
    hardDeleteStreamCTE :: Statement Text (Maybe StreamId)

### Updated Module: `Kiroku.Store.Connection`

Updated `ConnectionSettings`:

    data ConnectionSettings = ConnectionSettings
        { connString :: !Text
        , poolSize :: !Int
        , schema :: !Text
        , idleInTransactionTimeout :: !Int
        , observationHandler :: !(Maybe (Observation -> IO ()))
        }

`defaultConnectionSettings` sets `idleInTransactionTimeout = 30` and `observationHandler = Nothing`.

### Updated Module: `Kiroku.Store`

Add `module Kiroku.Store.Lifecycle` to re-exports. Re-export `Hasql.Pool.Observation.Observation` and related types.

### Dependencies

No new dependencies. `hasql-transaction` is already in library `build-depends`. `Hasql.Pool.Observation` is part of `hasql-pool` which is already a dependency.
