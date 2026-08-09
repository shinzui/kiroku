---
okf_version: "0.1"
---

# Improvement Request

- [Expose bounded fan-in replay windows](expose-bounded-fan-in-replay-windows.md) - Let callers capture Kiroku's global head and page $all or one category through that inclusive bound, so offline replays terminate against an immutable logical window even while new events continue to arrive.
- [Expose a durable subscription checkpoint inventory](expose-a-durable-subscription-checkpoint-inventory.md) - Let operators list Kiroku's persisted subscription checkpoints through a stable public API, including stopped subscriptions and consumer-group members, without querying Kiroku-owned tables directly or confusing live worker cursors with durable progress.
