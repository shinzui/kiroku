---
okf_version: "0.1"
---

# Improvement Request

- [Expose a durable subscription checkpoint inventory](expose-a-durable-subscription-checkpoint-inventory.md) - Let operators list Kiroku's persisted subscription checkpoints through a stable public API, including stopped subscriptions and consumer-group members, without querying Kiroku-owned tables directly or confusing live worker cursors with durable progress.
- [Expose bounded fan-in replay windows](expose-bounded-fan-in-replay-windows.md) - Let callers capture Kiroku's global head and page $all or one category through that inclusive bound, so offline replays terminate against an immutable logical window even while new events continue to arrive.
- [Expose the visible global head](expose-the-visible-global-head.md) - Let consumers read the greatest global position that is still visible in $all through a cheap public Store operation, without decoding an event or mistaking the monotonic append frontier for a reachable subscription position after hard deletion.
- [Make missing subscription checkpoints explicit and support safe lifecycle mutations](make-missing-subscription-checkpoints-explicit-and-support-safe-lifecycle-mutations.md) - Give each subscription an explicit atomic policy for a missing checkpoint and expose supported transactional checkpoint reset operations, so future-only workers cannot replay historical side effects and coordinating libraries do not write Kiroku-owned tables directly.
- [Publish a stable SQL subscription checkpoint relation](publish-a-stable-sql-subscription-checkpoint-relation.md) - Give PostgreSQL clients a versioned, supported relation for exact durable subscription-member checkpoints, so coordinating services can compose database views without depending on Kiroku's private subscriptions table or importing the Haskell Store effect.
