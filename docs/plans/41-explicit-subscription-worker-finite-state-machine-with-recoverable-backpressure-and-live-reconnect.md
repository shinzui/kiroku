---
id: 41
slug: explicit-subscription-worker-finite-state-machine-with-recoverable-backpressure-and-live-reconnect
title: "Explicit subscription-worker finite state machine with recoverable backpressure and live reconnect"
kind: exec-plan
created_at: 2026-05-29T20:08:37Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
master_plan: "docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md"
---

# Explicit subscription-worker finite state machine with recoverable backpressure and live reconnect

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. A **subscription** is a long-lived
background worker (one Haskell green thread) that reads events from the log in
order and hands them, one at a time, to a user-supplied **handler** callback,
remembering how far it got in a durable **checkpoint** row in the database. Today
that worker's behavior is correct but its *state is invisible and implicit*:
you cannot ask "what is this subscription doing right now?" because the answer is
encoded only in which Haskell function happens to be executing
(`runWorker` → `catchUp` → one of three live loops) plus two mutable cells. Worse,
two failure modes are *terminal*: if a consumer falls behind and its in-memory
queue fills up, the worker throws an exception and dies; if the worker loses its
database connection while live, it also dies. EventStore — the mature Elixir event
store Kiroku is modeled on — instead treats both as *recoverable* states it can
pause in and resume from.

After this change, the subscription worker is driven by an **explicit finite state
machine** (an "FSM": a value that is always in exactly one named state, with one
function that names every legal move between states). Concretely there is a Haskell
value `SubscriptionState` you can read to know whether the worker is `CatchingUp`,
`Live`, `Paused` (recoverable backpressure), `Reconnecting` (recovering from a lost
database connection), or `Stopped`. A single transition function `step` enumerates
every legal move. Two new behaviors become observable and testable:

- **Recoverable backpressure.** A slow consumer that fills its bounded queue is, by
  default, *paused* — the worker stops pulling, waits for the consumer to drain the
  queue, and then *resumes and delivers every event* with a monotonically advancing
  checkpoint and no gaps. Today this same scenario throws
  `SubscriptionOverflowed` and kills the subscription. The old fail-fast behavior
  remains available as an opt-in for consumers that genuinely want a slow handler
  to be a hard error.

- **Worker-level live reconnect.** A live worker that loses its database pool
  enters `Reconnecting`, backs off, and re-enters `CatchingUp` from its last
  checkpoint — resuming delivery — instead of propagating the exception and dying.

You can see it working two ways. First, the existing `kiroku-store` subscription
test suite continues to pass unchanged (proving no behavior regression). Second,
two new behavioral tests demonstrate the new states: one fills a subscriber's queue
with a deliberately slow handler, then drains it, and asserts the subscription
delivered *all* events in order with a monotonic checkpoint (where today it would
throw); the other injects a database failure during live mode via the existing
process-local fetch hook and asserts the worker reports `Reconnecting` and then
resumes from its checkpoint rather than crashing.

This plan is the **foundation** of MasterPlan 6
(`docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md`).
It deliberately does **not** add per-event retry or dead-letter handling — that is
the sibling plan `docs/plans/40-per-event-retry-and-dead-letter-for-kiroku-subscriptions-and-the-shibuya-adapter.md`,
which will *extend* this FSM. It deliberately does **not** change consumer-group
partitioning or the Shibuya adapter — that is the sibling plan
`docs/plans/42-wire-kiroku-consumer-groups-into-the-shibuya-partitioned-ordering-policy-model.md`.
Those siblings are referenced only by file path; nothing here depends on them.


## Progress

- [x] Design validated against source. Read in full: `Worker.hs` (the two-phase
  `runWorker` body, the top-level `try body` at lines 167-173, `catchUp`'s
  `cursor >= pubPos` boundary and `fetchRetryDelayMicros` backoff, the three live
  loops `liveLoop`/`liveLoopCategoryNotify`/`liveLoopDbDriven`, `processEvents`'s
  per-batch/per-event checkpoint, and the `withFetchBatchHookForTest` IORef hook);
  `Types.hs` (`SubscriptionResult = Continue | Stop`, `OverflowPolicy`,
  `SubscriptionOverflowed`, `SubscriptionConfigM` fields, `defaultSubscriptionConfig`);
  `EventPublisher.hs` (`Subscriber{subQueue,subStatus,subPolicy}`,
  `SubscriberStatus = Active | Overflowed`, the `deliverBatch` overflow decision,
  `publisherBatchSize = 1000`, `safetyPollMicros`); `Observability.hs`
  (`KirokuEvent` constructors and `SubscriptionStopReason`); `Notification.hs`
  (listener-layer reconnect loop and per-category generation counter);
  `Subscription.hs` (`subscribe`/`withSubscription`, worker spawn,
  `SubscriptionHandle{cancel,wait}`); `docs/architecture/subscriptions.md` (Design
  Invariants and Worker Lifecycle); the EventStore reference FSM
  `lib/event_store/subscriptions/subscription_fsm.ex`; and the test harness
  (`test/Main.hs`, `test/Test/Helpers.hs`, `test/Test/FailureInjection.hs`,
  `test/Test/CategoryIdleNoSpin.hs`, the cabal suite `kiroku-store-test`).
- [x] M1 — define `SubscriptionState` and an exhaustive `step` transition function;
  re-express today's catch-up/live/stopped phases as named states driven by a
  `runWorker` loop, with no behavior change. Existing subscription tests stay green.
  Done 2026-05-29: created `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`
  (`{-# OPTIONS_GHC -Werror=incomplete-patterns #-}`, exhaustive `step`); refactored
  `Worker.runWorker` into a `loop`/`feed`/`nextInput`/`runEffects` driver around
  `step`; removed the old `catchUp`/`liveLoop` (their logic moved into the driver);
  kept `liveLoopCategoryNotify`/`liveLoopDbDriven` as run-to-completion live handlers.
  `cabal build all` clean; `cabal test kiroku-store:kiroku-store-test` →
  `164 examples, 0 failures`; `kiroku-otel`, `shibuya-kiroku-adapter`,
  `kiroku-jitsurei` all still link.
- [x] M2 — recoverable backpressure: replace the terminal `Overflowed`→throw path
  with a `Paused` state that resumes when the consumer drains the queue, configurable
  via a new `overflowPolicy` value; keep fail-fast available; add a pause/resume test.
  Done 2026-05-29: added `PauseAndResume` to `OverflowPolicy` (now the
  `defaultSubscriptionConfig` default), `Paused` to `EventPublisher.SubscriberStatus`,
  publisher pauses (sets `Paused`, skips the write, never drops) on a full queue and
  clears `Paused`→`Active` when space returns; added the `QueueBackpressured` FSM input,
  `Live QueueBackpressured -> Paused` and `Paused QueueDrained -> CatchingUp` (re-catch-up
  from checkpoint); the driver's `Paused` action drains the stale queue, clears its own
  status to `Active`, and recovers; added `KirokuEventSubscriptionPaused`/`Resumed`.
  New spec `test/Test/SubscriptionPauseResume.hs` (2 examples) passes; full suite
  `166 examples, 0 failures`; `cabal build all` clean.
- [x] M3 — worker-level `Reconnecting`: a live worker that loses its pool re-enters
  `CatchingUp` from its checkpoint; add a fault-injection test using
  `withFetchBatchHookForTest`.
  Done 2026-05-29: changed `liveLoopCategoryNotify`/`liveLoopDbDriven` to **bubble** a
  live-mode fetch error (new `LiveExit = LiveHandlerStopped | LiveFetchError` return)
  instead of retrying in place; the driver maps `LiveFetchError -> ConnectionLost`,
  which `step` turns into `Reconnecting`; `nextInput (Reconnecting c _)` re-probes the
  DB from the checkpoint (`BatchFetched`→re-catch-up / `FetchEmpty`→`Live` /
  `FetchFailed`→another backed-off `Reconnecting`); wired the `EmitReconnecting` effect
  to the new `KirokuEventSubscriptionReconnecting` event. New spec
  `test/Test/SubscriptionReconnect.hs` (Category subscription) passes; full suite
  `167 examples, 0 failures`; `cabal build all` clean.
