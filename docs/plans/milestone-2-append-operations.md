# Milestone 2 — Append Operations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this milestone, kiroku-store can **append events to streams** — the foundational write
path of the event store. A caller can:

1. Create a new stream and append events (`NoStream` expectation)
2. Append to an existing stream with optimistic concurrency (`ExactVersion`)
3. Append to an existing stream at any version (`StreamExists`)
4. Append-or-create without caring about stream existence (`AnyVersion`)

Each append is a single SQL round-trip using a CTE that atomically updates the source stream
version, inserts events, links them to both the source stream and `$all`, and claims contiguous
global positions.

**Observable outcomes:**
- `cabal build all` compiles with all new modules
- `cabal test all` passes integration tests for all four append variants and error cases
- The Haskell append overhead vs the SQL baseline (Track 1) is measurable via `cabal bench all`


## Progress

- [x] M2.1: Add `mmzk-typeid` dependency for UUIDv7 generation (2026-03-22)
- [x] M2.2: Implement `Kiroku.Store.Schema.initializeSchema` (execute DDL) (2026-03-22)
- [x] M2.3: Implement `Kiroku.Store.SQL` — hasql statements for all 4 append CTE variants (2026-03-22)
- [x] M2.4: Implement `Kiroku.Store.Append` — public append functions (2026-03-22)
- [x] M2.5: Implement PostgreSQL error code mapping in `Kiroku.Store.Error` (2026-03-22)
- [x] M2.6: Update `Kiroku.Store` re-exports to include `Append` and `Schema` (2026-03-22)
- [x] M2.7: Update `kiroku-store.cabal` with new modules and dependencies (2026-03-22)
- [x] M2.8: Integration tests for all append variants and error paths (2026-03-22)
- [ ] M2.9: Benchmark gate — append throughput vs SQL baseline


## Surprises & Discoveries

- `OverloadedRecordDot` is NOT included in GHC2024 by default. Field access via `.field`
  in lambdas requires an explicit `{-# LANGUAGE OverloadedRecordDot #-}` pragma. Without it,
  `p.fieldName` is parsed as function composition `p . fieldName`. Added pragma to SQL.hs and
  Append.hs. (2026-03-22)

- `DuplicateRecordFields` causes ambiguous field selector errors when using `.fieldName` in
  contexts where multiple records in scope have the same field name. Fixed by using pattern
  matching for `EventData` (which shares field names with `RecordedEvent`) and prefixed field
  names (`pe*`) for the internal `PreparedEvent` type. (2026-03-22)

- `Hasql.Statement` exports `preparable` and `unpreparable` smart constructors, not the
  `Statement` data constructor directly. The constructor exists but should not be used —
  use `preparable sql encoder decoder` instead. (2026-03-22)

- `file-embed` added as dependency for embedding `schema.sql` at compile time. Simpler and
  more reliable than Haskell string literals for 132 lines of SQL. (2026-03-22)

- `contravariant-extras` turned out to be unnecessary. The `Contravariant` `(>$<)` operator
  plus `Monoid` `(<>)` on `Params` is sufficient for composing record field encoders:
  `(\p -> p.field) >$< param (nonNullable encoder)`. (2026-03-22)

- **AnyVersion CTE required a different approach than planned.** The plan called for
  `INSERT ... ON CONFLICT DO NOTHING` followed by `UPDATE` in a separate CTE step. This fails
  because data-modifying CTEs cannot see each other's changes (PostgreSQL documentation:
  "sub-statements in WITH are executed concurrently with each other and with the main query").
  Fixed by using `INSERT ... ON CONFLICT DO UPDATE` (upsert) that atomically creates or bumps
  the stream version in a single step. (2026-03-22)

- **PostgreSQL unique_violation error mapping.** The constraint name appears in the `message`
  field ("duplicate key value violates unique constraint \"events_pkey\""), not in the `detail`
  field. The `detail` field contains the key value ("Key (event_id)=(uuid) already exists.").
  Updated error mapping to check both fields. (2026-03-22)

- **hasql-pool requires `-threaded` runtime.** The pool uses `registerDelay` from GHC.Conc
  which requires the threaded RTS. Added `ghc-options: -threaded -rtsopts -with-rtsopts=-N`
  to the test-suite stanza. (2026-03-22)


