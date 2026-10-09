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
timestamp: "2026-10-09T22:49:20Z"
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

The reserved `$all` stream row records the authoritative append frontier: the greatest global
position allocated so far. Hard deletion can remove the event and `$all` junction at that position
without reducing the frontier. Kiroku therefore also exposes `visibleGlobalHeadPosition`, a
separate statement-time reachability observation of the greatest surviving `$all` junction. That
visible head can regress; the authoritative append frontier cannot.

## Decision

Resolve every worker's exact checkpoint key before `Started` or handler delivery through a closed
`MissingCheckpointPolicy`:

- `FromBeginning` inserts global position zero;
- `FromCurrentHead` reads and inserts the authoritative current append frontier in the same atomic
  database boundary; and
- `FailIfMissing` inserts nothing and returns a typed terminal startup failure.

An existing row always wins for all policies. Concurrent initializers converge on the first
committed row. Each consumer-group member resolves independently; Kiroku never infers or creates
group topology from another member.

`FromCurrentHead` deliberately does not use `visibleGlobalHeadPosition`. A future-only worker must
skip every position allocated before initialization, including positions already removed by hard
deletion, so it seeds the authoritative frontier. Callers that need a currently reachable wait or
backlog target may observe the visible head separately, but that separate statement does not share
the initialization transaction's snapshot.

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
- Atomic authoritative-frontier seeding makes every racing append either part of the durable seed
  or eligible for later delivery; there is no frontier-read/insert gap.
- The separate visible-head API lets reachability-oriented callers avoid waiting on a
  hard-deleted tail without weakening the future-only initialization boundary.
- Existing-row precedence prevents configuration changes from becoming accidental rewinds or
  fast-forwards.
- Reset reports every affected or absent identity and preserves Kiroku's ownership of the
  `subscriptions` table while remaining composable with a caller's transaction.

**Negative**

- Adding a field to `SubscriptionConfigM` and a constructor to the exported `Store` GADT requires a
  breaking source-compatibility cycle and updates to exhaustive record literals/interpreters.
- `FromBeginning` remains the compatibility default, so safety still depends on new services
  selecting a deliberate policy.
- The visible head is a separate statement-time observation and may regress after it is returned;
  it is not an atomic substitute for the frontier captured during `FromCurrentHead` initialization.
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

## Amendment: target binding and explicit rebind (2026-10-09)

Checkpoint identity includes the target shared by every member of a subscription
name. Store it as unindexed `target_kind` and `target_category` columns with CHECK
constraints; uniformly legacy rows remain `unbound` after migration 0014, which
drops the unused historical `stream_name`. Workers must be stopped for migration
and explicit reset, resize or rebind. The frozen public checkpoint relation is
unaffected. Plan 81 and ADR-2 supersede the original decision’s claim that stored
rows cannot encode topology; resize now owns explicit topology equalization.

Startup validates every sibling in the existing name-locked transaction and pool
checkout. `AdoptUnbound` atomically binds a uniformly unbound set and emits one
observable adoption event; `RequireBound` refuses it. Fresh rows are bound to the
requested target under either policy. Mixed or incompatible bindings refuse
startup before delivery. A missing exact key under `FailIfMissing` does not
adopt sibling rows. Ordinary saves remain one monotonic upsert without a
per-batch validation statement, index or extra checkout.

`rebindSubscriptionTargetTx` deliberately binds every existing member and resets
every cursor to the supplied position in the caller’s transaction. An absent
name fails that transaction. The report preserves distinct prior identities as
optional targets, including legacy or mixed sets, and records member count,
new target and position. Repeating the operation is idempotent; condemning the
transaction rolls back both identity and position. Resize preserves the target
on newly created members, and ordinary reset changes progress alone. Runtime
semantic startup refusals follow ADR-8’s exception hierarchy.
