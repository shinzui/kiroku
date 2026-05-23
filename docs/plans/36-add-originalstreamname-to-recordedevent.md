---
id: 36
slug: add-originalstreamname-to-recordedevent
title: "Add originalStreamName to RecordedEvent"
kind: exec-plan
created_at: 2026-05-23T00:27:20Z
intention: "intention_01ks93jge0eart0cyw9kttg4zf"
---


# Add originalStreamName to RecordedEvent

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL event store. When you read events, you get back a value of type
`RecordedEvent`. Today that value tells you which *database surrogate id* the event came
from (a meaningless `Int64` called `originalStreamId`) but **not** the human-readable
stream name (e.g. `"orders-42"`). For a single-stream read this does not matter, because
you already passed the stream name in. But for every *fan-in* read — the global `$all`
stream, a category, a causation/correlation graph query, and most importantly a
**subscription** — the events come from many different streams, and you only get the
surrogate id. There is no public API anywhere in Kiroku to turn that surrogate id back
into a stream name (the only lookups, `lookupStreamId` and `getStream`, go the other
direction: name → id). So a consumer that needs to know "which order did this event
belong to?" is stuck writing its own raw SQL against the internal `streams` table.

After this change, every `RecordedEvent` carries a new field, `originalStreamName ::
StreamName`, holding the human-readable name of the stream the event was *first appended
to*. A developer processing a subscription over the `orders` category can read
`event ^. #originalStreamName` and immediately get back `StreamName "orders-42"` — no
extra round-trip, no internal SQL, no id→name cache to maintain.

You can see it working at the end with a focused test that appends to two differently
named streams, reads them back through the `$all` stream (which mixes both), and asserts
that each returned event reports the correct originating stream name — including the
tricky case of a *linked* event, where the name must be the source stream, not the link
target. The test fails before the change (the field does not exist) and passes after.

Concretely, the acceptance command is:

```bash
cabal test kiroku-store
```

which runs the whole store suite against an ephemeral PostgreSQL instance (started
automatically; no external database needed) and must report `0 failures`, including the
new `originalStreamName` assertions.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — field plumbing (type, decoder, all read SQL, test stubs); project compiles and the existing suite stays green: **DONE 2026-05-23.**

- [x] Add `originalStreamName :: !StreamName` to the `RecordedEvent` record in `kiroku-store/src/Kiroku/Store/Types.hs`, positioned immediately after `originalStreamId`, with a Haddock comment. (2026-05-23)
- [x] Update the shared decoder `recordedEventRow` in `kiroku-store/src/Kiroku/Store/SQL.hs` to decode one extra `text` column in the matching position (now a 12-column row). (2026-05-23)
- [x] Add the originating stream name to all 10 read SQL templates in `kiroku-store/src/Kiroku/Store/SQL.hs` (8 got a new `JOIN streams os ON os.stream_id = se.original_stream_id`; the 2 category templates already joined `streams s` and only needed the column added to the `SELECT`). Verified 10 occurrences of `AS original_stream_name`; the link lateral at line 717 correctly untouched. (2026-05-23)
- [x] Fix the two test stubs that build a `RecordedEvent` by hand (`kiroku-otel/test/Main.hs` — also added `StreamName (..)` to its import list — and `shibuya-kiroku-adapter/test/Main.hs`). (2026-05-23)
- [x] Confirm the whole workspace compiles and the existing suites pass with no behavioral change to existing tests. `cabal build all` clean; `kiroku-store` 154 examples / 0 failures; `kiroku-otel` 6/0; `shibuya-kiroku-adapter` 8/0. (2026-05-23)

Milestone 2 — behavioral proof and documentation:

