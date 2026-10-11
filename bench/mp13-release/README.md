# MP13 inspection validation

The v2 probe validates ordered delivery and exact resolved stream names while
four writers append to both new and reused streams. The HTTP/WebSocket observer
runs in a child process, so its retained samples do not share the server heap.
Both original control and candidate use the same observer bookkeeping and payload.
The validator rejects historical v1 set-cardinality evidence.

The fixture has 10,000 catalog streams, 6,000 dead letters across three members,
100 subscription checkpoints, 512-byte event bodies, and more than 4,096 distinct
source streams. Active inspection polls the same four routes once per second and
subscribes to the live event tail. Control routes return 404; candidate routes
return 200. Every received position must advance exactly once, and candidate
names must match the appended source. Delivery includes warmup; append latency
samples cover only the measured phase. WAL and SQL snapshots surround that phase.
SQL diagnostics are optional locally and required on the remote cell.

## Checks

```bash
python3 bench/mp13-release/test-validation.py
python3 bench/mp13-release/test-controller.py
just perf-structure
```

Build `inspection-probe` against each runtime cohort with the same Cabal project
settings, then run its `self-test`. `run.py` is a local diagnostic controller and
accepts an absolute original experiment deadline. Its timings cannot establish
release acceptance on a busy workstation.

`run-cell.py` uses the protocol owned by
[mori://shinzui/load-testing-infra](mori://shinzui/load-testing-infra), with
`docs/cells/protocol.md` and `scripts/cell/` as project-relative locations
(artifact-level URIs pending). It requires an existing budget JSON containing
`started_epoch` and `budget_seconds`, including all earlier setup time. Use the
owner's cellctl, project environment and IAP SSH setup. The controller records
phase, power state and verified counts, verifies sealed artifacts, releases its
lease and shuts down its cell. It never shuts down a cell after failed acquisition.
A failed setup may resume its journal with `--resume`; submitted trials must be
recovered by fetching/verifying their original run ID, never replaced with a retry.

The cell's benchmark role stays unprivileged. Observer trials use a unique,
lease-owned template with `pg_stat_statements` installed by the PostgreSQL owner;
cleanup removes that template before releasing the lease. `--gate` runs the
unchanged `kiroku-store/bench/RegressionGate.hs`, with only ephemeral database
provisioning replaced by fresh databases on the dedicated cell. It uses the same
build flags and comparison thresholds. It does not need the diagnostic template.

Build the Linux payload with the pinned `flake.nix`/`flake.lock`. To exclude
concurrent edits, archive each exact git revision into its own directory and
supply `--override-input candidate path:... --override-input control path:...`.
Use the explicit `#packages.x86_64-linux.default` output on a macOS operator.
Publish its `bin/inspection-cell` entry with the owner's `cellctl payload-publish`.
All executions in the retained checkpoint used the original payload, whose six
source hashes are reproduced by `validation-2026-10-11/payload-source/`.

Before a paired queue, run `--proof`, then pass its successfully completed journal
as `--proof-journal`. `--case active` or `disabled` selects five alternating pairs;
`both` selects ten pairs. Each trial has 10 seconds of warmup and 30 seconds of
measurement. Admission includes reset/setup, collection and cleanup overhead.
Do not lower `--seconds-per-trial` merely to fit a queue; calibrate it first.

This opaque probe collects diagnostics, not a Kenshou benchmark-grade comparison.
A completed queue still needs paired analysis and the original policy's grade,
checkpoint-symmetry and precision checks. The policy in `bench/mp12-cell/policy.json`
remains unchanged: five pairs, 95% intervals, maximum relative interval width 6%,
and zero allowed slowdown. A passed workload gate alone does not accept cumulative
inspection overhead.

The latest [validation checkpoint](validation-2026-10-11/README.md) records what
actually ran, including all failures and the remaining acceptance gap.
