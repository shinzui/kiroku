---
id: 82
slug: repair-live-reconnect-and-validate-subscription-identity-and-batch-size
title: "Repair live reconnect and validate subscription identity and batch size"
kind: exec-plan
created_at: 2026-08-27T21:14:24Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: M1 is perf-positive; save-path boundary, migration lock note, and ADR-5 gates missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Recorded perf-positive reconnect, save-path boundary, migration lock note, zero-checkout InvalidBatchSize case, ADR-5 gates"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: typed target_kind/target_category columns, TargetBindingPolicy with bound event, SomeSubscriptionStartupFailure hierarchy"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: mkBatchSize and mkStreamBufferSize; stream_name dropped in the same migration; hierarchy narrowed to runtime refusals"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T18:48:29Z
      mode: "update"
      note: "Apply user PostgreSQL 18-only testing scope."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T22:40:06Z
      mode: "implement"
      note: "Implement reconnect progress, validated capacities, startup hierarchy and durable target identity under proportional ADR-11 evidence."
---

# Repair live reconnect and validate subscription identity and batch size

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Database-driven live subscriptions currently discard their real in-memory progress when a fetch
loses its connection: the worker emits `ConnectionLost` without the position in `posRef`, and the
finite-state machine reconnects from its older cursor. Separately, `batchSize <= 0` reaches SQL
instead of failing at construction, and a durable checkpoint name can be reused for a different
target because `kiroku.subscriptions.stream_name` is never populated or checked.

After this plan, reconnect resumes from the greatest position actually processed, an invalid
batch size cannot be constructed at all, and a checkpoint is durably bound to either `$all` or a
specific category. A deliberate public transaction operation is the only supported way to rebind
an existing subscription. Focused tests demonstrate that reconnect neither duplicates an already
checkpointed batch nor skips a post-disconnect event, and that accidental target reuse runs no
handler. Every runtime subscription startup refusal also becomes catchable through one parent
exception type.


## Progress

- [x] (2026-10-09) Practical acceptance: the user approves completion with passing correctness/structural checks, the accepted checkpoint-only cost and bounded Linux evidence. Append throughput changes -0.14% and p99 +2.87%, with wide intervals; statistical equivalence remains inconclusive. Cumulative append acceptance belongs to EP6 before release; no additional EP2 trials are queued.
- [x] (2026-10-09) Quick Linux verification: retain five sealed, benchmark-grade, durably drained trials, two matched pairs, the unmatched control and the interrupted sixth submission. Preparation through cleanup took 25 minutes 30 seconds; all artifact hashes were checked, the lease is absent and all four cell instances are TERMINATED.
- [x] (2026-10-09 22:49 UTC) M1: carry the current `GlobalPosition` in `ConnectionLost` and reconnect from the maximum of FSM cursor and `posRef`; add the mid-live-fetch regression test.
- [x] (2026-10-09 22:49 UTC) M1: make `BatchSize` and the ack-stream buffer size validated types built by smart constructors, and route every runtime startup refusal through `SomeSubscriptionStartupFailure`.
- [x] (2026-10-09 22:49 UTC) M2: add the typed `target_kind`/`target_category` columns and drop `stream_name` in one migration; persist and validate target identity through initialization, ordinary saves, and dead-letter saves.
- [x] (2026-10-09 22:49 UTC) M2: add `TargetBindingPolicy` with an observable adoption of unbound rows, and expose an explicit transaction-composable target rebind operation.
- [x] (2026-10-09 22:49 UTC) M3: update subscriptions, schema, adapter and observability guides and ADR-4; all six package suites pass (339 store examples, 24 migration examples, 38 adapter examples, 17 tracing examples, 20 metrics examples, 22 CLI examples).
- [x] (2026-10-09) M3: retain source-pinned correctness, 20 structural examples, 16 controlled comparisons, all named telemetry results (including one timeout), and both initial and optimized durable checkpoint/mixed diagnostics in `kiroku-store/bench/results/ep2-target-binding/`.
- [x] (2026-10-09) Focused optimization: use fixed-kind checkpoint statements; `cabal build all` passes and the current store suite passes 340 examples. Fix the dead-letter test’s premature cancellation barrier; retain its initial failed run.


## Surprises & Discoveries

- Quick verification (2026-10-09): the existing matched Linux harness avoids
  rebuilding the generic operator or creating a matrix. Build/publication cost
  224.38/64.13 seconds, but reset/fetch overhead still costs roughly a minute
  per trial. The selected 15-minute queue ceiling did not fit six trials; five
  completed and the sixth stopped during reset without a timing sample. Keep
  this failed scope estimate and the initial two-pair preflight refusal visible.
  Two matched pairs reverse throughput direction (-2.56%, +2.34%) while p99
  rises (+4.53%, +1.24%). The approximately 10% uncertainty target was not met.
  PostgreSQL checkpoint execution rises 36.31 to 62.10 microseconds/save versus
  the original pre-cohort control, excluding the client round trip. This is a
  cumulative EP1+EP2 checkpoint cost, not an isolated EP2 append cost.

