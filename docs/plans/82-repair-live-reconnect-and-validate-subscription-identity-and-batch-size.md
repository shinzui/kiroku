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

After this plan, reconnect resumes from the greatest position actually processed, invalid batch
sizes fail before a worker is registered, and a checkpoint is durably bound to either `$all` or a
specific category. A deliberate public transaction operation is the only supported way to rebind
an existing subscription. Focused tests demonstrate that reconnect neither duplicates an already
checkpointed batch nor skips a post-disconnect event, and that accidental target reuse runs no
handler. Every subscription startup refusal also becomes catchable through one parent exception
type.


## Progress

- [ ] M1: carry the current `GlobalPosition` in `ConnectionLost` and reconnect from the maximum of FSM cursor and `posRef`; add the mid-live-fetch regression test.
- [ ] M1: reject `batchSize < 1` with a typed startup error before registry or publisher allocation, and route every startup failure through `SomeSubscriptionStartupFailure`.
- [ ] M2: add the typed `target_kind`/`target_category` columns by an additive migration; persist and validate target identity through initialization, ordinary saves, and dead-letter saves.
- [ ] M2: add `TargetBindingPolicy` with an observable adoption of unbound rows, and expose an explicit transaction-composable target rebind operation.
- [ ] M3: update checkpoint lifecycle documentation and ADR-4, then run focused and full Kiroku validation and the performance gates.


## Surprises & Discoveries

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
  with CHECK constraints, leave `stream_name` untouched and unread, and represent rows created
  before the columns existed as `target_kind = 'unbound'`.
  Rationale: Reusing a misnamed column with a private token grammar would make every future reader
  learn the grammar and would let an inconsistent row exist until Kiroku happened to read it. Two
  columns make the encoder total, let PostgreSQL reject an inconsistent row, and give legacy rows
  an explicit state instead of a sentinel string. A constant column default is metadata-only in
  PostgreSQL 17 and 18, so the migration rewrites no rows.
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
  Rationale: This cohort adds three startup failures to four existing ones. The GHC hierarchy
  pattern lets a caller catch "refused to start" once while every existing handler on a concrete
  type keeps working, so the surface grows without a breaking change.
  Date: 2026-09-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

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
`kiroku.subscriptions.stream_name TEXT NOT NULL DEFAULT '$all'`, which no Kiroku code reads or
writes; it stays that way. This plan calls the persisted identity of a subscription's target its
*target binding* and stores it in two new columns, `target_kind` and `target_category`, that this
plan adds. `stream_name` is documented as deprecated and dropped by a later migration outside this
plan. The published `subscription_checkpoints_v1` relation from migration `0009` exposes neither
column, so [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md)
is unaffected.

`MissingCheckpointPolicy` on `SubscriptionConfigM` is the precedent for declaring startup policy in
configuration; `TargetBindingPolicy` follows it. The existing startup failures are
`InvalidConsumerGroup` (thrown synchronously by `subscribe`), `SubscriptionCheckpointMissing` and
`ConsumerGroupGuardConflict` (thrown from the worker and surfaced on the handle wait), and
`InvalidStreamBufferSize` in `Kiroku.Store.Subscription.Stream`; all derive `Exception` via
`anyclass` today. Plan 81 adds `ConsumerGroupSizeMismatch`, and this plan adds `InvalidBatchSize`
and `SubscriptionTargetMismatch`.

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

### Milestone 1 — preserve reconnect progress and reject invalid batch sizes

