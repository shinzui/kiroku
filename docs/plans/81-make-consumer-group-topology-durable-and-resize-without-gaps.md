---
id: 81
slug: make-consumer-group-topology-durable-and-resize-without-gaps
title: "Make consumer-group topology durable and resize without gaps"
kind: exec-plan
created_at: 2026-08-27T21:14:15Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: save must stay one upsert per batch, validation inside init checkout, ADR-5 gates missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Fixed save-path boundary, validation inside init checkout, structural checkout assertion, ADR-5 gates in steps and acceptance"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: migration-derived topology replaces runtime adoption; mismatch routed through SomeSubscriptionStartupFailure"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: ConsumerGroupSize and mkConsumerGroup; resize moved to the Checkpoint module with Report naming"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T16:36:22Z
      mode: "implement"
      note: "Implement validated durable topology and explicit gap-free resize; preserve e6ea664 control"
---

# Make consumer-group topology durable and resize without gaps

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku consumer groups split one subscription across a fixed number of members by hashing each
originating stream into a member slot. Today checkpoint rows do not record the configured group
size even though the schema has a `consumer_group_size` column, so restarting the same name with a
different size silently re-buckets streams against unrelated per-member cursors and can skip
events permanently.

After this plan, every checkpoint records the topology under which it was produced, a worker
refuses a mismatched restart before delivery, and operators can call one public transactional
resize operation that rewinds the new topology to the old members' minimum checkpoint. The
focused test demonstrates a deliberately skewed size-2 group: starting size 3 is refused, then
the supported resize delivers every seeded event at least once. Existing databases receive their
topology from a migration that derives it from the member rows already present, so no runtime
adoption path exists.


## Progress

- [x] (2026-10-09) Prepare the matched Linux harness, predeclare the focused 15-cell matrix with two method calibrations, and wire fail-closed evidence verification into `just perf-check`.
- [ ] Write-performance gate: establish pre-cohort controls and pass mixed append/subscription throughput, latency, checkpoint/WAL, and GC checks under ADR-11 before completion.
- [x] (2026-10-09 16:54 UTC) M1: introduce validated `ConsumerGroupSize` and `mkConsumerGroup`; write `consumer_group_size` through initialization, ordinary checkpoint saves, and dead-letter checkpoint saves; read and validate group-wide stored topology at startup.
- [x] (2026-10-09 16:54 UTC) M1: generate the derived-topology migration and add typed mismatch, upgrade-path, and underestimate-then-resize tests, including the currently lossy skewed size-2 to size-3 scenario.
- [x] (2026-10-09 16:54 UTC) M2: expose and test idempotent `resizeConsumerGroupTx` in `Kiroku.Store.Subscription.Checkpoint`, rewinding all new members to the old members' minimum checkpoint in one transaction.
- [x] (2026-10-09 16:54 UTC) M3: rewrite `docs/user/consumer-groups.md` and amend ADR-2 so stop/drain/restart alone is no longer described as safe.
- [x] (2026-10-09) Run the focused and full Kiroku test suites on PostgreSQL 17/18; update living sections and amend ADR-2 with the durable resize contract.


## Surprises & Discoveries

- Recovery startup correction (2026-10-09): the interrupted controller's lease
  expired and the PostgreSQL, monitoring and driver VMs shut down at
  20:19–20:21 UTC. The resume operator renewed the lease and submitted the next
  slice but did not start these stopped VMs, causing approximately 45 minutes
  of additional waiting with no new measurements. A live controller/heartbeat
  alone is insufficient progress evidence. At 21:12 UTC the three existing
  alpha instances were started; the queued slice reached `fetching` at
  21:13:22 UTC. Future interruption recovery must check instance power state
  and start the cell before resuming, then verify the submitted slice's remote
  phase using its current journal run ID. The CLI regenerates IDs for previously
  unsubmitted slices during resume, so the original planned IDs are stale.

- Controller recovery (2026-10-09): the local focused controller exited after
  six verified pilot trials, leaving its status file stale. The next submitted
  trial sealed successfully on the cell at 20:17:31 UTC. `cell resume` collected
  that same trial and continued the remaining saved slices. Pilot restart now
  verifies the saved plan hash, payload and cell before resuming its journal;
  completed evidence and original logs are preserved. Nine matrix tests pass,
  including refusal of a changed saved plan. The detached recovery controller
  is `/tmp/kiroku-mp12-focused-pipeline-v3.py`, with log
  `/tmp/kiroku-mp12-focused-pipeline-v3.log` and the existing state file below.
  It waits for the active resume operator before continuing the focused stages.
  Candidate comparison and performance acceptance remain open.

