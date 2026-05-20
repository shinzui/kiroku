---
id: 28
slug: consumer-group-partition-routing-sql-and-checkpoint-schema
title: "Consumer-Group Partition Routing SQL and Checkpoint Schema"
kind: exec-plan
created_at: 2026-05-20T03:19:43Z
intention: "intention_01ks1npgpye4xvcczxvzjsq232"
master_plan: "docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md"
---

# Consumer-Group Partition Routing SQL and Checkpoint Schema

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. A **subscription** is a long-running
consumer that reads events in order — either every event in the store (the
global `$all` stream) or every event in one **category** (the family of streams
whose name shares a prefix, for example all `acct-*` streams) — and feeds them to
a handler. Today a subscription is a single sequential worker, so it cannot be
spread across threads or processes; one slow handler caps throughput.

The broader initiative this plan belongs to (recorded in
`docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`)
introduces **consumer groups**: a named set of `N` cooperating workers
("members") that together process one subscription in parallel. Each source
stream is deterministically assigned to exactly one member, so all events of a
given stream are always handled by the same member in their original order.
Adding members increases parallelism without breaking per-stream ordering.

Define the terms once, in plain language, and reuse them throughout:

- **Consumer group**: a set of cooperating subscription workers that share one
  logical subscription (one category, or all of `$all`).
- **Member** (a.k.a. **member index**): one worker in the group, identified by a
  zero-based integer `m` in the range `0 .. size-1`.
- **Group size**: the total number of members, written `N` (or `size`). A group of
  size 1 is just an ordinary, non-partitioned subscription.
- **Partition key**: the value we hash to decide which member owns a stream. In
  this design the partition key is the **originating stream's surrogate id** — the
  `BIGINT` primary key `streams.stream_id` (equivalently
  `stream_events.original_stream_id`).

This plan (the data-layer foundation, called **EP-1** in the MasterPlan) delivers
two new capabilities entirely at the SQL and schema level, with no subscription
runtime:

1. **Partition-filtered reads.** Two new prepared statements that read a category
   (or all of `$all`) but return only the events whose originating stream is
   assigned to one member of a group of a given size.
2. **Per-member checkpoints.** The `subscriptions` table gains structured
   `(consumer_group_member, consumer_group_size)` columns and a composite unique
   key so each member can persist its own last-seen position, plus two new
   prepared statements that read and upsert those per-member checkpoints.

After this change, a developer can — using only raw SQL through the existing
connection pool — append events to many streams in one category, then call the
new category statement four times (`member = 0,1,2,3`, `size = 4`) and observe
that the four result sets are pairwise disjoint, that their union is exactly the
unpartitioned category read, and that every event of any single stream lands in
exactly one member's slice in ascending global-position order. The same holds for
`$all`. They can also write a checkpoint for `(name, member)` and read it back
independently of other members, while the pre-existing name-only checkpoint
behavior keeps working unchanged. All of this is provable by an automated test
suite (`cabal test kiroku-store`) with no subscription worker involved. The
runtime that consumes these statements is the next plan, **EP-2**
(`docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`),
which is out of scope here.


## Progress

This is the only checklist in the plan. Keep it synchronized with reality; split a
task into "done" and "remaining" at every stopping point.

- [x] M1 (2026-05-20): Add `readCategoryForwardConsumerGroupStmt` to
      `kiroku-store/src/Kiroku/Store/SQL.hs` (SQL body + 5-tuple encoder + export)
      and expose `Kiroku.Store.SQL` from the library so tests can import it.
- [x] M1 (2026-05-20): Add `kiroku-store/test/Test/ConsumerGroupSql.hs` with the assignment-rule
      property tests for the category path (disjointness, completeness,
      per-stream affinity, determinism, `size = 1` equivalence) and a `runMemberOf`
      helper that calls PostgreSQL's `member_of` expression directly.
- [x] M1 (2026-05-20): Register `Test.ConsumerGroupSql` in the `kiroku-store-test` `other-modules`
      and wire `ConsumerGroupSql.spec` into `kiroku-store/test/Main.hs`. Build green,
      `cabal test kiroku-store` green (135 examples, 0 failures).
- [ ] M2: Extend the `subscriptions` table in `kiroku-store/sql/schema.sql` with the
      two columns, the dropped inline `UNIQUE`, the idempotent `ALTER`/`DROP
      CONSTRAINT`/`CREATE UNIQUE INDEX` block, and verify `initializeSchema` applies
      it as a whole script.
- [ ] M2: Change the existing `saveCheckpointStmt` `ON CONFLICT` target in
      `kiroku-store/src/Kiroku/Store/SQL.hs` to the composite key, keeping its
      signature unchanged; add `getCheckpointMemberStmt` and
      `saveCheckpointMemberStmt` (with encoders + exports).
- [ ] M2: Add per-member checkpoint tests to `Test/ConsumerGroupSql.hs` and confirm
      existing subscription/checkpoint tests in `kiroku-store/test/Main.hs` still
      pass. Build green, `cabal test kiroku-store` green.
- [ ] M3: Add `readAllForwardConsumerGroupStmt` (SQL body + 4-tuple encoder +
      export) and the matching `$all` property tests in `Test/ConsumerGroupSql.hs`.
      Build green, `cabal test kiroku-store` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence (test output is ideal).

Findings from research while authoring this plan (no implementation yet):

- `Kiroku.Store.SQL` is an **internal** module — it sits under `other-modules` in
  the library stanza of `kiroku-store/kiroku-store.cabal`, not `exposed-modules`.
  No existing test imports it; the test suite instead rebuilds raw statements
  inline with `preparable` (see `countEvents` in
  `kiroku-store/test/Test/Helpers.hs`). Because this plan's whole point is to test
  the new prepared statements directly, the module must be moved to
  `exposed-modules`. Rebuilding each new statement inline in the test was
  considered and rejected: it would duplicate the IP-1 SQL (the very thing under
  test) and let the test drift from the shipped statement, defeating the purpose.

- `Kiroku.Store.Schema.initializeSchema` runs the embedded `sql/schema.sql` with
  `Hasql.Session.script` in a **single** call — `result <- Pool.use pool
  (Session.script schemaDDL)`. There is **no Haskell-side splitting on `;`**;
  PostgreSQL parses and executes the whole multi-statement string server-side. So
  the new `ALTER TABLE`, `DROP CONSTRAINT`, and `CREATE UNIQUE INDEX` statements
  added in M2 are simply appended to the file and execute in order — no risk of a
  naive split mangling them. (Contrast: if it had split on `;`, the plpgsql
  `uuidv7()` body, which contains semicolons, would already be broken — further
  confirmation it does not split.)

- PostgreSQL auto-names the inline `UNIQUE(subscription_name)` constraint
  `subscriptions_subscription_name_key`. That literal string appears **nowhere** in
  `kiroku-store/src/Kiroku/Store/Error.hs` (the only constraint names matched there
  are `events_pkey` and `ix_streams_stream_name`), so dropping it and adding the
  composite unique index does **not** affect any error mapping. No `Error.hs`
  change is needed.