Change `ConnectionLost` in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` to carry the
observed `GlobalPosition` as well as `Pool.UsageError`. Each transition from catch-up or live into
`Reconnecting` must retain `max cursor observedPosition`. In `Worker.hs`, read `posRef` when
turning `LiveFetchError` into the event. Update pure FSM examples and extend
`kiroku-store/test/Test/SubscriptionReconnect.hs` with a database-driven live case that processes
a batch, injects one pool usage error, appends another event, and proves the reconnect begins at
the processed position and delivers the later event once.

Add a typed `InvalidBatchSize` exception beside `InvalidConsumerGroup` in
`Subscription/Types.hs`. Validate `batchSize >= 1` in `subscribe` before inserting into the
subscription registry or registering a publisher queue. Add boundary tests for zero, negative,
and one. Add the zero case to the "no-op paths use no pooled connection" block of
`kiroku-store/test/Test/PerformanceStructure.hs` so the refusal is pinned as a zero-checkout path.

Define `SomeSubscriptionStartupFailure` in `Subscription/Types.hs` as an existential wrapper with
its own `Exception` instance, and replace the `anyclass` derivations on `InvalidConsumerGroup`,
`SubscriptionCheckpointMissing`, `ConsumerGroupGuardConflict`, `InvalidStreamBufferSize`,
`InvalidBatchSize`, and `SubscriptionTargetMismatch` with explicit instances whose `toException`
wraps the parent and whose `fromException` unwraps it, exactly as `SomeAsyncException` does in
`base`. Plan 81's `ConsumerGroupSizeMismatch` must be routed the same way; whichever plan lands
second adds that instance. Add a test that catches the parent for each concrete type and that an
existing handler on the concrete type still matches.

Milestone acceptance is a deterministic reconnect-position assertion plus zero observable
registration or handler activity for invalid configurations.

### Milestone 2 — make target identity durable and deliberate

Generate a new migration with the repository scaffolder. It adds the two columns without
rewriting rows:

```sql
ALTER TABLE kiroku.subscriptions
    ADD COLUMN target_kind TEXT NOT NULL DEFAULT 'unbound'
        CHECK (target_kind IN ('unbound', 'all', 'category')),
    ADD COLUMN target_category TEXT
        CHECK ((target_kind = 'category') = (target_category IS NOT NULL));
```

The `ALTER TABLE` takes an `ACCESS EXCLUSIVE` lock for the duration of the catalog change and the
CHECK verification scan, so document that the migration runs with subscription workers stopped;
the table holds one row per member, so the scan is small. Do not add an index on either column;
validation is by subscription name. Do not touch `stream_name`.

Introduce one internal encoder from `SubscriptionTarget` to the `(target_kind, target_category)`
pair and a decoder back that is total over rows satisfying the CHECK. Thread the pair through
checkpoint initialization in `Subscription/Checkpoint/SQL.hs`, ordinary saves, and
`insertDeadLetterAndCheckpointStmt` in `SQL.hs`. The pair is additional upsert columns only: no
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
`RequireBound` the start is refused and no handler runs.

### Milestone 3 — document the identity contract

Update the subscription and checkpoint user guides to define batch-size validation, target binding,
the binding policy and its adoption event, mismatch recovery, deliberate rebind, the deprecated
`stream_name` column, and the startup-failure parent exception. Amend ADR-4 and the ADR bundle log
with the final checkpoint identity and rebind semantics. If implementation changes the column names
or the kind vocabulary, record the final schema here before completion.


## Concrete Steps

Run from the Kiroku repository root. Allocate the migration; do not hand-pick a numeric filename:

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
  rejects a non-positive batch size before registration [OK]
  exposes every startup failure through SomeSubscriptionStartupFailure [OK]
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

The plan is complete when a live database fetch failure resumes at the greatest position already
processed; no event after the failure is skipped and a completed batch is not replayed merely
because the FSM held an older cursor. Batch sizes zero and below must return `InvalidBatchSize`
before a subscription enters the registry and before any pool checkout. `just perf-check` must
pass, ordinary saves must remain one statement per batch tail, target validation must add no
checkout beyond the initialization session, and the reconnect test must show the post-failure
fetch starting at the processed position rather than the live-entry cursor.

Every initialization, ordinary checkpoint save, and dead-letter checkpoint save must write both
target columns. Uniformly unbound rows adopt exactly once under `AdoptUnbound` with one
`KirokuEventSubscriptionTargetBound`, and are refused under `RequireBound`; a concrete mismatch or
mixed stored identity must run no handler and return `SubscriptionTargetMismatch`. Every startup
failure must be catchable as `SomeSubscriptionStartupFailure` while existing concrete handlers
still match. Deliberate rebind must update all members and their reset positions atomically. The
generated migration must pass both empty-database and upgrade-path tests and must not rewrite
rows, and ADR-4 plus user documentation must match the implemented contract.


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

`Kiroku.Store.Subscription.Types` exports typed `InvalidBatchSize` and
`SubscriptionTargetMismatch` failures, the parent `SomeSubscriptionStartupFailure`, and:

```haskell
data TargetBindingPolicy = AdoptUnbound | RequireBound

-- SubscriptionConfigM
targetBindingPolicy :: TargetBindingPolicy   -- default AdoptUnbound
```

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

The report contains old and new bindings as `SubscriptionTarget` values, member count, and reset
position. Use the
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