## Decision Log

- Decision: Use `mmzk-typeid` (`Data.UUID.V7`) for client-side UUIDv7 generation instead of
  rolling our own.
  Rationale: Already registered in mori, provides monotonic `genUUIDs` that generates batches
  at the same timestamp with incrementing sequence numbers — exactly what we need for batch
  appends. The `uuid` package (already a dependency) does not have V7 support.
  Date: 2026-03-22

- Decision: Use manual hasql encoders/decoders (not `hasql-th` quasi-quotes) for the CTE
  statements.
  Rationale: The CTEs are complex multi-step statements with `unnest` over parallel arrays.
  `hasql-th` compile-time checking may reject them or require workarounds. Manual
  encoders give full control over parameter marshaling. This matches the risk register item
  in IMPLEMENTATION.md. Can revisit for simpler statements later.
  Date: 2026-03-22

- Decision: Use `Hasql.Session.statement` directly (not `hasql-transaction`) for append
  operations.
  Rationale: Each append CTE is a single statement that runs atomically — PostgreSQL wraps
  it in an implicit transaction. No need for explicit `BEGIN`/`COMMIT`. The CTE's internal
  gating (`EXISTS (SELECT 1 FROM stream_update)`) handles concurrency. Using
  `hasql-transaction` would add unnecessary overhead and complexity. Multi-statement
  transactions are deferred to Milestone 5 (multi-stream appends).
  Date: 2026-03-22

- Decision: `append_any_version` uses an `INSERT ... ON CONFLICT` to upsert the stream,
  followed by a separate `UPDATE` for the version bump, all within the same CTE.
  Rationale: A single `UPDATE ... WHERE stream_name = $8` returns 0 rows for a new stream.
  We need `INSERT ... ON CONFLICT DO NOTHING` first to ensure the stream exists, then
  `UPDATE ... RETURNING` to claim versions. This matches DESIGN.md's description.
  Date: 2026-03-22

- Decision: Change AnyVersion CTE from INSERT + UPDATE to INSERT ON CONFLICT DO UPDATE (upsert).
  Rationale: Data-modifying CTEs execute concurrently and cannot see each other's changes.
  The INSERT in `stream_ensure` was invisible to the UPDATE in `stream_update`. A single
  upsert atomically creates the stream (with version = count) or bumps an existing stream's
  version (stream_version + count). Discovered during integration testing. (2026-03-22)

- Decision: Use `ephemeral-pg` for integration tests.
  Rationale: Provides temporary PostgreSQL databases with hasql integration. Registered in
  mori as a dependency. Tests need a real database (not mocks) — the SQL benchmarks already
  validated this approach.
  Date: 2026-03-22


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Current State

Milestone 1 (Schema + Types) is complete. The following modules exist:

| Module | Path | State |
|---|---|---|
| `Kiroku.Store.Types` | `kiroku-store/src/Kiroku/Store/Types.hs` | Complete — all domain types |
| `Kiroku.Store.Connection` | `kiroku-store/src/Kiroku/Store/Connection.hs` | Complete — pool + `withStore` bracket |
| `Kiroku.Store.Error` | `kiroku-store/src/Kiroku/Store/Error.hs` | Stub — `AppendError` type defined, no mapping logic |
| `Kiroku.Store.Schema` | `kiroku-store/src/Kiroku/Store/Schema.hs` | Stub — `initializeSchema` is `pure ()` |
| `Kiroku.Store.SQL` | `kiroku-store/src/Kiroku/Store/SQL.hs` | Stub — empty, marked TODO |
| `Kiroku.Store` | `kiroku-store/src/Kiroku/Store.hs` | Re-exports Types, Connection, Error |

The schema DDL lives in `kiroku-store/sql/schema.sql` (132 lines, idempotent, tested via
pgbench). SQL benchmarks are complete (Track 1, `docs/BENCH-SQL-BASELINE.md`).

### Key Files

- **Design spec:** `docs/DESIGN.md` — CTE SQL for all append variants (lines 177–261),
  error mapping table (lines 498–503), type definitions (lines 340–408)
