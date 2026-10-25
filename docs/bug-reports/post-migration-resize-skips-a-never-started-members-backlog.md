---
type: Bug Report
title: Resizing after migration 0013 skips the backlog of a member that never checkpointed
description: >-
  Migration 0013 derives a consumer group's size as max(member) + 1, so a group whose highest
  members never checkpointed derives too small a size, startup refuses the configured size, and
  the prescribed remedy, resizeConsumerGroupTx, seeds every missing member at the group's minimum
  checkpoint, permanently skipping that member's slice below it; under 0.9 the member would have
  started from the beginning.
generated:
  by: process:claude-code
  at: "2026-10-21T13:57:37Z"
bugId: BUG-5
status: reported
timestamp: "2026-10-25T23:14:18Z"
severity: data-loss
origin: mori://shinzui/kiroku/okf/reviews/concepts/REV-2
affects: mori://shinzui/kiroku/packages/kiroku-store
capability: mori://shinzui/kiroku/okf/capabilities/concepts/CAP-13
affectedVersion: "0.10.0.0"
environment: >-
  kiroku-store 0.10.0.0 with kiroku-store-migrations 0.7.0.0; the statements are unchanged
  through kiroku-store 0.11.0.1 and repository HEAD e2cdc892. Established by reading
  migrations/0013.sql, Kiroku.Store.Subscription.Checkpoint.resizeConsumerGroupTx and
  Kiroku.Store.Subscription.Checkpoint.SQL.resizeCheckpointMembersStmt at commit 364ffa82, and
  the 0.9.0.1 initializeSubscriptionCheckpointStmt at commit 94e11392. Not yet executed against
  a database.
observed: >-
  After 0013 a size-4 group whose member 3 never ran carries consumer_group_size 3 on its rows.
  A 0.10 worker configured at size 4 refuses with ConsumerGroupSizeMismatch. The migration
  comment, plan 81 and docs/user/consumer-groups.md direct the operator to resizeConsumerGroupTx
  at size 4, which inserts member 3 with last_seen equal to the minimum of the existing rows and
  rewinds members 0 to 2 to the same value. Member 3 then starts above every event in its hash
  slice that was recorded before that minimum, and no member ever delivers those events.
expected: >-
  A member that has never checkpointed should start from the subscription's missing-checkpoint
  policy, as it did on 0.9 where initializeSubscriptionCheckpointStmt resolved from_beginning to
  position 0, or the migration and its documented remedy should say that the new members of an
  incomplete legacy group must be reset to the start before they run. CAP-13 promises each member
  a disjoint slice delivered at least once.
reproduction:
  - On kiroku-store 0.9.0.1 with migrations 0.6.0.0, run a Category or AllStreams consumer group named g with size 4 and start only members 0, 1 and 2; let them checkpoint to positions 100, 120 and 110 while events whose stream ids hash to member 3 are appended below position 100.
  - Stop the workers and apply migrations 0013 and 0014 from kiroku-store-migrations 0.7.0.0; the subscriptions rows for g now carry consumer_group_size 3.
  - Start a kiroku-store 0.10.0.0 worker for g with mkConsumerGroupSize 4; it refuses with ConsumerGroupSizeMismatch g 4 [3], as the migration comment says it will.
  - Run resizeConsumerGroupTx (SubscriptionName "g") size-4 as the comment and docs/user/consumer-groups.md prescribe; the rows are now (0,4,100), (1,4,100), (2,4,100), (3,4,100).
  - Start all four members; member 3 fetches from position 100 and the events in its slice below 100 are never delivered to any member. Test/ConsumerGroupResize.hs "refuses an underestimated derived topology until resized" asserts the seeded-at-minimum row shape as the intended outcome.
workaround: >-
  No validated recovery procedure is available. Keep all workers stopped if history must be
  retained and establish the recovery requirement before changing checkpoints. Ordinary resize
  alone can skip backlog. resetSubscriptionCheckpointsTx accepts subscription names, resets all
  persisted members for those names, and creates no missing rows; it cannot select only newly
  created members. Any eventual recovery must account for missing rows and possible whole-group
  replay. Disposable development fixtures may follow their established rebuild workflow.
---

# Resizing after migration 0013 skips the backlog of a member that never checkpointed

## Disposition (2026-10-25)

The project owner reports that consumer groups have never been used in production.
Dedicated legacy recovery implementation is deferred under
[ExecPlan 100](../plans/100-make-resize-safe-for-legacy-consumer-groups-whose-members-never-checkpointed.md).
Reopen implementation when an actual retained incomplete legacy group needs
recovery, or a concrete future consumer requirement establishes the need for a new
seed API. Absence of production use does not make retained data disposable.

This report remains `reported`: its evidence is source inspection, not an executed
database reproduction or an observed production incident. The defect is not fixed.
The reproduction and references below preserve the advice and behavior at report
time. The [consumer guide](../user/consumer-groups.md#incomplete-legacy-groups) and
[historical upgrade edge](../../blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md)
now distinguish ordinary resizing from this recovery case. Neither supplies a
validated recovery procedure.

## Why it matters

Consumer-group members own disjoint hash slices, so an event that one member
skips is skipped by the group. Migration 0013 turns an operator's incomplete
deployment, a configured size whose highest members never ran, into a
persisted smaller size, and the documented remedy seeds the missing members at
the group minimum. The only members that could ever have delivered those
events now start above them. Nothing is logged, no dead letter is written and
no observer event fires, because from the resize's point of view the group is
simply equalized.

## Mechanism

`migrations/0013.sql` rewrites `consumer_group_size` to
`max(consumer_group_member) + 1` per name and states that an incomplete legacy
row set derives an underestimate that the operator equalizes with resize.
`resizeConsumerGroupTx` takes the minimum `last_seen` across the existing rows
and runs `resizeCheckpointMembersStmt`, whose `INSERT ... SELECT $1, member,
$2, $3 ... FROM generate_series(0, $2 - 1)` seeds every new member at that
minimum and whose `ON CONFLICT DO UPDATE SET last_seen = EXCLUDED.last_seen`
rewinds the existing ones to it. For a genuine resize that is right: below the
minimum every stream was covered by some old member. For a member that never
ran it is wrong: its slice was covered by nobody.

Under 0.9.0.1 the same member starting later went through
`initializeSubscriptionCheckpointStmt`, which resolves `from_beginning` to 0,
and caught up from the start.

The reverse direction also derives a wrong size: a group shrunk under 0.9's
stop-and-restart procedure keeps its stale higher-member rows, 0013 derives
the old larger size, and the forced resize rewinds the live members to the
stale rows' positions. That is redelivery rather than loss and is not the
subject of this report.

## Deferred implementation alternatives

Current documentation warns about incomplete legacy groups. Released migration
`kiroku-store-migrations/migrations/0013.sql`, including its comment, must remain
unchanged because its bytes are checksummed. Correcting current guidance does not
repair the underlying behavior.

If implementation is reopened, assess a transaction-composable recovery operation
that accounts for missing rows and resets the complete group, accepting replay for
existing members. `resetSubscriptionCheckpointsTx` alone creates no missing rows
and cannot reset selected individual members. Any composed procedure needs
version-compatible APIs, stopped workers, atomic checkpoint changes, and validation
that the missing member's events below the old minimum are delivered.

Alternatively, consider an explicit seed-position API that distinguishes new
members from existing ones. Its replay and retry semantics would need design and
tests against the actual recovery requirement. Neither alternative is implemented
or validated by this plan; no new API or recovery guarantee is available.