- The `subscriptions` table is referenced only by `kiroku-store/sql/schema.sql`
  (definition) and `kiroku-store/src/Kiroku/Store/SQL.hs` (the two checkpoint
  statements). The benchmark programs under `kiroku-store/bench/` do not mirror or
  hand-roll the `subscriptions` schema — they go through `withStore` /
  `initializeSchema` like everything else (`grep` for `subscriptions` and
  `CREATE TABLE` across `kiroku-store/bench/` returns no schema mirror). The bench
  files are therefore out of scope and will not break.


## Decision Log

Record every decision made while working on the plan, with rationale and date.

- Decision: Hash the originating **stream's surrogate id** (`streams.stream_id`,
  rendered to text) as the partition key, not the stream **name**.
  Rationale: The surrogate id is already present with zero extra joins in both
  read paths — `s.stream_id` in the category query and `se.original_stream_id` in
  the `$all` query — so hashing it avoids a name-parse/category step and an extra
  `streams` join on the hot `$all` path, while giving identical per-stream
  affinity (every event of one stream shares one originating stream id). This
  matches the MasterPlan IP-1 contract.
  Date: 2026-05-20

- Decision: Normalize the hash into `[0, size)` with the double-mod
  `(((h % size) + size) % size)` rather than `MOD` alone or `abs(h) % size`.
  Rationale: PostgreSQL's `hashtextextended` returns a signed `bigint` that can be
  negative, and `%` in PostgreSQL keeps the sign of the dividend, so `h % size`
  can be negative — an invalid member index. Adding `size` then taking `% size`
  folds negatives into `[0, size)`. `abs()` is wrong because `abs(min_bigint)`
  overflows (the most-negative `bigint` has no positive counterpart) and raises an
  error. This matches the MasterPlan IP-1 contract.
  Date: 2026-05-20

- Decision: Use PostgreSQL-native `hashtextextended(text, bigint)` as the hash.
  Rationale: It is SQL-callable, well-distributed, and the same hash family
  PostgreSQL uses for declarative HASH partitioning — zero maintenance versus a
  custom MurmurHash (no native implementation) or md5 (heavier). Its output is
  documented as stable only within one installation/major version, but that is
  benign here because every member re-derives the assignment at query time on the
  same cluster; EP-4 documents the cross-version caveat for operators who upgrade.
  Date: 2026-05-20

