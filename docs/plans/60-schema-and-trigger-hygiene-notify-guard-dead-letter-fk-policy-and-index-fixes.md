---
id: 60
slug: schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes
title: "Schema and trigger hygiene: NOTIFY guard, dead-letter FK policy, and index fixes"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
intention: intention_01kv3qaxg9e91v0zq47stehnkz
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Schema and trigger hygiene: NOTIFY guard, dead-letter FK policy, and index fixes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-5 of the master plan at
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.
It has no dependencies on other child plans; EP-7 (benchmark-gated performance work)
soft-depends on this plan because the NOTIFY trigger change shifts append benchmark
numbers.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. Applications append immutable events to
named streams; background "subscription" workers read those events and feed them to
application handlers (for example, to keep a projection — a derived read model — up to
date). The store wakes those workers without polling by using PostgreSQL's
LISTEN/NOTIFY mechanism: a database trigger sends a small text notification on every
append, and a dedicated listener connection in the Haskell process turns each
notification into an in-memory wakeup tick.

A 2026-06-10 audit of the schema and SQL layer found seven hygiene defects. None of
them corrupts data, but together they waste work on every single append and make one
maintenance operation (hard-deleting a stream) fail outright in a common situation:

1. The NOTIFY trigger fires twice per append (once for the appended stream's row and
   once for the internal `$all` bookkeeping row) and also fires spuriously when a
   stream is soft-deleted or undeleted — operations that add no events and need no
   wakeup.
2. Hard-deleting a stream aborts with an opaque `ConnectionError` whenever any of the
   stream's events has been "dead-lettered" (recorded in the `dead_letters` table
   after a subscription handler gave up on it), because `dead_letters.event_id` has a
   plain foreign key to `events` and the hard delete removes the `events` rows.
3. The junction-row delete inside hard delete is a full sequential scan of
   `stream_events` — the largest table in the schema.
4. Reading dead letters sorts every time because the query's `ORDER BY` does not match
   any index.
5. The `ix_events_event_type` index is maintained on every append but used by no
   query.
6. An append to a stream whose name is roughly 8,000 bytes long fails at trigger time
   (PostgreSQL's `pg_notify` rejects payloads ≥ 8,000 bytes) after all the insert work
   is done.
7. The single `streams` row for `$all` (stream_id 0) is updated on every append in the
   entire database, churning its heap page.

After this plan is complete: one append produces exactly one notification; stream
lifecycle operations produce none; hard-deleting a stream succeeds even when its
events have dead letters (and removes those dead letters); the hard-delete SQL uses
index scans instead of sequential scans (with `EXPLAIN` evidence); the dead-letter
read is index-ordered; the unused index is gone and the stream-version index enforces
uniqueness so a future version-assignment bug fails loudly; oversized stream names are
rejected with a typed error before any database work; and the `$all` hot row has
breathing room on its page (`fillfactor`).

Everything ships as new timestamped SQL migration files in
`kiroku-store-migrations/sql-migrations/` plus targeted Haskell changes in
`kiroku-store`. One hard constraint inherited from the master plan: the NOTIFY payload
format `stream_name,stream_id,stream_version`, parsed by `categoryFromPayload` in
`kiroku-store/src/Kiroku/Store/Notification.hs`, must remain byte-for-byte unchanged.
This plan changes only *when* notifications fire, never their shape.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1: Write migration `2026-06-11-00-00-00-notify-trigger-append-guard.sql`
      (drop the unconditional `stream_events_notify` trigger; create guarded
      INSERT and UPDATE triggers).
- [x] M1: Add `Test.NotifyGuard` to the `kiroku-store` test suite (LISTEN-based
      notification counting: 1 per append, 0 for soft-delete/undelete, payload
      shape unchanged) and add `hasql-notifications` to the test-suite
      `build-depends`.
- [x] M1: Extend `kiroku-store-migrations/test/Main.hs` to assert the trigger set
      on `kiroku.streams` after codd applies migrations.
- [x] M2: Write migration `2026-06-11-00-00-01-dead-letters-event-id-index.sql`
      (index on `kiroku.dead_letters (event_id)`).
- [x] M2: Replace `deleteStreamJunctionsStmt` in
      `kiroku-store/src/Kiroku/Store/SQL.hs` with the three indexed delete
      statements; add `deleteDeadLettersForOrphanedEventsStmt`.
- [x] M2: Rewire the `HardDeleteStream` transaction in
      `kiroku-store/src/Kiroku/Store/Effect.hs` (junction deletes → dead-letter
      pre-delete → orphan-event delete → stream-row delete).
- [x] M2: Add the hard-delete-with-dead-letters regression test (fails before the
      change with `ConnectionError`, passes after) and assert surviving linked
      events keep their dead letters.
- [x] M2: Capture before/after `EXPLAIN` evidence for the junction delete and the
      dead-letters FK lookup; paste transcripts into Surprises & Discoveries.
- [x] M3: Write migration
      `2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql`
      (drop `ix_events_event_type`; replace `ix_stream_events_stream_version`
      with unique `ux_stream_events_stream_version`; re-key the dead-letters read
      index on `global_position DESC, dead_letter_id DESC`; set
      `streams` fillfactor to 50).
- [x] M3: Extend the migrations test to assert index set, uniqueness, and
      `streams` reloptions.
- [x] M3: Run `just bench-regression` and investigate the result. The configured
      10% gate failed against both the old May baseline and a freshly captured
      baseline, but controlled SQL A/B timings showed M3's schema shape is
      effectively neutral after warm-up; details are in Surprises & Discoveries.
- [x] M4: Add `StreamNameTooLong` to `StoreError` in
      `kiroku-store/src/Kiroku/Store/Error.hs`; add `maxStreamNameBytes` and the
      shared validation helper; enforce at the append/link/multi-append sites in
      `kiroku-store/src/Kiroku/Store/Effect.hs` and in
      `runTransactionAppendingWith` in
      `kiroku-store/src/Kiroku/Store/Transaction.hs`.
- [x] M4: Write migration `2026-06-11-00-00-03-stream-name-length-check.sql`
      (CHECK constraint, defense in depth) and extend the migrations test.
- [x] M4: Add oversized-name tests (513-byte name rejected with
      `StreamNameTooLong`; 512-byte name appends and notifies normally).
- [x] Final: run `just build` and `just test` clean; update the master plan's
      Exec-Plan Registry row for EP-5 and its Progress checkboxes; write the
      Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

2026-06-14, M1 validation passed with:
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "NOTIFY trigger guard"'`
and
`cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct`.
The codd test initially still saw only the two old embedded migrations until
`Kiroku.Store.Migrations` was rebuilt; the Template Haskell `embedDir` does not
necessarily recompile when only a new file appears in the embedded directory.
The migration assertion also needed `t.tgname::text` because `pg_trigger.tgname`
has PostgreSQL type `name` (OID 19), not `text`.

2026-06-14, M2 validation passed with:
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "hardDeleteStream"'`,
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "subscription dispositions"'`,
and
`cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct`.
The codd test reported four embedded migrations, including
`2026-06-11-00-00-01-dead-letters-event-id-index.sql`.

M2 EXPLAIN evidence, captured on a seeded dev database with 1,000 streams,
20,000 events/junction pairs, and 5,000 dead letters:

```text
BEFORE old OR junction delete:
  -> Seq Scan on stream_events
     Filter: ((stream_id = ...) OR (original_stream_id = ...))

AFTER originated $all rows delete:
  -> Bitmap Index Scan on ix_stream_events_all_by_origin
     Index Cond: (original_stream_id = ...)

AFTER event-id junction delete:
  -> Bitmap Index Scan on stream_events_pkey
     Index Cond: (event_id = ANY (...))

AFTER stream own junction delete:
  -> Bitmap Index Scan on ix_stream_events_stream_version
     Index Cond: (stream_id = ...)

AFTER dead_letters event_id probe:
  Index Only Scan using ix_dead_letters_event_id on dead_letters
    Index Cond: (event_id = ...)
```

The EXPLAIN output also included `Seq Scan` nodes over temporary seed tables used
only to choose one stream/event id for the probe; those are not part of the
production statement shapes.

2026-06-14, M3 migration validation passed with:
`cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct`
(the codd test reported five embedded migrations) and
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "subscription dispositions"'`.

M3 dead-letter read EXPLAIN evidence on the seeded dev database:

```text
BEFORE old created_at index shape:
  Sort
    Sort Key: global_position DESC, dead_letter_id DESC
    -> Seq Scan on dead_letters

AFTER ix_dead_letters_subscription_position:
  Index Scan using ix_dead_letters_subscription_position on dead_letters
    Index Cond: ((subscription_name = 'ep5-explain') AND (consumer_group_member = 0))
```

`just bench-regression` needed a benchmark harness fix first:
`kiroku-store/bench/Main.hs` opened `withStore` on a blank ephemeral PostgreSQL
database, so the EventPublisher failed immediately with `relation "streams" does
not exist`. The harness now calls `migrateTestDatabase` before opening the store.

The benchmark gate result was noisy rather than a clean schema regression:

- Against the old tracked baseline from 2026-05-17, `just bench-regression`
  failed 3/23 cases: `append.single-event.NoStream (new stream)` (+12%),
  `category.exhausted-category` (+21%), and `concurrent.32 writers x 10 appends`
  (+25%).
- Per the plan's stale-baseline guidance, `just bench-baseline` was run and wrote
  a fresh `kiroku-store/bench/results/baseline.csv`.
- Against that fresh baseline, `just bench-regression` still failed 8/23 cases,
  all singleton/raw append microbenchmarks; batch appends, reads, category reads,
  concurrent writers, and reliability-audit benchmarks were at baseline or faster
  (`appendMultiStream 3 existing streams` was 15% faster in the final run).

Controlled SQL A/B timings on the same dev database isolated the schema pieces.
After fixing the reset to truncate/reseed `streams` (to avoid dead-tuple buildup)
and excluding the first warm-up row:

```text
M2 old shape (event_type index + nonunique stream-version index):
  singleton append ~= 0.121 ms; batch-10 append ~= 1.165 ms
M3 current shape (no event_type index + unique stream-version index + fillfactor 50):
  singleton append ~= 0.120 ms; batch-10 append ~= 1.178 ms
```

An old-unconditional-trigger vs new-guarded-trigger A/B under the M3 index shape
also measured effectively equal writer latency (`~0.066 ms` vs `~0.067 ms`
singleton, excluding warm-up). The corrected interpretation: M1 reduces duplicate
notifications and downstream wakeups; it should not be sold as a reliable
writer-latency improvement. M3's index hygiene is write-latency neutral in this
local experiment, while the configured tasty-bench gate is too noisy to confirm a
10% singleton/raw microbenchmark threshold from one baseline capture.

2026-06-14, M4 validation passed with:
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "stream-name contract"'`,
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "NOTIFY trigger guard"'`,
`cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "runTransactionAppending"'`,
`cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct`
(six embedded migrations), and `cabal build all`.
The first attempt to run NotifyGuard and runTransactionAppending in parallel hit a
Cabal build-directory race (`package.conf.inplace already exists`); rerunning the
transaction test serially passed.

2026-06-14, final validation passed with `just build` and `just test`.
An earlier full `just test` run failed one Shibuya adapter consumer-group example
(`delivers only matching types across a filtered consumer group (EP-43)`) by receiving
19 matching events instead of 20 under seed `521722692`; the exact seeded example then
passed, the full `shibuya-kiroku-adapter-test` suite passed, and the final full
`just test` rerun passed all suites.


## Decision Log

Record every decision made while working on the plan.

- Decision: Guard the NOTIFY trigger with two `CREATE TRIGGER ... WHEN (...)`
  definitions (one `AFTER INSERT`, one `AFTER UPDATE`) sharing the existing
  `kiroku.notify_events()` function, instead of one trigger with an `IF` inside the
  function body.
  Rationale: A trigger `WHEN` clause is evaluated before the trigger function is
  invoked, so filtered rows skip the PL/pgSQL call entirely — cheaper on the hot
  append path. A single trigger cannot do it because `WHEN` on an `INSERT OR UPDATE`
  trigger may not reference `OLD` (PostgreSQL only allows `OLD` in UPDATE/DELETE
  `WHEN` clauses, and `TG_OP` is not visible in `WHEN` at all). Two triggers express
  the per-operation conditions precisely: INSERT fires for any new non-`$all` stream
  row; UPDATE fires only when `stream_version` actually changed on a non-`$all` row.
  The function body — and therefore the payload format consumed by
  `categoryFromPayload` in `kiroku-store/src/Kiroku/Store/Notification.hs` — is
  untouched.
  Date: 2026-06-11

- Decision: Resolve the hard-delete vs `dead_letters` foreign-key conflict by
  explicitly deleting matching dead-letter rows inside the hard-delete transaction,
  and keep the FK as plain `NO ACTION` (no `ON DELETE CASCADE`).
  Rationale: The explicit pre-delete makes the destruction visible in the Haskell
  transaction code where an auditor reads the hard-delete path, and it matches the
  GDPR purpose of hard delete (a dead letter's `reason`/`reason_summary` may embed
  payload-derived data, so it must go too). Keeping `NO ACTION` turns the FK into a
  tripwire: if a *future* code path ever deletes `events` rows without considering
  dead letters, it fails loudly instead of silently cascading operator-facing data
  away. This mirrors the schema's existing philosophy (immutability and
  delete-protection triggers fail loudly). `CASCADE` was rejected because dead
  letters are operator-facing records, not purely derived data.
  Date: 2026-06-11