- **Implementation plan:** `docs/IMPLEMENTATION.md` — Milestone 2 scope (lines 127–165)
- **SQL baseline:** `docs/BENCH-SQL-BASELINE.md` — performance targets to compare against
- **Schema DDL:** `kiroku-store/sql/schema.sql` — the DDL that `initializeSchema` must execute
- **Cabal manifest:** `kiroku-store/kiroku-store.cabal` — must be updated with new modules/deps
- **Cabal project:** `cabal.project` — project-level settings

### Key Types (defined in `Kiroku.Store.Types`)

```haskell
newtype StreamName = StreamName Text
newtype StreamId = StreamId Int64
newtype EventId = EventId UUID
newtype EventType = EventType Text
newtype StreamVersion = StreamVersion Int64
newtype GlobalPosition = GlobalPosition Int64

data ExpectedVersion = NoStream | StreamExists | ExactVersion !StreamVersion | AnyVersion

data EventData = EventData
    { eventId       :: !(Maybe EventId)   -- Nothing = auto-generate UUIDv7
    , eventType     :: !EventType
    , payload       :: !Value             -- JSONB
    , metadata      :: !(Maybe Value)     -- JSONB
    , causationId   :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    }

data AppendResult = AppendResult
    { streamId       :: !StreamId
    , streamVersion  :: !StreamVersion
    , globalPosition :: !GlobalPosition
    }

data AppendError
    = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
    | StreamNotFound !StreamName
    | StreamAlreadyExists !StreamName
    | DuplicateEvent !EventId
```

### Key Dependencies

| Package | Version | Purpose |
|---|---|---|
| `hasql` | >= 1.8 | PostgreSQL driver — `Statement`, `Session`, encoders/decoders |
| `hasql-pool` | >= 1.2 | Connection pool — `Pool.use :: Pool -> Session a -> IO (Either UsageError a)` |
| `mmzk-typeid` | (new) | UUIDv7 generation — `Data.UUID.V7.genUUIDs :: Word16 -> m [UUID]` |
| `aeson` | >= 2.1 | `Value` type for JSONB encoding |
| `vector` | >= 0.13 | `Vector` for batch array parameters |
| `uuid` | >= 1.3 | `UUID` type (re-exported by mmzk-typeid) |
| `bytestring` | >= 0.11 | For raw SQL text in schema init |
| `text` | >= 2.0 | Text throughout |
| `time` | >= 1.12 | `UTCTime` for timestamps |
| `contravariant-extras` | (new) | `contrazip` functions for composing hasql encoders |

### Hasql API Patterns

**Statement construction:**
```haskell
Statement.preparable :: Text -> Encoders.Params a -> Decoders.Result b -> Statement a b
```

**Parameter encoding (product of params using Contravariant + Monoid):**
```haskell
-- Single param
Encoders.param (Encoders.nonNullable Encoders.int8) :: Encoders.Params Int64

-- Multiple params composed with (>$<) and (<>)
(fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
  <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.int8))

-- Array param (for unnest)
Encoders.param (Encoders.nonNullable (Encoders.foldableArray (Encoders.nonNullable Encoders.uuid)))
```

**Running a statement via the pool:**
```haskell
Pool.use pool (Session.statement params someStatement) :: IO (Either UsageError result)
```

**Error extraction (for PostgreSQL error code mapping):**
```haskell
-- Pool.use returns Either UsageError a
-- UsageError = ConnectionUsageError | SessionUsageError SessionError | AcquisitionTimeoutUsageError
-- SessionError contains StatementSessionError which wraps StatementError
-- StatementError = ServerStatementError ServerError | ...
-- ServerError = ServerError code message detail hint position
--   where code :: Text is the SQLSTATE (e.g., "23505")
```

### SQL CTE Structure (from DESIGN.md)

The append CTE has 5 steps, all gated on step 1:

1. **stream_update** — `UPDATE streams SET stream_version = ...` (optimistic concurrency check)
2. **inserted_events** — `INSERT INTO events` (gated on stream_update via `EXISTS`)
3. **source_links** — `INSERT INTO stream_events` for source stream
4. **all_update** — `UPDATE streams SET stream_version = ...` for `$all` (stream_id = 0)
5. **all_links** — `INSERT INTO stream_events` for `$all`

