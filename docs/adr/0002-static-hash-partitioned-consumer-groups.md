# ADR-0002: Consumer groups are static, hash-partitioned competing consumers

- **Status:** Accepted — 2026-05-20 (recorded retroactively 2026-05-22)
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
  stream, so it requires stop → drain to checkpoints → restart all members with
  the new size (documented in the user guide). No automatic resize.
- Static membership puts the "one process per member index" invariant on the
  operator; mitigated, not eliminated, by the optional advisory lock.
- `hashtextextended` is stable only within a PostgreSQL installation/version.
  Benign here (members re-derive at query time on one cluster) but documented.

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