- Decision: Fix the junction-delete sequential scan by restructuring into three
  statements that each use an existing index — no new index on
  `stream_events (original_stream_id)`.
  Rationale: The key insight is that every event originating in a stream has a `$all`
  junction row, and those rows are reachable through the existing partial index
  `ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE
  stream_id = 0`. Deleting them with `RETURNING event_id` yields exactly the set of
  events that originated in the stream; their remaining junction rows (the stream's
  own rows plus any link rows in other streams) are then deletable through the
  primary key `(event_id, stream_id)` via `event_id = ANY(...)`. A final delete on
  `stream_id = $1` (using `ix_stream_events_stream_version` /
  `ux_stream_events_stream_version`) removes link rows pointing *into* the deleted
  stream. A new always-maintained index on `original_stream_id` was rejected: it
  would add write amplification to every append to serve a rare maintenance
  operation — the exact trade this plan removes elsewhere by dropping
  `ix_events_event_type`.
  Date: 2026-06-11

- Decision: Keep `readDeadLettersSQL`'s `ORDER BY global_position DESC,
  dead_letter_id DESC` unchanged and re-key the index to
  `(subscription_name, consumer_group_member, global_position DESC, dead_letter_id
  DESC)`, replacing `ix_dead_letters_subscription_created_at`.
  Rationale: The operator-facing contract is "newest first". Per subscription member,
  dead letters are written in checkpoint order, so `global_position` order and
  `created_at` order agree — but `global_position` is the store's canonical,
  deterministic ordering while `created_at` is wall-clock (`now()`) and can tie or
  skew. Re-keying the index makes the existing deterministic `ORDER BY` an index-only
  ordering with zero Haskell churn; switching the SQL to `created_at DESC` would have
  traded determinism for nothing.
  Date: 2026-06-11

- Decision: Drop `ix_events_event_type`.
  Rationale: No statement in `kiroku-store/src/Kiroku/Store/SQL.hs` filters on
  `events.event_type` (verified 2026-06-10: every `event_type` mention is in INSERT
  column lists). The index is pure write amplification on every append. Server-side
  event-type filtering ("SQL pushdown") is a documented future direction (see the
  `EventTypeFilter` haddock in
  `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`), but pushdown would filter
  the category/`$all` *read* join and will almost certainly need a different index
  shape; when that ships, its plan re-adds a fit-for-purpose index (cheap:
  `CREATE INDEX`). Keeping a speculative, wrongly-shaped index in the meantime buys
  nothing.
  Date: 2026-06-11

- Decision: Replace `ix_stream_events_stream_version (stream_id, stream_version)`
  with a UNIQUE index `ux_stream_events_stream_version` on the same columns.
  Rationale: Version assignment is unique by construction (per-stream versions are
  assigned consecutively under the stream's row lock; `$all` versions are the global
  position, also assigned under a row lock), so existing data satisfies the
  constraint. Making it UNIQUE turns any future version-assignment bug into an
  immediate `23505` unique violation instead of silent duplicate versions. Note the
  error-mapping consequence: in `mapUsageError`
  (`kiroku-store/src/Kiroku/Store/Error.hs`), a `23505` not attributable to
  `events_pkey` or `ix_streams_stream_name` maps to `WrongExpectedVersion` — a loud,
  investigable surface, which is the goal. If `CREATE UNIQUE INDEX` fails during
  migration, that *is* the defect detection working; see Idempotence and Recovery.
  Date: 2026-06-11

- Decision: Enforce a 512-byte (UTF-8) stream-name limit at append/link validation
  time in `kiroku-store`, surfaced as a new typed error `StreamNameTooLong`, plus a
  `CHECK (octet_length(stream_name) <= 512)` constraint as defense in depth. Do NOT
  change the NOTIFY payload.
  Rationale: Inherited master-plan decision: the payload is a cross-component
  contract and stays unchanged. `pg_notify` rejects payloads of 8,000 bytes or more,
  so an append to a ~7,960-byte stream name fails at trigger time after all insert
  work. The bound is measured in bytes (not characters) because the `pg_notify`
  limit is bytes. 512 is generous — observed stream names are `category-identifier`
  shapes well under 100 bytes — while leaving over 7,400 bytes of headroom below the
  failure point. The CHECK constraint catches any writer that bypasses the Haskell
  validation (e.g., raw SQL through `runTransaction`).
  Date: 2026-06-11

- Decision: Set `ALTER TABLE kiroku.streams SET (fillfactor = 50)` in a migration;
  no `VACUUM FULL`, no autovacuum parameter overrides.
  Rationale: The `$all` row (stream_id 0) is updated by every append in the
  database. None of the columns it changes (`stream_version`) is indexed, so its
  updates are HOT-eligible (Heap-Only Tuple: PostgreSQL can place the new row
  version on the same page and skip all index updates) — but only if the page has
  free space. fillfactor 50 reserves that space. It applies to newly written pages
  only; existing pages converge through normal update/prune activity, which for a
  row updated on every append is immediate in practice. `VACUUM` cannot run inside
  codd's migration transaction, and autovacuum tuning is an operator concern; a
  comment in the migration records both points.
  Date: 2026-06-11

- Decision: Ship four separate timestamped migration files (one per milestone)
  rather than one combined file, each using explicit `kiroku.`-qualified object
  names rather than `SET search_path`.
  Rationale: Per-milestone files keep each milestone independently appliable and
  verifiable, matching the repo rule that applied migrations are never edited. codd
  applies each file independently, so a file cannot rely on the bootstrap's
  `SET search_path`; explicit qualification follows the precedent of
  `kiroku-store-migrations/sql-migrations/2026-05-26-00-00-00-add-subscription-dead-letters.sql`
  and is also robust under `kiroku-test-support`'s concatenate-and-run application
  path.
  Date: 2026-06-11

- Decision: Adding the `StreamNameTooLong` constructor to `StoreError` is treated as
  a breaking library change.
  Rationale: `StoreError` is a closed, exhaustively-matched sum (its haddock
  promises new constructors surface as `-Wincomplete-patterns`, never silent
  misclassification). Downstream consumers (keiro pins kiroku-store by git SHA) will
  need a pin bump and possibly a new match arm. The commit must use a
  `feat(kiroku-store)!:` conventional-commit marker.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

2026-06-14, completed. EP-5 shipped four production changes:

- The append notification trigger is guarded so lifecycle updates and `$all` row
  updates no longer emit duplicate append notifications, while the wire payload remains
  unchanged.
- Hard delete now removes dead letters for events that become orphaned before deleting
  the event payloads, and leaves dead letters alone when the event survives through
  another linked stream.
- Index hygiene is applied: dead-letter FK/delete and read paths are indexed, the
  stream-version junction index is unique, the unused event-type index is removed, and
  `streams` uses fillfactor 50 for the hot `$all` row.
- Stream names are bounded at 512 UTF-8 bytes in both the Haskell API and the database,
  closing the NOTIFY payload abort edge for appends, links, multi-stream appends, and
  transactional appends.

The important correction is performance-related. The original expectation that the
trigger guard would make appends faster was too broad. Local A/B measurements showed
writer latency was effectively unchanged after warm-up; the real win is fewer duplicate
notifications and less downstream subscription wakeup work. `just bench-regression`
remained too noisy for singleton/raw append microbenchmarks even after refreshing the
baseline, so EP-7 should use controlled before/after captures for performance promotion
decisions instead of treating one tasty-bench gate run as sufficient evidence.


## Context and Orientation

This section is self-contained background. Read it before touching anything.

### The packages involved

The repository root is the working directory for every command in this plan. Two
packages change:

- `kiroku-store` — the event-store library. The SQL text lives in
  `kiroku-store/src/Kiroku/Store/SQL.hs`; the effect interpreter that runs that SQL
  against a connection pool is `kiroku-store/src/Kiroku/Store/Effect.hs`; typed
  errors are in `kiroku-store/src/Kiroku/Store/Error.hs`; the LISTEN/NOTIFY consumer
  is `kiroku-store/src/Kiroku/Store/Notification.hs`; its test suite is
  `kiroku-store/test/` (hspec, entry point `kiroku-store/test/Main.hs`).
- `kiroku-store-migrations` — the schema owner. Schema changes are timestamped SQL
  files in `kiroku-store-migrations/sql-migrations/`, embedded into the binary at
  compile time (`embedDir` in
  `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs`) and applied by codd.
  codd is a PostgreSQL migration tool: it records each timestamped file after a
  successful run and never re-applies it, and it is forward-only — you never edit an
  applied migration; you add a new file that sorts later by filename. Its test is
  `kiroku-store-migrations/test/Main.hs`.

Two existing migrations define the current schema:

- `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
  creates the `kiroku` schema, the `streams` / `events` / `stream_events` /
  `subscriptions` tables, all indexes, and all triggers (the NOTIFY trigger is at
  the bottom under `-- Triggers`).