- Focused assurance (2026-10-09): following the user's instruction to avoid
  unnecessary testing, `matrix.json` now selects five workloads / 15 A/B cells:
  append-only fan-out; default category checkpoint rows; four-member group
  writes at batch 1; group fan-out at batch 100; and real adapter acknowledgements.
  Capacity and low/near-capacity latency remain separate. The unused 42-cell
  background queue was cancelled before its first submission. Startup/resize
  correctness remains covered by completed tests; unchanged idle/fetch paths
  and duplicate write/target combinations are omitted from this child's timing
  gate. EP-6 selects broader integrated coverage for the completed cohort.
  Two frequent-checkpoint method calibrations determine the steady window
  and pair count before candidates. Each comparison uses at least that window
  and enough time for its declared arrivals, without multiplying long low-rate cases. Every A/B interval independently meets the
  precision limit. Tight intervals around equality can pass without requiring
  unchanged paths to prove a speedup; any confirmed slowdown still blocks even
  below those limits. Ten interval tests and eight matrix tests pass.
  The superseded 610-second diagnostic stopped after its fifth
  verified trial (operator exit 130), preserving completed raw samples without
  treating incomplete pairs as accepted calibration. The owned focused pipeline is
  `/tmp/kiroku-mp12-focused-pipeline-v2.py`; it verified lease release and absence
  of quarantine, then started capacity pilots before two method calibrations, fifteen comparisons
  and the final gate into `/tmp/kiroku-mp12-ep1-matrix-v5`. Status and log are
  `/tmp/kiroku-mp12-focused-pipeline-state.json` and
  `/tmp/kiroku-mp12-focused-pipeline-v2.log`. Existing clean payloads are reused
  because only selection and acceptance tooling changed. No candidate comparison
  has started; performance acceptance remains open.

- Published/queued validation (2026-10-09 19:33 UTC; original queue subsequently cancelled): both clean Linux
  payloads use harness revision `6f67012011fd329c258553f1fe758a170e5a1cb1`.
  Control bundle SHA-256 is
  `0197f49615f02705bc8db94ea5f56932b874c49fb6e159b118666444e1210400`;
  candidate bundle SHA-256 is
  `926b596464faaf67b84ebeb6b9ef06db606951e810ae9752716f60cc0e32f9a6`.
  Production source remains identical to `15c21e8`; only benchmark tooling and
  documentation changed. The planner is explicitly bound to the compiled
  control identity and works from this checkout. The owned background pipeline
  `/tmp/kiroku-mp12-matrix-pipeline.py` waits for the earlier long A/A job, then
  runs pilot, full calibration, comparison and verification sequentially into
  `/tmp/kiroku-mp12-matrix-v5`. Its operator log is
  `/tmp/kiroku-mp12-matrix-pipeline.log`, status is
  `/tmp/kiroku-mp12-matrix-pipeline-state.json`. These are execution artifacts,
  not accepted evidence. A Darwin fixture-smoke build failed because its
  executable derivation retained a forbidden compiler reference; local smoke
  coverage is unverified. Required performance validation uses the published
  Linux payloads on PostgreSQL 18. No candidate comparison has started.

- Initial shared matrix implementation (2026-10-09; scope superseded above): `bench/mp12-cell/matrix.json`
  freezes 14 complementary configurations and three profiles (capacity, 20% and
  90% of the slowest control pilot capacity). Across the matrix all eight write
  shapes are covered; every mode has both payload/stream shapes and checkpoint
  frequencies. Idle subscriptions target a category receiving no matching work.
  The payload enforces zero idle deliveries/updates, a backlog bound independent
  of trial duration, and records startup-to-live time outside primary timing.
  `run-matrix.py` freezes offered loads before candidates, requires all A/A cells
  before A/B, and extends calibration using five pairs at the initial window,
  five at tenfold duration, then twenty at that longer duration. Candidate duration
  and pair count are fixed by calibration. Throughput gates capacity; p50/p95/p99
  gate fixed-load cells. Eight interval tests and seven matrix/evidence tests pass.
  The harness metadata is pinned to
  `mori://shinzui/keiro-runtime-kenshou` revision
  `31275c01a5e011d13465f4ef9a9c6abfd4b5e9df`; its registry tests and operator
  build pass. `just perf-check` now fails closed without the full matrix, rather
  than implying acceptance from its previously passing ADR-5 controls.
  Both matched Linux payload builds pass. Fresh-stream fixture names use
  deterministic, disjoint warmup/steady sequences rather than timestamps;
  the gate verifies their recorded preview so matched arms retain identical
  group partition assignments. Matrix trials remain open; the earlier
  610-second A/A timing pilot is running
  on alpha, and its first trial passed 61,000-event delivery, durable drain,
  61,000 HOT checkpoint updates, and benchmark grade. It is not full acceptance.

- Alpha cell calibration (2026-10-09): all ten sealed/verified control runs
  delivered and durably checkpointed exactly 6,100 events, with 6,100 HOT
  checkpoint updates. Five alternating control/control pairs remain inconclusive:
  relative interval half-widths are 5.35% p50, 4.07% p95, and 34.57% p99.
  The evidence bundle at
  `kiroku-store/bench/results/mp12-cell-pg18-calibration-group-fixed-1.json`
  retains the comparison, resolution verdict, payload identity, per-trial cost
  summaries and sealed manifests pointing to full raw samples in GCS. Every
  artifact hash was rechecked locally. No candidate comparison has run.
  The matched harness now uses POSIX nanosecond waits with monotonic deadline
  rechecks: the previous microsecond truncation could start an arrival early,
  underflow unsigned lag, and couple measurements to RTS timer quantisation.
  Both Linux payload builds pass after the clock correction. Raw samples show
  roughly 0.62 ms median scheduling lag with the old clock, plus varying
  service latency; the timer is not claimed to explain all uncertainty. Repeat
  calibration with longer trials before accepting any candidate evidence.