- Decision: Apply the `subscriptions` schema change idempotently inside the
  existing embedded `kiroku-store/sql/schema.sql`, rather than extract a
  `kiroku-migrate` package now.
  Rationale: The change is small and additive and expresses cleanly as
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` plus a guarded constraint/index swap,
  so it fits the current re-runnable-schema approach. Extracting a migration tool
  remains the right long-term move (auto-memory `project_schema_migration.md` and
  the parked `docs/plans/partition-ready-schema.md`), but the MasterPlan
  explicitly defers it; this plan honors that decision.
  Date: 2026-05-20

- Decision: Change the existing `saveCheckpointStmt`'s `ON CONFLICT` target to the
  composite key `(subscription_name, consumer_group_member)` in the same milestone
  that swaps the constraint, while keeping its `Statement (Text, Int64) ()`
  signature unchanged.
  Rationale: Once the single-column `UNIQUE(subscription_name)` is dropped,
  `ON CONFLICT (subscription_name)` is no longer a valid conflict target and the
  statement would fail at runtime, breaking every current subscription/checkpoint
  test. The existing statement inserts with `consumer_group_member` defaulting to
  0, so the composite target is correct and behavior is preserved. Migrating the
  worker to the new member-aware statements is EP-2's job, not this plan's.
  Date: 2026-05-20

- Decision: Expose `Kiroku.Store.SQL` from the library (move it from
  `other-modules` to `exposed-modules`) so the new test module can import the new
  `Statement` values directly.
  Rationale: `Kiroku.Store.SQL` is currently an internal `other-module`, so a
  test in the separate `kiroku-store-test` component cannot import it. The cleanest
  way to test prepared statements "at the SQL level" — the explicit goal of this
  plan — is to run them through `Hasql.Pool.use (store ^. #pool)
  (Session.statement params SQL.<stmt>)`, which requires the module to be
  importable. Exposing it is additive and breaks nothing. See Surprises &
  Discoveries for why the alternative (rebuilding each statement inline in the
  test) was rejected.
  Date: 2026-05-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before editing.

### The storage model

Kiroku keeps events in three tables, defined in
`kiroku-store/sql/schema.sql`:

- **`streams`** — one row per stream. Columns relevant here: `stream_id BIGSERIAL`
  (the surrogate primary key — a machine-assigned integer id), `stream_name TEXT`,
  and a generated column `category TEXT GENERATED ALWAYS AS
  (split_part(stream_name, '-', 1)) STORED`. The **category** is therefore the
  part of the stream name before the first hyphen: `acct-1`, `acct-2`, ... all have
  category `acct`. There is one reserved row, `stream_id = 0`, named `$all`; its
  `stream_version` column doubles as the store-wide **global position** counter.

- **`events`** — one immutable row per event (`event_id`, `event_type`, `data`,
  `metadata`, `causation_id`, `correlation_id`, `created_at`). Stream membership is
  **not** stored here.

- **`stream_events`** — the junction (join) table. Every appended event gets at
  least two rows: one for its **source stream** (`stream_id = <the stream>`) and
  one for the global `$all` stream (`stream_id = 0`). On the `$all` row,
  `stream_version` is the event's global position, and `original_stream_id` records
  which real stream the event came from. Links (one event surfaced into another
  stream) add further rows but always carry the original stream's id in
  `original_stream_id`.

- **`subscriptions`** — checkpoint persistence. Today (before this plan) it has
  `subscription_id BIGSERIAL PRIMARY KEY`, `subscription_name TEXT NOT NULL UNIQUE`,
  `stream_name TEXT NOT NULL DEFAULT '$all'`, `last_seen BIGINT NOT NULL DEFAULT 0`,
  `created_at`, `updated_at`. The `last_seen` value is the global position the
  named subscription has processed up to.

### How reads are expressed today

All prepared statements live in `kiroku-store/src/Kiroku/Store/SQL.hs`. Each is a
`Hasql.Statement.Statement input output` built with the `preparable` helper from
`Hasql.Statement`, which takes `(sqlText, encoder, decoder)`. Encoders are
`Hasql.Encoders` values composed with the contravariant operator `>$<` (from
`Data.Functor.Contravariant`) and `E.param (E.nonNullable E.<type>)`; a multi-field
encoder is the monoidal sum (`<>`) of one `>$<`-projected param per field. The
relevant type→encoder mapping: a Haskell `Int32` uses `E.int4`, an `Int64` uses
`E.int8`, and `Text` uses `E.text`. Decoders are `Hasql.Decoders`; all the read
statements decode rows with the shared `recordedEventRow :: D.Row RecordedEvent`
(11 columns) wrapped in `D.rowVector` to return a `Vector RecordedEvent`.

Two existing read statements are the templates for this plan:

The **category read** `readCategoryForwardStmt :: Statement (Int64, Text, Int32)
(Vector RecordedEvent)` (params `(startPosition, category, limit)`) runs this SQL
(`readCategoryForwardSQL`):

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM streams s
JOIN LATERAL (
  SELECT se.*
  FROM stream_events se
  WHERE se.stream_id = 0
    AND se.original_stream_id = s.stream_id
    AND se.stream_version > $1
  ORDER BY se.stream_version ASC
  LIMIT $3
) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = $2
ORDER BY se.stream_version ASC
LIMIT $3
```

It selects category streams from `streams s`, then for each one laterally pulls
its `$all` junction rows (`stream_id = 0 AND original_stream_id = s.stream_id`)
with `stream_version > $startPosition` (global position is `stream_version` on the
`$all` row), joins `events`, and orders by global position. Its encoder is:

```haskell
readCategoryEncoder :: E.Params (Int64, Text, Int32)
readCategoryEncoder =
    ((\(a, _, _) -> a) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, b, _) -> b) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, c) -> c) >$< E.param (E.nonNullable E.int4))
```

The **`$all` read** `readAllForwardStmt :: Statement (Int64, Int32) (Vector
RecordedEvent)` (params `(startPosition, limit)`) runs `readAllForwardSQL`:

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.stream_version > $1
ORDER BY se.stream_version ASC
LIMIT $2
```

Its encoder is:

```haskell
readAllEncoder :: E.Params (Int64, Int32)
readAllEncoder =
    (fst >$< E.param (E.nonNullable E.int8))
        <> (snd >$< E.param (E.nonNullable E.int4))
```

### How checkpoints are expressed today

In the same file, the two checkpoint statements:

```haskell
getCheckpointStmt :: Statement Text (Maybe Int64)
saveCheckpointStmt :: Statement (Text, Int64) ()
```

`getCheckpointSQL` is `SELECT last_seen FROM subscriptions WHERE subscription_name
= $1`. `saveCheckpointSQL` is:

```sql
INSERT INTO subscriptions (subscription_name, last_seen, updated_at)
VALUES ($1, $2, now())
ON CONFLICT (subscription_name)
DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
```

The `GREATEST(...)` keeps a checkpoint monotonic: a save never moves `last_seen`
backward. The `ON CONFLICT (subscription_name)` clause names the conflict target,
which today is the single-column unique constraint on `subscription_name`.

### How the schema is applied

`kiroku-store/src/Kiroku/Store/Schema.hs` embeds the whole `sql/schema.sql` file
at compile time with Template Haskell's `embedFile`, and `initializeSchema` runs
it with **`Hasql.Session.script`** in one call:

```haskell
result <- Pool.use pool (Session.script schemaDDL)
```

`Session.script` sends the entire file to PostgreSQL as a single multi-statement
command string. **It does not split on `;` in Haskell** — PostgreSQL's simple
query protocol parses and executes all the statements server-side. This matters
for M2: the new `ALTER TABLE`, `DROP CONSTRAINT`, and `CREATE UNIQUE INDEX`
statements are just more semicolon-terminated statements in the file and will be
executed in order; there is no naive Haskell-side split that could mangle them.
`withStore` (in `kiroku-store/src/Kiroku/Store/Connection.hs`) calls
`initializeSchema` during acquire, so opening any store re-runs the whole script;
the script must therefore remain safe to run repeatedly (idempotent).

### Error mapping — does the constraint rename matter?

`kiroku-store/src/Kiroku/Store/Error.hs` maps PostgreSQL unique-violation
(`23505`) errors to `StoreError` values by matching constraint **names** in
`mapUniqueViolation`: it looks for `events_pkey` and `ix_streams_stream_name`.
PostgreSQL auto-names the inline `UNIQUE(subscription_name)` constraint
`subscriptions_subscription_name_key`. That name appears **nowhere** in
`Error.hs` (confirmed by reading the file), so dropping it and replacing it with a
named composite unique index does not affect any error mapping. No change to
`Error.hs` is required by this plan.

### Where the test suite lives

Tests are Hspec specs under `kiroku-store/test/`, listed in the
`kiroku-store-test` stanza of `kiroku-store/kiroku-store.cabal`
(`other-modules` plus `main-is: Main.hs`). `kiroku-store/test/Test/Helpers.hs`
provides the database fixture `withTestStore :: (KirokuStore -> IO ()) -> IO ()`,
which brackets a **fresh ephemeral PostgreSQL** instance per use (via the
`EphemeralPg` library, imported as `Pg`) and opens a `KirokuStore` whose schema is
auto-initialized. Each `it`/`around withTestStore` block thus gets a clean
database — there is no cross-test state to reset. `makeEvent :: Text -> Value ->
EventData` builds an event with an auto-generated id. Seeding is done with
`runStoreIO store $ appendToStream (StreamName "...") NoStream [events]`
(`runStoreIO` and `appendToStream` are re-exported from `Kiroku.Store`). Raw
prepared statements are run directly against the pool, exactly as `countEvents` in
`Helpers.hs` does:

```haskell
result <- Pool.use (store ^. #pool) (Session.statement () stmt)
```

This is the pattern the new tests use to call the new statements with explicit
tuples.

### The reserved `$all` row and the partition predicate

One subtlety the `$all` milestone (M3) must respect: `streams.stream_id = 0` is
the reserved `$all` row, and `stream_events` rows on the `$all` stream have
`original_stream_id` equal to the **real** originating stream (never 0 for normal
appends). The `$all` partition predicate is applied to `se.original_stream_id`
(the real stream), so the reserved id 0 never enters the hash for actual events.


## Plan of Work

The work is three milestones. Each ends with a green build and a green
`cabal test kiroku-store`. All file paths below are repository-relative.

### Milestone 1 — Category partition-filtered read + assignment-rule property tests

Scope: add the partition-filtered category read statement and prove the
assignment rule's mathematical properties at the SQL level. At the end of M1,
`kiroku-store/src/Kiroku/Store/SQL.hs` exports
`readCategoryForwardConsumerGroupStmt`, `Kiroku.Store.SQL` is an exposed library
module, and a new test module `kiroku-store/test/Test/ConsumerGroupSql.hs` proves
the rule is a true partition of one category.

The partition rule (MasterPlan IP-1, the single source of truth for "which member
owns a stream") is, for a group of size `N`:

```text
member_of(stream_id) = (((hashtextextended(stream_id::text, 0) % size) + size) % size)
```

A stream belongs to member `m` of a group of size `N` iff `member_of(stream_id) =
m`. `hashtextextended(text, bigint)` is PostgreSQL's native extended hash; the
second argument `0` is the seed. The result is a signed `bigint`, so `% size` may
be negative; `((h % N) + N) % N` folds it into `[0, N)`. With `N = 1` the
expression is always `0` (`((h % 1) + 1) % 1 = 0` for every `h`), so a size-1
group is exactly an unpartitioned read — an explicit test target.

Edits:

1. In `kiroku-store/src/Kiroku/Store/SQL.hs`, add to the module export list (the
   "Read statements" or a new "Consumer-group read statements" section)
   `readCategoryForwardConsumerGroupStmt`. Add the statement, its 5-tuple encoder,
   and its SQL body. The SQL mirrors `readCategoryForwardSQL` but adds the IP-1
   predicate on `s.stream_id` in the outer `WHERE`, so unassigned streams are
   pruned **before** the lateral join (cheaper than filtering rows afterward). The
   params are `(startPosition :: Int64, category :: Text, member :: Int32, size ::
   Int32, limit :: Int32)`, in that order, mapped to `$1..$5`. The decoder reuses
   `recordedEventRow` via `D.rowVector`. Concrete code is in Interfaces and
   Dependencies below.

2. In `kiroku-store/kiroku-store.cabal`, move `Kiroku.Store.SQL` from the library
   stanza's `other-modules` into its `exposed-modules` list. (It is currently the
   sole entry under `other-modules:`; replace that line by adding the module to
   `exposed-modules` and removing the now-empty `other-modules` field, or leave
   `other-modules:` with no entries — both build. Adding to `exposed-modules` is
   the load-bearing change.)

3. Create `kiroku-store/test/Test/ConsumerGroupSql.hs` exporting `spec :: Spec`.
   It seeds events into 50 streams of one category and tests the five properties
   for `size = 4`, plus the `size = 1` equivalence, plus determinism and a direct
   `member_of` helper. Full module text is in Validation and Acceptance.

4. In `kiroku-store/kiroku-store.cabal`, add `Test.ConsumerGroupSql` to the
   `kiroku-store-test` stanza's `other-modules`.

5. In `kiroku-store/test/Main.hs`, import `Test.ConsumerGroupSql qualified as
   ConsumerGroupSql` and call `ConsumerGroupSql.spec` at the top level of `main`'s
   `hspec $ do` block, alongside the other top-level specs such as
   `Properties.spec` (these specs bracket their own `withTestStore`, so they sit
   beside `Properties.spec`, not inside the shared `around withTestStore`).

Commands: `cabal build kiroku-store` then `cabal test kiroku-store`. Acceptance:
build succeeds; the new "ConsumerGroupSql / category partitioning" examples pass.

### Milestone 2 — `subscriptions` schema extension + per-member checkpoints + ON CONFLICT migration

Scope: extend the `subscriptions` table for per-member checkpoints, migrate the
existing `saveCheckpointStmt` to the new composite conflict target, and add the
member-aware checkpoint statements. At the end of M2, a fresh database and an
already-initialized one both converge to the new shape, all existing
subscription/checkpoint tests still pass, and new tests write and read per-member
checkpoints.

Edits:

1. In `kiroku-store/sql/schema.sql`, change the `CREATE TABLE IF NOT EXISTS
   subscriptions (...)` block (currently near line 101): add the two new columns
   to the column list and **remove** the inline `UNIQUE` on `subscription_name`
   (so a brand-new database does not create the auto-named single-column
   constraint). Immediately after the `CREATE TABLE` statement, add an idempotent
   convergence block:

   ```sql
   ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_member INT NOT NULL DEFAULT 0;
   ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_size   INT NOT NULL DEFAULT 1;
   ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_subscription_name_key;
   CREATE UNIQUE INDEX IF NOT EXISTS ix_subscriptions_name_member
       ON subscriptions (subscription_name, consumer_group_member);
   ```

   `subscriptions_subscription_name_key` is the name PostgreSQL auto-assigns the
   inline `UNIQUE(subscription_name)`; `DROP CONSTRAINT IF EXISTS` removes it on an
   existing database where it was previously created, and is a harmless no-op on a
   fresh database that never created it. The exact final SQL is in Interfaces and
   Dependencies.

2. In `kiroku-store/src/Kiroku/Store/SQL.hs`, change `saveCheckpointSQL`'s
   `ON CONFLICT (subscription_name)` to `ON CONFLICT (subscription_name,
   consumer_group_member)`. Keep `saveCheckpointStmt :: Statement (Text, Int64) ()`
   and `getCheckpointStmt :: Statement Text (Maybe Int64)` signatures unchanged;
   the existing insert leaves `consumer_group_member` at its column default 0, so
   the composite target resolves correctly.

3. In the same file, add `getCheckpointMemberStmt :: Statement (Text, Int32)
   (Maybe Int64)` and `saveCheckpointMemberStmt :: Statement (Text, Int32, Int64)
   ()`, with their encoders, SQL bodies, and exports. The save upserts on the
   composite key with the same `GREATEST(...)` monotonicity. Concrete code in
   Interfaces and Dependencies.

4. Add per-member checkpoint tests to `kiroku-store/test/Test/ConsumerGroupSql.hs`
   (a new `describe` block): write member 0 and member 1 checkpoints under the same
   subscription name, read each back independently, prove the monotonic
   `GREATEST` behavior, and prove that the existing name-keyed
   `saveCheckpointStmt`/`getCheckpointStmt` still round-trips (it now writes member
   0).

Commands: `cabal build kiroku-store` then `cabal test kiroku-store`. Acceptance:
build succeeds; the pre-existing `subscribe` checkpoint tests in
`kiroku-store/test/Main.hs` (e.g. "persists checkpoint and resumes from saved
position") still pass; the new per-member checkpoint examples pass.

### Milestone 3 — `$all` partition-filtered read + property tests

Scope: deliver the `$all` analogue of M1. At the end of M3,
`readAllForwardConsumerGroupStmt` exists and is exported, and the same partition
properties are proven for `$all`.

Edits:

1. In `kiroku-store/src/Kiroku/Store/SQL.hs`, add and export
   `readAllForwardConsumerGroupStmt :: Statement (Int64, Int32, Int32, Int32)
   (Vector RecordedEvent)` (params `(startPosition, member, size, limit)`), its
   4-tuple encoder, and its SQL body. The SQL mirrors `readAllForwardSQL` but adds
   the IP-1 predicate on `se.original_stream_id` (the real originating stream of
   each `$all` row). Concrete code in Interfaces and Dependencies.

2. Add an `$all` property `describe` block to
   `kiroku-store/test/Test/ConsumerGroupSql.hs` mirroring the category tests:
   append to streams in **several** categories (so `$all` spans more than one
   category), read each member's `$all` slice for `size = 4`, and assert pairwise
   disjointness, union-equals-`readAllForward 0 bigLimit`, per-stream affinity in
   ascending global position, and `size = 1` equivalence.

Commands: `cabal build kiroku-store` then `cabal test kiroku-store`. Acceptance:
build succeeds; the `$all` examples pass.


## Concrete Steps

Run all commands from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless noted. The toolchain
is Cabal; an ephemeral PostgreSQL is started automatically by the test fixture, so
no running database is required for `cabal test`.

### Step 0 — Baseline

```bash
cabal build kiroku-store
cabal test kiroku-store
```

Expected: a clean build and all current tests passing. This establishes the
"before" state so a later regression is attributable.

### Step 1 — M1 SQL change

Edit `kiroku-store/src/Kiroku/Store/SQL.hs`:

- Add `readCategoryForwardConsumerGroupStmt` to the export list under the
  `-- * Read statements` group.
- Add the statement, encoder, and SQL body (see Interfaces and Dependencies).

Edit `kiroku-store/kiroku-store.cabal`: move `Kiroku.Store.SQL` from the library's
`other-modules` to its `exposed-modules`.

```bash
cabal build kiroku-store
```

Expected output ends with a successful link, no errors. If you see
`Module ‘Kiroku.Store.SQL’ ... is not exposed`, the cabal move did not take.

### Step 2 — M1 test module

Create `kiroku-store/test/Test/ConsumerGroupSql.hs` (full text in Validation and
Acceptance). Add `Test.ConsumerGroupSql` to the `kiroku-store-test`
`other-modules` and wire `ConsumerGroupSql.spec` into `kiroku-store/test/Main.hs`.

```bash
cabal test kiroku-store
```

Expected transcript (abridged; exact event counts depend on the seed data):

```text
ConsumerGroupSql
  category consumer-group partitioning (size 4)
    splits a category into 4 pairwise-disjoint member slices [✔]
    union of all member slices equals the unpartitioned category read [✔]
    every stream's events go to exactly one member, in ascending global position [✔]
    member assignment is deterministic across repeated reads [✔]
    size 1 is equivalent to an unpartitioned category read [✔]
  member_of assignment rule
    returns a member index in [0, size) for every stream [✔]

Finished in N.NNNN seconds
NN examples, 0 failures
```

### Step 3 — M2 schema + checkpoint statements

Edit `kiroku-store/sql/schema.sql` (subscriptions block + idempotent ALTER block),
edit `kiroku-store/src/Kiroku/Store/SQL.hs` (`ON CONFLICT` change +
`getCheckpointMemberStmt`/`saveCheckpointMemberStmt` + exports), add the per-member
checkpoint tests to `Test/ConsumerGroupSql.hs`.

```bash
cabal build kiroku-store
cabal test kiroku-store
```

Expected: the existing `subscribe` checkpoint tests still pass and the new
per-member checkpoint block passes. A failure of "persists checkpoint and resumes
from saved position" means the `ON CONFLICT` migration was missed or the column
default is wrong.

### Step 4 — Verify the schema converges on an existing database (optional manual check)

`cabal test` always uses a fresh ephemeral database, which exercises the
fresh-database path. To additionally exercise the **existing-database** path
(prove the `ALTER`/`DROP CONSTRAINT`/`CREATE UNIQUE INDEX` block converges a
pre-existing single-column-unique table), use the local dev database wired into
the `Justfile`:

```bash
just reset-database   # drops, recreates, applies schema.sql once
just init-schema      # applies schema.sql a SECOND time — must be a clean no-op
```

Expected: the second `init-schema` prints no errors (every statement is guarded
by `IF NOT EXISTS` / `IF EXISTS` / `OR REPLACE` / `ON CONFLICT DO NOTHING`). To
simulate upgrading a database that predates this plan, manually recreate the old
shape and then apply the new schema:

```bash
psql -d kiroku -c "DROP INDEX IF EXISTS ix_subscriptions_name_member;"
psql -d kiroku -c "ALTER TABLE subscriptions DROP COLUMN IF EXISTS consumer_group_member;"
psql -d kiroku -c "ALTER TABLE subscriptions DROP COLUMN IF EXISTS consumer_group_size;"
psql -d kiroku -c "ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_subscription_name_key UNIQUE (subscription_name);"
just init-schema
psql -d kiroku -c "\d subscriptions"
```

Expected: the final `\d subscriptions` shows both new columns and a unique index
`ix_subscriptions_name_member` on `(subscription_name, consumer_group_member)`, and
no `subscriptions_subscription_name_key` constraint.

### Step 5 — M3 `$all` statement + tests

Edit `kiroku-store/src/Kiroku/Store/SQL.hs` (add
`readAllForwardConsumerGroupStmt`), add the `$all` property block to
`Test/ConsumerGroupSql.hs`.

```bash
cabal build kiroku-store
cabal test kiroku-store
```

Expected: an additional `$all consumer-group partitioning (size 4)` describe block
passes with the same four/five properties as the category block.


## Validation and Acceptance

Acceptance is behavioral: the new prepared statements, run against a freshly
seeded ephemeral PostgreSQL, must exhibit the partition properties, and the
checkpoint statements must round-trip per member. The test module below encodes
all of it. Create it at `kiroku-store/test/Test/ConsumerGroupSql.hs`. (M1 lands the
category and `member_of` blocks; M2 adds the checkpoint block; M3 adds the `$all`
block. The full file at completion is shown here so a novice can build it
incrementally and know the end state.)

```haskell
{-# LANGUAGE OverloadedStrings #-}

{- | SQL-level tests for consumer-group partition routing and per-member
checkpoints (ExecPlan 28 / EP-1). These exercise the new prepared statements in
"Kiroku.Store.SQL" directly through the connection pool, with no subscription
runtime, on a fresh ephemeral PostgreSQL per test.

Terms: a /consumer group/ of /size/ N has members 0..N-1; each source stream is
assigned to exactly one member by 'Kiroku.Store.SQL'-encoded hash routing. The
properties proven here — disjointness, completeness, per-stream affinity,
determinism, and size-1 equivalence — are the contract EP-2's runtime depends on.
-}
module Test.ConsumerGroupSql (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

-- | A generous limit that returns every seeded event in one read.
bigLimit :: Int32
bigLimit = 100000

-- | Run a statement against the store's pool, failing the test on a usage error.
runStmt :: KirokuStore -> Session.Session a -> IO a
runStmt store session = do
    result <- Pool.use (store ^. #pool) session
    case result of
        Left err -> error ("ConsumerGroupSql statement failed: " <> show err)
        Right a -> pure a

-- | Append one event to each of the named streams, seeding the store. Each
-- stream gets a single event; per-stream affinity is what we test, so one event
-- per stream is enough, but the helper appends 'n' events to vary versions.
seedStreams :: KirokuStore -> [Text] -> Int -> IO ()
seedStreams store names n =
    mapM_
        ( \name -> do
            let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. n]
            r <- runStoreIO store $ appendToStream (StreamName name) NoStream events
            case r of
                Left err -> error ("seed append failed for " <> T.unpack name <> ": " <> show err)
                Right _ -> pure ()
        )
        names

-- | Collect the event ids from a read result, in order.
eventIds :: Vector RecordedEvent -> [UUID]
eventIds = map (\e -> case e ^. #eventId of EventId u -> u) . V.toList

-- | Collect (originalStreamId, globalPosition) pairs from a read result.
streamPositions :: Vector RecordedEvent -> [(Int64, Int64)]
streamPositions =
    map
        ( \e ->
            ( case e ^. #originalStreamId of StreamId s -> s
            , case e ^. #globalPosition of GlobalPosition p -> p
            )
        )
        . V.toList

-- | Direct call to the partition rule for one stream id and size, returning the
-- member index PostgreSQL computes. Mirrors IP-1 exactly so the test pins the
-- formula, not just its consequences.
runMemberOf :: KirokuStore -> Int64 -> Int32 -> IO Int32
runMemberOf store streamId size = runStmt store (Session.statement (streamId, size) stmt)
  where
    stmt :: Statement (Int64, Int32) Int32
    stmt =
        preparable
            "SELECT (((hashtextextended($1::text, 0) % $2) + $2) % $2)::int4"
            ( (fst >$< E.param (E.nonNullable E.int8))
                <> (snd >$< E.param (E.nonNullable E.int4))
            )
            (D.singleRow (D.column (D.nonNullable D.int4)))

-- | All distinct (originalStreamId) values present in the unpartitioned read.
distinctStreamIds :: Vector RecordedEvent -> [Int64]
distinctStreamIds = Set.toList . Set.fromList . map fst . streamPositions

spec :: Spec
spec = do
    describe "ConsumerGroupSql" $ do
        categorySpec
        checkpointSpec
        allSpec
        memberOfSpec

-- ---------------------------------------------------------------------------
-- M1: category partitioning
-- ---------------------------------------------------------------------------

categorySpec :: Spec
categorySpec = around withTestStore $ do
    describe "category consumer-group partitioning (size 4)" $ do
        let cat = "acct"
            names = map (\i -> "acct-" <> T.pack (show i)) [1 .. 50 :: Int]
            size = 4 :: Int32

        let readMember store m =
                runStmt store $
                    Session.statement (0 :: Int64, cat, m, size, bigLimit) SQL.readCategoryForwardConsumerGroupStmt
            readFull store =
                runStmt store $
                    Session.statement (0 :: Int64, cat, bigLimit) SQL.readCategoryForwardStmt

        it "splits a category into 4 pairwise-disjoint member slices" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            let idSets = map (Set.fromList . eventIds) slices
            -- pairwise disjoint: union of sizes equals size of union
            let totalIds = sum (map Set.size idSets)
                unionIds = Set.size (Set.unions idSets)
            totalIds `shouldBe` unionIds

        it "union of all member slices equals the unpartitioned category read" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            full <- readFull store
            let unionIds = Set.unions (map (Set.fromList . eventIds) slices)
                fullIds = Set.fromList (eventIds full)
            unionIds `shouldBe` fullIds

        it "every stream's events go to exactly one member, in ascending global position" $ \store -> do
            seedStreams store names 3
            slices <- mapM (readMember store) [0 .. size - 1]
            -- For each member slice, every stream present must have all its events
            -- in ascending global position, and no stream may appear in two slices.
            let perMemberStreams = map (Set.fromList . map fst . streamPositions) slices
            -- per-stream affinity: stream sets are pairwise disjoint
            let totalStreams = sum (map Set.size perMemberStreams)
                unionStreams = Set.size (Set.unions perMemberStreams)
            totalStreams `shouldBe` unionStreams
            -- ascending global position within each slice
            mapM_
                ( \slice -> do
                    let ps = map snd (streamPositions slice)
                    ps `shouldBe` sort ps
                )
                slices

        it "member assignment is deterministic across repeated reads" $ \store -> do
            seedStreams store names 1
            firstReads <- mapM (\m -> eventIds <$> readMember store m) [0 .. size - 1]
            secondReads <- mapM (\m -> eventIds <$> readMember store m) [0 .. size - 1]
            firstReads `shouldBe` secondReads

        it "size 1 is equivalent to an unpartitioned category read" $ \store -> do
            seedStreams store names 2
            one <-
                runStmt store $
                    Session.statement (0 :: Int64, cat, 0 :: Int32, 1 :: Int32, bigLimit) SQL.readCategoryForwardConsumerGroupStmt
            full <- readFull store
            eventIds one `shouldBe` eventIds full

-- ---------------------------------------------------------------------------
-- M2: per-member checkpoints
-- ---------------------------------------------------------------------------

checkpointSpec :: Spec
checkpointSpec = around withTestStore $ do
    describe "per-member checkpoints" $ do
        let subName = "proj-acct" :: Text

        it "stores and reads independent checkpoints per member" $ \store -> do
            runStmt store $ Session.statement (subName, 0 :: Int32, 7 :: Int64) SQL.saveCheckpointMemberStmt
            runStmt store $ Session.statement (subName, 1 :: Int32, 13 :: Int64) SQL.saveCheckpointMemberStmt
            m0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            m1 <- runStmt store $ Session.statement (subName, 1 :: Int32) SQL.getCheckpointMemberStmt
            m0 `shouldBe` Just 7
            m1 `shouldBe` Just 13

        it "never moves a member checkpoint backward (GREATEST monotonicity)" $ \store -> do
            runStmt store $ Session.statement (subName, 0 :: Int32, 20 :: Int64) SQL.saveCheckpointMemberStmt
            runStmt store $ Session.statement (subName, 0 :: Int32, 5 :: Int64) SQL.saveCheckpointMemberStmt
            m0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            m0 `shouldBe` Just 20

        it "missing member checkpoint reads as Nothing" $ \store -> do
            m9 <- runStmt store $ Session.statement (subName, 9 :: Int32) SQL.getCheckpointMemberStmt
            m9 `shouldBe` Nothing

        it "the existing name-keyed checkpoint statements still round-trip (as member 0)" $ \store -> do
            runStmt store $ Session.statement (subName, 42 :: Int64) SQL.saveCheckpointStmt
            -- name-keyed read returns the same row (member 0)
            byName <- runStmt store $ Session.statement subName SQL.getCheckpointStmt
            byMember0 <- runStmt store $ Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt
            byName `shouldBe` Just 42
            byMember0 `shouldBe` Just 42

-- ---------------------------------------------------------------------------
-- M3: $all partitioning
-- ---------------------------------------------------------------------------

allSpec :: Spec
allSpec = around withTestStore $ do
    describe "$all consumer-group partitioning (size 4)" $ do
        -- $all spans several categories; partitioning is by originating stream.
        let names =
                concatMap
                    (\c -> map (\i -> c <> "-" <> T.pack (show i)) [1 .. 20 :: Int])
                    ["acct", "user", "order"]
            size = 4 :: Int32

        let readMember store m =
                runStmt store $
                    Session.statement (0 :: Int64, m, size, bigLimit) SQL.readAllForwardConsumerGroupStmt
            readFull store =
                runStmt store $
                    Session.statement (0 :: Int64, bigLimit) SQL.readAllForwardStmt

        it "splits $all into 4 pairwise-disjoint member slices" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            let idSets = map (Set.fromList . eventIds) slices
                totalIds = sum (map Set.size idSets)
                unionIds = Set.size (Set.unions idSets)
            totalIds `shouldBe` unionIds

        it "union of all member slices equals the unpartitioned $all read" $ \store -> do
            seedStreams store names 2
            slices <- mapM (readMember store) [0 .. size - 1]
            full <- readFull store
            let unionIds = Set.unions (map (Set.fromList . eventIds) slices)
                fullIds = Set.fromList (eventIds full)
            unionIds `shouldBe` fullIds

        it "every stream's events go to exactly one member, in ascending global position" $ \store -> do
            seedStreams store names 3
            slices <- mapM (readMember store) [0 .. size - 1]
            let perMemberStreams = map (Set.fromList . map fst . streamPositions) slices
                totalStreams = sum (map Set.size perMemberStreams)
                unionStreams = Set.size (Set.unions perMemberStreams)
            totalStreams `shouldBe` unionStreams
            mapM_
                ( \slice -> do
                    let ps = map snd (streamPositions slice)
                    ps `shouldBe` sort ps
                )
                slices

        it "size 1 is equivalent to an unpartitioned $all read" $ \store -> do
            seedStreams store names 2
            one <-
                runStmt store $
                    Session.statement (0 :: Int64, 0 :: Int32, 1 :: Int32, bigLimit) SQL.readAllForwardConsumerGroupStmt
            full <- readFull store
            eventIds one `shouldBe` eventIds full

-- ---------------------------------------------------------------------------
-- The partition rule, pinned directly.
-- ---------------------------------------------------------------------------

memberOfSpec :: Spec
memberOfSpec = around withTestStore $ do
    describe "member_of assignment rule" $ do
        it "returns a member index in [0, size) for every stream" $ \store -> do
            let names = map (\i -> "rule-" <> T.pack (show i)) [1 .. 30 :: Int]
            seedStreams store names 1
            full <- runStmt store $ Session.statement (0 :: Int64, bigLimit) SQL.readAllForwardStmt
            let sids = distinctStreamIds full
            mapM_
                ( \sid -> do
                    m <- runMemberOf store sid 4
                    m `shouldSatisfy` (\x -> x >= 0 && x < 4)
                )
                sids
```

Notes on the test design:

- The seed uses `appendToStream ... NoStream`, the public API, so the streams and
  their `$all` junction rows are created exactly as in production. The new
  statements then read them through the pool.
- `EventId`, `StreamId`, `GlobalPosition`, `RecordedEvent`, `StreamName`,
  `EventData`, `appendToStream`, `runStoreIO` are all re-exported from
  `Kiroku.Store`. The new statements come from `Kiroku.Store.SQL` (now exposed),
  imported `qualified as SQL`. `>$<` is re-exported transitively; if the build
  reports it is not in scope, add `import Data.Functor.Contravariant ((>$<))`.
- The disjointness property is proven the canonical way: a family of sets is
  pairwise disjoint iff the sum of their sizes equals the size of their union.
- Per-stream affinity is proven two ways: (1) the set of originating stream ids in
  each member slice are pairwise disjoint (no stream split across members), and (2)
  within each slice the global positions are already ascending (the statement's
  `ORDER BY`), so each stream's events keep their order.
- `runMemberOf` calls the IP-1 expression verbatim, pinning the formula itself so
  a future accidental change to the SQL predicate is caught even if the
  consequence-level properties happen to still hold.

Run the whole suite with either of:

```bash
cabal test kiroku-store
just test
```

Expected tail of a passing run:

```text
ConsumerGroupSql
  category consumer-group partitioning (size 4)
    splits a category into 4 pairwise-disjoint member slices [✔]
    union of all member slices equals the unpartitioned category read [✔]
    every stream's events go to exactly one member, in ascending global position [✔]
    member assignment is deterministic across repeated reads [✔]
    size 1 is equivalent to an unpartitioned category read [✔]
  per-member checkpoints
    stores and reads independent checkpoints per member [✔]
    never moves a member checkpoint backward (GREATEST monotonicity) [✔]
    missing member checkpoint reads as Nothing [✔]
    the existing name-keyed checkpoint statements still round-trip (as member 0) [✔]
  $all consumer-group partitioning (size 4)
    splits $all into 4 pairwise-disjoint member slices [✔]
    union of all member slices equals the unpartitioned $all read [✔]
    every stream's events go to exactly one member, in ascending global position [✔]
    size 1 is equivalent to an unpartitioned $all read [✔]
  member_of assignment rule
    returns a member index in [0, size) for every stream [✔]

Finished in N.NNNN seconds
NNN examples, 0 failures
```


## Idempotence and Recovery

The schema script is safe to re-run. `initializeSchema` runs the whole
`kiroku-store/sql/schema.sql` via `Hasql.Session.script` (one server-side
multi-statement command — no Haskell-side `;` splitting), and every statement is
guarded: `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`,
`ALTER TABLE ... DROP CONSTRAINT IF EXISTS`, `CREATE UNIQUE INDEX IF NOT EXISTS`,
`INSERT ... ON CONFLICT DO NOTHING`, and `CREATE OR REPLACE FUNCTION`. Re-running
on an already-converged database is a no-op; running on a database that predates
this plan converges it (drops the old auto-named single-column unique, adds the
columns and the composite index). The `CREATE UNIQUE INDEX` will fail only if the
existing `subscriptions` data already contains duplicate `(subscription_name,
consumer_group_member)` pairs — impossible on a database that came from the old
single-column-unique schema, because every old row has `consumer_group_member = 0`
and `subscription_name` was unique.

Tests are inherently idempotent: `withTestStore` provisions a brand-new ephemeral
PostgreSQL per use, so there is never stale state to clean up and a failed test
leaves nothing behind. Re-running `cabal test kiroku-store` always starts from a
clean database.

If a milestone half-lands (for example M1 SQL compiles but the cabal `exposed`
move was forgotten), the symptom is a test-compile error
`Could not load module ‘Kiroku.Store.SQL’ ... it is a hidden module`. The fix is
to complete the `exposed-modules` move; no data or schema is touched, so there is
nothing to roll back. The SQL and schema edits are additive and can be reverted
with `git checkout -- <file>` if needed.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Hasql.Statement` (`preparable`), `Hasql.Encoders` (`E`), `Hasql.Decoders` (`D`)
  — the prepared-statement, encoder, and decoder vocabulary already used
  throughout `kiroku-store/src/Kiroku/Store/SQL.hs`. New statements follow the same
  style: `Int32 -> E.int4`, `Int64 -> E.int8`, `Text -> E.text`, all
  `E.nonNullable`, composed with `>$<` and `<>`.
- `Hasql.Pool` (`Pool.use`) and `Hasql.Session` (`Session.statement`) — how the
  tests run the new statements against the live pool, identical to the existing
  raw-SQL helpers in `kiroku-store/test/Test/Helpers.hs`.
- `Data.Set` (containers, already a test dependency) and `Data.List.sort` — to
  express disjointness/union and ascending-order assertions in the tests.

These are the exact artifacts that must exist at the end of each milestone.

### End of M1

In `kiroku-store/src/Kiroku/Store/SQL.hs`, exported:

```haskell
readCategoryForwardConsumerGroupStmt
    :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)
```

Definition (mirrors `readCategoryForwardStmt`, params
`(startPosition, category, member, size, limit)` = `$1..$5`):

```haskell
readCategoryForwardConsumerGroupStmt
    :: Statement (Int64, Text, Int32, Int32, Int32) (Vector RecordedEvent)
readCategoryForwardConsumerGroupStmt =
    preparable
        readCategoryForwardConsumerGroupSQL
        readCategoryConsumerGroupEncoder
        (D.rowVector recordedEventRow)

readCategoryConsumerGroupEncoder :: E.Params (Int64, Text, Int32, Int32, Int32)
readCategoryConsumerGroupEncoder =
    ((\(a, _, _, _, _) -> a) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, b, _, _, _) -> b) >$< E.param (E.nonNullable E.text))
        <> ((\(_, _, c, _, _) -> c) >$< E.param (E.nonNullable E.int4))
        <> ((\(_, _, _, d, _) -> d) >$< E.param (E.nonNullable E.int4))
        <> ((\(_, _, _, _, e) -> e) >$< E.param (E.nonNullable E.int4))
```

SQL body (`$3` = member, `$4` = size; the IP-1 predicate is applied to
`s.stream_id` in the outer `WHERE`, pruning unassigned streams before the lateral
join; `$5` is the limit, used both inside the lateral subquery and in the outer
clause exactly as the original):

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM streams s
JOIN LATERAL (
  SELECT se.*
  FROM stream_events se
  WHERE se.stream_id = 0
    AND se.original_stream_id = s.stream_id
    AND se.stream_version > $1
  ORDER BY se.stream_version ASC
  LIMIT $5
) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = $2
  AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3
ORDER BY se.stream_version ASC
LIMIT $5
```

In `kiroku-store/kiroku-store.cabal`, the library `exposed-modules` list now
includes `Kiroku.Store.SQL` (moved out of `other-modules`). In
`kiroku-store/test/Test/ConsumerGroupSql.hs`, `spec :: Spec` exists and is called
from `kiroku-store/test/Main.hs`. `Test.ConsumerGroupSql` is in the
`kiroku-store-test` `other-modules`.

### End of M2

In `kiroku-store/sql/schema.sql`, the `subscriptions` block is exactly:

```sql
-- Subscriptions (checkpoint persistence for subscription positions).
-- consumer_group_member / consumer_group_size carry static consumer-group
-- topology (ExecPlan 28 / EP-1). Non-group subscriptions are member 0, size 1.
-- The unique key is composite (subscription_name, consumer_group_member) so each
-- group member persists its own checkpoint under one shared subscription name.
CREATE TABLE IF NOT EXISTS subscriptions (
    subscription_id       BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    stream_name           TEXT         NOT NULL DEFAULT '$all',
    last_seen             BIGINT       NOT NULL DEFAULT 0,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    consumer_group_size   INT          NOT NULL DEFAULT 1,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Idempotent convergence for databases created before EP-1: add the columns if
-- missing, drop the old auto-named single-column unique constraint if present,
-- and install the composite unique index. All guarded so re-running schema.sql
-- (which initializeSchema does on every store open) is a safe no-op.
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_member INT NOT NULL DEFAULT 0;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_size   INT NOT NULL DEFAULT 1;
ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_subscription_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS ix_subscriptions_name_member
    ON subscriptions (subscription_name, consumer_group_member);
```

In `kiroku-store/src/Kiroku/Store/SQL.hs`, `saveCheckpointSQL`'s conflict target
is changed:

```sql
INSERT INTO subscriptions (subscription_name, last_seen, updated_at)
VALUES ($1, $2, now())
ON CONFLICT (subscription_name, consumer_group_member)
DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
```

`getCheckpointStmt :: Statement Text (Maybe Int64)` and `saveCheckpointStmt ::
Statement (Text, Int64) ()` keep their signatures. Two new statements are added
and exported:

```haskell
getCheckpointMemberStmt :: Statement (Text, Int32) (Maybe Int64)
getCheckpointMemberStmt =
    preparable
        getCheckpointMemberSQL
        ( (fst >$< E.param (E.nonNullable E.text))
            <> (snd >$< E.param (E.nonNullable E.int4))
        )
        (D.rowMaybe (D.column (D.nonNullable D.int8)))

saveCheckpointMemberStmt :: Statement (Text, Int32, Int64) ()
saveCheckpointMemberStmt =
    preparable
        saveCheckpointMemberSQL
        ( ((\(a, _, _) -> a) >$< E.param (E.nonNullable E.text))
            <> ((\(_, b, _) -> b) >$< E.param (E.nonNullable E.int4))
            <> ((\(_, _, c) -> c) >$< E.param (E.nonNullable E.int8))
        )
        D.noResult

getCheckpointMemberSQL :: Text
getCheckpointMemberSQL =
    """
    SELECT last_seen
    FROM subscriptions
    WHERE subscription_name = $1
      AND consumer_group_member = $2
    """

saveCheckpointMemberSQL :: Text
saveCheckpointMemberSQL =
    """
    INSERT INTO subscriptions (subscription_name, consumer_group_member, last_seen, updated_at)
    VALUES ($1, $2, $3, now())
    ON CONFLICT (subscription_name, consumer_group_member)
    DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now()
    """
```

(Use the `MultilineStrings` triple-quote literal style already enabled at the top
of `SQL.hs` for the SQL bodies.)

### End of M3

In `kiroku-store/src/Kiroku/Store/SQL.hs`, exported:

```haskell
readAllForwardConsumerGroupStmt
    :: Statement (Int64, Int32, Int32, Int32) (Vector RecordedEvent)
readAllForwardConsumerGroupStmt =
    preparable
        readAllForwardConsumerGroupSQL
        readAllConsumerGroupEncoder
        (D.rowVector recordedEventRow)

readAllConsumerGroupEncoder :: E.Params (Int64, Int32, Int32, Int32)
readAllConsumerGroupEncoder =
    ((\(a, _, _, _) -> a) >$< E.param (E.nonNullable E.int8))
        <> ((\(_, b, _, _) -> b) >$< E.param (E.nonNullable E.int4))
        <> ((\(_, _, c, _) -> c) >$< E.param (E.nonNullable E.int4))
        <> ((\(_, _, _, d) -> d) >$< E.param (E.nonNullable E.int4))
```

SQL body (params `(startPosition, member, size, limit)` = `$1..$4`; the IP-1
predicate is applied to `se.original_stream_id`, the real originating stream of
each `$all` junction row):

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.stream_version > $1
  AND (((hashtextextended(se.original_stream_id::text, 0) % $3) + $3) % $3) = $2
ORDER BY se.stream_version ASC
LIMIT $4
```

### Cross-plan contract (do not drift)

These signatures and SQL expressions are consumed verbatim by EP-2
(`docs/plans/29-consumer-group-subscription-runtime-and-per-member-workers.md`).
EP-2's worker swaps `readCategoryForwardStmt`/`readAllForwardStmt` for the
consumer-group variants and `getCheckpointStmt`/`saveCheckpointStmt` for the
member-aware variants when a group is configured; the decoder shape (`Vector
RecordedEvent`) is unchanged, so EP-2 touches no decoding code. The partition
expression `(((hashtextextended(<id>::text, 0) % size) + size) % size)` is the
MasterPlan IP-1 single source of truth — keep it byte-identical in both read
statements and in the test's `runMemberOf` helper.


## Revision History

- 2026-05-20: Initial authoring of the full plan from the skeleton, per
  MasterPlan 4 and IP-1..IP-3. Recorded the discovery that `Kiroku.Store.SQL` is
  an internal `other-module` and must be exposed for SQL-level tests, that
  `initializeSchema` uses `Hasql.Session.script` (no Haskell-side `;` splitting,
  so the new ALTER/CREATE statements run as-is), and that the auto-named
  `subscriptions_subscription_name_key` constraint is not referenced by
  `Kiroku.Store.Error`, so the constraint swap needs no error-mapping change.
