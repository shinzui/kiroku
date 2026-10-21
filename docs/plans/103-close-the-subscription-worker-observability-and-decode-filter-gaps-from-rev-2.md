---
id: 103
slug: close-the-subscription-worker-observability-and-decode-filter-gaps-from-rev-2
title: "Close the subscription worker observability and decode-filter gaps from REV-2"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
---

# Close the subscription worker observability and decode-filter gaps from REV-2

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Review REV-2 (`docs/reviews/kiroku-0-10-subscription-hardening-cohort.md`) accepted
the subscription hardening shipped in kiroku-store 0.10.0.0 as correct but recorded
five gaps an operator or integrator would trip over. Two are observability: a worker
refused for an invalid `handlerStallWarnAfter` emits no `Stopped` event, and a target
binding mismatch has no dedicated observer event, unlike a size mismatch. One is a
consistency gap in decode handling: the first delivery pass applies the event-type
filter to the raw event for undecodable events but the retry pass applies it to the
decoded event, so a retry can change an event's disposition. One is a footgun: the
low-level `initializeSubscriptionCheckpoint` effect still writes size-1 `unbound` rows,
so calling it for a member of a bound group breaks that member's next start. One is
documentation: the topology lock protects concurrent starters but not a running
member, whose next save overwrites a resize or rebind made while it ran.

After this plan an operator sees a `Stopped` event for every startup refusal and a
typed event for a target mismatch, the filter decision for an event is the same on
every attempt, the low-level initializer adopts an existing group's topology instead of
corrupting it, and the guides say plainly what the lock does not protect.


## Progress

- [ ] Milestone 1: an invalid `handlerStallWarnAfter` produces `KirokuEventSubscriptionStopped` with `StopWorkerCrashed` before `wait` surfaces the refusal, and `KirokuEventSubscriptionTargetMismatch` is emitted for a binding refusal; kiroku-metrics and kiroku-otel handle the new constructor; tests in `HandlerStall.hs` and `SubscriptionTarget.hs` assert the events.
- [ ] Milestone 2: the retry path filters on the same event the first pass filtered on, a test with a type-rewriting hook pins the behaviour, and `docs/user/subscriptions.md` and ADR-12 state the raw-versus-decoded filter rule and the `Stop` disposition's checkpoint effect.
- [ ] Milestone 3: `initializeSubscriptionCheckpoint` for a name that already has rows adopts their `consumer_group_size`, `target_kind` and `target_category`, a test proves a bound group's member can start after it, and the consumer-group and subscription guides document the running-worker caveat.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Add `KirokuEventSubscriptionTargetMismatch` as a new `KirokuEvent`
  constructor rather than reusing an existing one.
  Rationale: Operators filter on constructors; a mismatch hidden inside
  `StopWorkerCrashed` is invisible to the metrics collector and the OpenTelemetry
  tracer. The constructor breaks exhaustive matches, so this ships in a kiroku-store
  major version (0.12.0.0) with kiroku-metrics and kiroku-otel bumps, and the changelog
  says so.
  Date: 2026-10-21
- Decision: Keep ADR-12's rule that filtered-out raw events bypass the undecodable
  callback; make the retry path consistent with it rather than changing the first pass.
  Rationale: ADR-12 chose raw-event filtering deliberately; the defect is that retries
  disagree with it. Changing the rule would alter delivery for every consumer with a
  filter.
  Date: 2026-10-21
- Decision: The low-level initializer adopts sibling topology instead of refusing.
  Rationale: Its return type `Either SubscriptionCheckpointMissing CheckpointInitialization`
  has no refusal case, and adding one is a break; adopting the rows' size and binding
  removes the footgun without changing the type. A name with no rows keeps today's
  size-1 `unbound` behaviour.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL event store in Haskell. A subscription worker is the thread
`Kiroku.Store.Subscription.Worker` runs for each subscription; it loads its checkpoint,
catches up from the database, switches to live delivery, and reports its lifecycle
through `KirokuEvent` values (`kiroku-store/src/Kiroku/Store/Observability.hs`) passed
to the store's event handler. Exhaustive consumers of `KirokuEvent` in this repository
are `kiroku-metrics/src/Kiroku/Metrics/Collector.hs` and
`kiroku-otel/src/Kiroku/Otel/Subscription.hs`; downstream exhaustive matchers are found
with `mori registry dependents shinzui/kiroku --packages`.

