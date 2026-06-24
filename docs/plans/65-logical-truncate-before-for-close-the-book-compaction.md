---
id: 65
slug: logical-truncate-before-for-close-the-book-compaction
title: "Logical truncate-before for close-the-book compaction"
kind: exec-plan
created_at: 2026-06-24T16:27:28Z
intention: "intention_01kvx7a6vgeyk8de9agd08eef0"
---

# Logical truncate-before for close-the-book compaction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Event-sourcing systems keep the full history of every "stream" (an ordered list of
events for one entity, e.g. `preference-123` holds every change a recipient made to
their notification preferences). Over years a single stream can accumulate hundreds of
events, and rebuilding the entity's current state ("rehydration" — replaying a stream's
events one by one to compute the latest state) gets slow because every read replays the
whole history.

The standard fix is the **close-the-book** pattern (also called snapshot-and-compact):
periodically append one *snapshot* event that captures the entity's current state, then
arrange for future rehydration to start from that snapshot instead of from the beginning.
After this change, a kiroku consumer can do exactly that **safely and reversibly**:

1. Append a snapshot event to the stream (it lands at some version `V`).
2. Call a new function `setStreamTruncateBefore name V`.
3. From then on, `readStreamForward name` / `readStreamBackward name` return only the
   events at version `>= V` (the snapshot and everything after it). Rehydration is bounded.

Crucially, **no events are deleted**. The marker is a per-stream cursor that hides the
prefix from ordered stream reads. The global event log (`$all`), category reads, and
subscriptions still see the complete history, so projections and audit are unaffected and
a future projection can still be built from full history. The operation is fully
reversible: `clearStreamTruncateBefore name` (or setting the marker back to a lower value)
re-exposes the hidden prefix instantly.

You can see it working by running the new test suite `Test/TruncateBefore.hs`: it creates
a stream with several events, sets the marker, and asserts that the per-stream read returns
only the kept suffix while `readAllForward` (the `$all` global log) and `readCategory`
still return the full history, and that `countEvents` (a raw `SELECT count(*) FROM events`)
is unchanged — proving nothing was physically removed.

### Why logical truncation rather than physical delete

This plan deliberately implements a **logical** truncate-before marker instead of the
**physical** prefix hard-delete that was originally proposed in
`docs/feature-requests/0001-version-bounded-prefix-truncate.md` (a function
`hardTruncateStreamBefore` that would orphan-delete the prefix events out of the `events`
and `stream_events` tables). The physical approach was rejected for three event-sourcing
correctness reasons:

- **It mutates the global log.** kiroku's `$all` stream (the row with `stream_id = 0` in
  the `stream_events` table) is the backbone every subscription and projection reads from.
  Physically deleting prefix events removes them from `$all`, so any catch-up consumer that
  has not yet passed those positions silently skips events. A "subscription frontier guard"
  only protects *currently-registered* subscriptions — it cannot protect a *future*
  projection you have not written yet. Keeping the global log append-only and complete is
  the reason mature systems (EventStoreDB, Marten) snapshot separately from the log rather
  than deleting it.
- **It is irreversible.** A wrong version bound permanently destroys data. The logical
  marker is recoverable.
- **It fits kiroku's existing architecture better.** kiroku already has a *logical*,
  reversible read-hiding mechanism: soft-delete, which sets `streams.deleted_at` and makes
  reads filter `WHERE deleted_at IS NULL`. The truncate-before marker is the same shape — a
  column on `streams` plus a read-path filter — not the GUC-gated, multi-statement,
  orphan-deletion machinery that physical hard-delete requires.

