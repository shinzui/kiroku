# Prepare schema and CTEs for pg_partman time-based partitioning

Intention: intention_01kmtf2w1vehcvdfq34kxkyrkm

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Status: PARKED (2026-04-29)

This plan is parked pending real workload pressure. The current schema is sufficient for present and near-term use cases. Pre-optimizing for pg_partman now adds permanent overhead and introduces a `DuplicateEvent` regression (see Known Defects below) in exchange for benefits that only materialize at billion-row scale.

### Triggers to unpark

Execute this plan when **any** of the following becomes true:

- The `events` table exceeds ~100M rows.
- Sustained ingestion exceeds 100K events/day for 30 days.
- A retention requirement (regulatory, customer, or cost-driven) demands the ability to drop old data quickly. `DETACH PARTITION` / `DROP PARTITION` is the only scalable answer to that, and it requires the schema changes in this plan.
- A planned customer or workload projects volumes that would cross 100M rows within 6 months.

When unparked, this work must be combined with the decision to extract schema management into a `kiroku-migrate` package (per the existing project decision in auto-memory `project_schema_migration.md` — first non-trivial DDL is the trigger).

### Why parked, not abandoned

The research in `docs/SCALING-ANALYSIS.md` and `docs/PG-PARTMAN.md` is sound and remains the playbook for the day this is needed. The mechanical changes described in the milestones below are still correct in shape — they answer a question that does not need answering yet. At under ~100M rows, vanilla B-tree indexes give sub-millisecond stream reads on SSD, and the operational pain partitioning solves (slow `VACUUM`, expensive bulk deletes, retention sweeps) does not yet exist for kiroku.


## Known Defects (must resolve before unparking)

These were discovered during plan review on 2026-04-29 and are **not** reflected in the milestone bodies below. Any future implementation must resolve them; the milestones as currently written would ship a regression.

### Defect 1 — Composite PK silently breaks `DuplicateEvent` detection

`Kiroku.Store.Error.mapUniqueViolation` (`kiroku-store/src/Kiroku/Store/Error.hs`) maps unique-violation `23505` on constraint name `events_pkey` to `DuplicateEvent`. Today this fires when the same `event_id` is inserted twice (e.g. a retried append after a network blip).

After Milestone 1, `events_pkey` becomes `(event_id, created_at)`. A retried append with the same `event_id` but a different timestamp produces a different composite key — no conflict is raised, both rows insert silently, and `DuplicateEvent` is never returned. The store quietly accepts duplicates.

The note in `docs/PG-PARTMAN.md` ("`event_id` uniqueness is still guaranteed in practice by UUIDv7 generation") is misleading: UUIDv7 prevents *fresh* collisions, not retries that re-submit the same id. Detecting those retries is exactly what `DuplicateEvent` exists for.

Mitigations to choose between when implementing:

- **(A) Bridge constraint.** Add a plain `UNIQUE (event_id)` on `events` while it is still non-partitioned, named e.g. `events_event_id_key`. Map that name alongside `events_pkey` in `Error.hs`. The constraint must be dropped at actual partition cutover, since a partitioned table cannot carry a UNIQUE that omits the partition key. Cleanest preservation of existing semantics for the pre-partition era.
- **(B) Explicit CTE check.** Add `NOT EXISTS (SELECT 1 FROM events WHERE event_id = …)` to `inserted_events` and surface a sentinel for the duplicate case. Heavier; changes append semantics from "constraint-driven" to "application-driven."
- **(C) Accept the regression.** Document the loss of `DuplicateEvent` detection. Likely wrong — `DuplicateEvent` is a documented public error in the store API.

### Defect 2 — `DEFAULT now()` becomes a partition-routing footgun

The plan keeps `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` on `stream_events` *permanently* as scaffolding for the staged Milestone 1 → 2 rollout. Once the tables are actually partitioned by `created_at`, any future INSERT that forgets to supply the value writes `now()` — routing to *today's* partition — while the matching `events` row may live in an older partition (backfills, replays, late-arriving events with stale timestamps).

When retention later drops the old `events` partition, orphan `stream_events` rows survive in newer partitions, silently breaking `JOIN events e ON e.event_id = se.event_id` for the affected window.

**Fix:** treat `DEFAULT now()` as Milestone-1-only scaffolding. Drop the default at the end of Milestone 2, leaving the column `NOT NULL` with no default, so any missed propagation surfaces immediately as a write-time error instead of a silent partition mismatch. Add this step to Milestone 2 progress.

### Defect 3 — Plan claims "no new tests needed"; wrong for this column

