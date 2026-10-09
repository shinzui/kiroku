# MP-12 matched cell payloads

This isolated flake builds the same write/subscription workload against the
pre-cohort control `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0` and the current
Kiroku implementation. It adds no production package dependency. The one CPP
branch constructs membership using the old or validated API; all workload,
measurement, compiler, RTS, and non-Kiroku dependencies are shared.

Use the operator from `mori://shinzui/keiro-runtime-kenshou` at
`7a451b5f5f4b51986e872879a3bfe10f5943af6b` or later, including the saved-session recovery fixes. Its operator guide is
project-relative `docs/guides/running-on-gcp.md` (artifact-level URI pending).
The scenario contract is copied from that pinned project into both builds;
its historical general-purpose executables refuse this dedicated scenario.

The workload uses four appenders, one ten-connection pool shared with live
subscribers, `-N4 -T -A32m`, and a fixed 512-character JSON body. It records
full intended-arrival latency samples, load scheduling, PostgreSQL activity,
statement execution/WAL, checkpoint updates/HOT, handler backlog, and RTS/GC.
Durability, exact delivery, complete durable drain, checkpoint row count,
checkpoint frequency, and the declared offered arrival count are assertions.
Native all/category/group modes and the actual acknowledgement-coupled Shibuya
adapter use the same process and store. `mp12.offered=0` selects unpaced capacity
measurement with bounded subscriber backpressure. Intended arrivals use a
monotonic deadline and POSIX nanosecond waits, with a deadline recheck before
starting each call; scheduling delay is included in append latency. Capacity elapsed time includes
the final durable drain; fixed-load latency retains the declared arrival window.
Sustainable-capacity acceptance also requires bounded steady backlog evidence.

Build both Linux payloads, then publish their immutable closures with Kenshou.
The publisher needs `nix`, `nix-store`, `zstd`, and authenticated GCS access. If
`zstd` is absent, run it through `nix shell` using the `zstd` package from this
flake's pinned nixpkgs (`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`).

```bash
nix build ./bench/mp12-cell#packages.x86_64-linux.kenshou-released \
  ./bench/mp12-cell#packages.x86_64-linux.kenshou-head --no-link
kenshou cell payload publish --cohort released --root ./bench/mp12-cell \
  --out /tmp/mp12-released.payload.json
kenshou cell payload publish --cohort head --root ./bench/mp12-cell \
  --out /tmp/mp12-head.payload.json
```

Publish from a clean checkout. The candidate descriptor names the last source
revision; check the production package directories against that revision before
publication. Benchmark/documentation-only commits do not change that source.
Each payload records its compiled closure digest, cohort identity, and harness
revision. Never edit a published payload or reuse a trial output directory.

The cell image preloads `pg_stat_statements`, but the extension must also exist
in each cloned benchmark database. Once per cell, hold an operator lease and
run the following command (replace `alpha` with `beta` for PostgreSQL 17):

```bash
kenshou cell debug --cell alpha ssh postgres -- sudo -u postgres psql -X \
  -v ON_ERROR_STOP=1 -d template1 \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
```

Release that setup lease afterward. Kenshou clones
`template1` for the isolated migration template, then clones that into the run
and removes both run databases at cleanup. The benchmark role remains an
ordinary role. The checkpoint-cost probe qualifies `public.pg_stat_statements`
because the store connection uses a restricted search path. Confirm the
sampler sees the extension in the sealed run's logs and statement snapshots.

Start with control/control calibration. The planner's repeated runs are
replaced by the cell operator's adjacent alternating pairs:

```bash
kenshou plan --all --select kiroku/append/benchmark/subscription-hardening \
  --placement cell --seed 7 --dim pg.durability=durable --dim pg.version=18 \
  --out /tmp/mp12-calibration.plan.json
kenshou cell pair --cell alpha --start \
  --baseline /tmp/mp12-released.payload.json \
  --candidate /tmp/mp12-released.payload.json \
  --plan /tmp/mp12-calibration.plan.json --pairs 5 \
  --policy bench/mp12-cell/policy.json \
  --pg-setting shared_buffers=128MB --pg-setting fsync=on \
  --pg-setting synchronous_commit=on --pg-setting full_page_writes=on \
  --pg-setting wal_level=replica --out /tmp/mp12-calibration
python3 bench/mp12-cell/check-comparison.py \
  /tmp/mp12-calibration/comparison.json --calibrate \
  --out /tmp/mp12-calibration/resolution.json
```

