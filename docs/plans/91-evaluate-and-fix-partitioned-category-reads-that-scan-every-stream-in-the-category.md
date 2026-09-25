---
id: 91
slug: evaluate-and-fix-partitioned-category-reads-that-scan-every-stream-in-the-category
title: "Evaluate and fix partitioned category reads that scan every stream in the category"
kind: exec-plan
created_at: 2026-09-25T16:09:49Z
intention: "intention_01m3cn0wx4ef9thtphet1ns7vp"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-25T16:09:49Z
---

# Evaluate and fix partitioned category reads that scan every stream in the category

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku is a PostgreSQL event store written in Haskell (package `kiroku-store`). Events are
appended to named streams such as `notification-42`; the text before the first `-` is the
stream's *category* (`notification`). Every event also receives one row in the global `$all`
log, and its position there is the store-wide order. A *category subscription* delivers, in
`$all` order, the events of every stream in one category. A *consumer group* splits a category
(or `$all`) subscription into `size` members; each member owns the streams whose PostgreSQL hash
lands on its `member` index, as recorded in
[ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md). A *poll* is one execution of
the read statement a subscription worker runs to fetch its next batch after its checkpoint.

Bug report BUG-2,
[`docs/bug-reports/partitioned-category-read-scans-every-stream-in-the-category.md`](../bug-reports/partitioned-category-read-scans-every-stream-in-the-category.md),
filed 2026-09-25 from `mori://tan/notification-hub`, shows that one consumer-group category
poll costs work proportional to the number of streams ever written in the category: about 1.3
buffer pages per stream, 13,000 pages per call at 10,000 streams, while returning about one
event. In Notification Hub, which creates one stream per notification, this single statement
took 80% of PostgreSQL's statement time in a paced delivery run and keeps growing with every
notification ever sent.

This plan answers the two questions the report raises, then fixes the defect under
pre-registered gates.

First, is the fix the report suggests safe? No, not as a drop-in. The suggested shape drives
the read from `$all` in position order and filters each row by category. Plan 10
([`docs/plans/10-large-store-read-path-and-index-performance-audit.md`](10-large-store-read-path-and-index-performance-audit.md),
Decision Log, 2026-05-06) measured exactly that shape: when a category has no events past the
cursor it scanned the remaining 50,000 `$all` rows in 9.88 ms, where the current LATERAL shape
took 0.116 ms. So the suggested fix swaps "cost grows with streams in the category" for "cost
grows with `$all` rows past the checkpoint". That second cost is catastrophic for a quiet
category in a busy store and for rebuilding a small category's projection on a large store,
because every poll or page re-scans other categories' events. Neither shape dominates the other.

Second, does fixing it affect non-partitioned category reads? Yes, unavoidably, because the
non-partitioned statement `readCategoryForwardSQL` has the identical LATERAL shape and the
identical cost in the number of streams; the report undercounts the defect. A shape-only fix
applied to both statements would regress the quiet-category regime that plan 10 protected with
the `exhausted-category` benchmark. Applied to the partitioned statement only, it would leave
the plain read defective and make the two statements' cost profiles diverge while the tests
assert that a size-1 group equals the plain read.

The fix this plan implements is the one shape whose cost is proportional to rows *returned* in
every regime: copy the originating stream's category onto each `$all` junction row (a new
`stream_events.category` column that the append statements fill from the stream row's generated
`category`) and add the partial index
`ix_stream_events_all_by_category (category, stream_version) INCLUDE (original_stream_id) WHERE stream_id = 0`.
Both category statements then become an index range scan that starts at `(category, checkpoint)`
and stops at the limit. This is the category-index shape message-db has used for years, and it
makes the non-partitioned read strictly cheaper too, which the plan proves with a same-process
control rather than assumes.

The expected-impact statement required by
[`docs/PERF-METHODOLOGY.md`](../PERF-METHODOLOGY.md) step 3 is: the report's
`pg_stat_statements` figures attribute about 1.3 shared buffers per category stream per poll to
the LATERAL statement, about 13,000 at 10,000 streams. The index-range shape should read about
4 buffers for an empty caught-up poll and about 10 per returned event regardless of stream
count, more than 1,000 times fewer at 10,000 streams. The append path should grow by one B-tree
insert per event, predicted at or below 3% on a single-event append workload; the gate refuses
more than 5%.

After this plan is implemented a reader can see the result three ways. `just perf-structure`
runs a deterministic buffer-budget test that seeds a category of 20,000 idle streams and asserts
a caught-up poll reads at most 32 buffers for both category statements (the same test reads
tens of thousands of buffers on the current statements). `just perf-workload-gate` runs the old
LATERAL SQL as a same-process control against the production statements and fails unless the
plain read is not slower on its protected cells and the large-category poll is at least five
times faster. `cabal test all` proves behavior is unchanged: the consumer-group partition
properties, the size-1 equivalence, and every subscription test pass as before.


## Progress

- [ ] M1: add the `category-scaling` benchmark fixture and cells, capture `EXPLAIN (ANALYZE, BUFFERS)` for both category statements at 100 and 20,000 idle streams, record the numbers in Surprises & Discoveries and `docs/perf-experiment-log.md`, and move BUG-2 to `confirmed`.
- [ ] M2: add migration `0012` (column, backfill, CHECK constraint, partial index), update the four append CTEs to populate `stream_events.category` on `$all` rows, update every direct `stream_events` inserter in tests and benches, extend the migrations test suite with the upgrade-path assertions, and add the append A/B gate (G4).
- [ ] M3: switch `readCategoryForwardSQL` and `readCategoryForwardConsumerGroupSQL` to the index-range shape, update the plan-shape structural test, add the buffer-budget structural test (G1, G2), add the read A/B gate (G3), refresh the historical baseline rows for the category cells with the reason recorded.
- [ ] M4: write ADR-10, update `docs/user/schema.md`, `docs/SCALING-ANALYSIS.md`, `docs/architecture/subscriptions.md`, `docs/DESIGN.md`, `docs/BENCH-SQL-BASELINE.md`, both CHANGELOGs and package versions, move BUG-2 to `fixed`, and append the perf-log rows.
- [ ] M5: route consumer-group category members through the category-generation live loop so an idle category's members no longer poll on every global append, and extend `Test.CategoryIdleNoSpin` to prove zero idle fetches.


## Surprises & Discoveries

