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
measurement; sustainable-capacity acceptance also requires bounded steady
backlog and drain evidence.

Build both Linux payloads, then publish their immutable closures with Kenshou:

```bash
nix build ./bench/mp12-cell#packages.x86_64-linux.kenshou-released \
  ./bench/mp12-cell#packages.x86_64-linux.kenshou-head --no-link
kenshou cell payload publish --cohort released --root bench/mp12-cell \
  --out /tmp/mp12-released.payload.json
kenshou cell payload publish --cohort head --root bench/mp12-cell \
  --out /tmp/mp12-head.payload.json
```

Publish from a clean checkout. The candidate descriptor names the last source
revision; check the production package directories against that revision before
publication. Benchmark/documentation-only commits do not change that source.
Each payload records its compiled closure digest, cohort identity, and harness
revision. Never edit a published payload or reuse a trial output directory.

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

Beta supplies PostgreSQL 17. Use a version-17 plan on that cell. A failed or wide
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
