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

> **Outcome note (2026-05-23):** the title goal — adding an `originalStreamName`
> field to `RecordedEvent` — was implemented (Milestones 1–2), then **abandoned
> after benchmarking** in favour of a lookup API (Milestone 4). Returning the
> name on every read row was measured to cost ~13% on the `$all` subscription
> hot path, irrespective of whether the name came from a join (Milestone 1) or a
> denormalized column (Milestone 3); the cost is decoding/transferring the extra
> column itself. The shipped solution is instead
> `Kiroku.Store.Read.lookupStreamNames :: [StreamId] -> Eff es (Map StreamId
> StreamName)` (plus singular `lookupStreamName`), which resolves the surrogate
> `originalStreamId` that fan-in reads already carry, on demand, keeping the read
> hot path at baseline. The narrative below is preserved as the record of how we
> got there; see the Decision Log, Surprises & Discoveries, and Outcomes.

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

Milestone 2 — behavioral proof and documentation: **DONE 2026-05-23.**

- [x] Add a focused test asserting `originalStreamName` for `$all` reads, category reads, and a *linked* event (source-stream semantics). New module `kiroku-store/test/Test/OriginalStreamName.hs`, wired into `kiroku-store/test/Main.hs` and the cabal `other-modules`. 3 examples, 0 failures. (2026-05-23)
- [x] Update the `RecordedEvent` Haddock prose in `Types.hs` to describe the new field's source-stream semantics under linking. (2026-05-23)
- [x] Add a CHANGELOG entry under `## Unreleased` in `kiroku-store/CHANGELOG.md`. (2026-05-23)
- [x] Full store suite green with the new tests: `cabal test kiroku-store` → 157 examples, 0 failures (was 154). (2026-05-23)

Milestone 3 — denormalize the column to remove the read regression: **IMPLEMENTED THEN ABANDONED 2026-05-23.** All M3 edits were made and verified green, but the re-benchmark showed denormalization did *not* reduce the read cost (the cost is the returned column, not the join — see Surprises & Discoveries). M3 was reverted; nothing from M3 is committed. Items kept for the record:

- [x] (done, then reverted) `schema.sql` column + convergence block.
- [x] (done, then reverted) codd migration `2026-05-23-...-add-original-stream-name.sql`.
- [x] (done, then reverted) append/link writes and direct-column reads in `SQL.hs`; bench raw shapes.
- [x] (done) Re-benchmark — the decisive measurement that abandoned both the join and the column. Append path confirmed flat; reads confirmed ~13% over no-field regardless of approach.

Milestone 4 — revert the field entirely; ship an on-demand lookup API: **DONE 2026-05-23.**

- [x] Revert all of Milestones 1–3 to the pre-field state (`37e1aaa`): `RecordedEvent` loses `originalStreamName`; read/append SQL, decoder, schema, stubs, CHANGELOG, and the `Test.OriginalStreamName` module are removed. Verified `git diff 37e1aaa` is empty for all code dirs. (2026-05-23)
- [x] Add `LookupStreamNames :: [StreamId] -> Store m (Map StreamId StreamName)` to the `Store` effect (`Effect.hs`) + interpreter clause; `lookupStreamNamesStmt` in `SQL.hs` (`SELECT stream_id, stream_name FROM streams WHERE stream_id = ANY($1)`). (2026-05-23)
- [x] Surface `lookupStreamNames` and singular `lookupStreamName :: StreamId -> Eff es (Maybe StreamName)` from `Kiroku.Store.Read`, with Haddock and a discoverability pointer on `RecordedEvent.originalStreamId`. (2026-05-23)
- [x] New test module `Test.StreamNameLookup` (4 cases: `$all` round-trip, unknown id omitted, empty list, singular + unknown). Wired into `Main.hs` + cabal. (2026-05-23)
- [x] CHANGELOG entry describing the lookup API and why the field was rejected. (2026-05-23)
- [x] All suites green: `kiroku-store` 158/0 (154 base + 4 lookup), `kiroku-otel` 6/0, `shibuya-kiroku-adapter` 8/0, `kiroku-store-migrations` PASS. Read SQL byte-identical to pre-field, so the read hot path is at baseline by construction. (2026-05-23)

Milestone 3 detail (retained for the record):

