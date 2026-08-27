---
id: 82
slug: repair-live-reconnect-and-validate-subscription-identity-and-batch-size
title: "Repair live reconnect and validate subscription identity and batch size"
kind: exec-plan
created_at: 2026-08-27T21:14:24Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
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
handler.


## Progress

- [ ] M1: carry the current `GlobalPosition` in `ConnectionLost` and reconnect from the maximum of FSM cursor and `posRef`; add the mid-live-fetch regression test.
- [ ] M1: reject `batchSize < 1` with a typed startup error before registry or publisher allocation.
- [ ] M2: encode, persist, and validate subscription target identity through initialization, ordinary saves, and dead-letter saves.
- [ ] M2: generate and test the legacy-row migration and expose an explicit transaction-composable target rebind operation.
- [ ] M3: update checkpoint lifecycle documentation and ADR-4, then run focused and full Kiroku validation.


## Surprises & Discoveries

- Transfer audit (2026-08-27): `FetchLive` reads from the mutable `posRef`, but
  `LiveFetchError err` becomes `ConnectionLost err`. `Fsm.step` therefore retains the cursor from
  the state value even when successful live batches advanced `posRef` after entering `Live`.
- Transfer audit (2026-08-27): `stream_name` already exists on `kiroku.subscriptions` with the
  historical default `$all`, but no Kiroku checkpoint write reads or writes it. Treating the
  default as authoritative would silently misclassify every legacy category subscription.


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

- Decision: Expose deliberate retargeting as a public Hasql transaction combinator that rewrites
  every member and resets all positions explicitly.
  Rationale: [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) separates ordinary
  monotonic saves from intentional position changes. Retargeting without a reset can apply an
  unrelated cursor to another event set, so the operation must be atomic and conspicuous.
  Date: 2026-08-27


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
writes are statements in `kiroku-store/src/Kiroku/Store/SQL.hs`. The bootstrap schema already has
`kiroku.subscriptions.stream_name TEXT NOT NULL DEFAULT '$all'`, but these paths omit it. This plan
calls the stable string written to that field a *target binding*. It is identity metadata, not an
event-stream name despite the historical column name.

[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) requires exact subscription
checkpoint identity and explicit transaction-composable reset. This plan extends that contract
from `(subscription_name, member)` to include target identity and makes rebind an equally explicit
operation. [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) matters only where all
members of one group must share the same target; topology persistence itself belongs to
`docs/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md`.


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
and one.

Milestone acceptance is a deterministic reconnect-position assertion plus zero observable
registration or handler activity for invalid configurations.

### Milestone 2 — make target identity durable and deliberate

Introduce one internal renderer from `SubscriptionTarget` to `$all` or
`$category:<category>`. Thread that binding through checkpoint initialization in
`Subscription/Checkpoint/SQL.hs`, ordinary saves, and `insertDeadLetterAndCheckpointStmt` in
`SQL.hs`. Existing-row initialization must read every row for the subscription name, verify a
single binding, and return a typed `SubscriptionTargetMismatch` before delivery if configured and
stored targets differ.

Generate a new migration with the repository scaffolder. It must remove the misleading default,
rewrite all existing rows to `$legacy`, and retain `NOT NULL`. On first startup against a group
whose rows are uniformly `$legacy`, atomically adopt the configured target for every member. A
mixed legacy/concrete group is corruption and must be refused. Coordinate the shared SQL tuple
changes with plan 81 so `consumer_group_size` and target binding are both preserved.

Extend `Kiroku.Store.Subscription.Checkpoint` with `rebindSubscriptionTargetTx`. It locks every
row for one `SubscriptionName`, requires at least one existing row, rewrites all target bindings,
and resets every member to the caller-provided `GlobalPosition` in the same transaction. Return a
report containing member count, old binding, new binding, and position. Repeating the same call
must be idempotent.

Add integration coverage that reuses one name for `$all` and a category, asserts typed refusal
before the handler runs, then uses the public rebind operation and proves the new target starts at
the explicit reset position.

### Milestone 3 — document the identity contract

Update the subscription and checkpoint user guides to define batch-size validation, target
binding, legacy adoption, mismatch recovery, and deliberate rebind. Amend ADR-4 and the ADR bundle
log with the final checkpoint identity and rebind semantics. If implementation changes the token
encoding, record the actual stable encoding here before completion.


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
checkpoint target
  refuses accidental target reuse before delivery [OK]
  rebinds every member and resets position atomically [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

The plan is complete when a live database fetch failure resumes at the greatest position already
processed; no event after the failure is skipped and a completed batch is not replayed merely
because the FSM held an older cursor. Batch sizes zero and below must return `InvalidBatchSize`
before a subscription enters the registry.

Every initialization, ordinary checkpoint save, and dead-letter checkpoint save must preserve
the normalized target. Uniform legacy rows may adopt once; a concrete mismatch or mixed stored
identity must run no handler and return `SubscriptionTargetMismatch`. Deliberate rebind must update
all members and their reset positions atomically. The generated migration must pass both empty
database and upgrade-path tests, and ADR-4 plus user documentation must match the implemented
contract.


## Idempotence and Recovery

Tests and the migration runner are repeatable. The migration is forward-only and must be generated
as a new payload; never edit an already released migration. If migration testing fails, fix the
new payload before release and rerun against both a fresh database and a snapshot containing
legacy `$all` rows.

Legacy adoption and `rebindSubscriptionTargetTx` must be atomic and idempotent. A failed or
cancelled transaction leaves all members at their old binding and positions. Rebinding can replay
or omit history according to the explicitly supplied position, so callers must stop all group
members first; the operation never runs implicitly during mismatch recovery.


## Interfaces and Dependencies

The FSM event has this semantic shape:

```haskell
ConnectionLost :: GlobalPosition -> Pool.UsageError -> SubscriptionEvent
```

`Kiroku.Store.Subscription.Types` exports typed `InvalidBatchSize` and
`SubscriptionTargetMismatch` failures. `Kiroku.Store.Subscription.Checkpoint` exports an operation
with this shape:

```haskell
rebindSubscriptionTargetTx ::
    SubscriptionName ->
    SubscriptionTarget ->
    GlobalPosition ->
    Tx.Transaction SubscriptionTargetRebindReport
```

The report contains old/new normalized bindings, member count, and reset position. Use the
existing `Hasql.Transaction.Transaction` stack located through Mori under
`mori://hasql/hasql`; add no external package dependency. Plan 81 may extend the same SQL parameter
tuples with topology, so neither plan may replace the other's fields while integrating.
