---
title: "Partitioned consumer groups"
type: Capability
description: "Split a named subscription across N members that each process a disjoint, per-stream-ordered slice in parallel, with per-member checkpoints and an optional startup conflict guard."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-13
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Subscription.Types
requires:
  - CAP-11
evidence:
  - kind: test
    resource: kiroku-store/test/Test/ConsumerGroup.hs
    proves: A size-N group processes a disjoint, per-stream-ordered partition of events with per-member checkpoints, and rejects invalid membership.
  - kind: test
    resource: kiroku-store/test/Test/ConsumerGroupSql.hs
    proves: The hash-partitioning predicate assigns each stream to exactly one member.
  - kind: example
    resource: kiroku-jitsurei/app/Main.hs
    proves: A runnable size-4 group over 120 events across 40 streams asserts completeness (counts sum to 120) and disjointness (union is exactly 1..120).
  - kind: guide
    resource: docs/user/consumer-groups.md
    proves: Configuring group size, member, and the guard.
---

# Partitioned consumer groups

Scale a [subscription](live-subscriptions.md) horizontally: set
`consumerGroup = Just (ConsumerGroup member size)` and each member processes a disjoint,
per-stream-ordered slice, with per-member checkpoints keyed on
`(subscription_name, consumer_group_member)`. A stream is assigned to member
`(((hashtextextended(stream_id::text, 0) % size) + size) % size)`. Works for `Category` and `$all`
targets.

## Usage

```haskell
defaultSubscriptionConfig
  & #consumerGroup      .~ Just (ConsumerGroup { member = 0, size = 4 })
  & #consumerGroupGuard .~ True
```

## Limits

- `consumerGroupGuard` (default `False`) is a **one-shot startup detection probe** using a
  PostgreSQL advisory lock — not a lifetime-held lock. It catches a duplicate member at startup;
  it does not prevent a second process claiming the same member later.
- `subscribe` throws `InvalidConsumerGroup` when `size < 1` or `member` is out of range.
- Group members are DB-driven in live mode (no publisher queue), so subscription overflow tuning
  does not apply to them.
- Membership is static: resizing a group re-partitions stream-to-member assignments.
