---
type: Architecture Decision Record
title: Subscription configuration validates at construction and runtime refusals share one parent
description: "Validate subscription configuration values with smart constructors returning typed errors, declare state-dependent startup behavior as configuration policies, route every runtime startup refusal through one exception parent, and never skip an event on a consumer's behalf."
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-09-10T01:20:59Z"
docId: ADR-8
status: Accepted
date: 2026-09-10
timestamp: "2026-09-10T01:20:59Z"
originatingPlan: docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md
---

# ADR-0008: Subscription configuration validates at construction and runtime refusals share one parent

- **Related:** [MasterPlan 12](../masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md);
  [ADR-2](0002-static-hash-partitioned-consumer-groups.md);
  [ADR-4](0004-explicit-subscription-checkpoint-lifecycle.md);
  [ExecPlan 81](../plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md);
  [ExecPlan 82](../plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size.md);
  [ExecPlan 83](../plans/83-contain-persistent-publisher-decode-hook-failures.md).

## Context

Kiroku's subscription surface grew one feature at a time. Configuration values such as batch
size, ack-stream buffer capacity, and the consumer-group member and size pair are plain integers
checked at runtime, some by `subscribe` throwing synchronously and some not at all. Behavior
that depends on stored state, such as what to do when no checkpoint exists, is declared through
`MissingCheckpointPolicy` on the configuration, which has worked well. Refusals discovered at
startup are separate exception types with no common parent, so a caller who wants to handle
"refused to start" must enumerate them. Elsewhere in the store,
`mkHistoryRetentionInventoryLimit` and `mkHistoryRetentionLeaseOwner` already validate values at
construction and return `Either` a typed error.

MasterPlan 12 adds several configuration values, two state-dependent startup behaviors, and two
startup refusals, and it introduces a store-wide decode hook whose failure is delivered per event.
The cohort is a deliberately breaking release toward 1.0, so the conventions it sets will be the
ones the 1.0 review audits.

## Decision

1. **Configuration values that can be invalid are validated at construction.** Each such value is
   a newtype whose constructor is not exported, built by a smart constructor that returns `Either`
   a typed error: `mkBatchSize`, `mkStreamBufferSize`, `mkConsumerGroupSize`, and
   `mkConsumerGroup`. The error types are values, not exceptions, and `subscribe` performs no
   configuration checks because none is possible.

2. **Startup behavior that depends on stored state is declared on the configuration as a policy.**
   `MissingCheckpointPolicy` is the precedent; `TargetBindingPolicy` follows it. A policy never
   moves a checkpoint silently: adoption of legacy rows is chosen by the caller and emits an
   observability event. Values that a migration can derive from existing rows, such as a
   consumer group's stored size, are derived in the migration rather than adopted at runtime.

3. **Every runtime startup refusal is an exception under one parent,** `SomeSubscriptionStartupFailure`,
   using the exception-hierarchy pattern of `SomeAsyncException`: each concrete type keeps its own
   `Exception` instance whose `toException` and `fromException` route through the parent, so
   existing handlers on concrete types keep working and a caller can catch the family once.

4. **The store never skips an event on a consumer's behalf.** A per-event failure the store
   detects but cannot resolve, such as an undecodable event, is handed to the consumer through
   the ordinary `SubscriptionResult` disposition vocabulary via an optional callback; without one,
   the worker retries briefly and stops the subscription with a typed reason, leaving the
   checkpoint before the event. Dead-lettering remains a consumer decision.

5. **Explicit checkpoint-set operations live together.** Reset, resize, and rebind are
   transaction-composable operations in `Kiroku.Store.Subscription.Checkpoint`, each returning a
   `...Report` value, as [ADR-4](0004-explicit-subscription-checkpoint-lifecycle.md) requires.

## Consequences

**Positive**

- Invalid configurations cannot reach a worker, a registry, or a pool checkout; the structural
  performance gate pins them as zero-checkout paths.
- Callers see two clearly separated failure kinds: `Either` values at construction and one
  catchable exception family at startup.
- No startup path moves a checkpoint or skips an event without a declared policy or an explicit
  consumer decision, which keeps ordering-sensitive read models sound.
- The conventions are already established elsewhere in the store, so the surface becomes more
  uniform rather than larger.

**Negative**

- Record-update construction of a configuration becomes slightly less convenient: a caller must
  thread `Either` results from the smart constructors before building the record.
- Changing `batchSize`, `bufferSize`, and `ConsumerGroup` construction is a breaking change for
  every caller, including the Shibuya adapter and Keiro; it is accepted only because the cohort
  is a breaking release toward 1.0.
- Regrouping `SubscriptionConfig` into policy sub-records is deliberately deferred to the 1.0 API
  review, so the record carries more fields until then.

## Alternatives Considered

- **Keep runtime checks in `subscribe` and add more exception types.** Rejected because it
  grows the startup failure surface without a rule, and because invalid values would still exist
  as Haskell values.
- **Adopt legacy rows implicitly on first start.** Rejected because implicit one-way transitions
  on startup are the class of silent behavior the initiative exists to remove; a declared policy
  with an emitted event is the same convenience made visible.
- **Dead-letter undecodable events automatically after retries.** Rejected because it advances
  the checkpoint past an event the consumer never processed, corrupting ordering-sensitive read
  models silently, and because a systemic hook failure would become a flood of skipped events.
- **A store-wide terminal publisher state after a fixed number of decode failures.** Rejected
  because it stops every subscriber for one consumer's problem and hides a magic constant.
