---
id: 21
slug: evaluate-append-hot-path-performance-experiments
title: "Evaluate Append Hot Path Performance Experiments"
kind: exec-plan
created_at: 2026-05-17T23:36:35Z
---

# Evaluate Append Hot Path Performance Experiments

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku's benchmark regression gate currently fails on append-heavy paths, especially the structured benchmark named `All.concurrent.32 writers x 10 appends`. The goal of this plan is to determine, with measured evidence, whether small append hot-path changes inspired by Commanded EventStore reduce the slowdown without weakening Kiroku's append ordering or optimistic-concurrency semantics.

After this plan is complete, a contributor can point to a benchmark report that says which experiment helped, which did not, and whether any production code should be kept. The visible outcome is not a new public API. The visible outcome is a reproducible benchmark comparison using `cabal bench kiroku-store:kiroku-store-bench` and the checked-in baseline file at `kiroku-store/bench/results/baseline.csv`.


## Progress

- [x] Created this ExecPlan from the repository skeleton on 2026-05-17.
- [x] Milestone 1: Captured initial focused current-performance evidence for `32`, `NoStream`, and `invoice-payment` on 2026-05-18.
- [x] Milestone 2: Prototyped replacing repeated SQL `count(*)` reads with an explicit event-count parameter, measured it, and discarded it because the primary benchmark got worse.
- [x] Milestone 3: Prototyped a specialized `AnyVersion` update/insert path that avoids upsert in the normal case and keeps the original upsert as fallback.
- [x] Milestone 4: Prototyped a `VALUES`-based one-event append statement, measured it, and discarded it because it did not improve the primary benchmark.
- [x] Milestone 5: Compared results, reverted the experimental source changes, and recorded the final recommendation on 2026-05-18.


## Surprises & Discoveries

- EventStore does not eliminate the global `$all` write bottleneck. Its append SQL still updates the single `$all` row with `UPDATE streams SET stream_version = stream_version + $2::bigint WHERE stream_id = 0`. The relevant files in the local EventStore checkout are `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store/sql/statements/insert_events.sql.eex` and `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store/sql/statements/insert_events_any_version.sql.eex`.
- The current Kiroku append CTEs repeatedly compute `(SELECT count(*) FROM new_events)` inside each statement. The affected statements live in `kiroku-store/src/Kiroku/Store/SQL.hs` as `appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`, and `appendAnyVersionSQL`.
- Initial focused evidence on 2026-05-18 showed broad local slowdown before source edits: `32 writers x 10 appends` was 1.055s, 63 percent over baseline; `NoStream` was 296us for single-event, 637us for batch-10, and 3.28ms for batch-100; `hot invoice-payment 10 AnyVersion appends` was 2.99ms, 88 percent over baseline. Transcripts are in `docs/bench/append-hot-path/2026-05-18-head-*.txt`.
- The explicit event-count parameter experiment passed `cabal test kiroku-store:kiroku-store-test` with 129 examples and 0 failures, but the primary `32 writers x 10 appends` measurement worsened to 1.262s. The experiment was discarded. Transcripts are in `docs/bench/append-hot-path/2026-05-18-event-count-*.txt`.
- The `AnyVersion` update/insert split passed `cabal test kiroku-store:kiroku-store-test` with 129 examples and 0 failures. Its first focused measurements were mixed: `32 writers x 10 appends` stayed essentially unchanged at 1.069s, while `hot invoice-payment 10 AnyVersion appends` improved to 2.26ms and then 2.07ms on a direct `AnyVersion` pattern run. This suggests the change helps repeated appends to an existing hot stream but does not solve fresh-stream `$all` contention.
- The one-event scalar `VALUES` experiment passed `cabal test kiroku-store:kiroku-store-test` with 129 examples and 0 failures, but `32 writers x 10 appends` measured 1.140s and `AnyVersion (new stream)` measured 200us. The experiment was discarded because it added complexity without improving the primary target.
- The full `just bench-regression` run with the kept `AnyVersion` split still failed 10 of 15 benchmarks. The primary `32 writers x 10 appends` benchmark measured 808ms, 25 percent more than baseline. The `hot invoice-payment 10 AnyVersion appends` benchmark measured 1.78ms, 12 percent more than baseline, which is much better than the initial focused 2.99ms result but still just over the 10 percent gate in the full suite.
- `cabal test all` did not pass as a whole because `hasql-notifications-test` failed before Kiroku code was involved with `Could not open database connection`. In the same command, `kiroku-store-test` passed with 129 examples and 0 failures, `kiroku-otel-test` passed with 6 examples and 0 failures, and `shibuya-kiroku-adapter-test` passed with 7 examples and 0 failures.
- After reviewing the complexity and the full-suite benchmark result, the source-code experiment was reverted. The focused invoice-payment numbers showed a possible improvement, but the full-suite invoice-payment result was effectively flat versus the earlier full-suite failure, and the primary `32 writers x 10 appends` regression did not improve.


