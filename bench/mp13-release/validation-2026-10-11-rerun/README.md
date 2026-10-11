# MP13 controlled comparison — 2026-10-11 rerun

The user authorized this fresh run after the earlier setup attempt failed to
produce a comparison. The bounded queue completed; the lease released and machines stopped. Temporary-database deletion remains pending. The results below do not clear release. This directory preserves the earlier run's
original runtime binaries; it does not include later stream-head work.

## Results and release decision

**Do not release under the unchanged acceptance policy.** Both comparisons are complete; neither passes every append metric. No native benchmark-grade certificate is claimed.

| Inspection | Metric | Candidate change | 95% interval | Metric verdict |
|---|---|---:|---:|---|
| disabled | latency.p50 | +1.512% | [-0.907%, +3.989%] | inconclusive |
| disabled | latency.p95 | +1.767% | [-1.020%, +4.633%] | inconclusive |
| disabled | latency.p99 | +4.743% | [-36.158%, +71.846%] | inconclusive |
| disabled | throughput | -1.544% | [-4.090%, +1.069%] | inconclusive |
| active | latency.p50 | +0.898% | [-1.251%, +3.094%] | inconclusive |
| active | latency.p95 | -0.015% | [-3.647%, +3.754%] | inconclusive |
| active | latency.p99 | -14.035% | [-40.890%, +25.023%] | inconclusive |
| active | throughput | -0.370% | [-3.371%, +2.724%] | inconclusive |

Changes are candidate relative to released control. Lower latency is better; higher throughput is better. The table converts the adverse throughput ratio back to throughput change. Every point and interval comes from all five predefined pairs; the proof is excluded.

All **20 measured trials / 10 pairs**, plus the readiness proof, verified. They contain **660,159 measured appends**. Every active trial and the proof passed the exact ordered-delivery/name oracle. Across all 21 runs, **368 sealed artifacts** independently match their byte counts and hashes. Checkpoint counters/LSNs remain unchanged throughout each entry envelope. Peak observed driver CPU is 17.00%; maximum CPU steal is 0.00%.

For disabled inspection, mean WAL per measured append is 2049.56 bytes in control and 2108.00 in candidate (+2.852%). This is diagnostic write-cost evidence, without a separate confidence claim.
For active inspection, mean WAL per measured append is 2051.44 bytes in control and 2120.64 in candidate (+3.373%). This is diagnostic write-cost evidence, without a separate confidence claim.

## Completion and cleanup

The controller finished at **15:42:46 UTC**, 56.35 minutes after the original clock began. Temporary-database removal was not completed after an SSH wrapper timeout. The owned lease `01a12b74-4dab-7661-8bd3-6711314258f8` released, and all four cell machines reached TERMINATED. See `cell/journal.json`, `cell/lease-release.log`, and `cell/power-after.json`. No remote work or owned lease remains. The ALTER DATABASE command succeeded, but inherited SSH output handles held the local command open until its 90-second timeout; DROP DATABASE was not reached. The bounded recovery admission refused to restart a machine because fewer than 150 seconds remained. The small diagnostic database remains on the stopped PostgreSQL disk and must be removed under the next owned lease. See `cell/cleanup-recovery/journal.json`. No sample was retried, no gate changed, and no package was published.

The remaining acceptance work is specific: use the native benchmark runner for actual phase/per-operation timing and grade evidence, and address the unresolved interval widths before treating this cohort as performance-accepted. A fresh remote experiment requires a separately declared budget; this run does not restart its clock or silently add trials.

## Fixed inputs and protocol

- Candidate: `109d58f57dbd5757ad55792474d046a37cc2e87d`.
- Released control: `364ffa82136fcfc83d39ead1234abffaf500844b`.
- One dedicated PostgreSQL 18 cell and one continuously held lease for the proof
  and both comparisons. Each trial gets a fresh database from an owned template.
- One active-observer readiness proof, excluded from comparison; then five
  interleaved pairs with inspection disabled and five with inspection active.
