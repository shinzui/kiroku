---
id: 83
slug: contain-persistent-publisher-decode-hook-failures
title: "Contain persistent publisher decode-hook failures"
kind: exec-plan
created_at: 2026-08-27T21:14:24Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: signal terminal failure via SubscriberStatus not a queue item type; overhead bench and perf-check missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Terminal signal via SubscriberStatus, tick-paced retry cadence discovery, overhead bench and perf-check in steps and acceptance"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: typed per-event decode contract with retry and DeadLetterDecodeFailure replaces attempt budget and terminal publisher state"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: undecodableHandler callback with retry-then-StopUndecodable default replaces automatic dead-lettering; RetryPolicy unchanged"
---

# Contain persistent publisher decode-hook failures

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The shared event publisher, the worker catch-up path, and every read apply the store-wide
`decodeHook` before an event reaches a consumer. Today the hook's only failure channel is an
exception, so one event the hook cannot decode fails its whole batch, and a permanently failing
hook retries the same publisher position forever while every `$all` subscriber continues to
appear live and makes no progress.

After this plan, the hook returns a typed per-event result. The publisher never stalls: it
broadcasts an undecodable event as such and moves on. Each subscriber decides what an undecodable
event means through an optional callback that uses the ordinary disposition vocabulary; without
one, the worker retries briefly and then stops that subscription with a typed reason, so the store
never skips an event on a consumer's behalf. A read that meets an undecodable event returns a
typed `StoreError`. Focused tests prove one-shot recovery, the default stop, a consumer-chosen
dead-letter that continues with the rest of the batch, and the typed read failure.


## Progress

- [ ] M1: add a deterministic persistent-`decodeHook` regression that proves the current repeated same-position loop and apparent-live subscriber state.
- [ ] M2: introduce `DecodeFailure`, change `decodeHook` to return `Either DecodeFailure RecordedEvent`, make `decodeEvents` produce `DecodedEvent` values, and decode per event in the publisher and the worker catch-up path.
- [ ] M2: add `undecodableHandler` to `SubscriptionConfigM`; deliver `Undecodable` to it, or apply the default retry-then-`StopUndecodable`; map read-path failures to `EventDecodeFailed`.
- [ ] M3: document the hook contract, create its ADR, and run focused plus full Kiroku tests and the performance gates.


## Surprises & Discoveries

- Transfer audit (2026-08-27): `Test.PublisherCallbackResilience` intentionally proves that one
  thrown `decodeHook` emits `KirokuEventPublisherLoopError` and the publisher later delivers
  another event. A fix that crashes on the first failure would regress released behavior.
- Transfer audit (2026-08-27): `KirokuEventPublisherLoopError` covers both decode-hook and
  observability-handler exceptions. The implementation must narrow the failure boundary before it
  can count decode failures without making a throwing event handler terminal.
- Performance review (2026-09-09): `decodeEvents` already runs once per fetched batch of up to
  1000 events, and the loop parks in `waitForWakeup` between attempts, so retries are paced by
  notifier ticks (one per committed append, debounced) or the 30-second safety poll and never
  spin. Under sustained append load, however, five tick-driven attempts can elapse within
  milliseconds. Resolved later on 2026-09-09: the per-event contract has no attempt budget and no
  terminal transition, so the question no longer arises.
- Design review (2026-09-09): `decodeEvents` has three callers, not one. `Kiroku.Store.Effect`
  applies it to every read result, `Worker.hs` applies it to every catch-up batch, and the
  publisher applies it once per live batch. Any change to the hook's result type must therefore
  define read-path semantics as well as subscription semantics.
- Design review (2026-09-09), second pass: the first per-event draft had the worker dead-letter
  an undecodable event automatically after retries. It was withdrawn the same day because every
  dead-letter in Kiroku is the consumer's decision, and an automatic one would advance the
  checkpoint past an event the consumer never saw.


## Decision Log

- Decision: Allow four consecutive failures at one publisher position and fail terminally on the
  fifth; reset the count after a successful decoded batch or position advance.
  Rationale: One-shot recovery is an existing tested guarantee. A fixed small budget bounds an
  otherwise unbounded stall without adding a public configuration surface before operational
  experience exists.
  Date: 2026-08-27
  Superseded on 2026-09-09 by the typed per-event contract below: there is no publisher-level
  budget.