The Validation section argues that any CTE mistake would surface as a SQL syntax error or column mismatch caught by the existing test suite. This is incorrect for the specific case of forgetting to propagate `ne.created_at`: with `DEFAULT now()` in place, the INSERT silently succeeds with a wrong-but-valid timestamp, and no existing test compares `stream_events.created_at` to `events.created_at`.

**Fix:** add one Milestone 2 test that joins `stream_events` to `events` on `event_id` and asserts equality of `created_at` after each append variant. This guards both the initial CTE rollout and any future regression that re-introduces a `DEFAULT now()` shortcut.

### Open question — `kiroku-migrate` package extraction

This plan is the trigger event identified in `project_schema_migration.md` (first non-trivial DDL change since the original schema). When unparked, decide *before* starting Milestone 1 whether to extract `kiroku-migrate` first and land this plan as that package's first migration, or defer the extraction with an explicit justification logged in the Decision Log.


## Purpose / Big Picture

At high event volumes (millions of events per day), the `events` and `stream_events` tables need to be partitioned by time so that old data can be detached, archived, or dropped without touching active data. PostgreSQL declarative partitioning requires the partition key to appear in every unique constraint, and the `stream_events` table currently lacks a `created_at` column entirely.

This plan makes the schema "partition-ready" by performing the minimal structural changes identified in the research document at `docs/PG-PARTMAN.md`. After this work, the schema can be converted to partitioned tables via pg_partman with no further DDL or application code changes. The actual pg_partman conversion is a separate future step.

Concretely, after this plan:

- The `stream_events` table has a `created_at` column populated from the event's timestamp during every append.
- Both `events` and `stream_events` have composite primary keys that include `created_at`, satisfying PostgreSQL's partition-key-in-unique-constraint requirement.
- The foreign key from `stream_events.event_id` to `events.event_id` is removed, since a partitioned `events` table cannot support a single-column unique constraint on `event_id`.
- All existing tests pass without modification.


## Progress

> **PARKED.** All milestones below are blocked on the Known Defects section above. Do not start implementation until trigger criteria are met *and* the defects are resolved. The milestone bodies below are preserved as the future-work playbook; they are intentionally left in their original form so the resolution of each defect can be folded in as part of the unparking work.

- [ ] Milestone 1: Schema DDL changes in `kiroku-store/sql/schema.sql`
  - [ ] Add `created_at` column to `stream_events` table definition
  - [ ] Change `events` primary key from `(event_id)` to `(event_id, created_at)`
  - [ ] Change `stream_events` primary key from `(event_id, stream_id)` to `(event_id, stream_id, created_at)`
  - [ ] Remove `REFERENCES events(event_id)` from `stream_events.event_id`
  - [ ] Verify tests pass with schema changes alone (CTEs rely on `DEFAULT now()`)
- [ ] Milestone 2: Propagate `created_at` in Haskell CTEs (`kiroku-store/src/Kiroku/Store/SQL.hs`)
  - [ ] Update `source_links` and `all_links` in `appendExpectedVersionSQL`
  - [ ] Update `source_links` and `all_links` in `appendStreamExistsSQL`
  - [ ] Update `source_links` and `all_links` in `appendNoStreamSQL`
  - [ ] Update `source_links` and `all_links` in `appendAnyVersionSQL`
  - [ ] Update `link_inserts` in `linkToStreamSQL`
  - [ ] Verify tests pass
- [ ] Milestone 3: Update benchmark SQL files
  - [ ] Update `source_links` and `all_links` in all 8 benchmark append files
  - [ ] Update `setup.sql` manual `stream_events` inserts
  - [ ] Verify benchmarks run


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Scope this plan to schema readiness only, not the actual pg_partman conversion.
  Rationale: Converting existing tables to partitioned tables requires pg_partman's migration tooling or a `CREATE TABLE ... PARTITION BY RANGE` with data copy. That is an operational concern best handled before production traffic ramps up, and is independent of the code changes here.
  Date: 2026-03-28

- Decision: Drop the foreign key from `stream_events.event_id` to `events.event_id`.
  Rationale: On a partitioned `events` table, only `UNIQUE(event_id, created_at)` is possible, which cannot be the target of a single-column FK. Referential integrity between `events` and `stream_events` is already guaranteed by the append CTEs, which insert into both tables atomically within a single CTE. The FK from `stream_events.stream_id` to `streams.stream_id` is unaffected since `streams` is not partitioned.
  Date: 2026-03-28