- Scope correction (2026-10-09): the user explicitly removed PostgreSQL 17
  testing from the remaining work. Use alpha/PostgreSQL 18 for the controlled
  gate. Beta workload diagnostics passed 6,100-event delivery and durable
  progress, but its old role agent rejects the new driver lease-sequence field;
  those runs are excluded from acceptance. The PostgreSQL 17 image rebuild was
  cancelled, with no active beta lease or quarantine. Completed functional
  PostgreSQL 17 results remain recorded.

- Cell smoke diagnostics: alpha sealed diagnostic runs
  `01a121d5-4615-73e2-8e99-0ade6461cd66` and
  `01a121dc-8992-77b0-880b-16b28bf76bdb` under the results bucket
  `gs://tan-nb-exp-cells-results/runs/`. They reached live subscriptions and
  completed warmup, then failed before the measurement window. The first
  isolated database lacked `pg_stat_statements`; installing the extension in
  alpha's `template1` under lease made it available to the ordinary benchmark
  role in cloned run databases. The second failure exposed the store's
  restricted search path; the cost probe now qualifies
  `public.pg_stat_statements`. These are harness/setup failures, not Kiroku
  regressions or accepted performance evidence. The cell reports PostgreSQL
  18.3, unlike the local 18.6 tests; record the actual cell versions in results.
- The cell harness now samples durable pending work at 1 Hz and handler
  backlog at 10 Hz, propagates sampler failures, and refuses incomplete
  sampling. Capacity writers apply bounded subscriber backpressure and include
  the final durable drain in elapsed time, so a growing delivery deficit cannot
  masquerade as sustainable write throughput. Fixed-load measurements keep
  their declared arrival window. Both revised Linux payloads build.

- Controlled cell preparation (2026-10-09): `bench/mp12-cell` builds matched
  Linux baseline/candidate payloads with the existing Kenshou executor and
  measurement libraries. Both Linux builds pass. The shared scenario and p95
  metrics are pinned at `mori://shinzui/keiro-runtime-kenshou` revision
  `68f986cd7548e7da64e6eeb0444d8f5524cf5e82`; its 11 registry tests and 32
  measurement tests pass. Seven local checker tests enforce missing-metric,
  health, control-bias, uncertainty, and zero-regression rejection. Cell trials now have the inconclusive calibration recorded below; this is
  evidence collection, not performance acceptance.
  The production package directories are unchanged from candidate revision
  `15c21e8a7bd833573ccd117157f2f12e656629e8`.

- Validation: `nix develop .#postgresql17 --command cabal test all
  --test-show-details=direct` passes every suite (store 326, migrations 23,
  adapter 38, CLI 22, metrics 20, OpenTelemetry 17 examples). PostgreSQL 18.6
  passes the same suite counts. `just perf-check` passes structural invariants
  and all 16 existing controlled cells. These comparisons protect previous
  append/category optimizations, not MP-12 against its original implementation.
- Local pilot calibration: five alternating control/control pairs on PostgreSQL
  18.6, each with a 61-second declared window, passed exact 6,100-event delivery,
  durable drain, and checkpoint-frequency checks. The paired 95% interval
  half-widths were 7.52% p50, 79.81% p95, and 204.16% p99, exceeding the required
  1%/3%/3% resolution. This is inconclusive, not candidate regression evidence.
  Raw results are retained at
  `kiroku-store/bench/results/mp12-pg18-calibration-group-fixed-1.json`.
- Cell infrastructure: the user identified
  `mori://shinzui/keiro-runtime-kenshou` as the benchmark environment. Its
  `mori://shinzui/keiro-runtime-kenshou/okf/adrs/concepts/ADR-6` requires controlled
  Linux cells for authoritative Kiroku comparisons. Its operator guide is at
  project-relative `docs/guides/running-on-gcp.md` (artifact-level URI pending).
  Cell alpha is available with PostgreSQL 18 and no lease or quarantine.
  Use its leased resets, health evidence, sealed output, and pairing machinery;
  preserve matched pool sizes and ADR-11's stricter workload/resolution contract.
- Telemetry: `just perf-telemetry` completed all 30 historical cells. Category
  catch-up was 1.37 ms (50% below the historical baseline), checkpoint inventory
  was 389 microseconds at 100 rows and 38.5 ms at 10,000 rows, and exhausted-category
  polling was 20.2 microseconds (19% above its historical baseline). These are
  non-blocking historical observations, not a controlled MP-12 verdict.

- Schema observation: EP-1 adds a checkpoint statement parameter but no new row
  column: the fixed-width `consumer_group_size` already exists. EP-2 adds the
  genuinely new target columns. WAL/HOT and shared-pool effects remain required
  measurements for both children.

- Implementation (2026-10-09): `0013.sql` was allocated by the migration
  scaffolder. The upgrade suite applies migrations through 0012, inserts default-1
  legacy groups, upgrades through the real ledger, and verifies complete groups
  derive size 2, incomplete groups derive size 1, and positions do not move.
- Implementation: validating after initialization could leave a new wrong-size
  row even on refusal. Startup validates siblings before insertion and uses a
  transaction-scoped name lock to serialize competing initializers, including
  absent groups. Startup reads do not take row locks; resize locks the old rows.
  Ordinary saves and appends never acquire that name lock.
- Validation on PostgreSQL 18.6: the complete store suite passed 326 examples;
  adapter 38, metrics 20, and OpenTelemetry 17 examples passed. The initial full
  run caught two stale migration-tail expectations, corrected to the actual
  manifest length; the rerun passed all 23 migration examples. Focused group
  coverage passed 28 examples including the new resize cases.