- Decision: Scope the terminal budget to `decodeHook` only; a throwing observability callback
  remains isolated and non-terminal.
  Rationale: The decode hook is on the data path and prevents progress. Observability is advisory
  and must not be able to take down event delivery.
  Date: 2026-08-27
  Still in force on 2026-09-09: an observability callback exception is caught and emitted, never
  converted into an undecodable event and never dead-lettered.

- Decision: A terminal publisher failure must be visible through both publisher status and every
  registered subscriber queue.
  Rationale: Merely stopping the publisher thread recreates the original false-liveness bug.
  Existing and newly registering subscribers need one deterministic failure result.
  Date: 2026-08-27
  Superseded on 2026-09-09: the publisher no longer has a terminal state, so there is nothing to
  propagate.

- Decision: Signal terminal publisher failure through a new `SubscriberStatus` constructor rather
  than a new queue element type.
  Rationale: The worker already reads `subStatus` in the same STM transaction as its queue read,
  so a status constructor adds no hot-path work, needs no re-wrapping of every broadcast batch,
  and can be set even when a subscriber's bounded queue is full; the publisher must never block
  on a full queue. Fixed by the 2026-09-09 performance review under
  [ADR-5](../adr/0005-three-tier-performance-regression-gates.md).
  Date: 2026-09-09
  Superseded later on 2026-09-09 by the per-event contract, which changes the queue element type
  for a different reason: each element now carries its own decode outcome, not a control signal.
  `SubscriberStatus` is unchanged.

- Decision: Give `decodeHook` a typed result, `RecordedEvent -> IO (Either DecodeFailure
  RecordedEvent)`, and make `decodeEvents` return `Vector DecodedEvent`.
  Rationale: An exception is the wrong failure channel for a per-event transformation. It fails
  the whole batch, it carries no event identity, and it forces the store to choose between
  retrying forever and failing every subscriber. A typed result lets one bad event be handled as
  one bad event. The cohort is already a breaking release, so changing the field type costs
  nothing extra.
  Date: 2026-09-09

- Decision: Route an undecodable event through the receiving subscriber's `RetryPolicy` and
  dead-letter it with `DeadLetterDecodeFailure` when the policy is exhausted; add
  `decodeRetryDelay` to `RetryPolicy`, defaulting to one second.
  Rationale: The worker already owns per-event retry, dead-letter recording, and checkpoint
  advance in one statement. Reusing them gives one-shot recovery for transient hook failures and
  a bounded, per-subscriber outcome for persistent ones, with no new constant and no store-wide
  state. The dead-letter row preserves the event for replay after the hook is fixed. The retry
  path re-applies the hook in the worker, which already holds `StoreSettings` for catch-up.
  Date: 2026-09-09
  Superseded later on 2026-09-09: the store must not skip an event on the consumer's behalf; see
  the callback decision below. `decodeRetryDelay` is withdrawn and `RetryPolicy` is unchanged.

- Decision: Deliver an undecodable event to an optional per-subscription `undecodableHandler`
  that returns an ordinary `SubscriptionResult`; when none is configured, retry with a one-second
  delay up to `retryMaxAttempts` and then stop the subscription with `StopUndecodable`.
  Rationale: Every dead-letter in Kiroku is the consumer's choice, made through the handler's
  disposition vocabulary. Skipping an undecodable event automatically would advance the
  checkpoint past an event the consumer never saw, which corrupts an ordering-sensitive read
  model silently, and under a systemic hook failure it would turn one configuration error into a
  flood of skipped events. Reusing the disposition vocabulary lets a consumer that can skip poison
  say so, keeps ordinary handlers free of decode concerns, and makes the default the safe one:
  transient failures recover, persistent ones stop one subscription loudly with the event id in
  the reason.
  Date: 2026-09-09

- Decision: A read that meets an undecodable event fails with a typed
  `EventDecodeFailed DecodeFailure` `StoreError` rather than returning a partial result.
  Rationale: A read is request-response; the caller can retry after fixing the hook, and a vector
  with holes would silently change every reader's contract. Subscriptions are the place for
  per-event outcomes because they already have a per-event disposition model.
  Date: 2026-09-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`kiroku-store/src/Kiroku/Store/Settings.hs` defines `StoreSettings` with