- Decision: Use `DEFAULT now()` on the new `stream_events.created_at` column so that schema changes and CTE changes can be done in separate milestones.
  Rationale: With the default in place, existing CTEs that do not yet propagate `created_at` will still produce valid rows. This allows milestone 1 (schema) to be verified independently of milestone 2 (CTE changes).
  Date: 2026-03-28

- Decision: Fetch `created_at` from the `events` table in the link CTE rather than from the LATERAL join on `stream_events`.
  Rationale: The `events.created_at` is the canonical source of truth for an event's timestamp. Fetching it from `stream_events` would depend on that row's `created_at` having been correctly populated by a prior append or backfill. Joining `events` directly avoids this dependency.
  Date: 2026-03-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL-backed event store. Its core schema lives in `kiroku-store/sql/schema.sql` and is applied idempotently on startup via `Kiroku.Store.Schema.initializeSchema`, which embeds the SQL at compile time using TemplateHaskell `embedFile`. There is no external migration tool; the schema uses `CREATE TABLE IF NOT EXISTS` and is designed for fresh database setup in development and testing. The test suite uses `EphemeralPg` to create isolated PostgreSQL instances per test, so schema changes take effect automatically.

Four tables make up the schema. `streams` tracks named streams with a version counter; the reserved row `stream_id = 0` is the `$all` global stream. `events` stores immutable event facts keyed by UUIDv7. `stream_events` is a junction table linking events to streams, carrying both the source stream position and the global (`$all`) position. `subscriptions` stores checkpoint positions for catch-up subscribers.

The application's write path consists of four append CTE variants in `kiroku-store/src/Kiroku/Store/SQL.hs`. Each CTE follows the same structure: `new_events` (unnest parameters with ORDINALITY) then a stream update/insert/upsert, then `inserted_events` (INSERT into `events`), then `source_links` (INSERT into `stream_events` for the source stream), then `all_update` (atomic increment on the `$all` row), then `all_links` (INSERT into `stream_events` for `$all`). A separate link CTE (`linkToStreamSQL`) links existing events into a new or existing stream.

There are also 8 standalone SQL files in `kiroku-store/bench/sql/` used for pgbench benchmarks. Each contains a CTE that mirrors the Haskell append pattern.

Two immutability triggers prevent UPDATE and DELETE on `events` and `stream_events` (the delete trigger is gated by a session variable for maintenance). A NOTIFY trigger on `streams` fires on INSERT or UPDATE to signal new events.

Error mapping in `kiroku-store/src/Kiroku/Store/Error.hs` converts PostgreSQL error codes to domain errors. Code `23505` (unique_violation) is matched against constraint names: `events_pkey` maps to `DuplicateEvent`, `ix_streams_stream_name` maps to `StreamAlreadyExists`, and anything else maps to `WrongExpectedVersion`. Code `23503` (foreign_key_violation) maps to `StreamNotFound`. After dropping the FK from `stream_events` to `events`, the only remaining FK that can trigger `23503` is `stream_events.stream_id REFERENCES streams.stream_id`, so the `StreamNotFound` mapping remains correct.


## Plan of Work

The work proceeds in three milestones. Each milestone leaves the codebase in a fully working state with all tests passing.


### Milestone 1 — Schema DDL changes

This milestone modifies the table definitions in `kiroku-store/sql/schema.sql` to make the schema partition-ready. No Haskell code changes are needed. After this milestone, all tests pass because the new `stream_events.created_at` column has `DEFAULT now()`, so CTEs that do not yet propagate the timestamp will still produce valid rows.

The file `kiroku-store/sql/schema.sql` requires four changes to the `events` and `stream_events` table definitions:

**Change 1: Composite primary key on `events`.** The `events` table currently defines the primary key inline on the `event_id` column (line 25: `event_id UUID PRIMARY KEY DEFAULT uuidv7()`). Change this to `event_id UUID NOT NULL DEFAULT uuidv7()` (remove the inline `PRIMARY KEY`, add explicit `NOT NULL`) and add a table-level constraint `PRIMARY KEY (event_id, created_at)` after the `created_at` column. The constraint will be named `events_pkey` by PostgreSQL convention, which matches the error mapping in `kiroku-store/src/Kiroku/Store/Error.hs`.

**Change 2: Add `created_at` to `stream_events`.** Add a new column `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` to the `stream_events` table, after the `original_stream_version` column.

**Change 3: Drop the foreign key from `stream_events.event_id` to `events.event_id`.** Remove `REFERENCES events(event_id)` from the `event_id` column definition on line 36. The column definition becomes `event_id UUID NOT NULL`. The FK from `stream_id` to `streams.stream_id` on line 37 is unchanged.

