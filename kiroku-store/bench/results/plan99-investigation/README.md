# Plan 99 follow-up investigation — 2026-10-25

The evidence supports a real append cost around **5–6%** for migration 0012 in
this workload, alongside substantial harness noise. It does **not** establish
that the true cost exceeds exactly 5%, or establish a universal consumer cost.
The original adverse sample remains in `../plan99/`; no threshold or production
SQL changed, and no sample was dropped.

The user authorized this investigation after the original adverse stop and later
asked to try again. One 60-minute budget began at 13:56:36 UTC. Timing finished
at 14:12:10 UTC, including the requested repeat, within about 16 minutes of
setup, builds and investigation. The final documentation/checks followed under
the same budget. Host load was retained in `journal.jsonl`; the earlier user
authorization to continue on the active machine remained in force.

## Reproducing the original observation

Three unchanged focused tasty-bench runs, preserving `--stdev 5` and the 1.05
ceiling, produced:

| Run | Candidate/control | Control / candidate doubled spread | Interpretation |
| --- | --- | --- | --- |
| `unchanged-1` | 0.7843x | 68.69% / 4.12% | Invalid control; the CSV spread safeguard rejects this despite tasty's ratio pass. |
| `unchanged-2` | 1.0554x | 6.86% / 7.12% | Converged, ratio failed. |
| `unchanged-3` | 1.0567x | 3.05% / 6.39% | Converged, ratio failed. |

The earlier setup repair is not sufficient to eliminate every startup effect.
Two usable repeats support the direction of the original 1.0585x result, but
their spreads cannot resolve a sharp boundary at 1.05.

## Equal-work and identical-code comparisons

Each diagnostic invocation uses fresh ephemeral databases and the existing 20
setup iterations per append store, checkpoint and vacuum/analyze. It then runs
12 consecutive pairs of 32 workload iterations per arm, alternating which arm
runs first. Each iteration remains 20 fresh-stream and 20 hot-stream appends.
Before and after every pair, iteration counters must agree. Both final databases
must contain 8,082 streams, 16,160 events, 32,320 junction rows, hot-stream version
8,080 and global position 16,160. Every invocation verified these counts.

The final protocol collects garbage **before** each timed batch, matching
tasty-bench. It retains ordinary notifier/publisher behavior. The first two
exploratory diagnostic invocations omitted this collection; they are retained
as `paired-aa` and `paired`, not silently substituted with the later results.
Their ratios were 1.0921x and 1.0856x, with large spikes even for identical SQL.
This motivated matching the library's measurement practice. It does not prove
that GC caused the original gate's startup defect: that gate already collected
before batches, and the later identical-code repeat still had a host/runtime
spike.

| Comparison | Geometric mean ratio | Descriptive interval | First-control / first-candidate ratio |
| --- | --- | --- | --- |
| Identical old SQL/schema, `paired-aa-gc` | **0.9986x** | 0.9824–1.0150x | 1.0086 / 0.9886x |
| Full migration, `paired-gc` | **1.0489x** | 1.0337–1.0644x | 1.0479 / 1.0500x |
| Column/statement only, `paired-column-gc` | **1.0437x** | 1.0246–1.0632x | 1.0372 / 1.0503x |
| Index and CHECK only, `paired-index-check-gc` | **1.0029x** | 0.9892–1.0167x | 1.0053 / 1.0004x |
| Requested repeat: identical SQL/schema | **0.9692x** | 0.9006–1.0431x | 0.9969 / 0.9423x |
| Requested repeat: full migration | **1.0644x** | 1.0456–1.0835x | 1.0685 / 1.0602x |

Intervals are mean log-ratio ± t(11) × its standard error, exponentiated.
They describe these 12 consecutive pairs; possible autocorrelation and the
single host preclude treating them as calibrated population confidence limits
or promotion gates. The repeat's identical-code control includes a 160.574 ms
control batch against a 109.790 ms candidate batch; that spike is retained.
No clipping, favorable retry, pooled estimate or threshold adjustment was used.

Full-migration estimates were +4.89% and +6.44%, with similar results in both
orders. In the latter run the candidate was slower in all 12 pairs. The first
run's mean difference was 0.174 ms per 40 appends (4.35 µs per event), and the
repeat's was 0.227 ms (5.67 µs per event). The identical-code checks show why a
single near-threshold ratio is insufficient, even when the direction of the
migration cost reproduces.

The component comparison attributes most of the measured effect to carrying
the category through the SQL and writing its text value: about +4.4% even after
removing the new index and CHECK from both stores. Adding the index and CHECK
back with identical production SQL measured about +0.3%, unresolved from noise.
These comparisons do not isolate `RETURNING category` from tuple construction,
nor precisely add up across separate processes. They support an attribution,
not exact independent component costs. The control retains the nullable category
column, as the existing gate always did; this is a statement/index counterfactual
on the current schema rather than a complete old binary/schema reproduction.

## Plans and physical evidence

The `explain` invocation wraps `Statement.toSql` of the actual control and
production statements in `EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING OFF, FORMAT JSON)`.
It samples a fresh append and a hot append after the same setup, outside paired
timing. The four extracted `*-plan.json` files and `plan-summary.json` retain
the results; the full console output is archived in `explain.log.gz`. These custom plans are structural evidence, not a latency estimate
or proof about every cached generic plan.

The fresh and hot plan node/operation/relation/index sequences match between
control and candidate; neither comparison introduces another scan/join. Physical
`$all` tuples are **72 bytes** in the control and **79 bytes** in the candidate
for the benchmark's six-character `append` category; home rows remain 72 bytes.
The `all_links` insert produces **one extra WAL record and 87 extra WAL bytes**
in both sampled cases (335→422 bytes fresh, 327→414 hot). These observations
confirm additional write work; they do not alone assign its elapsed-time cost.
Do not interpret the top plan node's WAL count as the whole statement's total:
data-modifying CTEs also report their own work.

## Commands and retained evidence

Run from the repository root, selecting one diagnostic mode per invocation:

```bash
nix develop --no-write-lock-file -c env KIROKU_GATE_DIAGNOSE=paired \
  cabal bench kiroku-store:kiroku-store-bench-workload-gate
```

Modes are `paired` (old vs full production), `paired-aa` (identical old SQL and
schema), `paired-column` (old vs production SQL with index/CHECK absent in both),
`paired-index-check` (production SQL in both, index/CHECK only in candidate), and
`explain`. A diagnostic exit code of zero proves completion and count validation,
**not** a performance gate pass. With the variable unset, the original tasty
gate and its bounds remain in force. New runs must use new evidence labels.

`journal.jsonl` records exact commands, loads, times and exit statuses. Each
paired log has a corresponding CSV and summary JSON. Recompute summaries with:

```bash
python3 kiroku-store/bench/results/plan99-investigation/summarize.py \
  paired-aa paired paired-aa-gc paired-gc paired-column-gc \
  paired-index-check-gc paired-aa-gc-repeat paired-gc-repeat
```

The benchmark-library behavior was checked in the registered source
`mori://Bodigrim/tasty-bench` (`src/Test/Tasty/Bench.hs`, file-level URI pending).
`measureUntil` keeps only the latest n/2n batches for its estimate and uses a
1 ms timing perturbation for deviation. Its displayed spread is not the
uncertainty of the candidate/control ratio, and independent convergence can
give growing arms different work counts. The diagnostic addresses those risks;
it does not replace the authoritative gate or erase its adverse findings.