Physical storage reclamation (actually shrinking the `events` table by removing
orphaned prefix events, the equivalent of a database "scavenge"/garbage-collection pass)
is a genuinely separate and more dangerous concern. It is **explicitly deferred to a
possible Phase 2** and is out of scope for this plan. If a consumer ever proves a real
disk-pressure need, it should be added as a distinct, separately-planned, frontier-guarded
operation layered on top of the marker introduced here.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `truncate_before` column migration and expose it on `StreamInfo`/`getStream`. (2026-06-24)
- [x] M1: New SQL migration file `kiroku-store-migrations/sql-migrations/2026-06-24-00-00-00-stream-truncate-before.sql`. (2026-06-24)
- [x] M1: Extend `StreamInfo` (`Kiroku/Store/Types.hs`) with `truncateBefore`, update `streamInfoRow` decoder and `getStreamSQL` (`Kiroku/Store/SQL.hs`). Confirmed `getStreamStmt` is the sole `streamInfoRow` consumer. (2026-06-24)
- [x] M2: New write API — `SetStreamTruncateBefore` effect constructor + interpreter arm + `setStreamTruncateBeforeStmt` SQL. (2026-06-24)
- [x] M2: Export `setStreamTruncateBefore` and `clearStreamTruncateBefore` from `Kiroku/Store/Lifecycle.hs` (re-exported transitively by the `Kiroku.Store` umbrella, which re-exports `module Kiroku.Store.Lifecycle`). (2026-06-24)
- [x] M3: Read-path enforcement — `readStreamForwardSQL` and `readStreamBackwardSQL` filter on `stream_version >= truncate_before`. (2026-06-24)
- [x] M3: Confirm paged read (`readStreamForwardStream`) is built on `ReadStreamForward` (Read.hs:78) so it inherits the filter; `$all`/category/`eventExistsInStream` left untouched per the decisions below. (2026-06-24)
- [x] M1–M3 build: `cabal build kiroku-store kiroku-store-migrations` green (incl. all test suites). (2026-06-24)
- [x] M4: New test module `kiroku-store/test/Test/TruncateBefore.hs` (8 examples), registered in `kiroku-store/test/Main.hs` and `kiroku-store.cabal` other-modules. (2026-06-24)
- [x] M4: Update user docs and annotate the source feature request with the chosen design. Updated `docs/user/lifecycle.md` (new "Close-the-Book Compaction" section), `docs/user/schema.md` (truncate_before column), `docs/SCALING-ANALYSIS.md` and `docs/DESIGN.md` (cross-references), and `docs/feature-requests/0001-...` (resolution note). (2026-06-24)
- [x] M3/M4: `EXPLAIN (ANALYZE, BUFFERS)` the rewritten per-stream read on a seeded table; confirmed the index-bound nested-loop generic plan (both `> $2` and `>= truncate_before` pushed as Index Cond). Plan recorded in Surprises & Discoveries. (2026-06-24)
- [x] Full validation: `cabal test all` green (kiroku-store-test 234/234, kiroku-store-migrations-test 1/1). Embedded migration applies cleanly and repeatably via the ephemeral-pg test path (`just migrate` against the dev cluster was not run — its port 5432 is held by another local service — but migration application is fully exercised by every test's `withTestStore`). (2026-06-24)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The generic prepared-statement plan for the rewritten `readStreamForwardSQL` is the
  index-bound nested loop the Performance Considerations section predicted — no fallback to
  the scalar-subquery form is needed. Verified on a seeded scratch table (2000 streams ×
  200 events = 400k `stream_events` rows, mirroring the real schema and the
  `ix_stream_events_stream_version` index), with `truncate_before = 180` on the target
  stream and `SET plan_cache_mode = force_generic_plan`:

  ```text
  Limit
    ->  Sort  (Sort Key: se.stream_version)
      ->  Nested Loop
        ->  Nested Loop
          ->  Index Scan using ix_streams_stream_name on streams s
                Index Cond: (stream_name = $1)
                Filter: (deleted_at IS NULL)
          ->  Index Scan using ix_stream_events_stream_version on stream_events se
                Index Cond: ((stream_id = s.stream_id)
                             AND (stream_version >= s.truncate_before)
                             AND (stream_version > $2))
        ->  Index Scan using events_pkey on events e
              Index Cond: (event_id = se.event_id)
  Execution Time: 0.047 ms
  ```

  Both `stream_version >= s.truncate_before` and `stream_version > $2` are pushed into the
  inner **Index Cond** (index lower bounds), not demoted to a post-scan `Filter`. The outer
  `streams` row (reached by the unique `ix_streams_stream_name`) binds `s.stream_id` and
  `s.truncate_before` before the inner scan, so a set marker makes the read *seek past* the
  hidden prefix: the scan touched 21 rows (versions 180–200), not all 200. The number of
  `streams` accesses is one, unchanged from the pre-rewrite scalar-subquery form.
  Date: 2026-06-24


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement a logical `truncate_before` marker rather than the physical
  `hardTruncateStreamBefore` delete proposed in feature request 0001.
  Rationale: Physical deletion mutates the `$all` global log (breaking catch-up and
  future projections), is irreversible, and requires GUC-gated orphan-deletion machinery.
  The logical marker preserves the global log, is reversible, and mirrors the existing
  soft-delete read-filter mechanism. Physical reclamation is deferred to a possible Phase 2.
  Date: 2026-06-24

- Decision: The `truncate_before` marker affects only the per-stream ordered read APIs
  (`readStreamForward`, `readStreamBackward`, and the paged `readStreamForwardStream` that
  builds on them). It does **not** affect `readAllForward`/`readAllBackward` (the `$all`
  global log), `readCategory`, subscriptions, or `eventExistsInStream`.
  Rationale: The global log and its derived read paths are the projection/subscription
  backbone and must remain complete — that is the entire point of choosing logical over
  physical. `eventExistsInStream` is a low-level physical-membership probe; the prefix
  events still physically exist, so it continues to report membership. Consumers who need
  the prefix gone from the global log must use the deferred physical compaction (Phase 2).
  Date: 2026-06-24

- Decision: `setStreamTruncateBefore` accepts any non-negative version and may be set
  lower as well as higher (no monotonic-raise-only restriction).
  Rationale: Reversibility is the core safety advantage over physical delete; lowering the
  marker (or `clearStreamTruncateBefore`, which sets it to `0`) re-exposes hidden events.
  A value of `0` (the column default) means "nothing truncated". Because per-stream event
  versions are 1-based (the first appended event is version 1), a marker of `0` or `1`
  keeps the entire stream. The value is stored verbatim with no upper clamp; setting it
  beyond the stream's high-water version simply hides every event (still reversible).
  Date: 2026-06-24

- Decision: Reuse the existing `Maybe StreamId` return shape (as `softDeleteStream` /
  `undeleteStream` do): `Just streamId` on success, `Nothing` if the stream does not exist
  or is soft-deleted. Reject the reserved `$all` stream with `ReservedStreamName` via the
  existing `validateStreamName` guard. No new `StoreError` variant is introduced.
  Rationale: Consistency with the established lifecycle API surface; minimal new surface.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-24.** All four milestones landed as designed; the result matches the
original purpose exactly. A kiroku consumer can now append a snapshot event, call
`setStreamTruncateBefore name V`, and have `readStreamForward` / `readStreamBackward` /
`readStreamForwardStream` return only the kept suffix, while `readAllForward`,
`readCategory`, subscriptions, and `countEvents` are provably unchanged — the
single most important acceptance property (the global log stays complete and nothing is
deleted) is asserted directly in `Test/TruncateBefore.hs`. The operation is reversible
(`clearStreamTruncateBefore`) and idempotent.

What went to plan: the soft-delete template transferred cleanly to every layer (migration,
`StreamInfo`, effect constructor + interpreter arm, SQL statement, lifecycle wrappers). The
`Kiroku.Store` umbrella re-exports `module Kiroku.Store.Lifecycle`, so the two new functions
became visible to consumers with no umbrella edit.

The one thing worth verifying — the prepared-statement read-path plan — came out
*better than neutral*: under `force_generic_plan` the planner pushes both the cursor bound
and the `truncate_before` bound into the `ix_stream_events_stream_version` Index Cond, so a
set marker makes the read seek past the hidden prefix (21 rows scanned for versions 180–200,
not 200). The scalar-subquery fallback documented in Performance Considerations was not
needed. Evidence in Surprises & Discoveries.

Gaps / deferred (unchanged from plan): physical reclamation of the hidden prefix
("scavenge") remains out of scope for a possible Phase 2. `just migrate` against the
developer's local cluster was not run because port 5432 was held by another service; the
embedded migration is instead validated by the ephemeral-pg test path, which applies all
migrations (idempotently and repeatably) before every test.


## Context and Orientation

This work lives in the **kiroku** repository, a PostgreSQL-backed event store written in
Haskell. The package that changes is `kiroku-store` (the library) plus
`kiroku-store-migrations` (the schema-owning package that holds the SQL migration files).
You do not need prior knowledge of either; everything required is described below.

### Key terms

- **Stream**: an ordered sequence of events identified by a text name (e.g.
  `preference-123`). Stored across three tables.
- **Per-stream version** (`stream_version`): an event's 1-based position within its stream.
  The first event appended to a stream is version 1, the second is version 2, and so on.
  The current high-water version of a stream is kept in `streams.stream_version`.
- **`$all`**: a reserved internal stream (the `streams` row with `stream_id = 0`, name
  `$all`) that contains one row per event in global order. It is the backbone that
  subscriptions and category reads consume. The text name `$all` is *reserved*: application
  lifecycle operations reject it.
- **Soft-delete**: kiroku's existing reversible "hide a whole stream" operation. It sets
  `streams.deleted_at` to a timestamp; reads then filter `WHERE deleted_at IS NULL`.
  `undeleteStream` clears it. This is the architectural template for the marker we add.
- **Close-the-book / snapshot-and-compact**: append a snapshot event capturing current
  state, then make rehydration start from it. See Purpose above.
- **Rehydration**: replaying a stream's events to compute the entity's current state.

### Database schema (current)

Defined in `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`.
All objects live in the `kiroku` schema. The three core tables:

```sql
CREATE TABLE streams (
    stream_id      BIGSERIAL    PRIMARY KEY,   -- 0 is reserved for $all
    stream_name    TEXT         NOT NULL,
    category       TEXT         GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED,
    stream_version BIGINT       NOT NULL DEFAULT 0,   -- high-water version
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at     TIMESTAMPTZ,                 -- soft-delete marker
    CONSTRAINT ix_streams_stream_name UNIQUE (stream_name)
);

CREATE TABLE events ( event_id UUID PRIMARY KEY DEFAULT uuidv7(), ... );

CREATE TABLE stream_events (   -- junction: one row per (event, stream) membership
    event_id                UUID   NOT NULL REFERENCES events(event_id),
    stream_id               BIGINT NOT NULL REFERENCES streams(stream_id),
    stream_version          BIGINT NOT NULL,   -- this event's position in THIS stream
    original_stream_id      BIGINT NOT NULL,
    original_stream_version BIGINT NOT NULL,
    PRIMARY KEY (event_id, stream_id)
);
CREATE INDEX ix_stream_events_stream_version ON stream_events (stream_id, stream_version);
```

Important: there is a `BEFORE UPDATE` trigger (`prevent_mutation`) on `events` and
`stream_events`, but **not** on `streams`. Soft-delete and undelete already issue plain
`UPDATE streams SET deleted_at = ...`, so the `UPDATE streams SET truncate_before = ...`
this plan adds is permitted with no GUC and no trigger changes. (Confirmed: the
`protect_deletion` / `protect_truncation` triggers gate `DELETE`/`TRUNCATE` only; they do
not touch `UPDATE`.)

### How migrations are embedded and applied

`kiroku-store-migrations/kiroku-store-migrations.cabal` declares `data-files:
sql-migrations/*.sql`, and `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` embeds
the entire `sql-migrations/` directory at compile time with `file-embed`. **Adding a new
timestamped `.sql` file to that directory is all that is needed** — it is picked up
automatically on the next build. The bootstrap migration's own header says: "Future schema
changes add new timestamped SQL files in this directory instead of changing kiroku-store."
Migrations are applied with the `kiroku-store-migrate` executable; the `justfile` `migrate`
recipe runs it. Tests apply migrations automatically (see below).

### The read path (current)

`kiroku-store/src/Kiroku/Store/SQL.hs` holds the SQL. The two per-stream ordered reads are:

```sql
-- readStreamForwardSQL
SELECT e.event_id, e.event_type, se.stream_version, 0::bigint AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id, e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1 AND deleted_at IS NULL)
  AND se.stream_version > $2        -- $2 = exclusive start cursor; 0 returns from the first event
ORDER BY se.stream_version ASC
LIMIT $3;

-- readStreamBackwardSQL: same, but  se.stream_version < $2  ORDER BY ... DESC
```

These are wrapped by `readStreamForwardStmt` / `readStreamBackwardStmt`, dispatched from
the `ReadStreamForward` / `ReadStreamBackward` arms of the interpreter in
`kiroku-store/src/Kiroku/Store/Effect.hs` (around lines 180–190), and exposed as
`readStreamForward` / `readStreamBackward` in `kiroku-store/src/Kiroku/Store/Read.hs`. The
paged helper `readStreamForwardStream` in `Read.hs` repeatedly invokes `ReadStreamForward`,
so fixing `readStreamForwardSQL` fixes paging too — verify this during M3.

The global reads `readAllForwardSQL` / `readAllBackwardSQL` (over `stream_id = 0`) and
`readCategoryForwardSQL` must be left untouched (see Decision Log).

### The lifecycle API (current)

`kiroku-store/src/Kiroku/Store/Lifecycle.hs` exports `softDeleteStream`, `hardDeleteStream`,
`undeleteStream`, each a one-liner that `send`s a `Store` effect constructor defined in
`kiroku-store/src/Kiroku/Store/Effect.hs`. The constructors `SoftDeleteStream`,
`HardDeleteStream`, `UndeleteStream` each take a `StreamName` and return `Maybe StreamId`.
The soft-delete interpreter arm (Effect.hs ~line 295) is the template to copy:

```haskell
SoftDeleteStream (StreamName name) -> do
    rejectInvalidApplicationStream name          -- rejects $all with ReservedStreamName
    usePool (store ^. #pool) $
        Session.statement name SQL.softDeleteStreamStmt
```

`softDeleteStreamStmt` (SQL.hs ~line 912) returns `Maybe StreamId`:

```haskell
softDeleteStreamStmt :: Statement Text (Maybe StreamId)
softDeleteStreamStmt =
    preparable
        softDeleteStreamSQL
        (E.param (E.nonNullable E.text))
        (D.rowMaybe (StreamId <$> D.column (D.nonNullable D.int8)))
```

`StreamVersion` is `newtype StreamVersion = StreamVersion Int64` in
`kiroku-store/src/Kiroku/Store/Types.hs` (line 82). `validateStreamName`
(`kiroku-store/src/Kiroku/Store/Error.hs:148`) returns `Left (ReservedStreamName ...)` for
`$all`; `rejectInvalidApplicationStream` in `Effect.hs` wraps it.

### How tests work

Tests live in `kiroku-store/test/`. `kiroku-store/test/Test/Helpers.hs` provides
`withTestStore :: (KirokuStore -> IO ()) -> IO ()`, which spins up an ephemeral PostgreSQL
database (via `ephemeral-pg`), **applies all embedded migrations automatically**, and hands
back a live `KirokuStore` handle. There is no manual migration step in tests. `Helpers`
also exposes `makeEvent :: Text -> Value -> EventData` and `countEvents :: KirokuStore ->
IO Int64` (a raw `SELECT count(*) FROM events`). `kiroku-store/test/Main.hs` is the hspec
entry point that lists every test module. `kiroku-store/test/Test/ReadStream.hs` is a good
pattern reference for reading-oriented tests.


## Plan of Work

The work is additive and proceeds in four milestones, each independently verifiable. The
first milestone changes only schema/metadata (no behavior change), so it is safe to land
alone. Each later milestone builds on the previous.

### Milestone 1 — Schema column and metadata exposure

Scope: add the `truncate_before` column to `streams` (default `0`, meaning "no
truncation") and surface it on the `StreamInfo` record returned by `getStream`. At the end
of M1, `getStream name` returns a `StreamInfo` whose new `truncateBefore` field is `0` for
every existing stream, and the migration applies cleanly and idempotently. No read or write
behavior changes yet.

Work:

1. Create `kiroku-store-migrations/sql-migrations/2026-06-24-00-00-00-stream-truncate-before.sql`:

   ```sql
   -- Logical truncate-before marker for close-the-book compaction
   -- (ExecPlan docs/plans/65). Per-stream cursor: ordered stream reads return
   -- only events whose stream_version >= truncate_before. Default 0 keeps all
   -- events (per-stream versions are 1-based). Reversible; the global $all log
   -- is never affected. UPDATE on streams is already permitted (soft-delete
   -- uses it), so no trigger/GUC changes are needed.
   ALTER TABLE kiroku.streams
       ADD COLUMN IF NOT EXISTS truncate_before BIGINT NOT NULL DEFAULT 0;
   ```

   `ADD COLUMN IF NOT EXISTS` makes re-application a no-op (idempotent).

2. In `kiroku-store/src/Kiroku/Store/Types.hs`, add a field to `StreamInfo` (currently 5
   fields, after `deletedAt`):

   ```haskell
   , truncateBefore :: !StreamVersion
   -- ^ The logical truncate-before marker. Ordered per-stream reads
   -- ('Kiroku.Store.Read.readStreamForward' / 'readStreamBackward') return only
   -- events whose per-stream version is >= this value. 0 (the default) keeps the
   -- whole stream. Does not affect the $all global log, category reads, or
   -- subscriptions. Set with 'Kiroku.Store.Lifecycle.setStreamTruncateBefore'.
   ```

3. In `kiroku-store/src/Kiroku/Store/SQL.hs`, update `streamInfoRow` (the comment says "5
   columns" — change to 6) to decode the new trailing column:

   ```haskell
   streamInfoRow :: D.Row StreamInfo
   streamInfoRow =
       StreamInfo
           <$> (StreamId <$> D.column (D.nonNullable D.int8))
           <*> (StreamName <$> D.column (D.nonNullable D.text))
           <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
           <*> D.column (D.nonNullable D.timestamptz)
           <*> D.column (D.nullable D.timestamptz)
           <*> (StreamVersion <$> D.column (D.nonNullable D.int8))   -- truncate_before
   ```

   And add the column to `getStreamSQL`:

   ```sql
   SELECT stream_id, stream_name, stream_version, created_at, deleted_at, truncate_before
   FROM streams
   WHERE stream_name = $1
   ```

   Search SQL.hs for any *other* consumer of `streamInfoRow` (e.g. a list-streams
   statement) and add `truncate_before` to those `SELECT`s too, in the same trailing
   position, so the decoder column count matches every query that uses it.

Acceptance: `just migrate` applies the new file; a test (added in M4, but verifiable
manually) shows `getStream` returns `truncateBefore = StreamVersion 0` for a freshly
created stream. Build is green: `cabal build kiroku-store kiroku-store-migrations`.

### Milestone 2 — Write API: set and clear the marker

Scope: add the effect, interpreter arm, SQL statement, and the two public functions that
let a caller set and clear the marker. At the end of M2, `setStreamTruncateBefore name V`
updates the column and returns `Just streamId` (or `Nothing` for a missing/soft-deleted
stream, `ReservedStreamName` error for `$all`), and `getStream` reflects the new value.
Reads still ignore the marker until M3.

Work:

1. In `kiroku-store/src/Kiroku/Store/Effect.hs`, add a constructor to the `Store` GADT
   alongside the lifecycle constructors (near lines 115–117):

   ```haskell
   SetStreamTruncateBefore :: StreamName -> StreamVersion -> Store m (Maybe StreamId)
   ```

2. Add `setStreamTruncateBeforeStmt` to `kiroku-store/src/Kiroku/Store/SQL.hs` (in the
   Lifecycle Statements section near `softDeleteStreamStmt`, and add it to the module export
   list):

   ```haskell
   -- | Set a stream's logical truncate-before marker. Returns Nothing if the
   -- stream does not exist or is soft-deleted.
   setStreamTruncateBeforeStmt :: Statement (Text, Int64) (Maybe StreamId)
   setStreamTruncateBeforeStmt =
       preparable
           """
           UPDATE streams
           SET truncate_before = $2
           WHERE stream_name = $1 AND deleted_at IS NULL
           RETURNING stream_id
           """
           (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int8)))
           (D.rowMaybe (StreamId <$> D.column (D.nonNullable D.int8)))
   ```

   (`contrazip2` is the two-parameter encoder combinator already used elsewhere in SQL.hs,
   e.g. `eventExistsInStreamStmt`. Filtering `deleted_at IS NULL` makes a soft-deleted
   stream return `Nothing`, matching the established lifecycle semantics.)

3. Add the interpreter arm in `kiroku-store/src/Kiroku/Store/Effect.hs`, modeled on the
   `SoftDeleteStream` arm:

   ```haskell
   SetStreamTruncateBefore (StreamName name) (StreamVersion v) -> do
       rejectInvalidApplicationStream name
       usePool (store ^. #pool) $
           Session.statement (name, v) SQL.setStreamTruncateBeforeStmt
   ```

4. In `kiroku-store/src/Kiroku/Store/Lifecycle.hs`, export and define the public functions
   (add both to the module export list):

   ```haskell
   {- | Set the logical truncate-before marker for a stream. After this call,
   'Kiroku.Store.Read.readStreamForward' and 'readStreamBackward' return only the
   events whose per-stream version is >= @before@; earlier events are hidden from
   ordered stream reads but are NOT deleted.

   This is the close-the-book / snapshot-and-compact primitive: append a snapshot
   event (it lands at version @V@), then call @setStreamTruncateBefore name V@ so
   rehydration starts from the snapshot.

   The marker does NOT affect the @$all@ global log, 'Kiroku.Store.Read.readCategory',
   subscriptions, or existence probes — the global history stays complete, so
   projections (including ones not yet written) can still be built from it. The
   operation is fully reversible: lower the marker or call
   'clearStreamTruncateBefore' to re-expose hidden events.

   Returns @Just streamId@ on success, @Nothing@ if the stream does not exist or is
   soft-deleted. The reserved stream @$all@ is rejected with
   'Kiroku.Store.Error.ReservedStreamName'. Per-stream versions are 1-based, so a
   @before@ of 0 or 1 keeps the whole stream. Idempotent: setting the same value
   again returns the same result and changes nothing.
   -}
   setStreamTruncateBefore ::
       (HasCallStack, Store :> es) =>
       StreamName ->
       StreamVersion ->
       Eff es (Maybe StreamId)
   setStreamTruncateBefore name before = send (SetStreamTruncateBefore name before)

   {- | Clear a stream's truncate-before marker, re-exposing the full history to
   ordered stream reads. Equivalent to @setStreamTruncateBefore name 0@. Returns
   @Just streamId@ on success, @Nothing@ for a missing or soft-deleted stream.
   Rejects @$all@ with 'Kiroku.Store.Error.ReservedStreamName'.
   -}
   clearStreamTruncateBefore ::
       (HasCallStack, Store :> es) =>
       StreamName ->
       Eff es (Maybe StreamId)
   clearStreamTruncateBefore name = setStreamTruncateBefore name (StreamVersion 0)
   ```

   If `Kiroku.Store` (the umbrella module `kiroku-store/src/Kiroku/Store.hs`) re-exports the
   lifecycle functions, add the two new names there as well so consumers importing
   `Kiroku.Store` see them.

Acceptance: build green; a manual or M4 test shows `setStreamTruncateBefore name (StreamVersion 3)`
returns `Just _`, `getStream name` then reports `truncateBefore = StreamVersion 3`, setting
on a non-existent stream returns `Nothing`, and on `$all` raises `ReservedStreamName`.

### Milestone 3 — Read-path enforcement

Scope: make the per-stream ordered reads honor the marker. At the end of M3, after setting
the marker, `readStreamForward` / `readStreamBackward` (and the paged
`readStreamForwardStream`) return only the kept suffix, while all global read paths are
unchanged.

Work:

1. Rewrite `readStreamForwardSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs` to join
   `streams` (so the marker is available cheaply) and add the keep predicate:

   ```sql
   SELECT e.event_id, e.event_type, se.stream_version, 0::bigint AS global_position,
          se.original_stream_id, se.original_stream_version,
          e.data, e.metadata, e.causation_id, e.correlation_id, e.created_at
   FROM stream_events se
   JOIN events e  ON e.event_id  = se.event_id
   JOIN streams s ON s.stream_id = se.stream_id
   WHERE s.stream_name = $1
     AND s.deleted_at IS NULL
     AND se.stream_version > $2
     AND se.stream_version >= s.truncate_before
   ORDER BY se.stream_version ASC
   LIMIT $3
   ```

   The join to `streams` is by primary key (`stream_id`), and the existing
   `ix_stream_events_stream_version` index on `(stream_id, stream_version)` still serves the
   range scan, so the plan is unchanged in shape. The encoder (`readStreamEncoder`,
   `(Text, Int64, Int32)`) and result decoder are unchanged.

2. Apply the symmetric change to `readStreamBackwardSQL` (keep `se.stream_version < $2`,
   add `AND se.stream_version >= s.truncate_before`, `ORDER BY se.stream_version DESC`).

3. Confirm `readStreamForwardStream` in `kiroku-store/src/Kiroku/Store/Read.hs` is built on
   `ReadStreamForward` (it is, per Context) so paging inherits the filter automatically.
   Add a paging test in M4 to prove it.

4. Do **not** modify `readAllForwardSQL`, `readAllBackwardSQL`, `readCategoryForwardSQL`,
   `readCategoryForwardConsumerGroupStmt`, `readAllForwardConsumerGroupStmt`, the causation/
   correlation finders, or `eventExistsInStreamStmt`. These intentionally ignore the marker
   (see Decision Log). Leave a one-line comment near `readAllForwardSQL` noting that the
   global log deliberately ignores `truncate_before`.

Acceptance: the M4 tests below pass — per-stream reads return the suffix, global reads
return full history, `countEvents` is unchanged.

### Milestone 4 — Tests and documentation

Scope: a behavior-complete test suite plus doc updates. This is where the feature is
*proven*, per the spec's "validation is not optional" rule.

1. Create `kiroku-store/test/Test/TruncateBefore.hs` (hspec, using `withTestStore` from
   `Test/Helpers.hs`). Cover, at minimum:

   - **Bounded read**: append 5 events to `preference-abc` (versions 1..5), then a 6th
     "snapshot" event (version 6); `setStreamTruncateBefore "preference-abc" (StreamVersion 6)`
     returns `Just _`; `readStreamForward "preference-abc" 0 100` returns exactly the
     version-6 event; `readStreamBackward` likewise.
   - **Global log intact (the key distinguishing test)**: after the truncate,
     `readAllForward 0 1000` still returns all 6 events for that stream, and `readCategory`
     for category `preference` still returns all 6. `countEvents store` equals the
     pre-truncate count (nothing physically deleted).
   - **Reversibility**: `clearStreamTruncateBefore "preference-abc"` (or set back to 1) →
     `readStreamForward` again returns all 6.
   - **Idempotence**: calling `setStreamTruncateBefore name (StreamVersion 6)` twice returns
     `Just _` both times and the read result is identical.
   - **Paging**: with a marker set, `readStreamForwardStream` yields only the suffix across
     page boundaries (use a small page size).
   - **Metadata**: `getStream name` reports the current `truncateBefore`.
   - **Missing/soft-deleted**: `setStreamTruncateBefore "does-not-exist" v` returns
     `Nothing`; after `softDeleteStream`, it returns `Nothing`.
   - **Reserved name**: `setStreamTruncateBefore "$all" v` raises `ReservedStreamName`
     (assert via the `Error StoreError` channel, as other lifecycle tests do).

2. Register the module in `kiroku-store/test/Main.hs` (add the `import` and the `describe`/
   `spec` call following the existing pattern for, e.g., `Test.ReadStream`).

3. Documentation: add a short "Close-the-book compaction" section to the relevant user
   guide (search `docs/` for the snapshot/scaling discussion — `docs/SCALING-ANALYSIS.md`
   already describes Marten's snapshot-and-compact and `docs/DESIGN.md` lists "snapshotting
   for long-lived aggregates" as a roadmap item; cross-reference this feature there and in
   `docs/guides/` if a lifecycle guide exists). Explain the three-step usage and emphasize
   that it is logical and reversible.

4. Annotate the source feature request `docs/feature-requests/0001-version-bounded-prefix-truncate.md`:
   add a short note at the top recording that it was resolved by ExecPlan
   `docs/plans/65-logical-truncate-before-for-close-the-book-compaction.md` with a *logical*
   marker (not the proposed physical delete), and that physical reclamation is deferred.

Acceptance: `cabal test all` (or nix test path) green, with `Test.TruncateBefore` listed and
passing.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
unless noted.

1. Create the migration file (M1):

   ```bash
   $EDITOR kiroku-store-migrations/sql-migrations/2026-06-24-00-00-00-stream-truncate-before.sql
   ```

2. Edit the Haskell sources per the Plan of Work (M1–M3), then build:

   ```bash
   cabal build kiroku-store kiroku-store-migrations
   ```

   Expected: compiles with no errors. A common error if you miss a `streamInfoRow`
   consumer is a Hasql row-decoder/column-count mismatch at runtime — fix by adding
   `truncate_before` to that query's `SELECT`.

3. Apply migrations to a local database to sanity-check the SQL (M1). The `justfile`
   `migrate` recipe runs the `kiroku-store-migrate` executable against the configured
   database:

   ```bash
   just migrate
   ```

   Expected: the new `2026-06-24-...` migration is reported applied. Re-running is a no-op
   thanks to `ADD COLUMN IF NOT EXISTS` and codd's run-tracking.

4. Write and run the tests (M4):

   ```bash
   cabal test all
   ```

   Expected: hspec output lists `TruncateBefore` with all examples passing, e.g.:

   ```text
   TruncateBefore
     bounds per-stream reads to the kept suffix [✔]
     leaves the $all global log and category reads intact [✔]
     is reversible via clearStreamTruncateBefore [✔]
     is idempotent [✔]
     applies across paged reads [✔]
     reflects the marker in getStream [✔]
     returns Nothing for missing/soft-deleted streams [✔]
     rejects $all with ReservedStreamName [✔]
   ```

   If the project's `nix build`/test path is preferred over `cabal` (see the test-only
   dependency note in repo memory about `ephemeral-pg`/`wai-app-static` and the cabal flag),
   use that instead; the test expectations are identical.

Real execution notes (2026-06-24):

- `cabal build kiroku-store kiroku-store-migrations` — green (library + migrations + all
  test suites compiled and linked).
- `cabal test kiroku-store-test --test-options='--match "/TruncateBefore/"'` — 8 examples,
  0 failures.
- `cabal test all` — `kiroku-store-test` 234/234 and `kiroku-store-migrations-test` 1/1
  passed.
- `just migrate` was **not** run: the developer cluster's port 5432 is held by another local
  service, and the project-local `.pg` cluster cannot bind it. The migration is instead
  validated by the test path (ephemeral-pg applies every embedded migration before each
  test, idempotently and repeatably). The generic-plan `EXPLAIN` check was run against a
  throwaway ephemeral PostgreSQL seeded to mirror the real schema (see Surprises &
  Discoveries).


## Validation and Acceptance

The feature is accepted when a human can observe the following with the new test suite and
a scratch program:

- After `setStreamTruncateBefore name V`, `readStreamForward name 0 100` returns only
  events with per-stream version `>= V`, and the rehydrated aggregate (folding the returned
  events) equals the rehydration computed before truncation from the snapshot onward.
- `readAllForward 0 N` and `readCategory` still return the truncated prefix — the global
  log is complete — and `countEvents` is unchanged, proving the prefix was hidden, not
  deleted. **This is the property that distinguishes this design from a physical delete and
  is the single most important acceptance check.**
- `clearStreamTruncateBefore name` re-exposes the full history to `readStreamForward`.
- Setting the marker twice with the same value is a no-op with identical read results
  (idempotent and crash-safe to retry).
- `getStream name` reports the current `truncateBefore`.
- `setStreamTruncateBefore "$all" v` raises `ReservedStreamName`; a missing or soft-deleted
  stream returns `Nothing`.

All of the above are encoded as assertions in `kiroku-store/test/Test/TruncateBefore.hs`;
acceptance is `cabal test all` green with that module passing.


## Performance Considerations

This feature is designed to avoid regressions on kiroku's benchmarked hot paths. Confirm
each of these during implementation:

- **Append path: unchanged.** No new round-trips or work are added to appends.
  `setStreamTruncateBefore` is a separate, infrequent call. This matters because append
  latency in this project is dominated by round-trip count.
- **`$all`, category, and subscription reads: unchanged by design.** The marker is not
  applied to any global read path, so the `$all` read cost (which this project is sensitive
  to) is untouched.
- **Migration: metadata-only.** `ADD COLUMN ... NOT NULL DEFAULT 0` with a *constant*
  default is a metadata-only operation in PostgreSQL 11+ (no table rewrite), so it is
  instant even on a large `streams` table.
- **Write (`setStreamTruncateBefore`): a single HOT-eligible UPDATE** of one `streams` row
  by the unique `stream_name` index. The `streams` table is already updated on every append
  (`stream_version`) and on soft-delete (`deleted_at`), with a tuned fillfactor; a rare
  truncate-marker update is negligible.
- **Per-stream read: the one path that changes — verify with `EXPLAIN`.** The rewritten
  `readStreamForwardSQL`/`readStreamBackwardSQL` replace the scalar `stream_id` subquery
  with a `JOIN streams`, so the number of `streams` accesses is unchanged (one, by unique
  index). In the expected nested-loop plan, the outer `streams` row binds `truncate_before`
  before the inner index scan, so both `stream_version > $2` and `stream_version >=
  truncate_before` are pushed as index lower bounds on `ix_stream_events_stream_version` —
  meaning a set marker makes the read *faster* (seeks past the hidden prefix), not slower.
  The only risk is the planner choosing a non-nested-loop join, which would demote
  `truncate_before` to a post-scan filter (no worse than today, just no speedup). Because
  these are prepared (generic-plan) statements, run `EXPLAIN (ANALYZE, BUFFERS)` on the
  rewritten read against a seeded table to confirm the generic plan keeps the index-bound
  nested loop. If it does not, fall back to the plan-stable alternative: keep the existing
  `stream_id` subquery and add `truncate_before` as a *second* non-correlated scalar
  subquery (evaluated once as an InitPlan constant, reliably usable as an index bound) —
  identical query structure to today at the cost of one extra cached index lookup.


## Idempotence and Recovery

- The migration uses `ADD COLUMN IF NOT EXISTS`, so applying it more than once is safe; codd
  also records applied migrations and skips them.
- `setStreamTruncateBefore` is naturally idempotent: it writes an absolute value, so
  re-running with the same argument leaves the column unchanged and returns the same result.
  This makes the close-the-book sequence (append snapshot, then set marker) safe to retry
  after a crash between the two steps — re-issuing the set is harmless.
- Because the operation never deletes data, there is no destructive step to recover from. A
  wrong marker value is corrected by calling `setStreamTruncateBefore`/`clearStreamTruncateBefore`
  again; the hidden events are still present and reappear immediately.
- All edits are additive (new column with a default, new functions, augmented `SELECT`s).
  Reverting the code restores prior behavior; the column can remain in place harmlessly
  (default `0` = no truncation) if a rollback is needed without a down-migration.


## Interfaces and Dependencies

No new external libraries. The change touches existing packages `kiroku-store` and
`kiroku-store-migrations` and uses the in-repo Hasql wrappers already present in
`Kiroku.Store.SQL`.

Signatures that must exist at completion:

- `kiroku-store/src/Kiroku/Store/Types.hs` — `StreamInfo` gains
  `truncateBefore :: !StreamVersion`.
- `kiroku-store/src/Kiroku/Store/Effect.hs` — new constructor
  `SetStreamTruncateBefore :: StreamName -> StreamVersion -> Store m (Maybe StreamId)`
  and its interpreter arm.
- `kiroku-store/src/Kiroku/Store/SQL.hs` —
  `setStreamTruncateBeforeStmt :: Statement (Text, Int64) (Maybe StreamId)`; updated
  `streamInfoRow`, `getStreamSQL`, `readStreamForwardSQL`, `readStreamBackwardSQL`.
- `kiroku-store/src/Kiroku/Store/Lifecycle.hs` —
  `setStreamTruncateBefore :: (HasCallStack, Store :> es) => StreamName -> StreamVersion -> Eff es (Maybe StreamId)`
  and
  `clearStreamTruncateBefore :: (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)`.
- `kiroku-store-migrations/sql-migrations/2026-06-24-00-00-00-stream-truncate-before.sql` —
  the `ADD COLUMN` migration.
- `kiroku-store/test/Test/TruncateBefore.hs` — registered in `kiroku-store/test/Main.hs`.

Out of scope (deferred to a possible Phase 2, separate ExecPlan): physical reclamation of
the hidden prefix from the `events`/`stream_events` tables ("scavenge"), and any
subscription-frontier guard that such physical deletion would require.


## Revision Notes

- 2026-06-24: Added a "Performance Considerations" section and a corresponding `EXPLAIN`
  validation item to Progress. Reason: a review question asked whether the read-path
  rewrite (adding a `JOIN streams` and the `stream_version >= truncate_before` predicate to
  `readStreamForwardSQL`/`readStreamBackwardSQL`) risks a regression. The analysis concludes
  the change is neutral-to-positive (same number of `streams` accesses as today; the marker
  is pushable as an index lower bound under the expected nested-loop plan) and that the
  append and `$all`/category/subscription paths are untouched, but it records the generic
  prepared-statement plan as the one thing to verify with `EXPLAIN`, plus a plan-stable
  scalar-subquery fallback.