(None yet. Planning-time findings that shaped the approach are recorded in Context and
Orientation and in the Decision Log.)


## Decision Log

- Decision: Reject the report's suggested position-driven join as the fix for either statement.
  Rationale: Plan 10 measured it on 2026-05-06 at 9.88 ms versus 0.116 ms for LATERAL when a
  category has nothing past the cursor. Its cost is proportional to `$all` rows past the
  checkpoint until `limit` matches accumulate, which is unbounded for a quiet category in a busy
  store and for a projection rebuild of a small category on a large store. The reported workload
  would improve, but a different, already-protected workload would regress.
  Date: 2026-09-25

- Decision: Fix both category statements with a denormalized `stream_events.category` column and
  a `(category, stream_version)` partial index rather than changing only the consumer-group
  statement.
  Rationale: The plain statement has the identical defect. The index-range shape is the only one
  whose cost is proportional to rows returned in every regime, so it is the only fix that can be
  proven "not slower" for the non-partitioned read on the `exhausted-category` cell while
  removing the O(streams) cost. Statement parameter order and the Haskell encoders are unchanged,
  so no caller changes.
  Date: 2026-09-25

- Decision: Populate the new column only on `$all` rows (`stream_id = 0`), keep it NULL on home
  and link rows, enforce that with `CHECK (stream_id <> 0 OR category IS NOT NULL)`, and derive
  its value from `RETURNING category` on the stream row inside the append CTEs.
  Rationale: Only the `$all` rows are read by category. Deriving the value from the generated
  `streams.category` column keeps the two byte-identical without duplicating the
  `split_part` expression. The CHECK makes any inserter that forgets the column fail loudly
  (SQLSTATE 23514) instead of producing rows invisible to category reads.
  Date: 2026-09-25

- Decision: Ship `0012` as one ordinary transactional migration with an in-transaction backfill,
  and document it as a maintenance-window step for large stores.
  Rationale: The backfill rewrites every `$all` row and the index build holds a SHARE lock, so
  appends block for the duration. A batched online variant with `CREATE INDEX CONCURRENTLY` is
  possible but adds a non-transactional migration and a two-phase read path; the operator
  runbook already treats migrations as forward-only maintenance steps.
  Date: 2026-09-25

- Decision: Pre-register the gates before measuring. G1 buffer budget: at most 32 shared
  buffers (hit plus read) for a caught-up poll of both category statements on a category with
  20,000 idle streams. G2 plan shape: both statements use `ix_stream_events_all_by_category` and
  contain no `Sort` node. G3 read A/B, same process and database, wall-clock, 100 executions per
  cell: candidate over control at most 1.05 on `exhausted-category`, `page-10-streams`, and
  `page-20000-streams-from-0`; at most 0.20 on `caught-up-20000-streams`. G4 append A/B, same
  process, two databases: candidate over control at most 1.05 on a 40-append workload. A gate
  that fails between its threshold and 10% above it is repeated three times on a quiet host
  before the workload or threshold is questioned, per ADR-5.
  Rationale: ADR-5 makes structural checks and same-process controlled ratios the authoritative
  tiers; a threshold chosen after seeing the result is not a gate.
  Date: 2026-09-25

- Decision: If G4 fails after three repeats, stop after M2's measurement, record the verdict, and
  do not merge the schema change. Leave the choice between accepting the append cost and a
  narrower consumer-group-only shape change to the user in a follow-up.
  Rationale: The user's stated constraint is safety and no regression elsewhere; a write-path
  regression above the gate is exactly that, and scaling the work down is their call.
  Date: 2026-09-25

- Decision: Include M5 (category-generation wake gating for consumer-group category members) as
  a separable final milestone.
  Rationale: The report counts 48,714 polls in 840 s because group members wake on every global
  append, while plain category members already wake only on their own category. Reusing the
  existing `liveLoopCategoryNotify` for group members is a small change with an existing test
  pattern, and it multiplies with the per-poll fix. It can be dropped without affecting M1
  through M4.
  Date: 2026-09-25

- Decision: Version bumps and CHANGELOG entries are in scope; publishing to Hackage is not.
  Rationale: Releases follow the existing cohort release process; this plan lands the change on
  `master` with `kiroku-store-migrations` bumped to 0.6.0.0 and `kiroku-store` to 0.9.0.0, and
  records that the store now requires migration `0012`.
  Date: 2026-09-25

- Decision: Track this work under intention `intention_01m3cn0wx4ef9thtphet1ns7vp`, created with
  `mina ci`.
  Rationale: Per-initiative intentions are the expected workflow.
  Date: 2026-09-25


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The schema that matters here

All Kiroku objects live in the PostgreSQL schema `kiroku` (ADR-3,
[`docs/adr/0003-dedicated-kiroku-schema.md`](../adr/0003-dedicated-kiroku-schema.md)). The
tables are created by
[`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`](../../kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql):

- `streams (stream_id, stream_name, category, stream_version, created_at, deleted_at, truncate_before)`.
  `category` is `GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED` and indexed by
  `ix_streams_category (category)`. The row with `stream_id = 0` is the `$all` stream; its
  `stream_version` is the global head position.
- `events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)`.
- `stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)`,
  the *junction table*. Each appended event gets two rows: a *home row* with the source stream's
  id and per-stream version, and an *`$all` row* with `stream_id = 0` whose `stream_version` is
  the global position. `original_stream_id` on both rows names the source stream. Link rows
  (`linkToStreamSQL`) add a row per target stream and never add `$all` rows. The indexes are the
  primary key `(event_id, stream_id)`, `ux_stream_events_stream_version (stream_id, stream_version)`
  (unique, added by `0005`), and the partial
  `ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE stream_id = 0`.
- Immutability triggers `no_update_stream_events` (BEFORE UPDATE) and the gated delete and
  truncate triggers. The backfill in M2 must disable the update trigger for its own UPDATE.

Migrations are a native `pg-migrate` component owned by `kiroku-store-migrations`; the manifest
`kiroku-store-migrations/migrations/manifest` lists eleven files, the last three named `0009.sql`
through `0011.sql`. New files are created with `kiroku-store-migrate new`, every object name is
schema-qualified, released payloads are never edited, and the package suite in
`kiroku-store-migrations/test/Main.hs` proves fresh apply, strict verify, idempotent rerun and the
upgrade-tail shape on both PostgreSQL 17 and 18 (`just test-matrix`). The
`kiroku-store-migrations/expected-schema/` directory is empty; there is no snapshot drift gate to
update. Tests and benches migrate ephemeral databases through
`Kiroku.Test.Postgres.migrateTestDatabase` in `kiroku-test-support`, so a new migration is applied
everywhere automatically.