The final `SELECT` returns `stream_id`, `stream_version`, `global_position`. Empty result = version conflict.

The CTE takes 9 positional parameters:
- `$1`–`$7`: parallel arrays (event_ids, event_types, causation_ids, correlation_ids, data, metadata, created_at)
- `$8`: stream_name (Text)
- `$9`: expected_version (Int64) — only for `append_expected_version`


## Plan of Work

### Milestone 2.1 — Dependencies and Schema Init

**Scope:** Add `mmzk-typeid` and `contravariant-extras` as dependencies. Wire `initializeSchema`
to execute the DDL from `kiroku-store/sql/schema.sql`.

**What exists at the end:** `initializeSchema` creates all tables, indexes, and triggers in
the target schema. Idempotent — safe to call on every startup.

#### Step 2.1.1 — Update `kiroku-store.cabal`

In `kiroku-store/kiroku-store.cabal`, add to the `library` `build-depends`:

```
, contravariant-extras >= 0.3
, mmzk-typeid          >= 0.6
```

Add to the `exposed-modules`:

```
Kiroku.Store.Append
```

Change `Kiroku.Store.SQL` from `other-modules` to remain in `other-modules` (internal).

Add `mmzk-typeid` to the test-suite `build-depends`:

```
, mmzk-typeid
```

Add `ephemeral-pg` to the test-suite `build-depends`:

```
, ephemeral-pg
, hasql
, hasql-pool
, text
, vector
```

#### Step 2.1.2 — Add `mmzk-typeid` source-repository-package to `cabal.project`

`mmzk-typeid` is at `/Users/shinzui/Keikaku/hub/haskell/mmzk-typeid-project`. Check whether
it's available on Hackage or needs a `source-repository-package` stanza. If local-only, add:

```
optional-packages: /path/to/mmzk-typeid
```

or use `packages:` in `cabal.project`. Similarly for `ephemeral-pg`.

#### Step 2.1.3 — Implement `initializeSchema`

In `kiroku-store/src/Kiroku/Store/Schema.hs`:

- Read the DDL from `kiroku-store/sql/schema.sql` at compile time using `file-embed`
  or, simpler: embed the DDL as a `ByteString` literal using Template Haskell.
- **Simpler approach:** Use `Hasql.Session.script` to execute raw SQL. The `script` function
  takes a `Text` parameter and executes it as a multi-statement script.
- The schema DDL is already idempotent (`CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO NOTHING`,
  `DROP TRIGGER IF EXISTS`).
- For schema parameterization: defer to a later milestone. For now, execute against the default
  schema. The schema name from `ConnectionSettings` is stored but not yet used to parameterize
  DDL.

```haskell
initializeSchema :: Pool -> Text -> IO ()
initializeSchema pool _schema = do
    result <- Pool.use pool (Session.script schemaDDL)
    case result of
        Left err -> throwIO (SchemaInitError err)
        Right () -> pure ()
  where
    schemaDDL :: Text
    schemaDDL = "..." -- embedded DDL
```

**Decision:** Embed the DDL as a Haskell `Text` literal rather than reading from disk at
runtime. This keeps the library self-contained with no file system dependency.

**Acceptance:** `initializeSchema` creates the schema. Running it twice is a no-op.

### Milestone 2.2 — SQL Statements

**Scope:** All four append CTE variants as hasql `Statement` values in `Kiroku.Store.SQL`.

**What exists at the end:** Four prepared statements, each taking a structured parameter tuple
and returning `Maybe AppendResult`.

#### Parameter Type

All four variants share the same event-array parameters. Define a common type:

```haskell
-- | Parameters for an append CTE.
data AppendParams = AppendParams
    { eventIds      :: !(Vector UUID)
    , eventTypes    :: !(Vector Text)
    , causationIds  :: !(Vector (Maybe UUID))
    , correlationIds :: !(Vector (Maybe UUID))
    , payloads      :: !(Vector Value)
    , metadatas     :: !(Vector (Maybe Value))
    , createdAts    :: !(Vector UTCTime)
    , streamName    :: !Text
    }

-- | Extended with expected version.
data AppendExpectedParams = AppendExpectedParams
    { base            :: !AppendParams
    , expectedVersion :: !Int64
    }
```

