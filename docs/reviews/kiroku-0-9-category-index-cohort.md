---
type: Review
title: Kiroku 0.9.0.0 and 0.9.0.1 category-index cohort
description: The 0.8.0.2 to 0.9.0.1 cohort correctly replaces the per-stream LATERAL category reads with one index range scan that fresh same-process gates show 2.5x to 100x faster, correctly fixes the idle publisher's heap retention and wakes category group members only on their category, and documents migration 0012's maintenance window, but the only same-process measurement of 0012's per-event write cost, the append-category-column cell, has a reproducible position effect that makes its 1.05 ceiling pass vacuously, so that cost has never been validly measured.
generated:
  by: process:claude-code
  at: "2026-10-21T14:17:00Z"
reviewId: REV-1
subject: mori://shinzui/kiroku
subjectKind: project
reviewedSha: 94e11392a1e84f33ecd7f135f816e4ce3ea019d2
coverage: incremental
baseSha: 407cb223f7ba5007d36cc77550d8489a1ae7206d
previousReview: mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review
reviewedAt: "2026-10-21T13:57:37Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - performance
  - test-coverage
  - documentation
  - operability
produced:
  - mori://shinzui/kiroku/plans/99-repair-the-append-category-column-workload-cell-and-measure-migration-0012-s-write-cost
context: >-
  Reviewed the 17 commits between the kiroku-store-v0.8.0.2 tag and the
  release commit that published kiroku-store 0.9.0.1 and the dependent
  patches, following the 0.9.0.0 cohort (kiroku-store 0.9.0.0,
  kiroku-store-migrations 0.6.0.0) three commits earlier. The whole source
  diff (migration 0012, the four append CTEs, both category read statements,
  the subscription live-source selection, the publisher position fix) and the
  test, fixture and benchmark changes were read in full by this reviewer. The
  ADR-5 gates, the baseline-name check and every test suite were run at
  repository HEAD e2cdc892, whose category-read and append SQL is this
  cohort's SQL plus the additive 0.11 statements, and the append-category
  cell was repeated five times in different orders to characterize it. This
  is the first record in the bundle: the previous examination of Kiroku is
  the July 2026 review whose findings keiro masterplan 20 carries, which
  covered kiroku-store 0.3.1.0; the 0.4.0.0 through 0.8.0.2 windows
  (2026-07-23 to 2026-09-21) have no review record and this one does not
  claim them. No remote cell was used; no absolute historical timing is used
  as evidence.
---

# Kiroku 0.9.0.0 and 0.9.0.1 category-index cohort

## Verdict

Changes requested, for the evidence rather than the code. Every source change
in this cohort was read against its claim and holds: the two category reads
are the same result set in the same order, served from the new partial index
instead of one probe per stream in the category; consumer-group members on a
category wake on that category's notification generation with the partition
predicate still applied in SQL; the idle publisher forces its position before
storing it; migration 0012 is a documented, single-transaction,
no-rolling-deploy change with an upgrade edge that shipped in the same
cohort. The read-side gain is large and reproduced here. What has never been
established is the other side of the trade: migration 0012 adds a text
column and one partial-index entry to every `$all` row an append writes, and
the one same-process cell that measures that cost cannot measure it.

## Required before the next tag

1. **Repair the `append-category-column` cell and obtain one valid
   measurement of 0012's write cost.** On 2026-09-25 the plan 91 ledger row
   recorded the cell at 1.00x, 1.04x and 1.00x with a spread of about ±100% on
   a host at load 10 to 33 and asked for a repeat on a quiet host. On this
   quiet host (load 1.5 to 3.6) the cell reports, three times in a row,
   control 54 ms ± 61 ms against candidate 3.62 ms ± 25 μs, 0.07x. Run with
   only the candidate arm selected, the candidate reports 55.2 ms ± 62 ms;
   run with only the control arm, 53.8 ms ± 57 ms. Whichever arm is measured
   first after the harness setup pays about 50 ms per iteration with a
   standard deviation of 30 ms for the whole convergence loop, and whichever
   runs second measures the true cost of 40 single-event appends, about
   3.6 ms. The ratio is therefore a function of cell order, and
   `bcompareWithin 0 1.05` accepts any ratio from zero, so the gate has
   passed without ever testing the ceiling. The repair should (a) quiesce the
   shared server after the category-scaling fixture is seeded and the
   warm-ups run, or run a throwaway timed cell before the gated pair, (b)
   refuse a verdict when either arm's doubled standard deviation exceeds a
   stated fraction of its mean, and (c) raise the lower bound of the ceiling
   so a control that is slower than the candidate by more than noise fails
   loudly instead of passing. Then record the measured ratio in
   `docs/perf-experiment-log.md` against the plan 91 row of 2026-09-25.