In `Worker.hs`: `withHandlerStallDiagnostics` (lines 249 to 263) throws
`InvalidHandlerStallWarnAfter` when the interval is not positive, before
`runWorkerBody` is entered; `runWorkerBody` wraps the body in `try` (around line 499)
and emits `KirokuEventSubscriptionStopped subName pos (classifyStopReason e) groupCtx`
for any exception, so refusals raised inside it are observable and this one is not.
The checkpoint load (lines 578 to 596) converts `SomeSubscriptionStartupFailure` to a
throw and emits `KirokuEventSubscriptionGroupSizeMismatch` only for the size case; a
`SubscriptionTargetMismatch` reaches the operator only inside `StopWorkerCrashed`.
Delivery is `processEvents`: `walk` (lines 817 to 836) applies
`shouldDeliver (eventTypeFilter config) (selector config) event` to `rawOf item`, where
`rawOf = decodedEventRecorded` returns the hook's output for `Decoded` and the raw
event for `Undecodable`; `dispatch` (843 to 853) handles the undecodable branch; and
`retryDecode` (855 onward) re-applies the hook and, on success, filters on the decoded
event (`Decoded event | not (shouldDeliver ... event) -> pure True`). The test
`Test/PublisherCallbackResilience.hs` "does not apply an undecodable disposition to an
explicitly filtered-out event" pins the raw-excluded case; `Test/HandlerStall.hs` line
250 asserts the typed `InvalidHandlerStallWarnAfter` from `wait`;
`Test/SubscriptionTarget.hs` covers binding policies.

The low-level initializer is the `InitializeSubscriptionCheckpoint` constructor of the
`Store` effect (`kiroku-store/src/Kiroku/Store/Effect.hs` lines 175 to 179 and 442 to
444), interpreted by `Kiroku.Store.Subscription.Checkpoint.SQL.initializeSubscriptionCheckpointSession`,
which calls `initializeCheckpointWith ... 1 Nothing` (size 1, unbound). The topology
lock and verification used by workers live in the same module
(`initializeWorkerCheckpointSession`, with `pg_advisory_xact_lock` on a per-name key).
`SubscriptionTargetMismatch` and `ConsumerGroupSizeMismatch` are defined in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`.

Documentation: `docs/user/subscriptions.md` (decode hooks, undecodable handler,
dispositions), `docs/user/consumer-groups.md` ("Operational Invariant" at line 114 and
"Resizing The Group" at 146), `docs/user/observability.md` (the `KirokuEvent`
catalogue), and `docs/user/metrics.md` where the collector's counters are listed.

Relevant ADRs: [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
(every runtime startup refusal is an exception under one parent; the store never skips
an event on a consumer's behalf; checkpoint-set operations live together),
[ADR-12](../adr/0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md)
(filtered-out raw events bypass the callback; `Stop` checkpoints the event; the
default path stops before it), and
[ADR-13](../adr/0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md)
(nonpositive intervals fail before checkpoint initialization under the shared parent).
Milestone 2 adds one sentence to ADR-12; milestone 1 does not change ADR-13's rule, only
makes the refusal observable. No cross-repository ADR applies.


## Plan of Work

Milestone 1 makes refusals observable. Move the `InvalidHandlerStallWarnAfter` check so
it runs inside the region `runWorkerBody` observes, or emit
`KirokuEventSubscriptionStopped` with `StopWorkerCrashed` explicitly before throwing;
either way the event carries the worker's name, position 0 and group context, and the
exception still surfaces from `wait` as today so the `HandlerStall.hs` assertion keeps
passing. Add `KirokuEventSubscriptionTargetMismatch !SubscriptionTargetMismatch
!SubscriptionGroupContext` next to the size-mismatch constructor in `Observability.hs`,
emit it in the checkpoint-load branch where the size case is handled, extend the
collector in kiroku-metrics (count it with the other startup refusals) and the tracer in
kiroku-otel (set the same stop attributes it sets for a size mismatch), and document it
in `docs/user/observability.md`. Tests: extend the `HandlerStall.hs` case to collect
events and assert the `Stopped` event; add a `SubscriptionTarget.hs` case asserting the
new event on a binding refusal.

Milestone 2 makes filtering consistent. In `retryDecode`, drop the decoded-event
filter and instead rely on the decision `walk` already made for the raw event, so a
retry either delivers the decoded event or continues the undecodable path, never
silently skips. Add a test to `PublisherCallbackResilience.hs` with a hook that rewrites
`OrderCreatedV1` into `OrderCreatedV2` and a filter on `OrderCreatedV2`: a decodable
V1 event is delivered as V2; an undecodable V1 event is filtered out on its raw type and
skipped without calling the callback, with the checkpoint advancing, exactly as ADR-12
states; and a retry of an undecodable event whose raw type is inside the filter reaches
the callback on every attempt. Add one sentence to ADR-12 making the rule explicit
("the filter decision is taken once, on the hook's output for decodable events and on
the raw event otherwise, and does not change across retries"), bump its timestamp, add
the log entry and validate strictly. In `docs/user/subscriptions.md` add the same rule
and a warning that a type-rewriting hook should keep raw types in the filter, and make
the `Stop` disposition's effect explicit: it checkpoints past the event, so a callback
that wants to investigate an event later should use `Retry` with a delay or
`DeadLetter`, not `Stop`.

Milestone 3 removes the initializer footgun and documents the lock. Change
`initializeSubscriptionCheckpointSession` so that, inside the same session, it first
reads any existing rows for the name and, when they exist, passes their
`consumer_group_size` and binding to `initializeCheckpointWith` instead of `1` and
`Nothing`; when rows disagree among themselves, keep today's behaviour and let the
worker's verification refuse later. Add a case to
`Test/SubscriptionCheckpointInitialization.hs`: provision a bound size-2 group through
resize, call `initializeSubscriptionCheckpoint` for a member, start that member, and
assert it starts rather than refusing. In `docs/user/consumer-groups.md`
"Operational Invariant" and in `subscriptions.md` state that the per-name lock
serializes starting workers and lifecycle mutations against each other, that a member
already running is not stopped by it, and that its next save writes its own size and
binding and advances its position, so resize, rebind and reset are correct only with
every member stopped. Draft the `## Unreleased` changelog entries for kiroku-store
(breaking: new `KirokuEvent` constructor; bug fixes: refusal observability, consistent
filtering, initializer adoption), kiroku-metrics and kiroku-otel (handle the new
constructor).