**Change 4: Composite primary key on `stream_events`.** Change `PRIMARY KEY (event_id, stream_id)` to `PRIMARY KEY (event_id, stream_id, created_at)`.

No changes to indexes, triggers, functions, or the `subscriptions` table.

After applying these changes, run the test suite. Since `EphemeralPg` creates a fresh database for each test, the new schema takes effect immediately. The existing CTEs insert into `stream_events` without specifying `created_at`, so PostgreSQL uses the `DEFAULT now()` value.

Acceptance: `cabal test` passes. Inspecting the schema of a fresh test database (or `kiroku` dev database after `just reset-database`) shows the composite PKs and the new column.


### Milestone 2 — Propagate `created_at` in Haskell CTEs

This milestone updates the SQL CTE templates in `kiroku-store/src/Kiroku/Store/SQL.hs` so that every INSERT into `stream_events` explicitly sets `created_at` to the event's actual timestamp, rather than relying on the `DEFAULT now()`.

All four append CTE variants (`appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`, `appendAnyVersionSQL`) share the same structure. Each has two INSERT-into-`stream_events` CTEs: `source_links` (for the source stream) and `all_links` (for the `$all` stream). The change is identical in all eight locations.

In the `source_links` CTE, add `created_at` to the INSERT column list and `ne.created_at` to the SELECT list. In the `all_links` CTE, do the same. The `new_events` CTE already carries `created_at` from the unnested parameter arrays, so the value is available in both CTEs via `ne.created_at`.

For `appendExpectedVersionSQL` and `appendStreamExistsSQL`, the stream CTE alias is `stream_update` (aliased `su`). For `appendNoStreamSQL`, it is `stream_insert` (aliased `si`). For `appendAnyVersionSQL`, it is `stream_upsert` (aliased `su`). Only the column list and SELECT list of `source_links` and `all_links` change; the stream alias references remain the same.

The link CTE (`linkToStreamSQL`) also inserts into `stream_events` via the `link_inserts` CTE. Unlike the append CTEs, the link CTE operates on events that already exist in the `events` table. To get the event's `created_at`, add a `JOIN events e ON e.event_id = el.event_id` to the `link_inserts` SELECT, and include `e.created_at` in the INSERT column list.

Specifically, the `link_inserts` CTE currently reads:

    link_inserts AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
               orig.original_stream_id, orig.original_stream_version
        FROM event_list el
        CROSS JOIN stream_upsert su
        JOIN LATERAL (
          SELECT se.original_stream_id, se.original_stream_version
          FROM stream_events se
          WHERE se.event_id = el.event_id AND se.stream_id <> 0
          LIMIT 1
        ) orig ON true
      )

After the change:

    link_inserts AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, created_at)
        SELECT el.event_id, su.stream_id, su.initial_version + el.idx,
               orig.original_stream_id, orig.original_stream_version,
               e.created_at
        FROM event_list el
        CROSS JOIN stream_upsert su
        JOIN events e ON e.event_id = el.event_id
        JOIN LATERAL (
          SELECT se.original_stream_id, se.original_stream_version
          FROM stream_events se
          WHERE se.event_id = el.event_id AND se.stream_id <> 0
          LIMIT 1
        ) orig ON true
      )

No changes to the `AppendParams` type, encoders, decoders, or any other Haskell module.

Acceptance: `cabal test` passes.


### Milestone 3 — Update benchmark SQL files

This milestone updates the standalone SQL files in `kiroku-store/bench/sql/` to match the schema changes. These files are used with pgbench and are not embedded in the Haskell build, so compilation is unaffected. The purpose is to keep the benchmarks runnable against the updated schema.

Eight benchmark files contain append CTEs with `source_links` and `all_links` that insert into `stream_events`. The change is identical to milestone 2: add `created_at` to the INSERT column list and `ne.created_at` to the SELECT. The files are:

- `kiroku-store/bench/sql/bench_append_single.sql`
- `kiroku-store/bench/sql/bench_append_batch_10.sql`
- `kiroku-store/bench/sql/bench_append_batch_100.sql`
- `kiroku-store/bench/sql/bench_append_batch_1000.sql`
- `kiroku-store/bench/sql/bench_append_concurrent.sql`
- `kiroku-store/bench/sql/bench_append_concurrent_batch.sql`
- `kiroku-store/bench/sql/bench_mixed_write.sql`
- `kiroku-store/bench/sql/bench_mixed.sql`

In each file, the `source_links` CTE changes from:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx

to:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, created_at)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx,
           ne.created_at

And the `all_links` CTE changes from:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx

to:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, created_at)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx,
           ne.created_at