- `kiroku-store-migrations/sql-migrations/2026-05-26-00-00-00-add-subscription-dead-letters.sql`
  adds `kiroku.dead_letters` with
  `event_id UUID NOT NULL REFERENCES kiroku.events(event_id)` (default referential
  action, i.e. `NO ACTION`), a UNIQUE key on
  `(subscription_name, consumer_group_member, global_position, event_id)`, and a read
  index `ix_dead_letters_subscription_created_at (subscription_name,
  consumer_group_member, created_at)`.

### How tests get a migrated database

There are two distinct application paths; new migrations must work in both:

- The `kiroku-store-migrations` test applies the *embedded* migrations through codd
  itself (`runKirokuMigrationsNoCheck`) against an ephemeral PostgreSQL. This is the
  same mechanism production uses. codd applies each file separately, so each file
  must be self-sufficient (hence explicit `kiroku.` qualification).
- The `kiroku-store` test suite (and benchmarks) use
  `kiroku-test-support/src/Kiroku/Test/Postgres.hs` (`withMigratedTestDatabase` /
  `withSharedMigratedPostgres`), which reads every `*.sql` file from
  `kiroku-store-migrations/sql-migrations/` off disk in sorted filename order,
  concatenates them, and runs them as one script. New files in that directory are
  picked up automatically — no registration step.

There is no checked-in codd "expected schema" snapshot in this repository: the
migrations test passes `DbRep Null` and uses the no-check entry point, and
`kiroku-store-migrations/README.md` states snapshots are not yet shipped. So there is
no schema-checksum file to regenerate after a schema change; the migrations test plus
the assertions this plan adds to it are the schema gate.

### How an append touches the schema (why the trigger fires twice today)

Every append runs one big CTE statement (see `appendAnyVersionSQL` and siblings in
`kiroku-store/src/Kiroku/Store/SQL.hs`). Inside it:

1. The named stream's row in `streams` is INSERTed (new stream) or UPDATEd
   (`stream_version = stream_version + N`).
2. Event payloads go into `events`.
3. Junction rows go into `stream_events` — one row linking each event to its source
   stream, and one row linking it to the `$all` stream (stream_id 0), whose
   `stream_version` is the event's global position.
4. The `$all` row in `streams` is UPDATEd (`stream_version = stream_version + N`) —
   this row-level lock is also what serializes global-position assignment.

