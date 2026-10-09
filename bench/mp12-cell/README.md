# MP-12 matched cell payloads

This isolated flake builds the same write/subscription workload against the
pre-cohort control `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0` and the current
Kiroku implementation. It adds no production package dependency. The one CPP
branch constructs membership using the old or validated API; all workload,
measurement, compiler, RTS, and non-Kiroku dependencies are shared.

Use the operator from `mori://shinzui/keiro-runtime-kenshou` at
`68f986cd7548e7da64e6eeb0444d8f5524cf5e82` or later. Its operator guide is
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
slowdown allowances and a nonpositive adverse upper bound. The 1% throughput/p50
and 3% p95/p99 limits constrain precision, never permitted slowdown.

This package and its checker are evidence-collection machinery. A single cell
is explicitly `complete_matrix: false`; full ADR-11 coverage and integration
into `just perf-check` remain required by plan 81. Existing ADR-5 baselines and
thresholds are untouched. Validate the checker with:

```bash
python3 bench/mp12-cell/test-comparison.py
```