## Decision Log

- Decision: Treat this as an evidence-gathering performance plan, not as a direct refactor plan.
  Rationale: The 32-writer benchmark failed even at the commit that introduced the benchmark workflow under the current local environment, so the first task is to separate real code improvements from benchmark noise.
  Date: 2026-05-17
- Decision: Test each optimization separately before combining them.
  Rationale: Performance changes interact. A combined patch can make it impossible to tell whether the event-count parameter, the `AnyVersion` path split, or `VALUES` input shape caused a result.
  Date: 2026-05-17
- Decision: Do not change the checked-in `kiroku-store/bench/results/baseline.csv` during the experiment milestones.
  Rationale: The baseline is the comparison target. A baseline refresh belongs only after a measured, explained decision is made.
  Date: 2026-05-17
- Decision: Discard the explicit event-count parameter experiment.
  Rationale: It preserved correctness but made the primary `32 writers x 10 appends` focused run slower, moving from 1.055s before edits to 1.262s with the patch.
  Date: 2026-05-18
- Decision: Validate the `AnyVersion` update/insert split but do not keep it.
  Rationale: It preserved the original upsert as fallback and improved the hot existing-stream benchmark from 2.99ms before edits to 2.26ms and 2.07ms in focused runs, but the full-suite result was 1.78ms versus an earlier full-suite 1.76ms, and it did not improve the fresh-stream 32-writer benchmark.
  Date: 2026-05-18
- Decision: Discard the scalar one-event `VALUES` path.
  Rationale: It did not improve `32 writers x 10 appends` and made the single-event `AnyVersion` new-stream focused run worse than the split-path-only measurement.
  Date: 2026-05-18
- Decision: Revert all source-code experiments and keep only documentation plus benchmark evidence.
  Rationale: The added append SQL path increased maintenance complexity without a reliable full-suite improvement. The evidence is still useful for future work, so the ExecPlan and benchmark transcripts remain.
  Date: 2026-05-18


## Outcomes & Retrospective

No source-code change is kept. The work produced benchmark evidence showing that the tested EventStore-inspired SQL-shape changes do not justify extra append-path complexity in Kiroku at this time. The most promising experiment, an `AnyVersion` split update/insert path, improved focused hot-stream runs but did not improve the full-suite result enough to clear the gate or justify another large append CTE.

The work did not fix the full benchmark regression gate. The `32 writers x 10 appends` workload primarily creates fresh unique streams and still contends on the `$all` stream row; none of the event-count parameter, `AnyVersion` split-path, or scalar one-event `VALUES` experiments produced a stable improvement there. The next meaningful performance plan should either stabilize the benchmark gate for noisy local environments or investigate a larger design that reduces lock hold time around `$all` more substantially than these SQL-shape changes.

Validation completed on 2026-05-18 during the experiment: `cabal test kiroku-store:kiroku-store-test` passed with 129 examples and 0 failures for each source experiment. `just bench-regression` still failed with the best source experiment, with output recorded in `docs/bench/append-hot-path/2026-05-18-anyversion-split-full-bench-regression.txt`. `cabal test all` was attempted and failed only because `hasql-notifications-test` could not open a database connection; Kiroku package tests that completed passed. After the final revert, the source tree returned to the pre-experiment append implementation.


## Context and Orientation

Kiroku is a Haskell PostgreSQL event store. An event store persists immutable application events into named streams. A stream is an ordered sequence of events. Kiroku also maintains a special global stream named `$all`, represented by the row `stream_id = 0` in the `streams` table, so readers and subscriptions can observe every event in one total order.