- Implementation (2026-10-09): plan 81’s name-locked transaction is extended for
  target checks; no extra pool checkout is introduced. Migration 0014 is allocated
  by the scaffolder after 0013. The upgrade test checks both relation filenode
  and tuple ctid to establish that adding defaults and dropping stream_name did
  not rewrite the existing row.
- Implementation: both adapter records had to adopt validated batch/buffer types
  in this child to keep the workspace compiling. Plan 84 consumes those types
  directly. Resize preserves a uniform binding on newly created members, while
  reset leaves metadata intact. Low-level checkpoint provisioning deliberately
  creates unbound rows because it has no target argument.
- Validation: the initial six package suites passed on PostgreSQL 18.6. The first local
  telemetry invocation used an invalid tasty pattern and was discarded; the
  rerun with an explicit OR expression passed all 11 selected control cells.
  Local timing telemetry is exploratory, with test durability disabled, and is
  distinct from the supplementary durable save comparison.

- Focused follow-up (2026-10-09): the quiet checkpoint probe showed a consistent
  7.6–17.0% per-save cost signal and about 4.2% more WAL per save. Three short
  mixed pairs showed adverse tail point estimates and about 6% more allocation
  against the original control. These are retained local diagnostics, not
  statistical acceptance. Ordinary saves now use fixed-kind prepared statements
  to avoid encoding constant kind/null fields while still writing both columns.
- Validation follow-up: the first optimized store run passed 339 of 340 examples.
  The new dead-letter test cancelled at an observed live state before the first
  durable save; live is not a delivery barrier when the publisher head lags.
  The test now waits for the durable checkpoint before cancelling. Production
  behavior is unchanged by this test correction.
- Candidate historical telemetry passed 10 of 11 selected cells; the unchanged
  plain caught-up read on 20,000 streams timed out. Its failed transcript and
  partial CSV remain retained, without a substituted successful sample.

- Historical refresh audit (2026-10-09, before implementation): source, tests, and changelogs confirmed the acceptance
  work was unimplemented; the dated Context audit distinguishes existing baseline from this plan.
- Transfer audit (2026-08-27): `FetchLive` reads from the mutable `posRef`, but
  `LiveFetchError err` becomes `ConnectionLost err`. `Fsm.step` therefore retains the cursor from
  the state value even when successful live batches advanced `posRef` after entering `Live`.
- Transfer audit (2026-08-27): `stream_name` already exists on `kiroku.subscriptions` with the
  historical default `$all`, but no Kiroku checkpoint write reads or writes it. Treating the
  default as authoritative would silently misclassify every legacy category subscription.
- Performance review (2026-09-09): because the database-driven live loop runs to completion inside
  the worker's `nextInput`, the FSM's `Live` cursor never advances while live; a `ConnectionLost`
  therefore re-catches-up from the position at live entry and replays every batch processed since.
  Milestone 1 removes that redundant fetch and handler work, so it is performance-positive.


## Decision Log

- Decision (2026-10-09, user approval): complete this child on practical
  acceptance with all passing checks and bounded evidence retained. Keep the
  statistical report inconclusive, including adverse tail/allocation estimates,
  and assess cumulative append performance at EP6 before release. No further
  EP2 benchmark is required; proceed to EP3.

- Decision (2026-10-09, user clarification): accept the checkpoint-only save
  overhead after distinguishing it from event appends. A save runs synchronously
  between subscriber batches, outside the append transaction, through the shared
  store pool. Subscriber throughput and indirect append contention remain risks;
  this does not accept an event-append regression. ADR-11 records the distinction.
  Use the existing matched Linux harness for one bounded category-group workload,
  three alternating pairs, 30 seconds warmup and 61 seconds measurement, without
  replacements or further calibration. The entire experiment, including setup
  and cleanup, must stay below the user's one-hour ceiling; quick is the goal.

- Decision (2026-10-09): follow the registry order and land EP-2 before EP-3.
  The suggested worker order is soft; EP-2 does not edit the delivery primitive’s
  decode contract. Apply the parent’s final minimum-evidence correction rather
  than the superseded matrix text. No remote queue is launched for this child.
- Decision (2026-10-09): report prior rebind identity as all distinct optional
  targets, because legacy and mixed rows cannot honestly be represented by a
  single SubscriptionTarget. Reject missing names through Hasql’s singleRow
  decoder, which fails and rolls back the surrounding transaction. The
  transaction abstraction has no arbitrary exception-throwing API.