The `setup.sql` file (`kiroku-store/bench/sql/setup.sql`) also inserts into `stream_events` directly in the PL/pgSQL block that populates 100K events. The two INSERT statements (lines 91-93 for source stream links, lines 96-98 for `$all` links) need `created_at` added. Since the setup block uses `unnest(v_created_at)` for the `events` INSERT, the same array is available. Add a `created_at` column to both INSERTs and use `v_created_at[g]` as the value (matching the array indexing pattern already used for `v_event_ids[g]`).

Specifically, the source stream link INSERT changes from:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
    SELECT v_event_ids[g], v_stream_id, v_stream_version + g, v_stream_id, v_stream_version + g
    FROM generate_series(1, v_batch_size) AS g;

to:

    INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, created_at)
    SELECT v_event_ids[g], v_stream_id, v_stream_version + g, v_stream_id, v_stream_version + g, v_created_at[g]
    FROM generate_series(1, v_batch_size) AS g;

And the `$all` link INSERT changes identically (add `created_at` column and `v_created_at[g]` value).

Acceptance: after `just reset-database` and `psql -d kiroku -f kiroku-store/bench/sql/setup.sql`, the setup completes without errors and `SELECT created_at FROM stream_events LIMIT 1` returns a non-null timestamp.


## Concrete Steps

All commands are run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

**Milestone 1:**

Edit `kiroku-store/sql/schema.sql` as described in milestone 1. Then run:

    cabal test kiroku-store

Expected: all tests pass. If any test fails, inspect the error for constraint name mismatches.

**Milestone 2:**

Edit `kiroku-store/src/Kiroku/Store/SQL.hs` as described in milestone 2. Then run:

    cabal test kiroku-store

Expected: all tests pass.

**Milestone 3:**

Edit the 8 benchmark SQL files and `setup.sql` as described in milestone 3. Verify by resetting the dev database and running setup:

    just reset-database
    psql -d kiroku -f kiroku-store/bench/sql/setup.sql

Expected: setup completes with the notice `Setup complete: 100 streams x 1000 events = 100000 total events`.


## Validation and Acceptance

The primary validation is the existing test suite. Run `cabal test kiroku-store` after each milestone. The test suite exercises all four append variants, batch appends, global position contiguity, duplicate event detection, read operations (forward/backward, stream/`$all`/category), lifecycle (soft delete, undelete), multi-stream transactions, and linking. If all tests pass, the schema and CTE changes are correct.

For the benchmark files, verify that `setup.sql` runs without errors against a fresh database with the new schema.

No new tests are needed because:

- The schema changes are structural (PKs, FKs, column addition) and are validated by the existing test suite running against the new DDL.
- The CTE changes are mechanical (adding one column and one value to existing INSERT statements) and any mistake would cause a SQL syntax error or column mismatch that the test suite would catch.
- The `created_at` value propagation is verified implicitly: if the wrong number of columns were inserted, PostgreSQL would raise an error caught by the test.


## Idempotence and Recovery

Each milestone's changes are to source files (`schema.sql`, `SQL.hs`, benchmark `.sql` files). The changes can be re-applied safely by re-editing the files. There is no database state to corrupt because:

- `EphemeralPg` creates a fresh database per test, so test runs are always against the current schema.
- The dev database can be fully reset with `just reset-database`.
- The `schema.sql` file uses `CREATE TABLE IF NOT EXISTS`, so re-applying it to an empty database is idempotent.

For existing databases that already have data under the old schema, a migration script is needed. This is documented in `docs/PG-PARTMAN.md` under "Migration DDL" and is out of scope for this plan. One important caveat for that future migration: the `prevent_mutation` trigger on `stream_events` prevents UPDATE statements, so the backfill step (`UPDATE stream_events SET created_at = e.created_at FROM events e ...`) would require temporarily dropping and recreating the `no_update_stream_events` trigger.


## Interfaces and Dependencies

No new dependencies. No changes to Haskell types, encoders, decoders, effect interpreters, or the public API. The only interface change is the PostgreSQL DDL:

After milestone 1, `stream_events` gains:

    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()

After milestone 1, `events` PK changes from `PRIMARY KEY (event_id)` to `PRIMARY KEY (event_id, created_at)`. The constraint name remains `events_pkey`.

After milestone 1, `stream_events` PK changes from `PRIMARY KEY (event_id, stream_id)` to `PRIMARY KEY (event_id, stream_id, created_at)`. The constraint name remains `stream_events_pkey`.

After milestone 1, the FK `stream_events.event_id REFERENCES events(event_id)` is removed. The FK `stream_events.stream_id REFERENCES streams(stream_id)` is unchanged.