- [x] `kiroku-store/sql/schema.sql`: add `original_stream_name TEXT NOT NULL` inline to the `stream_events` `CREATE TABLE`, plus a guarded idempotent convergence `DO` block (ADD COLUMN / disable trigger / backfill from `streams` / SET NOT NULL) that no-ops once converged.
- [ ] New codd migration `kiroku-store-migrations/sql-migrations/2026-05-23-00-00-00-add-original-stream-name.sql`: ADD COLUMN, disable `no_update_stream_events`, backfill from `streams`, re-enable, SET NOT NULL. Update the bootstrap header note to point at additive migrations.
- [ ] `kiroku-store/src/Kiroku/Store/SQL.hs` append/link writes: add `original_stream_name` to all 9 `stream_events` INSERT column lists; source/`$all` link SELECTs supply `$8` (the stream-name param); the link insert supplies `orig.original_stream_name` (and its lateral selects `se.original_stream_name`).
- [ ] `kiroku-store/src/Kiroku/Store/SQL.hs` reads: remove the 8 `JOIN streams os …` lines added in M1 and read `se.original_stream_name` directly; the 2 category templates keep their existing `streams` join and `s.stream_name` (no regression there). The decoder is unchanged (still a 12-column row).
- [ ] `kiroku-store/bench/Main.hs` (and `bench/Explain.hs`) raw append shapes: supply `original_stream_name` so the experimental harness still inserts validly.
- [ ] Update the CHANGELOG entry to describe denormalized storage + the migration.
- [ ] Rebuild; `cabal test kiroku-store` and `cabal test kiroku-store-migrations` green (migration applies, backfills, is repeatable).
- [ ] Re-benchmark: confirm `$all`/`stream` reads return to baseline AND the `append` group shows no regression vs a fresh pre-M3 baseline. Record numbers in Surprises & Discoveries.


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