## Concrete Steps

All commands run from the repository root.

```bash
cabal build all
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "stall"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "target"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "undecodable"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "initializ"'
```

Each focused group must show the new cases passing; before the change, the new cases
fail with messages like:

```text
  emits a Stopped event for an invalid stall interval [✘]
    expected: one KirokuEventSubscriptionStopped with StopWorkerCrashed
     but got: []
```

Then the whole repository, because the new constructor touches three packages:

```bash
cabal test all
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
```


## Validation and Acceptance

Milestone 1 is accepted when the two new tests pass, `kiroku-metrics` and `kiroku-otel`
compile and their suites pass with the new constructor, and `docs/user/observability.md`
lists it. Milestone 2 is accepted when the type-rewriting hook test passes in all three
of its scenarios, ADR-12 validates strictly after the added sentence, and the user guide
carries the filter rule and the `Stop` warning. Milestone 3 is accepted when the
initializer test shows a bound group's member starting after the low-level call, the
full suite passes, and both guides carry the running-worker caveat. The
performance tier must be unchanged: `just perf-structure` passes and no change in this
plan touches an append, read or per-batch statement, which the implementer confirms by
reading the diff of `Kiroku.Store.SQL` and `Checkpoint/SQL.hs` (the initializer change
adds one read on a startup-only path).

Proposed, not required: a typed refusal for `rebindSubscriptionTargetTx` on an absent
name, which today fails with hasql's `UnexpectedAmountOfRows`; it changes the function's
error contract and is left for a later decision.


## Idempotence and Recovery

Code changes are small and local; tests run on ephemeral databases and can be repeated.
The ADR amendment and guide edits are additive. If the new constructor breaks a
downstream package found by `mori registry dependents`, record it under Surprises and
coordinate the bump; nothing here changes a database.


## Interfaces and Dependencies

`Kiroku.Store.Observability.KirokuEvent` gains
`KirokuEventSubscriptionTargetMismatch !SubscriptionTargetMismatch !SubscriptionGroupContext`
(kiroku-store 0.12.0.0). `Kiroku.Store.Subscription.Worker` changes internally only.
`Kiroku.Store.Subscription.Checkpoint.SQL.initializeSubscriptionCheckpointSession`
keeps its type. `Kiroku.Metrics.Collector` and `Kiroku.Otel.Subscription` must match
the new constructor. ADR-12 and the user guides change text. Plan 102 owns the errata
for already-published entries; this plan writes only `## Unreleased` entries.