- Decision (2026-10-09): extend the resize operation to preserve binding on new
  members and migrate both adapter capacities now for source compatibility.
  Keep ordinary saves unconditional and monotonic; workers must be stopped for
  explicit reset, resize, rebind and target-binding migration. ADR-4 records the
  durable identity and ownership boundaries.

- Decision (2026-10-09): required testing for this cohort uses PostgreSQL 18.
  The user explicitly removed PostgreSQL 17 testing; preserve already collected
  PostgreSQL 17 evidence without requiring more trials. ADR-11 and the parent
  MasterPlan carry this scope correction.

- Decision: Apply ADR-11's write-performance constraint to this child's implementation and release
  evidence, including indirect CPU/GC/pool/checkpoint effects where applicable.
  Rationale: The user explicitly prioritizes performance, especially writes. A confirmed regression
  requires correction; unchanged append SQL alone is insufficient evidence.
  Date: 2026-10-09

- Decision: Put `GlobalPosition` on `ConnectionLost` and reconnect from `max stateCursor
  observedPosition`.
  Rationale: `posRef` is the worker's source of truth after successful handler/checkpoint work.
  Taking the maximum preserves monotonic progress even if a future event is produced from an
  older state transition.
  Date: 2026-08-27

- Decision: Bind checkpoints to the normalized tokens `$all` and `$category:<category>` and mark
  pre-existing rows `$legacy` before enforcing identity.
  Rationale: The existing `$all` default was never written intentionally, so it cannot prove a
  legacy target. A reserved, explicit legacy marker forces one operator-visible adoption instead
  of guessing from ambiguous data.
  Date: 2026-08-27
  Superseded on 2026-09-09 by the typed-column decision below; the reasoning that the `$all`
  default proves nothing still stands.

- Decision: Expose deliberate retargeting as a public Hasql transaction combinator that rewrites
  every member and resets all positions explicitly.
  Rationale: [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) separates ordinary
  monotonic saves from intentional position changes. Retargeting without a reset can apply an
  unrelated cursor to another event set, so the operation must be atomic and conspicuous.
  Date: 2026-08-27

- Decision: Persist the target binding as additional upsert columns, validate it only inside the
  startup initialization checkout, and keep the target columns unindexed.
  Rationale: The ordinary save is the only per-batch write on the subscription path. Identity can
  only change between restarts, so checking it per batch would pay a round trip for nothing. The
  2026-09-09 performance review under
  [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) fixed this boundary.
  Date: 2026-09-09

- Decision: Store target identity in two new typed columns, `target_kind` and `target_category`,
  with CHECK constraints, drop `stream_name` in the same migration, and represent rows created
  before the columns existed as `target_kind = 'unbound'`.
  Rationale: Reusing a misnamed column with a private token grammar would make every future reader
  learn the grammar and would let an inconsistent row exist until Kiroku happened to read it. Two
  columns make the encoder total, let PostgreSQL reject an inconsistent row, and give legacy rows
  an explicit state instead of a sentinel string. A constant column default is metadata-only in
  PostgreSQL 17 and 18, so the migration rewrites no rows. Nothing in any Kiroku package or user
  guide reads `stream_name` and the published relation does not expose it, so dropping it now,
  also metadata-only, avoids a cleanup with no owner.
  Date: 2026-09-09

- Decision: Make adoption of unbound rows a declared `TargetBindingPolicy` on the subscription
  configuration, `AdoptUnbound` by default and `RequireBound` for strict operators, and emit
  `KirokuEventSubscriptionTargetBound` when adoption happens.
  Rationale: The target cannot be derived from the table, so some adoption must exist, but an
  implicit one-way transition on first start is the kind of silent behavior this initiative
  removes elsewhere. `MissingCheckpointPolicy` is the established precedent for declaring startup
  policy in configuration; following it makes the transition chosen and visible.
  Date: 2026-09-09

- Decision: Introduce `SomeSubscriptionStartupFailure` as an exception-hierarchy parent and route
  every subscription startup failure through it.
  Rationale: After construction-time validation removes the configuration errors, the cohort has
  four runtime startup refusals, two existing and two new. The GHC hierarchy pattern lets a
  caller catch "refused to start" once while every existing handler on a concrete type keeps
  working, so the surface grows without a breaking change.
  Date: 2026-09-09

- Decision: Validate subscription configuration at construction: `BatchSize` via `mkBatchSize`,
  the ack-stream buffer size via `mkStreamBufferSize`, and in plan 81 `ConsumerGroup` via
  `mkConsumerGroup`; each returns `Either` its typed error, and none of those errors is an
  exception any longer.
  Rationale: `mkHistoryRetentionInventoryLimit` and `mkHistoryRetentionLeaseOwner` in
  `Kiroku.Store.HistoryRetention.Types` already establish this pattern. A value that cannot be
  invalid needs no runtime check and no exception, and it separates two kinds of failure cleanly
  toward 1.0: configuration errors are `Either` values at construction, and refusals that depend
  on stored state are exceptions under one parent at startup. Recorded durably in
  [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md).
  Date: 2026-09-09