- [ ] Add a focused test asserting `originalStreamName` for `$all` reads, category reads, and a *linked* event (source-stream semantics).
- [ ] Update the `RecordedEvent` Haddock prose in `Types.hs` to describe the new field's source-stream semantics under linking.
- [ ] Add a CHANGELOG entry under `## Unreleased` in `kiroku-store/CHANGELOG.md`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The hard-delete cascade makes an INNER JOIN to `streams` on `original_stream_id`
  provably safe (no dropped rows). `deleteStreamJunctionsStmt` in
  `kiroku-store/src/Kiroku/Store/SQL.hs` deletes every junction row where
  `stream_id = $1 OR original_stream_id = $1`:

  ```sql
  DELETE FROM stream_events
  WHERE stream_id = $1
     OR original_stream_id = $1
  ```

  So when a stream is hard-deleted, every `$all` junction row and every cross-stream
  *link* row that pointed at it via `original_stream_id` is removed in the same
  transaction. No surviving `stream_events` row can therefore reference a
  hard-deleted (absent) `streams` row through `original_stream_id`. Soft-deleted
  streams keep their `streams` row (only `deleted_at` is set), so they also resolve.
  This is why we can use a plain `JOIN` (inner) rather than a `LEFT JOIN` with a
  fallback — confirmed against the schema in `kiroku-store/sql/schema.sql` where
  `stream_events.original_stream_id` is `BIGINT NOT NULL` with **no** foreign key,
  meaning the database does not enforce this for us; the cascade does.