- Performance probe preflight: `mori://shinzui/ephemeral-pg/packages/ephemeral-pg` defaults disables
  durability. The new shared probe explicitly enables fsync, synchronous_commit,
  and full_page_writes, uses replica WAL and 128 MB shared buffers, and verifies
  those settings in its JSON. Smoke checks have exercised native all/category/group
  and the real Shibuya acknowledgement bridge; they are not acceptance trials.

- Implementation preflight (2026-10-09): froze the original production control at
  `e6ea664` in a detached worktree. The current starting revision `4d9b68e` differs
  only in documentation. Performance acceptance retains the declared five paired
  60-second trials, PostgreSQL 18, batch sizes 1/100, 1% throughput/p50 and 3%
  tail-latency resolution; no thresholds or baseline are relaxed.

- Refresh audit (2026-10-09): source, tests, and changelogs confirm the remaining acceptance
  work is unimplemented; the dated Context audit distinguishes existing baseline from this plan.
- Transfer audit (2026-08-27): Kiroku 0.5 added atomic checkpoint initialization in
  `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`. Topology must be threaded through
  that path as well as the older save statements; changing only `saveCheckpointMemberStmt` would
  leave a freshly initialized worker incorrectly recorded as size 1.
- Transfer audit (2026-08-27): `consumer_group_size` remains referenced only by schema and
  downstream inspection tests, not by Kiroku checkpoint writes or worker validation. No schema
  migration is required for the field itself.
- Design review (2026-09-09): a migration is required after all, not for the column but for its
  values. Existing member rows let the migration derive each group's size as
  `max(consumer_group_member) + 1`, which removes the runtime legacy-adoption branch entirely. The
  note above that no migration is required is superseded.


## Decision Log

- Decision (2026-10-09, user-directed scope): use risk-based child performance
  coverage, not exhaustive target/write-shape combinations. EP-1 requires five
  workloads at three profiles and two method calibrations, with precise paired
  evidence independently required per comparison. Accept tightly bounded
  uncertainty around equality without requiring a speedup; confirmed adverse
  changes remain blocking. See ADR-11 for the bounded-evidence contract.
  Rationale: unchanged idle/fetch paths and redundant A/A combinations do not
  justify replaying the full integrated cohort matrix for this checkpoint change.

- Decision: Keep existing member row identities during resize using an upsert
  plus deletion of obsolete indices, rather than deleting and recreating the set.
  Rationale: It produces the same equalized positions while avoiding needless
  identity churn; repeated resize preserves the row set. Workers must be stopped.
  Date: 2026-10-09

- Decision: Preserve the existing low-level exact-checkpoint initializer as a
  size-1 provisioning API; provision complete groups through the explicit resize.
  Rationale: The public initializer has no topology input. Worker startup uses
  the new configured-size initializer and validates stored siblings atomically;
  retroactively guessing a group size from a raw member index would recreate
  implicit adoption. Plan 82 must extend this same worker session for target binding.
  Date: 2026-10-09

- Decision: Use read-only accessor functions rather than exported record fields
  for opaque `ConsumerGroup`.
  Rationale: Exported record selectors permit record updates even when the data
  constructor is hidden, allowing an invalid member/size pair to bypass validation.
  Date: 2026-10-09

- Decision: Apply ADR-11's write-performance constraint to this child's implementation and release
  evidence, including indirect CPU/GC/pool/checkpoint effects where applicable.
  Rationale: The user explicitly prioritizes performance, especially writes. A confirmed regression
  requires correction; unchanged append SQL alone is insufficient evidence.
  Date: 2026-10-09

- Decision: Persist and validate topology, then require an explicit equalizing resize; do not add
  dynamic rebalancing.
  Rationale: [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) deliberately makes
  membership static. Per-stream handoff would be a different architecture, while rewinding every
  new member to the old minimum is simple, at-least-once, and gap-free.
  Date: 2026-08-27

- Decision: Expose resize as a public `Hasql.Transaction.Transaction` combinator.
  Rationale: [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) establishes
  transaction-composable explicit checkpoint mutation. Keiro must be able to compose topology
  resize with its shard-table rewrite without private Kiroku SQL.
  Date: 2026-08-27
  Amended on 2026-09-09: it lives in `Kiroku.Store.Subscription.Checkpoint` beside reset and
  rebind, takes a validated `ConsumerGroupSize`, and returns `ConsumerGroupResizeReport`, matching
  `SubscriptionCheckpointResetReport`.

- Decision: Treat an all-size-1 legacy row set as adoptable once, including a genuine size-1 to
  larger-size transition.
  Rationale: Kiroku has never written the field, so existing groups of every size contain the
  default 1. Growing a genuine size-1 group cannot lose history: member 0 had already processed
  every stream through its cursor and new members start no later than that cursor; re-delivery is
  possible, loss is not.
  Date: 2026-08-27
  Superseded on 2026-09-09 by the migration-derived topology decision below.

- Decision: Persist topology as additional upsert columns and validate it only at startup inside
  the existing initialization checkout.
  Rationale: The save runs once per delivered batch tail and is the only per-batch write on the
  subscription path. A predicate or verification round trip there would be paid on every batch
  for a condition that can only change between restarts. The 2026-09-09 performance review under
  [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) fixed this boundary.
  Date: 2026-09-09