The append hot path is the code that writes new events. It is hot because it runs for every event append. In Kiroku it is implemented in `kiroku-store/src/Kiroku/Store/SQL.hs` and called by `kiroku-store/src/Kiroku/Store/Effect.hs`. The SQL uses common table expressions, abbreviated CTEs. A CTE is a named subquery introduced by `WITH`; Kiroku uses data-modifying CTEs so one SQL statement can update the stream row, insert event payloads, insert per-stream links, update `$all`, and insert `$all` links atomically.

The key append statements in `kiroku-store/src/Kiroku/Store/SQL.hs` are:

- `appendExpectedVersionSQL`, used when the caller supplies an exact current stream version.
- `appendStreamExistsSQL`, used when the stream must already exist but any current version is acceptable.
- `appendNoStreamSQL`, used when the stream must not already exist.
- `appendAnyVersionSQL`, used when the append should create the stream if needed or append to it if it already exists.

The benchmark suite is `kiroku-store/bench/Main.hs`. The benchmark regression workflow is documented in `docs/BENCH-REGRESSION.md`. The Justfile target `just bench-regression` runs all benchmarks against `kiroku-store/bench/results/baseline.csv` and fails if any benchmark is more than 10 percent slower. Focused benchmark runs can be made with `cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline ... --fail-if-slower 10 -p PATTERN"`.

The benchmark currently under suspicion is `All.concurrent.32 writers x 10 appends`. In `kiroku-store/bench/Main.hs`, the helper `runConcurrentWriters` starts several Haskell threads with `mapConcurrently_`. Each thread appends 10 one-event writes to unique stream names using `appendToStream sn AnyVersion [makeEvent "ConcEvent"]`. This stresses both Kiroku's per-append overhead and the unavoidable PostgreSQL row lock on the `$all` stream row.

The comparison project is Commanded EventStore at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`. It has a similar schema: a `streams` table, an `events` table, a `stream_events` join table, and a `$all` row with `stream_id = 0`. EventStore still updates the `$all` row on append, so it does not provide a design that removes this lock. It does provide implementation ideas that may reduce the time spent before or while contending on the lock:

First, EventStore passes the event count as a parameter named `$2` and uses it throughout its append SQL, instead of repeatedly asking PostgreSQL to count the new event rows. Second, EventStore's generated SQL uses a `VALUES` list for event parameters rather than array `unnest`. Third, EventStore has a distinct `:any_version` SQL template and does not always use one generic upsert path for existing streams. Fourth, EventStore batches up to 1000 events per statement because PostgreSQL has a 65,535-parameter limit.

Kiroku's current benchmark data is in `kiroku-store/bench/results/baseline.csv`. As of this plan's creation, the `All.concurrent.32 writers x 10 appends` baseline row is 645071900000 picoseconds, about 645 milliseconds. Recent local focused runs have been materially slower, but also noisy, which is why the plan requires repeated measurements.


## Plan of Work

Milestone 1 establishes a measurement harness before changing production code. Run focused benchmarks for the affected append paths multiple times and save the output under `docs/bench/append-hot-path/`. This folder is new and contains human-readable benchmark transcripts, not golden test data. The point is to know the local variance before judging a patch.

Milestone 2 prototypes an explicit event-count parameter. In `kiroku-store/src/Kiroku/Store/SQL.hs`, extend `AppendParams` and `appendParamsEncoder` with a strict count field, likely `eventCount :: Int64`. In `kiroku-store/src/Kiroku/Store/Effect.hs`, set that count in `buildAppendParams` from `length prepared`. Replace repeated `(SELECT count(*) FROM new_events)` in the append CTEs with the new parameter. This experiment keeps the same CTE shape and should preserve behavior exactly. Its acceptance criterion is that `cabal test kiroku-store:kiroku-store-test` passes and focused benchmark medians improve or remain neutral.

Milestone 3 prototypes a specialized `AnyVersion` path for existing streams. Kiroku's current `appendAnyVersionSQL` uses `INSERT INTO streams ... ON CONFLICT DO UPDATE`. That is correct and compact, but the concurrent benchmark appends one event per unique stream name, so it may pay unnecessary upsert cost. This milestone should add an experiment-only path that first tries a simple existing-stream update statement and falls back to the current upsert statement only when the update returns no row. If the extra round trip makes fresh-stream workloads worse, record that and discard the change. If existing hot-stream workloads improve without hurting fresh streams, keep the narrower part.

Milestone 4 prototypes a `VALUES`-based one-event append statement. This is deliberately narrow: only one-event appends should use it, because the failing 32-writer benchmark and the single-event append benchmarks are one-event writes. Add a separate SQL statement for the one-event case rather than replacing the general array `unnest` path. The statement should accept scalar event parameters, preserve the same error behavior, and still write to `events`, source `stream_events`, `$all`, and `$all` `stream_events`. If the code complexity is not justified by measured improvement, discard it.

Milestone 5 compares all results. If no experiment gives a stable improvement greater than local variance, revert the prototypes and document that the current regression gate is mostly benchmark/environment sensitive. If an experiment gives a stable improvement, keep the smallest patch, run the full benchmark regression gate, update `docs/BENCH-REGRESSION.md` or the relevant plan decision log with measured before/after numbers, and only then consider refreshing `kiroku-store/bench/results/baseline.csv`.

Each milestone must be committed separately if it changes source code. Every commit must include this trailer:

```text
ExecPlan: docs/plans/21-evaluate-append-hot-path-performance-experiments.md
```


## Concrete Steps

All commands in this section run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Before changing code, confirm the project identity and dependency map using Mori:

```bash
mori show --full
```

Expected output includes `kiroku-store` as a package and dependencies including `hasql/hasql`, `hasql:hasql-pool`, and `shinzui/ephemeral-pg`.

Create a folder for benchmark evidence:

```bash
mkdir -p docs/bench/append-hot-path
```

Capture focused current measurements. Run each command at least three times on a quiet machine. Save the terminal output manually into files named with the date, commit, and benchmark pattern, for example `docs/bench/append-hot-path/2026-05-17-head-32-writers-run1.txt`.

```bash
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p 32"
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p NoStream"
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p invoice-payment"
```

Use `--fail-if-slower 100` during investigation so the command completes and reports numbers even when it exceeds the normal 10 percent gate. Expected output for the first command includes a single benchmark section like:

```text
All
  concurrent
    32 writers x 10 appends:
      800  ms +/- ...
