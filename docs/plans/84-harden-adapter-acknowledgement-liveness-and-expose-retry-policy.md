---
id: 84
slug: harden-adapter-acknowledgement-liveness-and-expose-retry-policy
title: "Harden adapter acknowledgement liveness and expose retry policy"
kind: exec-plan
created_at: 2026-08-27T21:14:25Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: pending-ack must be one cell per adapter with a parked watchdog; overhead bench missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Single pending-ack cell with parked watchdog, overhead bench in steps and acceptance"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: stall watchdog moved into the store worker as handlerStallWarnAfter and KirokuEventSubscriptionHandlerStalled; adapter forwards the field"
---

# Harden adapter acknowledgement liveness and expose retry policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`shibuya-kiroku-adapter` is acknowledgement-coupled: after yielding one event, the Kiroku worker
waits inside its handler call until Shibuya finalizes its `AckDecision`. Shibuya Core 0.9's
standard runner already catches a synchronous handler exception, substitutes
`AckRetry (RetryDelay 0)`, and separately retries finalization, but raw consumers of
`adapter.source` can still leave the acknowledgement pending forever, and a bare Kiroku subscriber
whose handler blocks has exactly the same silent-liveness problem. The adapter also cannot forward
Kiroku's configurable retry-attempt policy.

After this plan, the store worker itself reports a handler that has held one event longer than a
configured threshold, for every subscriber kind, through a typed
`KirokuEventSubscriptionHandlerStalled` event; the recommended single-processor helper applies the
existing paced exception guard; and both single and consumer-group adapter configuration expose
`RetryPolicy` and forward the stall threshold. Tests distinguish the supported runner's current
non-wedging behavior from the structurally possible raw-source wedge, then prove guarded retry,
the stall event on both the raw adapter path and a bare subscription, and custom dead-letter
counts.


## Progress

- [ ] M1: reproduce current Shibuya Core 0.9 exception/finalization behavior and the raw-source pending-ack case with bounded integration tests.
- [ ] M2: export `kirokuProcessor` as the recommended guarded single-processor path and correct module/user documentation.
- [ ] M2: add `handlerStallWarnAfter` to `SubscriptionConfigM` with a single-cell, parked watchdog in the store worker emitting `KirokuEventSubscriptionHandlerStalled`; forward the field from both adapter configs.
- [ ] M3: expose and thread `retryPolicy` through single and consumer-group configs; prove default and custom delivery counts.
- [ ] Run adapter and store suites plus the overhead benchmark; update living sections and perform ADR distillation.


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
  Location moved on 2026-09-09: the watchdog lives in the store worker; the observability-only
  rule is unchanged.

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

- Decision: Track the pending acknowledgement in one mutable cell per adapter, clear it inside the
  finalizer's existing STM transaction, and park the watchdog on STM until an item is pending.
  Rationale: The bridge is acknowledgement-coupled, so at most one event is outstanding per
  adapter; a map or a polling thread would add allocation and wake-ups to every event for no
  information. Fixed by the 2026-09-09 performance review under
  [ADR-5](../adr/0005-three-tier-performance-regression-gates.md).
  Date: 2026-09-09
  Superseded later on 2026-09-09: the cell is one per worker, not one per adapter; the budget is
  unchanged.

- Decision: Implement the stall watchdog in the store worker around the handler call in
  `processEvents`, configured by `handlerStallWarnAfter` on `SubscriptionConfigM`, and have the
  adapter only forward that field.
  Rationale: A pending acknowledgement is a handler that has held one event too long, and a bare
  `subscribe` handler that blocks has the same problem. One worker-level cell and event serve
  every subscriber kind, and the store's observability vocabulary stays free of adapter-specific
  constructors. The single-cell, parked-thread budget from the performance review is unchanged;
  it moves one level down.
  Date: 2026-09-09


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
bridge handler writes an `AckItem` containing an empty `TMVar` and blocks on `takeTMVar`; that
handler is the `handler config event` call inside `processEvents` in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, so while an acknowledgement is pending the
worker is blocked inside its own delivery primitive. In
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`, `toIngestedAck` creates an
idempotent first-wins finalizer with `tryPutTMVar`. If a consumer reads `adapter.source` and never
finalizes, the worker remains blocked and can still appear `Live`. A bare `subscribe` caller whose
handler blocks is indistinguishable from the store's point of view, which is why the watchdog
belongs around the handler call rather than in the adapter.

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

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
authoritative for performance evidence, and the `kiroku-shibuya-overhead` benchmark in
`kiroku-store/bench/ShibuyaOverhead.hs` measures the adapter layer against `subscriptionStream`
on the same store, which is exactly the bridge this plan instruments.


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

Add `handlerStallWarnAfter :: Maybe NominalDiffTime` to `SubscriptionConfigM` in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, defaulting to `Just 60` seconds in
`defaultSubscriptionConfig`. In `Worker.hs`, give each worker one `TVar (Maybe StalledDelivery)`
holding the event position and id and a monotonic start time. `processEvents` writes the cell
immediately before `handler config event` and clears it immediately after, in the same code path
for every target and both phases. Start one watchdog thread per worker alongside the existing
worker body so cancellation covers it; it blocks on the cell with STM `retry` while empty, then
waits the threshold with `registerDelay`, and if the same delivery is still pending emits
`KirokuEventSubscriptionHandlerStalled` through the worker's event handler with the elapsed time,
at most once per threshold interval. It never finalizes, never touches the checkpoint, and never
polls on a fixed interval. When the setting is `Nothing`, no thread is started and the cell is
never written.

In the adapter, add `handlerStallWarnAfter` to `KirokuAdapterConfig` and
`KirokuConsumerGroupConfig` with the same default, and forward it into the store
`SubscriptionConfig` for the single adapter and for every group member. The adapter adds no
watchdog and no observability constructor of its own.

Flip the raw-source test to expect `KirokuEventSubscriptionHandlerStalled`, add a store-side test
under `kiroku-store/test` in which a bare `subscribe` handler blocks past a short threshold and the
event is emitted once, and add shutdown plus finalize-before-threshold tests proving no event and
no leaked thread. Add a guarded helper test in which a one-shot exception is retried after
approximately one second and processing continues.

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
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "handler stall"'
```