#### Encoder Construction

Use `contrazip` from `contravariant-extras` and `foldableArray` from `Hasql.Encoders`:

```haskell
appendParamsEncoder :: Encoders.Params AppendParams
appendParamsEncoder =
    contrazip8
        (param (nonNullable (foldableArray (nonNullable uuid))))   -- $1 event_ids
        (param (nonNullable (foldableArray (nonNullable text))))   -- $2 event_types
        (param (nonNullable (foldableArray (nullable uuid))))      -- $3 causation_ids
        (param (nonNullable (foldableArray (nullable uuid))))      -- $4 correlation_ids
        (param (nonNullable (foldableArray (nonNullable jsonb))))  -- $5 data
        (param (nonNullable (foldableArray (nullable jsonb))))     -- $6 metadata
        (param (nonNullable (foldableArray (nonNullable timestamptz)))) -- $7 created_at
        (param (nonNullable text))                                 -- $8 stream_name
```

Wait — `contrazip8` takes a tuple, but `AppendParams` is a record. Use `(>$<)` to project
fields:

```haskell
appendParamsEncoder :: Encoders.Params AppendParams
appendParamsEncoder =
    ((.eventIds) >$< param (nonNullable (foldableArray (nonNullable uuid))))
    <> ((.eventTypes) >$< param (nonNullable (foldableArray (nonNullable text))))
    <> ((.causationIds) >$< param (nonNullable (foldableArray (nullable uuid))))
    <> ((.correlationIds) >$< param (nonNullable (foldableArray (nullable uuid))))
    <> ((.payloads) >$< param (nonNullable (foldableArray (nonNullable jsonb))))
    <> ((.metadatas) >$< param (nonNullable (foldableArray (nullable jsonb))))
    <> ((.createdAts) >$< param (nonNullable (foldableArray (nonNullable timestamptz))))
    <> ((.streamName) >$< param (nonNullable text))
```

This is cleaner — uses `OverloadedRecordDot` and `Contravariant` composition. No need for
`contravariant-extras` after all (the `(<>)` from `Monoid` on `Params` + `(>$<)` from
`Contravariant` suffice).

#### Result Decoder

```haskell
appendResultDecoder :: Decoders.Result (Maybe AppendResult)
appendResultDecoder = Decoders.rowMaybe $
    AppendResult
        <$> (StreamId <$> Decoders.column (Decoders.nonNullable Decoders.int8))
        <*> (StreamVersion <$> Decoders.column (Decoders.nonNullable Decoders.int8))
        <*> (GlobalPosition <$> Decoders.column (Decoders.nonNullable Decoders.int8))
```

#### The Four CTE Variants

**1. `appendExpectedVersion`** — Standard optimistic concurrency. Stream must exist at exact version.

SQL: The full CTE from DESIGN.md lines 178–246, with `WHERE stream_version = $9` in `stream_update`.
Parameters: `AppendParams` + `expectedVersion :: Int64` (9 params total).
Returns: `Maybe AppendResult` — `Nothing` means version conflict.

**2. `appendStreamExists`** — Stream must exist, any version.

SQL: Same CTE but `stream_update` has no version check:
```sql
UPDATE streams SET stream_version = stream_version + (SELECT count(*) FROM new_events)
WHERE stream_name = $8
RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
```
Parameters: `AppendParams` (8 params, no `$9`).
Returns: `Maybe AppendResult` — `Nothing` means stream doesn't exist.

**3. `appendNoStream`** — Stream must NOT exist. Creates it.

SQL: `stream_update` becomes an `INSERT`:
```sql
stream_insert AS (
    INSERT INTO streams (stream_name, stream_version)
    VALUES ($8, (SELECT count(*) FROM new_events))
    ON CONFLICT (stream_name) DO NOTHING
    RETURNING stream_id, 0 AS initial_version
)
```
Subsequent CTEs reference `stream_insert` instead of `stream_update`.
Parameters: `AppendParams` (8 params).
Returns: `Maybe AppendResult` — `Nothing` means stream already exists.

