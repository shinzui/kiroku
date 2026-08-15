---
type: Improvement Request
title: Make missing subscription checkpoints explicit and support safe lifecycle mutations
description: >-
  Give each subscription an explicit atomic policy for a missing checkpoint and expose supported
  transactional checkpoint reset operations, so future-only workers cannot replay historical
  side effects and coordinating libraries do not write Kiroku-owned tables directly.
generated:
  by: openai/gpt-5
  at: "2026-08-11T15:41:42Z"
timestamp: "2026-08-11T15:41:42Z"
requestId: IR-3
status: completed
completedAt: "2026-08-15T14:12:26Z"
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-09T17:49:15Z"
    document_timestamp: "2026-08-09T17:49:15Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against kiroku-store 0.4.0.0 and current master, Keiro's post-0.11 projection
      catalog, and the migration evidence in
      mori://shinzui/mori/plans/215-restore-the-seven-registration-read-models-dropped-by-the-functional-rewrite.
      A missing worker checkpoint currently becomes global position zero, while Keiro's group
      rebuild updates Kiroku's subscriptions table through private SQL and cannot detect a missing
      declared identity.
verified:
  by: process:codex
  at: "2026-08-11T15:41:42Z"
---

# Improvement Request: Make Missing Subscription Checkpoints Explicit and Support Safe Lifecycle Mutations

## Status

Completed. Implemented in Kiroku repository source by
`mori://shinzui/kiroku/plans/70-make-subscription-checkpoint-initialization-and-reset-semantics-explicit`.
The three startup policies, typed resolution/refusal events, and transaction-composable exact reset
are covered by the store, adapter, mock, concurrency, rollback, and monotonicity suites.
`kiroku-store` 0.5.0.0 published the API to Hackage on 2026-08-11, and 0.7.0.0 carries it forward.
Keiro adopted it under
`mori://shinzui/keiro/masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release`,
which records the initiative as complete, and shipped that downstream cohort as Keiro 0.12.0.0.

## Context

`kiroku-store` persists one checkpoint for each `(subscription_name,
consumer_group_member)` pair. On worker startup, `loadCheckpoint` reads that key and returns
`GlobalPosition 0` when no row exists. This is correct for a replayable projection that needs all
retained history, but it is unsafe for a future-only worker that performs an external side effect:
adding the worker to a populated store, changing its name, or losing its checkpoint can replay the
entire event log as if every event were new.

The public inventory completed by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` deliberately remains read-only. It
shows that a row is absent but cannot say whether startup should begin at zero, seed the current
store head, or fail. Applications that need the latter two behaviors currently have no supported
atomic API and are tempted to insert Kiroku-owned rows themselves.

Keiro's post-0.11 projection-catalog rebuild has the complementary ownership violation. It must
rewind every persisted member of selected subscription names in the same database transaction as
projection fencing and target preparation, but it currently executes a private `UPDATE
subscriptions`. That update silently affects zero rows when a declared subscription has never
persisted a checkpoint. Kiroku owns the table and the monotonic ordinary save rule; Keiro should
consume a public transaction combinator and decide how a missing-name report affects the rebuild.

## Requested Change

Add a closed `MissingCheckpointPolicy` to `SubscriptionConfigM` and require the worker to resolve
the policy atomically before it can deliver an event. The compatibility default remains
`FromBeginning`, but every new service should set the field deliberately. The closed choices are:

1. `FromBeginning`: when the key is absent, insert a durable checkpoint at global position zero and
   start there;
2. `FromCurrentHead`: when the key is absent, capture the `$all` stream's current global position,
   insert that exact value, and start there; and
3. `FailIfMissing`: when the key is absent, return a typed failure and stop before invoking the
   handler.

An existing checkpoint always wins. A deployment may change its configured policy without moving
an existing cursor; resetting, deleting, or reinterpreting a persisted checkpoint remains a
separate operator action. Initialization must use one PostgreSQL statement or one transaction that
both selects the starting value and inserts the absent key, so concurrent appends cannot fall into
an unacknowledged gap between head capture and checkpoint creation. The key includes the actual
consumer-group member; non-group subscriptions continue to use member zero.

Expose the initialization contract through the mockable `Store` effect as well as the concrete
worker path. Return a value that distinguishes an existing checkpoint from a newly initialized
one, including the chosen position and key. Expose a typed `SubscriptionCheckpointMissing` failure
for `FailIfMissing`, and emit enough lifecycle telemetry to distinguish existing, beginning-seeded,
head-seeded, and refused startup without logging event payloads.

Also expose a public `Hasql.Transaction.Transaction` combinator that rewinds every existing member
row for a non-empty set of `SubscriptionName` values to one caller-supplied `GlobalPosition`. This
operation is intentionally separate from the monotonic ordinary checkpoint save. It must return a
deterministically ordered report containing every reset `(name, member)` key and every requested
name for which no row existed. It must never invent consumer-group members, infer topology from
member zero, or silently claim that an absent name was reset. A coordinating library such as Keiro
can compose the combinator into a larger transaction and condemn that transaction when the missing
set violates its own catalog contract.

One possible public shape is:

```haskell
data MissingCheckpointPolicy
    = FromBeginning
    | FromCurrentHead
    | FailIfMissing

