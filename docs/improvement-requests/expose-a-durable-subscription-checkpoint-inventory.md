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
timestamp: "2026-08-09T14:52:11Z"
requestId: IR-2
status: completed
completedAt: "2026-08-09T14:52:11Z"
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-09T14:52:11Z"
    document_timestamp: "2026-08-09T14:52:11Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Re-reviewed the implemented contract, correctness and performance evidence, package
      metadata, public Hackage artifacts, GitHub releases, and clean-consumer compilation.
      kiroku-store 0.4.0.0 exposes the inventory through the Store effect with the documented
      durable semantics; all required in-repository dependent releases resolve together from
      Hackage. Keiro remains a downstream adopter and does not block completion of this
      owning-library request.
verified:
  by: process:codex
  at: "2026-08-09T14:52:11Z"
---

# Improvement Request: Expose a Durable Subscription Checkpoint Inventory

## Status

Completed as the owning-library follow-up to
`mori://shinzui/keiro/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops`.
The API shipped in `kiroku-store` 0.4.0.0 under
`mori://shinzui/kiroku/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory`.
Keiro can now mount its deferred durable commands without crossing Kiroku's schema boundary;
that downstream adoption is planned separately and does not hold this request open.

## Context

Kiroku stores subscription progress in the `subscriptions` table. The durable key is
`(subscription_name, consumer_group_member)`. Member zero can represent either a non-group
subscription or member zero of a consumer group; the row alone cannot distinguish them.
`last_seen` is the exact persisted `GlobalPosition`, and a row remains after its worker stops. The
worker already reads and saves individual member checkpoints through
`getCheckpointMemberStmt` and `saveCheckpointMemberStmt`, but those statements are internal and
there is no public operation that lists the rows.

The public `Kiroku.Store.Subscription.subscriptionStates` function answers a different question.
It snapshots live workers registered on one `KirokuStore` handle and exposes each worker FSM's
`cursor`. As documented by
[the registry plan](../plans/45-central-subscription-state-registry-on-the-store-handle-for-cheap-observability.md),
that cursor is process-local rather than a durable database fact. Work inside an active handler
does not appear in the durable inventory until the checkpoint write commits. A stopped worker
disappears from the registry even though its durable row remains. The completed
[operator CLI initiative](../masterplans/8-embeddable-operator-cli-for-kiroku-subscription-status.md)
therefore deliberately reports only live process-local state.

Shibuya does not provide the missing durable view. Its processor introspection in
`mori://shinzui/shibuya/packages/shibuya-core` is also process-local, and the existing Shibuya IR
requests a lifecycle probe rather than checkpoint persistence. The
`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter` package consumes Kiroku subscriptions, but
Kiroku still owns the checkpoint table and its semantics. Neither Shibuya nor an adapter should
reach into that table to manufacture an inventory.

## Requested Change

Add the read-only `kiroku-store` API now implemented on master. It returns a captured global store
position and every durable subscription checkpoint visible to the configured Kiroku store:

1. Define `SubscriptionCheckpoint` with `subscriptionName`, `consumerGroupMember`,
   `checkpointPosition`, and `checkpointUpdatedAt`. The timestamp is the latest upsert time, not
   proof that the position advanced.
2. Define `SubscriptionCheckpointInventory` with one `storePosition` and a strict vector of
   `checkpoints`. Fetch both from one read-only SQL statement snapshot and one database round trip,
   retaining the position-zero `$all` row when no checkpoint exists.
3. Expose `subscriptionCheckpointInventory` through the mockable `Store` effect and
   `Kiroku.Store.Subscription`; consumers must not import the package-internal statement.
4. Return rows in deterministic ascending `(subscription name, member)` order. A consumer group is
   represented by one row per persisted member; a non-group subscription is member zero.
5. Make the semantics explicit in Haddock and user documentation: values are exact persisted
   checkpoints, stopped subscriptions remain present, an active worker's live FSM cursor may be
   ahead, and the inventory is a point-in-time read rather than a transactionally frozen view of
   subsequent writes.
6. Keep internal schema details behind Kiroku. Callers must not need `Hasql`, the `subscriptions`
   table name, or raw SQL, and mock interpreters must be able to implement the operation without a
   database.

The implemented public shape is:

```haskell
data SubscriptionCheckpoint = SubscriptionCheckpoint
    { subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !Int32
    , checkpointPosition :: !GlobalPosition
    , checkpointUpdatedAt :: !UTCTime
    }

data SubscriptionCheckpointInventory = SubscriptionCheckpointInventory
    { storePosition :: !GlobalPosition
    , checkpoints :: !(Vector SubscriptionCheckpoint)
    }

subscriptionCheckpointInventory ::
    (HasCallStack, Store :> es) =>
    Eff es SubscriptionCheckpointInventory
```

The captured store position makes a global position-distance calculation cheap. It does not make
that subtraction an exact relevant-event backlog for filtered, category, or sharded consumers.

## Boundaries

This request is read-only. It does not ask for checkpoint reset, rewind, deletion, synthetic row
creation, consumer-group rebalancing, worker lifecycle control, or a combined live-and-durable
status view. Those actions need separate safety semantics and should not be implied by exposing an
inventory.

It also does not ask Kiroku to calculate projection lag or know Keiro command rendering. Keiro can
interpret the captured store position where global position distance is meaningful and choose a
category head or another definition where it is not. Kiroku owns only the durable snapshot facts
and their public contract. A standalone store frontier and bounded replay-window API remain the
separate repository-local request
[Expose bounded fan-in replay windows](expose-bounded-fan-in-replay-windows.md).

The legacy `stream_name` and `consumer_group_size` columns are not required fields in the public
row unless Kiroku first guarantees that every checkpoint-writing path maintains them accurately.
The current member-aware upsert persists only name, member, and position, so exposing defaulted
topology values as authoritative inventory would overstate the schema's contract.

## Acceptance

1. An empty store returns `storePosition == GlobalPosition 0` and an empty checkpoint vector.
2. Saving a non-group checkpoint produces one row with its name, member zero, and exact persisted
   `GlobalPosition`.
3. Saving several members under one consumer-group name produces one independently positioned row
   per member; rows are ordered by name and then member.
4. A stopped or cancelled subscription remains in the durable inventory after it disappears from
   `subscriptionStates`.
5. While a confirmed-live handler is processing an event before its checkpoint write, the durable
   inventory reports only the prior persisted position. After the write commits, a new inventory
   read reports the advanced position.
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
10. The same SQL statement captures the `$all` store position and checkpoint rows; its query plan
    has one store-row lookup and one checkpoint scan, with no per-checkpoint follow-up work.

## Implementation and Release Evidence

The focused correctness suite currently passes 10 examples covering the empty store, both
pool-backed interpreter entry points, exact captured head, member-zero row, deterministic
multi-member ordering, monotonic saves, stopped-worker retention, a synchronized live in-flight
boundary, dead-letter atomicity, normal checkpoint bounds, and a Hasql-free custom interpreter:

```text
SubscriptionCheckpointInventory
  9 examples, 0 failures
SubscriptionCheckpointInventory mock interpreter
  1 example, 0 failures
```

The full `kiroku-store` suite passes 245 examples with 0 failures, and Haddock generation succeeds
for the package.

On PostgreSQL 18.4, the exact ordered query used one singleton `streams` scan, one `subscriptions`
scan, and one in-memory quicksort at both 100 and 10,000 checkpoint rows. It had no subplans,
repeated scans, event-table access, or disk spill. Database execution took 0.088 ms and 2.679 ms,
respectively. The fully materialized public-effect benchmark baselines are 463.3 microseconds for
100 rows and 44.7 milliseconds for 10,000 rows, a 96.50x time ratio for 100x the returned rows; the
focused 10% regression comparison passes.

The supported API is published as
[`kiroku-store-0.4.0.0`](https://hackage.haskell.org/package/kiroku-store-0.4.0.0), with the
matching [annotated-tag GitHub release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-v0.4.0.0).
The audited in-repository dependent cohort is also published as
[`kiroku-otel-0.2.0.2`](https://hackage.haskell.org/package/kiroku-otel-0.2.0.2),
[`kiroku-cli-0.2.0.1`](https://hackage.haskell.org/package/kiroku-cli-0.2.0.1),
[`kiroku-metrics-0.1.0.3`](https://hackage.haskell.org/package/kiroku-metrics-0.1.0.3), and
[`shibuya-kiroku-adapter-0.4.0.1`](https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.4.0.1).
Their direct bounds admit `kiroku-store ^>=0.4`.

After refreshing the Hackage index, a clean temporary Cabal project constrained all five exact
versions, downloaded them from Hackage, and compiled a public-effect signature calling
`subscriptionCheckpointInventory`. This verifies that the released package set resolves and
that consumers can compile the inventory API without this repository's working tree.
