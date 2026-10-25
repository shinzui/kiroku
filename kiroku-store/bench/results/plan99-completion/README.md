# Plan 99 completion evidence

The user accepted migration 0012's roughly 5–6% historical append cost and asked
for the remaining plan to be completed. The authoritative append control is now
an independent literal of accepted post-0012 SQL at git `22ac4de`, on the same
fully migrated schema as the candidate. The unchanged 0.50–1.05 bounds protect
later SQL changes. This is a declared baseline change, not a passing result for
the old migration-cost comparison. Historical SQL and evidence remain intact.
Future schema/index changes need a separate schema-aware comparison.

The completion experiment has one budget, **2026-10-25 16:26:53–17:26:53 UTC**,
including setup, builds, diagnosis, repeats and documentation. The user authorized
the active host; actual load is in `journal.jsonl`. Each log and CSV has a unique
name. Only redundant blank lines at the end of two failed command logs were trimmed; sample content is unchanged. The retained `controller.py` enforces the original deadline and refuses
overwrite. Journal records contain command, status, duration and input hashes;
production source hashes were added after the prepared-statement probe. Its
exact pre-comment production hash is in `snapshot-verification.json`.

## Changes and rejected attempts

- `focused-1` passed at the old 5% convergence target; `focused-2` failed at
  1.06x despite identical SQL. Both are retained. A 1% append target then yielded
  three focused passes, described in `focused-summary.json`.
- `full-1` failed an unconverged four-stream candidate (8.27x, 97.7% doubled
  spread). Pipeline setup is now refreshed just before that group's measurements:
  20 equal four/eight-stream iterations, vacuum/analyze and a final iteration
  each, outside timing. It uses Tasty's resource acquisition with no lazy getter
  entering STM.
- `full-pipeline-warm-1` failed the four-stream 0.90 ceiling at about 0.91x.
  Tightening only that pair's target to 1% confirmed a 0.91624x miss in
  `pipeline-precise-probe`, with 0.97% / 1.17% doubled spreads.
- The production pipeline reparsed BEGIN/COMMIT/ROLLBACK each call, unlike the
  existing transaction library. Making those statements preparable retains all
  transaction boundaries and error handling. `pipeline-prepared-probe` passed at
  0.82631x (19.42% control spread, 1.53% candidate spread); full confirmation is
  required. `transaction-correctness.log` records 18 passing existing examples,
  including atomicity, conflict rollback, duplicate-event rollback and overlapping
  concurrent calls.

The pipeline thresholds remain 0.50–0.90, the append thresholds 0.50–1.05, and
all compared arms must have doubled standard deviation at most 20% of the mean.
The tighter convergence target is not a confidence interval or a changed gate.
The eight-stream and category-read comparisons retain the existing 5% target.

The three focused append runs precede changes confined to pipeline setup and
transaction-control preparability; append setup, statement, measurement and
thresholds are unchanged. The final full runs also recheck both append arms.
Source hashes preserve this distinction rather than claiming identical whole-file
hashes for every historical run.

## Reproduction and verification

From the repository root, use the Nix environment:

```bash
nix develop --no-write-lock-file -c just perf-workload-gate
nix develop --no-write-lock-file -c just perf-check
python3 kiroku-store/bench/test-gate-spread.py
```

Each full CSV has 17 rows: the disposable cell and 16 required comparison arms.
The recipe preserves ratio failures even when spread is valid. The eight parser
and recipe tests include malformed/missing/noisy arms and historical-control
substitution. `snapshot-verification.json` verifies the accepted SQL literal
against `22ac4de` and the unchanged pre-0012 literal against the prior harness.
The historical result remains the accepted compromise recorded in
[the earlier investigation](../plan99-investigation/README.md).

## Batched validation

The subsequent `full-prepared-1` passed pipeline/read comparisons but rejected
identical append SQL at 1.06x with low reported spread (3.50 ms versus 3.71 ms).
Tightening convergence alone is therefore insufficient. The final append cells
batch 32 unchanged 40-append workloads, explicitly named `*-append-40x32`, while
the disposable cell remains `warm-append-40`. Means are per 1,280 appends; ratio
and 20% spread limits are unchanged. This reduces the relative size of tasty's
fixed 1 ms perturbation. It does not claim equal database sizes: counters printed
after `focused-batched-1` were 16,372 / 2,036 including the 20 setup iterations.
That run passed at about 0.98x. Different adaptive lengths remain a limitation;
use matched-work diagnostics for migration-cost attribution, not these gate means.

`focused-batched-1` preceded formatting of the two Haskell files; the formatter
changed layout only. Later validation uses the formatted source. Earlier
`focused-precision-*` results remain evidence for the earlier unbatched protocol,
not acceptance of the batched protocol.

Final acceptance: all three full runs pass all 17 cells and all 16 compared-arm
spread checks. The third runs through `perf-check`, with 41 structural examples
passing. `full-summary.json` independently checks every ratio/spread and verifies
identical input hashes across the three full runs.

| Run | Accepted append ratio | Four-stream pipeline ratio | Eight-stream pipeline ratio | Maximum doubled spread |
| --- | ---: | ---: | ---: | ---: |
| full-batched-1 | 1.0046x | 0.8637x | 0.8663x | 9.63% |
| full-batched-2 | 0.9895x | 0.8645x | 0.8683x | 9.55% |
| full-batched-3 | 0.9577x | 0.8561x | 0.8536x | 9.06% |

All eight CSV/parser recipe tests and 18 transaction/concurrency examples pass;
strict ADR/friction validation passes. FRIC-1 remains resolved and FRIC-2 accepted.
The earlier cost and failed gate results retain their original status. The
accepted historical migration cost and current SQL-regression validation answer
different questions. Matched-work diagnostics remain necessary for attribution.
Completion recorded at 2026-10-25T17:22:22.445359+00:00, inside the original one-hour budget.
