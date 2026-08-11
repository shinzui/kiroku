# Benchmark Regression Workflow

> See [`docs/perf-experiment-log.md`](perf-experiment-log.md) for the history
> of append-performance experiments and
> [`docs/PERF-METHODOLOGY.md`](PERF-METHODOLOGY.md) for the discipline future
> optimization plans must follow. The contributor-facing map of authoritative
> gates versus telemetry is
> [`docs/PERF-REGRESSION-GATES.md`](PERF-REGRESSION-GATES.md).

## What this is

The `kiroku-store-bench` suite (`kiroku-store/bench/Main.hs`) carries an
on-disk baseline (`kiroku-store/bench/results/baseline.csv`) captured by
`tasty-bench`'s CSV mode. Subsequent runs can report each benchmark against
that historical reference without failing on timing movement, or opt into the
older strict percentage check. The CSV is historical telemetry; Kiroku's
authoritative promotion gate is `just perf-check`, which combines deterministic
structure with a same-process control/candidate workload.

This protects the Gate 3 throughput numbers (recorded in
`docs/BENCH-GATE3.md`) from silent regressions across refactors and
dependency bumps. It also protects the focused reliability-and-scale
audit gates for hot `invoice-payment` writes, `appendMultiStream`,
subscription catch-up, and high-cursor category reads.

## Running historical comparisons

The default historical command reports timing movement without turning a noisy
percentage into a failing gate:

```bash
just perf-telemetry
```

It still fails if baseline names do not match, the benchmark cannot start, or
the workload itself errors. Every historical comparison begins with
`just bench-baseline-check`, which requires all 25 current leaves to have
exactly one baseline row.

The retained opt-in strict command runs the same suite and fails if any compared
benchmark is more than 10% slower:

```bash
just bench-regression
```

A timing-only failure here is a smoke signal. Repeat it on a quiet host and
compare the affected behavior with `just perf-structure` and
`just perf-workload-gate`; do not refresh the CSV solely to make it green.

To raise or lower the threshold for a one-off run:

```bash
just bench-regression-threshold 5      # 5% allowed slowdown
```

To rerun only a specific benchmark:

```bash
just bench-regression-pattern append.batch-100
```

To capture a fresh baseline (overwrites the on-disk file — see *When to
update*):

```bash
just bench-baseline
just bench-baseline-check
```

The capture target writes `kiroku-store/bench/results/baseline.csv` from
a clean run. Commit the change with a Decision Log entry in the relevant
ExecPlan or in `docs/BENCH-GATE3.md`.

Useful focused patterns include:

```bash
just bench-regression-pattern category
just bench-regression-pattern reliability-audit
just bench-regression-pattern subscription-checkpoint-inventory
```

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

## Exact name coverage

`tasty-bench` itself does not fail a current benchmark merely because its name
is absent from the baseline. `just bench-baseline-check` closes that gap by
comparing the complete sorted name multisets and printing a unified diff. Run it
after adding, removing, or renaming a benchmark and before reviewing timing.

Historical benchmark names must not contain commas. The checker intentionally
rejects such names instead of implementing a partial CSV parser. When a
benchmark-set change is intentional, capture and review a complete baseline,
then rerun the exact coverage check; do not synthesize timings for a new leaf.

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

The durable checkpoint inventory adds two public-effect cases under
`subscription-checkpoint-inventory`: 100 persisted rows (representative) and
10,000 rows (stress). Each uses its own migrated store, seeds outside the timed
action, and forces the captured store position plus every returned row so the
measurement includes query execution, transfer, decode, invariant validation,
and materialization.