data CheckpointInitialization
    = ExistingCheckpoint SubscriptionCheckpointKey GlobalPosition
    | InitializedCheckpoint MissingCheckpointPolicy SubscriptionCheckpointKey GlobalPosition

initializeSubscriptionCheckpoint ::
    (HasCallStack, Store :> es) =>
    SubscriptionName ->
    Int32 ->
    MissingCheckpointPolicy ->
    Eff es (Either SubscriptionCheckpointMissing CheckpointInitialization)

resetSubscriptionCheckpointsTx ::
    NonEmpty SubscriptionName ->
    GlobalPosition ->
    Tx.Transaction SubscriptionCheckpointResetReport
```

The final module and constructor names belong to Kiroku, but the three policies, existing-row
precedence, atomic head seeding, exact member key, and explicit missing-name reset report are part
of the requested contract.

## Boundaries

This request does not let arbitrary callers delete checkpoint rows, move one checkpoint forward,
or bypass the worker's at-least-once protocol. Ordinary handler-driven checkpoint writes remain
monotonic and member-aware. Rewind is exposed only as an explicitly named transaction combinator
whose result makes every affected or absent identity visible.

The request does not make Kiroku understand projection catalogs, projection targets, replay
adapters, or whether a missing checkpoint should abort a coordinated rebuild. Keiro owns those
decisions. Kiroku owns the checkpoint key, storage schema, SQL, initialization atomicity, and reset
report.

No schema migration is required merely to initialize or reset existing checkpoint rows. If
implementation discovers that durable policy provenance must be stored, that is a design change:
update the plan and record the schema decision in a Kiroku ADR rather than adding a column
incidentally.

## Acceptance

1. On an empty store, `FromBeginning` atomically creates `(name, member)` at position zero and the
   handler sees no historical event before that initialization is durable.
2. On a populated store, `FromCurrentHead` atomically stores the captured head and delivers only
   events appended after that position, including when appends race worker startup.
3. `FailIfMissing` produces a typed terminal startup failure before the handler runs and creates no
   row.
4. For all three policies, an existing row is returned unchanged and processing resumes from it.
5. Two concurrent initializers for the same key converge on one persisted checkpoint; neither can
   overwrite an already selected position with a later policy result.
6. Non-group and consumer-group members use the same structured key behavior, and initializing one
   member never creates or moves another member.
7. Resetting several names in one surrounding transaction moves every existing member row to the
   requested position, reports exact affected keys and missing names, and rolls back with the
   caller's other SQL when that transaction is condemned.
8. Ordinary save remains monotonic after initialization or reset; the reset combinator is the only
   new supported rewind path.
9. The concrete pool interpreter, resource interpreter, worker entry points, `Store` mock examples,
   Shibuya adapter, Haddocks, and subscription guide agree on the policy semantics.
10. The change is classified as a breaking `kiroku-store` API cycle because the exported `Store`
    GADT and `SubscriptionConfigM` record gain constructors or fields; all in-repository dependents
    are compiled together before any package is released.