```

For Milestone 2, edit `kiroku-store/src/Kiroku/Store/SQL.hs` and `kiroku-store/src/Kiroku/Store/Effect.hs`. Add `eventCount` to the append parameter structure and encoder, set it in `buildAppendParams`, and replace each append CTE's repeated count subquery with that field. Run:

```bash
cabal test kiroku-store:kiroku-store-test
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p 32"
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p NoStream"
```

Record the results in this plan's Surprises & Discoveries section and in `docs/bench/append-hot-path/`.

For Milestone 3, edit `kiroku-store/src/Kiroku/Store/SQL.hs` to add a narrow existing-stream `AnyVersion` statement, and edit `kiroku-store/src/Kiroku/Store/Effect.hs` to dispatch the experiment. Keep the current upsert statement available as the fallback. Run:

```bash
cabal test kiroku-store:kiroku-store-test
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p 32"
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p invoice-payment"
```

For Milestone 4, add a one-event append statement only if Milestones 2 and 3 do not explain the regression or if the measurements show that SQL input-shape overhead is still significant. Run:

```bash
cabal test kiroku-store:kiroku-store-test
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p 32"
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="--baseline $PWD/kiroku-store/bench/results/baseline.csv --fail-if-slower 100 -p 'NoStream'"
```

After choosing the final state, run the normal gate:

```bash
just bench-regression
```

If the normal gate still fails only because unrelated noisy benchmarks cross 10 percent, record the exact output in this plan rather than hiding the failure.


## Validation and Acceptance

The implementation is acceptable only if correctness and benchmark evidence are both present.

Correctness acceptance means:

```bash
cabal test kiroku-store:kiroku-store-test
```

passes with all tests green. If source changes touch shared append behavior, also run:

```bash
cabal test all
```

Benchmark acceptance means each kept optimization has at least three focused before/after measurements for the same benchmark pattern on the same machine, with the same command shape, and the results are recorded in `docs/bench/append-hot-path/` plus summarized in this plan. A change should be kept only when the improvement is larger than observed local run-to-run variance. As an initial rule, require at least a 10 percent improvement in `All.concurrent.32 writers x 10 appends` or a clearly explained improvement in two related append benchmarks such as `All.append.single-event.AnyVersion` and `All.reliability-audit.hot invoice-payment 10 AnyVersion appends`.

The plan is complete when the Outcomes & Retrospective section says one of the following:

First, no code change was kept because none beat noise; the recommendation is to stabilize or relax the benchmark gate. Second, one or more source changes were kept; the plan records the final benchmark evidence, and the full test suite result is documented. Third, a larger schema change is needed; the plan records why the small hot-path experiments were insufficient and names the next plan that should be written.


## Idempotence and Recovery

The benchmark commands are safe to rerun. They use ephemeral PostgreSQL through `ephemeral-pg` and do not modify persistent user data. The `docs/bench/append-hot-path/` evidence files are additive and can be regenerated if a run was taken while the machine was busy.

Do not edit `kiroku-store/bench/results/baseline.csv` during Milestones 1 through 4. If it changes accidentally, restore only that file from the current branch after verifying it is not a user edit:

```bash
git diff -- kiroku-store/bench/results/baseline.csv
git restore kiroku-store/bench/results/baseline.csv
```

Do not use `git reset --hard`. If an experiment makes the code messy, revert only the files changed by that experiment after reviewing `git diff`. If another user has changed the same files, preserve their changes and manually remove only the experimental patch.

If a benchmark run fails because Cabal splits a pattern containing spaces, use a simpler pattern such as `-p 32`, `-p NoStream`, or `-p invoice-payment`. This avoids the quoting issue observed with tasty-bench's suggested patterns.


## Interfaces and Dependencies

The core modules are:

`kiroku-store/src/Kiroku/Store/SQL.hs`: owns Hasql `Statement` values and the SQL text. Any new append statement belongs here. `AppendParams` is the parameter record for append statements. The encoder named `appendParamsEncoder` must match the SQL parameter order exactly.

`kiroku-store/src/Kiroku/Store/Effect.hs`: owns the `Store` effect interpreter. `runStorePool` dispatches `AppendToStream` to one of the SQL statements. `prepareEvents` fills in missing UUIDv7 event ids. `buildAppendParams` turns prepared events and a stream name into `SQL.AppendParams`.

`kiroku-store/bench/Main.hs`: owns benchmark definitions. Do not change benchmark names in this plan unless the purpose is explicitly to add an experiment-only benchmark. Existing names are used as keys into `kiroku-store/bench/results/baseline.csv`.

`Justfile`: owns benchmark recipes. Prefer using existing targets. If a new helper target is added, it must be additive and documented in `docs/BENCH-REGRESSION.md`.

`docs/BENCH-REGRESSION.md`: explains when benchmark baselines may be updated. Follow it. A baseline refresh is not part of the prototype milestones.

The relevant dependencies are `hasql`, `hasql-pool`, and `hasql-transaction`. Use Mori before relying on dependency APIs:

```bash
mori registry search hasql
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
```

If a dependency API is unclear, read its source or docs from the path reported by Mori. Never search `/nix/store`.

At the end of Milestone 2, if the event-count experiment is kept, `SQL.AppendParams` must contain a strict event-count field and all four append statements must use that field instead of repeated CTE count subqueries.

At the end of Milestone 3, if the `AnyVersion` split is kept, there must be a clearly named statement for the existing-stream `AnyVersion` path and the existing upsert statement must remain available for create-or-append fallback.

At the end of Milestone 4, if the one-event statement is kept, it must be isolated enough that multi-event append behavior still uses the general path and all existing tests continue to exercise the public `appendToStream` API rather than a private shortcut.


## Revision Notes

2026-05-17: Initial plan created to evaluate EventStore-inspired append hot-path experiments against Kiroku's benchmark regression gate.

2026-05-18: Implemented and measured the event-count, AnyVersion split-path, and one-event VALUES experiments. Kept only the AnyVersion split-path change because it improved hot existing-stream writes while preserving correctness; recorded that the full benchmark gate still fails.

2026-05-18: Reverted the AnyVersion split-path source change after reviewing complexity versus measured benefit. The plan and benchmark transcripts remain as documentation.