### The two category statements today

Both live in [`kiroku-store/src/Kiroku/Store/SQL.hs`](../../kiroku-store/src/Kiroku/Store/SQL.hs)
under "Category Read Statements" and "Consumer-Group Read Statements". `readCategoryForwardSQL`
(params `(startPosition, category, limit)`) is:

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

`readCategoryForwardConsumerGroupSQL` (params `(startPosition, category, member, size, limit)`)
is the same text with `LIMIT $5` and one more outer predicate,
`AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3`. A *LATERAL join* is a
subquery in the `FROM` list that may reference columns of the tables before it, so the planner
runs it once per outer row. Here the outer rows are every stream of the category found through
`ix_streams_category`, and each inner run is one probe of `ix_stream_events_all_by_origin`. The
outer `ORDER BY ... LIMIT` cannot stop early because it must see every stream's first candidate
row. So each call costs about one index descent per category stream (the report measured about
1.3 buffer pages per stream) plus the rows returned, whether or not any stream has new events.
The group predicate removes `1 - 1/size` of the streams but is evaluated per stream. For
comparison, `readAllForwardConsumerGroupSQL` is already position-driven: it scans
`ux_stream_events_stream_version` from the cursor and applies the hash to
`se.original_stream_id`.

The plain statement's encoder is `readCategoryEncoder` (`contrazip3`), the group statement's is
`readCategoryConsumerGroupEncoder` (`contrazip5`), and both decode with `recordedEventRow`. The
module has an explicit export list that exports the statements but not these encoders or the row
decoder; M3 exports them additively so the benchmark control can reuse them.

### Who runs these statements

- `kiroku-store/src/Kiroku/Store/Effect.hs`, `ReadCategoryForward`, is the public `readCategory`
  API and runs `readCategoryForwardStmt`. Its callers include `kiroku-metrics`'s WebSocket
  category tail (`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`, `categoryLoop`), which polls
  `readCategory` whenever the publisher position advances.
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, `fetchBatch`, dispatches on
  `(consumerGroup config, target config)`: plain `$all` uses `readAllForwardStmt`, plain category
  uses `readCategoryForwardStmt`, group `$all` uses `readAllForwardConsumerGroupStmt`, and group
  category uses `readCategoryForwardConsumerGroupStmt`. Catch-up for every target goes through the
  FSM's `DeliverBatch`; live mode differs by target. A plain category subscription runs
  `liveLoopCategoryNotify`, which blocks on the Notifier's per-category generation counter
  (`Kiroku.Store.Notification.categoryGenerations`, bumped on every NOTIFY whose payload names a
  stream of that category) with a 30 s safety poll, so an idle category does no database work.
  A consumer-group member of any target runs `liveLoopDbDriven`, which wakes whenever the
  publisher's global position advances, so a group member of a quiet category polls on every
  append anywhere in the store. Both loops drain until an empty fetch and checkpoint at the batch
  tail through `saveCheckpointMemberStmt`, whose `GREATEST` upsert is monotone (ADR-4,
  [`docs/adr/0004-explicit-subscription-checkpoint-lifecycle.md`](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)).
  Checkpoint semantics are unchanged by this plan.
- Tests: `kiroku-store/test/Test/ConsumerGroupSql.hs` proves disjointness, completeness,
  per-stream affinity, determinism, and size-1 equivalence of the group statements against the
  plain reads; `kiroku-store/test/Test/ConsumerGroup.hs` and `Test/ConsumerGroupEffect.hs` use the
  group statement as ground truth for runtime tests; `kiroku-store/test/Test/PerformanceStructure.hs`
  seeds a fixture directly into `stream_events` and asserts, with `EXPLAIN (FORMAT JSON)`, that
  "category high-cursor reads use ix_stream_events_all_by_origin"; `Test/CategoryIdleNoSpin.hs`
  counts `KirokuEventSubscriptionFetched` events to prove idle plain-category members fetch zero
  times and idle group members fetch a bounded number of times.
- Benches: `kiroku-store/bench/Main.hs` has the `category` group (`category forward (100-event page)`,
  `exhausted-category` at cursor 90,000 on a 100-category, 10-streams-each, 100K-event seed) and
  `subscription category catch-up 100 events`; `kiroku-store/bench/RegressionGate.hs` is the
  `kiroku-store-bench-workload-gate` executable that ADR-5's controlled tier runs, with a
  control and candidate store on two ephemeral databases in one process; `kiroku-store/bench/Explain.hs`
  carries a byte-identical copy of `appendAnyVersionSQL`; `kiroku-store/bench/sql/*.sql` are the
  legacy pgbench scripts behind `docs/BENCH-SQL-BASELINE.md` and insert `stream_events` rows
  directly.

### The cost model

Let S be the number of streams in the category, `size` the group size, `limit` the batch size,
`gap` the number of `$all` rows after the checkpoint, and `share` the fraction of `$all` rows that
belong to the category. The three shapes cost, in index probes and rows touched:

| Shape | Caught-up poll | Catch-up page | Quiet category, busy store | Rebuild small category on large store |
| --- | --- | --- | --- | --- |
| LATERAL (today) | S/size probes | S/size probes + limit rows | S/size probes per poll | S/size probes per page |
| Position-driven join (report) | min(gap, limit·size/share) rows | limit·size/share rows | gap rows per poll | whole store once |
| Category index (this plan) | 1 descent | limit·size index entries | 1 descent | category rows once |

The category-index column is the only one with no unbounded cell. The group predicate is
evaluated on index tuples because `original_stream_id` is an `INCLUDE` column, so a member
scanning past other members' events touches only index pages when the visibility map allows.

