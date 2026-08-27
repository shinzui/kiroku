---
id: 84
slug: harden-adapter-acknowledgement-liveness-and-expose-retry-policy
title: "Harden adapter acknowledgement liveness and expose retry policy"
kind: exec-plan
created_at: 2026-08-27T21:14:25Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Harden adapter acknowledgement liveness and expose retry policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`shibuya-kiroku-adapter` is acknowledgement-coupled: after yielding one event, the Kiroku worker
waits until Shibuya finalizes its `AckDecision`. Shibuya Core 0.9's standard runner already catches
a synchronous handler exception, substitutes `AckRetry (RetryDelay 0)`, and separately retries
finalization, but raw consumers of `adapter.source` can still leave the acknowledgement pending
forever. The adapter also cannot forward Kiroku's configurable retry-attempt policy.

After this plan, the recommended single-processor helper applies the existing paced exception
guard, raw or unusually slow consumers produce a typed pending-ack warning without changing the
decision, and both single and consumer-group configuration expose `RetryPolicy`. Tests distinguish
the supported runner's current non-wedging behavior from the structurally possible raw-source
wedge, then prove guarded retry, warning, and custom dead-letter counts.


## Progress

- [ ] M1: reproduce current Shibuya Core 0.9 exception/finalization behavior and the raw-source pending-ack case with bounded integration tests.
- [ ] M2: export `kirokuProcessor` as the recommended guarded single-processor path and correct module/user documentation.
- [ ] M2: add configurable, observability-only pending-ack warnings with shutdown-safe lifecycle tests.
- [ ] M3: expose and thread `retryPolicy` through single and consumer-group configs; prove default and custom delivery counts.
- [ ] Run adapter and relevant store suites; update living sections and perform ADR distillation.


## Surprises & Discoveries

- Transfer audit (2026-08-27): Mori-located `mori://shinzui/shibuya/packages/shibuya-core` is at
  the current 0.9 line. Its supervised `processOne` still catches handler exceptions as immediate
  retry decisions and calls `finalizeWithRetry` separately. The standard runner is not the
  unfinalized-ack path described by the July review.
- Transfer audit (2026-08-27): `guardKirokuHandler` and
  `kirokuConsumerGroupProcessors` already provide a one-second paced retry guard; the missing
  ergonomic surface is the equivalent recommended helper for a single `KirokuAdapterConfig`.


## Decision Log

- Decision: Preserve the structural acknowledgement wait and make its watchdog observability-only.
  Rationale: Auto-finalization races a slow correct handler and can turn a later `AckOk` into an
  unnecessary redelivery. A warning closes silent-liveness diagnostics without changing delivery
  semantics.
  Date: 2026-08-27

- Decision: Export `kirokuProcessor` rather than changing `kirokuAdapter` to own a handler.
  Rationale: An adapter is a source and does not receive the handler that a processor will run.
  The helper can compose `mkProcessor` with `guardKirokuHandler` while retaining the low-level raw
  adapter for advanced users.
  Date: 2026-08-27

- Decision: Add `retryPolicy` directly to both exported configuration records and default it to
  `defaultRetryPolicy`.
  Rationale: Both APIs already direct callers to extensible `default*Config` constructors. The
  policy is a Kiroku subscription concern and should pass through without an adapter-specific
  duplicate type.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` defines `KirokuAdapterConfig`,
`KirokuConsumerGroupConfig`, defaults, `kirokuAdapter`, `guardKirokuHandler`, and the
consumer-group processor factory. `kirokuAdapter` builds a store `SubscriptionConfig` but leaves
its `retryPolicy` at the Kiroku default. The group factory forwards most fields into one adapter
per member and automatically wraps its handler with `guardKirokuHandler`.

`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` implements `subscriptionAckStream`. Its
bridge writes an `AckItem` containing an empty `TMVar` and blocks on `takeTMVar`. In
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`, `toIngestedAck` creates an
idempotent first-wins finalizer with `tryPutTMVar`. If a consumer reads `adapter.source` and never
finalizes, the Kiroku worker remains blocked and can still appear `Live`.

The standard Shibuya runner dependency was located and read via Mori at
`mori://shinzui/shibuya/packages/shibuya-core`. Its current `processOne` and
`finalizeWithRetry` paths prevent an ordinary synchronous handler exception from abandoning the
ack, although the substituted zero-delay retry can be much faster than the adapter's one-second
guard.

`Kiroku.Store.Subscription.Types.RetryPolicy` counts total deliveries before dead-lettering.
`AckRetry (RetryDelay d)` chooses the delay before the next attempt; the two settings are
orthogonal. No current Kiroku ADR covers this adapter boundary. Create one only if implementation
introduces a durable cross-package contract beyond the documented configuration and warning
behavior.


## Plan of Work

### Milestone 1 — pin the two acknowledgement paths

In `shibuya-kiroku-adapter/test/Main.hs`, add a real-store test using `kirokuAdapter`,
`mkProcessor`, and `runApp` with a handler that throws synchronously on its first call. Assert the
current Shibuya Core behavior: the event is immediately redelivered, finalization occurs, and the
next event is eventually processed. Record actual attempts and timing in Surprises & Discoveries.