The bootstrap trigger is:

```sql
CREATE TRIGGER stream_events_notify
    AFTER INSERT OR UPDATE ON streams
    FOR EACH ROW EXECUTE FUNCTION notify_events();
```

with `notify_events()` sending payload
`NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version` on channel
`kiroku.events`. Because steps 1 and 4 *both* touch `streams`, every append emits two
notifications: one for the real stream (e.g. `order-123,7,5`) and one for the
bookkeeping row (`$all,0,42`). The bootstrap comment "fires once per append" is
wrong. Additionally, `softDeleteStreamSQL` and `undeleteStreamSQL` (in
`kiroku-store/src/Kiroku/Store/SQL.hs`, around lines 1015–1033) UPDATE only
`deleted_at` on a `streams` row — no new events exist — yet they fire the trigger
too, waking every listener for nothing.

### Who consumes the notifications (why the guard is safe)

`startNotifier` in `kiroku-store/src/Kiroku/Store/Notification.hs` holds one
dedicated connection that LISTENs on `<schema>.events`. Its callback
`handleNotification` does two things per notification, atomically:

- writes a unit tick to a broadcast channel — this wakes the EventPublisher
  (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`), whose loop
  blocks in `waitForWakeup` on that channel with a 30-second safety-poll timeout and
  then drains/debounces pending ticks (`drainTicks`) before fetching new events;
- parses the payload with `categoryFromPayload` (stream name = everything before the
  last two comma-separated fields; category = prefix before the first `-`) and bumps
  that category's wake counter, which unblocks Category-subscription workers.

Tracing the guard's safety: every successful append performs an INSERT or a
version-bumping UPDATE on the *named* stream's row (step 1 above), so after the
guard, every append still emits exactly one notification per appended stream — the
publisher tick still fires for every append, and the correct category counter still
bumps. What the guard removes is (a) the `$all`-row notification, whose only effect
today is a duplicate tick (debounced anyway by `drainTicks`) and a bump of the
useless `"$all"` entry in the category map (`$all` is reserved — `categoryName
(StreamName "$all")` yields category `$all`, and no application Category subscription
can target it because appends to `$all` are rejected with `ReservedStreamName` by
`rejectReservedApplicationStream` in `kiroku-store/src/Kiroku/Store/Effect.hs`); and
(b) lifecycle (soft-delete/undelete) notifications, which add no events, so no
consumer needs waking — and even a hypothetical missed edge is reconciled by the
30-second safety poll that both the publisher and category workers already run.
A multi-stream append (`AppendMultiStream`) updates N named-stream rows plus `$all`
once: today N+1 notifications, after the guard exactly N — one per appended stream,
each with the right category. That is the correct count, not a loss.

### The hard-delete path (findings B and C)

`HardDeleteStream` in `kiroku-store/src/Kiroku/Store/Effect.hs` (around line 266)
runs one transaction: `SET LOCAL kiroku.enable_hard_deletes = 'on'` (the GUC the
delete-protection triggers check), resolve the stream id, then

- `deleteStreamJunctionsStmt` (in `kiroku-store/src/Kiroku/Store/SQL.hs`, around
  line 938): `DELETE FROM stream_events WHERE stream_id = $1 OR original_stream_id
  = $1 RETURNING event_id` — the `OR` defeats every index (only the partial index
  `ix_stream_events_all_by_origin ... WHERE stream_id = 0` covers the second arm,
  and only partially), so the planner falls back to a sequential scan of the whole
  junction table;
- `deleteOrphanedEventsStmt` (around line 961): deletes `events` rows from the
  returned id set that have no surviving junction row;
- `deleteStreamRowStmt`: deletes the `streams` row.

If any deleted event has a `dead_letters` row, the `events` delete violates
`dead_letters_event_id_fkey`; the whole transaction aborts, and `usePool` in
`Effect.hs` surfaces it as the catch-all `ConnectionError` (the FK-to-`StreamNotFound`
mapping in `mapUsageError` applies only to the append statements). Worse, the FK
check itself has no index: the UNIQUE key on `dead_letters` leads with
`subscription_name`, so each per-row referential-integrity check sequential-scans
`dead_letters`.

Junction-table semantics needed for the fix: a row in `stream_events` has
`(event_id, stream_id, stream_version, original_stream_id, original_stream_version)`.
For an event appended to stream S: one row with `stream_id = S, original_stream_id =
S` (its home), one row with `stream_id = 0, original_stream_id = S` (its `$all`
entry). If the event is later linked into stream T (`linkToStream`), a third row has
`stream_id = T, original_stream_id = S`. Therefore: deleting stream S must remove
(i) all rows with `original_stream_id = S` — its events' home rows, `$all` rows, and
link rows elsewhere — and (ii) rows with `stream_id = S, original_stream_id = X` for
events linked *into* S from other streams (those events survive; they keep their home
and `$all` rows). Events in set (i) always lose *all* their junctions (their `$all`
row is in the set), so they are always orphan-deleted; events in set (ii) never
orphan.

### Dead-letter reads (finding D)

`readDeadLettersSQL` (in `kiroku-store/src/Kiroku/Store/SQL.hs`, around line 1213)
selects by `(subscription_name, consumer_group_member)` and orders by
`global_position DESC, dead_letter_id DESC` — "newest first" for the operator. The
only index is on `(subscription_name, consumer_group_member, created_at)`, so every
read does an explicit sort step.

### Stream-name validation today (finding F)

The only name validation is the reserved-name check: `isReservedApplicationStream`
(`== "$all"`) in `kiroku-store/src/Kiroku/Store/Effect.hs`, applied via
`rejectReservedApplicationStream` at the `AppendToStream`, `LinkToStream`,
`SoftDeleteStream`, `HardDeleteStream`, and `UndeleteStream` interpreter cases and
via an inline `name == "$all"` guard in `runTransactionAppendingWith` in
`kiroku-store/src/Kiroku/Store/Transaction.hs` (around line 309). There is no length
bound anywhere, so `pg_notify`'s 8,000-byte payload limit makes a ≳7,960-byte stream
name an append-time trigger error.

### Build and test commands

All commands run from the repository root. `just build` runs `cabal build all`;
`just test` runs `cabal test all`. Targeted suites:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct
```

Both suites boot their own ephemeral PostgreSQL (the `ephemeral-pg` library); no
external database or service is needed for tests. For interactive `EXPLAIN` work
there is a local dev database: `just up` (starts PostgreSQL via process-compose),
`just create-database`, `just init-schema` (runs the codd migration executable —
this applies your new migration files for real), `just psql`. Benchmarks:
`just bench-regression` compares against
`kiroku-store/bench/results/baseline.csv` and fails if >10% slower.


## Plan of Work

Four milestones. Each ships independently: a migration file (picked up automatically
by both test paths), the Haskell change if any, and tests proving the behavior.
Migration filenames must sort after `2026-05-26-...`; this plan fixes them as
`2026-06-11-00-00-0X-...` so they apply in milestone order even if implemented out of
order. All milestones are additive; none changes the NOTIFY payload format.

### Milestone 1 — One NOTIFY per append, none for lifecycle

Scope: replace the unconditional `stream_events_notify` trigger with two guarded
triggers, and prove the new firing behavior with a LISTEN-based test.

Create `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-00-notify-trigger-append-guard.sql`:

```sql
-- Guard the append-notification trigger (MasterPlan 9 / EP-5, docs/plans/60-...).
--
-- The bootstrap's stream_events_notify trigger fired for EVERY insert or update
-- on kiroku.streams. Each append updates both the named stream's row and the
-- $all bookkeeping row (stream_id 0), so every append emitted two
-- notifications; soft-delete/undelete (which change only deleted_at) emitted
-- spurious ones. The named-stream row is inserted or version-bumped on every
-- append, so notifying on that row alone preserves every wakeup the publisher
-- and category workers rely on.
--
-- The payload format produced by kiroku.notify_events()
-- (stream_name,stream_id,stream_version) is a cross-component contract parsed
-- by Kiroku.Store.Notification.categoryFromPayload and is deliberately
-- unchanged; only the firing conditions change.
--
-- Two triggers because a WHEN clause cannot reference TG_OP, and an
-- INSERT-trigger WHEN cannot reference OLD: the conditions are per-operation.

DROP TRIGGER IF EXISTS stream_events_notify ON kiroku.streams;

DROP TRIGGER IF EXISTS stream_events_notify_insert ON kiroku.streams;
CREATE TRIGGER stream_events_notify_insert
    AFTER INSERT ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0)
    EXECUTE FUNCTION kiroku.notify_events();

DROP TRIGGER IF EXISTS stream_events_notify_update ON kiroku.streams;
CREATE TRIGGER stream_events_notify_update
    AFTER UPDATE ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0
          AND NEW.stream_version IS DISTINCT FROM OLD.stream_version)
    EXECUTE FUNCTION kiroku.notify_events();
```

Do not touch `notify_events()` itself. Note the conditions against the append CTEs:
new-stream creation is an `INSERT ... ON CONFLICT DO NOTHING/DO UPDATE` on `streams`
(INSERT trigger, `stream_id <> 0` true); existing-stream appends and `linkToStream`
bump `stream_version` (UPDATE trigger fires); the `$all` row update has
`stream_id = 0` (filtered); soft-delete/undelete change only `deleted_at`
(`stream_version IS DISTINCT FROM OLD.stream_version` is false — filtered). The
bootstrap's seed `INSERT` of the `$all` row is also filtered, which is harmless (no
listener exists at migration time).