## Outcomes & Retrospective

Implementation (2026-10-09): the functional scope is complete at `6612523`:
reconnect retains processed live progress; capacities validate at construction;
four semantic startup refusals share one parent; and migration 0014 persists
target identity with declared adoption, uniform resize preservation and explicit
transactional rebind. Guides and ADR-4 record the behavior. The initial six
package suites passed, the optimized store suite passes 340 examples, 20
structural examples pass, and all 16 controlled append comparisons remain valid
because their paths were not changed by the checkpoint optimization.

Historical local evidence before the user accepted the checkpoint-only cost is retained in
`kiroku-store/bench/results/ep2-target-binding/README.md` and `summary.json`.
The first quiet category-save comparison showed +7.6–17.0% latency and about
+4.2% WAL per save. Fixed-kind statements remove constant parameter encoding,
but the follow-up still shows +25.6–26.5% category-save latency locally. Control
and candidate table columns/indexes were checked against the bootstrap and
migration 0013; neither has subscription triggers. Do not call this equivalent
performance. The user subsequently accepted this checkpoint-only trade-off;
the event-append regression gate remains in force.

All twelve mixed trials (six initial, six optimized) delivered exactly 1,500
events and 1,500 checkpoint updates apiece and durably drained. Against the
original `e6ea664` control, optimized point changes are p50 +14.84%, p95 +64.02%,
p99 +109.27%, total WAL +0.181% and allocation +2.34%. Tail changes reverse sign
in the third pair; descriptive 95% intervals are very wide (p50 -18.08/+61.00%,
p95 -57.16/+527.96%, p99 -82.28/+2371.79%). Allocation’s interval is -0.413/+5.160%.
The initial +6.01% allocation point increase was reduced, but append-performance
acceptance remains inconclusive, with material adverse signals retained. These
are local diagnostics, not benchmark-grade Linux results. At that historical
stopping point no remote run or lease had started; the follow-up below now
provides Linux evidence. No policy was weakened and no package was released.

The user accepted checkpoint-only overhead after distinguishing it from event
appends. The bounded Linux follow-up is retained in
`kiroku-store/bench/results/ep2-quick-linux/README.md` and `summary.json`.
Five trials passed delivery/durability checks and sealed artifact verification;
181434 events correspond to exactly 181434 deliveries and checkpoint calls.
Two complete pairs show throughput -0.14%, p50 -0.82%, p95 +2.17%, p99 +2.87%,
WAL/append +0.074% and allocation/append +4.24%. Descriptive 95% intervals remain
wide: throughput -26.88/+36.38%, p99 -16.06/+26.06%. This does not meet the
approximately 10% uncertainty target or prove equivalence. The unchanged
five-pair policy is retained; interruption produced no strict acceptance report.

The full experiment through cleanup took 25 minutes 30 seconds. Five trials
completed; the sixth stopped during reset when its minimum measurement time
could not fit the remaining queue budget. It supplied no timing sample; no
replacement was launched. The owned lease is absent, all four alpha VMs are
TERMINATED, and no remote execution remains active. **This child is Complete
on the user-approved practical acceptance.** Statistical equivalence remains
inconclusive and cumulative event-append acceptance remains an EP6 release
concern. No further EP2 experiments are queued. The user approved beginning
EP3; no release is claimed.


## Context and Orientation

Historical source audit (2026-10-09, `e6ea664`, before this implementation): implementation was Not Started. `Worker.hs` still
emits `ConnectionLost err` from `LiveFetchError err`, and `Fsm.hs` still retains the old state
cursor. `Test/SubscriptionReconnect.hs` injects failures before any successful live delivery,
so its passing historical scenario does not prove the missing mid-live cursor behavior.
Batch sizes remain `Int32`, ack-stream buffer validation still throws at runtime, and the
binding policy, columns, rebind operation, and common exception parent are absent. The manifest
ends at `0012.sql`; allocate a fresh migration.

[IR-16](../improvement-requests/retry-publisher-pool-errors-before-the-safety-poll.md) explicitly
cites this plan for category replay observed during its network-partition experiment. This plan
fixes that replay, but does not satisfy IR-16's requested prompt publisher pool-error retry.
Preserve the category index and category-specific group wakeups from
[ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md), and the
ack-stream masked ownership transfer and joined monitor shutdown already present since store
0.8.0.2. Coordinate startup exception changes with the separate lifetime-guard plan 93.
Measure group-wide startup validation as well as the existing per-batch checkpoint-write cells;
one pool checkout is not proof of constant startup cost.

