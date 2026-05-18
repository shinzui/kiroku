# Benchmark Regression Workflow

> See [`docs/perf-experiment-log.md`](perf-experiment-log.md) for the history
> of append-performance experiments and
> [`docs/PERF-METHODOLOGY.md`](PERF-METHODOLOGY.md) for the discipline future
> optimization plans must follow.

## What this is

The `kiroku-store-bench` suite (`kiroku-store/bench/Main.hs`) carries an
on-disk baseline (`kiroku-store/bench/results/baseline.csv`) captured by
`tasty-bench`'s CSV mode. Subsequent runs compare against the baseline
and report each benchmark as OK or WARN. CI can be wired to fail when
any benchmark regresses past a configurable threshold.

This protects the Gate 3 throughput numbers (recorded in
`docs/BENCH-GATE3.md`) from silent regressions across refactors and
dependency bumps. It also protects the focused reliability-and-scale
audit gates for hot `invoice-payment` writes, `appendMultiStream`,
subscription catch-up, and high-cursor category reads.

## Running

The `bench-regression` Justfile target runs the suite, compares to
`baseline.csv`, and fails if any benchmark is more than 10% slower:

    just bench-regression

To raise or lower the threshold for a one-off run:

    just bench-regression-threshold 5      # 5% allowed slowdown

To rerun only a specific benchmark:

    just bench-regression-pattern append.batch-100

To capture a fresh baseline (overwrites the on-disk file — see *When to
update*):

    just bench-baseline

The capture target writes `kiroku-store/bench/results/baseline.csv` from
a clean run. Commit the change with a Decision Log entry in the relevant
ExecPlan or in `docs/BENCH-GATE3.md`.

Useful focused patterns include:

    just bench-regression-pattern category
    just bench-regression-pattern reliability-audit

## When to update the baseline

Update the baseline when *and only when* either:

* A measurable regression has been investigated, root-caused, and
  accepted as a deliberate trade-off (cite the trade-off in the commit
  message). Example: a multi-tenant feature adds 5% per-append overhead
  in exchange for tenant isolation.
* A measurable improvement has been investigated and is reproducible
  on more than one machine. Example: a CTE rewrite that reliably cuts
  append latency by 15%.

Do *not* update the baseline because:

* "CI is flaky" — instead, raise `--stdev` (default 5%) for noisier
  benchmarks, or rerun on a quiet host.
* "The benchmark is too slow now" — investigate the root cause; an
  unexplained slowdown is exactly what the workflow is meant to catch.
* "I bumped a dependency" — measure first; if the bump caused a
  regression, decide whether to keep it.

Every baseline update should be accompanied by a Decision Log entry
naming the change and the magnitude (e.g., "append.batch-100 +6%
acceptable: tenant-id column added per F4").

## How `tasty-bench` formats the CSV

The baseline file is `tasty-bench`'s standard CSV: header line
`Name,Mean (ps),2*Stdev (ps)` followed by one row per benchmark.
`tasty-bench` parses both the on-disk baseline and the current run, then
prints `OK` or `WARN` per benchmark with the percent change.

## When to rerun the baseline

Rerun the baseline when adding or removing benchmarks (the comparison
is keyed by benchmark name; a missing baseline entry produces a "not
found" message and a new entry is silently ignored).

## Where the legacy ad-hoc B9 measurement lives

The original B9 wall-clock pool-saturation measurement is still
present in `kiroku-store/bench/Main.hs` (printed before the
`defaultMain` invocation) for historical comparability with the
baseline runs in `docs/BENCH-GATE3.md`. The structured
`concurrent.{8 writers x 10 appends, 32 writers x 10 appends}`
benchmarks added under EP-6 F19 are the entries that participate in
the baseline-regression workflow.

## Focused reliability-and-scale audit gates

The May 2026 reliability-and-scale audit added four benchmark guards:
`category.exhausted-category`, `reliability-audit.hot invoice-payment 10
AnyVersion appends`, `reliability-audit.appendMultiStream 3 existing
streams`, and `reliability-audit.subscription category catch-up 100
events`. The baseline was refreshed after accepting the category read
SQL change from a direct `$all` join to a LATERAL partial-index plan.
That change preserves the normal 100-event category page around 1ms and
adds a guard for the high-cursor case that should stay in the tens of
microseconds on the benchmark dataset.