Add a test module `kiroku-store/test/Test/NotifyGuard.hs`, register it in the
`other-modules` of `test-suite kiroku-store-test` in
`kiroku-store/kiroku-store.cabal` and import/run its `spec` from
`kiroku-store/test/Main.hs`. Add `hasql-notifications >=0.2 && <0.3` to the test
suite's `build-depends` (it is already a library dependency with those bounds). The
test opens its own raw LISTEN connection alongside the store, mirroring what
`startNotifier` does:

- Use `withMigratedTestDatabase` from `Kiroku.Test.Postgres` (gives the connection
  string), open the store with `withStore (defaultConnectionSettings connStr)`, and
  separately `Hasql.Connection.acquire` a dedicated connection; run
  `Hasql.Notifications.listen conn (toPgIdentifier "kiroku.events")`; spawn an
  `Async` running `waitForNotifications` with a callback that appends each payload
  `ByteString` to a `TVar [ByteString]`.
- Sequence of store operations: append one batch to stream `notify-guard-1`
  (expect 1 notification, payload exactly `notify-guard-1,<sid>,<version>` — assert
  the three-field shape and that the name parses back via the same
  split-on-last-two-commas rule `categoryFromPayload` uses); `softDeleteStream`;
  `undeleteStream`; then append to a second stream `notify-guard-2`.
- Determinism without sleeps: notifications on one LISTEN connection are delivered
  in commit order, so once the `notify-guard-2` payload has arrived, any
  notification from the earlier soft-delete/undelete/`$all` updates would already
  have arrived. Block (with `waitWithTimeout`-style budget, e.g.
  `Async.race (threadDelay 5_000_000) (atomically (... check ...))`) until a payload
  prefixed `notify-guard-2,` is present, then assert the collected list contains
  exactly two payloads: one for each append, none for `$all` and none for the
  lifecycle operations.
- Cancel the async and release the connection in a bracket.

Extend `kiroku-store-migrations/test/Main.hs` with an
`assertStreamTriggers :: Text -> IO ()` (same pool-acquire pattern as the existing
`assertDeadLettersTable`) asserting the exact user-trigger set on `kiroku.streams`
after the codd run:

```sql
SELECT t.tgname
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'kiroku' AND c.relname = 'streams' AND NOT t.tgisinternal
ORDER BY t.tgname
```

Expected exactly: `no_delete_streams`, `no_truncate_streams`,
`stream_events_notify_insert`, `stream_events_notify_update` (and in particular NOT
`stream_events_notify`).

Acceptance: `cabal test kiroku-store:kiroku-store-test` and
`cabal test kiroku-store-migrations:kiroku-store-migrations-test` pass; the new
NotifyGuard spec fails if run against the un-migrated trigger (verify once by
running the test before adding the migration file — it should report 3+
notifications instead of 2). All other suites stay green — in particular the
subscription tests, which prove publisher and category wakeups still work end to
end with half the notifications.

### Milestone 2 — Hard delete coexists with dead letters and stops seq-scanning

Scope: make `hardDeleteStream` succeed when dead letters reference the stream's
events (purging exactly those dead letters), and restructure the junction delete to
use index scans. One migration plus Haskell changes in `SQL.hs` and `Effect.hs`.

Create `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-01-dead-letters-event-id-index.sql`:

```sql
-- Index dead_letters by event_id (MasterPlan 9 / EP-5, docs/plans/60-...).
--
-- dead_letters.event_id has a FK to kiroku.events. The UNIQUE key leads with
-- subscription_name, so every referential-integrity check triggered by a
-- DELETE on kiroku.events (the hard-delete path) was a sequential scan of
-- dead_letters, and the hard-delete transaction's own dead-letter pre-delete
-- (Kiroku.Store.SQL.deleteDeadLettersForOrphanedEventsStmt) needs the same
-- access path.
CREATE INDEX IF NOT EXISTS ix_dead_letters_event_id
    ON kiroku.dead_letters (event_id);
```

In `kiroku-store/src/Kiroku/Store/SQL.hs`, remove `deleteStreamJunctionsStmt` and
add four statements (keep the existing haddock discipline; each haddock should state
which index serves the statement):

1. `deleteAllRowsForOriginStmt :: Statement Int64 (Vector UUID)` —
   `DELETE FROM stream_events WHERE original_stream_id = $1 AND stream_id = 0
   RETURNING event_id`. Served by the partial index
   `ix_stream_events_all_by_origin`. The returned ids are exactly the events that
   originated in the stream (every originated event has a `$all` row).
2. `deleteJunctionsByEventIdsStmt :: Statement (Vector UUID) ()` —
   `DELETE FROM stream_events WHERE event_id = ANY($1::uuid[])`. Served by the
   primary key `(event_id, stream_id)`. Removes the originated events' home rows
   and any link rows for them in other streams.
3. `deleteStreamOwnJunctionsStmt :: Statement Int64 (Vector UUID)` —
   `DELETE FROM stream_events WHERE stream_id = $1 RETURNING event_id`. Served by
   the `(stream_id, stream_version)` index (UNIQUE after M3). After step 2 this
   matches only link rows for events that originated elsewhere and were linked into
   the deleted stream; those events survive, but their ids join the orphan-candidate
   set so the existing `NOT EXISTS` orphan check decides (it will keep them).
4. `deleteDeadLettersForOrphanedEventsStmt :: Statement (Vector UUID) ()` —

   ```sql
   DELETE FROM dead_letters dl
   WHERE dl.event_id = ANY($1::uuid[])
     AND NOT EXISTS (
       SELECT 1 FROM stream_events se
       WHERE se.event_id = dl.event_id
     )
   ```

   Served by the new `ix_dead_letters_event_id`. The `NOT EXISTS` mirrors
   `deleteOrphanedEventsStmt` exactly, so dead letters are purged precisely for
   events about to be orphan-deleted — dead letters of surviving (linked-in)
   events are kept, and the FK stays satisfiable.

In `kiroku-store/src/Kiroku/Store/Effect.hs`, rewire the `HardDeleteStream`
transaction body in this order (statements 1–3 first, then 4, then the existing
orphan-event and stream-row deletes; combine the two `RETURNING` vectors into one
candidate list — duplicates are harmless to `ANY`):

```haskell
originated <- Tx.statement sid SQL.deleteAllRowsForOriginStmt
Tx.statement originated SQL.deleteJunctionsByEventIdsStmt
linkedIn  <- Tx.statement sid SQL.deleteStreamOwnJunctionsStmt
let affected = originated <> linkedIn
Tx.statement affected SQL.deleteDeadLettersForOrphanedEventsStmt
Tx.statement affected SQL.deleteOrphanedEventsStmt
Tx.statement sid SQL.deleteStreamRowStmt
```

The statements run inside the same hasql transaction that already does
`SET LOCAL kiroku.enable_hard_deletes = 'on'` (later statements see earlier
statements' effects — the same reason the original code split junction and orphan
deletes; the haddock on the removed statement explains the data-modifying-CTE
snapshot rule, PostgreSQL §7.8.2: keep that explanation on the new statements).
`dead_letters` has no delete-protection trigger, so no extra GUC handling is needed.