- [ ] M4 — observability + regression tests: expose the current state; add regression
  specs for no-missed-events across catch-up→live, monotonic checkpoints, pause/resume,
  reconnect, and idle-category no-busy-poll (the EP-37 invariant).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **There are three distinct live loops, not one.** `Worker.hs` switches among
  `liveLoop` (non-group `AllStreams`, reads the publisher's bounded `TBQueue`),
  `liveLoopCategoryNotify` (non-group `Category`, blocks on a per-category NOTIFY
  generation counter and re-queries the database), and `liveLoopDbDriven` (any
  consumer-group member, gated on the global publisher position). Any FSM `Live`
  state must therefore be parameterized by *which* live strategy is in force, or
  the driver must dispatch on `(consumerGroup, target)` exactly as `runWorker`
  does at lines 159-165 today. This plan keeps the three loops as **effect
  handlers** and lets the driver pick among them; it does not collapse them.

- **A process-local fault-injection hook already exists.** `Worker.hs` exposes
  `withFetchBatchHookForTest :: FetchBatchHook -> IO a -> IO a` backed by a
  `{-# NOINLINE #-}` `IORef (Maybe FetchBatchHook)`, where
  `FetchBatchHook = SubscriptionConfig -> GlobalPosition -> IO (Maybe (Either Pool.UsageError (Vector RecordedEvent)))`.
  `fetchBatch` consults it first and, when the hook returns `Just`, uses the injected
  result instead of hitting Postgres. This is exactly the seam M3's reconnect test
  needs: returning `Just (Left someUsageError)` from the hook forces a fetch failure
  on demand. M3 extends rather than reinvents this mechanism.

- **The terminal `Overflowed` path is two cooperating pieces.** The publisher
  (`EventPublisher.deliverBatch`) makes the *decision* when a subscriber's queue is
  full: under `DropSubscription` it writes `Overflowed` into `subStatus`; under
  `DropOldest` it drops the oldest batch and enqueues the new one. The worker
  (`liveLoop`) only *observes* `Overflowed` on its next STM read and throws
  `SubscriptionOverflowed`. Crucially, only `liveLoop` (the non-group AllStreams
  path) ever reads `subStatus`; the category and DB-driven loops never consult it
  because they bypass the publisher queue. So recoverable backpressure (M2) is
  primarily an AllStreams concern, and the natural place to make it recoverable is to
  *not* have the publisher set a terminal status — instead let the bounded queue's
  natural backpressure (a full `TBQueue` simply isn't written to) pause delivery.

- **`SubscriptionStopReason` already enumerates the terminal reasons.** It is
  `StopHandlerRequested | StopCancelled | StopOverflowed | StopWorkerCrashed !SomeException`.
  The FSM's `Stopped { reason }` state maps one-to-one onto this set, so the existing
  `KirokuEventSubscriptionStopped` emission and `classifyStopReason` mapping carry
  over unchanged.

- **Listener-layer reconnect already exists and is *not* what this plan adds.**
  `Notification.hs`'s `listenerLoop` reconnects the dedicated `LISTEN` connection
  with capped exponential backoff and emits `KirokuEventNotifierReconnecting`/
  `KirokuEventNotifierReconnected`. That recovers the *wake-up* channel, not the
  *worker's* event-reading pool. The new `Reconnecting` state is at the **worker**
  layer: it handles a `Pool.UsageError` from `fetchBatch`/`Pool.use` while the worker
  is live, which today has no recovery in the AllStreams/category live paths beyond
  the per-fetch retry in the DB-driven loops.


## Decision Log

- Decision (M1 implementation): `CatchingUp` carries an `attempt :: !Int` field
  (`CatchingUp { cursor, attempt }`), not just `cursor` as the original sketch showed.
  Rationale: catch-up's escalating capped backoff (`fetchRetryDelayMicros attempt`,
  reset to 0 on any successful fetch) is part of the behavior M1 must preserve.
  Modelling the attempt counter as FSM context keeps `step` pure and total: a
  `FetchFailed` during catch-up transitions `CatchingUp c n -> (CatchingUp c (n+1),
  [Backoff n])`, exactly reproducing the old `go cursor (attempt+1)` with
  `threadDelay (fetchRetryDelayMicros attempt)` before the retry. `Reconnecting`
  already carries an `attempt`; this makes the two recovery counters symmetric.
  Date: 2026-05-29.

- Decision (M1 implementation): moved `SubscriptionStopReason` out of
  `Kiroku.Store.Observability` and into `Kiroku.Store.Subscription.Fsm`, re-exporting
  it from `Observability` (so the public `KirokuEvent` API is byte-for-byte unchanged
  — `Kiroku.Store` and downstream `kiroku-otel` still import it transitively).
  Rationale: M4 adds a `currentState :: m SubscriptionState` accessor to
  `SubscriptionHandleM` in `Subscription.Types`, which would close the cycle
  `Subscription.Types -> Fsm -> Observability -> Subscription.Types` if `Fsm` imported
  `Observability` for the stop reason. Defining the reason in `Fsm` (a near-leaf
  depending only on `Kiroku.Store.Types` + `hasql-pool`) keeps the graph acyclic. Done
  in M1 rather than M4 to avoid authoring `Fsm` against `Observability` and flipping it
  later. Verified: `cabal build all` clean, all three downstream packages link.
  Date: 2026-05-29.

- Decision (M1 implementation): the FSM `Effect` constructor for persisting a
  checkpoint is named `Checkpoint`, not `SaveCheckpoint`.
  Rationale: `Kiroku.Store.Observability.SubscriptionDbPhase` already has a
  `SaveCheckpoint` constructor; `Worker.hs` imports both `Observability` and `Fsm`
  unqualified, so reusing the name produced an ambiguous-occurrence error. The effect
  is internal to the driver, so renaming is harmless.
  Date: 2026-05-29.

- Decision (M1 implementation): `Halt` drives only the driver's *exit* (return
  cleanly vs rethrow), and does **not** itself emit `KirokuEventSubscriptionStopped`.
  The existing top-level `try body` plus its `Right ()` / `Left e` emission is kept
  verbatim. `Halt StopHandlerRequested` returns `Nothing` (the driver unwinds and the
  outer `Right ()` arm emits `StopHandlerRequested`); `Halt StopOverflowed` rethrows
  `SubscriptionOverflowed`, and an uncaught exception still flows through
  `classifyStopReason`. This keeps the emitted event sequence byte-for-byte identical
  to the pre-FSM worker (the M1 acceptance), at the cost of `Halt` not being the single
  emission site the sketch envisioned. Recorded so M2/M4 add the new
  Paused/Resumed/Reconnecting emissions through the `Emit*` effects rather than `Halt`.
  Date: 2026-05-29.

- Decision (M1 implementation): the `Live`/`CatchingUp` clauses for `ConnectionLost`
  and live `FetchFailed` were authored with their M3 *recoverable* target
  (`-> Reconnecting c 1`) already in place, as dead code: the M1 driver never produces
  `ConnectionLost`, and live `FetchFailed` only arises for the category/consumer-group
  loops which retain their own internal retry. This avoids writing a throwaway terminal
  clause (and an exception wrapper to fit `Pool.UsageError` into `StopWorkerCrashed`)
  in M1 only to delete it in M3. The genuinely reachable terminal path in M1 is
  `Live QueueOverflowed -> Stopped StopOverflowed` (preserving the F6 fail-fast test);
  M2 replaces that clause with the `Paused` transition. M3's remaining work is purely
  driver-side: detect a live-phase `Pool.UsageError` and feed `ConnectionLost`.
  Date: 2026-05-29.

