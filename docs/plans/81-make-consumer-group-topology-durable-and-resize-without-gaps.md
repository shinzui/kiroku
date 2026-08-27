---
id: 81
slug: make-consumer-group-topology-durable-and-resize-without-gaps
title: "Make consumer-group topology durable and resize without gaps"
kind: exec-plan
created_at: 2026-08-27T21:14:15Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
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
the supported resize delivers every seeded event at least once.


## Progress

- [ ] M1: write `consumer_group_size` through initialization, ordinary checkpoint saves, and dead-letter checkpoint saves; read and validate group-wide stored topology at startup.
- [ ] M1: add typed mismatch and legacy-adoption tests, including the currently lossy skewed size-2 to size-3 scenario.
- [ ] M2: expose and test idempotent `resizeConsumerGroupTx`, rewinding all new members to the old members' minimum checkpoint in one transaction.
- [ ] M3: rewrite `docs/user/consumer-groups.md` and amend ADR-2 so stop/drain/restart alone is no longer described as safe.
- [ ] Run the focused and full Kiroku test suites; update living sections and perform ADR distillation.


## Surprises & Discoveries

- Transfer audit (2026-08-27): Kiroku 0.5 added atomic checkpoint initialization in
  `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`. Topology must be threaded through
  that path as well as the older save statements; changing only `saveCheckpointMemberStmt` would
  leave a freshly initialized worker incorrectly recorded as size 1.
- Transfer audit (2026-08-27): `consumer_group_size` remains referenced only by schema and
  downstream inspection tests, not by Kiroku checkpoint writes or worker validation. No schema
  migration is required for the field itself.


## Decision Log

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

- Decision: Treat an all-size-1 legacy row set as adoptable once, including a genuine size-1 to
  larger-size transition.
  Rationale: Kiroku has never written the field, so existing groups of every size contain the
  default 1. Growing a genuine size-1 group cannot lose history: member 0 had already processed
  every stream through its cursor and new members start no later than that cursor; re-delivery is
  possible, loss is not.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The database table `kiroku.subscriptions` is created by
`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`. Its key is
`(subscription_name, consumer_group_member)` and it already has
`consumer_group_size INT NOT NULL DEFAULT 1`. The field has never been written by Kiroku, so it
cannot currently distinguish a real size-1 group from any pre-existing larger group.

`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` defines `ConsumerGroup { member, size }` and
`SubscriptionConfig`. `kiroku-store/src/Kiroku/Store/Subscription.hs` validates only local bounds
(`size >= 1` and `0 <= member < size`) before starting a worker. The worker resolves the exact
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

Downstream Keiro workers use Kiroku consumer-group members for shards. Their safe adoption is
coordinated by `docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md`;
this plan owns only Kiroku's public topology and resize semantics.


## Plan of Work

### Milestone 1 — persist topology and refuse unsafe startup

Extend the checkpoint initialization statement in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` to accept the configured size and
write `consumer_group_size` on insert. Existing-row resolution must return the stored topology as
well as position. Extend `saveCheckpointMemberStmt` and the checkpoint half of
`insertDeadLetterAndCheckpointStmt` in `kiroku-store/src/Kiroku/Store/SQL.hs` to write the size on
every insert and update. Thread `configSize` from `Worker.hs` through every call.

Before delivery, validate the stored rows for the subscription name as one topology. Equal sizes
proceed. A legacy set containing only stored size 1 may be adopted atomically by the configured
size. Any other mismatch throws a typed `ConsumerGroupSizeMismatch` containing the subscription,
configured size, and observed sizes. Export it beside the other subscription startup failures and
emit a typed refusal event before the worker terminates.

Add `kiroku-store/test/Test/ConsumerGroupResize.hs` and register it in the store test suite. Seed
several streams, advance size-2 members to deliberately different checkpoints, and prove a size-3
start is refused before its handler runs. Add initializer, ordinary-save, and dead-letter-save
assertions proving every path persists the configured size. Add the legacy adoption case.

Milestone acceptance is that the mismatch is typed and deterministic, no handler runs, and the
legacy upgrade case converges to one recorded topology.

### Milestone 2 — provide the supported resize transaction

Create `Kiroku.Store.Subscription.ConsumerGroup` (or another narrowly named module under
`Kiroku.Store.Subscription`) containing `resizeConsumerGroupTx`. Validate `newSize >= 1`. In one
transaction, lock all checkpoint rows for the name, calculate their minimum `last_seen`, replace
the row set with members `0 .. newSize - 1` at that minimum and the new stored size, and return a
structured result with old sizes, old member count, new size, and resume position. A missing row
set resumes from zero. Running the same resize again must produce the same rows and position.

Extend the skewed test: after the initial mismatch refusal, call `resizeConsumerGroupTx`, start
three members, collect event ids, and assert every seeded id is observed. Duplicates are permitted;
missing ids are not. Call resize twice and assert idempotence.

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
  adopts legacy default-size rows exactly once [OK]
  delivers every seeded event after equalizing size 2 to size 3 [OK]
  is idempotent when repeated at the same size [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

The work is complete only when a mis-sized startup fails before handler delivery, all checkpoint
write paths store topology, legacy rows adopt safely, and the supported resize test proves no
seeded event is skipped after a skewed 2-to-3 transition. Ordinary saves must remain monotonic;
only the explicit resize transaction may move positions backward. The user guide and ADR-2 must
describe the same procedure and strict ADR validation must pass.


## Idempotence and Recovery

Tests use ephemeral databases and are repeatable. `resizeConsumerGroupTx` must be idempotent and
must either replace the complete topology or roll back without change. Rewinding to the minimum
can cause duplicate delivery but cannot lose an event. No migration is expected because the
column already exists; if implementation discovers a schema/default change is required, generate
it with `kiroku-store-migrate new --manifest kiroku-store-migrations/migrations/manifest
--description "persist consumer group topology"`, never edit a released payload, and record the
new migration in this plan before proceeding.


## Interfaces and Dependencies

The end state includes a public transaction-composable operation with this semantic shape:

```haskell
resizeConsumerGroupTx ::
    SubscriptionName ->
    Int32 ->
    Tx.Transaction ConsumerGroupResizeResult
```

`ConsumerGroupResizeResult` reports the previous topology, new size, and `GlobalPosition` from
which every new member resumes. The subscription startup surface exports a typed
`ConsumerGroupSizeMismatch`. Checkpoint initialization, ordinary save, and dead-letter save all
persist `consumer_group_size`. No new external package dependency is required; use the existing
Hasql session/transaction stack located through Mori under `mori://hasql/hasql`.
