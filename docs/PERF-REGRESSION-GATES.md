# Performance Regression Gates

Kiroku separates performance evidence into three tiers because one signal cannot
reliably answer every question. Run the authoritative aggregate gate from the
repository root:

```bash
just perf-check
```

This runs the deterministic structural checks followed by the controlled
same-process workload comparison. It deliberately excludes historical timing
telemetry.

## The three tiers

| Tier | Command | What it proves | What a failure means |
| --- | --- | --- | --- |
| Structural | `just perf-structure` | Protected production SQL still selects the intended indexes; dead-letter reads do not add a sort; notification cardinality and no-database-work paths remain exact. | A deterministic invariant changed. Inspect the named Hspec failure and its JSON plan or checkout count before changing code or migrations. |
| Controlled workload | `just perf-workload-gate` | In one process and PostgreSQL server, pipelined `appendMultiStream` stays within `0.50–0.90x` of a sequential transaction control at four and eight streams; migration 0012's append path stays within `0.50–1.05x` of the pre-0012 control; category reads meet their existing `1.05x` or `0.20x` ceilings. Every compared arm has doubled standard deviation at most 20% of its mean. | A ratio is outside its bounds, an arm is too noisy, a CSV result is missing/invalid, or a store/database error occurred. The spread failure names the cell, mean, doubled deviation and 20% bound. Repeat the unchanged wall-time gate three times on a quiet host; investigate before changing the workload or threshold. |
| Historical telemetry | `just perf-telemetry` | Every historical benchmark has exactly one CSV baseline row, and current absolute timings are reported against that older run. | Structural name mismatch or benchmark execution errors still fail. Timing movement is printed but does not fail this command; investigate repeated or corroborated movement. |

`just bench-regression` retains the older strict historical comparison and fails
when any compared timing is more than 10% slower than the checked-in CSV. It is
an opt-in smoke diagnostic, not part of `perf-check`: machine state, background
load, and benchmark layout can move an absolute historical comparison without a
production regression. A strict timing-only failure is actionable evidence to
investigate, not permission to refresh the baseline and not an automatic veto
when both authoritative tiers pass.

The workload recipe saves tasty-bench's CSV to
`kiroku-store/bench/results/workload-gate.csv` and checks it with
`kiroku-store/bench/check-gate-spread.sh`, using the `Name`, `Mean (ps)` and
`2*Stdev (ps)` columns. It requires all 16 comparison arms, so a partial run or
failed cell cannot silently pass. The recipe checks spread even when the benchmark
comparison fails and retains the benchmark's nonzero exit status. Run these commands
inside the repository development environment, for example
`nix develop --no-write-lock-file -c just perf-check`.

Before measurement, all three append stores run 20 workload iterations each (400
fresh streams and 800 events), then the harness checkpoints PostgreSQL and runs
`VACUUM (ANALYZE)` on the six databases. This primes growing tables and refreshes
statistics before prepared statements are measured. No timed workload or frozen
control SQL changes. The first cell, `append-category-column.warm-append-40`, is
disposable: it absorbs post-setup effects using its own third append store. Its spread
is exempt from the 20% check. A warm-up does not establish measurement quality;
both control and candidate must pass the check themselves. The append ratios also
have a `0.50x` plausibility floor, since a slow control can otherwise create a
vacuous pass. Category reads retain a zero floor because their large speedups are
expected. The 20% bound is a convergence safeguard, not a confidence interval or
proof that a small write-cost difference has been resolved. The parser's failure
cases can be checked without PostgreSQL with
`python3 kiroku-store/bench/test-gate-spread.py`.

## Diagnosing a controlled append result

For a suspicious append ratio, use the optional fixed-work diagnostic from the
repository root:

```bash
nix develop --no-write-lock-file -c env KIROKU_GATE_DIAGNOSE=paired \
  cabal bench kiroku-store:kiroku-store-bench-workload-gate
```

This runs 12 pairs of 32 workload iterations per arm, alternating order and
collecting garbage before each timed batch as tasty-bench does. It checks equal
work counts before/after each pair and verifies final database counts. Modes
`paired-aa`, `paired-column`, `paired-index-check` and `explain` provide an
identical-code/schema comparison, component comparisons and exact-statement plans.
Benchmark-only `paired-combined-links` and `paired-no-publisher` modes retain
negative/inconclusive append-speed probes. The latter deliberately stops an idle
publisher in a subscriber-free fixture and is an upper bound, never a valid
production subscriber configuration. `explain-combined-links` enables instrumented
plans for the SQL prototype. See the [probe record](../kiroku-store/bench/results/plan99-append-probe/README.md).
Use fresh output labels and retain every sample. A zero diagnostic exit status
means completion and count validation, **not** performance acceptance. Unset
`KIROKU_GATE_DIAGNOSE` when running the authoritative tasty gate.

The diagnostic is useful because independent adaptive cells can grow their stores
to different sizes, and tasty's displayed spread is not a confidence interval for
the ratio. The [Plan 99 investigation](../kiroku-store/bench/results/plan99-investigation/README.md)
retains both clean and noisy identical-code controls and full-migration estimates
of +4.89% and +6.44%. Those results support additional write cost while leaving the
exact 5% boundary unresolved. Do not choose a favorable repeat as acceptance.

## Baseline coverage and updates

Run `just bench-baseline-check` after adding, removing, or renaming a historical
benchmark. The command builds the suite, compares its sorted `All.*` leaf names
with the first column of `kiroku-store/bench/results/baseline.csv`, and prints a
unified diff for any missing or extra name. Benchmark names must not contain
commas; the checker fails loudly rather than pretending to parse such a row.

Only run `just bench-baseline` after the reason for changing the historical
reference is written down. Acceptable reasons are a reproducible improvement,
an investigated trade-off, or an intentional benchmark-set change. Do not
refresh it to erase a noisy failure. Review the complete CSV diff, rerun
`just bench-baseline-check`, and record the decision in the active ExecPlan or
the relevant durable performance record.

For details of the CSV workflow, see
[`docs/BENCH-REGRESSION.md`](BENCH-REGRESSION.md). For the evidence discipline
required of future optimization work, see
[`docs/PERF-METHODOLOGY.md`](PERF-METHODOLOGY.md).