(Add further discoveries here as implementation proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Add a denormalized `originalStreamName` field to `RecordedEvent` rather than
  a separate id→name lookup API.
  Rationale: Subscriptions and `$all`/category reads — the dominant consumers — almost
  always need the source stream name, so a lookup API just forces every consumer to build
  the same id→name cache. A field eliminates the friction at the point of use and matches
  the prevailing event-store convention (EventStoreDB's `RecordedEvent` carries
  `eventStreamId`, the stream name). The cost is one indexed primary-key join to
  `streams` on the fan-in read paths — not an extra round-trip — and prior benchmarking
  in this repo (docs/plans/21–23) established that round-trip count, not SQL shape,
  dominates Hasql read latency, so a PK nested-loop join sits in the noise.
  Date: 2026-05-23

- Decision: The field holds the *original* (source) stream name, paired with the existing
  `originalStreamId`, not the name of the stream being read.
  Rationale: For ordinary reads the two coincide. For a *linked* event (an event appended
  to stream A and later linked into stream B via `linkToStream`), the consumer wants to
  know where the event actually originated (its aggregate identity, which survives
  linking). This mirrors the existing `originalStreamId` / `originalVersion` field
  semantics documented on `RecordedEvent`, and matches EventStoreDB, whose
  `eventStreamId` resolves to the origin stream for linked events. The name therefore
  follows `original_stream_id`, not the stream the read targeted.
  Date: 2026-05-23

- Decision: Use a plain (inner) `JOIN streams ON streams.stream_id = se.original_stream_id`
  on the read paths that do not already join `streams`.
  Rationale: See the hard-delete cascade discovery above — every surviving junction row's
  `original_stream_id` references a live `streams` row, so an inner join never drops a row
  that would otherwise be returned. An inner join is also the cheapest form and lets the
  planner use the `streams` primary key.
  Date: 2026-05-23

- Decision: Place the new field/column immediately after `originalStreamId`
  (record position 6, SQL column 6), shifting `originalVersion` to position 7.
  Rationale: Keeps the origin triple (`originalStreamId`, `originalStreamName`,
  `originalVersion`) adjacent and self-documenting, and the Hasql row decoder is
  positional, so the record field order, the decoder order, and every `SELECT` column
  order must agree — grouping them reduces the chance of a mismatch.
  Date: 2026-05-23

- Decision: Scope is `RecordedEvent` only; do not touch `AppendResult` or `StreamInfo`.
  Rationale: The friction reported is purely on the read/subscription side. `AppendResult`
  callers already know the stream name they appended to. Keeping scope tight minimizes the
  blast radius of this breaking change.
  Date: 2026-05-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kiroku stores events in three PostgreSQL tables, defined in
`kiroku-store/sql/schema.sql`:

- `streams` — one row per stream. Columns: `stream_id BIGSERIAL PRIMARY KEY`,
  `stream_name TEXT NOT NULL` (unique), `category TEXT` (a generated column equal to the
  text before the first `-`), `stream_version BIGINT`, `created_at`, `deleted_at`.
  `stream_id = 0` is a reserved seed row named `$all`.
- `events` — one row per event payload: `event_id UUID PRIMARY KEY`, `event_type`,
  `causation_id`, `correlation_id`, `data JSONB`, `metadata JSONB`, `created_at`.
- `stream_events` — the junction table tying events to streams. Columns: `event_id`,
  `stream_id` (which stream this row places the event in; `0` means the global `$all`
  stream), `stream_version` (position within that stream), `original_stream_id` and
  `original_stream_version` (the stream and position where the event was *first*
  appended). Each appended event gets at least two junction rows: one in its source
  stream and one in `$all`. Linking an event into another stream adds one more row whose
  `stream_id` is the link target but whose `original_stream_id` still points at the
  source. Note that `original_stream_id` is `BIGINT NOT NULL` with **no** foreign-key
  constraint to `streams`.

The Haskell types live in `kiroku-store/src/Kiroku/Store/Types.hs`. The relevant ones:

- `newtype StreamName = StreamName Text` — the human-readable name.
- `newtype StreamId = StreamId Int64` — the surrogate id; the type's Haddock already
  states it is "Not generally used by application code — prefer `StreamName` for
  identification," which is exactly the gap this plan closes for read results.
- `data RecordedEvent` — what every read returns. Its current fields, in order, are:
  `eventId`, `eventType`, `streamVersion`, `globalPosition`, `originalStreamId`,
  `originalVersion`, `payload`, `metadata`, `causationId`, `correlationId`, `createdAt`.
  Its Haddock already explains the source-vs-linked distinction for `streamVersion`,
  `originalVersion`, and `originalStreamId`.

How a `RecordedEvent` is built: there is exactly **one** production construction site, the
Hasql row decoder `recordedEventRow` in `kiroku-store/src/Kiroku/Store/SQL.hs` (around
line 366). "Hasql row decoder" means a small applicative value that pulls one column at a
time, in order, out of a returned database row; the order of the `<*>` chain must line up
with the order of columns in the `SELECT`. Every read statement reuses this one decoder,
so adding a field is a single decoder edit plus a matching column in each `SELECT`.

The read statements that return `Vector RecordedEvent` and therefore use
`recordedEventRow` are, all in `kiroku-store/src/Kiroku/Store/SQL.hs`:

1. `readStreamForwardStmt` / `readStreamForwardSQL`
2. `readStreamBackwardStmt` / `readStreamBackwardSQL`
3. `readAllForwardStmt` / `readAllForwardSQL`
4. `readAllBackwardStmt` / `readAllBackwardSQL`
5. `findByCorrelationStmt` / `findByCorrelationSQL`
6. `findCausationDescendantsStmt` / `findCausationDescendantsSQL`
7. `findCausationAncestorsStmt` / `findCausationAncestorsSQL`
8. `readCategoryForwardStmt` / `readCategoryForwardSQL` — **already joins `streams s`**
9. `readCategoryForwardConsumerGroupStmt` / `readCategoryForwardConsumerGroupSQL` —
   **already joins `streams s`**
10. `readAllForwardConsumerGroupStmt` / `readAllForwardConsumerGroupSQL`

Statements 8 and 9 already have `FROM streams s ... WHERE se.original_stream_id =
s.stream_id` (the category filter), so the originating stream name is already in scope as
`s.stream_name` — those two only need the column added to the `SELECT`. The other eight
need a new `JOIN streams ... ON ... = se.original_stream_id`.

Why this also fixes subscriptions: the subscription worker
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` does not have its own SQL. Around
lines 308–317 it dispatches `readAllForwardStmt`, `readCategoryForwardStmt`,
`readAllForwardConsumerGroupStmt`, and `readCategoryForwardConsumerGroupStmt` directly.
Because these are the same statements above, subscriptions inherit `originalStreamName`
automatically once the statements are updated — no separate change in the worker.

The effect-layer dispatch in `kiroku-store/src/Kiroku/Store/Effect.hs` (the `Store`
effect's `ReadStreamForward`, `ReadAllForward`, `ReadCategoryForward`, `FindEvents`, etc.)
also routes to these statements; it carries `Vector RecordedEvent` opaquely and needs no
change.

Two **test stubs** build a `RecordedEvent` with explicit record syntax and will fail to
compile until the new field is supplied:

- `kiroku-otel/test/Main.hs`, function `mkStubRecorded` (around line 114).
- `shibuya-kiroku-adapter/test/Main.hs`, function `makeRecordedEvent` (around line 484).

No other production or test code constructs a `RecordedEvent` positionally; readers use
`generic-lens` labels (`event ^. #field`) or record-wildcard patterns (`RecordedEvent{..}`,
`RecordedEvent{metadata = ...}`), both of which keep compiling when a field is added. For
example `kiroku-otel/src/Kiroku/Otel/TraceContext.hs` matches `RecordedEvent{metadata =
Just (Object o)}` and is unaffected; `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/
Convert.hs` destructures only a few named fields and is unaffected.