Tests (in `kiroku-store/test/Main.hs` under the existing
`describe "hardDeleteStream"` block, or a new focused module if the block grows
unwieldy — the dead-lettering machinery to copy from is
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs`, which builds subscriptions
whose handlers return a dead-letter disposition):

- Regression: append events to a stream, dead-letter one of them through a
  subscription (or insert a `dead_letters` row directly with raw SQL through the
  pool — simpler and equally valid since the FK is what's under test), then
  `hardDeleteStream`. Before this milestone the call returns
  `Left (ConnectionError ...)` mentioning `dead_letters_event_id_fkey`; after, it
  returns `Right (Just _)`, the stream's events are gone (`countEvents` from
  `kiroku-store/test/Test/Helpers.hs`), and `SELECT count(*) FROM dead_letters`
  for those event ids is 0.
- Survival: create stream A and stream B, link an event of A into B, dead-letter
  that event, hard-delete B. The event (originating in A) must survive, and its
  dead-letter row must survive. Then hard-delete A and assert both are gone.
- The existing `f1-orphan` / `f1-keep-src` hard-delete specs in
  `kiroku-store/test/Main.hs` (around lines 851–872) must stay green — they pin the
  orphan-vs-survivor semantics the restructured deletes must preserve.

EXPLAIN evidence (capture into Surprises & Discoveries): on a dev database
(`just up`, `just create-database`, `just init-schema`, seed a few streams/events by
running any append, then `just psql`):

```sql
SET search_path TO kiroku;
-- BEFORE (run on a checkout without this milestone): full table scan
EXPLAIN DELETE FROM stream_events WHERE stream_id = 42 OR original_stream_id = 42;
--   expect: Seq Scan on stream_events
-- AFTER: each restructured statement
EXPLAIN DELETE FROM stream_events WHERE original_stream_id = 42 AND stream_id = 0;
--   expect: Index Scan (or Bitmap Index Scan) using ix_stream_events_all_by_origin
EXPLAIN DELETE FROM stream_events WHERE event_id = ANY(ARRAY['00000000-0000-7000-8000-000000000001']::uuid[]);
--   expect: Index Scan using stream_events_pkey
EXPLAIN DELETE FROM stream_events WHERE stream_id = 42;
--   expect: Index/Bitmap scan using the (stream_id, stream_version) index
-- FK-check path (the RI trigger runs the equivalent of this per deleted event):
EXPLAIN SELECT 1 FROM dead_letters WHERE event_id = '00000000-0000-7000-8000-000000000001';
--   before: Seq Scan on dead_letters; after: Index Only/Index Scan using ix_dead_letters_event_id
```

Inside a transaction you can wrap the DELETEs in `BEGIN; ... ROLLBACK;` to avoid
mutating the dev database. (Hard-delete DELETEs additionally need
`SET LOCAL kiroku.enable_hard_deletes = 'on'` inside the transaction or the
protection trigger raises — `EXPLAIN` without `ANALYZE` does not execute the
statement, so plain `EXPLAIN` works without the GUC.)

Acceptance: regression and survival tests pass; previously-green hard-delete and
dead-letter suites pass; `EXPLAIN` transcripts show no `Seq Scan on stream_events`
or `Seq Scan on dead_letters` in the after plans.

### Milestone 3 — Index hygiene and the $all hot row

Scope: one migration; no Haskell changes. Drop the unused index, make the junction
version index UNIQUE, re-key the dead-letter read index, and set `streams`
fillfactor.

Create `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql`:

```sql
-- Index hygiene and $all hot-row tuning (MasterPlan 9 / EP-5, docs/plans/60-...).

-- 1. ix_events_event_type is referenced by no statement in kiroku-store; it is
--    pure write amplification on every append. Server-side event-type pushdown
--    (see the EventTypeFilter haddock in kiroku-store) should re-add a
--    fit-for-purpose index when it ships.
DROP INDEX IF EXISTS kiroku.ix_events_event_type;

-- 2. Stream versions are unique per stream by construction (assigned under the
--    stream row lock; $all versions are the global position). Enforce it so a
--    version-assignment bug surfaces as a loud 23505 instead of silent
--    duplicates. Built as a new unique index, then the old non-unique index is
--    dropped (an index cannot be altered to unique in place).
CREATE UNIQUE INDEX IF NOT EXISTS ux_stream_events_stream_version
    ON kiroku.stream_events (stream_id, stream_version);
DROP INDEX IF EXISTS kiroku.ix_stream_events_stream_version;

-- 3. readDeadLetters orders by (global_position DESC, dead_letter_id DESC) —
--    the store's canonical, deterministic "newest first". Re-key the read
--    index to match so the read is index-ordered instead of sorting each time.
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_position
    ON kiroku.dead_letters
       (subscription_name, consumer_group_member,
        global_position DESC, dead_letter_id DESC);
DROP INDEX IF EXISTS kiroku.ix_dead_letters_subscription_created_at;

-- 4. The $all row (stream_id 0) is updated by every append in the database.
--    Its updated column (stream_version) is not indexed, so updates are
--    HOT-eligible when the page has free space; fillfactor 50 reserves that
--    space on newly written pages. Existing pages converge through normal
--    update/prune activity (VACUUM cannot run inside this migration's
--    transaction). Autovacuum tuning for this table is left to operators.
ALTER TABLE kiroku.streams SET (fillfactor = 50);
```

Ordering note: `CREATE UNIQUE INDEX` before `DROP INDEX` keeps the
`(stream_id, stream_version)` access path available throughout (reads in the same
migration window and the M2 delete statements rely on it). Migrations run before the
application opens the store (`kiroku-store-migrations/README.md`), so the table
locks taken by `CREATE INDEX` (non-concurrent) contend with nothing.

Extend `kiroku-store-migrations/test/Main.hs` with assertions (same pattern as
`assertDeadLettersTable`):

- `pg_indexes`-based check: `ix_events_event_type` and
  `ix_dead_letters_subscription_created_at` and `ix_stream_events_stream_version`
  absent; `ux_stream_events_stream_version`, `ix_dead_letters_event_id`,
  `ix_dead_letters_subscription_position` present
  (`SELECT indexname FROM pg_indexes WHERE schemaname = 'kiroku' ORDER BY 1` and
  compare the relevant members).
- Uniqueness check: `SELECT indisunique FROM pg_index WHERE indexrelid =
  'kiroku.ux_stream_events_stream_version'::regclass` is true.
- Reloptions check: `SELECT reloptions FROM pg_class WHERE oid =
  'kiroku.streams'::regclass` contains `fillfactor=50`.

EXPLAIN evidence for D (capture into Surprises & Discoveries): with a few
dead-letter rows present,

```sql
EXPLAIN SELECT global_position, event_id, reason, reason_summary, attempt_count, created_at
FROM kiroku.dead_letters
WHERE subscription_name = 'demo' AND consumer_group_member = 0
ORDER BY global_position DESC, dead_letter_id DESC;
```

Before: a `Sort` node above the index/seq scan. After: an `Index Scan using
ix_dead_letters_subscription_position` with no `Sort` node.

Acceptance: both test suites pass (the dead-letter read tests in
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs` pin the newest-first order
and must stay green, proving the re-keyed index preserves observable ordering);
`just bench-regression` shows no append regression (expect a small improvement —
one less index maintained per event insert, one less NOTIFY per append; if the
baseline predates M1, re-baseline with `just bench-baseline` and note it here).

### Milestone 4 — Stream-name length bound

Scope: reject oversized stream names with a typed error before any database work,
plus a CHECK constraint as schema-level defense in depth. This is the agreed
alternative to changing the NOTIFY payload (master-plan decision; the payload format
is a frozen contract).

Haskell changes in `kiroku-store`:

- `kiroku-store/src/Kiroku/Store/Error.hs`: add a constructor to `StoreError`:

  ```haskell
  | {- | The stream name exceeds 'maxStreamNameBytes' bytes of UTF-8. Enforced
    before any database work because the append trigger's @pg_notify@ payload
    embeds the stream name and PostgreSQL rejects payloads of 8,000 bytes or
    more — without this bound an oversized name fails at trigger time, after
    the insert work, as an opaque server error. The field is the offending
    name's UTF-8 byte length.
    -}
    StreamNameTooLong !StreamName !Int
  ```

  Place it after `ReservedStreamName` (both are pre-flight validation errors).
  Update the `mapUsageError` haddock table only if it mentions exhaustiveness;
  the constructor is produced by validation, never by error mapping.