The required performance scope is PostgreSQL 18 on alpha, following the user
correction on 2026-10-09. Completed PostgreSQL 17 functional tests remain recorded. A failed or wide
control/control interval requires investigation or additional measurement before
candidate comparisons. Candidate checks omit `--calibrate`; they require zero
slowdown allowances. Any confidence interval wholly on the adverse side blocks
acceptance, even below the precision limits. An interval containing equality can
pass only if it is sufficiently narrow and its adverse upper bound is within the
1% throughput/p50 or 3% p95/p99 measurement-resolution target. This reports
bounded uncertainty around unchanged performance; it does not accept a confirmed
slowdown or require unchanged code to demonstrate a statistically significant
speedup. Lack of significance alone is insufficient.

This package and its checker are evidence-collection machinery. A single cell
is explicitly `complete_matrix: false`; full ADR-11 coverage and integration
into `just perf-check` remain required by plan 81. Existing ADR-5 baselines and
thresholds are untouched. Validate the checker with:

```bash
python3 bench/mp12-cell/test-comparison.py
```


## Focused plan 81 matrix

`matrix.json` declares five workloads, each measured at sustainable capacity,
20% of the slowest control pilot capacity, and 90% of that capacity: 15 A/B
cells. This is change-based coverage of the new checkpoint metadata, selected
before viewing any candidate results.

| Workload | Risk covered |
| --- | --- |
| Append-only, multiple fresh streams, batched appends | Unchanged append path under write and allocation pressure |
| Native category, single existing stream, small appends, checkpoint batch 1 | Default one-member checkpoint row and frequent saves |
| Four-member category group, existing streams, checkpoint batch 1 | Group metadata under maximum checkpoint-write frequency |
| Four-member all-streams group, multiple fresh streams, batched appends, checkpoint batch 100 | Amortized saves, hash partitioning and batched fan-out |
| Real Shibuya adapter, multiple existing streams, small appends, checkpoint batch 1 | Acknowledgement-coupled processing in the same process and pool |

The append SQL and the idle/fetch paths are unchanged by plan 81. Structural
checks and completed functional tests cover startup and resize correctness;
repeating every unchanged target and write-shape combination adds little
performance assurance for this change. The earlier 42-cell expansion is not
required here. EP-6 selects broader integrated cohort coverage, including
paths changed by later children. Hook/watchdog cost remains owned by plans 83/84.

Payload size (512 characters), four appenders, pool ten, durability, RTS settings
and deterministic fresh-stream names remain fixed. The recorded fixture preview
binds even warmup and odd steady names to the same hash partitions in both arms.

Capacity pilots use three 61-second control runs per configuration and freeze
both offered loads before any candidate trial. Fixed-load initial windows are
`max(61, ceil(6100 / offered))` seconds, retaining at least 6,100 arrivals.
Method calibration uses the frequent-checkpoint group configuration at capacity
and below capacity, covering throughput and latency separately. It starts with
five alternating pairs, then five at tenfold duration, then twenty at that same
longer duration if precision remains insufficient. Both method calibrations
must pass before A/B starts. Capacity comparisons inherit the capacity calibration;
both fixed-load profiles inherit the latency calibration. Each case uses the longer of its
own minimum-arrival window and the demonstrated calibration window, with the
calibrated pair count. It does not multiply an already-long low-rate case. These rules are frozen before viewing candidates.

Every A/B cell must independently satisfy the uncertainty and regression checks;
shared method calibration does not waive them. Inconclusiveness or regression
stops acceptance. The runner never widens limits or selects a favorable retry.