- Each trial has 10 seconds of warmup and 30 seconds of append measurement.
- The unchanged policy is `bench/mp12-cell/policy.json`: five pairs, 95%
  intervals, maximum relative interval width 6%, and zero allowed slowdown.
  No failed or adverse measured trial is replaced.
- The single hour begins at **14:46:26 UTC** and ends at **15:46:26 UTC**,
  including wrapper preparation, startup, readiness, reset, fetching, validation,
  and cleanup. `budget.json` retains that clock. The original 100-second trial
  estimate was optimistic; observed trials take approximately 132 seconds end
  to end. Progress forecasts include that measured overhead and cleanup.

The wrapper adds a once-per-second PostgreSQL checkpoint snapshot around the
unchanged workload entry point. A read-only security-definer function lives only
in the owned template and its disposable clones. The benchmark role remains
unprivileged. Every admitted trial must have samples enclosing the entire entry,
stable checkpoint counters/LSN/reset time, and an idle checkpointer at each sample.
The independent assessor repeats these checks and verifies every manifest byte
count and SHA-256, the ordered-delivery oracle, cell health, consistent payload,
database settings, host images, agent version and system closures.

`protocol.json`, `payload.json` and `execution-sources.json` identify the exact
inputs. `execution-sources.tar.gz` preserves the source bytes used at execution,
before repository formatting. The original runtime source archive and original
payload descriptor remain in `../validation-2026-10-11/`.

## Interpretation

`ComparePairs.hs` calls the actual `compareMetricPairs` implementation from
`mori://shinzui/keiro-runtime-kenshou` using the unchanged policy. Its source and
binary identity are in `comparator-provenance.json`; positive and adverse
constant-effect self-tests are retained. The owner implementation is
`kenshou-measure/src/Kenshou/Measure/Compare.hs` relative to that canonical
project URI (artifact-level URI pending).

These are independently verified opaque-probe results, **not a native Kenshou
run-directory benchmark-grade certificate**. The probe does not emit the native
per-operation monotonic timing frames. Checkpoint evidence and sealed cell health
do not substitute for that certificate. Numeric intervals can identify a
regression; numeric passes alone cannot close the plan's formal grade requirement.
No timestamp or native grade artifact is synthesized from duration estimates.

SQL deltas and WAL bytes per measured append are diagnostic. Checkpoint sampling
also appears in statement statistics; its work is identical in both arms. Tail
delivery/name correctness is verified separately from append timing. The proof
sample contributes no pair or timing metric to either comparison.

## Reproduce the assessment

Restore each trial archive from the repository root, retaining the directory
structure. `archive-index.json` records archive hashes and manifest identities.
For example:

```sh
tar -xzf bench/mp13-release/validation-2026-10-11-rerun/cell/proof/fetched.tar.gz \
  -C bench/mp13-release/validation-2026-10-11-rerun/cell/proof
```

Build `bench/mp13-release/ComparePairs.hs` against the recorded owner revision's
`kenshou-measure` library and its matching Aeson package. Then run:

```sh
python3 bench/mp13-release/assess.py \
  --root bench/mp13-release/validation-2026-10-11-rerun \
  --comparator /path/to/compare-pairs
```

The assessor refuses changed manifests, changed trial data, delivery failures,
checkpoint activity, changed inputs, or overlapping/reordered pairs. Incomplete
cases remain incomplete and never receive a five-pair verdict. Derived results
live in `assessment/`; originals remain under `cell/`.

Local validation is retained in `controller-tests.log` (seven tests),
`validation-tests.log` (two tests including twelve malformed-evidence cases), and
the comparator self-test JSON files. Failed preparation/build attempts are kept
with their logs; they are not measured samples.

## Controller correction after execution

The controller now redirects command output directly to retained files and waits for the wrapper process, avoiding an inherited-pipe EOF wait after that process exits. The additional fault test recreates an exited parent with a child retaining output handles; all eight controller tests pass (`controller-tests-after-cleanup-fix.log`). This local correction was made after remote execution and does not alter any trial or retrospectively claim database deletion. The executed controller remains preserved in `execution-sources.tar.gz`.