`decodeHook :: Maybe (RecordedEvent -> IO RecordedEvent)` and `decodeEvents`, which applies the
hook with `V.mapM` when it is set. `decodeEvents` has three callers.
`kiroku-store/src/Kiroku/Store/Effect.hs` applies it to every read result (`readStreamForward`,
`readAllForward`, `readCategoryForward`, and their siblings).
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` applies it in `fetchBatch` to every
catch-up and database-driven live batch.
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` applies it once per fetched live
batch of up to 1000 events before fanning out into bounded per-subscriber queues of type
`TBQueue (Vector RecordedEvent)`; singleton `$all` subscriptions consume those queues.

The publisher loop currently catches a synchronous exception around its whole broadcast
iteration, emits `KirokuEventPublisherLoopError`, skips the tick, and continues without advancing
its position. A persistent hook exception therefore attacks the same batch on every notifier tick
or 30-second safety poll while every `$all` subscriber reports `Live`.

`processEvents` in `Worker.hs` is the single delivery primitive for every target and both phases.
It walks a batch one event at a time, applies the filters, calls the handler, and resolves
`Continue`, `Stop`, `Retry`, and `DeadLetter`. `Retry` is bounded by `retryMaxAttempts` in
`RetryPolicy` (`Subscription/Types.hs`, currently a newtype with that one field); an exhausted
retry and an explicit `DeadLetter` both call `writeDeadLetter`, which records the event in
`kiroku.dead_letters` and advances the checkpoint in one statement. `DeadLetterReason` and its
`deadLetterSummary` and `deadLetterReasonJson` encoders live in `Subscription/Fsm.hs`.
`Kiroku.Store.Error.StoreError` is the typed read and append error vocabulary. `StopReason` in
`Subscription/Fsm.hs` records why a worker stopped (`StopHandlerRequested`, `StopOverflowed`,
`StopCancelled`, `StopWorkerCrashed`) and is surfaced through `SubscriptionState` and the handle's
wait.