The store test suite is hspec-based: `kiroku-store/test/Main.hs` (`main = hspec $ do ...`)
wires together the per-feature spec modules in `kiroku-store/test/Test/`. Tests use an
ephemeral PostgreSQL started in-process (no external DB needed). The existing
`kiroku-store/test/Test/ReadStream.hs` and `Test/Causation.hs` are good models for how a
test appends events and reads them back.

Term definitions used in this plan:

- "Fan-in read" — any read that returns events from more than one source stream: `$all`,
  category, causation/correlation, and subscriptions.
- "Linked event" — an event first appended to one stream and later added to another via
  `linkToStream` (see `kiroku-store/src/Kiroku/Store/Link.hs`). Reading the link target
  returns the event with `originalStreamId`/`originalVersion` pointing at the *source*.
- "Source / origin stream" — the stream an event was first appended to; the one
  `original_stream_id` names.


## Plan of Work

The work is a single conceptual change — surface one already-available datum — split into
two milestones so the first leaves the tree compiling and green and the second proves the
behavior and documents it.

### Milestone 1 — Field plumbing end to end

Scope: add the field to the type, decode it, select it in every read statement, and fix
the two hand-written test stubs. At the end the entire workspace compiles and the existing
test suites pass unchanged (no test asserts on the new field yet). Acceptance: `cabal
build all` succeeds and `cabal test kiroku-store` reports `0 failures`.

Step 1.1 — Type. In `kiroku-store/src/Kiroku/Store/Types.hs`, add the field to
`RecordedEvent` immediately after `originalStreamId`:

```haskell
    , originalStreamId :: !StreamId
    -- ^ The stream the event was first appended to.
    , originalStreamName :: !StreamName
    {- ^ The human-readable name of the stream the event was first appended
    to (the stream identified by @originalStreamId@). For events read from
    their source stream this is the stream you read; for events read from a
    /linked/ target stream it is the /source/ stream's name, not the target's.
    -}
    , originalVersion :: !StreamVersion
```

`StreamName` is already exported from this module and already in scope, so no import
changes are needed.

Step 1.2 — Decoder. In `kiroku-store/src/Kiroku/Store/SQL.hs`, update `recordedEventRow`.
It currently decodes 11 columns; add a `StreamName <$> D.column (D.nonNullable D.text)`
between the `originalStreamId` decode (the fifth, `StreamId <$> ...`) and the
`originalVersion` decode (the sixth, `StreamVersion <$> ...`). Also update the comment
from "11 columns" to "12 columns":

```haskell
-- | Shared decoder for a RecordedEvent row (12 columns).
recordedEventRow :: D.Row RecordedEvent
recordedEventRow =
    RecordedEvent
        <$> (EventId <$> D.column (D.nonNullable D.uuid))
        <*> (EventType <$> D.column (D.nonNullable D.text))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))
        <*> (StreamId <$> D.column (D.nonNullable D.int8))
        <*> (StreamName <$> D.column (D.nonNullable D.text))
        <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nullable D.uuid)
        <*> D.column (D.nonNullable D.timestamptz)
```

