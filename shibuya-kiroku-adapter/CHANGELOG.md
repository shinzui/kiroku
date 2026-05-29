# Changelog

## Unreleased

### Added — consumer groups as a single partitioned subscription (plan 42)

* `kirokuConsumerGroupProcessors` — present a whole kiroku consumer group as one
  `PartitionedInOrder` unit: a single call yields `N` named `QueueProcessor`s
  (one member adapter each, `ProcessorId "<name>-member-<m>"`), each pinned to
  `(PartitionedInOrder, Serial)`. Replaces the manual `mapM mkMemberAdapter
  [0..N-1]` wiring.
* `KirokuConsumerGroupConfig` + `defaultConsumerGroupConfig` — describe a whole
  group (subscription name, target, group size, batch size, buffer size, and a
  per-member `Concurrency` that must be `Serial`).
* `consumerGroupPolicy` — map a requested per-member `Concurrency` onto the
  validated group policy `(PartitionedInOrder, Serial)`, reusing Shibuya's own
  `validatePolicy` so `Ahead`/`Async` are rejected early with
  `InvalidPolicyCombo` before any subscription opens.
* No `shibuya-core` changes: the helper only consumes existing exports.

### Changed — ack decisions now drive Kiroku checkpointing (plan 40)

* The adapter bridges through `kiroku-store`'s ack-coupled
  `subscriptionAckStream`: each event blocks the Kiroku worker until the Shibuya
  handler's `AckDecision` is finalized, so the decision drives Kiroku
  checkpointing per event. Previously `AckRetry` / `AckDeadLetter` were no-ops.
  * `AckOk` — checkpoint past the event.
  * `AckRetry delay` — redeliver the same event after `delay`, bounded by the
    subscription's retry policy, then dead-letter on exhaustion.
  * `AckDeadLetter reason` — record the event in `kiroku.dead_letters` (reason
    translated to a Kiroku-native `DeadLetterReason`) and advance past it.
  * `AckHalt` — cancels the subscription (unchanged).
* The envelope `attempt` now reports the zero-based redelivery count.
* `Shibuya.Adapter.Kiroku.Convert` exposes `toIngestedAck` (replacing
  `toIngested`), `toKirokuResult`, and `toKirokuDeadLetterReason`.

## 0.1.0.0 — 2026-05-23

### New Features

* Initial release.
* `kirokuAdapter` — create a Shibuya `Adapter es RecordedEvent` from a
  Kiroku store handle and subscription configuration.
* `KirokuAdapterConfig` — subscription name, target, batch size, and
  TBQueue buffer size.
* Ack semantics: AckOk/AckRetry/AckDeadLetter are no-ops (checkpoint
  managed by Kiroku); AckHalt cancels the subscription.
* `Shibuya.Adapter.Kiroku.Convert` — RecordedEvent to Envelope mapping.