- Define the bound and a pure check where both call sites can reach them. The
  natural home is `kiroku-store/src/Kiroku/Store/Error.hs` itself (it already owns
  `StoreError` and is imported by both `Effect.hs` and `Transaction.hs`):

  ```haskell
  -- | Maximum stream-name length in UTF-8 bytes (512). Generous for
  -- "category-identifier" names while leaving ample headroom under
  -- pg_notify's 8,000-byte payload limit (payload = name + two integer
  -- fields + two commas, so names up to ~7,960 bytes would technically fit;
  -- 512 is a deliberate policy bound, mirrored by a CHECK constraint on
  -- kiroku.streams).
  maxStreamNameBytes :: Int
  maxStreamNameBytes = 512

  -- | 'Left' with the appropriate validation error when the name is reserved
  -- or oversized; 'Right' otherwise.
  validateStreamName :: StreamName -> Either StoreError ()
  ```

  `validateStreamName` checks `name == "$all"` (returning
  `ReservedStreamName`) and then `Data.ByteString.length (Data.Text.Encoding.encodeUtf8 name) > maxStreamNameBytes`
  (returning `StreamNameTooLong`). Export both from `Error.hs` and re-export through
  the public `Kiroku.Store` module surface alongside `StoreError` (check
  `kiroku-store/src/Kiroku/Store.hs` for where `ReservedStreamName` reaches users).
- `kiroku-store/src/Kiroku/Store/Effect.hs`: replace the body of
  `rejectReservedApplicationStream` with `either throwError pure . validateStreamName . StreamName`
  (keeping the existing function name and call sites: `AppendToStream`,
  `LinkToStream`, `SoftDeleteStream`, `HardDeleteStream`, `UndeleteStream`), or
  rename it to `rejectInvalidApplicationStream` and update the five call sites —
  implementer's choice, recorded in this plan on completion. Extend the
  `AppendMultiStream` pre-check (which currently `find`s only reserved names) to
  validate every target name with `validateStreamName` and throw the first failure.
- `kiroku-store/src/Kiroku/Store/Transaction.hs`: in
  `runTransactionAppendingWith`, replace the inline `name == "$all"` guard with
  `validateStreamName`, returning `Left` with whichever error it yields (this also
  fixes the transactional path's lack of any length bound).

Create `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-03-stream-name-length-check.sql`:

```sql
-- Defense-in-depth bound on stream-name length (MasterPlan 9 / EP-5,
-- docs/plans/60-...). The Haskell store validates this before any SQL
-- (StoreError StreamNameTooLong, maxStreamNameBytes = 512); the constraint
-- catches writers that bypass the library (raw SQL via runTransaction,
-- psql sessions). 512 bytes is far below pg_notify's 8,000-byte payload
-- limit, so the append-notification trigger can never abort on payload size.
ALTER TABLE kiroku.streams
    ADD CONSTRAINT chk_streams_stream_name_length
    CHECK (octet_length(stream_name) <= 512);
```

(`ADD CONSTRAINT` validates existing rows. Any existing deployment that already
contains a longer name would fail this migration — see Idempotence and Recovery.
The bound `512` is intentionally duplicated as a literal here and as
`maxStreamNameBytes` in Haskell; the migration comment names the Haskell constant
so a future change finds both.)

Tests:

- In `kiroku-store/test/Main.hs` (a new `describe "stream name length"` near the
  reserved-name specs around line 268): a 513-byte name (e.g.
  `T.replicate 513 "a"` — ASCII, so bytes = chars; also test a multibyte case such
  as 171 × `"あ"` = 513 bytes to prove the bound is bytes, not chars) is rejected
  by `appendToStream`, `linkToStream`, `appendMultiStream`, and
  `runTransactionAppending` with `Left (StreamNameTooLong _ 513)` and creates no
  stream (`getStream` returns Nothing). A 512-byte name appends successfully —
  and (tying back to M1) delivers exactly one notification whose payload still
  parses, which the `Test.NotifyGuard` module can cover with one extra case.
- Migrations test: assert the constraint exists
  (`SELECT 1 FROM pg_constraint WHERE conname = 'chk_streams_stream_name_length' AND conrelid = 'kiroku.streams'::regclass`)
  and that a direct over-limit insert fails (`Session.statement` expecting a
  `Left`).

Acceptance: new tests pass; `cabal build all` shows no `-Wincomplete-patterns`
warnings in this repo from the new constructor (fix any site that matches
`StoreError` exhaustively, e.g. test helpers); commit message uses
`feat(kiroku-store)!:` noting the new `StoreError` constructor. Downstream note for
the final report: keiro consumes kiroku-store by git pin and will need a pin bump.


## Concrete Steps

Work from the repository root
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; all paths below are
repo-relative). The milestones are independent, but implement in order — M2's
`EXPLAIN` "before" capture is easiest while M3's index swap hasn't happened, and
M3's bench comparison is cleanest after M1.

1. Baseline: `just build` and `just test` must be green before starting. If
   benchmarking M3, also capture `just bench-baseline` now (on the pre-change tree)
   and note the commit hash here.

2. M1: add
   `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-00-notify-trigger-append-guard.sql`
   exactly as specified in Plan of Work. Then write
   `kiroku-store/test/Test/NotifyGuard.hs`, register it in
   `kiroku-store/kiroku-store.cabal` (`other-modules` plus `hasql-notifications` in
   `build-depends`) and in `kiroku-store/test/Main.hs`. Run the focused spec first
   with the migration file temporarily renamed to `.sql.disabled` to watch it fail
   (3+ notifications), restore the filename, then:

   ```bash
   cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
     --test-options='--match "NotifyGuard"'
   cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct
   ```

   Expected tail of each run:

   ```text
   Finished in ... seconds
   N examples, 0 failures
   ```

   Commit: `fix(kiroku-store-migrations): guard NOTIFY trigger to fire once per append`.