Step 1.3 — SQL templates that need a new join. For each of the eight templates listed
below, add the originating stream name to the `SELECT` list right after
`se.original_stream_id`, and add a join to `streams` on `original_stream_id`. The pattern
for the four simple `stream_events`-rooted reads (forward/backward stream, forward/backward
all) is identical. For example, `readAllForwardSQL` becomes:

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, os.stream_name AS original_stream_name,
       se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
JOIN streams os ON os.stream_id = se.original_stream_id
WHERE se.stream_id = 0
  AND se.stream_version > $1
ORDER BY se.stream_version ASC
LIMIT $2
```

Apply the same shape (`JOIN streams os ON os.stream_id = se.original_stream_id` plus
`os.stream_name AS original_stream_name` in the right `SELECT` position) to:

- `readStreamForwardSQL`
- `readStreamBackwardSQL`
- `readAllForwardSQL`
- `readAllBackwardSQL`
- `readAllForwardConsumerGroupSQL`

The three causation/correlation templates (`findByCorrelationSQL`,
`findCausationDescendantsSQL`, `findCausationAncestorsSQL`) already join `events e` and
`stream_events se`; add the same `JOIN streams os ON os.stream_id = se.original_stream_id`
and the `os.stream_name AS original_stream_name` column. For the two recursive-CTE
templates, the join goes in the final outer `SELECT` (the one after the `WITH RECURSIVE
chain ...` block), not inside the CTE.

Step 1.4 — SQL templates that already join `streams`. For `readCategoryForwardSQL` and
`readCategoryForwardConsumerGroupSQL`, the outer query is already `FROM streams s` with
the lateral join filtering `se.original_stream_id = s.stream_id`, so `s.stream_name` is the
originating name. Only add the column to the `SELECT`:

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, s.stream_name AS original_stream_name,
       se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM streams s
JOIN LATERAL ( ... ) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = $2
ORDER BY se.stream_version ASC
LIMIT $3
```

Step 1.5 — Test stubs. Add `originalStreamName = StreamName "..."` to the two hand-written
`RecordedEvent` literals. In `kiroku-otel/test/Main.hs` `mkStubRecorded`, insert after the
`originalStreamId = StreamId 1` line:

```haskell
        , originalStreamId = StreamId 1
        , originalStreamName = StreamName (T.pack "X")
        , originalVersion = StreamVersion 1
```

`StreamName` may need adding to that module's import list from `Kiroku.Store.Types`; check
the existing import and add it if absent. Apply the same insertion to
`shibuya-kiroku-adapter/test/Main.hs` `makeRecordedEvent` (use a literal like
`StreamName "trace-1"`), again confirming `StreamName` is imported.

### Milestone 2 — Behavioral proof and documentation

Scope: add a test that proves the field is correct for fan-in reads and for linked events,
update the `RecordedEvent` Haddock prose, and record a CHANGELOG entry. Acceptance: the new
test fails if you revert the SQL/decoder change and passes with it; `cabal test
kiroku-store` reports `0 failures`.

Step 2.1 — Test. Add a spec to the store suite. The simplest home is a new module
`kiroku-store/test/Test/OriginalStreamName.hs` wired into `kiroku-store/test/Main.hs`
alongside the other `Test.*` specs (follow the existing `import`/`describe` pattern there).
Export `spec :: Spec` and wrap the cases with `around withTestStore` so each `it` receives a
`KirokuStore` handle — `withTestStore` is provided by the `Test.Helpers` module the suite
already imports, and `kiroku-store/test/Test/ReadStream.hs` is a working template.
The test must, against the ephemeral store:

1. Append one event to `StreamName "orders-1"` and one to `StreamName "shipments-1"`.
2. Read the global stream via `readAllForward (GlobalPosition 0) 100` and assert that the
   event whose payload came from `orders-1` reports `originalStreamName == StreamName
   "orders-1"`, and likewise for `shipments-1`. This proves the `$all` path.
