---
title: "Explicit subscription checkpoint lifecycle"
type: Capability
description: "Resolve absent subscription checkpoints by an explicit atomic policy and compose exact multi-name checkpoint resets with application-owned SQL in one transaction."
generated:
  by: openai/gpt-5
  at: "2026-08-11T15:41:42Z"
capabilityId: CAP-20
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "unreleased"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Subscription
  - Kiroku.Store.Subscription.Checkpoint
  - Kiroku.Store.Subscription.Types
requires:
  - CAP-6
  - CAP-11
evidence:
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionCheckpointInitialization.hs
    proves: All three missing-checkpoint policies, existing-row precedence, member isolation, and concurrent initialization convergence against PostgreSQL.
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionCheckpointWorker.hs
    proves: Real workers form a clean future-only cut at an atomically seeded current head across native, Effectful, Streamly, and consumer-group entry points.
  - kind: test
    resource: kiroku-store/test/Test/SubscriptionCheckpointReset.hs
    proves: Exact sorted reset evidence, missing-name reporting, application-write rollback under Tx.condemn, explicit rewind, and ordinary-save monotonicity.
  - kind: guide
    resource: docs/user/subscriptions.md
    proves: Policy selection for replayable and future-only workers plus transaction-composable reset usage and safety boundaries.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-11T15:41:42Z"
    document_timestamp: "2026-08-11T15:41:42Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against the public types and owned SQL, focused initialization/worker/reset suites,
      full repository build and tests, Haddock output, and the explicit startup/reset user guide.
---

# Explicit subscription checkpoint lifecycle

Choose what an absent exact `(subscription name, consumer-group member)` checkpoint means before a
worker can deliver an event. `FromBeginning` durably seeds zero, `FromCurrentHead` atomically seeds
the current `$all` position, and `FailIfMissing` refuses startup with a typed failure. Existing rows
always win, so changing policy is never an implicit reset.

For coordinated projection rebuilds, `resetSubscriptionCheckpointsTx` assigns one exact position to
every persisted member of a non-empty subscription-name set and returns sorted affected keys plus
sorted requested names with no rows. It is a `Hasql.Transaction.Transaction` combinator, so the
reset commits or rolls back with application-owned fence and target-table writes without exposing
Kiroku's private statement.

## Usage

```haskell
let config =
      (defaultSubscriptionConfig name AllStreams handler)
        { missingCheckpointPolicy = FromCurrentHead }

report <- runTransaction $
  resetSubscriptionCheckpointsTx (name :| otherNames) targetPosition
```

## Limits

- Policy is consulted only for an absent exact member key; it does not move or reinterpret an
  existing row.
- Reset updates persisted members only. It does not create absent names, infer a consumer-group
  size, or invent member rows.
- Reset is intentionally non-monotonic. Ordinary worker saves retain their separate
  `GREATEST(...)` monotonicity rule.
- The capability is implemented in repository source but not yet published; its final package
  version is deferred to the coordinated downstream release cycle.