`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` defines the pure subscription state machine.
Its `ConnectionLost` event currently contains only `Pool.UsageError`; reconnect transitions retain
the cursor stored in `Live`. `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` maintains a
separate `IORef GlobalPosition` named `posRef`. The live fetch uses that reference, but
`LiveFetchError` discards it while constructing the FSM event. Database-driven live paths are the
consumer-group `$all` path and every category path; publisher-fed singleton `$all` subscriptions
do not use this fetch branch.

`SubscriptionConfigM` and `defaultSubscriptionConfig` live in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. `subscribe` in
`kiroku-store/src/Kiroku/Store/Subscription.hs` validates consumer-group bounds but does not reject
a non-positive `batchSize`. This is a configuration error, not a retryable database failure.

Checkpoint initialization is implemented in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`. Ordinary and dead-letter progress
writes are statements in `kiroku-store/src/Kiroku/Store/SQL.hs`. The bootstrap schema has
`kiroku.subscriptions.stream_name TEXT NOT NULL DEFAULT '$all'`, which no Kiroku code, package, or
user guide reads or writes. This plan calls the persisted identity of a subscription's target its
*target binding* and stores it in two new columns, `target_kind` and `target_category`, that this
plan adds. The same migration drops `stream_name`, which is metadata-only in PostgreSQL. The
published `subscription_checkpoints_v1` relation from migration `0009` exposes neither column, so
[ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) is unaffected.

`MissingCheckpointPolicy` on `SubscriptionConfigM` is the precedent for declaring startup policy in
configuration; `TargetBindingPolicy` follows it. `mkHistoryRetentionInventoryLimit` and
`mkHistoryRetentionLeaseOwner` in `Kiroku.Store.HistoryRetention.Types` are the precedent for
validating a value at construction and returning `Either` a typed error. Today `subscribe` throws
`InvalidConsumerGroup` synchronously and `subscriptionAckStream` throws `InvalidStreamBufferSize`;
both are configuration errors that the construction pattern removes. `SubscriptionCheckpointMissing`
and `ConsumerGroupGuardConflict` are thrown from the worker and surfaced on the handle wait; they
are refusals that depend on stored state. Plan 81 adds `ConsumerGroupSizeMismatch` and this plan
adds `SubscriptionTargetMismatch` to that second kind.

[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) requires exact subscription
checkpoint identity and explicit transaction-composable reset. This plan extends that contract
from `(subscription_name, member)` to include target identity and makes rebind an equally explicit
operation. [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) matters only where all
members of one group must share the same target; topology persistence itself belongs to
`docs/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md`.

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
authoritative for performance evidence. `kiroku-store/test/Test/PerformanceStructure.hs` already
pins zero-checkout refusals and production query plans, and the historical suite measures
category catch-up (fetch, delivery, and the checkpoint upsert) plus checkpoint-inventory reads
over `kiroku.subscriptions`. That table is indexed only on `subscription_id` and the composite
`(subscription_name, consumer_group_member)` key, so writing `stream_name` keeps the upsert
HOT-eligible as long as no index is added.


## Plan of Work

### Milestone 1 — preserve reconnect progress and validate configuration at construction

Change `ConnectionLost` in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` to carry the
observed `GlobalPosition` as well as `Pool.UsageError`. Each transition from catch-up or live into
`Reconnecting` must retain `max cursor observedPosition`. In `Worker.hs`, read `posRef` when
turning `LiveFetchError` into the event. Update pure FSM examples and extend
`kiroku-store/test/Test/SubscriptionReconnect.hs` with a database-driven live case that processes
a batch, injects one pool usage error, appends another event, and proves the reconnect begins at
the processed position and delivers the later event once.

Introduce `BatchSize` in `Subscription/Types.hs` as a newtype whose constructor is not exported,
with `mkBatchSize :: Int32 -> Either InvalidBatchSize BatchSize` rejecting zero and negative
values and `defaultBatchSize` carrying the current default of 100. Change
`SubscriptionConfigM.batchSize` to that type; `subscribe` performs no batch-size check because
none is possible. Apply the same pattern to the ack-stream capacity in
`Kiroku.Store.Subscription.Stream`: a `StreamBufferSize` newtype with `mkStreamBufferSize`
returning `InvalidStreamBufferSize`, taken by `subscriptionAckStream`, so that exception and its
throw are removed. Neither error type carries an `Exception` instance any longer. Add boundary
tests for zero, negative, and one to the pure constructor, and add the zero case to the "no-op
paths use no pooled connection" block of `kiroku-store/test/Test/PerformanceStructure.hs` beside
`mkHistoryRetentionInventoryLimit 0`, so the refusal is pinned as a pure, zero-checkout path.