3. Read `readCategory (CategoryName "orders") (GlobalPosition 0) 100` and assert the
   returned event's `originalStreamName == StreamName "orders-1"`. This proves the category
   path.
4. Linked-event case: link the `orders-1` event into `StreamName "audit-1"` via
   `linkToStream`, then `readStreamForward (StreamName "audit-1") (StreamVersion 0) 100`
   and assert the linked event's `originalStreamName == StreamName "orders-1"` (the
   *source*, not `"audit-1"`). This proves source-stream semantics — the part most likely
   to regress.

Access fields with `generic-lens` labels (`evt ^. #originalStreamName`) to match house
style; `Control.Lens ((^.))` and `Data.Generics.Labels ()` are already used in the
codebase (see `kiroku-store/src/Kiroku/Store/Read.hs`).

Step 2.2 — Docs. In `kiroku-store/src/Kiroku/Store/Types.hs`, extend the `RecordedEvent`
type's leading Haddock block (the paragraph beginning "What comes back from reading
events.") with one sentence noting that `originalStreamName` accompanies `originalStreamId`
and always names the source stream, so linked-target reads still report where the event
originated.

Step 2.3 — CHANGELOG. Add an entry under `## Unreleased` in `kiroku-store/CHANGELOG.md`,
in the same style as the existing entries:

```markdown
### Added — `RecordedEvent.originalStreamName` (plan 36)

* `RecordedEvent` now carries `originalStreamName :: StreamName`, the
  human-readable name of the stream an event was first appended to. This
  removes the need to resolve `originalStreamId` (a surrogate id) back to a
  name when consuming fan-in reads — `$all`, categories, causation/correlation
  queries, and subscriptions — which previously had no public id→name lookup.
  For linked events the field reports the source stream, matching
  `originalStreamId`/`originalVersion`.
* Read statements that did not already join `streams` now add an indexed
  primary-key join on `original_stream_id`; no extra round-trips.

BREAKING: any code constructing `RecordedEvent` positionally or with a complete
record literal must supply the new field. Code reading fields via `generic-lens`
labels or record-wildcard patterns is unaffected.
```


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Build everything after the type/decoder/SQL edits and the stub fixes (Milestone 1):

```bash
cabal build all
```

Expected: a clean build. If you see an error like

```text
• Constructor ‘RecordedEvent’ does not have field ‘originalStreamName’
```

you edited a construction site before adding the field — do Step 1.1 first. If you see

```text
• Couldn't match type ... the type signature ... 12 columns
```

style decoder mismatches at runtime (a Hasql `RowError`/`UnexpectedAmountOfColumns`),
a `SELECT` column count does not match the decoder — recount the columns in the offending
template against the 12-column decoder.

Run the store suite (Milestone 1 keeps it green; Milestone 2 adds assertions):

```bash
cabal test kiroku-store
```

Expected tail:

```text
Finished in N.NNNN seconds
NN examples, 0 failures
```

Run the downstream suites whose stubs were touched:

```bash
cabal test kiroku-otel
cabal test shibuya-kiroku-adapter
```

Expected: `0 failures` for each.

To prove the new test actually exercises the change (Milestone 2), temporarily revert just
the SQL/decoder edits (e.g. `git stash` only `kiroku-store/src/Kiroku/Store/SQL.hs` and
`Types.hs`) and confirm the new spec fails to compile or fails its assertions, then restore.


## Validation and Acceptance

The change is internal (a new field on a read result), so acceptance is demonstrated by a
behavior a human can verify through the test suite rather than a UI.

Primary acceptance: after implementing both milestones,

```bash
cabal test kiroku-store
```

reports `0 failures`, and the new spec includes assertions equivalent to:

- An event appended to `orders-1` and read back via `readAllForward` has
  `originalStreamName == StreamName "orders-1"`.
- The same event read via `readCategory (CategoryName "orders") ...` has
  `originalStreamName == StreamName "orders-1"`.