**4. `appendAnyVersion`** — Create-or-append. Always succeeds (unless duplicate event ID).

SQL: Two-phase in the CTE:
```sql
-- Phase 1: Ensure stream exists
stream_ensure AS (
    INSERT INTO streams (stream_name, stream_version)
    VALUES ($8, 0)
    ON CONFLICT (stream_name) DO NOTHING
),
-- Phase 2: Update version (now guaranteed to exist)
stream_update AS (
    UPDATE streams SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_name = $8
    RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
)
```
Parameters: `AppendParams` (8 params).
Returns: `Maybe AppendResult` — should always be `Just` unless a constraint violation occurs.

#### File: `kiroku-store/src/Kiroku/Store/SQL.hs`

Define:

```haskell
module Kiroku.Store.SQL
    ( AppendParams (..)
    , appendExpectedVersion
    , appendStreamExists
    , appendNoStream
    , appendAnyVersion
    ) where
```

Each statement is a `Statement.Statement params (Maybe AppendResult)` using `Statement.preparable`.

### Milestone 2.3 — Append Module

**Scope:** Public append functions that prepare `EventData` into `AppendParams`, handle UUIDv7
pre-generation, run the statement via the pool, and map errors.

**What exists at the end:** `Kiroku.Store.Append` with four public functions.

#### File: `kiroku-store/src/Kiroku/Store/Append.hs`

```haskell
module Kiroku.Store.Append
    ( appendToStream
    ) where
```

**Core flow for `appendToStream`:**

```haskell
appendToStream
    :: KirokuStore
    -> StreamName
    -> ExpectedVersion
    -> [EventData]
    -> IO (Either AppendError AppendResult)
appendToStream store (StreamName name) expected events = do
    -- 1. Pre-generate UUIDv7s for events with eventId = Nothing
    preparedEvents <- prepareEvents events

    -- 2. Build AppendParams from prepared events
    let params = buildAppendParams name preparedEvents

    -- 3. Select and run the appropriate CTE variant
    result <- Pool.use (store.pool) $ case expected of
        ExactVersion (StreamVersion v) ->
            Session.statement (params, v) SQL.appendExpectedVersion
        StreamExists ->
            Session.statement params SQL.appendStreamExists
        NoStream ->
            Session.statement params SQL.appendNoStream
        AnyVersion ->
            Session.statement params SQL.appendAnyVersion

    -- 4. Map the result
    case result of
        Left usageErr -> Left <$> mapUsageError name expected usageErr
        Right Nothing -> pure (Left (versionConflictError name expected))
        Right (Just r) -> pure (Right r)
```

**`prepareEvents`** — walks the `[EventData]` list, generates UUIDv7s for any `eventId = Nothing`:

```haskell
prepareEvents :: [EventData] -> IO [PreparedEvent]
prepareEvents events = do
    let needIds = length (filter (\e -> isNothing e.eventId) events)
    newIds <- if needIds > 0
        then Data.UUID.V7.genUUIDs (fromIntegral needIds)
        else pure []
    pure (zipAssign events newIds)
```

**`buildAppendParams`** — converts `[PreparedEvent]` into the `AppendParams` record with
`Vector` fields built from the list via `Vector.fromList`.

**`mapUsageError`** — pattern matches on `UsageError` → `SessionUsageError` →
`StatementSessionError` → `ServerStatementError (ServerError code msg detail _ _)` and maps:

| SQLSTATE `code` | `detail` contains | `AppendError` |
|---|---|---|
| `"23505"` | `events_pkey` | `DuplicateEvent` (extract event_id from detail) |
| `"23505"` | `ix_streams_stream_name` | `StreamAlreadyExists` |
| `"23505"` | (other) | `WrongExpectedVersion` |
| `"23503"` | — | `StreamNotFound` |

**`versionConflictError`** — when the CTE returns 0 rows (no `ServerError`), the version
didn't match. Return the appropriate error based on `ExpectedVersion`:
- `ExactVersion v` → `WrongExpectedVersion name (ExactVersion v) (StreamVersion 0)` (actual
  version unknown from empty result; caller should `getStream` if they need it)
