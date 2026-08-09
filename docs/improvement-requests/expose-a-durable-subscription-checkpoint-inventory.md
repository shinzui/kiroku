---
type: Improvement Request
title: Expose a durable subscription checkpoint inventory
description: >-
  Let operators list Kiroku's persisted subscription checkpoints through a stable public API,
  including stopped subscriptions and consumer-group members, without querying Kiroku-owned
  tables directly or confusing live worker cursors with durable progress.
generated:
  by: openai/gpt-5
  at: "2026-08-09T02:41:50Z"
timestamp: "2026-08-09T02:41:50Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-09T02:41:50Z"
    document_timestamp: "2026-08-09T02:41:50Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against kiroku-store 0.3.1.0 and current master. Kiroku persists checkpoints in
      subscriptions, keyed by subscription_name and consumer_group_member; its public
      subscriptionStates snapshot contains only live process-local FSM cursors and explicitly
      does not guarantee the durable database position. Shibuya's public processor
      introspection is likewise process-local and does not own Kiroku's checkpoint schema.
verified:
  by: process:codex
  at: "2026-08-09T02:41:50Z"
---

# Improvement Request: Expose a Durable Subscription Checkpoint Inventory

## Status

Proposed as the owning-library follow-up to
`mori://shinzui/keiro/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops`.
Keiro's standalone operator CLI can currently show Kiroku's supported live registry honestly, but
it cannot list durable subscription progress without crossing Kiroku's schema boundary. This
request is not a blocker for the already completed live-state command; it enables a distinct
database-only durable-inventory command once the API ships in a tagged Kiroku release.

## Context

Kiroku stores subscription progress in the `subscriptions` table. The durable key is
`(subscription_name, consumer_group_member)`, where member zero represents a non-group
subscription. `last_seen` is the exact persisted `GlobalPosition`, and a row remains after its
worker stops. The worker already reads and saves individual member checkpoints through
`getCheckpointMemberStmt` and `saveCheckpointMemberStmt`, but those statements are internal and
there is no public operation that lists the rows.

The public `Kiroku.Store.Subscription.subscriptionStates` function answers a different question.
It snapshots live workers registered on one `KirokuStore` handle and exposes each worker FSM's
`cursor`. As documented by
[the registry plan](../plans/45-central-subscription-state-registry-on-the-store-handle-for-cheap-observability.md),
that cursor can be ahead of the persisted checkpoint while a batch is in flight or while an event
is being retried. A stopped worker disappears from the registry even though its durable row
remains. The completed
[operator CLI initiative](../masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md)
therefore deliberately reports only live process-local state.

Shibuya does not provide the missing durable view. Its processor introspection in
`mori://shinzui/shibuya/packages/shibuya-core` is also process-local, and the existing Shibuya IR
requests a lifecycle probe rather than checkpoint persistence. The
`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` package consumes Kiroku subscriptions, but
Kiroku still owns the checkpoint table and its semantics. Neither Shibuya nor an adapter should
reach into that table to manufacture an inventory.

## Requested Change

Add an additive, read-only `kiroku-store` API that returns every durable subscription checkpoint
visible to the configured Kiroku store:

1. Define a public row type containing at least `SubscriptionName`, consumer-group member, and the
   persisted `GlobalPosition`. If the existing `updated_at` column is exposed, document it as the
   time of the latest checkpoint write/upsert, not proof that the position advanced.
2. Add a public list operation, reachable through the mockable `Store` effect and an ordinary
   consumer-facing module such as `Kiroku.Store.Subscription`. It should execute one read-only
   database query and return an empty collection when no checkpoint rows exist.
3. Return rows in deterministic ascending `(subscription name, member)` order. A consumer group is
   represented by one row per persisted member; a non-group subscription is member zero.
4. Make the semantics explicit in Haddock and user documentation: values are exact persisted
   checkpoints, stopped subscriptions remain present, an active worker's live FSM cursor may be
   ahead, and the inventory is a point-in-time read rather than a transactionally frozen view of
   subsequent writes.
5. Keep internal schema details behind Kiroku. Callers must not need `Hasql`, the `subscriptions`
   table name, or raw SQL, and mock interpreters must be able to implement the operation without a
   database.

One possible additive shape is:

```haskell
data SubscriptionCheckpoint = SubscriptionCheckpoint
    { subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !Int32
    , checkpoint :: !GlobalPosition
    , updatedAt :: !UTCTime
    }

subscriptionCheckpoints ::
    (HasCallStack, Store :> es) =>
    Eff es (Vector SubscriptionCheckpoint)
```

The final names, collection type, and whether `updatedAt` is included belong to Kiroku. The
required contract is the durable, member-aware inventory through the public store abstraction.

## Boundaries

This request is read-only. It does not ask for checkpoint reset, rewind, deletion, synthetic row
creation, consumer-group rebalancing, worker lifecycle control, or a combined live-and-durable
status view. Those actions need separate safety semantics and should not be implied by exposing an
inventory.

It also does not ask Kiroku to calculate projection lag or know Keiro command rendering. Keiro can
join the returned persisted position with its own head-position reads and present it through
`keiro-ops`. Kiroku owns only the checkpoint facts and their public contract.

The legacy `stream_name` and `consumer_group_size` columns are not required fields in the public
row unless Kiroku first guarantees that every checkpoint-writing path maintains them accurately.
The current member-aware upsert persists only name, member, and position, so exposing defaulted
topology values as authoritative inventory would overstate the schema's contract.

## Acceptance

1. An empty store returns an empty checkpoint inventory.
2. Saving a non-group checkpoint produces one row with its name, member zero, and exact persisted
   `GlobalPosition`.
3. Saving several members under one consumer-group name produces one independently positioned row
   per member; rows are ordered by name and then member.
4. A stopped or cancelled subscription remains in the durable inventory after it disappears from
   `subscriptionStates`.
5. While a live worker's FSM cursor is ahead of its last completed checkpoint write, the durable
   inventory reports only the persisted position. After the write commits, a new inventory read
   reports the advanced position.
6. Existing monotonic checkpoint writes, retry/dead-letter atomicity, subscription delivery, and
   live-registry behavior remain unchanged.
7. The operation is available through the public `Store` effect, both pool-backed interpreters,
   and test/mock interpreters without exposing a raw statement or requiring `Hasql` in consumers.
8. Haddocks and subscription documentation distinguish `subscriptionStates` (live,
   process-local FSM cursors) from the new inventory (durable, database-backed checkpoints), with
   a copyable example of listing persisted rows.
9. A consumer such as
   `mori://shinzui/keiro/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops`
   can implement durable subscription listing using public Kiroku APIs only.