The backlog bound is independent of window length: at most eight times the
larger of the append width/batch and checkpoint batch/member count, capped by
`mp12.max-backlog`. Capacity backpressure is tighter than that limit. Handler
progress is sampled at 10 Hz, durable pending work at 1 Hz, with completeness
assertions and final exact drain. Checkpoint statement snapshots record SQL
execution time and WAL per save; those are server execution costs, not client
round-trip latency. Startup-to-live time is recorded outside primary timing for one and four workers.
Full activity/lock, CPU, RTS, raw arrival and service samples
remain in the sealed trees.

Use the freshly built operator from
`mori://shinzui/keiro-runtime-kenshou` at revision
`7a451b5f5f4b51986e872879a3bfe10f5943af6b` or later, with resume startup and lease cleanup fixes.
Estimate the whole experiment before submission. The initial focused design
contains 185 trials and 27,935 planned seconds (about 7.8 hours), before reset,
startup and collection overhead, replacements or calibration escalation. The
one-minute steady window is not the total experiment duration. Frozen loads
and calibration can increase this estimate.

```bash
python3 bench/mp12-cell/run-matrix.py estimate --root /tmp/mp12-matrix
python3 bench/mp12-cell/run-matrix.py run --operator kenshou --cell alpha \
  --control /tmp/mp12-released.payload.json --candidate /tmp/mp12-head.payload.json \
  --root /tmp/mp12-matrix --max-wall-seconds 3600
```

`run` shares one hard deadline across pilots, calibration, comparison and final
verification. The default budget is one hour. It refuses an over-budget plan
before submitting trials, and checks the remaining budget before each larger
calibration design. The current full matrix therefore refuses the default
budget. Report this scope/precision/runtime conflict and select a useful bounded
experiment before committing to a long queue; do not silently relax acceptance
limits or extend the budget. A timeout remains inconclusive and retains evidence.

For targeted recovery, individual stages are available below. Pass the remaining
experiment budget with `--max-wall-seconds`; chaining stages must not reset the
clock. The runner interrupts an operator with no log progress for five minutes,
or the expected long measurement window plus 150 seconds for longer paired
trials, and interrupts it at the hard wall deadline regardless of activity.
SIGINT allows journal preservation and owned-lease cleanup. The watchdog is a
failure detector; verified sealed trials remain the progress evidence.

Collect stages sequentially on an idle cell:

```bash
python3 bench/mp12-cell/run-matrix.py pilot --operator kenshou --cell alpha \
  --control /tmp/mp12-released.payload.json --root /tmp/mp12-matrix
python3 bench/mp12-cell/run-matrix.py calibrate --operator kenshou --cell alpha \
  --control /tmp/mp12-released.payload.json --root /tmp/mp12-matrix
python3 bench/mp12-cell/run-matrix.py compare --operator kenshou --cell alpha \
  --control /tmp/mp12-released.payload.json --candidate /tmp/mp12-head.payload.json \
  --root /tmp/mp12-matrix
MP12_CELL_MATRIX=/tmp/mp12-matrix just perf-check
python3 bench/mp12-cell/test-matrix.py
```

All execution and recovery commands request startup, including
`cell resume --start`. Resume releases both newly acquired and reattached held
leases on exit; detached-session leases remain until terminal collection.
A fully verified pilot is collected locally without reopening its lease.
The operator holds and renews leases, resets PostgreSQL and
verifies seals. The collector rechecks every artifact hash before saving evidence.
Completed pilot/calibration cells can be reused with identical frozen inputs;
an interrupted cell session must be inspected/resumed through its operator
journal before proceeding. No trial directory or published descriptor is overwritten.

`just perf-check` now fails closed until `MP12_CELL_MATRIX` (or the default
`kiroku-store/bench/results/mp12-cell-matrix`) supplies the entire accepted
matrix. The checker recomputes resolution judgments and raw hashes, verifies
workload/cohort identities and refuses changed production source. Preserve the
whole focused matrix directory with its sealed trees; relative tree lookup allows moving
it between checkouts. Do not use a lone calibration or copied acceptance flag as
complete plan 81 evidence. The earlier ADR-5 workload gates still run after this gate.