Define `SomeSubscriptionStartupFailure` in `Subscription/Types.hs` as an existential wrapper with
its own `Exception` instance, and replace the `anyclass` derivations on
`SubscriptionCheckpointMissing`, `ConsumerGroupGuardConflict`, and `SubscriptionTargetMismatch`
with explicit instances whose `toException` wraps the parent and whose `fromException` unwraps it,
exactly as `SomeAsyncException` does in `base`. Plan 81's `ConsumerGroupSizeMismatch` must be
routed the same way; whichever plan lands second adds that instance. Add a test that catches the
parent for each concrete type and that an existing handler on the concrete type still matches.

Milestone acceptance is a deterministic reconnect-position assertion, a pure constructor that
rejects every invalid size, and one parent that catches every runtime refusal.

### Milestone 2 — make target identity durable and deliberate

Generate a new migration with the repository scaffolder. It adds the two columns without
rewriting rows:

```sql
ALTER TABLE kiroku.subscriptions
    ADD COLUMN target_kind TEXT NOT NULL DEFAULT 'unbound'
        CHECK (target_kind IN ('unbound', 'all', 'category')),
    ADD COLUMN target_category TEXT
        CHECK ((target_kind = 'category') = (target_category IS NOT NULL)),
    DROP COLUMN stream_name;
```

The `ALTER TABLE` takes an `ACCESS EXCLUSIVE` lock for the duration of the catalog change and the
CHECK verification scan, so document that the migration runs with subscription workers stopped;
the table holds one row per member, so the scan is small. Do not add an index on either column;
validation is by subscription name. Dropping `stream_name` is metadata-only; PostgreSQL reclaims
its bytes on each row's next rewrite, which the ordinary upsert performs.

Introduce one internal encoder from `SubscriptionTarget` to the `(target_kind, target_category)`
pair and a decoder back that is total over rows satisfying the CHECK. Thread the pair through
checkpoint initialization in `Subscription/Checkpoint/SQL.hs` and
`insertDeadLetterAndCheckpointStmt` in `SQL.hs`. Ordinary saves select a prepared statement by
the target constructor: fixed kind/null literals avoid encoding constants per batch, and
Category binds its category name. All forms write both target columns. The pair is additional upsert columns only: no
`WHERE` predicate, no returned-row check, and no second statement on an ordinary save, which runs
once per delivered batch tail. Existing-row initialization must read every row for the
subscription name, inside the existing `initializeSubscriptionCheckpointSession` checkout and
sharing the sibling-row read plan 81 adds for topology, and classify the set: all rows bound to
the configured target proceed; all rows `unbound` are adopted under `AdoptUnbound` by one `UPDATE`
in the same session that also emits `KirokuEventSubscriptionTargetBound`, or refused under
`RequireBound` with `SubscriptionTargetMismatch`; any row bound to a different target, or a mixed
bound and unbound set, is refused with `SubscriptionTargetMismatch` before delivery. Add
`targetBindingPolicy :: TargetBindingPolicy` to `SubscriptionConfigM` with `AdoptUnbound` in
`defaultSubscriptionConfig`.

Extend `Kiroku.Store.Subscription.Checkpoint` with `rebindSubscriptionTargetTx`. It locks every
row for one `SubscriptionName`, requires at least one existing row, rewrites both target columns
on every member, and resets every member to the caller-provided `GlobalPosition` in the same
transaction. Return a report containing member count, old binding, new binding, and position.
Repeating the same call must be idempotent.

Add integration coverage that reuses one name for `$all` and a category, asserts typed refusal
before the handler runs, then uses the public rebind operation and proves the new target starts at
the explicit reset position. Add an upgrade-path test against a snapshot with rows created before
the columns existed: under `AdoptUnbound` the rows bind and the event fires once; under
`RequireBound` the start is refused and no handler runs; and in both cases the `stream_name`
column no longer exists.

### Milestone 3 — document the identity contract

Update the subscription and checkpoint user guides to define batch-size construction, target
binding, the binding policy and its adoption event, mismatch recovery, deliberate rebind, the
removed `stream_name` column, and the startup-refusal parent exception. Amend ADR-4 and the ADR
bundle log with the final checkpoint identity and rebind semantics. If implementation changes the
column names or the kind vocabulary, record the final schema here before completion.


## Concrete Steps

The amended ADR-11 and parent MasterPlan's final scope correction supersede the original
matrix requirements below. Use existing correctness and structural gates, historical telemetry,
and a focused old/new checkpoint-upsert comparison. Preserve uncertainty instead of claiming
statistical equivalence. Additional mixed-write remote trials are not justified for this child
unless an affected-path comparison identifies a consistent adverse signal. The integrated
cohort's original-control mixed evidence remains EP-6's responsibility.

