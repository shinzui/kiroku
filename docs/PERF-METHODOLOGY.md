# Append Performance Methodology

This file states the discipline future Kiroku append-performance plans must
follow. It exists so the next contributor proposing an optimization plan does
not repeat the cycle that plans 21–24 fell into: benchmark-driven optimization
without profiling, without an expected-impact model, and without a checked-in
experiment ledger. Plans 21–24 each formed a hypothesis from reading the code,
built a candidate, ran `tasty-bench`, and made a keep-or-revert decision from
eyeball percent deltas. Several arrived at conclusions stronger than the
harness could support, and the same shortlist of "remaining candidates" kept
being re-proposed because no canonical record existed of what had already been
tried — until plan 22's `stream_events_notify` and `streams.category` informal
trials were nearly re-proposed by plan 24.

The discipline below is what subsequent append-perf plans must follow. It is
short on purpose; the goal is friction sufficient to stop the cycle, not
process for its own sake.


## The four steps

1. **Profile first.** Before proposing an optimization plan, run the
   Haskell-side profiling harness and the PostgreSQL-side profiling harness
   to identify *where time actually goes* in the append path. The harnesses
   are documented in
   [`docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`](plans/25-haskell-side-append-profiling-with-ghc-prof.md)
   and
   [`docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`](plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md)
   respectively. The Haskell-side harness produces a GHC `.prof` whose
   cost-centre rows attribute wall time across `appendToStream`, `prepareEvents`,
   `buildAppendParams`, `appendDispatchTx`, `appendParamsEncoder`, and the
   Effectful interpreter wrapping. The PostgreSQL-side harness runs the
   production `AnyVersion` CTE under `EXPLAIN (ANALYZE, BUFFERS, TIMING)` and
   captures `auto_explain` output, attributing time across the six CTEs
   (`new_events`, `stream_upsert`, `inserted_events`, `source_links`,
   `all_update`, `all_links`).

2. **Check the ledger.** Open
   [`docs/perf-experiment-log.md`](perf-experiment-log.md) and read every row
   whose **Variant** or **Hypothesis** touches the cost centre or CTE node the
   profile pointed at. If the candidate optimization is already represented as
   a `reverted` or `not-implemented` row, do not re-propose it without
   explicitly justifying in the new plan's Decision Log why this time will be
   different. A valid justification looks like: "the EP-1 profile shows this
   is now N % of append time, vs. the qualitative `did not move the needle`
   finding in plan 22; the numeric evidence changes the cost-benefit." If no
   such justification exists, pick a different candidate.

3. **State an expected-impact hypothesis grounded in the profile.** The new
   plan's Purpose / Big Picture must contain a sentence of the form:

   > The profile shows X is N % of append time; this change should reduce X
   > to roughly Y % of append time, saving Z µs per call.

   Without that sentence, the plan is not ready to be implemented. The point
   is to force the author to predict the result before measuring it, so that
   the post-implementation measurement is a falsifiable check, not a
   sense-making exercise.

4. **Re-profile after.** Once the experiment is implemented (or completed as
   a benchmark-only proof), re-run the same harness commands and compare. Add
   a new row to the ledger whose **Outcome** records whether the prediction
   held, and whose **Lesson** records the delta between expected and observed.
   A row whose **Lesson** reads "expected -20 %, observed -2 %" is a useful
   warning to future plans *even if the change was kept*: it tells the next
   contributor that this region of the code is harder to optimize than it
   looks. The ledger is append-only by convention; revisions to a prior row's
   interpretation are made by appending a new row that cross-references the
   earlier date.


## Where the harnesses live

- **Haskell-side profiling (GHC `-prof`, `.prof` cost-centre breakdown).**
  Detailed plan and findings:
  [`docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`](plans/25-haskell-side-append-profiling-with-ghc-prof.md).
  Reference profile checked in at
  [`docs/bench/append-hot-path/single-event-anyversion.prof`](bench/append-hot-path/single-event-anyversion.prof).
  Reproduction:

  ```bash
  cd <repo-root>
  cabal build --enable-profiling kiroku-store:kiroku-store-bench
  BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
  rm -f kiroku-store-bench.prof
  "$BENCH" +RTS -p -RTS \
    --pattern '$0 == "All.append.single-event.AnyVersion (new stream)"' \
    --stdev 100
  ```

  Note: there is no `--` between `-RTS` and the bench's own arguments, and
  the pattern includes the implicit `All.` prefix that `tasty-bench`'s
  `defaultMain` adds to the test tree. The first profiled build rebuilds
  ~50 transitive dependencies in the profiling way; subsequent builds are
  fast. The bench's unconditional pre-`defaultMain` setup (100K category
  events, B9 pool saturation) accounts for ~10 s of wall time per run; this
  is documented in the EP-1 plan's Surprises & Discoveries.

- **PostgreSQL-side profiling (`EXPLAIN (ANALYZE, BUFFERS, TIMING)` and
  `auto_explain`).** Detailed plan and findings:
  [`docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`](plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md).
  Reference artefacts and per-file inventory under
  [`kiroku-store/bench/explain-results/`](../kiroku-store/bench/explain-results/)
  (`anyversion-singleton.txt`, `anyversion-singleton.json`,
  `auto-explain.csv`, `auto-explain.log`).
  Reproduction:

  ```bash
  cd <repo-root>
  cabal build kiroku-store:kiroku-store-bench-explain
  cabal bench kiroku-store-bench-explain                                       # M1: EXPLAIN ANALYZE
  cabal bench kiroku-store-bench-explain --benchmark-options="--auto-explain"  # M2: auto_explain
  ```

  Caveats discovered while landing EP-2:
  `ephemeral-pg` discards postgres's stderr unconditionally, so the
  harness uses PostgreSQL's `logging_collector` + `csvlog` rather than
  the originally documented `Config.stderr` override; and PostgreSQL
  18.3 needs `log_min_messages = 'log'` for auto_explain output to
  reach the csvlog. Both are baked into the harness; details and a
  full debrief are in the EP-2 plan's Surprises & Discoveries.


## Where the existing process docs live

The methodology above slots into the project's existing benchmark workflow; it
does not replace it. The relevant existing docs are:

- [`docs/BENCH-REGRESSION.md`](BENCH-REGRESSION.md) — the regression-gate
  workflow run as `just bench-regression`, against the baseline at
  `kiroku-store/bench/results/baseline.csv`. Use this to confirm a kept change
  did not regress unrelated cells.
- [`docs/BENCH-GATE3.md`](BENCH-GATE3.md) — the M4 public-API benchmark gate
  (2026-03-23), which is the baseline append-via-`withStore` measurement.
- [`docs/BENCH-HASKELL-APPEND.md`](BENCH-HASKELL-APPEND.md) — the M2
  Haskell-append benchmark gate (2026-03-22), which compares
  `appendToStream` against the pgbench SQL baseline.
- [`docs/BENCH-SQL-BASELINE.md`](BENCH-SQL-BASELINE.md) — the M1 pgbench SQL
  baseline (2026-03-20) used by `docs/BENCH-HASKELL-APPEND.md` as its
  comparison floor.


## Where the ledger lives

[`docs/perf-experiment-log.md`](perf-experiment-log.md). Append-only by
convention; the file's own header describes the row schema and the rule for
revising prior interpretations.