3. M2: add
   `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-01-dead-letters-event-id-index.sql`;
   edit `kiroku-store/src/Kiroku/Store/SQL.hs` (remove
   `deleteStreamJunctionsStmt` from the export list and body; add the four new
   statements and export them) and `kiroku-store/src/Kiroku/Store/Effect.hs`
   (`HardDeleteStream` case). Add the regression and survival tests; run:

   ```bash
   cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
     --test-options='--match "hardDeleteStream"'
   ```

   Capture `EXPLAIN` before/after transcripts per Plan of Work (the "before" plans
   can be captured from `git stash`-ed state or by running the old `OR` query text
   manually — the query text, not the Haskell, is what's being planned). Paste into
   Surprises & Discoveries. Commit:
   `fix(kiroku-store): purge dead letters in hard delete and index the delete path`.

4. M3: add
   `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql`;
   extend `kiroku-store-migrations/test/Main.hs` with the index/uniqueness/
   reloptions assertions. Run both suites, then `just bench-regression` (or
   `just bench-baseline` first if the old baseline predates M1; record which).
   Commit: `perf(kiroku-store-migrations): drop unused index, unique stream versions, re-key dead-letter reads, streams fillfactor`.

5. M4: edit `kiroku-store/src/Kiroku/Store/Error.hs`,
   `kiroku-store/src/Kiroku/Store/Effect.hs`,
   `kiroku-store/src/Kiroku/Store/Transaction.hs`; check
   `kiroku-store/src/Kiroku/Store.hs` re-exports; add
   `kiroku-store-migrations/sql-migrations/2026-06-11-00-00-03-stream-name-length-check.sql`;
   add tests. Run `cabal build all` (watch for incomplete-pattern warnings) and both
   suites. Commit:
   `feat(kiroku-store)!: reject oversized stream names with StreamNameTooLong`.

6. Final: `just build`, `just test` (everything: kiroku-store, migrations, metrics,
   adapter, CLI suites). Update
   `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`:
   set EP-5's registry row Status to Complete and tick its three Progress entries
   (trigger fires once / lifecycle fires nothing; FK policy decided and enforced
   with the `dead_letters(event_id)` index; junction-delete index support and index
   hygiene). Update this plan's Progress to all-checked and write the Outcomes &
   Retrospective entry. Commit: `docs(plans): complete EP-5 schema and trigger hygiene`.


## Validation and Acceptance

The change is accepted when all of the following hold, each observable by running a
command:

1. Notification behavior (M1). `cabal test kiroku-store:kiroku-store-test
   --test-options='--match "NotifyGuard"'` passes, asserting: exactly one
   notification per append batch; payload still
   `stream_name,stream_id,stream_version`; zero notifications for soft-delete and
   undelete. The full subscription suites
   (`--match "Subscription"`, Category, ConsumerGroup specs) pass unchanged,
   demonstrating end to end that publisher and category wakeups survive on half the
   notification volume. The migrations test asserts the exact trigger set on
   `kiroku.streams` under codd application.

2. Hard delete with dead letters (M2). The regression test that dead-letters an
   event and then calls `hardDeleteStream` passes, where on the pre-change tree it
   fails with `Left (ConnectionError ...)` referencing
   `dead_letters_event_id_fkey`. The survival test proves linked-in events and
   their dead letters outlive another stream's hard delete. `EXPLAIN` transcripts
   (pasted in Surprises & Discoveries) show index scans for all three junction
   deletes and the dead-letters FK probe, with no `Seq Scan on stream_events` or
   `Seq Scan on dead_letters`.

3. Index hygiene (M3). Migrations-test assertions pass: `ix_events_event_type`
   gone, `ux_stream_events_stream_version` present and unique,
   `ix_dead_letters_subscription_position` present,
   `ix_dead_letters_subscription_created_at` gone, `streams` reloptions contain
   `fillfactor=50`. The dead-letter read `EXPLAIN` shows no `Sort` node.
   `just bench-regression` reports no benchmark >10% slower.

4. Stream-name bound (M4). Appends/links/multi-appends/transactional appends with a
   513-byte name return `Left (StreamNameTooLong _ 513)` (both ASCII and multibyte
   encodings of 513 bytes) and create nothing; 512-byte names work and notify
   normally; a raw SQL insert of an over-limit name into `kiroku.streams` fails on
   `chk_streams_stream_name_length` (migrations-test assertion).

5. Whole-tree health: `just build` and `just test` exit 0. (The migrations suite
   prints codd log lines including a benign
   "DB and expected schemas do not match"-style lax-check notice in downstream
   repos; in this repo judge by the hspec `examples, 0 failures` line.)


## Idempotence and Recovery

All four migration files are written defensively (`DROP TRIGGER IF EXISTS`,
`CREATE INDEX IF NOT EXISTS`, `DROP INDEX IF EXISTS`) so re-running them against a
database that already has the changes is harmless — relevant for the
`kiroku-test-support` concatenation path and disposable dev databases. Under codd
they run once each and are recorded; codd is forward-only, so "undo" means shipping
another forward migration, never editing these files after they have been applied
anywhere that matters.

Two migrations can fail against a hypothetical existing database, and both failures
are informative rather than damaging (codd applies each migration transactionally,
so a failure leaves the database unchanged):

- `CREATE UNIQUE INDEX ux_stream_events_stream_version` fails if duplicate
  `(stream_id, stream_version)` pairs exist. That would mean the version-assignment
  invariant is already broken — exactly what the index exists to catch. Recovery:
  investigate with
  `SELECT stream_id, stream_version, count(*) FROM kiroku.stream_events GROUP BY 1, 2 HAVING count(*) > 1`,
  fix the data deliberately, re-run migrations.
- `ADD CONSTRAINT chk_streams_stream_name_length` fails if a stream name longer
  than 512 bytes already exists. Recovery: find it
  (`SELECT stream_name FROM kiroku.streams WHERE octet_length(stream_name) > 512`),
  decide its fate with the operator (such a stream is already one append away from
  trigger-time NOTIFY failure today), then re-run.

The exactly-one-NOTIFY change is behaviorally safe to roll forward and back: both
the EventPublisher and the category workers run a 30-second safety poll
(`safetyPollMicros` in
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`), so even a missed
wakeup — which the correctness trace in Context and Orientation argues cannot happen
for genuine appends — degrades to bounded latency, not a stall.

The Haskell changes (M2, M4) are ordinary library edits guarded by the test suite;
if a step fails midway, `git status` plus the per-milestone commits keep each
milestone independently revertable. The M2 transaction rewiring preserves the
existing transaction boundary and GUC handling, so a partial implementation fails
tests loudly (FK violation or protection-trigger error) rather than half-deleting:
the whole hard delete is still one atomic transaction.

Dev-database drift: if `just init-schema` was run with a work-in-progress migration
file that later changed, codd will not re-apply it. Recover with
`just reset-database` (drops and recreates the local `kiroku` database, then
re-applies all migrations). Ephemeral test databases are created fresh per run and
need nothing.


## Interfaces and Dependencies

No new package dependencies. `hasql-notifications >=0.2 && <0.3` (already a
`kiroku-store` library dependency for `Kiroku.Store.Notification`) is added to the
`kiroku-store-test` suite's `build-depends` in `kiroku-store/kiroku-store.cabal` for
the LISTEN-based M1 test. `bytestring` and `text` (already test deps) cover the
byte-length checks.

Schema interface at completion (all in the `kiroku` schema, created only via the
four new migration files):

- Triggers on `streams`: `stream_events_notify_insert` (AFTER INSERT, WHEN
  `NEW.stream_id <> 0`) and `stream_events_notify_update` (AFTER UPDATE, WHEN
  `NEW.stream_id <> 0 AND NEW.stream_version IS DISTINCT FROM OLD.stream_version`),
  both executing the unchanged `kiroku.notify_events()`; `stream_events_notify` no
  longer exists. The NOTIFY channel (`kiroku.events`) and payload
  (`stream_name,stream_id,stream_version`) are unchanged — this is a frozen
  contract with `Kiroku.Store.Notification.categoryFromPayload`.
- Indexes: `ux_stream_events_stream_version` UNIQUE `(stream_id, stream_version)`
  replaces `ix_stream_events_stream_version`; `ix_dead_letters_event_id
  (event_id)` added; `ix_dead_letters_subscription_position (subscription_name,
  consumer_group_member, global_position DESC, dead_letter_id DESC)` replaces
  `ix_dead_letters_subscription_created_at`; `ix_events_event_type` dropped.
- Constraints: `chk_streams_stream_name_length CHECK (octet_length(stream_name) <=
  512)` on `streams`; `dead_letters_event_id_fkey` stays `NO ACTION` by decision.
- Storage: `streams` has `fillfactor=50`.

Haskell interface at completion:

- `Kiroku.Store.Error` (module
  `kiroku-store/src/Kiroku/Store/Error.hs`) exports the enlarged
  `StoreError` (new constructor `StreamNameTooLong !StreamName !Int`), plus
  `maxStreamNameBytes :: Int` and
  `validateStreamName :: StreamName -> Either StoreError ()`; re-exported wherever
  `StoreError` already reaches the public `Kiroku.Store` surface. Breaking change
  for exhaustive matchers (`feat(kiroku-store)!:`); keiro needs a git-pin bump to
  see it.
- `Kiroku.Store.SQL` (internal module `kiroku-store/src/Kiroku/Store/SQL.hs`):
  `deleteStreamJunctionsStmt` removed; added
  `deleteAllRowsForOriginStmt :: Statement Int64 (Vector UUID)`,
  `deleteJunctionsByEventIdsStmt :: Statement (Vector UUID) ()`,
  `deleteStreamOwnJunctionsStmt :: Statement Int64 (Vector UUID)`,
  `deleteDeadLettersForOrphanedEventsStmt :: Statement (Vector UUID) ()`.
  `readDeadLettersSQL` text unchanged.
- `Kiroku.Store.Effect` (`kiroku-store/src/Kiroku/Store/Effect.hs`): the
  `HardDeleteStream` interpreter case uses the four statements in the documented
  order; all stream-name-accepting cases validate through `validateStreamName`.
- `Kiroku.Store.Transaction` (`kiroku-store/src/Kiroku/Store/Transaction.hs`):
  `runTransactionAppendingWith` validates via `validateStreamName`.
- `kiroku-store-migrations` exposes nothing new; its embedded migration list grows
  by four files automatically through `embedDir` in
  `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs`.