- Decision: Derive stored topology in a migration from the member rows already present, and have
  no runtime adoption path; an underestimated derivation is refused at startup and corrected by
  the operator through the idempotent resize.
  Rationale: A group that has run has one row per member, so `max(consumer_group_member) + 1` is
  its size. Computing that once in a migration replaces an implicit one-way transition on first
  start with an explicit schema step, and the only failure mode, a group whose higher members never
  checkpointed, surfaces as the same typed refusal every other mismatch does, with the same safe
  remedy.
  Date: 2026-09-09

- Decision: Route `ConsumerGroupSizeMismatch` through the `SomeSubscriptionStartupFailure`
  hierarchy parent that plan 82 introduces.
  Rationale: Callers should be able to catch every startup refusal once. Whichever plan lands
  second adds the instance, so neither plan blocks the other.
  Date: 2026-09-09

- Decision: Validate consumer-group configuration at construction with `ConsumerGroupSize` and
  `mkConsumerGroup`, and take `ConsumerGroupSize` in `resizeConsumerGroupTx`;
  `InvalidConsumerGroup` becomes the constructors' error value rather than an exception thrown by
  `subscribe`.
  Rationale: Plan 82 adopts the `mkHistoryRetentionInventoryLimit` precedent for every
  configuration value, recorded in
  [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md).
  A size validated once at construction needs no `newSize >= 1` check in the resize operation
  and no runtime check in `subscribe`, and Keiro constructs the same type when it composes a
  shard resize.
  Date: 2026-09-09


## Outcomes & Retrospective

Functional milestones M1–M3 are implemented and validated on PostgreSQL 18.6.
The topology migration, typed refusal, transaction-composable resize, construction
validation, and operator documentation are present. ADR-2 is amended and strict
profile enforcement passes. The new mismatch exception remains a concrete
`Exception`; plan 82 owns its routing through the shared startup-refusal parent.

Both PostgreSQL 17.10 and 18.6 pass the complete suite. Before integrating the
new matrix gate, the existing ADR-5 controls passed all 16 cells and the structural
checks; historical telemetry also completed. `just perf-check` now intentionally
fails until full ADR-11 matrix evidence is available. This child remains In
Progress pending that controlled write-performance acceptance.
The pre-cohort control remains `e6ea664`; no performance acceptance is inferred
from functional tests or the probe's smoke checks.


## Context and Orientation

Source audit (2026-10-09, `e6ea664`): implementation remains Not Started. Initialization in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` and both checkpoint upserts in
`kiroku-store/src/Kiroku/Store/SQL.hs` still omit `consumer_group_size`; `ConsumerGroup` is still
publicly constructible, and the resize API is absent. The migration manifest ends at `0012.sql`;
allocate a fresh filename. Completed checkpoint inventory/reset work does not establish topology.

The newer lifetime member guard is owned separately by
[plan 93](93-hold-the-consumer-group-member-guard-for-the-worker-s-lifetime.md) for IR-15.
It prevents duplicate active members; it does not persist sizes or equalize checkpoints.
Coordinate edits to startup and preserve its guard behavior if it lands first. Preserve the
category index and group wakeups from [ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md).
One initialization checkout still permits extra SQL and group-wide work: measure startup cost
across group sizes, and retain checkpoint-write measurements for the wider rows.

The database table `kiroku.subscriptions` is created by
`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`. Its key is
`(subscription_name, consumer_group_member)` and it already has
`consumer_group_size INT NOT NULL DEFAULT 1`. The field has never been written by Kiroku, so it
cannot currently distinguish a real size-1 group from any pre-existing larger group.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines `ConsumerGroup { member, size }` and
`SubscriptionConfig`. `kiroku-store/src/Kiroku/Store/Subscription.hs` validates only local bounds
(`size >= 1` and `0 <= member < size`) before starting a worker; plan 82 establishes
construction-time validation following `mkHistoryRetentionInventoryLimit` in
`Kiroku.Store.HistoryRetention.Types`, and this plan applies it to the consumer-group pair. The
worker resolves the exact
checkpoint key through `initializeSubscriptionCheckpointSession` in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`, then saves progress through
`saveCheckpointMemberStmt` in `kiroku-store/src/Kiroku/Store/SQL.hs`. The dead-letter statement in
the same module also advances a checkpoint. All three write paths currently omit group size.

Assignment is calculated at fetch time in the consumer-group `$all` and category SQL statements:
the originating `stream_id` is hashed and reduced modulo the configured size. Each member has one
global cursor. When size changes, a stream can move from a slow member to a fast member whose
cursor is already beyond that stream's undelivered events; strict `position > cursor` reads then
skip those events forever. Draining reduces skew but does not prove every member checkpoint is
equal, and cancellation can preserve a batch-boundary skew.

[ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) is directly relevant. Its static
hash-partition decision remains accepted, but its consequence that stop/drain/restart is an
adequate resize procedure must be amended. [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)
requires ordinary saves to stay monotonic and intentional movement to use a separately named
transaction operation. The completed
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3` added initialization and exact reset
but explicitly does not infer topology; this plan adds that missing contract.

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
authoritative for performance evidence. The historical cell
`All.reliability-audit.subscription category catch-up 100 events` exercises the fetch, delivery,
and checkpoint upsert whose parameter set this plan extends, and `kiroku-store/test/Test/PerformanceStructure.hs` pins
zero-checkout refusals and production query plans. `kiroku.subscriptions` is indexed only on
`subscription_id` and the composite `(subscription_name, consumer_group_member)` key, so writing
`consumer_group_size` keeps the upsert HOT-eligible.

Downstream Keiro workers use Kiroku consumer-group members for shards. Their safe adoption is
coordinated by `docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md`;
this plan owns only Kiroku's public topology and resize semantics.


## Plan of Work

### Milestone 1 — persist topology and refuse unsafe startup

Generate a migration with the repository scaffolder that derives each group's stored size from
the member rows already present:

```sql
UPDATE kiroku.subscriptions AS s
SET consumer_group_size = derived.size
FROM (
    SELECT subscription_name, max(consumer_group_member) + 1 AS size
    FROM kiroku.subscriptions
    GROUP BY subscription_name
) AS derived
WHERE s.subscription_name = derived.subscription_name
  AND s.consumer_group_size <> derived.size;
```

A non-group subscription has one row with member 0 and derives size 1, which is already its
default. A group whose higher members never checkpointed derives an underestimate; that is
acceptable because the next start with the configured size is refused by the validation below and
the operator corrects it with the milestone 2 resize, which is safe at any size. The rewrite
touches one row per member and runs with subscription workers stopped, like every checkpoint
migration. Plan 82 generates a separate additive migration for its target columns; do not merge
the two.

Introduce `ConsumerGroupSize` in `Subscription/Types.hs` as a newtype whose constructor is not
exported, with `mkConsumerGroupSize :: Int32 -> Either InvalidConsumerGroup ConsumerGroupSize`
requiring at least one, and
`mkConsumerGroup :: Int32 -> ConsumerGroupSize -> Either InvalidConsumerGroup ConsumerGroup`
enforcing `0 <= member < size`. Stop exporting the `ConsumerGroup` data constructor and export
field accessors instead. Remove the runtime bounds check and the `InvalidConsumerGroup` throw from
`subscribe`, and drop that type's `Exception` instance; it is now the constructors' error value.
Update every in-repository caller, example, and test, including the adapter's group factory.

Extend the checkpoint initialization statement in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` to accept the configured size and
write `consumer_group_size` on insert. Existing-row resolution must return the stored topology as
well as position. Extend `saveCheckpointMemberStmt` and the checkpoint half of
`insertDeadLetterAndCheckpointStmt` in `kiroku-store/src/Kiroku/Store/SQL.hs` to write the size on
every insert and update. Thread `configSize` from `Worker.hs` through every call. The save
statements gain a column and nothing else: no `WHERE` predicate on the stored size, no
returned-row check, and no second statement. Ordinary saves run once per delivered batch tail and
must remain one statement and one pool checkout.

Before delivery, validate the stored rows for the subscription name as one topology. Perform that
read inside the existing `initializeSubscriptionCheckpointSession` checkout, by extending the
session or the initialization statement to return the sibling rows, rather than through a separate
`Pool.use`; startup stays at one checkout per member, and plan 82 adds target validation to the
same read. Equal sizes proceed. There is no runtime adoption path: any mismatch throws a typed
`ConsumerGroupSizeMismatch` containing the subscription, configured size, and observed sizes.
Export it beside the other subscription startup failures, route it through
`SomeSubscriptionStartupFailure` as plan 82 defines, and emit a typed refusal event before the
worker terminates.

Add `kiroku-store/test/Test/ConsumerGroupResize.hs` and register it in the store test suite. Seed
several streams, advance size-2 members to deliberately different checkpoints, and prove a size-3
start is refused before its handler runs. Add initializer, ordinary-save, and dead-letter-save
assertions proving every path persists the configured size. Add an upgrade-path test against a
snapshot with two member rows of a group at the default size: after the migration both rows read
size 2 and a size-2 start proceeds; with only member 0 present the migration derives size 1 and a
size-2 start is refused, and milestone 2 extends that case with the resize. Add the mismatch
refusal to the "no-op paths use no pooled connection" block of
`kiroku-store/test/Test/PerformanceStructure.hs` using its checkout counter: a refused start
performs exactly the one initialization checkout and runs no handler.

Milestone acceptance is that the mismatch is typed and deterministic, no handler runs, the refusal
is pinned at one checkout, and the migration yields one recorded topology per group that has run.

### Milestone 2 — provide the supported resize transaction

Add `resizeConsumerGroupTx` to `Kiroku.Store.Subscription.Checkpoint`, beside
`resetSubscriptionCheckpointsTx` and plan 82's `rebindSubscriptionTargetTx`, so every explicit
checkpoint-set operation lives in one module. It takes a `ConsumerGroupSize`, so no size check is
needed. In one transaction, lock all checkpoint rows for the name, calculate their minimum
`last_seen`, replace the row set with members `0 .. newSize - 1` at that minimum and the new
stored size, preserving each row's target columns from plan 82, and return a
`ConsumerGroupResizeReport` with old sizes, old member count, new size, and resume position. A
missing row set resumes from zero. Running the same resize again must produce the same rows and
position.

Extend the skewed test: after the initial mismatch refusal, call `resizeConsumerGroupTx`, start
three members, collect event ids, and assert every seeded id is observed. Duplicates are permitted;
missing ids are not. Call resize twice and assert idempotence. Extend the milestone 1 underestimate
case: after the migration derives size 1 from a lone member 0 row and a size-2 start is refused,
resize at size 2 and prove the start proceeds.

