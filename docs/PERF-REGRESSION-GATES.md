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
| Controlled workload | `just perf-workload-gate` | In one process and PostgreSQL server, the public pipelined `appendMultiStream` path remains at least 10% faster than an explicit sequential transaction control at four and eight streams. | A candidate/control ratio exceeded `0.90`, or a real store/database error occurred. Repeat the unchanged wall-time gate three times on a quiet host; investigate before changing the workload or threshold. |
| Historical telemetry | `just perf-telemetry` | Every historical benchmark has exactly one CSV baseline row, and current absolute timings are reported against that older run. | Structural name mismatch or benchmark execution errors still fail. Timing movement is printed but does not fail this command; investigate repeated or corroborated movement. |

`just bench-regression` retains the older strict historical comparison and fails
when any compared timing is more than 10% slower than the checked-in CSV. It is
an opt-in smoke diagnostic, not part of `perf-check`: machine state, background
load, and benchmark layout can move an absolute historical comparison without a
production regression. A strict timing-only failure is actionable evidence to
investigate, not permission to refresh the baseline and not an automatic veto
when both authoritative tiers pass.

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