2. **Record that repair and its result in the ledger.** The methodology's
   step 5 asks for a row whose lesson states expected against observed; the
   expected cost was at most 3%, and the observation so far is that the
   harness could not see it.

## Hot-path performance

| Path | What changed | Evidence | Assessment |
| --- | --- | --- | --- |
| Append, all four CTE variants | `stream_upsert` / `stream_update` / `stream_insert` return `category`; `all_links` writes it onto each `$all` row; the new partial index `ix_stream_events_all_by_category (category, stream_version) INCLUDE (original_stream_id) WHERE stream_id = 0` gains one entry per event | `0012.sql`; `SQL.hs` diff; `streams.category` is `GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED` so it is never null and the CHECK cannot fail for store-written rows | One more indexed column per event. Cost unmeasured: see required item 1 |
| Category read, plain and consumer-group | LATERAL join over every stream of the category replaced by a range scan of the new index from `(category, cursor)` that stops at the limit; the group predicate hashes `se.original_stream_id`, the same value the old statement hashed as `s.stream_id` | Fresh same-process gate at HEAD, below; structural budget test (a caught-up poll on 20,000 idle streams reads at most 32 buffers) passes | Order and result set unchanged; cost follows rows returned instead of streams in the category |
| Consumer-group category member, live phase | `LiveFromCategoryNotify` instead of `LiveFromGroupPolling`; the notify payload is `stream_name,stream_id,stream_version` and `categoryName` takes the prefix before the first `-`, matching `split_part`; the 30 s safety poll remains | `Subscription.hs`, `Worker.hs`, `0001-kiroku-bootstrap.sql`, `Types.hs`; `CategoryIdleNoSpin.hs` | Members of idle categories do no live database work; a sibling's append costs one empty fetch |
| Publisher idle position | `nextPos \`seq\` writeTVar` forces the `Int64` before storage | `EventPublisher.hs`; `PublisherIdleAdvance.hs` post-major-GC case | Fixes BUG-3 retention; no per-batch cost |
| Hard delete | Unchanged; `deleteAllRowsForOriginStmt` still removes the origin's `$all` rows first, so the category read's loss of the `streams` join changes nothing for deleted streams | `SQL.hs` at HEAD | Unchanged |

Fresh same-process measurements at HEAD e2cdc892, `just perf-workload-gate`
(`--stdev 5`, wall time, one PostgreSQL 18.4 server, load 1.5 to 2.3):

| Cell | Control | Candidate | Ratio | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| exhausted category | 1.37 ms ± 113 μs | 535 μs ± 27 μs | 0.39x | 1.05 |
| page from 0, 200 streams | 156 ms ± 14 ms | 5.07 ms ± 426 μs | 0.03x | 1.05 |
| page from 0, 20,000 streams | 203 ms ± 14 ms | 4.87 ms ± 475 μs | 0.02x | 1.05 |
| plain caught-up poll, 20,000 streams | 67.0 ms ± 2.7 ms | 525 μs ± 43 μs | 0.01x | 0.20 |
| group caught-up poll, 20,000 streams | 45.3 ms ± 3.8 ms | 577 μs ± 36 μs | 0.01x | 0.20 |
| pipelined multi-append, 4 and 8 streams | 370 μs, 659 μs | 316 μs, 570 μs | 0.86x, 0.87x | 0.90 |
| append-category-column, 40 appends | 54.3 ms ± 61 ms | 3.62 ms ± 25 μs | 0.07x | 1.05 (vacuous) |