`kiroku-store/test/Test/PublisherCallbackResilience.hs` covers a one-shot hook failure and a
throwing observability handler. No existing ADR records the decode hook's failure contract; this
plan creates one. ADR-4 is not changed because publisher position is independent of durable
subscription checkpoints. [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes
`just perf-check` authoritative for performance evidence, and the bare-subscribe layer of the
`kiroku-shibuya-overhead` benchmark in `kiroku-store/bench/ShibuyaOverhead.hs` measures the
publisher-fed `$all` path this plan changes.


## Plan of Work

### Milestone 1 — pin the liveness failure

Extend `Test/PublisherCallbackResilience.hs` with a hook that always throws for one seeded batch.
Record hook invocations and observed positions, keep a singleton `$all` subscription registered,
and use bounded waits to prove the publisher repeatedly retries the same position while the
subscriber still reports `Live` and the other events in the batch are never delivered. This is a
regression characterization and must fail once milestone 2 lands; retain it by changing the
expected outcome. The test must also assert there is delay between attempts, which the current
tick-and-poll cadence provides.

### Milestone 2 — make decode failure a typed per-event outcome

In `Settings.hs`, add `DecodeFailure` (event id plus operator-facing detail), change the hook
field to `Maybe (RecordedEvent -> IO (Either DecodeFailure RecordedEvent))`, and change
`decodeEvents` to return `Vector DecodedEvent`, where `DecodedEvent` is either
`Decoded RecordedEvent` or `Undecodable RecordedEvent DecodeFailure`. `Undecodable` carries the
raw event so its position and id are available and the worker can re-apply the hook on retry.
Keep applying the hook once per surfaced event; with no hook configured, wrap without traversing
the hook. An exception escaping the hook is a programming error and is still caught at the
existing loop boundary as `KirokuEventPublisherLoopError`; it is not converted into an
`Undecodable`.

In `EventPublisher.hs`, broadcast `Vector DecodedEvent` through the subscriber queues and advance
the publisher position over undecodable events exactly as over decoded ones. Emit
`KirokuEventPublisherDecodeFailed` once per undecodable event at broadcast time. The loop's
exception boundary and its wake cadence are unchanged; there is no failure counter and no terminal
state, and `SubscriberStatus` is unchanged.

Add `undecodableHandler :: Maybe (RecordedEvent -> DecodeFailure -> m SubscriptionResult)` to
`SubscriptionConfigM`, defaulting to `Nothing`. In `Worker.hs`, make `fetchBatch` return
`Vector DecodedEvent` and make `processEvents` walk that type. A `Decoded` event follows the
existing path. For an `Undecodable` event the worker consults the callback. When it is set, call
it with the raw event and the failure and honor its `SubscriptionResult` exactly as the ordinary
handler's: `Continue` skips the event, `Retry` re-applies the hook after the requested delay and
delivers the decoded event to the ordinary handler if the hook now succeeds, `DeadLetter` records
the row and advances, `Stop` stops, and retry exhaustion dead-letters under the existing
`retryMaxAttempts` contract. When it is not set, the worker retries with a fixed one-second delay
while the attempt is below `retryMaxAttempts`, setting the observable `Retrying` state, and then
stops the subscription with a new `StopUndecodable DecodeFailure` stop reason surfaced through
`SubscriptionState` and the handle's wait, leaving the checkpoint before the event. The worker
never dead-letters an undecodable event on its own. Add `DeadLetterDecodeFailure DecodeFailure` to
`DeadLetterReason`, with summary and JSON encodings pinned in tests, as the reason a callback
returns when it chooses to dead-letter. `RetryPolicy` is unchanged.

In `Effect.hs`, map any `Undecodable` in a read result to a new `EventDecodeFailed DecodeFailure`
constructor of `StoreError`, so reads fail typed rather than partially. Update every exhaustive
match on `DeadLetterReason`, `StopReason`, `KirokuEvent`, and `StoreError` in Kiroku packages and
tests.

Rewrite the milestone-1 test around the default: the undecodable event reaches the ordinary
handler zero times, is retried `retryMaxAttempts - 1` times at one-second spacing, and the
subscription stops with `StopUndecodable` carrying the event id while its checkpoint still
precedes the event; the events before it in the batch were delivered exactly once. Add a callback
case whose `undecodableHandler` returns `DeadLetter (DeadLetterDecodeFailure _)`: one dead-letter
row, the checkpoint advances, and the remaining events in the batch are delivered exactly once
while the subscription stays `Live`. Retain the one-shot recovery test with a hook that returns
`Left` once and `Right` on retry, and the throwing observability-handler test unchanged. Add a
read test that returns `Left (EventDecodeFailed _)`.

### Milestone 3 — publish the hook contract

Update the `Settings.hs` Haddocks, the subscription user guide, and the reading guide with the
typed result, per-event retry and dead-letter semantics, the read-path failure, and the replay
procedure after fixing a hook. Create a focused ADR for the decode hook's per-event failure
contract, add it to the ADR bundle log, and validate the strict profile.


## Concrete Steps

Run from the Kiroku repository root:

```bash
cabal build kiroku-store:kiroku-store-test
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "publisher callback resilience"'
```

The final focused transcript must contain examples equivalent to:

```text
publisher callback resilience
  keeps the publisher alive when decodeHook fails once and recovers on retry [OK]
  stops a subscription with StopUndecodable after retries when no callback is configured [OK]
  honors an undecodableHandler that dead-letters and continues with the rest of the batch [OK]
  does not treat a throwing observability handler as a decode failure [OK]
  returns EventDecodeFailed from a read that meets an undecodable event [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run the overhead benchmark once on the unchanged tree before milestone 2 and once after it, and
record both bare-subscribe figures in Surprises & Discoveries. Then run the
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) authoritative gate, which must
pass.

```bash
cabal bench kiroku-store:kiroku-shibuya-overhead
just perf-check
```


## Validation and Acceptance

A hook that returns `Left` once must recover on the next retry and deliver the event normally
without any callback configured. A hook that always returns `Left` for one event must never reach
the ordinary handler with that event; with no callback it must be retried exactly
`retryMaxAttempts - 1` times at one-second spacing and then stop the subscription with
`StopUndecodable` carrying the event id, with the checkpoint still before the event and the
publisher position advanced past it. With a callback that returns `DeadLetter`, exactly one
`kiroku.dead_letters` row with the `DeadLetterDecodeFailure` summary must exist, the checkpoint
must advance, every other event in the batch must be delivered exactly once, and the subscription
must remain `Live`. A read that meets an undecodable event must return `Left (EventDecodeFailed _)`
and no partial vector.

A throwing observability callback must neither stop the subscription nor stop the publisher.
Store shutdown during a decode retry must not leak a thread or block. The bare-subscribe layer of
`kiroku-shibuya-overhead` must show no corroborated slowdown against the pre-change run, and
`just perf-check` must pass. Focused, full store, and strict ADR validation must pass.


## Idempotence and Recovery

Tests are deterministic and repeatable; use bounded waits, not wall-clock sleeps. A subscription
stopped by `StopUndecodable` has moved nothing: its checkpoint still precedes the event, so after
the hook is fixed the operator restarts it and the event is delivered normally. A consumer whose
callback dead-lettered uses the existing dead-letter replay procedure. The publisher never needs
restarting because it never stops. Reverting the change restores the exception-based hook without
a schema change.


## Interfaces and Dependencies

`Kiroku.Store.Settings` exposes:

```haskell
data DecodeFailure = DecodeFailure
    { decodeFailureEventId :: !EventId
    , decodeFailureReason :: !Text
    }

data DecodedEvent
    = Decoded !RecordedEvent
    | Undecodable !RecordedEvent !DecodeFailure

decodeHook :: Maybe (RecordedEvent -> IO (Either DecodeFailure RecordedEvent))
decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector DecodedEvent)
```

`Kiroku.Store.Subscription.Types.SubscriptionConfigM` gains:

```haskell
-- default Nothing
undecodableHandler :: Maybe (RecordedEvent -> DecodeFailure -> m SubscriptionResult)
```

`RetryPolicy` is unchanged. `StopReason` gains `StopUndecodable DecodeFailure`. `DeadLetterReason`
gains `DeadLetterDecodeFailure DecodeFailure`. `Kiroku.Store.Error.StoreError` gains
`EventDecodeFailed DecodeFailure`. `Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventPublisherDecodeFailed
    :: GlobalPosition -> EventId -> DecodeFailure -> KirokuEvent