- That event linked into `audit-1` and read via `readStreamForward (StreamName "audit-1")
  ...` reports `originalStreamName == StreamName "orders-1"` (source, not target).

Effectiveness beyond compilation: the linked-event assertion fails if anyone "simplifies"
the join to key off the read's stream name (`$1`) instead of `se.original_stream_id`, so it
guards the one subtle requirement. Reverting the SQL/decoder edits makes the new spec fail,
proving it exercises the new code path (see the last Concrete Step).

Regression safety: all pre-existing specs in `kiroku-store`, `kiroku-otel`, and
`shibuya-kiroku-adapter` must still pass, demonstrating the field addition did not change
existing read or subscription behavior.


## Idempotence and Recovery

All edits are ordinary source changes under version control and can be repeated safely. If
a build or test step fails midway, the working tree is never left in a damaging state — no
data migration or destructive database operation is involved. The store schema is
unchanged (no `sql/schema.sql` edit, no new migration): `original_stream_name` is computed
at read time by joining the existing `streams` table, so there is nothing to migrate and
no rollback beyond reverting source.

To start over cleanly, `git checkout -- kiroku-store kiroku-otel shibuya-kiroku-adapter`
restores the affected trees, then re-apply the steps. Re-running `cabal build all` and
`cabal test kiroku-store` is safe any number of times; the ephemeral PostgreSQL is created
fresh per run.


## Interfaces and Dependencies

No new libraries or services. The change uses facilities already present:

- `Kiroku.Store.Types` (`kiroku-store/src/Kiroku/Store/Types.hs`) — the `RecordedEvent`
  record gains the field; `StreamName` is already exported and used here.
- `hasql` decoders/encoders (`Hasql.Decoders` imported as `D` in
  `kiroku-store/src/Kiroku/Store/SQL.hs`) — `D.column (D.nonNullable D.text)` decodes the
  new column; this API is already used for every other text column.
- `generic-lens` / `Control.Lens` — used in the new test to read fields by label, matching
  existing usage in `kiroku-store/src/Kiroku/Store/Read.hs`.
- `hspec` — the new spec module follows the structure of existing modules under
  `kiroku-store/test/Test/`.

Signatures and shapes that must exist at the end of each milestone:

End of Milestone 1:

```haskell
-- kiroku-store/src/Kiroku/Store/Types.hs
data RecordedEvent = RecordedEvent
    { eventId            :: !EventId
    , eventType          :: !EventType
    , streamVersion      :: !StreamVersion
    , globalPosition     :: !GlobalPosition
    , originalStreamId   :: !StreamId
    , originalStreamName :: !StreamName   -- new
    , originalVersion    :: !StreamVersion
    , payload            :: !Value
    , metadata           :: !(Maybe Value)
    , causationId        :: !(Maybe UUID)
    , correlationId      :: !(Maybe UUID)
    , createdAt          :: !UTCTime
    }

-- kiroku-store/src/Kiroku/Store/SQL.hs
recordedEventRow :: D.Row RecordedEvent   -- now decodes 12 columns
```

All ten read statements continue to have their existing Haskell signatures (their result
type `Vector RecordedEvent` is unchanged); only their SQL text and the shared decoder
change. The `Store` effect constructors in `kiroku-store/src/Kiroku/Store/Effect.hs` and
the subscription worker in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` are
untouched and pick up the field transitively.

End of Milestone 2: a new spec module
`kiroku-store/test/Test/OriginalStreamName.hs` exporting `spec :: Spec` that uses `around
withTestStore` (the project convention — every module under `kiroku-store/test/Test/`
exports `spec :: Spec`; `withTestStore` comes from `Test.Helpers` and hands each `it` a
`KirokuStore`, as in `kiroku-store/test/Test/ReadStream.hs`), wired into
`kiroku-store/test/Main.hs` by adding `import Test.OriginalStreamName qualified as
OriginalStreamName` and an `OriginalStreamName.spec` line in `main`. Plus the CHANGELOG
entry and the expanded `RecordedEvent` Haddock.