- Decision (M1 implementation): the AllStreams live path is driven *per batch* through
  `step` (so M2's `Paused` slots in there), while the `Category` and consumer-group
  live phases are delegated to the existing `liveLoopCategoryNotify` /
  `liveLoopDbDriven` as a single run-to-completion step (`nextInput (Live c)` runs the
  loop, then reports `HandlerStopped` on its normal return). This matches the standing
  decision to keep the three loops as effect handlers and not collapse their distinct
  wake-up strategies (publisher queue / per-category NOTIFY generation / global-position
  gate), which the EP-37 no-busy-poll invariant depends on. The FSM governs the
  lifecycle (entering/leaving `Live`); the loops remain the within-`Live` mechanism.
  Date: 2026-05-29.

- Decision (M2 implementation): recoverable backpressure recovers by **re-catch-up
  from the checkpoint**, not by resuming the queue in place. Transitions:
  `Live QueueBackpressured -> (Paused c ResumeOnDrain, [EmitPaused])`, then
  `Paused c _ QueueDrained -> (CatchingUp c 0, [EmitResumed])`. The publisher, under
  `PauseAndResume`, when the queue is full **skips the write and sets `SubscriberStatus
  = Paused`** (it does not drop and does not block — a blocking STM write would stall
  the shared publisher loop for *all* subscribers, since `deliverBatch` runs
  per-subscriber but sequentially in one thread). Because the skipped events are never
  enqueued, the only lossless recovery is to re-read them from the database: the worker,
  on observing `Paused`, drains the now-stale queue (discarding — those positions are
  re-fetched), clears its own status to `Active`, and re-enters `CatchingUp` from its
  cursor. The AllStreams live `> cursor` filter then drops any superseded queued entries
  once live again. This guarantees no missed events with a monotonic checkpoint
  (at-least-once permits a duplicate around the boundary).
  Rationale: the sketch's `Paused QueueDrained -> (Live c, [...])` would only resume
  reading the queue and would miss the events the publisher skipped while full. The
  worker clearing its own status (rather than waiting for the publisher to clear it)
  avoids an idle busy-loop when no further appends arrive to trigger the publisher.
  Date: 2026-05-29.

- Decision (M2 implementation): a distinct `QueueBackpressured` `Input` was added
  alongside `QueueOverflowed`, rather than making `step`'s single `QueueOverflowed`
  clause branch on the overflow policy.
  Rationale: the publisher already encodes the policy decision in the *status* it sets
  (`Overflowed` under `DropSubscription`, `Paused` under `PauseAndResume`), so the
  worker observes two distinct signals and feeds two distinct inputs. This keeps `step`
  pure and total without threading the `OverflowPolicy` into every state (and `Fsm`
  cannot import `OverflowPolicy` from `Subscription.Types` without reintroducing the
  cycle the M1 `SubscriptionStopReason` move removed). `QueueOverflowed -> Stopped
  StopOverflowed` is therefore unchanged from M1, preserving the F6 fail-fast test
  verbatim.
  Date: 2026-05-29.

- Decision (M2 implementation): the `KirokuEventSubscriptionPaused`/`Resumed`
  constructors were added in M2 (the milestone whose acceptance test asserts they
  fire), not deferred to M4 as the original milestone split implied. M4 still adds
  `KirokuEventSubscriptionReconnecting` (M3 needs it too), the `currentState` accessor,
  and the docs/regression battery. `EventPublisher.SubscriberStatus.Paused` clashes
  with `Fsm.SubscriptionState.Paused` when both are imported unqualified into
  `Worker.hs`, so the publisher status constructors are imported qualified as `Pub`
  there.
  Rationale: each milestone's acceptance is self-proving; adding the event it asserts
  in the same milestone keeps the test honest and the milestone independently
  verifiable.
  Date: 2026-05-29.

- Decision (M3 implementation): worker-level reconnect applies to **Category and
  consumer-group** subscriptions, not AllStreams. AllStreams live delivery is fed by
  the shared `EventPublisher` (a separate thread that owns its own pool-error retry on
  the 30s safety poll); the AllStreams worker performs **no** live-mode database fetch
  — it reads the publisher's in-memory queue — so it has nothing to reconnect. Only the
  Category (`liveLoopCategoryNotify`) and consumer-group (`liveLoopDbDriven`) workers
  fetch in live mode, so those are where a live `Pool.UsageError` can occur and where
  `Reconnecting` is meaningful. The M3 acceptance test therefore drives a **Category**
  subscription (the plan's sketch said AllStreams); `withFetchBatchHookForTest` can only
  inject into `fetchBatch`, which AllStreams live never calls.
  Rationale: routing AllStreams live through a synthetic fetch purely to demonstrate
  reconnect would contradict the publisher-fed design. The worker-level reconnect is
  exactly the recovery for workers that fetch.
  Date: 2026-05-29.

- Decision (M3 implementation): the two DB-driven live loops no longer retry a fetch
  error in place (the old `threadDelay (fetchRetryDelayMicros attempt); goDrain (attempt+1)`).
  They now **return** a `LiveFetchError` outcome; the driver feeds `ConnectionLost` to
  `step`, entering `Reconnecting`, which owns the backoff (`Backoff n`) and the
  re-catch-up. Recovery is equivalent (back off, re-read from the same cursor) but is
  now a single, observable mechanism (`KirokuEventSubscriptionReconnecting`) shared by
  both loops, rather than a silent per-loop retry. The `KirokuEventSubscriptionReconnecting`
  constructor was added in M3 (its acceptance asserts it), alongside M2's Paused/Resumed.
  Rationale: unifies recovery on the FSM, makes a sustained outage observable and
  metric-friendly, and removes the duplicated in-loop retry. `fetchBatch` still emits
  `KirokuEventSubscriptionDbError` on each failed fetch, so the existing DB-error signal
  is unchanged.
  Date: 2026-05-29.

- Decision: Implement a *faithful EventStore-style FSM that adds the two missing
  recoverable states* (paused backpressure and worker-level reconnect), not merely a
  renaming of today's phases.
  Rationale: User direction, recorded identically in MasterPlan 6's Decision Log.
  These two states close real behavioral gaps (terminal overflow; worker dies on live
  DB loss) that EventStore's `max_capacity` and `disconnected` states handle. A pure
  rename would deliver no observable behavior change and fail the "demonstrably
  working behavior" requirement.
  Date: 2026-05-29.

- Decision: The FSM is one sum type `SubscriptionState` plus one exhaustive transition
  function `step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])`. The
  driver (`runWorker`) interprets `Effect`s, produces the next `Input`, and feeds it
  back to `step`. The three live loops and the catch-up loop become effect handlers
  invoked by the driver, not independent control flow.
  Rationale: A single `step` is the documented *extension seam* the MasterPlan's
  Integration Points require: when sibling plan `docs/plans/40-...` adds a
  `SubscriptionResult` constructor (retry/dead-letter), the new constructor must force
  a compile error at every handling site rather than fall through silently. A single
  exhaustively pattern-matched function, compiled with `-Werror=incomplete-patterns`,
  guarantees that. Centralizing the state→effect decision in `step` also means there is
  exactly one place to read the current state for observability.
  Date: 2026-05-29.

- Decision: Recoverable backpressure (`Paused`) is the **default** for the
  correctness-preserving policy, exposed by *adding a new `OverflowPolicy`
  constructor* rather than changing the meaning of `DropSubscription`. Concretely:
  introduce `PauseAndResume` (recoverable) and keep `DropSubscription` (fail-fast,
  terminal) and `DropOldest` (lossy) unchanged; make `defaultSubscriptionConfig` use
  `PauseAndResume`.
  Rationale: Changing the meaning of the existing `DropSubscription` would silently
  alter the behavior every current caller depends on (and break the F6 overflow test,
  which asserts `SubscriptionOverflowed` is thrown). Adding a constructor is additive,
  keeps the fail-fast path intact and tested, and lets the default move to the safer
  recoverable behavior while leaving an explicit opt-out. The `-Werror` incomplete
  pattern guard then forces the publisher's `deliverBatch` and the worker to handle the
  new constructor explicitly.
  Date: 2026-05-29.

- Decision: Expose the current state by **adding `KirokuEvent` constructors** for the
  new transitions (`KirokuEventSubscriptionPaused`, `KirokuEventSubscriptionResumed`,
  `KirokuEventSubscriptionReconnecting`) AND by storing the live `SubscriptionState`
  in a `TVar` that the worker writes on every transition, with a read accessor exposed
  on the subscription handle.
  Rationale: `KirokuEvent` is the established observability channel
  (`Observability.hs` documents that the constructor set is additive and new
  constructors surface as warnings, never silent regressions), so emitting transition
  events is idiomatic and free for existing operators. But events are a *stream of
  past transitions*; the MasterPlan's Vision asks for a state "readable for
  observability" — a *current* value. A `TVar SubscriptionState` provides that
  point-in-time read for tests and operators without polling the event log. Both are
  cheap and complementary; we add both.
  Date: 2026-05-29.

- Decision: Keep the three live loops and the catch-up loop as effect handlers; the
  driver dispatches on `(consumerGroup config, target config)` exactly as today's
  `runWorker` does.
  Rationale: The three loops encode genuinely different wake-up strategies (publisher
  queue vs per-category NOTIFY generation vs global-position gate) that the EP-37
  no-busy-poll invariant depends on. Collapsing them risks reintroducing the idle
  busy-poll the `CategoryIdleNoSpin` test pins. The FSM governs *lifecycle*
  (catch-up/live/paused/reconnecting/stopped); the loops remain the *mechanism* for
  obtaining the next batch within the `Live` state.
  Date: 2026-05-29.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of Kiroku. Read it fully before editing.

**Repository.** The project root is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. It is a Cabal-based Haskell
project (GHC 9.12). The package this plan touches is `kiroku-store`, defined by
`kiroku-store/kiroku-store.cabal`. The library's modules are under
`kiroku-store/src/Kiroku/Store/`; the tests are under `kiroku-store/test/`.

**What a subscription is.** Kiroku stores events in an append-only PostgreSQL log.
Each event has a strictly increasing `GlobalPosition` (think "row number in the
`$all` stream"). A *subscription* is a named, long-lived consumer that reads those
events in order and calls a *handler* — a function
`RecordedEvent -> IO SubscriptionResult` — once per event. The handler returns
`Continue` (process the next event) or `Stop` (shut the subscription down cleanly).
A *checkpoint* is a durable row in the `kiroku.subscriptions` table recording the
last `GlobalPosition` this subscription processed, keyed by
`(subscription_name, consumer_group_member)`. On restart the worker resumes from
the checkpoint, so delivery is *at-least-once* (an event may be re-delivered if the
process dies between handling it and saving the checkpoint).

**Terms of art used below, in plain language.**

- **Finite state machine (FSM):** a value that is always in exactly one named state,
  together with a single function that, given the current state and an input event,
  says which state to move to next. In this plan the state value is
  `SubscriptionState` and the function is `step`.
- **Catch-up:** the phase where the worker reads *history* directly from PostgreSQL,
  in batches, starting from its checkpoint, until it has read everything the
  publisher has already seen.
- **Live:** the phase after catch-up, where the worker receives *new* events as they
  arrive — either from an in-memory queue the publisher writes to, or by re-querying
  PostgreSQL when notified.
- **Publisher (`EventPublisher`):** one background thread per store that reads each
  new `$all` batch from PostgreSQL once and fans it out to every all-stream
  subscriber's bounded in-memory queue. Defined in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`.
- **NOTIFY / `LISTEN`:** PostgreSQL's pub/sub mechanism. A trigger fires
  `pg_notify` on every append; the `Notifier`
  (`kiroku-store/src/Kiroku/Store/Notification.hs`) holds a dedicated connection that
  `LISTEN`s and, on each notification, writes a tick to a broadcast channel and bumps
  a per-category counter. NOTIFY is only a *wake-up*; the worker always reads real
  rows from the database.
- **Consumer group:** a named subscription split into N static *members*; each member
  receives only the streams whose name hashes to its slot, keeping per-stream order.
- **Checkpoint monotonicity:** the checkpoint can never move backward;
  `SQL.saveCheckpointMemberStmt` uses `GREATEST(existing, new)` as the final
  guardrail.
- **Backpressure:** when a consumer is slower than the producer, the system must not
  buffer without bound; it either blocks the producer, drops data, or pauses.
- **`TBQueue`:** a bounded, transactional (STM) in-memory queue. "Bounded" means
  writes block (or the publisher applies an overflow policy) when it is full.

**The current worker, in detail.** The worker lives in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. Its entry point is
`runWorker`, whose body is two phases wrapped in one `try`:

```haskell
runWorker pool liveQueue statusVar pubPosVar catGenVar config mHandler stSettings = liftIO $ do
    let body = do
            ... -- optional consumer-group startup guard
            checkpoint <- loadCheckpoint pool config emit
            emit (KirokuEventSubscriptionStarted subName checkpoint groupCtx)
            -- Phase 1: catch-up (returns Nothing if handler said Stop)
            result <- catchUp pool config checkpoint pubPosVar emit posRef stSettings
            case result of
                Nothing -> pure ()                    -- handler said Stop during catch-up
                Just finalPos -> do
                    emit (KirokuEventSubscriptionCaughtUp subName finalPos groupCtx)
                    case (consumerGroup config, target config) of
                        (Nothing, AllStreams)        -> liveLoop ...
                        (Nothing, Category (CategoryName cat)) -> liveLoopCategoryNotify ...
                        (Just _, _)                  -> liveLoopDbDriven ...
    result <- try body
    pos <- readIORef posRef
    case result of
        Right () -> emit (KirokuEventSubscriptionStopped subName pos StopHandlerRequested groupCtx)
        Left (e :: SomeException) -> do
            emit (KirokuEventSubscriptionStopped subName pos (classifyStopReason e) groupCtx)
            throwIO e
```

The current "state" is implicit: it is *which function is running* (`catchUp`,
`liveLoop`, `liveLoopCategoryNotify`, or `liveLoopDbDriven`) plus two mutable cells:
`posRef :: IORef GlobalPosition` (the cursor) and `statusVar :: TVar SubscriberStatus`
(only ever `Active` or `Overflowed`). There is no value you can read to learn the
phase, and no single enumeration of legal transitions.

`catchUp` reads batches until `cursor >= pubPos` (the publisher's last-published
position), retrying a failed `fetchBatch` at the *same* cursor with capped
exponential backoff (`fetchRetryDelayMicros`). `processEvents` calls the handler per
event and saves the checkpoint at the batch tail (or at the `Stop` event). The three
live loops each obtain their next batch differently (see Surprises & Discoveries).
`fetchBatch` consults the test-only `fetchBatchHookRef` before touching PostgreSQL.

**The handler result type** lives in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

```haskell
data SubscriptionResult = Continue | Stop
    deriving stock (Eq, Show)
```

This plan does **not** change it. Sibling plan `docs/plans/40-...` will add
constructors; the FSM's `step` must be written so that addition forces compile
errors everywhere a `SubscriptionResult` is consumed.

**The overflow policy and subscriber status** are in `Types.hs` and
`EventPublisher.hs`:

```haskell
data OverflowPolicy = DropSubscription | DropOldest
    deriving stock (Eq, Show)

data SubscriberStatus = Active | Overflowed
    deriving stock (Eq, Show)
```

The publisher decides overflow in `deliverBatch`: on a full queue, `DropSubscription`
sets `subStatus := Overflowed`; `DropOldest` drops the oldest batch and enqueues the
new one. Only `liveLoop` reads `subStatus` and throws `SubscriptionOverflowed` on
seeing `Overflowed`.

**Observability** is `kiroku-store/src/Kiroku/Store/Observability.hs`. The relevant
constructors are `KirokuEventSubscriptionStarted`, `...CaughtUp`, `...Stopped`,
`...DbError`, `...Fetched`. `SubscriptionStopReason` is
`StopHandlerRequested | StopCancelled | StopOverflowed | StopWorkerCrashed !SomeException`.
The module documents that the constructor set is additive: new constructors surface
as `-Wincomplete-patterns` warnings, never silent regressions.

**Public API and handle.** `kiroku-store/src/Kiroku/Store/Subscription.hs` exposes
`subscribe` and `withSubscription`. `subscribe` validates the consumer group,
registers a bounded queue with the publisher, spawns `runWorker` in an
`Async.async`, and returns
`SubscriptionHandle { cancel :: IO (), wait :: IO (Either SomeException ()) }`
(from `Types.hs`, the `SubscriptionHandleM` record). M4 extends this handle with a
state accessor.

**The architecture doc** `docs/architecture/subscriptions.md` lists the Design
Invariants this plan must preserve: `last_seen` is always a `$all` position;
checkpoint writes are monotonic; never more than one handler call at a time; live
all-stream delivery must not miss appends during catch-up; live all-stream delivery
must filter stale queued events after catch-up; category live mode must not query on
every unrelated append; consumer-group partitioning stays stream-stable; members
checkpoint independently; NOTIFY wakes but is not the data source; safety polls
remain a backstop; bounded queues must stay bounded. The FSM keeps each (see Plan of
Work, per-milestone "Invariants preserved").

**EventStore reference.** The Elixir reference FSM is at
`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store/subscriptions/subscription_fsm.ex`.
Its states are `initial`, `request_catch_up`, `catching_up`, `subscribed`,
`max_capacity`, `disconnected`, `unsubscribed`. Kiroku's FSM maps onto these as
follows, and the mapping justifies *why* Kiroku has fewer states:

- EventStore `initial` + `request_catch_up` + `catching_up` collapse into Kiroku
  **`CatchingUp`**. EventStore splits `catching_up` from `subscribed` because it
  performs *per-event acknowledgement* and must gate per-event acks differently while
  reading history vs while live. Kiroku has **no per-event ack** — `processEvents`
  invokes the handler synchronously and checkpoints per batch — so the distinction
  vanishes and catch-up is one state.
- EventStore `subscribed` ↔ Kiroku **`Live`**.
- EventStore `max_capacity` ↔ Kiroku **`Paused`** (the recoverable backpressure state
  this plan adds; EventStore enters `max_capacity` when its in-flight queue exceeds
  `max_size` and leaves it when the subscriber acks enough to drain).
- EventStore `disconnected` ↔ Kiroku **`Reconnecting`** (the worker-level reconnect
  this plan adds; EventStore's `disconnect`→`disconnected`→`subscribe`→
  `request_catch_up` cycle is exactly "lose the connection, back off, re-catch-up
  from the last acked position").
- EventStore `unsubscribed` ↔ Kiroku **`Stopped { reason }`**.

Kiroku does **not** copy EventStore's per-subscriber buffers, `partition_by`
round-robin fan-out, or `ack`/`checkpoint` events, because Kiroku uses a centralized
publisher plus a single synchronous handler callback rather than EventStore's
many-subscriber pub/sub-with-acks model.


## Plan of Work

The work is four milestones. M1 is a pure refactor (no behavior change) that
introduces the FSM. M2 and M3 each add one recoverable state and its test. M4 wires
up observability and the full regression suite. Each milestone leaves the package
building and all tests green.

New module: `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, added to the
`exposed-modules` (or `other-modules`) list of the `library` stanza in
`kiroku-store/kiroku-store.cabal`. It holds `SubscriptionState`, `Input`, `Effect`,
and the pure `step` function. Keeping the pure FSM in its own module makes it unit-
testable without a database and keeps `Worker.hs` as the impure *driver/interpreter*.

### M1 — Define the FSM and re-express today's phases as named states (no behavior change)

Scope: introduce the explicit state machine and make `runWorker` a driver loop around
it, reproducing exactly today's observable behavior.

Edits:

1. Create `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`. Define:

   ```haskell
   data SubscriptionState
       = CatchingUp   { cursor :: !GlobalPosition }
       | Live         { cursor :: !GlobalPosition }
       | Paused       { cursor :: !GlobalPosition, resumeWhen :: !ResumeCondition }
       | Reconnecting { cursor :: !GlobalPosition, attempt :: !Int }
       | Stopped      { reason :: !StopReason }
       deriving stock (Show)
   ```

   where `StopReason` mirrors `Observability.SubscriptionStopReason` (we reuse that
   type directly to avoid a parallel enumeration), and `ResumeCondition` describes
   what unblocks a pause (for M1 this is a placeholder; M2 fills it in). Define the
   driver alphabet:

   ```haskell
   data Input
       = BatchFetched   !(Vector RecordedEvent)   -- a non-empty history/live batch arrived
       | FetchEmpty                                 -- a fetch returned no rows
       | FetchFailed    !Pool.UsageError            -- a fetch hit a database error
       | CaughtUp                                   -- cursor reached the publisher position
       | HandlerStopped !GlobalPosition             -- the handler returned Stop at this position
       | QueueOverflowed                            -- the bounded queue filled (AllStreams)
       | QueueDrained                               -- the consumer drained enough to resume
       | ConnectionLost !Pool.UsageError            -- the worker lost its pool while live
       | Cancelled                                  -- the caller cancelled the worker
       deriving stock (Show)
   ```

   and the effects the driver must perform:

   ```haskell
   data Effect
       = FetchHistory   !GlobalPosition   -- read a catch-up batch from the given cursor
       | RunLive                          -- obtain the next live batch via the active live loop
       | DeliverBatch   !(Vector RecordedEvent)  -- call the handler per event, checkpoint at tail
       | SaveCheckpoint !GlobalPosition
       | WaitForDrain                     -- block until the consumer drains the queue
       | Backoff        !Int              -- sleep for the reconnect backoff of this attempt
       | EmitCaughtUp
       | EmitPaused
       | EmitResumed
       | EmitReconnecting !Int
       | Halt           !StopReason       -- terminal: emit Stopped and exit (rethrow on crash)
       deriving stock (Show)
   ```

   Then the single transition function:

   ```haskell
   step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])
   ```

   It must be **exhaustively pattern-matched on `Input` within each state** (no
   wildcard `_` on `Input` in the states that drive event processing), so that
   sibling plan `docs/plans/40-...` adding a `SubscriptionResult` constructor — which
   will introduce a new `Input` such as `HandlerRetried`/`HandlerDeadLettered` — fails
   to compile until every relevant `step` clause handles it. Compile this module with
   `-Werror=incomplete-patterns` (the package already treats warnings as errors via
   the `common` stanza; confirm and, if not, add the pragma to `Fsm.hs`).

   M1 transitions (behavior-preserving):
   - `step (CatchingUp c) (BatchFetched evs)` → `(CatchingUp (lastPos evs), [DeliverBatch evs])`.
     The driver, after delivering, re-checks `cursor >= pubPos` and feeds either
     `CaughtUp` or loops with another `FetchHistory`.
   - `step (CatchingUp c) FetchEmpty` → `(CatchingUp c, [EmitCaughtUp])` then driver
     issues `CaughtUp` (mirrors `catchUp`'s `V.null events -> pure (Just cursor)`).
   - `step (CatchingUp c) (FetchFailed _)` → `(CatchingUp c, [Backoff 0 {- retry same cursor -}])`
     — reproduce `fetchRetryDelayMicros` retry-at-same-cursor.
   - `step (CatchingUp c) CaughtUp` → `(Live c, [EmitCaughtUp])`.
   - `step (Live c) (BatchFetched evs)` → `(Live (lastPos freshEvs), [DeliverBatch freshEvs])`
     where the driver applies the stale-event filter `globalPosition > c` for the
     AllStreams path exactly as `liveLoop` does today.
   - `step (Live c) FetchEmpty` → `(Live c, [RunLive])` (block again on the live loop).
   - `step _ (HandlerStopped p)` → `(Stopped StopHandlerRequested, [SaveCheckpoint p, Halt StopHandlerRequested])`.
   - `step _ Cancelled` → `(Stopped StopCancelled, [Halt StopCancelled])`.
   - In M1, `step (Live _) QueueOverflowed` → `(Stopped StopOverflowed, [Halt StopOverflowed])`
     (preserves today's terminal overflow; M2 replaces this clause).
   - In M1, `step (Live _) (ConnectionLost e)` → `(Stopped (StopWorkerCrashed (toException e)), [Halt ...])`
     (preserves today's "live DB loss kills the worker"; M3 replaces this clause).

2. Refactor `Worker.hs`'s `runWorker` into a **driver loop** that:
   holds the current `SubscriptionState` in a local `IORef`/`TVar`; produces an
   `Input` by performing the indicated `Effect` (e.g. `FetchHistory cur` calls the
   existing `fetchBatch`; `RunLive` calls the appropriate one of the three existing
   live loops *for one batch* — see below; `DeliverBatch` calls the existing
   `processEvents`; `SaveCheckpoint` calls the existing `saveCheckpoint`); then calls
   `step` to get the next state and effects. The existing `loadCheckpoint`,
   `fetchBatch`, `processEvents`, `saveCheckpoint`, `guardMember`,
   `classifyStopReason`, and `fetchRetryDelayMicros` are reused as effect handlers.

   The three live loops change shape only slightly: instead of each running its own
   `go`/recursion to termination, factor out a *"get next live batch"* step for each
   strategy (AllStreams reads the `TBQueue` once; category snapshots its generation,
   drains, and blocks; DB-driven gates on the global position, then drains). The
   driver calls the right one based on `(consumerGroup config, target config)`,
   exactly the dispatch `runWorker` does today at lines 159-165. The simplest faithful
   refactor keeps each live loop's inner recursion but has it *return an `Input`* to
   the driver at each natural decision point (batch arrived, empty, overflow observed)
   rather than recursing directly; the driver then re-enters the loop on `RunLive`.

   The top-level `try body` and the final `KirokuEventSubscriptionStopped` emission
   stay: the driver's `Halt` effect is what produces the `Stopped` emission, and an
   uncaught exception still maps through `classifyStopReason` to a `Stopped`
   state/emission and rethrow.

Invariants preserved: no per-event-call concurrency (still `processEvents`
sequentially); monotonic checkpoints (still `saveCheckpoint` with `GREATEST`);
no-missed-appends (queue still registered before catch-up; stale filter
`globalPosition > cursor` still applied in the `Live` AllStreams path); category
no-busy-poll (the category live loop still blocks on the generation counter); per-
member checkpoints and stream-stable partitioning (DB-driven loop and SQL unchanged);
bounded queues (publisher unchanged in M1).

Acceptance: `cabal build kiroku-store` succeeds; `cabal test
kiroku-store:kiroku-store-test` is fully green; the `subscribe`, `FailureInjection`,
`CategoryIdleNoSpin`, `ConsumerGroup`, `PublisherRestartNoRebroadcast`, and
`CatchupDbErrorNoPrematureSwitch` specs pass unchanged. The observable
`KirokuEvent` sequence (Started → CaughtUp → … → Stopped) is byte-for-byte the same.

### M2 — Recoverable backpressure (`Paused`)

Scope: a slow AllStreams consumer that fills its bounded queue is paused and resumes
when the queue drains, delivering all events with a monotonic checkpoint; keep the
fail-fast policy available.

Edits:

1. In `Types.hs`, add a constructor to `OverflowPolicy`:

   ```haskell
   data OverflowPolicy
       = PauseAndResume   -- recoverable: stop pulling, resume when the consumer drains
       | DropSubscription -- fail-fast: terminate with SubscriptionOverflowed
       | DropOldest       -- lossy: drop the oldest batch
       deriving stock (Eq, Show)
   ```

   Change `defaultSubscriptionConfig` to set `overflowPolicy = PauseAndResume`.

2. In `EventPublisher.hs`'s `deliverBatch`, handle the new constructor. Under
   `PauseAndResume`, the publisher must **not** set `Overflowed` and must **not** drop
   the batch; instead it leaves the full queue alone and does not advance past the
   unwritten batch for that subscriber (the bounded `TBQueue` is the backpressure).
   The natural implementation: when the queue is full under `PauseAndResume`, skip the
   write for this subscriber this cycle — the publisher's `lastPublished` still
   advances globally, but the subscriber's worker, on its next live read, will re-fetch
   from the cursor it has not yet passed. Because the AllStreams live path filters
   `globalPosition > cursor`, no event is lost: the worker simply reads from the queue
   as space frees up, and any batch the publisher could not enqueue is recoverable
   because the worker can fall back to a catch-up-style re-fetch from its cursor when
   it observes the queue could not keep up. (Confirm during implementation whether a
   re-fetch fallback is needed or whether leaving the events in the bounded queue —
   blocking the publisher's enqueue under STM `retry` for that subscriber only —
   suffices; the `deliverBatch` STM is per-subscriber, so a blocking write does not
   roll back other subscribers. The blocking-write option is preferred if it does not
   stall the shared publisher loop; otherwise use the status-flag + worker-managed
   `Paused` approach below.)

   Decision to finalize in M2 implementation and record here: introduce a third
   `SubscriberStatus` value `Paused` (distinct from `Active`/`Overflowed`) that the
   publisher sets under `PauseAndResume` when the queue is full and clears once the
   queue has free space again, so the worker's FSM can observe `QueueOverflowed`
   (→ enter `Paused`) and `QueueDrained` (→ resume).

3. In `Fsm.hs`, replace the M1 terminal-overflow clause:
   - `step (Live c) QueueOverflowed` → `(Paused c (DrainOf ...), [EmitPaused, WaitForDrain])`
     when the policy is `PauseAndResume`; keep the terminal mapping for
     `DropSubscription`. (The policy is available to the driver from `config`; either
     thread it into `step` as part of `Input`/state or branch in the driver before
     constructing the `Input`. Threading the policy into the state at construction
     time is cleanest, so `step` stays a pure total function.)
   - `step (Paused c _) QueueDrained` → `(Live c, [EmitResumed, RunLive])`.

4. In `Worker.hs`, the driver's `WaitForDrain` effect blocks (STM) until the
   subscriber's status returns to `Active` (publisher cleared the `Paused` flag), then
   issues `QueueDrained`.

Invariants preserved: bounded queues stay bounded (the queue capacity is unchanged;
`Paused` is *because* it is bounded); monotonic checkpoints (delivery still per
batch); no missed events (the stale filter plus re-read guarantees every position is
delivered exactly through the cursor). The fail-fast `DropSubscription` path and its
F6 test are untouched.

Acceptance: a new spec `Test/SubscriptionPauseResume.hs` (added to `other-modules` in
the cabal test suite and invoked from `test/Main.hs`) where a handler blocks (via an
`MVar`) long enough to fill a `queueCapacity = 1` subscriber while several batches are
appended (the exact shape mirrors the existing F6 test in `test/Main.hs` lines
1437-1499, but with `overflowPolicy = PauseAndResume`), then releases the handler and
asserts: `wait` returns `Right ()` after the handler returns `Stop` (not
`SubscriptionOverflowed`); every appended `globalPosition` is delivered in order; the
final checkpoint equals the last position. The same scenario under
`overflowPolicy = DropSubscription` still yields `SubscriptionOverflowed` (assert
both).

### M3 — Worker-level live reconnect (`Reconnecting`)

Scope: a live worker that loses its database pool re-enters catch-up from its
checkpoint instead of dying.

Edits:

1. In `Fsm.hs`, replace the M1 terminal `ConnectionLost` clause:
   - `step (Live c) (ConnectionLost _e)` → `(Reconnecting c 1, [EmitReconnecting 1, Backoff 1])`.
   - `step (Reconnecting c n) (FetchFailed _)` → `(Reconnecting c (n+1), [EmitReconnecting (n+1), Backoff (n+1)])`.
   - `step (Reconnecting c _) (BatchFetched evs)` → `(CatchingUp (lastPos evs), [DeliverBatch evs])`
     i.e. a successful fetch after a reconnect re-enters catch-up from `c`.
   - `step (Reconnecting c _) FetchEmpty` → `(Live c, [])` (nothing new; back to live).

2. In `Worker.hs`, make the live paths detect a `Pool.UsageError` and surface it to
   the driver as `ConnectionLost` instead of letting it escape the `try`. The
   AllStreams `liveLoop` does not call `fetchBatch` (it reads the queue), so the
   relevant DB error path is on the *re-catch-up* fetch and on the category/DB-driven
   live fetches; those already return `Either Pool.UsageError`. After M1's refactor
   the driver sees those `Left err` results; map a live-phase `Left err` to the
   `ConnectionLost`/`FetchFailed` inputs rather than the catch-up retry-in-place. Use
   the existing capped-backoff schedule (`fetchRetryDelayMicros`) for `Backoff`.

3. Extend the test seam if needed. The existing `withFetchBatchHookForTest` already
   lets a test return `Just (Left err)` from `fetchBatch`. For a deterministic
   reconnect test we want the hook to fail a bounded number of times and then succeed;
   implement that in the *test* by closing over a counter `IORef` in the hook, not by
   changing the hook type.

Invariants preserved: monotonic checkpoints (re-catch-up reads from the saved cursor;
`GREATEST` guards any overlap); no missed events (catch-up from the cursor re-reads
everything after it); at-least-once (a duplicate around the reconnect boundary is
allowed and expected).

Acceptance: a new spec `Test/SubscriptionReconnect.hs` installs a fetch hook that, for
a chosen subscription, returns `Just (Left someUsageError)` on the first K live-phase
fetch attempts after catch-up and `Nothing` (fall through to the real DB) thereafter.
With an `eventHandler` that records `KirokuEventSubscriptionReconnecting` emissions and
delivered events, the test asserts: at least one `Reconnecting` event fired; the
subscription did **not** fail (`wait` does not return a `Left` for the injected DB
error); all events appended before and after the fault are eventually delivered in
order; the checkpoint is monotonic. (Constructing a real `Pool.UsageError` value for
the hook: reuse the type from `Hasql.Pool`; if no value is conveniently
constructible, the hook can instead force the error by other means — finalize the
exact construction in implementation and record it in Surprises & Discoveries.)

### M4 — Observability and regression suite

Scope: make the current state readable and add the full regression battery.

Edits:

1. In `Observability.hs`, add the additive constructors
   `KirokuEventSubscriptionPaused !SubscriptionName !GlobalPosition !SubscriptionGroupContext`,
   `KirokuEventSubscriptionResumed !SubscriptionName !GlobalPosition !SubscriptionGroupContext`,
   and `KirokuEventSubscriptionReconnecting !SubscriptionName !Int !SubscriptionGroupContext`.
   These are emitted by the driver's `EmitPaused`/`EmitResumed`/`EmitReconnecting`
   effects. Update the module Haddock's event list and `docs/architecture/subscriptions.md`
   observability table.

2. Expose the live state. Add a `TVar SubscriptionState` that `subscribe` creates and
   passes into `runWorker`; the driver writes it on every transition. Add a field to
   `SubscriptionHandleM`:

   ```haskell
   , currentState :: !(m SubscriptionState)
   ```

   so callers and tests can read the point-in-time state. Since `SubscriptionState`
   lives in `Fsm.hs` and `SubscriptionHandleM` in `Types.hs`, move
   `SubscriptionState` (and `Input`/`Effect` if needed) so the dependency direction is
   acyclic — likely `Types.hs` imports from a new small `Fsm.Types` or `Fsm.hs`
   imports `Types.hs` and the handle's accessor returns the `Fsm` type. Finalize the
   module layout in implementation and record it.

3. Add regression specs (new modules under `test/Test/`, wired into `test/Main.hs`
   and the cabal `other-modules`), each phrased as observable behavior:
   - **No missed events across catch-up→live:** append N before subscribing and M
     after; assert all N+M delivered in strictly increasing `globalPosition` with no
     duplicates beyond the documented boundary.
   - **Monotonic checkpoints:** read the checkpoint row repeatedly during a run and
     assert it never decreases.
   - **Pause/resume:** the M2 spec.
   - **Reconnect:** the M3 spec.
   - **Idle-category no-busy-poll:** assert the existing `CategoryIdleNoSpin`
     invariant still holds against the FSM driver (this spec already exists; confirm
     it stays green and, if its internals reference loop functions that the refactor
     renamed, update only the references, not the assertions).

Invariants preserved: all of them; M4 only adds observation, not behavior, except the
new events.

Acceptance: full `cabal test kiroku-store:kiroku-store-test` green, including all new
specs; `handle.currentState` returns the expected state at known points (e.g. `Live`
after `KirokuEventSubscriptionCaughtUp`, `Paused` while a slow consumer is blocked).


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The test suite uses an
ephemeral PostgreSQL spun up by the harness (`Kiroku.Test.Postgres.withSharedMigratedPostgres`,
imported in `test/Main.hs` and `test/Test/Helpers.hs`), so no external database
setup is required — the harness provisions and migrates a throwaway database per run.

Build the library after each milestone's edits:

```bash
cabal build kiroku-store
```

Expected on success (abbreviated):

```text
Building library 'kiroku-store' ...
[ 1 of 1] Compiling Kiroku.Store.Subscription.Fsm ...
...
Linking ...
```

Run the full test suite (this is the single suite that covers subscriptions; its
cabal name is `kiroku-store-test`):

```bash
cabal test kiroku-store:kiroku-store-test
```

Expected tail on success:

```text
Finished in N.NNNN seconds
M examples, 0 failures
Test suite kiroku-store-test: PASS
```

To run only the new specs while iterating (hspec accepts a `--match` pattern via the
suite's test-options; pass it after `--`):

```bash
cabal test kiroku-store:kiroku-store-test --test-options='--match "pause"'
```

Expected:

```text
subscription FSM
  pauses a slow AllStreams consumer and resumes, delivering all events [PASS]
  still fails fast under DropSubscription [PASS]
```

To prove M2 closes the gap (the test must fail *before* the FSM change and pass
*after*), temporarily stash the M2 `Fsm.hs` clause and the `PauseAndResume` policy and
re-run the pause spec; it should fail with a `SubscriptionOverflowed` left value:

```text
  pauses a slow AllStreams consumer and resumes, delivering all events [FAIL]
    expected Right (), got Left (SubscriptionOverflowed ...)
```

Restore the change and confirm green again.


## Validation and Acceptance

Acceptance is behavioral, not "it compiles".

**M1 (no regression).** After the refactor, `cabal test
kiroku-store:kiroku-store-test` passes with zero failures, identical example count to
before (modulo any new specs). Specifically the `subscribe` describe-block in
`test/Main.hs` (catch-up from 0, live-after-start, checkpoint-resume, no-replay on
transition, the F6 overflow spec, the Eff handler spec) and the `FailureInjection`,
`CategoryIdleNoSpin`, `CatchupDbErrorNoPrematureSwitch`, `ConsumerGroup`, and
`PublisherRestartNoRebroadcast` specs all pass unchanged. The
`KirokuEventSubscriptionStarted/CaughtUp/Stopped` sequence is unchanged. The FSM state
is now an inspectable value (verified in M4).

**M2 (pause/resume).** Input: an AllStreams subscription with
`overflowPolicy = PauseAndResume`, `queueCapacity = 1`, and a handler that blocks on
an `MVar` after the first event. Append five events with publisher synchronization
(mirroring `waitForPub` in `test/Main.hs` line 1473), then release the handler.
Observed output: `wait` returns `Right ()` (clean stop after the handler returns
`Stop` on the last event); the list of delivered `globalPosition`s is exactly
`[1..5]` in order; the checkpoint row's `last_seen` equals 5; at least one
`KirokuEventSubscriptionPaused` followed by a `KirokuEventSubscriptionResumed` fired.
Contrast: the identical scenario with `overflowPolicy = DropSubscription` yields
`wait = Left (SubscriptionOverflowed "name")`. Both assertions in one spec prove the
new path is recoverable and the old path is preserved.

**M3 (reconnect).** Input: an AllStreams subscription; after it reaches live mode,
inject `Just (Left usageError)` from `withFetchBatchHookForTest` for the first K
live-phase fetches, then `Nothing`. Append events before and after the fault.
Observed output: at least one `KirokuEventSubscriptionReconnecting` event fired; `wait`
does not surface the injected DB error (the subscription survived); every appended
event is eventually delivered in increasing `globalPosition`; the checkpoint is
monotonic across the fault. This is the proof the worker recovered rather than died —
contrast with today, where the same live-phase DB error in the non-AllStreams loops
would surface through `wait`.

**M4 (state readout).** `handle.currentState` returns `CatchingUp ...` before the
`CaughtUp` event, `Live ...` after it, and `Paused ...` while the M2 slow consumer is
blocked. Assert these at the synchronization points the existing helpers expose
(`waitForSubscriptionLive` from `Test/Helpers.hs` opens an `MVar` on
`KirokuEventSubscriptionCaughtUp`).

The whole battery is run by one command, `cabal test kiroku-store:kiroku-store-test`,
and success is `0 failures`.


## Idempotence and Recovery

The edits are additive and re-runnable. `cabal build` and `cabal test` are
idempotent — re-running them after a partial edit simply recompiles changed modules.
The test harness provisions a fresh ephemeral database per run
(`withSharedMigratedPostgres`), so tests never accumulate state across runs and can be
re-run safely any number of times.

If a milestone's edit leaves the package not building, the safe recovery is to revert
the single module under edit (`git checkout -- kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`
or the relevant file) and re-apply the change incrementally; because M1 is a
behavior-preserving refactor, you can land `Fsm.hs` first (it compiles standalone as a
pure module with its own unit checks) before touching `Worker.hs`.

The runtime change itself is recovery-oriented: the new `Paused` and `Reconnecting`
states *are* the recovery paths. They introduce no destructive database operation —
no schema migration, no data deletion. The only durable artifact a subscription
writes is its checkpoint row, and that write remains monotonic (`GREATEST`), so even a
mid-transition crash cannot move a checkpoint backward; the worst case is at-least-once
re-delivery, which the architecture already documents and handlers already tolerate.

There is no data migration in this plan. Sibling plan `docs/plans/40-...` introduces a
`kiroku.dead_letters` table; this plan does not.


## Interfaces and Dependencies

Libraries and services used (already dependencies of `kiroku-store`; see
`kiroku-store/kiroku-store.cabal`): `stm` (the `TVar`/`TBQueue` state and queues),
`async` (the worker thread and `wait`/`cancel`), `hasql` and `hasql-pool` (database
access and the `Pool.UsageError` type the reconnect path keys on), `vector` (event
batches), `hspec` (tests), and the ephemeral-Postgres test harness
`Kiroku.Test.Postgres`.

The following types and signatures must exist at the end of each milestone, with full
module paths.

**End of M1.** New module `Kiroku.Store.Subscription.Fsm`
(`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`) exporting:

```haskell
data SubscriptionState
    = CatchingUp   { cursor :: !GlobalPosition }
    | Live         { cursor :: !GlobalPosition }
    | Paused       { cursor :: !GlobalPosition, resumeWhen :: !ResumeCondition }
    | Reconnecting { cursor :: !GlobalPosition, attempt :: !Int }
    | Stopped      { reason :: !Kiroku.Store.Observability.SubscriptionStopReason }

data Input
    = BatchFetched !(Data.Vector.Vector Kiroku.Store.Types.RecordedEvent)
    | FetchEmpty
    | FetchFailed !Hasql.Pool.UsageError
    | CaughtUp
    | HandlerStopped !Kiroku.Store.Types.GlobalPosition
    | QueueOverflowed
    | QueueDrained
    | ConnectionLost !Hasql.Pool.UsageError
    | Cancelled

data Effect
    = FetchHistory !Kiroku.Store.Types.GlobalPosition
    | RunLive
    | DeliverBatch !(Data.Vector.Vector Kiroku.Store.Types.RecordedEvent)
    | SaveCheckpoint !Kiroku.Store.Types.GlobalPosition
    | WaitForDrain
    | Backoff !Int
    | EmitCaughtUp | EmitPaused | EmitResumed | EmitReconnecting !Int
    | Halt !Kiroku.Store.Observability.SubscriptionStopReason

step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])
```

`Kiroku.Store.Subscription.Worker.runWorker` keeps its existing signature (the
publisher queue, status `TVar`, position `TVar`, category-generation `TVar`, config,
optional handler, settings) and is internally a driver loop around `step`.
`Kiroku.Store.Subscription.Worker.withFetchBatchHookForTest` and its `FetchBatchHook`
type are unchanged.

**End of M2.** In `Kiroku.Store.Subscription.Types`:

```haskell
data OverflowPolicy = PauseAndResume | DropSubscription | DropOldest
    deriving stock (Eq, Show)

