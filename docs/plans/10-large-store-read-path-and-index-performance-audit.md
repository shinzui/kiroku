---
id: 10
slug: large-store-read-path-and-index-performance-audit
title: "Large-store read path and index performance audit"
kind: exec-plan
created_at: 2026-05-06T20:43:05Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/2-focused-event-store-reliability-and-scale-audit.md"
---

# Large-store read path and index performance audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan audits performance risks that would become expensive once the event store grows. After it is complete, maintainers have current query-plan evidence, benchmark coverage, and operational notes for the main read/write paths: stream reads, `$all` reads, category reads, hot-stream writes, concurrent writes, and subscription catch-up.

The useful outcome is a short list of must-fix performance red flags, accepted scaling tradeoffs, and benchmark gates that catch regressions before a large production table makes them painful.


## Progress

- [ ] Inventory current benchmarks, baseline files, and scaling documentation.
- [ ] Capture query plans for stream, `$all`, category, and checkpoint read paths on representative data.
- [ ] Add missing benchmark coverage for high-write, hot-stream, or subscription scenarios discovered by EP-1 through EP-3.
- [ ] Review large-table risks: indexes, `$all` row contention, autovacuum, hard deletes, category cardinality, and benchmark baseline drift.
- [ ] Land benchmark/doc updates and record the final scale-risk verdict.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Treat this as a performance audit with targeted benchmark additions, not as a mandate to implement partitioning.
  Rationale: Existing `docs/SCALING-ANALYSIS.md` argues against time-based partitioning for this schema. The correct first step is evidence and regression gates, not structural churn.
  Date: 2026-05-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Current benchmark and scaling context is spread across the repository. `docs/BENCH-SQL-BASELINE.md` records raw SQL baselines for Strategy E, including `$all` row contention and read paths. `docs/BENCH-HASKELL-APPEND.md` records Haskell append overhead. `docs/BENCH-REGRESSION.md` describes the `tasty-bench` baseline workflow. `docs/SCALING-ANALYSIS.md` estimates billion-row behavior and recommends B-tree indexes, operational tuning, hot/cold archival later, and avoiding time-based partitioning. `docs/PRODUCTION-TUNING.md` documents pool sizing, statement timeout, subscription queue capacity, monitoring, and `$all` contention.

The Haskell benchmark suite is `kiroku-store/bench/Main.hs`. It uses `ephemeral-pg`, pre-populates category and read data, runs append/read/category benchmarks, and includes structured concurrent-writer benchmarks. The on-disk benchmark baseline is `kiroku-store/bench/results/baseline.csv`. Justfile targets include `just bench-baseline`, `just bench-regression`, and `just bench-regression-pattern`.

The primary read SQL lives in `kiroku-store/src/Kiroku/Store/SQL.hs`. `readStreamForwardSQL` and `readStreamBackwardSQL` filter by stream id and stream version. `readAllForwardSQL` and `readAllBackwardSQL` filter by `stream_id = 0` and global position. `readCategoryForwardSQL` filters `$all` rows by joining the originating stream's generated `category` column. Checkpoint reads and writes use the `subscriptions` table through `getCheckpointStmt` and `saveCheckpointStmt`.


## Plan of Work

Milestone 1 inventories current performance coverage. Read the benchmark docs, `Justfile`, `kiroku-store/bench/Main.hs`, and `kiroku-store/bench/results/baseline.csv`. Record which user concerns are already covered and which are not: high-write ordering tests are not the same as benchmarks, hot `skill-installer` writes may not have a benchmark, and subscription catch-up may not have a benchmark.

Milestone 2 captures query-plan evidence. Add temporary or permanent helper SQL only if needed. Populate representative data using the existing benchmark harness or direct test helpers, then run `EXPLAIN (ANALYZE, BUFFERS)` for stream forward, `$all` forward, category forward, `getCheckpointStmt`, and `saveCheckpointStmt`. The evidence should confirm that the planner uses `ix_stream_events_stream_version`, `ix_stream_events_all_by_origin`, `ix_streams_category`, and the `subscriptions.subscription_name` unique index as expected.

Milestone 3 adds missing benchmark gates. If EP-1, EP-2, or EP-3 added new stress scenarios that are performance-sensitive, add compact `tasty-bench` entries to `kiroku-store/bench/Main.hs`. Good candidates are hot single-stream `AnyVersion`, hot `skill-installer`, concurrent `appendMultiStream`, and subscription catch-up over a known backlog. Avoid adding long soak tests to the default benchmark suite.

Milestone 4 updates documentation. If query plans or benchmarks differ from `docs/SCALING-ANALYSIS.md`, `docs/PRODUCTION-TUNING.md`, or `docs/BENCH-REGRESSION.md`, update those docs with the new evidence. If no red flags are found, say so explicitly and name the residual risks: `$all` row lock contention, category cardinality, index bloat after hard deletes, and backup/restore time.


## Concrete Steps

Run baseline tests before benchmark work:

    cabal test kiroku-store

Inventory performance artifacts:

    sed -n '1,260p' kiroku-store/bench/Main.hs
    sed -n '1,220p' docs/BENCH-REGRESSION.md
    sed -n '1,260p' docs/SCALING-ANALYSIS.md
    sed -n '1,260p' docs/PRODUCTION-TUNING.md
    head -20 kiroku-store/bench/results/baseline.csv

Run current benchmark regression:

    just bench-regression

If the full regression is too slow for an inner loop, use focused patterns:

    just bench-regression-pattern append
    just bench-regression-pattern concurrent
    just bench-regression-pattern category

For query-plan evidence, use an ephemeral benchmark database or a local `just up` database. Capture short `EXPLAIN (ANALYZE, BUFFERS)` outputs for the main read paths and paste concise summaries into Surprises & Discoveries. Do not paste huge plans; include the index names, row counts, planning time, and execution time.


## Validation and Acceptance

Acceptance requires a clear scale-risk verdict in this plan. Every main read path must either have evidence that it uses the intended index or a finding explaining why it does not. Every benchmark addition must be included in `kiroku-store/bench/Main.hs`, run through `just bench-regression-pattern <pattern>`, and either compare cleanly against the existing baseline or come with a documented baseline update decision.

Documentation acceptance requires the current docs to match the evidence. If `docs/SCALING-ANALYSIS.md` remains correct, add a brief note naming this audit's confirmation. If it is wrong, revise it rather than leaving conflicting guidance.


## Idempotence and Recovery

Benchmark runs are safe to repeat, but they can be noisy. Do not update `kiroku-store/bench/results/baseline.csv` to hide noise. Follow `docs/BENCH-REGRESSION.md`: update the baseline only after investigating and accepting a reproducible change.

`EXPLAIN ANALYZE` on temporary or ephemeral data is safe. Avoid running destructive SQL on a shared database. If using `just up`, create audit-specific stream names and do not truncate shared tables unless the user explicitly asks for a reset.


## Interfaces and Dependencies

Use existing `tasty-bench`, `ephemeral-pg`, and `Justfile` benchmark tooling. Use PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)` for query plans. Do not add external benchmark frameworks.

Coordinate with EP-1 at `docs/plans/8-high-write-append-ordering-and-atomicity-audit.md`, EP-2 at `docs/plans/7-hot-system-stream-and-skill-installer-workload-audit.md`, and EP-3 at `docs/plans/9-subscription-ordering-catch-up-and-checkpoint-reliability-audit.md` before adding benchmark entries for their scenarios.