Milestone acceptance is full set coverage after resize and exact stable rows after a repeated call.

### Milestone 3 — correct durable and user documentation

Rewrite `docs/user/consumer-groups.md` so resize is stop all members, call the supported resize
transaction, then start the new topology. Explain why drain alone is insufficient and apply the
same operation with unchanged size before resuming after any PostgreSQL change that can alter the
hash assignment. Amend [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) without
rewriting history: record that the original consequence understated the loss risk and identify the
new persisted topology/refusal/equalization contract. Update the ADR bundle log and run strict
profile validation.


## Concrete Steps

This child owns the shared checkpoint-write/mixed-append harness; if another MP-12 child starts
first it establishes that harness and this child extends the same specification. Measure wider
checkpoint rows, WAL per save, observed HOT-update behavior, checkpoint batch sizes 1 and 100,
and pool contention during concurrent appends. Extra metadata may increase bytes written; quantify
it and prove it does not cause a reproducible append throughput/latency regression. If it does,
redesign the metadata-write path while preserving topology correctness.

Run from the Kiroku repository root:

```bash
cabal build kiroku-store:kiroku-store-test
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "consumer-group resize"'
```

The focused transcript must end with examples equivalent to:

```text
consumer-group resize
  refuses a configured size that disagrees with stored topology [OK]
  derives stored topology from existing member rows during migration [OK]
  refuses an underestimated derived topology until resized [OK]
  delivers every seeded event after equalizing size 2 to size 3 [OK]
  is idempotent when repeated at the same size [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Finally run the [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) performance gates
from the repository root. `just perf-check` is the authoritative structural and
controlled-workload tier and must pass. `just perf-telemetry` prints the historical cells against
the checked-in baseline without failing on timing; compare the
`All.reliability-audit.subscription category catch-up 100 events`, `All.category.*`, and
`All.subscription-checkpoint-inventory.*` cells with their baseline rows, record both figures in
Surprises & Discoveries, and investigate any corroborated slowdown on the catch-up cell before
completion, because that cell exercises the fetch, delivery, and checkpoint upsert this plan
touches.

```bash
just perf-check
just perf-telemetry
```


## Validation and Acceptance

Write-performance acceptance (2026-10-09): [ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md) makes write performance
blocking. Before production changes, freeze a pre-cohort control (initially `e6ea664`) and this
child's workload specification. Compare append-only and simultaneous appends/subscriptions in the
same process and pool, with native `$all`, category/group, and real acknowledgement-coupled adapter
coverage as applicable. Keep append SQL, successful-path round trips, locks, and instrumentation
unchanged. Keep ordinary checkpoint saves at one monotonic upsert per batch tail.

Run durable PostgreSQL 18, matched compiler/RTS/pool/database settings, and fixed payloads,
concurrency, checkpoint frequency, and offered load. Include single/multi-stream, fresh/existing,
and small/batched writes; test checkpoint batch sizes 1 and 100. Establish live mode before live
measurements, assert equal delivered work, durable progress, and bounded backlog, and measure
throughput separately from fixed-load append p50/p95/p99 including queueing delay. Record checkpoint
latency, WAL per event/save, allocation/GC/residency, and contention as well as append throughput.
Warm up, alternate at least five paired trials of at least 60 seconds, and extend inconclusive runs.
Calibrate variability on control/control first; predeclare uncertainty margins able to resolve
1% throughput/p50 and 3% p95/p99 changes or better. These are measurement-resolution limits, not
slowdown budgets. A wide uncertainty interval is inconclusive; any reproducible write regression
blocks completion until corrected. Do not offset a slow case with a faster one or alter durability,
checkpoint frequency, thresholds, or baselines to pass. Add the controlled gate to `just perf-check`
and record exact commands, revisions, schemas, raw results, and interpretation before completion.

The work is complete only when an invalid member/size pair cannot be constructed, a mis-sized
startup fails before handler delivery, all checkpoint write paths store topology, the migration
derives topology for existing groups with no runtime adoption, and the supported resize test proves
no seeded event is skipped after a skewed 2-to-3 transition. Ordinary saves must remain monotonic;
only the explicit resize transaction may move positions backward. The user guide and ADR-2 must
describe the same procedure and strict ADR validation must pass. `just perf-check` must pass, the
ordinary checkpoint save must remain a single upsert issued once per batch tail, and topology
validation must add no pool checkout beyond the initialization session.


### Controlled write probe (implementation pilot)

The identical `shibuya-kiroku-adapter/bench/WriteProbe.hs` harness is built in this
checkout and a detached `e6ea664` checkout. The control uses only
`-DLEGACY_TOPOLOGY` to construct the original consumer-group representation; its
production source is unchanged. `scripts/mp12-write-pair.py` preserves alternating
raw trials, binary hashes, declared workload, durability and delivery assertions,
and paired 95% log-ratio intervals. Its `complete_matrix: false` output explicitly
prevents interpreting a single cell as full acceptance. A positive slowdown is
never allowed by the resolution limits. Existing ADR-5 baselines are untouched.

The pilot uses GHC 9.12.4, `-N4 -T -A32m`, four appenders, one ten-connection pool,
a 512-character JSON body, `fsync`, `synchronous_commit`, and `full_page_writes`
on, replica WAL, and 128 MB shared buffers. Subscribers enter live mode before
the measurement; a two-second warmup is drained before counters reset. The first
calibration cell is an existing single-stream write of one event, native size-four
category group, checkpoint batch one, 100 offered append calls/second, five
alternating pairs, and 61 scheduled seconds per trial. Latency includes scheduled
arrival-to-completion delay. The candidate/control comparison must wait until
control/control calibration establishes sufficient precision.

```bash
control=$(cd /tmp/kiroku-mp12-control-e6ea664 && cabal list-bin shibuya-kiroku-adapter:kiroku-mp12-write-probe)
python3 scripts/mp12-write-pair.py --control "$control" --candidate "$control" \
  --calibrate --mode group --checkpoint-batch 1 --offered 100 --pairs 5 --seconds 61 \
  --output kiroku-store/bench/results/mp12-pg18-calibration-group-fixed-1.json