- The added `streams` join measurably regresses the read paths that gained it,
  contradicting the Decision Log's pre-implementation assumption that a PK join
  would "sit in the noise." Same-machine A/B with `tasty-bench` (pre-JOIN source
  checked out vs. post-JOIN HEAD, `kiroku-store/bench/Main.hs`, 100-event pages
  over the 100K-event fixture), five measurements per path:

  ```text
  $all forward    : +11% +13% +14% +15% +11%  → ~+12% (exceeds 10% gate)
  stream forward  : +9%  +9%  +11% +9%        → ~+9-10% (at gate)
  category forward: same as baseline (already joined streams)
  exhausted-category: same as baseline
  ```

  Absolute: ~988 µs → ~1.12 ms per 100-event `$all` page (≈+130 µs, ≈1.3 µs per
  event). The `category` path is the control: it already joined `streams` for
  the category filter, so adding the column changed nothing — proving the delta
  is the join, not noise. The earlier append-perf lesson ("round-trip count
  dominates, SQL shape does not") held for the single-round-trip append path; it
  does not transfer to reads, where adding a per-row PK lookup over a 100-row
  page is real server-side work. The `$all` path is the subscription hot path,
  so this regression matters. Decision on how to proceed is pending (see
  Decision Log).

- DECISIVE (Milestone 3 re-benchmark): the read regression is the *column
  itself*, not the join. A fresh same-machine A/B of pre-Milestone-1 (no field,
  11-column rows) vs Milestone 3 (denormalized column, no join, 12-column rows),
  run back-to-back on the read group, still shows ~+13% on `$all`:

  ```text
  $all forward (100-event page):
    no field (pre-M1):        955-988 µs   (11-column result)
    field via join (M1/M2):   1.08-1.14 ms (12-column result + streams join)
    field denormalized (M3):  1.09-1.12 ms (12-column result, no join)
  ```

  The join and denormalized variants are statistically identical, both ~13%
  above the no-field baseline. The machine was stable-to-faster during the M3
  runs (B9 saturation latency 0.371 ms vs 0.45 ms in the pre-M1 run), so this is
  not drift. Conclusion: the cost is returning the extra `stream_name` column in
  every read row — Hasql decoding ~100 extra `text` values per page plus wider
  `stream_events` heap tuples — and the `streams` join was never the dominant
  term. Therefore **denormalization does not restore reads to the no-field
  baseline**; it removes only the minor join cost while adding a migration, a
  little write cost, and storage. (Caveat: the join does O(rows) extra random
  index lookups, so it may degrade worse than a stored column at much larger
  pages or cold cache; this microbench used 100-event warm-cache pages.) This
  refutes the Milestone-3 premise and reopens the keep-vs-revert decision.

- Append path is unaffected by the denormalized write. Milestone-3 vs
  Milestone-2 append (same machine): `batch-10` 352 vs 384 µs, `batch-100` 2.40
  vs 2.43 ms, `single-event NoStream` 155 vs 146 µs — all "same as baseline".
  The sub-200 µs `single-event AnyVersion` bench was noisy (167 vs 128 µs) but
  the representative batch benches are flat: writing a value already held as the
  `$8` parameter adds no measurable write cost.


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
  SUPERSEDED 2026-05-23 by the denormalization decision below — the join was measured to
  cost ~12% on the `$all` hot path (see Surprises & Discoveries). The join is removed in
  Milestone 3.

- Decision: Replace the read-time `streams` join with a denormalized
  `original_stream_name` column physically stored on `stream_events`, written at
  append/link time and read directly (no join). The public `RecordedEvent.originalStreamName`
  field and its semantics are unchanged — this is purely an internal storage/perf change.
  Rationale: The Milestone-1 read-time join regressed `$all` reads ~12% and `stream` reads
  ~9% (five-sample same-machine A/B; category reads flat as the control), exceeding the
  repo's 10% regression gate on the subscription hot path. Denormalizing moves the cost to
  write time, where it is structurally near-zero: the source stream name is already an
  append parameter (`$8`), so the source/`$all` junction inserts write a value they already
  hold — no extra lookup, just a wider row. For links the name comes from the source row via
  the existing `orig` lateral. Reads then select `se.original_stream_name` with no join,
  returning to baseline. The user chose this option explicitly over (a) shipping the ~12%
  regression and (b) reverting to a batch id→name lookup API.
  Trade-offs accepted: a schema column + one additive codd migration with a backfill, a
  little more storage (one short text per junction row, ~2× events), and the obligation to
  re-benchmark the append path to confirm the write cost is in fact negligible.
  Date: 2026-05-23

- Decision: Ship the column as one additive codd migration; leave the already-applied
  bootstrap migration (`kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`)
  immutable. Add the column inline to `kiroku-store/sql/schema.sql`'s `CREATE TABLE`
  (fresh dev/test installs) plus a guarded idempotent convergence block for in-place dev
  upgrades.
  Rationale: codd here runs via `applyMigrationsNoCheck` (no checksum/expected-schema
  verification — see `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` and the test),
  and migrations are meant to be immutable and additive. Editing the bootstrap to "keep it
  in sync" with `schema.sql` (as its header historically suggested) would mutate an applied
  migration; instead the follow-on migration reconciles existing databases, and `schema.sql`
  remains the consolidated current-schema view for fresh installs. The bootstrap header note
  is updated to say schema changes after it are shipped as additive migrations.
  Date: 2026-05-23

- Decision: The backfill UPDATE disables the `no_update_stream_events` trigger for its
  duration (in both the migration and the `schema.sql` convergence block), and the
  convergence is guarded so the common path (fresh/already-converged DB) does no table scan.
  Rationale: `stream_events` carries a `prevent_mutation` BEFORE UPDATE trigger
  (`no_update_stream_events`) that unconditionally raises, so a plain backfill UPDATE would
  abort. Disabling it inside the migration transaction is the least invasive fix. The
  `schema.sql` block is gated on `pg_attribute.attnotnull` so that once the column exists and
  is NOT NULL, re-running `schema.sql` (which `initializeSchema` does on every store open)
  skips the `ADD`/backfill/`SET NOT NULL` entirely — avoiding a full-table `SET NOT NULL`
  validation scan on every open.
  Date: 2026-05-23

- Decision: Abandon the `RecordedEvent.originalStreamName` field entirely (revert
  Milestones 1–3) and ship an on-demand lookup API instead:
  `lookupStreamNames :: [StreamId] -> Eff es (Map StreamId StreamName)` and the
  singular `lookupStreamName`.
  Rationale: The Milestone-3 re-benchmark refuted the premise that denormalizing
  would restore read latency. A back-to-back same-machine A/B (no field vs.
  denormalized, see Surprises & Discoveries) showed ~+13% on `$all` 100-event
  reads for *both* the join (M1) and denormalized (M3) variants — the cost is
  decoding/transferring the extra `text` column on every read row, not the join.
  So no field-on-every-read design can avoid it. Because the cost lands on the
  subscription hot path and exceeds the repo's 10% regression gate, and the
  field is a convenience rather than a necessity, the field was rejected. The
  lookup API resolves the surrogate `originalStreamId` that fan-in reads already
  carry, in one round trip per batch, so consumers pay only when and as much as
  they need names — and the read hot path is byte-identical to pre-change (the
  ~13% is gone by construction, not by re-measurement). The user chose this
  option over shipping the regression (join or denormalized).
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

Completed 2026-05-23. The shipped result is **not** the title's field but an
on-demand lookup API — `Kiroku.Store.Read.lookupStreamNames :: [StreamId] ->
Eff es (Map StreamId StreamName)` and singular `lookupStreamName` — reached after
implementing and benchmarking the field three different ways.

The journey, and why it matters:

- Milestones 1–2 added `RecordedEvent.originalStreamName`, sourced via a
  read-time `JOIN streams`, with behavioral tests. Green, but a same-machine
  A/B benchmark found ~+12% on `$all` and ~+9% on `stream` 100-event reads
  (category flat — the control), exceeding the repo's 10% regression gate on the
  subscription hot path.
- Milestone 3 denormalized the name onto `stream_events` (written at append/link
  time, read with no join), on the hypothesis that the join was the cost. It
  was not: a back-to-back no-field-vs-denormalized A/B still showed ~+13% on
  `$all`. The cost is decoding/transferring the extra `text` column on every
  read row — unavoidable for any field-on-every-read design. The append path
  was confirmed flat (denormalized write is free; the name is already a
  parameter).
- Milestone 4 reverted the field entirely and shipped the lookup API. Reads are
  byte-identical to pre-change (the regression is gone by construction), and
  consumers resolve the surrogate `originalStreamId` that fan-in reads already
  carry, one round trip per batch, only when they need names.

Result vs. original purpose: the user-facing need — "recover the source stream
name for fan-in/subscription events without hand-rolled SQL" — is met, but
pay-per-use rather than baked into every read. Final state: `kiroku-store`
158/0 (154 base + 4 `Test.StreamNameLookup`), `kiroku-otel` 6/0,
`shibuya-kiroku-adapter` 8/0, `kiroku-store-migrations` PASS.

Lessons:
- "A PK join sits in the noise" held for the single-round-trip append path but
  not for reads; per-row server work and extra result columns over a 100-row
  page are measurable (~13%). Benchmark the actual hot path before assuming.
- The decisive experiment was the *control*: comparing no-field vs. denormalized
  (not just join vs. denormalized) isolated the cost to the column, which
  inverted the design and saved shipping a migration for no read benefit.
- Returning more data by default is not free even when it looks "already there";
  an on-demand resolver keeps the common path cheap.


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

### Milestone 3 — Denormalize to remove the read regression

Scope: replace the Milestone-1 read-time `streams` join with a stored
`stream_events.original_stream_name` column, populated at write time and read
directly. The public `RecordedEvent` field and all Milestone-2 tests are
unchanged; this milestone is an internal storage/perf change driven by the
benchmark in Surprises & Discoveries. At the end, `$all`/`stream` reads return
to their pre-Milestone-1 latency, the `append` path shows no regression, and a
codd migration upgrades existing databases in place.

The edits, all detailed in the Progress checklist above: (1) `schema.sql` gets
the column inline plus a guarded convergence block; (2) a new additive codd
migration adds + backfills + constrains the column for existing databases,
disabling the `no_update_stream_events` trigger around the backfill; (3) the
nine `INSERT INTO stream_events` statements in `SQL.hs` write the column
(`$8` for appends, `orig.original_stream_name` for links); (4) the eight
non-category read templates drop the join and select `se.original_stream_name`;
(5) the bench raw shapes are updated so the harness still inserts validly.

Acceptance: `cabal test kiroku-store` and `cabal test kiroku-store-migrations`
both report `0 failures`; a fresh same-machine A/B (pre-Milestone-3 vs
post-Milestone-3) shows `$all forward` back within noise of baseline and the
`append.single-event`/`batch` benches within the 10% gate.


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


## Revision Notes

- 2026-05-23 — Added Milestone 3 (denormalize `original_stream_name` onto
  `stream_events`). After Milestones 1–2 shipped the field via a read-time
  `streams` join, a same-machine A/B benchmark showed the join costs ~12% on
  the `$all` subscription hot path and ~9% on single-stream reads (category
  reads flat — the control), exceeding the repo's 10% regression gate. Rather
  than ship that regression or revert to a lookup API, the field is now backed
  by a stored column written at append/link time (near-zero write cost, since
  the source name is already an append parameter) and read with no join. The
  public `RecordedEvent.originalStreamName` API and the Milestone-2 behavioral
  tests are unchanged; only storage and SQL change. Decision Log entries and
  the Surprises & Discoveries benchmark evidence were added; the Milestone-1
  inner-join decision is marked superseded. Why: the change must respect the
  established performance gate on the subscription read path, and denormalizing
  is the only option that keeps the ergonomic field while restoring read
  latency to baseline.

- 2026-05-23 — Added Milestone 4 and abandoned the field. The Milestone-3
  re-benchmark refuted Milestone 3's own premise: denormalizing did not reduce
  the read cost because the cost is the returned column, not the join (a
  back-to-back no-field-vs-denormalized A/B showed ~+13% on `$all` for both the
  join and the denormalized variants). Since no field-on-every-read design can
  avoid that, and it breaches the 10% gate on the subscription hot path, the
  field (Milestones 1–3) was reverted in full and replaced with an on-demand
  `lookupStreamNames`/`lookupStreamName` API that resolves the surrogate
  `originalStreamId` fan-in reads already carry. Purpose, Progress, Decision
  Log, Surprises & Discoveries, and Outcomes were all updated to reflect the
  reversal; the field-era narrative is retained as the record of the
  exploration. Why: the change must respect the established read-path
  performance gate, and the benchmark proved the ergonomic field could not do so.