defaultSubscriptionConfig :: SubscriptionName -> SubscriptionTarget -> EventHandlerM m -> SubscriptionConfigM m
-- now sets overflowPolicy = PauseAndResume
```

In `Kiroku.Store.Subscription.EventPublisher`:

```haskell
data SubscriberStatus = Active | Paused | Overflowed
    deriving stock (Eq, Show)
```

(the `Paused` value is set/cleared by `deliverBatch` under `PauseAndResume`).

**End of M3.** No new exported signatures are strictly required; the reconnect logic
lives inside `runWorker`'s driver and `step`. The `FetchBatchHook` type
(`Kiroku.Store.Subscription.Worker.FetchBatchHook =
SubscriptionConfig -> GlobalPosition -> IO (Maybe (Either Hasql.Pool.UsageError (Data.Vector.Vector RecordedEvent)))`)
remains the fault-injection seam.

**End of M4.** In `Kiroku.Store.Observability`, three additive `KirokuEvent`
constructors:

```haskell
KirokuEventSubscriptionPaused        !SubscriptionName !GlobalPosition !SubscriptionGroupContext
KirokuEventSubscriptionResumed       !SubscriptionName !GlobalPosition !SubscriptionGroupContext
KirokuEventSubscriptionReconnecting  !SubscriptionName !Int            !SubscriptionGroupContext
```

In `Kiroku.Store.Subscription.Types`, the handle gains a state accessor:

```haskell
data SubscriptionHandleM m = SubscriptionHandle
    { cancel       :: !(m ())
    , wait         :: !(m (Either SomeException ()))
    , currentState :: !(m Kiroku.Store.Subscription.Fsm.SubscriptionState)
    }
```

**Extension seam for sibling plan `docs/plans/40-...`.** The single
`step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])` is the
documented seam. EP-40 will add `SubscriptionResult` constructors and matching
`Input` constructors (e.g. for retry/dead-letter) plus `Effect`s and a `Retrying`
state; because `step` is exhaustively pattern-matched and the module is built with
`-Werror=incomplete-patterns`, that addition forces a compile error at every `step`
clause and every `Input`/`SubscriptionResult` consumer that must handle it, exactly as
MasterPlan 6's Integration Points require. EP-40 must extend this `step` and these
types in place, not fork a parallel state type.