```

The pilot records whole-workload WAL, checkpoint update/HOT counts, and Haskell
allocation/GC. Before full acceptance, add checkpoint latency, contention and
continuous backlog evidence, all declared write shapes on PostgreSQL 18,
separate sustainable-throughput trials, and integration of the complete gate into
`just perf-check`. This pilot is evidence collection rather than a completed gate.

## Idempotence and Recovery

Tests use ephemeral databases and are repeatable. `resizeConsumerGroupTx` must be idempotent and
must either replace the complete topology or roll back without change. Rewinding to the minimum
can cause duplicate delivery but cannot lose an event. The derivation migration is generated with
`kiroku-store-migrate new --manifest kiroku-store-migrations/migrations/manifest --description
"derive consumer group topology"`; it is forward-only and idempotent because it updates only rows
whose stored size differs from the derived size. Never edit a released payload, and record the
allocated filename in this plan before proceeding. Plan 82 generates its own additive migration
for the target columns; the two are not merged.


## Interfaces and Dependencies

The end state includes a public transaction-composable operation in
`Kiroku.Store.Subscription.Checkpoint` with this semantic shape:

```haskell
resizeConsumerGroupTx ::
    SubscriptionName ->
    ConsumerGroupSize ->
    Tx.Transaction ConsumerGroupResizeReport
```

`ConsumerGroupResizeReport` reports the previous topology, new size, and `GlobalPosition` from
which every new member resumes, named to match `SubscriptionCheckpointResetReport`.
`Kiroku.Store.Subscription.Types` exports `ConsumerGroupSize`, `mkConsumerGroupSize`, and
`mkConsumerGroup`, with `InvalidConsumerGroup` as their error value; the subscription startup
surface exports a typed `ConsumerGroupSizeMismatch` routed through the
`SomeSubscriptionStartupFailure` parent that plan 82 defines. Checkpoint initialization, ordinary
save, and dead-letter save all persist `consumer_group_size`. No new external package dependency
is required; use the existing Hasql session/transaction stack located through Mori under
`mori://hasql/hasql`.

Revision note (2026-09-09): Performance review under ADR-5. Fixed the save-path boundary (columns
only, no predicates or extra statements), placed topology validation inside the existing
initialization checkout, added the structural one-checkout refusal assertion, and added
`just perf-check` plus the named telemetry cells to the concrete steps and acceptance.

Revision note (2026-09-09): Design review. Replaced the runtime legacy-adoption branch with a
migration that derives each group's stored size from its existing member rows, so an
underestimate is refused and corrected by the explicit resize rather than adopted silently; routed
`ConsumerGroupSizeMismatch` through plan 82's startup-failure parent. The adoption decision is
marked superseded rather than removed.

Revision note (2026-09-09): Design review, second pass. Consumer-group configuration is validated
at construction through `ConsumerGroupSize` and `mkConsumerGroup`, the resize operation moves
into `Kiroku.Store.Subscription.Checkpoint` beside reset and rebind, takes the validated size, and
returns a `...Report` type matching the existing reset report.

Revision note (2026-10-09): Audited current source, tests, migrations, and related records at
`e6ea664`; retained unfinished milestones, documented existing baseline and actual request
coverage, and refreshed integration/performance context. This is a documentation update, not
implementation or new runtime-test evidence.

Revision note (2026-10-09, write-performance requirement): Applied ADR-11 and blocking write-path
acceptance, with per-child ownership and evidence requirements. The user explicitly prioritizes
write performance. Implementation and benchmark gates remain open.

Revision note (2026-10-09, implementation): Implemented validated membership,
configured-size checkpoint writes, pre-insertion topology validation, migration
0013, and transactional minimum-position resize. Updated consumers and tests,
corrected the user guide and ADR-2, and preserved the pre-cohort control. Runtime
and performance evidence are recorded above; unfinished acceptance remains open.

Revision note (2026-10-09, cell gate): Applied the PostgreSQL 18-only user scope,
retained inconclusive sealed calibration evidence, corrected arrival timing,
and implemented the representative matrix collector and fail-closed gate.
Functional acceptance remains satisfied; performance acceptance remains open.

Revision note (2026-10-09, focused assurance): Reduced timing coverage to affected checkpoint paths, replaced per-cell A/A repeats with two method calibrations, cancelled the unused full queue, and corrected the unintended requirement to demonstrate a speedup on unchanged paths. The performance gate remains open.