Add a separate raw-source test that reads one `Ingested` from `adapter.source` and intentionally
does not call its finalizer. Prove a second event is not delivered within a bounded window while
the subscription remains registered. This test owns the actual pending-ack hazard; do not conflate
it with the standard runner test.

### Milestone 2 — make the safe surface and stalled state visible

Export `kirokuProcessor` from `Shibuya.Adapter.Kiroku` with the same policy/concurrency arguments
required by the current `Shibuya.App.mkProcessor`, but always wrap the supplied handler in
`guardKirokuHandler`. Change single-adapter examples and `docs/user/shibuya-adapter.md` to use it.
Keep direct `kirokuAdapter` and `mkProcessor` use documented as advanced: Shibuya's standard runner
finalizes exceptions, while custom/raw consumers must finalize every item.

Add `ackPendingWarnAfter :: Maybe NominalDiffTime` to `KirokuAdapterConfig` and
`KirokuConsumerGroupConfig`, defaulting to `Just 60` seconds. Instrument `toIngestedAck` or a
narrow adapter wrapper so each outstanding event records subscription, event id, and monotonic
start time; wrapping the idempotent finalizer clears it. Start one watchdog per adapter, cancel it
during shutdown, and emit `KirokuEventAdapterAckPending` through the store's configured event
handler after the threshold and at most once per threshold interval. Never finalize from the
watchdog. Forward the setting to every group member.

Flip the raw-source test to expect the warning, and add shutdown plus finalize-before-threshold
tests. Add a guarded helper test in which a one-shot exception is retried after approximately one
second and processing continues.

### Milestone 3 — expose retry policy

Add `retryPolicy :: RetryPolicy` to both configs and both defaults. Thread it through
`kirokuAdapter` into `Sub.retryPolicy` and through the group factory to each member. Document that
`retryMaxAttempts` is total deliveries, while each `AckRetry` decides delay.

Extend the ack-disposition tests: the default still delivers five times before dead-lettering; a
single adapter configured for two attempts delivers exactly twice; a size-2 group forwards the
same policy to each member. Use zero-delay explicit decisions for counting tests and the guarded
one-second path only for the exception test.


## Concrete Steps

Run from the Kiroku repository root:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter-test \
  --test-show-details=direct \
  --test-options='--match "acknowledgement liveness|retry policy"'
```

The focused transcript must contain examples equivalent to:

```text
acknowledgement liveness
  standard Shibuya handler exceptions are finalized [OK]
  guarded single processor retries with pacing and continues [OK]
  raw unfinalized acknowledgement emits a pending warning [OK]
retry policy
  preserves five-delivery default [OK]
  honors two total deliveries for one adapter [OK]
  forwards policy to every consumer-group member [OK]
```

Then run:

```bash
cabal test shibuya-kiroku-adapter-test --test-show-details=direct
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```


## Validation and Acceptance

The standard current Shibuya pipeline must never be claimed to wedge on a synchronous handler
exception; its regression test must demonstrate finalization. The new `kirokuProcessor` path must
turn the same exception into a paced retry and continue. A deliberately unfinalized raw-source
item must produce `KirokuEventAdapterAckPending` within its configured threshold while remaining
unfinalized, and finalization or adapter shutdown must stop future warnings.

Changing `retryMaxAttempts` to two must yield exactly two deliveries and then one dead-letter row
on both the single and group paths. Defaults remain five. Full adapter and relevant store suites
must pass, and user documentation must explain raw-source responsibility, warning semantics, and
the difference between attempt policy and delay.


## Idempotence and Recovery

All tests use isolated databases and are repeatable. Warning emission is advisory and periodic;
it never writes an acknowledgement or checkpoint. Finalization remains first-wins and idempotent.
Watchdog shutdown must be safe to call repeatedly and must not outlive adapter shutdown.

Existing callers using `defaultKirokuAdapterConfig` or `defaultConsumerGroupConfig` inherit the
new fields. Full record literals require a source update and therefore affect the eventual PVP
release decision in plan 85. If warnings are too noisy, callers may tune the duration or set
`Nothing` without changing delivery semantics.


## Interfaces and Dependencies

`Shibuya.Adapter.Kiroku` exports `kirokuProcessor` with the exact current `mkProcessor` policy and
concurrency shape, plus these record fields on both relevant configs:

```haskell
retryPolicy :: RetryPolicy
ackPendingWarnAfter :: Maybe NominalDiffTime
```

`Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventAdapterAckPending
    :: SubscriptionName -> EventId -> NominalDiffTime -> KirokuEvent
```

Use `Data.Time.Clock` or the repository's existing monotonic-clock facility after checking its
current dependencies; do not introduce wall-clock ordering into tests. The Shibuya API source of
truth is `mori://shinzui/shibuya/packages/shibuya-core`. Plan 83 may also add an observability
constructor, so exhaustive matches must preserve both changes.
