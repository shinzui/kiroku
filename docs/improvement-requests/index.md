---
okf_version: "0.1"
---

# Improvement Request

- [Expose a durable subscription checkpoint inventory](expose-a-durable-subscription-checkpoint-inventory.md) - Let operators list Kiroku's persisted subscription checkpoints through a stable public API, including stopped subscriptions and consumer-group members, without querying Kiroku-owned tables directly or confusing live worker cursors with durable progress.
- [Expose bounded fan-in replay windows](expose-bounded-fan-in-replay-windows.md) - Let callers capture Kiroku's global head and page $all or one category through that inclusive bound, so offline replays terminate against an immutable logical window even while new events continue to arrive.
- [Make missing subscription checkpoints explicit and support safe lifecycle mutations](make-missing-subscription-checkpoints-explicit-and-support-safe-lifecycle-mutations.md) - Give each subscription an explicit atomic policy for a missing checkpoint and expose supported transactional checkpoint reset operations, so future-only workers cannot replay historical side effects and coordinating libraries do not write Kiroku-owned tables directly.
