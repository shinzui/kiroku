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
  After resizing an incomplete legacy group, reset the newly created members to position 0 with
  resetSubscriptionCheckpointsTx before starting them, or reset the whole group to 0 and accept
  redelivery.
---

# Resizing after migration 0013 skips the backlog of a member that never checkpointed

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

## Suggested fix

Either of these closes the loss; both are compatible with the current schema.

1. Make the incomplete-legacy case explicit in the migration comment,
   `docs/user/consumer-groups.md`, plan 81 and the `0.9.0.1 -> 0.10.0.0`
   upgrade edge: when the derived size is smaller than the configured size
   because members never ran, resize and then reset the new members to 0
   before starting them. `Test/ConsumerGroupResize.hs` should gain a case that
   appends into the new member's slice before the minimum and asserts
   delivery after the documented procedure.
2. Or give `resizeConsumerGroupTx` a seed-position argument, or a sibling
   that seeds new members at 0, so the operator can choose replay for members
   that have no history instead of the group minimum.