The category-read numbers reproduce the 2026-09-25 ledger row (0.43x, 0.03x,
0.02x, 0.01x, 0.01x) on a different host, which is as much corroboration as
two same-process runs can give. The append cell is discussed above; the
0.07x is not a result.

What this means for a consumer: nothing in this cohort adds a round trip or a
lock to any append or read. The only write-side addition is one index entry
and one short text per event, which the WAL-per-append diagnostic retained
with the 0.11 cohort (about 2,050 bytes per append at 0.10, after 0012)
cannot separate from the pre-0012 figure because none was taken. A consumer
whose own absolute-baseline guard turned red after adopting 0.9 cannot
attribute that to Kiroku from this evidence, and Kiroku cannot currently
refute it by measurement; required item 1 is what would.

## Correctness

- The group predicate is applied to `se.original_stream_id` where the old
  statement applied it to `s.stream_id` under `se.original_stream_id =
  s.stream_id`, so every member keeps exactly its slice across the upgrade;
  no checkpoint moves.
- Dropping the `streams` join cannot surface rows the old read hid:
  soft-deleted streams were never filtered by either statement, and hard
  delete removes the `$all` rows before the stream row.
- `streams.category` is a stored generated column, so `RETURNING category`
  from the insert and upsert CTEs is always populated and the new CHECK
  constraint can only fire for writers that bypass the store, which is what
  the changelog says it is for.
- The migration backfill runs with the immutability trigger disabled for one
  statement and re-enabled in the same transaction; the migrations suite has
  an upgrade case that applies 0012 to a store populated with pre-0012 rows
  and checks the backfill, constraint, index definition and re-enabled
  trigger.
- The publisher fix forces an `Int64`, which is full evaluation; the
  regression test allocates, appends, forces a major GC and checks the
  retained heap.

## Operability

Migration 0012 is one transaction that rewrites every `$all` row and builds
the index under a write-blocking lock; there is no rolling deploy in either
direction (old writers fail with SQLSTATE 23514 after it, new writers fail
with 42703 before it). The changelog, `docs/user/schema-migrations.md` and the
`0.8.0.2 -> 0.9.0.0` upgrade edge all say so, prescribe a rehearsal on a
restored clone, a maintenance window and a `VACUUM (ANALYZE)` afterwards. The
`DISABLE TRIGGER` requires the migrating role to own the table, which the
migration comment states.

## Test coverage

`CategoryIdleNoSpin.hs` (members of an idle category do not spin),
`PublisherIdleAdvance.hs` (post-GC retention), `PerformanceStructure.hs`
(buffer budget on the category-scaling fixture, 20,000 streams), the
migrations upgrade case for 0012 and the `CategoryScaling` fixture were added
or extended in this cohort and would catch a regression of each claim. At HEAD
every suite passes (487 store, 117 metrics, 45 adapter, 24 otel, 22 CLI, 17
migration examples) and `just bench-baseline-check` reports 30 historical
names matching exactly.

## Documentation

The kiroku-store 0.9.0.0 and 0.9.0.1 entries, the migrations 0.6.0.0 entry
and the dependent packages' bump notes match the code, including the
no-rolling-deploy statement and the consumer-group wake change. The ledger
row for plan 91's G4 gate honestly records that the gate passed without
resolving the cost; this review's finding is the follow-up it asked for.

## Evidence and limits

- Local, at HEAD e2cdc892 between 13:37Z and 13:53Z on 2026-10-21:
  `just perf-structure` (41 examples), `just bench-baseline-check`,
  `just perf-workload-gate` once in full and the append cell twice more in
  isolation and once per arm alone, `cabal test all`. Total measured time
  about ten minutes inside a sixty-minute budget.
- Retained: `docs/perf-experiment-log.md` rows of 2026-09-25,
  `kiroku-store/bench/RegressionGate.hs`.
- Not done: no build at the 0.9.0.1 tag itself (the gates ran on HEAD, whose
  append and category SQL contain this cohort's statements unchanged); no
  root-cause of the position effect beyond its characterization; no remote
  cell.