### Performance gates in this repository

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) and
[`docs/PERF-REGRESSION-GATES.md`](../PERF-REGRESSION-GATES.md) define three tiers. Structural
checks (`just perf-structure`, Hspec `performance structure` specs) and controlled same-process
workload ratios (`just perf-workload-gate`, `kiroku-store/bench/RegressionGate.hs`) are
authoritative; the historical CSV (`kiroku-store/bench/results/baseline.csv`, `just perf-telemetry`,
`just bench-regression`) is telemetry, refreshed only with a written reason and after
`just bench-baseline-check`. [`docs/PERF-METHODOLOGY.md`](../PERF-METHODOLOGY.md) requires a
profile-first expected-impact hypothesis, a ledger check, a pre-registered comparison, and a
row in [`docs/perf-experiment-log.md`](../perf-experiment-log.md) afterwards. The ledger's rows of
2026-05-18 record that removing `streams.category` was tried informally and did not move append
time, which is the opposite direction from this plan; no row concerns category reads.

### Documents that describe the current shape and must change

`docs/user/schema.md` (index table row for `ix_stream_events_all_by_origin`),
`docs/SCALING-ANALYSIS.md` (the "Category reads" section and the index-size table),
`docs/architecture/subscriptions.md` ("Category Subscriptions" and "Consumer-Group Subscriptions"),
`docs/DESIGN.md` (the CTE listing around "Step 5: Link events to $all"),
`docs/BENCH-SQL-BASELINE.md` (its category-read explanation), `docs/user/consumer-groups.md`,
and the two CHANGELOGs.

### ADRs consulted

ADR-2 records that consumer groups hash the surrogate `stream_id` "so no join is added on the hot
`$all` path"; the new group statement keeps the hash on `se.original_stream_id` and adds no join.
ADR-4 fixes checkpoint semantics, which this plan leaves untouched. ADR-5 supplies the gate
tiers used here. ADR-3 requires schema-qualified names in migrations. No ADR records the LATERAL
decision itself; it lives only in plan 10's Decision Log, and M4 promotes the replacement into
ADR-10. No cross-repository ADR applies; the bug's origin is `mori://tan/notification-hub`, whose
evidence is cited in the report.


## Plan of Work

### Milestone 1: reproduce the cost and fix the numbers before touching production code

This milestone builds the measurement the rest of the plan is judged by and confirms the report
in this repository. At its end there is a reusable fixture that seeds three categories of known
shape, benchmark cells that time a caught-up poll at 100 and at 20,000 idle streams for both
category statements, and captured `EXPLAIN (ANALYZE, BUFFERS)` output showing buffers per call
growing with stream count. Nothing under `kiroku-store/src/` changes.

Add a module `Kiroku.Test.Fixtures.CategoryScaling` to `kiroku-test-support` (register it in
`kiroku-test-support/kiroku-test-support.cabal`) exporting `categoryScalingFixtureSql :: Text`,
a `BEGIN ... COMMIT; ANALYZE ...` script in the style of `queryPlanFixture` in
`kiroku-store/test/Test/PerformanceStructure.hs`. It inserts, with `generate_series` and one
`INSERT ... SELECT` per table, category `performance` as 200 streams with 100 events each at
global positions 1 to 20,000, category `idle` as 20,000 streams with one event each at positions
20,001 to 40,000, and category `noise` as 100 streams with 400 events each at positions 40,001
to 80,000, then advances the `$all` row's `stream_version` to 80,000 and runs `ANALYZE` on
`streams`, `events`, and `stream_events`. Until M2 lands, the `stream_events` inserts name only the
five existing columns; M2 adds `category` to the `$all` insert. Export also
`categoryScalingHead :: Int64` (80,000) so callers do not repeat the number.

In `kiroku-store/bench/Main.hs`, add a `category-scaling` benchmark group backed by its own
migrated database (follow `withInventoryBenchmarkStores`, which brackets two databases through
`withSharedMigratedPostgres` and `withMigratedTestDatabase`), seeded with the fixture through
`Session.script`. Its cells each run the statement 100 times and force the result:
`plain caught-up poll, 200 streams` (category `performance`, cursor 80,000),
`plain caught-up poll, 20000 streams` (category `idle`, cursor 80,000),
`group caught-up poll, 20000 streams` (category `idle`, member 1, size 2, cursor 80,000),
`plain page from 0, 20000 streams` (category `idle`, cursor 0, limit 100), and
`exhausted category, 200 streams` (category `performance`, cursor 80,000). Run them and record
the times in Surprises & Discoveries. Then run `just bench-baseline-check`; it will report the
five new names missing from `baseline.csv`. Do not refresh the baseline yet; M3 refreshes it once
with the reason recorded.

Add an `EXPLAIN` capture to the same bench binary behind a flag, or as a one-off Hspec spec that
prints, using the `explainProductionStatement` helper pattern with
`EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT JSON)`: for the plain and group
statements at cursor 80,000 on `performance` and on `idle`, print the top plan node's
`Shared Hit Blocks` plus `Shared Read Blocks`. The expected shape of the evidence is buffers of
the order of 250 for 200 streams and of the order of 26,000 for 20,000 streams, with `Actual Rows`
0. Paste the four figures into Surprises & Discoveries. If the 20,000-stream figure is not at
least ten times the 200-stream figure the report is not reproduced here; stop and reassess before
M2.

Finally move BUG-2 to `confirmed`: set `status: confirmed` in the report's frontmatter, add a
short paragraph under its body noting that `readCategoryForwardSQL` shares the shape and cost,
then run the bundle's strict validation and log the change (commands in Concrete Steps). Append
a `docs/perf-experiment-log.md` row: date, this plan's path, the hypothesis above, variant
"measurement only, LATERAL statements on the category-scaling fixture", the buffer and timing
figures, outcome `confirmed`, lesson "cost is O(streams in category) for both category
statements".

Acceptance: `cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p category-scaling"`
completes and prints the five cells; the captured buffer counts grow roughly linearly with
stream count; `okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce`
passes with BUG-2 `confirmed`.

### Milestone 2: put the category on the `$all` rows and gate the write cost

This milestone changes the schema and the write path without changing any read. At its end,
every `$all` row carries its originating stream's category, the partial index exists, the four
append statements populate the column, every test and bench that inserts junction rows directly
does the same, and a same-process A/B gate shows the write cost stays within the pre-registered
bound.

Create the migration from the repository root:

```bash
cabal run kiroku-store-migrations:kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "denormalize category onto \$all junction rows for category reads"
```

It creates `kiroku-store-migrations/migrations/0012.sql` and appends the name to the manifest.
Replace the generated body with:

```sql
-- denormalize category onto $all junction rows for category reads

-- Category reads (readCategoryForwardSQL and its consumer-group variant in
-- kiroku-store) used to start from every stream of the category and probe
-- stream_events once per stream, so a caught-up poll cost work proportional to
-- the number of streams ever written in the category (BUG-2). Carrying the
-- originating stream's category on each $all junction row lets both reads run
-- as one index range scan from (category, checkpoint) that stops at the limit.
--
-- The column is populated only on $all rows (stream_id = 0). Home rows and link
-- rows keep it NULL; nothing reads them by category. The CHECK below makes any
-- inserter that forgets the column fail loudly instead of writing rows that a
-- category read cannot see.

ALTER TABLE kiroku.stream_events
    ADD COLUMN category TEXT;

COMMENT ON COLUMN kiroku.stream_events.category IS
  'Originating stream''s category, present on $all rows (stream_id = 0) only; equals streams.category of original_stream_id.';

-- Backfill every existing $all row from its originating stream. The immutability
-- trigger rejects every UPDATE on this table, so it is suspended for this one
-- statement and re-enabled before the transaction ends. Runs as the table owner.
ALTER TABLE kiroku.stream_events DISABLE TRIGGER no_update_stream_events;

UPDATE kiroku.stream_events AS se
SET category = s.category
FROM kiroku.streams AS s
WHERE se.stream_id = 0
  AND s.stream_id = se.original_stream_id;

ALTER TABLE kiroku.stream_events ENABLE TRIGGER no_update_stream_events;

ALTER TABLE kiroku.stream_events
    ADD CONSTRAINT ck_stream_events_all_category
    CHECK (stream_id <> 0 OR category IS NOT NULL);

-- Category read path: rows of one category in global-position order. The
-- INCLUDE column lets the consumer-group hash predicate run on index tuples.
CREATE INDEX ix_stream_events_all_by_category
    ON kiroku.stream_events (category, stream_version)
    INCLUDE (original_stream_id)
    WHERE stream_id = 0;

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0012';
```

The whole file runs in one transaction. On a store with N events the UPDATE rewrites N rows and
writes roughly N times 100 bytes of WAL, the CHECK validation reads the table once, and the index
build reads the `$all` rows once; appends are blocked throughout. Record in `docs/user/schema-migrations.md`
that `0012` is a maintenance-window migration whose duration is proportional to the number of
events, and that `VACUUM (ANALYZE) kiroku.stream_events` after it reclaims the old row versions.

Change the four append statements in `kiroku-store/src/Kiroku/Store/SQL.hs`
(`appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`,
`appendAnyVersionSQL`). In each, the stream CTE (`stream_update`, `stream_insert`, or
`stream_upsert`) gains `category` in its `RETURNING` list, and `all_links` inserts it. For
`appendAnyVersionSQL` the diff is:

```diff
       stream_upsert AS (
         INSERT INTO streams (stream_name, stream_version)
         VALUES ($8, (SELECT count(*) FROM new_events))
         ON CONFLICT (stream_name)
         DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
           WHERE streams.deleted_at IS NULL
-        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
+        RETURNING stream_id, category, stream_version - (SELECT count(*) FROM new_events) AS initial_version
       ),
@@
       all_links AS (
-        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
-        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
+        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, category)
+        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx, su.category
         FROM new_events ne
         CROSS JOIN all_update au
         CROSS JOIN stream_upsert su
       )
```

Apply the same two hunks to the other three statements, using their CTE alias (`su` for
`stream_update`, `si` for `stream_insert`). `RETURNING` may name a generated column; the value is
the one PostgreSQL computed for the inserted or updated row, so it is byte-identical to
`streams.category`. `source_links` and `linkToStreamSQL` are unchanged. The `AppendParams`
encoder and result decoder are unchanged.