```

The publisher queue element type becomes `Vector DecodedEvent`; `SubscriberStatus` is unchanged.
Use existing `async`, STM, and exception dependencies; add no new external package. Plan 84 adds
`KirokuEventSubscriptionHandlerStalled` to the same observability type, so both must preserve each
other's constructors during integration. Plans 82 and 84 also edit `Worker.hs`: plan 82 owns
reconnect and validation and plan 84 owns the handler-stall cell around the handler call, so keep
the `DecodedEvent` walk and the undecodable disposition in `processEvents` mechanically separable
from both.

Revision note (2026-09-09): Performance review under ADR-5. Changed the terminal signal from a new
queue element type to a `SubscriberStatus` constructor so the hot path and full-queue behavior are
unchanged, recorded the tick-paced retry cadence and the attempt-versus-time budget question, and
added the `kiroku-shibuya-overhead` before/after run plus `just perf-check` to the concrete steps
and acceptance.

Revision note (2026-09-09): Design review. Replaced the attempt-budget and terminal-state design
with a typed per-event decode contract: `decodeHook` returns `Either DecodeFailure RecordedEvent`,
`decodeEvents` yields `DecodedEvent`, undecodable events retry under the subscriber's
`RetryPolicy` and dead-letter with `DeadLetterDecodeFailure`, and reads fail with
`EventDecodeFailed`. Three earlier decisions are marked superseded rather than removed, and the
`SubscriberStatus` decision from the morning performance review is superseded because the queue
element now carries a per-event outcome. Title and file name are retained for reference stability.

Revision note (2026-09-09): Design review, second pass. Withdrew automatic dead-lettering: an
undecodable event now goes to an optional per-subscription `undecodableHandler` that returns an
ordinary `SubscriptionResult`, and without one the worker retries briefly and stops with
`StopUndecodable`, so the store never skips an event on a consumer's behalf. `decodeRetryDelay`
is withdrawn and `RetryPolicy` is unchanged. The earlier dead-letter decision is marked
superseded.
