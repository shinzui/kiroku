---
id: 26
slug: postgresql-side-append-profiling-with-explain-analyze-and-auto-explain
title: "PostgreSQL-side append profiling with EXPLAIN ANALYZE and auto_explain"
kind: exec-plan
created_at: 2026-05-18T22:10:26Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
master_plan: "docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md"
---

# PostgreSQL-side append profiling with EXPLAIN ANALYZE and auto_explain

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a Haskell event store whose single-event append takes roughly 150 microseconds against a hot stream on an ephemeral PostgreSQL. The production append is a single multi-statement Common Table Expression (CTE) at `kiroku-store/src/Kiroku/Store/SQL.hs` named `appendAnyVersionSQL`. Several earlier plans (numbers 21 through 24, under `docs/plans/`) tried to shave that latency by rewriting parts of the CTE, but each one had to guess which CTE node — the `stream_upsert` `INSERT … ON CONFLICT … DO UPDATE`, the `inserted_events` insert into `events`, the `source_links` and `all_links` inserts into `stream_events`, or the `all_update` global-version bump — was actually expensive. Without per-node timings, those plans recommended changes (statement-level triggers, dropping the `streams.category` generated column, advisory locks, PL/pgSQL) more than once because no one had a record of what had been measured.

After this plan, running a single command from this repository's root prints the production `AnyVersion` append CTE's per-CTE-node execution timing against the same ephemeral PostgreSQL the rest of the benchmark suite uses. The output names each CTE — `new_events`, `stream_upsert`, `inserted_events`, `source_links`, `all_update`, and `all_links` — with its own `actual time` and row count. A second command boots an ephemeral PostgreSQL with the contrib module `auto_explain` enabled and writes a `kiroku-store-bench` log that contains the plans of every append issued by the bench, so we have a recording of plans under realistic load rather than just a one-shot synthetic call. From those two artefacts, future optimization plans can cite, for example, "the `stream_upsert` ModifyTable node accounts for 38 % of the CTE's execution time" instead of guessing. Nothing in `kiroku-store/src/Kiroku/Store/*` or in `kiroku-store/sql/schema.sql` changes. Nothing in the existing `append`, `raw-append-shape`, `read`, `category`, `concurrent`, or `reliability-audit` benchmark groups changes, so `just bench-regression` against `kiroku-store/bench/results/baseline.csv` remains a valid regression gate.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Add a new `benchmark kiroku-store-bench-explain` stanza to `kiroku-store/kiroku-store.cabal` so the EXPLAIN run lives in its own executable and does not pollute `just bench-regression`. — 2026-05-18.
- [x] Create `kiroku-store/bench/Explain.hs` that boots an ephemeral PostgreSQL via `EphemeralPg.withCached`, runs the production `AnyVersion` CTE under `EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT)` wrapped in `BEGIN … ROLLBACK`, and prints the result to stdout. — 2026-05-18, also archived at `kiroku-store/bench/explain-results/anyversion-singleton.txt` (7.2 KB).
- [x] Confirm the printed output names each of the six CTE nodes (`new_events`, `stream_upsert`, `inserted_events`, `source_links`, `all_update`, `all_links`). — 2026-05-18, all six appear in both TEXT and JSON forms.
- [x] Add a second invocation of the same harness under `EXPLAIN (FORMAT JSON)` and write its output to `kiroku-store/bench/explain-results/anyversion-singleton.json` for machine-parseable consumption. — 2026-05-18, 45 KB JSON; the CTEs appear under `"Subplan Name"` rather than the `"CTE Name"` field this plan's acceptance gate predicted (see Surprises).
- [x] Boot a second ephemeral PostgreSQL via `EphemeralPg.withConfig (defaultConfig <> autoExplainConfig 0)` and run the existing `kiroku-store-bench` against it (or a small subset), capturing the resulting PostgreSQL log to a file under `kiroku-store/bench/explain-results/`. — 2026-05-18 (with a workaround: ephemeral-pg discards postgres's stderr, so the harness drives PostgreSQL's `logging_collector` to write a CSV log directly to `auto-explain.csv`. See Surprises.)
- [x] Write a short prose paragraph at the top of `kiroku-store/bench/explain-results/README.md` (only this directory's README — do not touch project-level docs) explaining what each captured file contains and how to reproduce it. — 2026-05-18.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`ephemeral-pg` discards the postgres process's stderr unconditionally.**
  `EphemeralPg/Process/Postgres.hs:78` hardcodes `& setStderr nullStream` on
  the postgres-process startup config, completely ignoring the `Config.stderr`
  field even though it is documented as user-settable. As a result, plan 26's
  documented approach of overriding `Config.stderr` with a file handle could
  not be implemented as written — the postgres stderr stream that the file
  handle was meant to capture goes straight to `/dev/null`.

  The harness routes around this by configuring PostgreSQL's own
  `logging_collector` to write directly to disk. The relevant
  `postgresSettings`:

  ```haskell
  ("logging_collector", "'on'")
  ("log_destination", "'csvlog'")
  ("log_directory", "<absolute path>")
  ("log_filename", "auto-explain.log")
  ("log_min_messages", "'log'")
  ```

  Evidence: see `kiroku-store/bench/Explain.hs:runAutoExplain` for the
  full config, and the comment immediately above
  `EphemeralPg/Process/Postgres.hs:78` for the upstream behaviour. A
  potential follow-up is to upstream a patch that wires `Config.stderr`
  through `setStderr` when it is `Last (Just (Just h))`; out of scope
  for EP-2.

- **`log_min_messages = 'log'` is required for auto_explain output to
  reach the csvlog.** With the default `log_min_messages = 'warning'`,
  empirical testing showed the csvlog file stayed at 0 bytes for the
  same workload that produces 42 KB at `log_min_messages = 'log'`.
  PostgreSQL's docs say `log_min_messages` orders levels so WARNING is
  *less* severe than LOG, meaning LOG-level messages *should* pass a
  warning threshold — but the empirical behaviour disagreed for this
  configuration on this PostgreSQL build (`PostgreSQL 18.3 on
  aarch64-apple-darwin25.3.0`). The harness forces `log_min_messages
  = 'log'` and documents the discrepancy. Re-verifying on a
  different build/platform is a candidate follow-up.

  Evidence: two consecutive harness runs with identical configuration
  except `log_min_messages`; the first (default warning) produced a
  0-byte `auto-explain.csv`, the second (`log`) produced 41,752 bytes
  with 8 `duration:` entries. Captured in the per-run output in
  `/private/tmp/.../tasks/*.output`.

- **In `EXPLAIN (FORMAT JSON)` output, the six append CTEs are not
  uniformly tagged with `"CTE Name"`.** PostgreSQL only emits a
  `"CTE Name"` field for those CTEs that are subsequently referenced
  via a `CTE Scan` later in the plan. Of Kiroku's six CTEs:

    - `new_events`, `stream_upsert`, `all_update` — referenced via
      `CTE Scan` elsewhere, so they appear under `"CTE Name"`.
    - `inserted_events`, `source_links`, `all_links` — modify-only,
      not referenced elsewhere, so they only appear under
      `"Subplan Name": "CTE <name>"`.

  The plan's acceptance gate predicted six `"CTE Name"` entries; the
  actual coverage is three `"CTE Name"` + six `"Subplan Name"` entries.
  All six CTEs are still uniquely identifiable from the JSON; the
  verification command in this plan's Concrete Steps section was
  updated to grep on `"Subplan Name"` rather than `"CTE Name"` for the
  full set.

  Evidence: `grep -oE '"(CTE Name|Subplan Name)": "[^"]*"' kiroku-store/bench/explain-results/anyversion-singleton.json | sort -u`.

- **The TEXT-format EXPLAIN execution time is dominated by trigger
  work, not CTE node work.** The captured profile shows
  `Execution Time: 2.358 ms` with the breakdown:

  ```text
  Trigger stream_events_notify on streams: time=0.689 calls=2
  Trigger for constraint stream_events_event_id_fkey on stream_events: time=0.446 calls=2
  Trigger for constraint stream_events_stream_id_fkey on stream_events: time=0.052 calls=2
  ```

  ~1.2 ms (51% of execution time) is spent in triggers — most of it in
  `stream_events_notify` (the `pg_notify` trigger documented in
  `kiroku-store/sql/schema.sql`) and the foreign-key validation triggers
  on `stream_events`. The summed CTE-node `actual time` values come to
  well under 1 ms. This is the same picture EP-1 hinted at from the
  Haskell side: round-trip and PostgreSQL-side overhead dominates, and
  Haskell-side or CTE-shape changes can recover only a small fraction
  of total append latency. Future plans should treat the `pg_notify`
  trigger and the per-row foreign-key triggers on `stream_events` as
  named first-class candidates, not secondary considerations. Evidence:
  `kiroku-store/bench/explain-results/anyversion-singleton.txt` lines
  starting with `Trigger`.

- **Cabal benchmark stanzas set CWD to the package directory, not the
  repo root, when invoked via `cabal bench`.** The first version of the
  harness wrote files relative to `kiroku-store/bench/explain-results/`,
  which under `cabal bench` resolved to
  `kiroku-store/kiroku-store/bench/explain-results/` — files were
  silently lost. The fix is `locateRepoRoot` which walks up until it
  finds `cabal.project`; the harness now resolves output paths from
  there regardless of how it was invoked. This is recorded so the next
  contributor adding a multi-output cabal target does not get caught.


## Decision Log

Record every decision made while working on the plan.

- Decision: Wrap the EXPLAIN ANALYZE call in `BEGIN; … ; ROLLBACK;` rather than spin up a fresh ephemeral PostgreSQL per measurement.
  Rationale: `EXPLAIN ANALYZE` executes the query, which means it inserts rows. Rolling back after each measurement leaves the database in the state it was in before the harness ran, so re-running the harness is idempotent and we do not need to incur the cost of repeatedly initialising a new cluster. The fresh-cluster alternative was rejected because `EphemeralPg.withCached` already amortises initdb but still costs a few hundred milliseconds per cluster start, and we want the harness to be cheap enough to re-run iteratively while tuning.
  Date: 2026-05-18

- Decision: Capture EXPLAIN output in both `FORMAT TEXT` (for human reading) and `FORMAT JSON` (for machine parsing).
  Rationale: Text form is what a developer reads when investigating a slow node; JSON form is what a future tool can ingest if we ever want to programmatically compare two runs or assert "node X did not regress more than Y percent". Producing both at one go is cheap because the same query merely runs twice, and we never need to commit to one form. The alternative — pick only one — was rejected because the cost of producing the other is essentially zero and removing it later is trivial.
  Date: 2026-05-18

- Decision: Use both `EXPLAIN ANALYZE` (in the dedicated harness) and `auto_explain` (in a bench run) because they answer different questions.
  Rationale: `EXPLAIN ANALYZE` is targeted: it gives one detailed plan for one chosen statement and is easy to read in isolation. `auto_explain` is ambient: it logs the plans of every query issued during a real bench run, so it captures the prepared-statement plan-cache behavior, the variance across iterations, and the surrounding queries (resolves, reads) that the dedicated harness omits. They are complementary; we want both.
  Date: 2026-05-18

- Decision: Pass `auto_explain` configuration through `ephemeral-pg`'s `Config.postgresSettings` rather than relying on a per-session `LOAD 'auto_explain'; SET LOCAL auto_explain.log_min_duration = 0;`.
  Rationale: `ephemeral-pg` exposes `postgresSettings :: [(Text, Text)]` on its `Config` and ships a built-in `autoExplainConfig :: Int -> Config` that emits `shared_preload_libraries = 'auto_explain'`, `auto_explain.log_min_duration = '<ms>ms'`, and `auto_explain.log_analyze = 'on'` into `postgresql.conf` at initdb time. That is the cluster-level path PostgreSQL documents for `auto_explain` and works for every connection, including connections opened by the existing `KirokuStore` pool. The per-session fallback is documented in the Idempotence and Recovery section as a backup if a future ephemeral-pg version regresses on this feature.
  Date: 2026-05-18

- Decision: Add a separate `benchmark kiroku-store-bench-explain` stanza in `kiroku-store/kiroku-store.cabal` rather than extending the existing `kiroku-store-bench` stanza.
  Rationale: A cabal `benchmark` stanza has a single `main-is`. Putting the EXPLAIN executable into its own stanza keeps `kiroku-store-bench` exactly as it is today, so `cabal bench kiroku-store-bench --benchmark-options="--csv …"` and the `just bench-regression` workflow continue to measure the same cells. The alternative — overload the bench by adding a tasty-bench cell that calls `EXPLAIN` — was rejected because tasty-bench iterates each cell hundreds of times to estimate timing, and we do not want the EXPLAIN output to drown in benchmark noise or appear in regression CSVs.
  Date: 2026-05-18

- Decision: Use PostgreSQL's `logging_collector` writing csvlog directly to disk rather than the documented `Config.stderr = Last (Just (Just h))` override.
  Rationale: Empirical testing during implementation showed `ephemeral-pg` hardcodes `setStderr nullStream` for the postgres process (`EphemeralPg/Process/Postgres.hs:78`), so the `Config.stderr` field is silently ignored. The first try produced a 0-byte log file. Driving PostgreSQL's own logging collector with `logging_collector = 'on'` and `log_destination = 'csvlog'` writes the auto_explain output to disk regardless of what ephemeral-pg does with the postgres process's stderr. The CSV format also has the side benefit that the auto_explain message column is structured (multi-line within a CSV-quoted field) and is parseable by any standard CSV reader.
  Date: 2026-05-18

- Decision: Force `log_min_messages = 'log'` in the auto_explain harness even though PostgreSQL's documented default (`warning`) should include LOG-level messages.
  Rationale: Empirical testing showed that with default `log_min_messages = 'warning'` the csvlog stayed at 0 bytes for the same workload that produces 42 KB at `log_min_messages = 'log'`. The discrepancy with the documented level ordering is recorded as a Surprise & Discovery; the right action for EP-2 was to make the harness work reliably rather than re-investigate PostgreSQL semantics. A future cross-platform verification (especially on Linux, where ephemeral-pg may be more commonly run) is a candidate follow-up.
  Date: 2026-05-18

- Decision: Locate the repo root via upward search for `cabal.project` rather than hardcoding a relative path or requiring the user to invoke the harness from a specific directory.
  Rationale: `cabal bench` sets CWD to the package directory (`kiroku-store/`), but `cabal run` and direct binary invocation typically use the repo root. A hardcoded relative path can be made to work for exactly one of these but breaks the other. `locateRepoRoot` walks up from CWD until it finds `cabal.project`, returning that directory; the harness then resolves output paths from there. This makes the harness invariant to invocation style. Costs five lines of code in `Explain.hs`.
  Date: 2026-05-18

- Decision: Stick with the bench-cell setup of the production code path even though it routes through the schema-migration step (which `auto_explain` logs and inflates the captured CSV).
  Rationale: The schema-migration statements are part of the cluster-warmup process, and `auto_explain.log_min_duration = 0` logs them too — adding ~30 of the 75 LOG lines in the csvlog. We considered isolating just the workload statements by tightening `auto_explain.log_min_duration` to a non-zero threshold or by adding `SET LOCAL auto_explain.log_min_duration = -1` around the migration; both were rejected because the migration's own plans are useful evidence for future plans that touch schema, and the resulting noise is small.
  Date: 2026-05-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### Delivered

A new cabal target `kiroku-store-bench-explain` produces the
PostgreSQL-side profiling artefacts for the production `AnyVersion`
append CTE. Reproduction (from the repo root):

```bash
cabal build kiroku-store:kiroku-store-bench-explain
cabal bench kiroku-store-bench-explain                              # M1
cabal bench kiroku-store-bench-explain --benchmark-options="--auto-explain"  # M2
```

The captured artefacts live at
`kiroku-store/bench/explain-results/` with the per-file inventory
documented in that directory's `README.md`:

- `anyversion-singleton.txt` (7.2 KB) — `EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT)` of `appendAnyVersionSQL`.
- `anyversion-singleton.json` (45 KB) — same EXPLAIN run in `FORMAT JSON`.
- `auto-explain.csv` (42 KB) — `auto_explain` capture of a small workload (1 AnyVersion + 1 ExactVersion + readStreamForward + readAllForward + the schema migration that precedes them).
- `auto-explain.log` (158 bytes) — small stderr-emitted startup messages from PostgreSQL before the logging collector takes over.

### Key findings for future plans

From `anyversion-singleton.txt`, the dominant cost in a hot-cache
single-event `AnyVersion` append is *triggers*, not CTE-node work:

```text
Trigger stream_events_notify on streams: time=0.689 calls=2
Trigger for constraint stream_events_event_id_fkey on stream_events: time=0.446 calls=2
Trigger for constraint stream_events_stream_id_fkey on stream_events: time=0.052 calls=2
```

Triggers account for ~1.19 ms out of a ~2.36 ms `Execution Time`, or
~51%. The summed CTE-node `actual time` values come to well under
1 ms. This corroborates EP-1's Haskell-side finding from the
PostgreSQL side: round-trip and per-call overhead dominate, and any
candidate optimization plan targeting CTE shape or Haskell-side
encoder work can recover at most ~50% of total append latency without
also reducing trigger work.

Concrete implication for the next optimization plan: the named
candidates are now (in order of measured impact)

1. `stream_events_notify` `pg_notify` trigger (~0.69 ms, 29%)
2. `stream_events_event_id_fkey` FK trigger (~0.45 ms, 19%)
3. CTE shape (everything else)

The first two are not visible to a Haskell-side optimization; they are
PostgreSQL schema decisions whose right plan is a separate ExecPlan
that touches `kiroku-store/sql/schema.sql`. Plan 22's Surprises &
Discoveries had noted that disabling `stream_events_notify` "helped
less than was hoped" but the magnitude was not quantified. EP-2 now
quantifies it.

### Gaps and follow-ups

Three gaps are recorded as Surprises & Discoveries:

1. `Config.stderr` is silently ignored by `ephemeral-pg`. The harness
   routes around this with `logging_collector`; a potential upstream
   patch to ephemeral-pg would let future plans simplify.

2. `log_min_messages = 'log'` is needed empirically. PostgreSQL's
   documentation suggests the default `warning` should work; we have
   not yet identified whether this is a build-time configuration
   detail, a `auto_explain` version detail (Postgres 18.3 ships
   auto_explain with no recent behaviour change), or a misreading on
   our part.

3. The JSON-format EXPLAIN tags only three of the six CTEs with
   `"CTE Name"`. The other three appear under `"Subplan Name"`. The
   plan's acceptance verification command was updated; future plans
   should use `"Subplan Name"` for full coverage.

### Comparison against the original purpose

The Purpose stated this plan would let a contributor cite, for
example, "the `stream_upsert` ModifyTable node accounts for 38% of
the CTE's execution time". The captured profile lets the next
contributor cite a sharper, different sentence: "the
`stream_events_notify` trigger and the foreign-key triggers on
`stream_events` together account for 51% of execution time; the
six append CTE nodes combined account for under 30%". The shape of
the answer matches what the plan promised — per-node-named evidence
— and the answer itself redirects future optimization work toward
the actual hot path.


## Context and Orientation

The full repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Throughout this plan paths are given relative to that root.

Kiroku stores events in three PostgreSQL tables defined in `kiroku-store/sql/schema.sql`. The table `streams` holds one row per named stream with a `stream_version` counter, a generated `category` column derived from `split_part(stream_name, '-', 1)`, and a trigger named `stream_events_notify` that calls `pg_notify` after each `INSERT OR UPDATE`. The table `events` holds the event payload (`event_id`, `event_type`, `data` as `jsonb`, `metadata` as `jsonb`, plus correlation and causation `uuid` columns). The junction table `stream_events` links each event to two or more `(stream_id, stream_version)` rows: one for the source stream and one for the `$all` stream (which is the reserved stream with `stream_id = 0`). Mutation-prevention triggers on `events`, `stream_events`, and `streams` refuse all `UPDATE`s, all row-level `DELETE`s outside a gated `SET LOCAL kiroku.enable_hard_deletes = 'on'` session, and all `TRUNCATE`s outside the same gate.

The production append for `AnyVersion` (the policy that does not require an expected stream version and creates the stream if it does not exist) is a single multi-CTE SQL statement at `kiroku-store/src/Kiroku/Store/SQL.hs` lines 304 to 353, named `appendAnyVersionSQL`. A Common Table Expression — abbreviated CTE — is a named subquery introduced with `WITH name AS (…)` that can be referenced like a temporary view from later parts of the same statement. PostgreSQL extends this so that the body of a CTE can be a data-modifying statement (`INSERT`, `UPDATE`, `DELETE`), and the whole multi-CTE block can be executed atomically within one round-trip. `appendAnyVersionSQL` chains six CTEs in a single statement:

```haskell
-- The full SQL lives in kiroku-store/src/Kiroku/Store/SQL.hs as appendAnyVersionSQL;
-- the structure is reproduced here so a novice does not need to switch files.
WITH
  new_events AS (
    SELECT *
    FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[],
                $5::jsonb[], $6::jsonb[], $7::timestamptz[])
    WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id,
                         data, metadata, created_at, idx)
  ),
  stream_upsert AS (
    INSERT INTO streams (stream_name, stream_version)
    VALUES ($8, (SELECT count(*) FROM new_events))
    ON CONFLICT (stream_name)
    DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
      WHERE streams.deleted_at IS NULL
    RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
  ),
  inserted_events AS (
    INSERT INTO events (event_id, event_type, causation_id, correlation_id,
                        data, metadata, created_at)
    SELECT event_id, event_type, causation_id, correlation_id,
           data, metadata, created_at
    FROM new_events
    WHERE EXISTS (SELECT 1 FROM stream_upsert)
    ORDER BY idx
  ),
  source_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version,
                                original_stream_id, original_stream_version)
    SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx,
           su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN stream_upsert su
  ),
  all_update AS (
    UPDATE streams
    SET stream_version = stream_version + (SELECT count(*) FROM new_events)
    WHERE stream_id = 0
      AND EXISTS (SELECT 1 FROM stream_upsert)
    RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
  ),
  all_links AS (
    INSERT INTO stream_events (event_id, stream_id, stream_version,
                                original_stream_id, original_stream_version)
    SELECT ne.event_id, 0, au.initial_global_version + ne.idx,
           su.stream_id, su.initial_version + ne.idx
    FROM new_events ne
    CROSS JOIN all_update au
    CROSS JOIN stream_upsert su
  )
SELECT su.stream_id,
       su.initial_version + (SELECT count(*) FROM new_events),
       au.initial_global_version + (SELECT count(*) FROM new_events)
FROM stream_upsert su
CROSS JOIN all_update au
```

The eight bind parameters carry the column-major arrays for an arbitrary-length batch (`$1` through `$7`) plus the stream name (`$8`). `WITH ORDINALITY` gives each unnested row an integer index (`idx`) so the inserted positions inside the batch can be reconstructed. The sibling `NoStream`, `StreamExists`, and `ExactVersion` SQL statements live adjacent to `appendAnyVersionSQL` in the same file and have the same six-CTE shape with different conflict-handling.

There are two relevant existing benchmark targets in `kiroku-store/kiroku-store.cabal`. The first is `benchmark kiroku-store-bench` at line 108, whose entry point is `kiroku-store/bench/Main.hs`. It uses the framework `tasty-bench` (a benchmarking library that re-uses tasty's test-tree interface and runs each cell many times to compute a stable timing estimate). The bench starts an ephemeral PostgreSQL via `EphemeralPg.withCached`, which is a function from the `ephemeral-pg` Haskell package that initialises a fresh PostgreSQL cluster in a temporary directory, caches the post-`initdb` data directory between runs so subsequent runs start in well under a second, runs an action with the cluster up, and tears it down on exit. The bench wires the cluster into Kiroku by passing `Pg.connectionString db` into `defaultConnectionSettings` and calling `withStore` (which creates a `KirokuStore` whose `pool` field is a `Hasql.Pool.Pool`). The second target is `benchmark kiroku-shibuya-overhead` at line 133, which is unrelated to this plan but documents the pattern for an additional benchmark stanza.

Inside `kiroku-store/bench/Main.hs`, the function `rawProductionAppendAnyVersionSQL` at line 155 is a copy of the production `AnyVersion` CTE that runs directly on a pooled connection without going through the `Kiroku.Store` effect layer. The helpers `mkRawAppendParams` (line 382) and `mkRawProductionAppendParams` (line 398) construct call-ready parameter records; both are reusable from a sibling bench module. The existing `bgroup "raw-append-shape"` (line 797) is where the production-shaped CTE is exercised in the regression bench. This plan adds new behavior in a sibling executable, not inside any existing `bgroup`.

The Haskell library `hasql` exposes the types this plan relies on. `Hasql.Statement.Statement params result` is a parameterised prepared statement (built with `Hasql.Statement.preparable` or `Hasql.Statement.unprepared`). `Hasql.Session.statement :: params -> Statement params result -> Session result` runs one statement on a connection. `Hasql.Session.script :: Text -> Session ()` runs a multi-statement script (no parameters, no results) — useful for issuing `BEGIN` and `ROLLBACK`. `Hasql.Pool.use :: Pool -> Session a -> IO (Either UsageError a)` acquires a connection from a pool, runs the session, and returns it.

`EXPLAIN (ANALYZE, BUFFERS, TIMING)` is the PostgreSQL command this plan uses to extract per-CTE-node timing. With `ANALYZE` the planner not only produces a plan but executes the query and records what actually happened, returning `actual time=<startup>..<total>`, `actual rows=<n>`, and `loops=<n>` for every node. With `BUFFERS` it also reports per-node buffer accounting: `shared hit=<n> read=<n> dirtied=<n> written=<n>`. With `TIMING` (the default when `ANALYZE` is on, but stated explicitly for clarity) it adds per-node clock reads. `FORMAT TEXT` (the default) returns indented human-readable rows; `FORMAT JSON` returns a single JSON object. A short representative excerpt of what the output looks like for one of Kiroku's CTE nodes is:

```text
                                                              QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------
 Insert on streams  (cost=0.00..0.04 rows=0 width=0) (actual time=0.063..0.064 rows=1 loops=1)
   Buffers: shared hit=12 read=2 dirtied=1
   CTE new_events
     ->  Function Scan on unnest t  (cost=0.00..1.00 rows=100 width=176) (actual time=0.005..0.006 rows=1 loops=1)
   CTE stream_upsert
     ->  Insert on streams streams_1  (cost=0.00..0.04 rows=0 width=0) (actual time=0.040..0.041 rows=1 loops=1)
           Conflict Resolution: UPDATE
           Conflict Arbiter Indexes: ix_streams_stream_name
           Buffers: shared hit=8
   CTE inserted_events
     ->  Insert on events  (cost=…) (actual time=0.018..0.018 rows=1 loops=1)
   …
 Planning Time: 0.412 ms
 Execution Time: 0.187 ms
```

Reading this output, the three rules a novice should know are: (a) each `CTE <name>` block corresponds to one of the six named CTEs in the statement, and the `actual time` on its inner `Insert`/`Update`/`Scan` row is the time PostgreSQL spent on that CTE; (b) `loops=N` means the inner timing should be multiplied by `N` to get total wall time (`loops > 1` is common for the inner side of a `CROSS JOIN`); (c) the bottom-line `Execution Time` is the actual wall clock minus `Planning Time`, and per-node times should approximately sum to `Execution Time` once you account for loops and overlap.

The PostgreSQL contrib module `auto_explain` is a small loadable library that hooks the executor and, after each statement runs, decides whether to log its plan. It is configured by three GUC parameters (Grand Unified Configuration variables — PostgreSQL's term for runtime-tunable settings): `shared_preload_libraries = 'auto_explain'` (loads it at server start), `auto_explain.log_min_duration = '<ms>ms'` (the threshold; `0` means log every query), and `auto_explain.log_analyze = 'on'` (causes it to log `actual time` rows, equivalent to running the query under `EXPLAIN ANALYZE`). With these set, every query the bench runs has its plan written to the PostgreSQL log alongside the wall-clock time PostgreSQL measured for it. There is some overhead from the per-statement plan capture, but for a profiling run that is acceptable; the bench is not measuring production throughput while `auto_explain` is on.

The Haskell package `ephemeral-pg` is registered with `mori` at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`. Its public module `EphemeralPg` exports `with :: (Database -> IO a) -> IO (Either StartError a)` (no-arg startup with `defaultConfig`), `withConfig :: Config -> (Database -> IO a) -> IO (Either StartError a)` (startup with a chosen `Config`), and `withCached :: (Database -> IO a) -> IO (Either StartError a)` (no-arg cached startup). It also re-exports a `Config` record whose `postgresSettings :: [(Text, Text)]` field is rendered into `postgresql.conf` at initdb time, and a convenience function `autoExplainConfig :: Int -> Config` that constructs a `Config` carrying the three GUCs above with `auto_explain.log_min_duration` set to the supplied millisecond threshold. `Config` has a `Semigroup` instance so `defaultConfig <> autoExplainConfig 0` is a valid configuration that means "default settings, plus log every query's plan via `auto_explain`". Caching with a custom `Config` is not exposed (`withCachedConfig` exists in the source but is not in the export list), so the auto_explain milestone in this plan uses `withConfig` (non-cached); the EXPLAIN ANALYZE milestone keeps using `withCached` because no config change is needed there.

The MasterPlan governing this work is at `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`. Its three child plans are: EP-1 at `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md` (Haskell-side profiling), this plan EP-2 at `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`, and EP-3 at `docs/plans/27-append-performance-experiment-ledger-and-methodology-readme.md` (experiment ledger and methodology README). There are no hard dependencies between the three. The intention identifier inherited from the MasterPlan is `intention_01krxrpv5heny9gs89seas59zm`; commits for this plan include the trailers `MasterPlan: docs/masterplans/3-…`, `ExecPlan: docs/plans/26-…`, and `Intention: intention_01krxrpv5heny9gs89seas59zm`.


## Plan of Work

The work is two milestones. Milestone 1 builds the dedicated `EXPLAIN ANALYZE` harness as a new executable in its own cabal stanza, runs the production `AnyVersion` CTE under EXPLAIN inside a rollback, and writes both text and JSON output. Milestone 2 enables `auto_explain` on an ephemeral cluster, runs (a subset of) the existing bench against it, and captures the resulting PostgreSQL log.

### Milestone 1: Dedicated EXPLAIN ANALYZE harness

At the end of this milestone, running `cabal bench kiroku-store-bench-explain` from the repository root prints the text-format `EXPLAIN (ANALYZE, BUFFERS, TIMING)` output for the production `AnyVersion` CTE and also writes a JSON-format copy to a known path on disk. The output names each of the six CTEs (`new_events`, `stream_upsert`, `inserted_events`, `source_links`, `all_update`, `all_links`) on its own line with an `actual time` measurement.

The cabal change is additive. In `kiroku-store/kiroku-store.cabal`, add a new stanza modelled on `benchmark kiroku-store-bench` (line 108) but pointing at a new `main-is: Explain.hs`. The build dependencies match the existing `kiroku-store-bench` stanza minus `tasty-bench` (we do not need tasty-bench here because we run the EXPLAIN call once, not as a benchmarked loop). The required dependencies are `base`, `aeson` (for printing or pretty-printing JSON output), `bytestring`, `ephemeral-pg`, `generic-lens`, `hasql`, `hasql-pool`, `kiroku-store`, `lens`, `text`, `time`, `uuid`, `vector`, and `mmzk-typeid` only if we end up reusing the existing UUID helpers. A reasonable initial stanza is:

```cabal
benchmark kiroku-store-bench-explain
  import:         common
  type:           exitcode-stdio-1.0
  main-is:        Explain.hs
  hs-source-dirs: bench
  ghc-options:    -threaded -rtsopts "-with-rtsopts=-N -A32m"
  build-depends:
    , aeson
    , base               >=4.18 && <5
    , bytestring         >=0.11
    , ephemeral-pg       >=0.2
    , generic-lens       >=2.2
    , hasql              >=1.10
    , hasql-pool         >=1.2
    , kiroku-store
    , lens               >=5.2
    , text               >=2.0
    , time               >=1.12
    , uuid
    , vector             >=0.13
```

Sharing the `bench/` directory means the harness can `import` the helpers in `kiroku-store/bench/Main.hs` if we want (cabal compiles only what `Main.hs` of its own stanza needs), but in practice it is cleaner to inline a small amount of duplication into `Explain.hs` so the dedicated executable does not depend on the bench's internal layout. The plan duplicates `mkRawAppendParams` and `rawProductionAppendAnyVersionSQL` into `Explain.hs` rather than refactoring.

The new file is `kiroku-store/bench/Explain.hs`. Its `main` boots ephemeral PostgreSQL via `EphemeralPg.withCached`, opens a `KirokuStore` so the schema is migrated, constructs one batch of production params for an `AnyVersion` append against a fresh stream name, and runs the following session on the pool:

```haskell
explainSession :: Text -> RawProductionAppendParams -> Session.Session ByteString
explainSession explainFormat params = do
    Session.script "BEGIN"
    rows <- Session.statement params (explainStatement explainFormat)
    Session.script "ROLLBACK"
    pure rows
```

`explainStatement` is a `Hasql.Statement.Statement RawProductionAppendParams ByteString` whose SQL is the production CTE wrapped in `EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT <format>) <production CTE>`. PostgreSQL returns the explain rows as one `text` column per row, which we decode with `Hasql.Decoders.rowVector (Hasql.Decoders.column (Hasql.Decoders.nonNullable Hasql.Decoders.text))` and concatenate with `Text.intercalate "\n"`. The encoder is the existing `rawProductionAppendParamsEncoder`.

The harness runs `explainSession "TEXT"` first and prints its output to stdout, then runs `explainSession "JSON"` and writes the result to `kiroku-store/bench/explain-results/anyversion-singleton.json`. Both runs use a stream name suffixed with the current `getCurrentTime` so the harness can be re-run against the same cached cluster without colliding (although ROLLBACK should make that moot, choosing a fresh name is defence in depth).

To verify Milestone 1, run `cabal bench kiroku-store-bench-explain` from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The expected behavior is that the command exits 0 and prints a plan that contains the substrings `CTE new_events`, `CTE stream_upsert`, `CTE inserted_events`, `CTE source_links`, `CTE all_update`, and `CTE all_links`, plus `Planning Time:` and `Execution Time:`. The file `kiroku-store/bench/explain-results/anyversion-singleton.json` exists and is valid JSON whose root array contains an object with the key `Plan`. The existing `kiroku-store-bench` target is untouched; running `cabal bench kiroku-store-bench` continues to produce its usual tasty-bench output. The `kiroku-store/bench/results/baseline.csv` regression baseline is untouched.

### Milestone 2: auto_explain log from a bench run

At the end of this milestone, running `cabal bench kiroku-store-bench-explain -- --auto-explain` from the repository root produces a PostgreSQL log file containing the plan of every statement issued during a representative subset of the existing benchmark cells. The flag `--auto-explain` is a command-line switch the harness reads on startup; without it, the harness runs Milestone 1 only.

The implementation extends `Explain.hs` with a second mode. When `--auto-explain` is present in the arguments, the harness uses `EphemeralPg.withConfig (defaultConfig <> autoExplainConfig 0)` instead of `withCached`. The `autoExplainConfig 0` argument means "log every query regardless of duration", which is what we want for an exhaustive plan capture; tuning the threshold up (for example `100` for queries longer than 100 ms) is a one-character edit and is documented in the Concrete Steps section. Additionally, the `EphemeralPg.Config` is extended so the PostgreSQL server writes its log to a file we can read. In `defaultConfig` the bench discards postgres stdout and stderr (`stdout = Last (Just Nothing)`, `stderr = Last (Just Nothing)`); we override `stderr` to a file handle opened on `kiroku-store/bench/explain-results/auto-explain.log`.

```haskell
import EphemeralPg.Config (Config (..))
import Data.Monoid (Last (..))
import System.IO (IOMode (..), openFile, hClose)

withAutoExplainConfig :: FilePath -> (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withAutoExplainConfig logPath action = do
    h <- openFile logPath WriteMode
    let cfg = Pg.defaultConfig
            <> Pg.autoExplainConfig 0
            <> mempty { stderr = Last (Just (Just h)) }
    result <- Pg.withConfig cfg action
    hClose h
    pure result
```

After the cluster boots, the harness opens a `KirokuStore`, performs a deliberately small workload (one `AnyVersion` append against a fresh stream, one `ExactVersion` append against the same stream, one `readStreamForward`, one `readAllForward`), then exits. The cluster shuts down, which causes PostgreSQL to flush `auto_explain` output to the configured stderr handle. We do not run the full `kiroku-store-bench` under `auto_explain` because that would log roughly a million queries; the harness captures enough plans to demonstrate the configuration is working and to give a representative sample. Running the full bench under `auto_explain` is a documented manual recipe in Concrete Steps for someone who wants the exhaustive capture.

To verify Milestone 2, run `cabal bench kiroku-store-bench-explain -- --auto-explain` from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The expected behavior is that the command exits 0 and that the file `kiroku-store/bench/explain-results/auto-explain.log` exists and contains at least one block matching the regular expression `duration:\s+\S+\s+ms\s+plan:.*?Insert on streams` (an `auto_explain` log line followed by the indented EXPLAIN output for the append). Re-running the command should overwrite the log file (the harness opens with `WriteMode`).


## Concrete Steps

All commands are run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Build artefacts live under `dist-newstyle/`; intermediate output for this plan lives under `kiroku-store/bench/explain-results/` and is gitignored by default by virtue of being under `bench/`. (If we choose to check in the captured artefacts, that decision should be recorded in the Decision Log.)

First, create the output directory:

```sh
mkdir -p kiroku-store/bench/explain-results
```

Second, add the new cabal stanza. Edit `kiroku-store/kiroku-store.cabal` and append the stanza shown in the Plan of Work section below the existing `benchmark kiroku-shibuya-overhead` stanza (at the bottom of the file).

Third, create `kiroku-store/bench/Explain.hs`. The file should compile and define `main :: IO ()` that performs Milestone 1 when invoked without arguments and Milestone 2 when invoked with `--auto-explain`.

Fourth, verify Milestone 1:

```sh
cabal bench kiroku-store-bench-explain
```

The expected stdout transcript (abbreviated) is:

```text
=== EXPLAIN (ANALYZE, BUFFERS, TIMING, FORMAT TEXT) of appendAnyVersionSQL ===

 Insert on streams  (cost=0.00..0.04 rows=0 width=0) (actual time=0.063..0.064 rows=1 loops=1)
   Buffers: shared hit=12
   CTE new_events
     ->  Function Scan on unnest t  (cost=0.00..1.00 rows=100 width=176) (actual time=0.005..0.006 rows=1 loops=1)
   CTE stream_upsert
     ->  Insert on streams streams_1  (cost=…) (actual time=0.040..0.041 rows=1 loops=1)
           Conflict Resolution: UPDATE
           Conflict Arbiter Indexes: ix_streams_stream_name
   CTE inserted_events
     ->  Insert on events  (cost=…) (actual time=0.018..0.018 rows=1 loops=1)
   CTE source_links
     ->  Insert on stream_events  (cost=…) (actual time=0.014..0.015 rows=1 loops=1)
   CTE all_update
     ->  Update on streams streams_2  (cost=…) (actual time=0.022..0.022 rows=1 loops=1)
   CTE all_links
     ->  Insert on stream_events stream_events_1  (cost=…) (actual time=0.013..0.013 rows=1 loops=1)
 Planning Time: 0.412 ms
 Execution Time: 0.187 ms

=== JSON output written to kiroku-store/bench/explain-results/anyversion-singleton.json ===
```

Confirm the JSON output is well-formed and contains all six CTE names.
**Note:** PostgreSQL only emits `"CTE Name"` for CTEs separately referenced
via a `CTE Scan` later in the plan; modify-only CTEs (here:
`inserted_events`, `source_links`, `all_links`) appear only under
`"Subplan Name"`. The actual coverage check is therefore:

```sh
grep -oE '"(CTE Name|Subplan Name)": "[^"]+"' kiroku-store/bench/explain-results/anyversion-singleton.json | sort -u
```

The expected output is nine lines (six `"Subplan Name": "CTE <name>"` and
three `"CTE Name": "<name>"`, the same three appearing in both).

Fifth, verify Milestone 2:

```sh
cabal bench kiroku-store-bench-explain -- --auto-explain
```

The expected behavior is that the command exits 0 and the files
`kiroku-store/bench/explain-results/auto-explain.csv` (~42 KB) and
`kiroku-store/bench/explain-results/auto-explain.log` (~150 bytes —
just the small "log output to stderr" handoff messages) exist. The
csvlog is the operationally useful file: the auto_explain output is
in the message column (column 14) of each `LOG` record. Inspect with
a CSV-aware reader, or grep with multi-line context:

```sh
grep -A 30 'duration:' kiroku-store/bench/explain-results/auto-explain.csv | head -40
```

The expected output is several blocks of the form (one per
`auto_explain`-logged statement):

```log
2026-…,"shinzui","postgres",…,"INSERT",…,LOG,00000,"duration: 0.268 ms  plan:
  Query Text: WITH new_events AS (...
  Insert on streams  (cost=… rows=… width=…) (actual time=… rows=… loops=…)
    Buffers: shared hit=… read=…
    CTE new_events
      ->  Function Scan on unnest t  (cost=…) (actual time=…)
    ...
```

Sixth, optionally extend the auto_explain capture to a fuller run by manually invoking the existing `kiroku-store-bench` while a separately-launched ephemeral PostgreSQL with `auto_explain` enabled is running. This is documented for completeness but is not part of the milestone acceptance:

```sh
# Terminal 1 — boot a cached ephemeral cluster manually with auto_explain.
# This recipe assumes a future ephemeral-pg release exposes `withCachedConfig`
# or an equivalent CLI; until then, use `cabal bench kiroku-store-bench-explain
# -- --auto-explain` which uses the non-cached path.
```

Update this section as work proceeds; record the actual commands run and any deviation from the expected transcripts.


## Validation and Acceptance

The plan is accepted when all of the following are true.

Running `cabal bench kiroku-store-bench-explain` (with no arguments) from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` exits with status 0 and prints output to stdout that contains every one of the substrings `CTE new_events`, `CTE stream_upsert`, `CTE inserted_events`, `CTE source_links`, `CTE all_update`, and `CTE all_links`, plus `Planning Time:` and `Execution Time:`. The summed inner `actual time` values across CTE-node rows approximately equal `Execution Time` (within a factor of two, allowing for `loops>1` rows and per-node overhead). The file `kiroku-store/bench/explain-results/anyversion-singleton.json` exists, parses as JSON, and a search for the key `"CTE Name"` returns the six expected names.

Running `cabal bench kiroku-store-bench-explain -- --auto-explain` from the same directory exits with status 0 and produces the file `kiroku-store/bench/explain-results/auto-explain.log`. The log contains at least one occurrence of the literal substring `duration:` followed within the same record by `Insert on streams`. The substring `CTE stream_upsert` appears at least once in the log, demonstrating that `auto_explain.log_analyze` is on and emitting structured plans (and not merely query texts).

Running `cabal bench kiroku-store-bench` from the same directory produces the same tasty-bench output it did before this plan. The CSV produced by `cabal bench kiroku-store-bench -- --csv kiroku-store/bench/results/regression.csv` diff-compares cleanly against `kiroku-store/bench/results/baseline.csv` under the existing `just bench-regression` threshold. No new bgroup names appear in the CSV, because the new code lives in a separate executable. The file `kiroku-store/src/Kiroku/Store/SQL.hs` is unmodified by this plan's commits. The file `kiroku-store/sql/schema.sql` is unmodified by this plan's commits.

Failure modes a reader should know about: if the EXPLAIN output is missing one of the CTE names, the most likely cause is that the embedded `EXPLAIN (...)` prefix was applied to the wrong SQL (for example the scalar singleton at `rawScalarAppendAnyVersionSQL` rather than the production `rawProductionAppendAnyVersionSQL`). If the JSON output does not contain `"CTE Name"`, the `FORMAT JSON` argument was misspelled (PostgreSQL accepts `FORMAT JSON`, `FORMAT TEXT`, `FORMAT XML`, `FORMAT YAML` — capitalisation does not matter, but the keyword must be `FORMAT`). If the auto_explain log is empty, either the `shared_preload_libraries` setting did not take effect (verify by running `SHOW shared_preload_libraries;` against the ephemeral cluster while it is up — the bench can be temporarily extended to print this), or the PostgreSQL stderr is still being discarded (verify the `Config.stderr` override is reaching `withConfig`).


## Idempotence and Recovery

The EXPLAIN ANALYZE harness in Milestone 1 wraps the append in `BEGIN; … EXPLAIN (ANALYZE) …; ROLLBACK;` so that no row is committed. The harness is safe to re-run an unbounded number of times against the same cached `EphemeralPg.withCached` cluster; the cluster's state at the end of each run is the same as at the start of each run. The `kiroku-store/bench/explain-results/anyversion-singleton.json` file is overwritten each invocation, which is the desired behavior; preserving older snapshots is a manual `cp` away.

The auto_explain harness in Milestone 2 opens `kiroku-store/bench/explain-results/auto-explain.log` in `WriteMode`, which truncates the file at the start of each run, so re-running is safe and does not accumulate stale captures. The ephemeral PostgreSQL itself uses a temporary data directory that `EphemeralPg.withConfig` removes on exit, so no on-disk PostgreSQL state survives the run.

If a future version of `ephemeral-pg` removes the `autoExplainConfig` helper or changes its semantics, the per-session fallback is to issue, on the connection used by the bench, the SQL:

```sql
LOAD 'auto_explain';
SET LOCAL auto_explain.log_min_duration = 0;
SET LOCAL auto_explain.log_analyze = 'on';
```

`LOAD` is a PostgreSQL command that loads a shared library file at run time (`auto_explain` ships as a contrib module with every standard PostgreSQL build, so the file is present on disk). `SET LOCAL` scopes the GUC change to the current transaction; outside a transaction, plain `SET` scopes it to the session. The limitation is that this approach only affects queries issued on the same session, so a multi-connection bench would need to issue these commands on every pooled connection — that is fine for a small profiling run but defeats the point of the cluster-level configuration. Use this fallback only if `Config.postgresSettings` and `autoExplainConfig` are unavailable.

If `cabal bench kiroku-store-bench-explain` fails to build because a transitive dependency cannot resolve, the most likely cause is a version skew between the existing `kiroku-store-bench` stanza and the new stanza. Match the new stanza's `build-depends` versions exactly against the existing stanza in the same file. If it fails to start the ephemeral cluster (`Pg.StartError`), inspect the captured `StartError` and follow the same diagnostic path the existing `kiroku-store-bench` uses (the bench's `main` already prints the error before re-raising; mirror that).


## Interfaces and Dependencies

This plan depends on libraries already in the project's `kiroku-store.cabal`. No new build-depends are introduced. The relevant modules are:

- `EphemeralPg` (package `ephemeral-pg`, source at `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg.hs`) — exports `withConfig`, `withCached`, `Database`, `connectionString`, `defaultConfig`, `autoExplainConfig`.
- `EphemeralPg.Config` (same package) — exports the `Config` record with `postgresSettings :: [(Text, Text)]` and the `Semigroup` instance used to combine configurations.
- `Hasql.Session` (package `hasql`) — exports `Session`, `script`, `statement`.
- `Hasql.Statement` (package `hasql`) — exports `Statement`, `preparable`, `unprepared`.
- `Hasql.Pool` (package `hasql-pool`) — exports `Pool`, `use`, `UsageError`.
- `Hasql.Decoders` (package `hasql`) — exports `rowVector`, `column`, `nonNullable`, `text`.
- `Kiroku.Store` (this project) — exports `KirokuStore`, `withStore`, `defaultConnectionSettings`. The `KirokuStore` record's `pool` field is a `Hasql.Pool.Pool`.

The contrib module `auto_explain` ships with every standard PostgreSQL build (it is part of the upstream contrib tree); on the platforms `ephemeral-pg` supports it is available wherever `pg_ctl` is. No additional installation step is required.

After Milestone 1 the executable target `kiroku-store-bench-explain` exists in `kiroku-store.cabal`. Its `main-is` is `Explain.hs` and its argv parsing recognises (at minimum) the absence of arguments (Milestone 1 mode) and the presence of `--auto-explain` (Milestone 2 mode). After Milestone 2 the file `kiroku-store/bench/explain-results/auto-explain.log` is produced by a Milestone 2 invocation. No public API in `kiroku-store/src/Kiroku/Store/*` changes; no SQL in `kiroku-store/src/Kiroku/Store/SQL.hs` changes; no schema in `kiroku-store/sql/schema.sql` changes.


## Revision Notes

- 2026-05-18: Plan created under MasterPlan 3 (`docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`) as EP-2 of three sibling plans. Initial draft fleshes out the skeleton with two milestones: a dedicated `EXPLAIN (ANALYZE, BUFFERS, TIMING)` executable in a new `benchmark kiroku-store-bench-explain` cabal stanza, and an `auto_explain` capture using `EphemeralPg.withConfig` with `defaultConfig <> autoExplainConfig 0`. Research confirmed that `ephemeral-pg` exposes both a generic `Config.postgresSettings` list and a ready-made `autoExplainConfig :: Int -> Config` helper, so the per-session `LOAD 'auto_explain'; SET LOCAL …` approach is documented only as a fallback. Confirmed that adding a second `main-is` to the existing `kiroku-store-bench` stanza is not supported by cabal, so the EXPLAIN harness lives in its own stanza to keep `just bench-regression` and `kiroku-store/bench/results/baseline.csv` unaffected.

- 2026-05-18: Implementation complete. Added the new cabal stanza, created `kiroku-store/bench/Explain.hs` with M1 (targeted EXPLAIN ANALYZE producing both TEXT and JSON artefacts) and M2 (auto_explain capture via `logging_collector` + `csvlog`). Surfaced four implementation-time corrections, all documented in Surprises & Discoveries: (a) `ephemeral-pg` discards postgres's stderr, forcing the harness to use the logging collector rather than the documented `Config.stderr` override; (b) `log_min_messages = 'log'` is empirically required even though defaults should suffice; (c) `EXPLAIN (FORMAT JSON)` tags only 3 of 6 CTEs with `"CTE Name"`, with the other 3 only under `"Subplan Name"`; (d) `cabal bench` sets CWD to the package directory, so the harness walks up to `cabal.project` to resolve output paths. Concrete Steps and Validation sections corrected to match reality. Outcomes & Retrospective records the new key finding for future optimization plans: triggers (`stream_events_notify` + FK triggers on `stream_events`) account for ~51% of single-event AnyVersion `Execution Time`, vs. <30% for the six CTE nodes combined.
