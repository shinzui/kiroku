---
id: 83
slug: contain-persistent-publisher-decode-hook-failures
title: "Contain persistent publisher decode-hook failures"
kind: exec-plan
created_at: 2026-08-27T21:14:24Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
---

# Contain persistent publisher decode-hook failures

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The shared event publisher applies the store-wide `decodeHook` before broadcasting `$all`
events. A synchronous hook exception is caught around the loop and retried on the next wake-up.
That preserves service after a one-shot callback failure, but a permanently failing hook retries
the same batch forever while subscribers continue to appear live and make no progress.

After this plan, a transient hook failure still recovers, while five consecutive failures on the
same publisher position move the publisher and all affected subscribers into an explicit terminal
failed state. Operators receive typed observability with the position, attempt count, and
exception. Focused tests prove both one-shot recovery and bounded persistent failure without a hot
loop or false `Live` state.


## Progress

- [ ] M1: add a deterministic persistent-`decodeHook` regression that proves the current repeated same-position loop and apparent-live subscriber state.
- [ ] M2: count consecutive decode failures per publisher position, preserve one-shot recovery, and terminally fail on the fifth failure.
- [ ] M2: propagate terminal publisher failure to registered subscriber queues and expose typed status/observability.
- [ ] M3: document the callback contract, decide and record its ADR, and run focused plus full Kiroku tests.


## Surprises & Discoveries

- Transfer audit (2026-08-27): `Test.PublisherCallbackResilience` intentionally proves that one
  thrown `decodeHook` emits `KirokuEventPublisherLoopError` and the publisher later delivers
  another event. A fix that crashes on the first failure would regress released behavior.
- Transfer audit (2026-08-27): `KirokuEventPublisherLoopError` covers both decode-hook and
  observability-handler exceptions. The implementation must narrow the failure boundary before it
  can count decode failures without making a throwing event handler terminal.


## Decision Log

- Decision: Allow four consecutive failures at one publisher position and fail terminally on the
  fifth; reset the count after a successful decoded batch or position advance.
  Rationale: One-shot recovery is an existing tested guarantee. A fixed small budget bounds an
  otherwise unbounded stall without adding a public configuration surface before operational
  experience exists.
  Date: 2026-08-27

- Decision: Scope the terminal budget to `decodeHook` only; a throwing observability callback
  remains isolated and non-terminal.
  Rationale: The decode hook is on the data path and prevents progress. Observability is advisory
  and must not be able to take down event delivery.
  Date: 2026-08-27

- Decision: A terminal publisher failure must be visible through both publisher status and every
  registered subscriber queue.
  Rationale: Merely stopping the publisher thread recreates the original false-liveness bug.
  Existing and newly registering subscribers need one deterministic failure result.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` owns one store-wide asynchronous
publisher. It fetches global event batches, runs `Kiroku.Store.Settings.decodeHook`, updates the
publisher position, and broadcasts into bounded per-subscription queues. Singleton `$all`
subscriptions catch up from PostgreSQL and then consume those queues. Category and consumer-group
subscriptions stay database-driven and are not affected by this shared publisher failure.

The publisher loop currently catches a synchronous exception around its broadcast iteration,
emits `KirokuEventPublisherLoopError`, skips the tick, and continues. Because its position advances
only after decoding and broadcasting, a persistent hook exception repeatedly attacks the same
batch. Queue registration status currently represents active, paused, or overflowed delivery, but
not a terminal publisher failure.

`kiroku-store/src/Kiroku/Store/Observability.hs` defines `KirokuEvent`.
`kiroku-store/test/Test/PublisherCallbackResilience.hs` covers a one-shot hook failure and a
throwing observability handler. `Test.SubscriptionState` and the FSM tests cover public
subscription state transitions. No existing ADR records the publisher callback failure contract;
this plan must create one if the terminal behavior remains after implementation. ADR-4 is not
changed because publisher position is independent of durable subscription checkpoints.


## Plan of Work

### Milestone 1 — pin the liveness failure

Extend `Test/PublisherCallbackResilience.hs` with a hook that always throws for one seeded batch.
Record hook invocations and observed positions, keep a singleton `$all` subscription registered,
and use bounded waits to prove the publisher repeatedly retries the same position while the
subscriber still reports `Live`. This is a regression characterization and should fail once the
new terminal contract is introduced; retain it by changing the expected outcome in milestone 2.

The test must also assert there is delay between attempts. If current code spins rather than
waiting for notifications or its safety poll, record that discovery and add bounded backoff as
part of milestone 2.

### Milestone 2 — make persistent failure bounded and explicit

Narrow `EventPublisher.hs` so hook execution has its own exception boundary. Track the last failed
batch start position and consecutive failure count. Preserve the current retry behavior for
attempts one through four, with the existing wake/poll cadence. On attempt five, atomically set a
terminal `PublisherFailed` status containing position and exception, notify every registered
subscriber queue with a terminal item, reject or immediately fail later registrations, emit a new
typed `KirokuEventPublisherDecodeHookFailed`, and exit the publisher loop.

Extend the subscriber queue item/status vocabulary and the worker/FSM boundary so a terminal item
leaves `Live` and produces a typed subscription failure. Do not map it to overflow and do not
silently fall back to a database catch-up loop: the same store-wide hook would fail there too.
Ensure publisher cleanup is idempotent when store shutdown races the failure.

Rewrite the milestone-1 test to assert exactly five attempts for the failing position, one terminal
event, terminal publisher status, and terminal subscriber state. Retain the existing one-shot
recovery and throwing-observability-handler tests unchanged except for new exhaustive cases.

### Milestone 3 — publish the callback contract

Update `kiroku-store/src/Kiroku/Store/Settings.hs` Haddocks and the subscription user guide with
the one-shot retry and five-attempt terminal semantics. Create a focused ADR for the store-wide
publisher callback boundary, add it to the ADR bundle log, and validate the strict profile.


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
  keeps the publisher alive when decodeHook throws once [OK]
  terminally fails after five failures at one publisher position [OK]
  does not count a throwing observability handler as decode failure [OK]
```

Then run:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

One hook exception must still recover and deliver a later append. A hook that always throws for a
batch must be invoked exactly five times at the same publisher position, then stop retrying. The
publisher status, subscription state, and `KirokuEventPublisherDecodeHookFailed` must agree on the
terminal failure and position. No subscriber may continue to report `Live`, and a subscriber
registered after terminal failure must fail immediately.

A throwing observability callback must neither increment the decode budget nor terminate the
publisher. Store shutdown before or after terminal transition must not leak a thread or block.
Focused, full store, and strict ADR validation must pass.


## Idempotence and Recovery

Tests are deterministic and repeatable; use bounded waits, not wall-clock sleeps. Terminal state
publication must be a single STM transition so repeated cleanup or subscriber notification cannot
double-report. Once failed, the publisher is not restarted inside the same `KirokuStore`; callers
recover by fixing the hook and recreating the store. This avoids continuing from partially decoded
process state.


## Interfaces and Dependencies

`Kiroku.Store.Subscription.EventPublisher` exposes a queryable status with the semantic shape:

```haskell
data PublisherStatus
    = PublisherRunning
    | PublisherFailed GlobalPosition SomeException
```

The internal subscriber item vocabulary gains a terminal publisher-failure variant, and the
subscription public error/state vocabulary gains the corresponding typed failure.
`Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventPublisherDecodeHookFailed
    :: GlobalPosition -> Int -> SomeException -> KirokuEvent
```

The failure threshold is an internal named constant equal to five. Use existing `async`, STM, and
exception dependencies; add no new external package. Plan 84 may add another observability
constructor and must preserve this one during integration.