- `StreamExists` → `StreamNotFound name`
- `NoStream` → `StreamAlreadyExists name`
- `AnyVersion` → should never happen (bug)

### Milestone 2.4 — Error Mapping

**Scope:** Flesh out `Kiroku.Store.Error` with the `mapUsageError` helper.

In `kiroku-store/src/Kiroku/Store/Error.hs`, add:

```haskell
-- | Map a hasql UsageError to an AppendError.
mapUsageError :: Text -> ExpectedVersion -> Pool.UsageError -> IO AppendError
```

This function lives in `Error.hs` but is called from `Append.hs`. It needs to import
`Hasql.Pool` and `Hasql.Errors` to pattern-match on the error hierarchy.

### Milestone 2.5 — Re-exports and Cabal Updates

**Scope:** Wire everything together.

In `kiroku-store/src/Kiroku/Store.hs`, add:
```haskell
import Kiroku.Store.Append
```
and re-export `appendToStream`.

### Milestone 2.6 — Integration Tests

**Scope:** Tests using `ephemeral-pg` for a real temporary PostgreSQL database.

In `kiroku-store/test/Main.hs`, add test cases:

1. **Append with NoStream** — creates stream, returns AppendResult with streamVersion=1
2. **Append with ExactVersion** — append to version 1, returns version 2
3. **Version conflict** — append with ExactVersion 0 to a stream at version 1, returns WrongExpectedVersion
4. **NoStream on existing stream** — returns StreamAlreadyExists
5. **StreamExists on missing stream** — returns StreamNotFound
6. **AnyVersion creates stream** — succeeds on non-existent stream
7. **AnyVersion appends to existing** — succeeds on existing stream
8. **Duplicate event ID** — append same event_id twice, returns DuplicateEvent
9. **Batch append** — append 10 events, verify all get sequential versions and global positions
10. **Read-your-own-writes** — append then query `stream_events` to verify data is visible

### Milestone 2.7 — Benchmarks

**Scope:** Haskell append benchmarks comparing against SQL baseline.

In `kiroku-store/bench/Main.hs`, add benchmark groups:

- **B1:** Sequential single-event appends (1 thread) — compare against 2,620 TPS SQL baseline
- **B2:** Sequential batch appends (10, 100 events) — compare against 14,939 / 43,166 events/s
- **B3:** Concurrent cross-stream appends (4, 8, 16 threads) — compare against Track 1 Bench 3

**Gate:** Haskell overhead should be < 20% vs SQL baseline. If > 30%, stop and investigate.


## Concrete Steps

All commands run from the repository root: `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

### Step 1: Verify current build

```bash
cabal build all
```

Expected: clean build, no errors.

### Step 2: Update cabal file and project

Edit `kiroku-store/kiroku-store.cabal` and `cabal.project` as described in M2.1.

```bash
cabal build all
```

Expected: builds with new dependencies resolved.

### Step 3: Implement initializeSchema

Edit `kiroku-store/src/Kiroku/Store/Schema.hs`.

```bash
cabal build kiroku-store
```

Expected: compiles. Then test manually:

```bash
just reset-database
cabal test all
```

### Step 4: Implement SQL statements

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`.

```bash
cabal build kiroku-store
```

Expected: compiles with all four statement definitions.

### Step 5: Implement Append module

Create `kiroku-store/src/Kiroku/Store/Append.hs`.

```bash
cabal build kiroku-store
```

### Step 6: Implement error mapping

Edit `kiroku-store/src/Kiroku/Store/Error.hs`.

```bash
cabal build kiroku-store
```

### Step 7: Update re-exports

Edit `kiroku-store/src/Kiroku/Store.hs`.

```bash
cabal build kiroku-store
```

### Step 8: Write and run tests

Edit `kiroku-store/test/Main.hs`.

```bash
cabal test kiroku-store-test
```

Expected: all tests pass.

### Step 9: Write and run benchmarks

Edit `kiroku-store/bench/Main.hs`.

```bash
just up  # ensure PostgreSQL is running
cabal bench kiroku-store-bench
```

Expected: benchmark results printed, overhead < 20% vs SQL baseline.