Update every direct inserter of `$all` rows so the CHECK passes: `queryPlanFixture` in
`kiroku-store/test/Test/PerformanceStructure.hs` (`all_links` gains `category` = `'performance'`),
`categoryScalingFixtureSql` from M1 (each category's `$all` insert names its category), the
raw-shape SQL copies in `kiroku-store/bench/Main.hs` (around lines 130, 181, 290, and 362; add
`RETURNING ... category` and the extra column exactly as in production), the copy in
`kiroku-store/bench/Explain.hs`, and the legacy pgbench scripts under `kiroku-store/bench/sql/`
(`setup.sql` and every `bench_append_*.sql` and `bench_mixed*.sql`; in the PL/pgSQL loops use
`split_part(v_stream_name, '-', 1)`). Do not change `docs/PG-PARTMAN.md` or `docs/DESIGN.md`
yet; M4 handles documentation.

Extend `kiroku-store-migrations/test/Main.hs`. The existing suite already applies the plan's
pending tail in a session that never ran `0001`; mirror that shape to add an upgrade-path case
that applies through `0011`, inserts one stream and two junction rows with the old five-column
shape, applies `0012`, and asserts: the `$all` row's `category` equals the stream's `category`;
zero `$all` rows have NULL `category`; inserting an `$all` row without `category` fails with
SQLSTATE `23514`; `pg_indexes` lists `ix_stream_events_all_by_category` with the expected
definition; `no_update_stream_events` is enabled again (`pg_trigger.tgenabled = 'O'`); and the
schema comment reads "through 0012". Add `0012` to whatever ordered-manifest and checksum
assertions the suite already makes for `0009` through `0011`.

Add the append gate G4 to `kiroku-store/bench/RegressionGate.hs`. Keep the pre-change
`appendAnyVersionSQL` text as a bench-local constant (copy it from `Explain.hs` before editing
that file, or from git at `12d50d5`). Build the control statement with
`Hasql.Statement.preparable oldSql SQL.appendParamsEncoder SQL.appendResultDecoder`, exporting
those two names from `Kiroku.Store.SQL` if the export list at the top of the module lacks them.
The control store's database is migrated through `0012` and then, through `Session.script`,
runs `DROP INDEX kiroku.ix_stream_events_all_by_category` and
`ALTER TABLE kiroku.stream_events DROP CONSTRAINT ck_stream_events_all_category`, so the old SQL's
NULL category inserts succeed and no extra index is maintained; the candidate database is
untouched and uses the production `SQL.appendAnyVersion`. One workload iteration performs 20
single-event appends to fresh stream names (a counter suffix, so the control and candidate do the
same work) and 20 to one hot stream, each through `Pool.use pool (Session.statement params stmt)`
with params from `buildAppendParams` exactly as `runSequentialMultiAppend` already prepares them,
and forces every result. Register `bench "control-append-40"` and
`bcompareWithin 0 1.05 "control-append-40" (bench "candidate-append-40" ...)` under a new
`bgroup "append-category-column"` with `localOption WallTime`.

Acceptance: `cabal test kiroku-store-migrations:kiroku-store-migrations-test` passes on the
default shell (PostgreSQL 18) and `just test-pg 17` passes; `cabal test kiroku-store:kiroku-store-test`
passes unchanged (reads still use LATERAL and ignore the column);
`just perf-workload-gate` prints the `append-category-column` ratio and passes at or below 1.05.
Record the ratio in Surprises & Discoveries. Commit as
`feat(migrations): denormalize category onto $all junction rows (0012)` with the plan and
intention trailers.

### Milestone 3: switch both category reads to the index and prove the two questions

This milestone is the fix. At its end both category statements are index range scans, the
deterministic tests prove the plan shape and the buffer budget, and the same-process A/B gate
proves the non-partitioned read is not slower on its protected cells while the large-category
poll is at least five times faster.

Replace `readCategoryForwardSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs` with:

```sql
SELECT e.event_id, e.event_type,
       se.stream_version, se.stream_version AS global_position,
       se.original_stream_id, se.original_stream_version,
       e.data, e.metadata, e.causation_id, e.correlation_id,
       e.created_at
FROM stream_events se
JOIN events e ON e.event_id = se.event_id
WHERE se.stream_id = 0
  AND se.category = $2
  AND se.stream_version > $1
ORDER BY se.stream_version ASC
LIMIT $3
```

and `readCategoryForwardConsumerGroupSQL` with the same text plus
`AND (((hashtextextended(se.original_stream_id::text, 0) % $4) + $4) % $4) = $3` after the
`stream_version` predicate and `LIMIT $5`. Parameter numbering and both encoders are unchanged.
Rewrite the two Haddock comments: the partition predicate now applies to `se.original_stream_id`
on index tuples, and the read is bounded by rows returned times `size`, not by category stream
count. Export `readCategoryEncoder`, `readCategoryConsumerGroupEncoder`, and `recordedEventRow`
from the module's export list so the benchmark control can build statements with the old SQL.

Update `kiroku-store/test/Test/PerformanceStructure.hs`. Change the existing case to
"category high-cursor reads use ix_stream_events_all_by_category without Sort", asserting
`expectIndex "ix_stream_events_all_by_category"` and `expectNoNodeType "Sort"`, and add the same
assertion for `SQL.readCategoryForwardConsumerGroupStmt` with replacements for `$5` through `$1`
(replace higher-numbered placeholders first). Because the fixture's only category is
`performance`, also seed the M1 `categoryScalingFixtureSql` in `withQueryPlanStore` so the
category predicate is selective and the planner has a reason to prefer the category index over
`ux_stream_events_stream_version`; either index gives correct results, but the test pins the
intended one.

Add the buffer-budget test G1 to the same module under `describe "production query plans"`:
using a helper `explainAnalyzeBuffers` that mirrors `explainProductionStatement` with
`EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, FORMAT JSON)` and returns the top `Plan`
node's `Shared Hit Blocks` plus `Shared Read Blocks`, assert for category `idle` at cursor
`categoryScalingHead` that the plain statement (`$3` = 100) and the group statement (`$3` = 1,
`$4` = 2, `$5` = 100) each read at most 32 buffers and return `Actual Rows` 0; then append one
event to stream `idle-1` through `appendToStream` and assert both statements at the same cursor
read at most 32 buffers and return one row. Run this test once *before* replacing the SQL: it
must fail with a figure in the tens of thousands, and that failure output goes into Surprises &
Discoveries as the before evidence. Then replace the SQL and run it again.

Add the read gate G3 to `kiroku-store/bench/RegressionGate.hs`. Keep both pre-change LATERAL
texts as bench-local constants and build `Statement`s with the exported production encoders and
`D.rowVector SQL.recordedEventRow`. Seed a third database with `categoryScalingFixtureSql`
(control and candidate run against this same database, so only the statement differs). Under
`bgroup "category-read"` with `localOption WallTime`, each cell executes its statement 100 times
through `Pool.use` and forces the vector; register these control and candidate pairs, each
candidate wrapped in `bcompareWithin 0 <bound> "<control name>"`: `exhausted-category`
(`performance`, cursor 80,000, limit 100; bound 1.05), `page-10-streams` (`performance`, cursor
0, limit 100; bound 1.05), `page-20000-streams-from-0` (`idle`, cursor 0, limit 100; bound 1.05),
`plain-caught-up-20000-streams` (`idle`, cursor 80,000; bound 0.20), and
`group-caught-up-20000-streams` (`idle`, member 1, size 2, cursor 80,000; bound 0.20).

Run the full historical suite and refresh the baseline: `just bench-baseline-check` must show
only the M1 cells as missing, then `just bench-baseline`, then `git diff kiroku-store/bench/results/baseline.csv`
must show the `category` and `category-scaling` cells improving and everything else within
noise. The reason for the refresh, "category reads moved to `ix_stream_events_all_by_category`;
new `category-scaling` cells", goes into the Decision Log.

Acceptance: `just perf-structure` passes with the two new plan-shape assertions and G1;
`just perf-workload-gate` passes G3 and G4; `cabal test all` passes, in particular every case in
`Test.ConsumerGroupSql` (including "size 1 is equivalent to an unpartitioned category read"),
`Test.ConsumerGroup`, `Test.ConsumerGroupEffect`, and `Test.CategoryIdleNoSpin`. Commit as
`fix(store): serve category reads from the $all category index (BUG-2)`.

### Milestone 4: durable records, documentation, versions, and the bug report

At the end of this milestone a reader of the repository can learn the new shape and its
rationale without this plan. Write ADR-10 as
`docs/adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md` following
`ADR.md` from the skill: `okf id next docs/adr --profile docs/adr/profile.dhall ADR` currently
returns `ADR-10`; frontmatter fields `type: Architecture Decision Record`, `title`,
`description`, `generated` (`by` is the model's OKF actor id, `at` a UTC timestamp), `docId: ADR-10`,
`status: Accepted`, `date`, `timestamp`, `originatingPlan` pointing at this plan. Its Context
summarizes plan 10's LATERAL decision and BUG-2; its Decision is the column, the CHECK, the
partial index, and the two index-range statements; its Consequences list the write amplification
figure measured by G4, the maintenance-window migration, and that `ix_stream_events_all_by_origin`
now serves only hard deletes; its Alternatives are the LATERAL shape, the position-driven join
(with plan 10's numbers), a worker-side gap-skipping cursor, and an adaptive hybrid. Then
`okf log add` an entry, `okf index docs/adr --write --okf-version 0.2` if the index does not
update itself, and run `just adr-validate`.

Update the documents listed in Context and Orientation. In `docs/user/schema.md` add the column
to the `stream_events` table description and the index to the index table, and mark the origin
index as serving hard deletes. In `docs/SCALING-ANALYSIS.md` rewrite "Category reads" to the
index-range description, replace "Scales with category stream count" with "scales with rows
returned", and add the new index's size estimate to the table. In
`docs/architecture/subscriptions.md` rewrite the two bullet lists that describe the category and
consumer-group category reads. In `docs/DESIGN.md` update the CTE listing's `all_links` step.
In `docs/BENCH-SQL-BASELINE.md` mark the LATERAL explanation as historical. In
`docs/user/schema-migrations.md` document `0012`'s maintenance-window nature and the post-migration
`VACUUM (ANALYZE)`. In `docs/user/consumer-groups.md` add a sentence that a member's poll cost
follows its slice's events, not the category's stream count.

Bump `kiroku-store-migrations` to `0.6.0.0` with a CHANGELOG entry describing `0012`, its backfill
and lock behavior, and the CHECK. Bump `kiroku-store` to `0.9.0.0` with a CHANGELOG entry under
Breaking Changes stating that the store requires migration `0012` (appends fail with SQLSTATE
`42703` on an older schema), under Bug Fixes the BUG-2 resolution with the before and after
buffer counts, and under Other Changes the new exports from `Kiroku.Store.SQL` and the new
benchmark gates. If a `kiroku-store` module documents the migrations version it needs, update it.

Move BUG-2 to `fixed`: `status: fixed`, `fixedVersion: "unreleased"`, and a `resolution` paragraph
that names the column, the index, the measured before and after buffers, and that the plain read
was fixed alongside. Validate the bundle strictly and log the change. Append two rows to
`docs/perf-experiment-log.md`: the read A/B outcome with G3's ratios, and the append A/B outcome
with G4's ratio and the lesson "expected ≤ 3%, observed X%".

Acceptance: `just adr-validate`, the bug-report validation, and `just capabilities-validate` pass;
`cabal build all` and `cabal test all` pass; `git log` shows one commit per concern with both
trailers.

### Milestone 5: stop idle consumer-group category members from polling on every global append

This milestone is separable and reduces poll *count*; M3 reduced poll *cost*. At its end a
consumer-group member of a category that receives no appends performs zero live fetches while
other categories are busy, exactly as a plain category subscription already does.

In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, where the driver chooses
`LiveFromCategoryNotify cat` for `(Nothing, Category cat)` and `LiveFromGroupPolling` for every
consumer-group configuration, choose `LiveFromCategoryNotify cat` for `(Just _, Category cat)`
as well; `$all` groups keep `LiveFromGroupPolling`. `liveLoopCategoryNotify` needs no change:
its `drainTo` calls `fetchBatch`, which already dispatches the group statement, and the category
generation counter advances on every NOTIFY naming a stream of the category, which is a superset
of the member's own streams. Rewrite the comment above `liveLoopCategoryNotify` that says group
members cannot use the per-category signal: they cannot filter to their own *member* from the
payload, but they can gate on the *category*, and the SQL predicate does the member filtering on
fetch. Update the module comment of `kiroku-store/test/Test/CategoryIdleNoSpin.hs` and add a case
that starts a size-2 group on an idle category, appends sustained traffic to another category,
and asserts zero `KirokuEventSubscriptionFetched` events for both members within a window shorter
than the 30 s safety poll, plus a liveness case that one append to the idle category wakes the
owning member. Update `docs/architecture/subscriptions.md` and `docs/capabilities/partitioned-consumer-groups.md`
("Group members are DB-driven in live mode") accordingly.

Acceptance: `cabal test kiroku-store:kiroku-store-test --test-options='--match "CategoryIdleNoSpin"'`
passes with the new cases; the full suite passes. Commit as
`perf(subscription): wake consumer-group category members on their category only`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`
inside the default dev shell, which puts GHC 9.12.4, `cabal`, and PostgreSQL 18 on `PATH`; the
test suites boot ephemeral PostgreSQL servers themselves. Use `just test-pg 17` for the other
supported major.

Provenance for the first write to this plan in a session:

```bash
bun .claude/skills/exec-plan/record-provenance.ts revision \
  --plan docs/plans/91-evaluate-and-fix-partitioned-category-reads-that-scan-every-stream-in-the-category.md \
  --model <your-model-id> --harness <your-harness> --mode implement --note "<one line>"
```

Milestone 1:

```bash
cabal build kiroku-test-support kiroku-store:kiroku-store-bench
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p category-scaling"
just bench-baseline-check      # expected: reports the five category-scaling names as missing
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
```

Expected shape of the bench output (figures are illustrative; record the real ones):

```text
All.category-scaling.plain caught-up poll, 200 streams:    OK ... 4.1 ms
All.category-scaling.plain caught-up poll, 20000 streams:  OK ... 380 ms
All.category-scaling.group caught-up poll, 20000 streams:  OK ... 210 ms
```

Milestone 2:

```bash
cabal run kiroku-store-migrations:kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "denormalize category onto \$all junction rows for category reads"
cabal test kiroku-store-migrations:kiroku-store-migrations-test
just test-pg 17
cabal test kiroku-store:kiroku-store-test
just perf-workload-gate
```

Expected tail of the gate:

```text
All.append-category-column.control-append-40:    OK ...
All.append-category-column.candidate-append-40:  OK ... 1.02x
```

Milestone 3:

```bash
just perf-structure            # run once before replacing the SQL: the budget test must fail
# replace the two statements, then:
just perf-structure
just perf-workload-gate
cabal test all
just bench-baseline-check
just bench-baseline
git diff --stat kiroku-store/bench/results/baseline.csv
```

Expected before evidence, to paste into Surprises & Discoveries:

```text
category caught-up poll on 20000 idle streams reads at most 32 buffers
  expected at most 32 shared buffers, but the plan read 26xxx
```

Milestone 4:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR     # ADR-10
just adr-validate
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
just capabilities-validate
cabal build all && cabal test all
```

Milestone 5:

```bash
cabal test kiroku-store:kiroku-store-test --test-options='--match "CategoryIdleNoSpin"'
cabal test all
```

Every commit carries both trailers:

```text
ExecPlan: docs/plans/91-evaluate-and-fix-partitioned-category-reads-that-scan-every-stream-in-the-category.md
Intention: intention_01m3cn0wx4ef9thtphet1ns7vp
```


## Validation and Acceptance

The plan's two questions are answered by evidence, not prose. The answer to "is the fix safe"
is G1 and G2 passing on both PostgreSQL majors together with G4 at or below 1.05 and the
migrations suite's upgrade-path case proving the backfill and CHECK. The answer to "does it
affect non-partitioned category reads" is G3: the plain statement's `exhausted-category`,
`page-10-streams`, and `page-20000-streams-from-0` candidate-over-control ratios at or below
1.05, printed by `just perf-workload-gate`, together with the plain read's own `caught-up-20000`
cell at or below 0.20 showing it improved rather than merely survived.

Behavioral acceptance is `cabal test all` green, and in particular: `Test.ConsumerGroupSql`
"union of all member slices equals the unpartitioned category read" and "size 1 is equivalent to
an unpartitioned category read" (the statements' results are identical sets to before);
`Test.ConsumerGroup` "resumes member 2 from its own (name, member) checkpoint" (the group
statement remains the runtime's ground truth); `Test.PerformanceStructure` "production query
plans" (six existing cases plus the three added here); and `Test.CategoryIdleNoSpin`.

End-to-end acceptance a human can observe: with `just up` and `just reset-database`, append 20,000
single-event streams `idle-<n>` with any client, start a size-1 consumer group on category `idle`
with `kiroku-jitsurei` or the consumer-groups guide's example, enable `pg_stat_statements`, reset
it, append one event per second to `idle-1` for a minute, and confirm that
`shared_blks_hit + shared_blks_read` per call of the consumer-group statement is below 40 and does
not change when 20,000 more `idle-<n>` streams are added.

Failure signatures to recognize: SQLSTATE `23514` on an insert means a direct inserter did not set
`category`; SQLSTATE `42703` "column se.category does not exist" means the store is running
against a database without `0012`; a G2 failure that lists `ux_stream_events_stream_version`
instead of the category index means the fixture's category is not selective enough for the
planner, which is a fixture problem, not a statement problem; a G1 failure in the tens of
thousands means the statement text still has the LATERAL shape.


## Idempotence and Recovery

M1 adds files and benchmark cells only; it can be re-run freely. The fixture script starts with
`BEGIN` and ends with `COMMIT`, so a failed seed leaves nothing behind.

Migration `0012` is a single transaction: a failure anywhere rolls back the column, the backfill,
the constraint, and the index together, and the trigger is re-enabled by the rollback. `pg-migrate`
records it once and skips it thereafter. It is forward-only like every Kiroku migration; the
recovery for a released defect is a new migration, never an edit. The migration is safe to apply
to a database with zero events (the UPDATE touches no rows) and to one with millions (it takes
proportionally long and blocks appends meanwhile; run it in a maintenance window and
`VACUUM (ANALYZE) kiroku.stream_events` afterwards).

If G4 fails after three repeats on a quiet host, revert the M2 commit (the migration file, the
manifest line, the CTE edits, and the inserter updates) rather than lowering the threshold, record
the ratio in Surprises & Discoveries and the stop in the Decision Log and Outcomes, move BUG-2
back to `confirmed` with a note, and end the plan for the user's decision.

If G3 or G1 fails after the SQL replacement, the statements can be restored from the M2 commit
without touching the schema; the column and index are harmless when unread. Baseline refreshes
are reviewed through `git diff` before commit and reverted with `git checkout` if the diff shows
unexplained movement.

Commits are small and each leaves `cabal test all` green; the bench and gate changes are
additive.


## Interfaces and Dependencies

No public Haskell signature changes. `Kiroku.Store.Read.readCategory`,
`Kiroku.Store.Subscription.Types.ConsumerGroup`, and every subscription entry point keep their
types and semantics. `Kiroku.Store.SQL` additionally exports `readCategoryEncoder`,
`readCategoryConsumerGroupEncoder`, `recordedEventRow`, and, if not already exported,
`appendParamsEncoder` and `appendResultDecoder`; these are internal to the repository's benches.

Schema additions, all in `kiroku` and created by `0012`: column `stream_events.category TEXT`
(non-NULL on `$all` rows by `ck_stream_events_all_category`), index
`ix_stream_events_all_by_category (category, stream_version) INCLUDE (original_stream_id) WHERE stream_id = 0`.
`ix_stream_events_all_by_origin` remains for `deleteAllRowsForOriginStmt`.

New test-support module `Kiroku.Test.Fixtures.CategoryScaling` in `kiroku-test-support`,
exporting `categoryScalingFixtureSql :: Data.Text.Text` and `categoryScalingHead :: Data.Int.Int64`,
used by `kiroku-store/test/Test/PerformanceStructure.hs`, `kiroku-store/bench/Main.hs`, and
`kiroku-store/bench/RegressionGate.hs`.

Tooling: `bun` for the skill scripts; `okf` for the ADR and bug-report bundles; `just`; `cabal`
3.16 with GHC 9.12.4; PostgreSQL 17 and 18 through `ephemeral-pg`; `hasql`, `hasql-pool`,
`tasty-bench` (its `bcompareWithin` provides the ratio gates) as already pinned in
`cabal.project` and the package files. No new external dependency.

Out of repository: `kiroku-bench` (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku-bench`)
pins `kiroku-store` by flake input and its raw-SQL variants insert `stream_events` rows directly;
when it bumps the pin past this change those copies must set `category` on `$all` rows or fail
`ck_stream_events_all_category` loudly. `keiro` consumes `kiroku-store` from Hackage by version
bound and reaches this change only through a release, which is outside this plan.
