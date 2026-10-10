---
type: Architecture Decision Record
title: Consumer groups are static, hash-partitioned competing consumers
description: "Implement consumer groups as static, hash-partitioned competing consumers over each stream's surrogate stream_id, with structured per-member checkpoint columns and no dynamic rebalancing."
generated:
  by: process:adopt-architecture-decisions/0.8.0
  at: "2026-08-09T00:00:00Z"
docId: ADR-2
status: Accepted (recorded retroactively)
date: 2026-05-20
timestamp: "2026-10-10T15:06:38Z"
---

# ADR-0002: Consumer groups are static, hash-partitioned competing consumers

- **Related:** MasterPlan `docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`;
  ExecPlans `docs/plans/28..31-consumer-group-*.md`.

## Context

A Kiroku subscription is a single sequential consumer: one worker reads the
`$all` stream or one category in order and feeds a handler one event at a time
(`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`). A high-volume
projection therefore cannot be scaled horizontally — one slow handler bounds
throughput, with no supported way to spread work across threads/processes while
preserving ordering.

The requirement: split a subscription across N workers for parallelism, while
guaranteeing that all events from the same stream are still processed by one
worker in their original order.

## Decision

Implement **consumer groups** as **static, hash-partitioned competing
consumers**:

- A group is N **members**; the caller supplies each worker's `(member, size)`.
  There is **no** dynamic rebalancing, heartbeat, or coordinator.
- Each originating stream is deterministically assigned to exactly one member by
  hashing its **surrogate `stream_id`** with PostgreSQL-native
  `hashtextextended`, folded into `[0, size)`:
  `(((hashtextextended(stream_id::text, 0) % size) + size) % size)`.
- Routing is applied in SQL on both the `Category` and `$all` read paths
  (partitioned by originating stream), so a whole-store projection can also be
  split.
- Per-member checkpoints are persisted as **structured columns**
  (`consumer_group_member`, `consumer_group_size`) on the existing
  `subscriptions` table, keyed by a composite unique index.
- An **optional** PostgreSQL advisory lock per `(group, member)` guards the
  "exactly one live process per member index" invariant; off by default.
- Exposed through every subscription entry point: `MonadIO`
  `subscribe`/`withSubscription`, the effectful `Subscription` effect, the
  Streamly bridge, and the Shibuya adapter, via a small `ConsumerGroup` descriptor.

This is the Kafka / Pulsar `Key_Shared` / EventStoreDB `Pinned` / message-db
pattern.

## Consequences

**Positive**

- Horizontal scaling of a single projection (category or whole `$all`) by adding
  members — in one process (thread each) or across processes/hosts.
- **Stronger** per-stream ordering than dynamic schemes: because a stream's
  assignment never moves while `size` is constant, ordering is a hard guarantee,
  not "best effort during rebalance."
- No coordinator, broker, or heartbeat protocol to operate; the simple
  in-process case stays dependency-free.
- Hashing the surrogate id (already in hand on both read paths) adds no join on
  the hot `$all` path.

**Negative**

- **Resizing is a coordinated operator action.** Changing `size` re-buckets every
  stream. The original stop/drain/restart advice was insufficient when member
  checkpoints differed; the 2026-10-09 amendment below replaces that procedure.
  No automatic resize.
- Static membership puts the "one process per member index" invariant on the
  operator; mitigated, not eliminated, by the optional advisory lock.
- `hashtextextended` is stable only within a PostgreSQL installation/version.
  An assignment-changing upgrade requires equalization even at unchanged size.

## Alternatives Considered

- **Dynamic rebalancing (Kafka/Pulsar/EventStoreDB Pinned).** Rejected:
  EventStoreDB's Pinned strategy documents ordering as "not a guarantee" during
  rebalancing; a coordinator + heartbeats + partition handoff is a large,
  separable effort. Recorded as possible future work, not built.
- **Whole-projection distribution (Marten's model)** — scale by spreading whole
  projections across nodes via advisory-lock leader election. Rejected: Kiroku
  has no "split into many smaller projections" escape hatch, and Marten itself
  has wanted but never shipped single-projection sharding — a signal of the
  difficulty. Hash partitioning is the right parallelism axis here.
- **Hash the stream *name*, or use md5 / MurmurHash.** Rejected: `hashtextextended`
  is native, SQL-callable, well-distributed (same family as PG declarative HASH
  partitioning); hashing the surrogate id avoids a name-parse and a `streams`
  join on the hot path. MurmurHash has no native PG implementation; md5 is
  heavier and only mattered for message-db compatibility we are not pursuing.
- **Encode the member into the subscription-name string.** Rejected in favor of
  structured columns, which are queryable (operators can see group topology) and
  keep the checkpoint key explicit.

## Amendment: durable topology and explicit equalization (2026-10-09)

[ExecPlan 81](../plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md)
corrects the original resize consequence. Draining does not establish equal
member cursors: a stream can move from a slow member to a fast member and its
undelivered events then fall behind the new owner's cursor permanently.

Validate group size and membership at construction with opaque `ConsumerGroupSize`
and `ConsumerGroup` values. Persist configured size on initialization, ordinary
monotonic saves, and atomic dead-letter saves. Before delivery, validate all rows
for the name; mismatch refuses startup before inserting a new member. Startup
and explicit resize serialize on a transaction-scoped advisory name lock, including
an initially absent group, within the existing one pool checkout. Ordinary saves
and event appends never take that lock or add verification queries.

With every worker stopped, call the public transaction-composable
`resizeConsumerGroupTx` in `Kiroku.Store.Subscription.Checkpoint`, then restart
all new members. It locks the old checkpoint set, rewinds every new member to its
minimum position (zero when absent), preserves surviving member row identities,
removes obsolete members, and reports the prior topology and resume position.
The same-size operation is required after a change in PostgreSQL hash assignment.
Duplicates are permitted; silent gaps are not. Callers own worker quiescence;
this operation does not perform dynamic rebalancing or live handoff.

Migration `0013.sql` derives legacy size as `max(consumer_group_member) + 1`.
Incomplete legacy membership yields an underestimate, refused at the next start
and corrected by explicit resize rather than implicit adoption. The low-level
exact-checkpoint initializer remains a size-1 provisioning API; pre-provision
whole groups through resize so their topology is explicit.

Performance acceptance remains governed by [ADR-11](0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md).
Functional validation alone does not establish write-performance neutrality.


## Implementation status (2026-10-10)

The durable topology and public transaction-composable equalization operation
ship in `kiroku-store` 0.10.0.0 with migration 0013 in
`kiroku-store-migrations` 0.7.0.0. Published source hashes and annotated tags are
verified in `kiroku-store/bench/results/ep6-publication/`. Downstream lease resize
in mori://shinzui/keiro composes that released checkpoint API with application-owned
lease rows; checkpoint SQL remains owned here. Stopped-worker preconditions and
at-least-once replay remain required.