## Validation and Acceptance

### Compilation

```bash
cabal build all
```

Must succeed with no warnings in kiroku-store modules.

### Tests

```bash
cabal test all
```

All 10 test cases must pass. Key behaviors:

- **Append creates events:** After `appendToStream store (StreamName "order-123") NoStream [event]`,
  querying `SELECT count(*) FROM events` returns 1, and `SELECT stream_version FROM streams
  WHERE stream_name = 'order-123'` returns 1.
- **Version conflict is safe:** After a conflict, no orphaned rows exist in `events` or
  `stream_events`.
- **Global positions are contiguous:** After N appends to different streams, `SELECT
  stream_version FROM streams WHERE stream_id = 0` equals total event count.
- **Batch ordering:** Events in a batch get sequential `stream_version` values matching
  their position in the input list.

### Benchmarks

```bash
cabal bench kiroku-store-bench
```

Compare output against `docs/BENCH-SQL-BASELINE.md`:

| Operation | SQL Baseline | Haskell Target (< 20% overhead) |
|---|---|---|
| Single-event append (1 thread) | 2,620 TPS | > 2,096 TPS |
| 10-event batch append | 14,939 events/s | > 11,951 events/s |
| 100-event batch append | 43,166 events/s | > 34,533 events/s |


## Idempotence and Recovery

- **Schema initialization** is idempotent — uses `IF NOT EXISTS` and `ON CONFLICT DO NOTHING`.
  Safe to call repeatedly.
- **Tests** use `ephemeral-pg` which creates a fresh database per test run. No cleanup needed.
- **Build steps** are idempotent — `cabal build` is incremental.
- **If a step fails:** fix the issue and re-run the same step. No rollback needed — all
  changes are source code edits.


## Interfaces and Dependencies

### New Module: `Kiroku.Store.SQL` (internal)

In `kiroku-store/src/Kiroku/Store/SQL.hs`, define:

```haskell
data AppendParams = AppendParams
    { eventIds       :: !(Vector UUID)
    , eventTypes     :: !(Vector Text)
    , causationIds   :: !(Vector (Maybe UUID))
    , correlationIds :: !(Vector (Maybe UUID))
    , payloads       :: !(Vector Value)
    , metadatas      :: !(Vector (Maybe Value))
    , createdAts     :: !(Vector UTCTime)
    , streamName     :: !Text
    }

appendExpectedVersion :: Statement (AppendParams, Int64) (Maybe AppendResult)
appendStreamExists    :: Statement AppendParams (Maybe AppendResult)
appendNoStream        :: Statement AppendParams (Maybe AppendResult)
appendAnyVersion      :: Statement AppendParams (Maybe AppendResult)
```

### New Module: `Kiroku.Store.Append` (public)

In `kiroku-store/src/Kiroku/Store/Append.hs`, define:

```haskell
appendToStream
    :: KirokuStore
    -> StreamName
    -> ExpectedVersion
    -> [EventData]
    -> IO (Either AppendError AppendResult)
```

### Updated Module: `Kiroku.Store.Error`

In `kiroku-store/src/Kiroku/Store/Error.hs`, add:

```haskell
-- | Internal: map a pool usage error to an AppendError.
mapUsageError :: Text -> ExpectedVersion -> Pool.UsageError -> AppendError

-- | Internal: infer error from empty CTE result.
emptyResultError :: Text -> ExpectedVersion -> AppendError
```

### Updated Module: `Kiroku.Store.Schema`

In `kiroku-store/src/Kiroku/Store/Schema.hs`:

```haskell
-- | Exception thrown when schema initialization fails.
newtype SchemaInitError = SchemaInitError Pool.UsageError
    deriving stock (Show)
    deriving anyclass (Exception)

initializeSchema :: Pool -> Text -> IO ()
```

### Updated Module: `Kiroku.Store`

In `kiroku-store/src/Kiroku/Store.hs`, add re-export:

```haskell
module Kiroku.Store
    ( module Kiroku.Store.Types
    , module Kiroku.Store.Connection
    , module Kiroku.Store.Error
    , module Kiroku.Store.Append
    , initializeSchema
    ) where
```