Run from the Kiroku repository root. Inspect and structurally test the shared startup checkout and
single-upsert save boundaries; measure startup scaling only for a specific unresolved risk.
Compare the actual changed checkpoint-write path with its previous schema/statement. Allocate the migration; do not hand-pick a numeric filename:

```bash
kiroku-store-migrate new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "bind subscription checkpoints to their targets"
```

Run focused tests while iterating:

```bash
cabal build kiroku-store:kiroku-store-test
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "subscription reconnect|subscription configuration|checkpoint target"'
```

The transcript must include passing examples equivalent to:

```text
subscription reconnect
  resumes a database-driven live worker from processed progress [OK]
subscription configuration
  mkBatchSize rejects zero and negative sizes without a pool checkout [OK]
  exposes every runtime startup refusal through SomeSubscriptionStartupFailure [OK]
checkpoint target
  refuses accidental target reuse before delivery [OK]
  adopts unbound rows once under AdoptUnbound and emits the bound event [OK]
  refuses unbound rows under RequireBound [OK]
  rebinds every member and resets position atomically [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Finally run the [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) performance gates
from the repository root. `just perf-check` is the authoritative structural and
controlled-workload tier and must pass. Select the affected cells from the historical telemetry
executable (the full `just perf-telemetry` remains available) against
the checked-in baseline without failing on timing; compare the
`All.reliability-audit.subscription category catch-up 100 events`, `All.category.*`, and
`All.subscription-checkpoint-inventory.*` cells with their baseline rows, record both figures in
Surprises & Discoveries, and investigate any corroborated slowdown on the catch-up cell before
completion, because that cell exercises the fetch, delivery, and checkpoint upsert this plan
touches.

```bash
just perf-check
kiroku_bench=$(cabal list-bin kiroku-store:kiroku-store-bench)
"$kiroku_bench" --baseline "$PWD/kiroku-store/bench/results/baseline.csv" \
  --pattern '/category/ || /subscription-checkpoint-inventory/' \
  --csv /tmp/mp12-ep2-telemetry.csv
```


## Validation and Acceptance

Write-performance acceptance (2026-10-09): [ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md) makes write performance
blocking. Before production changes, freeze a pre-cohort control (initially `e6ea664`) and this
child's workload specification. Compare append-only and simultaneous appends/subscriptions in the
same process and pool, with native `$all`, category/group, and real acknowledgement-coupled adapter
coverage as applicable. Keep append SQL, successful-path round trips, locks, and instrumentation
unchanged. Keep ordinary checkpoint saves at one monotonic upsert per batch tail.

Use PostgreSQL 18. Keep matched inputs, durability and checkpoint work in the focused
comparison, record exact source identities and results, and investigate a consistent adverse
signal. Existing thresholds and baselines remain unchanged. Local timing comparisons are
exploratory; they do not establish production statistical equivalence or satisfy EP-6's
integrated mixed-workload requirement. No universal matrix, minimum pair count or 1%/3%
resolution requirement applies after the user's final scope correction in the parent.

The plan is complete when a live database fetch failure resumes at the greatest position already
processed; no event after the failure is skipped and a completed batch is not replayed merely
because the FSM held an older cursor. `mkBatchSize` must return `InvalidBatchSize` for zero and
negative sizes, so an invalid size can never reach `subscribe`, the registry, or a pool checkout.
`just perf-check` must pass, ordinary saves must remain one statement per batch tail, target
validation must add no checkout beyond the initialization session, and the reconnect test must show
the post-failure fetch starting at the processed position rather than the live-entry cursor.

Every initialization, ordinary checkpoint save, and dead-letter checkpoint save must write both
target columns. Uniformly unbound rows adopt exactly once under `AdoptUnbound` with one
`KirokuEventSubscriptionTargetBound`, and are refused under `RequireBound`; a concrete mismatch or
mixed stored identity must run no handler and return `SubscriptionTargetMismatch`. Every runtime
startup refusal must be catchable as `SomeSubscriptionStartupFailure` while existing concrete
handlers still match. Deliberate rebind must update all members and their reset positions
atomically. The generated migration must pass both empty-database and upgrade-path tests and must
not rewrite rows and must leave no `stream_name` column, and ADR-4 plus user documentation must
match the implemented contract.


## Idempotence and Recovery

Tests and the migration runner are repeatable. The migration is forward-only and must be generated
as a new payload; never edit an already released migration. If migration testing fails, fix the
new payload before release and rerun against both a fresh database and a snapshot containing
rows created before the target columns existed.

Adoption under `AdoptUnbound` and `rebindSubscriptionTargetTx` must be atomic and idempotent. A
failed or cancelled transaction leaves all members at their old binding and positions. Rebinding can
replay or omit history according to the explicitly supplied position, so callers must stop all group
members first; the operation never runs implicitly during mismatch recovery.


## Interfaces and Dependencies

The FSM event has this semantic shape:

```haskell
ConnectionLost :: GlobalPosition -> Pool.UsageError -> SubscriptionEvent
```

`Kiroku.Store.Subscription.Types` exports the typed `SubscriptionTargetMismatch` refusal, the
parent `SomeSubscriptionStartupFailure`, and:

```haskell
newtype BatchSize   -- constructor not exported
mkBatchSize :: Int32 -> Either InvalidBatchSize BatchSize
defaultBatchSize :: BatchSize

