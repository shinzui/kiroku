---
type: Architecture Decision Record
title: Subscription checkpoint initialization is explicit and reset is a separate transaction operation
description: "Resolve an absent exact subscription checkpoint through one of three atomic policies, preserve existing rows, keep ordinary saves monotonic, and expose rewind only as an exact transaction-composable reset."
generated:
  by: openai/gpt-5
  at: "2026-08-11T15:37:12Z"
docId: ADR-4
status: Accepted
date: 2026-08-11
timestamp: "2026-08-11T15:37:12Z"
---

# ADR-0004: Subscription checkpoint initialization is explicit and reset is a separate transaction operation

- **Related:** [ExecPlan 70](../plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit.md);
  [ADR-2](0002-static-hash-partitioned-consumer-groups.md);
  [ADR-3](0003-dedicated-kiroku-schema.md);
  `mori://shinzui/keiro/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release`.

## Context

A subscription checkpoint is durable progress for one exact
`(subscription_name, consumer_group_member)` key. Treating an absent row as position zero is useful
for a replayable projection, but unsafe for a newly deployed future-only worker that performs
external side effects. Conversely, changing a configuration must not silently move an existing
cursor.

Coordinating projection libraries also need to rewind several declared subscriptions in the same
transaction as their own fence and target preparation. If they issue private SQL, Kiroku loses
ownership of its schema and an update that affects no rows can be mistaken for success.

## Decision

Resolve every worker's exact checkpoint key before `Started` or handler delivery through a closed
`MissingCheckpointPolicy`:

- `FromBeginning` inserts global position zero;
- `FromCurrentHead` reads and inserts the current `$all` position in the same atomic database
  boundary; and
- `FailIfMissing` inserts nothing and returns a typed terminal startup failure.

An existing row always wins for all policies. Concurrent initializers converge on the first
committed row. Each consumer-group member resolves independently; Kiroku never infers or creates
group topology from another member.

Keep ordinary handler-driven checkpoint saves monotonic with `GREATEST(existing, requested)`.
Expose intentional position reassignment only as the separately named
`resetSubscriptionCheckpointsTx` operation. It treats requested names as a set, directly assigns the
target to every persisted member, creates no missing rows, and returns deterministically ordered
affected keys and missing names. The operation is a public `Hasql.Transaction.Transaction`
combinator while its statement remains Kiroku-internal, allowing callers to commit or condemn it
with application-owned SQL.

## Consequences

**Positive**

- Replayable, future-only, and pre-provisioned workers state their different safety intentions
  explicitly.
- Atomic current-head seeding makes every racing append either part of the durable seed or eligible
  for later delivery; there is no head-read/insert gap.
- Existing-row precedence prevents configuration changes from becoming accidental rewinds or
  fast-forwards.
- Reset reports every affected or absent identity and preserves Kiroku's ownership of the
  `subscriptions` table while remaining composable with a caller's transaction.

**Negative**

- Adding a field to `SubscriptionConfigM` and a constructor to the exported `Store` GADT requires a
  breaking source-compatibility cycle and updates to exhaustive record literals/interpreters.
- `FromBeginning` remains the compatibility default, so safety still depends on new services
  selecting a deliberate policy.
- Reset is destructive and intentionally bypasses normal monotonicity; callers must validate its
  report and condemn their surrounding transaction when missing names violate their contract.

## Alternatives Considered

- **Always treat absence as zero.** Rejected because a future-only side-effect worker could replay
  the entire retained log on first deployment, rename, or checkpoint loss.
- **Let the configured policy overwrite existing rows.** Rejected because a missing-row policy is
  not an operator-authorized progress mutation.
- **Implement rewind through the ordinary save statement.** Rejected because weakening
  `GREATEST(...)` would let stale worker writes move checkpoints backward accidentally.
- **Expose a raw statement or let downstream libraries update `subscriptions`.** Rejected because
  schema ownership, member expansion, ordering, and missing-name evidence belong to Kiroku.
- **Create rows for absent reset names from configured group size.** Rejected because checkpoint
  rows do not authoritatively encode current topology; invented members could claim work that never
  existed.