The focused transcripts must contain examples equivalent to:

```text
acknowledgement liveness
  standard Shibuya handler exceptions are finalized [OK]
  guarded single processor retries with pacing and continues [OK]
  raw unfinalized acknowledgement surfaces as a handler-stall event [OK]
retry policy
  preserves five-delivery default [OK]
  honors two total deliveries for one adapter [OK]
  forwards policy to every consumer-group member [OK]
handler stall
  emits once when a bare subscribe handler blocks past the threshold [OK]
  emits nothing when the handler finishes before the threshold or the worker stops [OK]
```

Then run:

```bash
cabal test shibuya-kiroku-adapter-test --test-show-details=direct
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

Run the overhead benchmark once on the unchanged tree before milestone 2 and once after milestone
3, and record the adapter-versus-`subscriptionStream` overhead and the bare-subscribe figure from
both runs in Surprises & Discoveries.

```bash
cabal bench kiroku-store:kiroku-shibuya-overhead
```


## Validation and Acceptance

The standard current Shibuya pipeline must never be claimed to wedge on a synchronous handler
exception; its regression test must demonstrate finalization. The new `kirokuProcessor` path must
turn the same exception into a paced retry and continue. A deliberately unfinalized raw-source
item must produce `KirokuEventSubscriptionHandlerStalled` from the store worker within its
configured threshold while remaining unfinalized, a blocking bare `subscribe` handler must produce
the same event, and finalization, handler completion, or worker shutdown must stop future
emissions.

Changing `retryMaxAttempts` to two must yield exactly two deliveries and then one dead-letter row
on both the single and group paths. Defaults remain five. Full adapter and relevant store suites
must pass, and user documentation must explain raw-source responsibility, stall-event semantics,
and the difference between attempt policy and delay. Both layers of `kiroku-shibuya-overhead`
must show no corroborated slowdown against the pre-change run.


## Idempotence and Recovery

All tests use isolated databases and are repeatable. Warning emission is advisory and periodic;
it never writes an acknowledgement or checkpoint. Finalization remains first-wins and idempotent.
Watchdog shutdown must be safe to call repeatedly and must not outlive the worker it belongs to.

Existing callers using `defaultKirokuAdapterConfig` or `defaultConsumerGroupConfig` inherit the
new fields. Full record literals require a source update and therefore affect the eventual PVP
release decision in plan 85. If stall events are too noisy, callers may tune the duration or set
`Nothing` without changing delivery semantics.


## Interfaces and Dependencies

`Shibuya.Adapter.Kiroku` exports `kirokuProcessor` with the exact current `mkProcessor` policy and
concurrency shape, plus these record fields on both relevant configs, each forwarded unchanged to
the store:

```haskell
retryPolicy :: RetryPolicy
handlerStallWarnAfter :: Maybe NominalDiffTime
```

`Kiroku.Store.Subscription.Types.SubscriptionConfigM` gains the same
`handlerStallWarnAfter :: Maybe NominalDiffTime` field, and
`Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventSubscriptionHandlerStalled
    :: SubscriptionName
    -> GlobalPosition
    -> EventId
    -> NominalDiffTime
    -> SubscriptionGroupContext
    -> KirokuEvent
```

Use `GHC.Clock.getMonotonicTime` from `base` for the start time; do not introduce wall-clock
ordering into tests. The Shibuya API source of truth is
`mori://shinzui/shibuya/packages/shibuya-core`. Plan 83 changes `RetryPolicy` to a record with
`decodeRetryDelay` and adds its own observability constructor; forward the whole `RetryPolicy`
value so the new field passes through, and preserve both constructors in exhaustive matches. Plans
82 and 83 also edit `Worker.hs`; keep the stall cell writes confined to the two lines around the
handler call.

Revision note (2026-09-09): Performance review under ADR-5. Fixed the pending-ack record to one
cell per adapter cleared in the finalizer's existing STM transaction with a parked, non-polling
watchdog, and added the `kiroku-shibuya-overhead` before/after run to the concrete steps and
acceptance.

Revision note (2026-09-09): Design review. Moved the stall watchdog from the adapter into the store
worker as `handlerStallWarnAfter` plus `KirokuEventSubscriptionHandlerStalled`, so bare
subscriptions, the ack stream, and the adapter share one event and the store's vocabulary carries
no adapter-specific constructor; the adapter now forwards the field. The per-adapter cell decision
from the morning performance review is marked superseded. Title and file name are retained for
reference stability.