data TargetBindingPolicy = AdoptUnbound | RequireBound

-- SubscriptionConfigM
batchSize :: BatchSize                        -- default defaultBatchSize
targetBindingPolicy :: TargetBindingPolicy   -- default AdoptUnbound
```

`Kiroku.Store.Subscription.Stream` exports `StreamBufferSize` and
`mkStreamBufferSize :: Natural -> Either InvalidStreamBufferSize StreamBufferSize`, and
`subscriptionAckStream` takes a `StreamBufferSize`.

`Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventSubscriptionTargetBound
    :: SubscriptionName -> SubscriptionTarget -> SubscriptionGroupContext -> KirokuEvent
```

`Kiroku.Store.Subscription.Checkpoint` exports an operation with this shape:

```haskell
rebindSubscriptionTargetTx ::
    SubscriptionName ->
    SubscriptionTarget ->
    GlobalPosition ->
    Tx.Transaction SubscriptionTargetRebindReport
```

The report contains every distinct prior binding as `Vector (Maybe SubscriptionTarget)`
(`Nothing` means legacy unbound), the new `SubscriptionTarget`, member count, and reset position.
A missing name fails the Hasql transaction rather than inventing rows. Use the
existing `Hasql.Transaction.Transaction` stack located through Mori under
`mori://hasql/hasql`; add no external package dependency. Plan 81 may extend the same SQL parameter
tuples with topology, so neither plan may replace the other's fields while integrating.


Revision note (2026-09-09): Performance review under ADR-5. Recorded that milestone 1 removes
redundant replay after reconnect, fixed the save-path boundary (column only, no predicates, no
index), placed target validation inside the existing initialization checkout, documented the
migration's lock footprint, added the zero-checkout structural case for `InvalidBatchSize`, and
added `just perf-check` plus the named telemetry cells to the concrete steps and acceptance.

Revision note (2026-09-09): Design review. Replaced the `stream_name` token encoding and `$legacy`
sentinel with typed `target_kind`/`target_category` columns added by a metadata-only migration,
made adoption of unbound rows a declared `TargetBindingPolicy` with an emitted event, and added
the `SomeSubscriptionStartupFailure` hierarchy parent for every startup refusal. The token
decision is marked superseded rather than removed.

Revision note (2026-09-09): Design review, second pass. Batch size and ack-stream buffer size
become validated types built by smart constructors following the retention-limit precedent, so
their errors are values rather than exceptions and the parent hierarchy covers only runtime
refusals; the migration drops `stream_name` in the same statement because nothing reads it.

Revision note (2026-10-09): Audited current source, tests, migrations, and related records at
`e6ea664`; retained unfinished milestones, documented existing baseline and actual request
coverage, and refreshed integration/performance context. This is a documentation update, not
implementation or new runtime-test evidence.

Revision note (2026-10-09, write-performance requirement): Applied ADR-11 and blocking write-path
acceptance, with per-child ownership and evidence requirements. The user explicitly prioritizes
write performance. Implementation and benchmark gates remain open.

Revision note (2026-10-09, EP-2 implementation): apply the parent’s final proportional-evidence
scope to this child, preserve plan 81’s topology and resize binding, and represent prior rebind
identity honestly for legacy or mixed rows. Migration 0014 follows plan 81’s 0013.

Revision note (2026-10-09, focused evidence): retain both implementations and all adverse/failed results; reduce constant parameter encoding and fix the new dead-letter fixture’s durable barrier. Functional and structural work is complete, but EP2 remains In Progress under the unchanged write-performance gate. No next child or release is claimed.

Revision note (2026-10-09, quick Linux verification): distinguish the accepted
checkpoint-only trade-off from unresolved event-append acceptance. Retain five
verified trials, two complete pairs, the unmatched control and the sixth reset
interrupted before timing, without replacements. Preparation through cleanup
took 25 minutes 30 seconds; uncertainty remains wider than the intended coarse
target. Lease absent, all four VMs stopped, no further experiment queued.

Revision note (2026-10-09, practical acceptance): the user approved completion
with performance uncertainty retained. Mark all progress complete and move the
cumulative append comparison to the integrated release gate; existing raw
results and thresholds are unchanged.
