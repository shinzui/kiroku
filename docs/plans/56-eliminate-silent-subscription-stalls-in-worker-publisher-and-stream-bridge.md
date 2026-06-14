---
id: 56
slug: eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge
title: "Eliminate silent subscription stalls in worker, publisher, and stream bridge"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
intention: intention_01kv3qaxg9e91v0zq47stehnkz
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Eliminate silent subscription stalls in worker, publisher, and stream bridge

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today there are several distinct paths by which a Kiroku subscription stops consuming
events **silently**: no exception surfaces, no observability event fires, the process
keeps running, and the projection it feeds simply goes stale. The 2026-06-10 audit
(coordinated by `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`,
where this plan is EP-1) confirmed each of them in the current code:

- A consumer pulling from the Streamly bridge in
  `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` blocks **forever** if the
  underlying worker thread dies on its own, because nothing ever writes the stream's
  termination sentinel except the explicit cancel action. The module's own Haddock
  ("The stream terminates when the underlying subscription ends") is currently false.
- The central event-publisher thread in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` dies permanently if a
  user-supplied callback (`decodeHook` or the observability `eventHandler`) throws —
  and once it is dead, every live `AllStreams` subscription blocks on its queue
  forever, every consumer-group subscription blocks on the publisher-position gate
  forever, and every **new** subscription stalls immediately after a truncated
  catch-up. Nobody is told.
- A transient database error while loading a subscription's checkpoint at startup
  silently restarts the subscription from global position 0, re-delivering the entire
  history to the handler.
- Narrower leaks: the bridge's cancel action can itself block forever on a full queue;
  `subscribe` can leak publisher/registry registrations if an asynchronous exception
  lands in its pre-fork window; and `startNotifier` leaks its dedicated LISTEN
  connection (and throws an undocumented exception type) when `LISTEN` fails at
  startup.

After this plan is implemented, **no subscription, bridge stream, or publisher path can
stop without a surfaced error**: a bridge consumer whose worker dies receives the
worker's exception instead of blocking; a publisher whose callback throws emits a
structured `KirokuEvent` and keeps running; a checkpoint-load failure fails the
subscription startup loudly through `wait`; and every startup/registration window
releases its resources on every exit path. Each fix is demonstrated by a test that
fails before the fix and passes after, run against a real (throwaway) PostgreSQL.

Two sibling plans build on this one. EP-2
(`docs/plans/57-harden-shibuya-adapter-ack-contract-and-overflow-policy.md`) **consumes
the bridge termination semantics this plan defines** in Milestone 1 — the adapter's
processor stream can only surface worker death once the bridge carries it. EP-3
(`docs/plans/58-stop-publisher-fan-out-work-for-category-and-consumer-group-subscribers.md`)
**extends the `subscribe` bracketing structure this plan introduces** in Milestone 3,
making publisher-queue registration conditional on the subscription target — so the
bracketing must be built as composable acquire/release pairs, not a monolithic block.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Replace the bridge's `Maybe` queue sentinel with a terminal `TVar` consulted via `orElse` in the reader step (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`). Completed 2026-06-14.
- [x] M1: Spawn a monitor `Async` on the worker handle's `wait` that records the worker's outcome (clean stop / cancel vs. crash) into the terminal `TVar`. Completed 2026-06-14.
- [x] M1: Make `cancelAction` non-blocking (cancel, then first-write-wins close; no queue write). Completed 2026-06-14.
- [x] M1: Update the Haddocks of `subscriptionStream` and `subscriptionAckStream` to state the new termination contract (this is the surface EP-2 consumes). Completed 2026-06-14.
- [x] M1: Add `kiroku-store/test/Test/StreamBridgeTermination.hs` (worker-crash rethrow, clean-stop end, cancel-with-full-queue) and register it in `kiroku-store/test/Main.hs` and `kiroku-store/kiroku-store.cabal`; tests fail before the fix, pass after. Completed 2026-06-14; focused suite passed with 3 examples, 0 failures.
- [x] M2: Add `KirokuEventPublisherLoopError` to `kiroku-store/src/Kiroku/Store/Observability.hs` and an `emitOrDrop` helper that swallows synchronous handler exceptions but never asynchronous ones. Completed 2026-06-14.
- [x] M2: Wrap each publisher loop iteration in a sync-exception catch that emits `KirokuEventPublisherLoopError` and continues on the next tick/safety poll (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`). Completed 2026-06-14.
- [x] M2: Route all `eventHandler` invocations in the publisher, the worker (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`), and the notifier (`kiroku-store/src/Kiroku/Store/Notification.hs`) through `emitOrDrop`. Completed 2026-06-14.
- [x] M2: Reorder `startPublisher` to `dupTChan` the notifier channel **before** reading the tail position. Completed 2026-06-14.
- [x] M2: Add `kiroku-store/test/Test/PublisherCallbackResilience.hs` (throwing `decodeHook` does not kill the publisher; throwing `eventHandler` kills neither publisher nor worker) and register it. Completed 2026-06-14; focused suite passed with 2 examples, 0 failures.
- [ ] M3: Restructure `subscribe` in `kiroku-store/src/Kiroku/Store/Subscription.hs` with `mask` + nested `bracketOnError` + `Async.asyncWithUnmask` so publisher registration and registry insertion are released on every exit path.
- [ ] M3: Make `loadCheckpoint` in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` throw on `Left err` (fresh subscription `Right Nothing` still starts at 0); add the `withLoadCheckpointHookForTest` seam; update the affected Haddocks in `Worker.hs`, `Subscription.hs`, and `Observability.hs`.
- [ ] M3: Bracket `startNotifier`'s acquire/listen/spawn window with `bracketOnError` and widen `NotifierStartError` to also carry LISTEN failures (`kiroku-store/src/Kiroku/Store/Notification.hs`).
- [ ] M3: Add M3 tests (checkpoint-load failure surfaces via `wait`; subscribe/cancel storm leaves no leaked registrations) and register them.
- [ ] M4: Fix the retry-budget off-by-one Haddocks in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` and the `DeadLetterMaxAttempts` doc in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`.
- [ ] M4: Full-suite validation (`cabal build all`, `cabal test all`), record the final bridge termination contract in Outcomes & Retrospective for EP-2, and update the MasterPlan 9 registry/progress.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Terminate the bridge stream through a separate terminal `TVar (Maybe BridgeTermination)`
  consulted via STM `orElse` in the reader step, instead of pushing a terminal element
  through the existing `TBQueue`.
  Rationale: A terminal queue element reproduces defect B — `writeTBQueue` blocks when
  the queue is full (consumer stopped pulling), so the very signal meant to unblock
  things can itself block. A `TVar` write never blocks. The `orElse` shape
  (`readTBQueue queue` first, terminal check second) also gives drain-then-terminate
  for free: items already queued are delivered before the consumer observes the close,
  and an empty queue plus an unset terminal var still blocks (STM `retry`) exactly as
  before. First-write-wins on the `TVar` makes close idempotent between the monitor
  thread and `cancelAction`.
  Date: 2026-06-11

- Decision: A worker that exits cleanly (handler returned `Stop`) **or** is cancelled
  (`Async.AsyncCancelled`, i.e. the bridge's own `cancelAction` or any external cancel
  of the handle) ends the stream normally; **any other** worker exception is rethrown
  to the stream consumer from the stream's pull step.
  Rationale: Cancellation is the consumer's own intent (the cancel action belongs to
  the same caller), so it is not an error; today's semantics already end the stream
  silently on cancel and EP-2's adapter treats end-of-stream as graceful shutdown. A
  crash (`SubscriptionOverflowed`, a rethrown dead-letter DB error, any handler/hook
  exception) is precisely what Shibuya's supervision must observe, so it must arrive
  as an exception, not as a silent end. This is the integration surface EP-2 consumes.
  Date: 2026-06-11

- Decision: The publisher loop catches **synchronous** exceptions per iteration, emits a
  new `KirokuEventPublisherLoopError !SomeException`, and continues; asynchronous
  exceptions (detected with `asyncExceptionFromException`) are rethrown so
  `stopPublisher`'s `Async.cancel` still works.
  Rationale: The loop's only legitimate way to die is cancellation. Everything else —
  a throwing user `decodeHook`, a throwing user `eventHandler`, a decode bug — must
  degrade to "this tick did no work, the operator was told, the 30-second safety poll
  retries", mirroring how `Pool.UsageError` is already handled with
  `KirokuEventPublisherPoolError`. A distinct constructor (rather than reusing the pool
  error) keeps the existing constructor's `UsageError` payload intact and lets
  operators alert on "user callback is broken" separately from "database is broken".
  Date: 2026-06-11

- Decision: Observability emission is hardened with a shared
  `emitOrDrop :: Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()` helper that
  catches and **drops** synchronous exceptions from the user's handler (asynchronous
  ones are rethrown), applied in the publisher, the worker, and the notifier.
  Policy chosen: catch-and-drop, not catch-and-emit-once.
  Rationale: Emitting an event about a failing event handler is recursive by
  construction (the only sink is the handler that just failed), and an emit-once
  latch adds mutable state for a marginal diagnostic. The handler is documented as a
  fast, non-throwing observability callback; if it throws, dropping the event is the
  only behavior that cannot harm store-internal threads. The helper lives in
  `Kiroku.Store.Observability` so all three call sites share one definition.
  Date: 2026-06-11

- Decision: A `decodeHook` exception on the **worker's** fetch path (`fetchBatch` in
  `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`) is left as-is: it kills only
  that worker and surfaces through the handle's `wait` (and, after M1, through the
  bridge stream). No catch is added there.
  Rationale: That path already satisfies the plan's invariant — the failure is loud
  and attributable to one subscription. The publisher is different because one shared
  thread serves every subscriber. Documented in the worker Haddock in M3.
  Date: 2026-06-11

- Decision: `loadCheckpoint` distinguishes `Right Nothing` (fresh subscription, start
  at `GlobalPosition 0`) from `Left err` (throw `err` after emitting the existing
  `KirokuEventSubscriptionDbError`), so a transient pool error at startup fails the
  subscription through `wait` instead of silently re-processing all of history.
  Rationale: `Pool.UsageError` already has an `Exception` instance (the worker's
  `writeDeadLetter` rethrows one at `Worker.hs:701` today), so `throwIO err` needs no
  new error type; the existing outer `try` in `runWorker` classifies it as
  `StopWorkerCrashed` and emits `KirokuEventSubscriptionStopped`, which is exactly the
  loud failure an operator can act on (restart, or fix the pool). Silent full replay
  is the worst possible default for an at-least-once consumer.
  Date: 2026-06-11

- Decision: Add a `withLoadCheckpointHookForTest` process-local injection seam to
  `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, mirroring the existing
  `withFetchBatchHookForTest` (an `IORef`-held hook, exported from the same module).
  Rationale: `loadCheckpoint` runs one `Pool.use` against a healthy test pool; there
  is no reliable way to make exactly that statement fail from outside the process
  without racy connection-killing. The fetch-hook precedent (used by
  `kiroku-store/test/Test/SubscriptionReconnect.hs` and
  `kiroku-store/test/Test/CatchupDbErrorNoPrematureSwitch.hs`) shows this pattern is
  accepted in this codebase and costs one `readIORef` on a once-per-startup path.
  Date: 2026-06-11

- Decision: Widen `NotifierStartError` in `kiroku-store/src/Kiroku/Store/Notification.hs`
  from `newtype NotifierStartError = NotifierStartError ConnectionError` to a
  two-constructor sum: `NotifierConnectError !ConnectionError` (the old case) and
  `NotifierListenError !SomeException` (the `LISTEN` statement failed after the
  connection was acquired).
  Rationale: `hasql-notifications`' `listen` throws its own `FatalError`-style
  exception on failure; translating it keeps `startNotifier`'s documented contract
  ("startup failure raises `NotifierStartError`") true for both failure points. This
  renames the existing constructor — a breaking change — but a repo-wide grep shows
  the only mentions outside the defining module are the re-export in
  `kiroku-store/src/Kiroku/Store.hs` (lines 31 and 59); no caller pattern-matches it.
  Date: 2026-06-11

- Decision: `subscribe`'s pre-fork window is protected with `mask` plus **nested
  `bracketOnError` pairs** (publisher registration → registry insertion → thread
  spawn via `Async.asyncWithUnmask`), one pair per acquired resource, rather than a
  single flat cleanup.
  Rationale: Each resource already has its own release (the publisher's `unsubscribe`
  closure; the token-conditional registry delete), and EP-3 will make the publisher
  registration **conditional on the subscription target** — composable pairs let EP-3
  swap the first acquisition for a no-op without touching the rest of the structure.
  `Async.asyncWithUnmask` is required because `Async.async` inside `mask` would leave
  the worker thread permanently masked (uncancellable).
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

2026-06-14, M1 completed. `subscriptionAckStream` now uses `TBQueue AckItem` for data
items only and a separate internal `TVar (Maybe BridgeTermination)` for stream
termination, where `BridgeTermination` is `BridgeClosedCleanly` or
`BridgeCrashed SomeException`. The stream reader first tries to drain the data queue
and only consults the terminal `TVar` when the queue is empty, via STM `orElse`.
`cancelAction` cancels the subscription handle and first-write-wins closes the
terminal `TVar`; it never writes to the bounded queue. A worker that returns normally
or exits with `AsyncCancelled` ends the stream normally. Any other worker exception is
re-thrown from the next stream pull. The focused validation command passed:

```text
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "stream bridge termination"'
3 examples, 0 failures
```

EP-2, `docs/plans/57-harden-shibuya-adapter-ack-contract-and-overflow-policy.md`, can
consume this contract: bridge consumers see graceful end on intentional stop/cancel and
an exception on worker crash.

The whole `kiroku-store` test suite also passed after M1:

```text
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
192 examples, 0 failures
```

2026-06-14, M2 completed. `Kiroku.Store.Observability` now exports
`KirokuEventPublisherLoopError` and `emitOrDrop`; publisher iterations catch
synchronous callback failures, emit/drop safely, and continue without advancing
`lastPublished` on failed ticks. Worker, notifier, and publisher observability
callbacks all go through `emitOrDrop`, so a throwing metrics/logging callback no
longer kills internal threads. The publisher now duplicates the notifier channel
before reading the tail position, making startup ticks redundant instead of lossy.
Focused validation passed:

```text
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "publisher callback resilience"'
2 examples, 0 failures
```

The full store suite passed after M2:

```text
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
194 examples, 0 failures
```


## Context and Orientation

This repository is a Haskell workspace (GHC 9.12.4, `cabal.project` at the repo root)
whose main package, `kiroku-store`, is a PostgreSQL-backed event store. All paths below
are relative to the repository root
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` on the authoring machine). The
pieces this plan touches form the **subscription pipeline** — the machinery that pushes
newly appended events to consumer code:

**The notifier** (`kiroku-store/src/Kiroku/Store/Notification.hs`) holds one dedicated
PostgreSQL connection executing `LISTEN`. PostgreSQL's `LISTEN`/`NOTIFY` is a built-in
publish/subscribe channel: a database trigger fires `NOTIFY` on every append, and the
listening connection receives it without polling. On each notification the notifier
writes a unit tick into a broadcast `TChan` (an STM channel where every reader gets its
own copy via `dupTChan`) and bumps a per-category counter. `startNotifier`
(lines 114–137) acquires the connection (`acquireOrThrow`, line 126), issues
`Notifications.listen` (line 128), and only then spawns the listener thread
(`Async.async`, line 130).

**The event publisher** (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`)
is one shared thread that wakes on a notifier tick or a 30-second safety poll
(`safetyPollMicros`, line 121), reads all new events from the `$all` ordering once
(`fetchAndBroadcast`, lines 219–251), applies the store-wide `decodeHook`
(line 233 — a user-supplied `RecordedEvent -> IO RecordedEvent` from
`Kiroku.Store.Settings.StoreSettings`, e.g. payload decryption), fans the batch out to
each subscriber's bounded `TBQueue` (a fixed-capacity STM queue providing
backpressure), and advances `lastPublished :: TVar GlobalPosition` (line 247).
`lastPublished` is load-bearing far beyond the fan-out: catch-up workers stop when
their cursor reaches it (`Worker.hs:218–219`), and consumer-group live loops block
until it advances (`Worker.hs:514–517`). `startPublisher` (lines 147–162) currently
reads the database tail position (line 150) **before** duplicating the notifier channel
(line 154), so ticks landing in that gap are invisible to the new publisher.

**The worker** (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`) is the
per-subscription thread spawned by `subscribe`. It loads its checkpoint
(`loadCheckpoint`, lines 392–406: the last globally ordered position this named
subscription has durably processed, stored in the `kiroku.subscriptions` table),
catches up by querying the database until it reaches `lastPublished`, then goes live
(reading the publisher's queue for `AllStreams`, or re-querying on signals for
category/consumer-group targets). Per-event delivery (`processEvents`/`deliver`,
lines 596–666) gives the handler a bounded retry budget and dead-letters exhausted
events. The worker can die in non-cancel ways: the publisher marks it overflowed and
it throws `SubscriptionOverflowed` (line 310); a dead-letter insert fails and the
`Pool.UsageError` is rethrown (line 701); the user handler or `decodeHook` throws.
Every such death surfaces through the handle's
`wait :: IO (Either SomeException ())` (`SubscriptionHandleM`,
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:346–372`) — **if** anyone calls
`wait`. `withFetchBatchHookForTest` (lines 91–100) is an existing test-only seam: a
process-global `IORef` holding a hook that, when set, replaces the worker's database
fetch — the suite uses it to inject fetch failures deterministically.

**`subscribe`** (`kiroku-store/src/Kiroku/Store/Subscription.hs`, lines 105–171)
performs three acquisitions before its handle exists: it registers a per-subscriber
queue with the publisher (`Pub.subscribePublisher` in STM, lines 113–118), inserts the
worker's state cell into the store's central registry (line 156), and spawns the worker
with `Async.async (runWorker ... \`finally\` cleanup)` (lines 157–161), where `cleanup`
(lines 142–153) releases both registrations. Nothing masks asynchronous exceptions
across this window: an exception delivered between the first acquisition and the
`finally`-protected fork leaks the publisher registration (the publisher keeps
delivering to a reader-less queue, which fills and trips its overflow policy forever)
and/or the registry entry.

**The Streamly bridge** (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) turns
the push-based subscription into a pull-based `Streamly.Data.Stream.Stream IO`.
`subscriptionAckStream` (lines 134–174) installs its own handler that enqueues each
event as a `Just AckItem` into a bounded `TBQueue (Maybe AckItem)` and blocks on a
reply `TMVar` (lines 148–157); the stream's pull step blocks on `readTBQueue`
(lines 167–172) and treats `Nothing` as end-of-stream. The **only** writer of that
`Nothing` sentinel is the returned `cancelAction` (lines 163–165). Nothing monitors the
worker handle's `wait`, so if the worker dies on its own the consumer blocks in
`atomically (readTBQueue queue)` forever — and GHC's `BlockedIndefinitelyOnSTM` rescue
never fires because the `cancelAction` closure still references the queue, keeping it
reachable. Worse, `cancelAction`'s `writeTBQueue queue Nothing` itself blocks if the
queue is full. The module Haddock's claim (lines 83–84) that "The stream terminates
when the underlying subscription ends" is currently false. The
`shibuya-kiroku-adapter` package builds directly on this bridge
(`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:274`).

**Observability** (`kiroku-store/src/Kiroku/Store/Observability.hs`) defines the
`KirokuEvent` sum (line 59) that all of the above emit through an optional
user-supplied `eventHandler :: Maybe (KirokuEvent -> IO ())` carried on the store.
Relevant existing constructors: `KirokuEventPublisherPoolError !UsageError` (line 79)
and `KirokuEventSubscriptionDbError` (line 88). Every emit site today is a bare
`for_ mHandler ($ evt)` (e.g. `Worker.hs:156`, `EventPublisher.hs:226`,
`Notification.hs:214`) — a throwing handler kills the emitting thread.

**Retry-budget doc bug (finding H).** `defaultRetryPolicy`
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:180–185`) says "up to five
redeliveries of a single event before it is dead-lettered", and `retryMaxAttempts`'s
field doc (lines 173–176) says "Maximum redeliveries". The code counts **total
deliveries**, 1-based: `deliver` starts at attempt 1 (`Worker.hs:634`) and dead-letters
when `attempt >= maxAttempts` (`Worker.hs:657`), so `retryMaxAttempts = 5` means five
total deliveries — the first delivery plus **four** redeliveries. The
`DeadLetterMaxAttempts !Int` reason (`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:126`)
likewise records total deliveries. The code is correct; the docs are wrong.

**Tests and tooling.** The test suite is `kiroku-store-test`
(`kiroku-store/kiroku-store.cabal`, lines 83–137), an hspec `exitcode-stdio-1.0` suite:
`kiroku-store/test/Main.hs` calls each module's `spec` inside
`withSharedMigratedPostgres`, which boots a throwaway PostgreSQL via the
`ephemeral-pg` library (no external database needed; the PostgreSQL binaries come from
the project's Nix dev shell — run commands inside `nix develop` or with direnv
active). New test modules must be added to both `Main.hs` and the cabal file's
`other-modules`. The repo `Justfile` defines `just build` (= `cabal build all`) and
`just test` (= `cabal test all`); single-suite runs use
`cabal test kiroku-store:kiroku-store-test`.


## Plan of Work

The work is four milestones. M1 fixes the bridge (findings A and B). M2 fixes the
publisher and emit hardening (findings C and D). M3 fixes the startup/registration
windows (findings E, F, G). M4 fixes the documentation off-by-one (finding H) and runs
final validation. Each milestone compiles, passes the full suite, and adds tests that
fail on the pre-milestone code.

### Milestone 1 — Bridge streams terminate with the worker's outcome

Scope: `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` only, plus one new test
module. At the end of this milestone, a consumer of `subscriptionAckStream` (or
`subscriptionStream`, which wraps it) whose worker dies receives the worker's exception
from its next stream pull instead of blocking forever; a clean stop or cancel ends the
stream normally; and `cancelAction` never blocks regardless of queue fullness. The
public types are unchanged (`IO (Stream IO AckItem, IO ())`); only the termination
**behavior** changes. This behavior is the contract EP-2 consumes.

Inside `subscriptionAckStream`, make these changes:

First, simplify the queue to `TBQueue AckItem` (drop the `Maybe`) and add a private
termination type and a terminal cell:

```haskell
-- Internal to Kiroku.Store.Subscription.Stream. How the bridge ended.
data BridgeTermination
    = -- | Worker stopped cleanly (handler 'Stop') or was cancelled.
      BridgeClosedCleanly
    | -- | Worker died; the exception is rethrown to the stream consumer.
      BridgeCrashed !SomeException

-- closedVar :: TVar (Maybe BridgeTermination), created alongside the queue.
-- First write wins, so monitor and cancelAction cannot fight:
closeBridge :: TVar (Maybe BridgeTermination) -> BridgeTermination -> STM ()
closeBridge var t =
    readTVar var >>= \case
        Nothing -> writeTVar var (Just t)
        Just _ -> pure ()
```

Second, after `subHandle <- subscribe store bridgeConfig`, spawn a monitor thread on
the handle's `wait` (which is `Async.waitCatch` under the hood, so it never throws):

```haskell
_monitor <- Async.async $ do
    outcome <- wait subHandle
    atomically . closeBridge closedVar $ case outcome of
        Right () -> BridgeClosedCleanly
        Left e
            | Just Async.AsyncCancelled <- fromException e -> BridgeClosedCleanly
            | otherwise -> BridgeCrashed e
```

The monitor performs one STM write and exits; it needs no explicit teardown. If a
consumer abandons the stream without calling `cancelAction`, the monitor lives exactly
as long as the (already leaked) worker — the pre-existing "forgetting to cancel leaks
the thread" contract documented on `subscribe` is unchanged.

Third, replace the reader step so it drains the queue first and only then consults the
terminal cell — `orElse` tries its left branch and falls to the right only when the
left retries (queue empty), and retries the whole transaction when both retry, which
preserves today's blocking behavior while the bridge is open:

```haskell
let step :: () -> IO (Maybe (AckItem, ()))
    step () = do
        next <-
            atomically $
                (Right <$> readTBQueue queue)
                    `orElse` (readTVar closedVar >>= maybe retry (pure . Left))
        case next of
            Right item -> pure (Just (item, ()))
            Left BridgeClosedCleanly -> pure Nothing
            Left (BridgeCrashed e) -> throwIO e
```

Fourth, make `cancelAction` non-blocking and idempotent — it no longer touches the
queue at all (fixing defect B):

```haskell
let cancelAction = do
        cancel subHandle
        atomically (closeBridge closedVar BridgeClosedCleanly)
```

`cancel subHandle` is `Async.cancel` on the worker, which interrupts a worker blocked
in the bridge handler's `takeTMVar` and returns once the worker has finished; the
direct `closeBridge` after it makes termination visible to the reader immediately
rather than waiting on monitor scheduling (the monitor's later write is a no-op by
first-write-wins). The `bridgeHandler` body changes only in that it enqueues `AckItem`
instead of `Just AckItem`.

Fifth, update the Haddocks: the module header, `subscriptionStream`, and
`subscriptionAckStream` must state the new contract in so many words — *the stream
ends normally when the worker stops cleanly or is cancelled, and rethrows the worker's
exception to the consumer when the worker dies for any other reason
(`SubscriptionOverflowed`, handler exceptions, dead-letter database errors,
`decodeHook` exceptions)*. Remove the now-false "writes the @Nothing@ sentinel"
wording.

Finally, add `kiroku-store/test/Test/StreamBridgeTermination.hs` with a `spec` and
register it (import + `spec` call in `kiroku-store/test/Main.hs`; module name in the
`other-modules` of `test-suite kiroku-store-test` in
`kiroku-store/kiroku-store.cabal`). Three tests, each using the existing helpers from
`kiroku-store/test/Test/Helpers.hs` (`withTestStore`, `makeEvent`, `waitForPublisher`)
and `Async.race` with a generous timeout (10 seconds) so a regression fails instead of
hanging the suite:

1. *Worker crash rethrows to the consumer.* Append one event and wait for the
   publisher to pass it (so the new subscription has catch-up work). Install a
   throwing fetch hook with the existing
   `Kiroku.Store.Subscription.Worker.withFetchBatchHookForTest`
   (`\_ _ -> throwIO TestBoom` for a private `TestBoom` exception — a hook that throws
   crashes the worker through `fetchBatch`, which is exactly the documented
   worker-death path). Open `subscriptionAckStream`, pull once
   (`Stream.uncons` from `Streamly.Data.Stream`), and assert the pull **throws**
   (catch with `try` and match `TestBoom`) within the timeout. On pre-M1 code this
   test times out: nothing ever wakes the reader.
2. *Clean stop ends the stream.* Open the bridge over an `AllStreams` subscription,
   append an event, pull the `AckItem`, reply `Stop` into `ackReply`, and assert the
   next pull returns end-of-stream (`Nothing` from `Stream.uncons`) within the
   timeout. On pre-M1 code this also times out — even a *graceful* worker exit never
   ended the stream.
3. *Cancel never blocks on a full queue.* Open the bridge with a tiny buffer
   (capacity 1), append two events so the worker fills the queue and blocks on the
   second item's reply, pull nothing, then call `cancelAction` and assert it returns
   within the timeout, and that a subsequent pull terminates (drained item(s) first,
   then end-of-stream). On pre-M1 code the old `cancelAction` would block in
   `writeTBQueue queue Nothing`.

Acceptance: the three new tests fail (by timeout) when run against the unmodified
`Stream.hs` and pass after the change; the full `kiroku-store-test` suite still passes
(in particular `Test.ConsumerGroup`'s `subscriptionStream` test, `Main.hs` bridge
users, and the `shibuya-kiroku-adapter` test suite via `cabal test all`, since the
adapter consumes this module).

### Milestone 2 — Publisher survives user callbacks and signals liveness

Scope: `kiroku-store/src/Kiroku/Store/Observability.hs`,
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`, the emit sites in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` and
`kiroku-store/src/Kiroku/Store/Notification.hs`, plus one new test module. At the end,
a throwing `decodeHook` or `eventHandler` costs the publisher one tick (with a
structured event emitted), never the thread; and the publisher cannot miss ticks at
startup.

In `Observability.hs`, add a constructor to `KirokuEvent` (alongside
`KirokuEventPublisherPoolError`, line 79) and the shared hardened emitter:

```haskell
    | {- | The publisher loop's broadcast iteration threw a synchronous
      exception that was not a 'UsageError' — typically a user-supplied
      'Kiroku.Store.Settings.decodeHook' or observability handler throwing.
      The publisher skipped this tick and will retry on the next
      notification or the 30-second safety poll. Sustained emissions mean a
      deterministically failing callback: live broadcast is effectively
      stalled (at safety-poll latency) until it is fixed.
      -}
      KirokuEventPublisherLoopError !SomeException
```

```haskell
{- | Invoke the optional observability handler, dropping any synchronous
exception it throws. Asynchronous exceptions (thread cancellation) are
rethrown. Store-internal threads must never die because a metrics callback
threw; see the module Haddock's handler contract.
-}
emitOrDrop :: Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()
emitOrDrop mHandler evt = for_ mHandler $ \h ->
    h evt `catch` \(e :: SomeException) ->
        case asyncExceptionFromException e of
            Just (ae :: SomeAsyncException) -> throwIO ae
            Nothing -> pure ()
```

Export both. In `EventPublisher.hs`, wrap the loop body (`publisherLoop`,
lines 208–217): keep `waitForWakeup`/`drainTicks` outside the catch (they cannot throw
synchronously), and guard `fetchAndBroadcast`:

```haskell
    loop = do
        waitForWakeup tickChan
        drainTicks tickChan
        fetchAndBroadcast `catch` \(e :: SomeException) ->
            case asyncExceptionFromException e of
                Just (ae :: SomeAsyncException) -> throwIO ae
                Nothing -> emitOrDrop mHandler (KirokuEventPublisherLoopError e)
        loop
```

Because `lastPublished` is only advanced (line 247) **after** a fully successful
broadcast, a mid-batch failure re-fetches from the same position next tick. Subscribers
that already received the batch may see it again — that is the store's documented
at-least-once contract, and the `AllStreams` live path's `> cursor` stale filter
(`Worker.hs:242–244`) plus checkpoint monotonicity make redelivery safe. Note this in a
comment at the catch site. Replace the publisher's existing bare emit
(`for_ mHandler ($ KirokuEventPublisherPoolError err)`, line 226) with `emitOrDrop`.

Still in `EventPublisher.hs`, fix the startup ordering nit (finding D) in
`startPublisher` (lines 147–162): move `tickChan <- atomically (dupTChan notifierChan)`
**above** the `Pool.use ... currentGlobalPositionStmt` tail read. A tick that arrives
after the dup but before the tail read is then merely redundant (the fetch from the
tail position returns nothing new); a tick arriving in today's inverse gap is lost
until the 30-second safety poll. Add a one-line comment explaining the ordering is
deliberate so it is not "simplified" back.

Harden the remaining emit sites: in `Worker.hs:156` change
`let emit evt = for_ mHandler ($ evt)` to `let emit = emitOrDrop mHandler`; in
`Notification.hs:214` change `emit evt = for_ mHandler ($ evt)` likewise (drop the
now-unused `for_` imports where applicable). The worker's **subscription handler**
(`handler config`) and its fetch-path `decodeHook` remain uncaught by design — their
exceptions kill only that worker and surface through `wait` and (after M1) the bridge;
state this explicitly in `runWorker`'s Haddock.

Add `kiroku-store/test/Test/PublisherCallbackResilience.hs` (registered in `Main.hs`
and the cabal `other-modules`):

1. *Throwing `decodeHook` does not kill the publisher.* Build a store with
   `withTestStoreSettings` setting `#storeSettings . #decodeHook` to a hook that
   throws **once** for a marker event type (arm it with an `IORef`; rethrow on first
   sight of event type `"Boom"`, pass everything else through) and an `#eventHandler`
   that records events into an `IORef`. Subscribe `AllStreams` with a counting handler.
   Append the `"Boom"` event; then append a normal event. Assert (within a 10-second
   timeout) that the subscription's handler eventually receives both events (the
   failed tick is retried by the next NOTIFY-driven tick, since `lastPublished` did
   not advance) and that the recorded events include a
   `KirokuEventPublisherLoopError`. On pre-M2 code the publisher thread is dead after
   the first throw and the live subscriber never receives anything — the test times
   out.
2. *Throwing `eventHandler` kills neither publisher nor worker.* Build a store whose
   `#eventHandler` **always** throws. Subscribe with a handler that counts events and
   returns `Stop` on the third. Append three events and assert `wait` returns
   `Right ()` within the timeout. On pre-M2 code the first emitted lifecycle event
   (`KirokuEventSubscriptionStarted`) kills the worker (and the first publisher emit
   kills the publisher), so the test fails.

Acceptance: both new tests fail before, pass after; the full suite passes. The
dup-before-tail reorder is a race fix with no deterministic test — its acceptance is
the explanatory comment plus the existing publisher tests
(`Test.PublisherRestartNoRebroadcast`, `Test.FailureInjection`) still passing.

### Milestone 3 — Startup and registration windows release everything, loudly

Scope: `kiroku-store/src/Kiroku/Store/Subscription.hs`,
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`,
`kiroku-store/src/Kiroku/Store/Notification.hs`, plus tests. At the end: an async
exception anywhere in `subscribe`'s pre-fork window leaks neither the publisher
registration nor the registry entry; a checkpoint-load database error fails the
subscription through `wait` instead of replaying history; and a `LISTEN` failure at
notifier startup releases the connection and throws the documented typed error.

**`subscribe` bracketing (finding E).** Restructure `subscribe` (lines 105–171) as:
keep the consumer-group validation first (it acquires nothing); then, under
`mask $ \_restore ->`, nest two `bracketOnError` pairs and finish with the thread
spawn:

```haskell
subscribe store config = liftIO $ do
    for_ (consumerGroup config) $ \(ConsumerGroup m n) ->
        when (n < 1 || m < 0 || m >= n) $ throwIO (InvalidConsumerGroup m n)
    mask $ \_restore ->
        bracketOnError
            (atomically (Pub.subscribePublisher (store ^. #publisher) (queueCapacity config) (overflowPolicy config)))
            (\(_, _, unsubscribe) -> unsubscribe)
            $ \(queue, statusVar, unsubscribe) -> do
                stateVar <- newTVarIO (CatchingUp (GlobalPosition 0) 0)
                token <- newUnique
                let reg = store ^. #subscriptionRegistry
                    key = (name config, configMember config)
                    deregister = atomically $ modifyTVar' reg (Map.update (\(tok', cell) -> if tok' == token then Nothing else Just (tok', cell)) key)
                    cleanup = unsubscribe >> deregister
                bracketOnError
                    (atomically (modifyTVar' reg (Map.insert key (token, stateVar))))
                    (const deregister)
                    $ \() -> do
                        thread <-
                            Async.asyncWithUnmask $ \unmask ->
                                unmask (runWorker (store ^. #pool) queue statusVar stateVar (Pub.lastPublished (store ^. #publisher)) (Notifier.categoryGenerations (store ^. #notifier)) config (store ^. #eventHandler) (store ^. #storeSettings))
                                    `finally` cleanup
                        pure SubscriptionHandle{ ... as today ... }
```

Preserve the existing comments (the token rationale, the cleanup rationale, the
insert-before-fork rationale) by carrying them into the new structure. The invariant
to state in a comment, because EP-3 extends this exact structure: *every acquisition
is paired with a release that runs on every exit path — `bracketOnError` covers the
pre-fork window, `finally cleanup` covers the worker's lifetime; once
`Async.asyncWithUnmask` returns, ownership of both releases has transferred to the
worker thread.* `Async.asyncWithUnmask` (not `Async.async`) is mandatory: the fork
happens under `mask`, and a forked thread inherits the masked state, which would make
the worker uncancellable without the explicit `unmask`. EP-3
(`docs/plans/58-stop-publisher-fan-out-work-for-category-and-consumer-group-subscribers.md`)
will replace the first acquisition with a target-conditional one; do not flatten the
pairs into one block.

**`loadCheckpoint` (finding F).** In `Worker.hs` (lines 392–406), change the `Left`
branch to rethrow after emitting:

```haskell
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError subName LoadCheckpoint err (groupCtxOf config))
            throwIO err
        Right Nothing -> pure (GlobalPosition 0)
        Right (Just pos) -> pure (GlobalPosition pos)
```

The throw propagates out of `body`, is caught by `runWorker`'s outer `try`
(line 332), emits `KirokuEventSubscriptionStopped ... (StopWorkerCrashed ...)`, and
surfaces through `wait` (and the M1 bridge). Add a test seam next to
`fetchBatchHookRef` (lines 84–100), same `IORef`+`bracket` pattern:

```haskell
type LoadCheckpointHook = SubscriptionConfig -> IO (Maybe (Either Pool.UsageError (Maybe Int64)))

withLoadCheckpointHookForTest :: LoadCheckpointHook -> IO a -> IO a
```

and consult it at the top of `loadCheckpoint` (a `Just` result replaces the
`Pool.use`). Export it from the module's export list with a "test-only seam" Haddock
mirroring `withFetchBatchHookForTest`'s. Update the stale Haddocks that promise the
old fallback: `loadCheckpoint`'s own comment (lines 386–391, "before falling back to
the safe default"), the `KirokuEventSubscriptionDbError` doc
(`Observability.hs:80–88`, "worker may continue with a documented fallback for
checkpoint load/save phases" — now only **save** continues), the
`KirokuEventSubscriptionStarted` doc (`Observability.hs:89–95`, "zero if no checkpoint
exists or KirokuEventSubscriptionDbError fired in the LoadCheckpoint phase"), and
`subscribe`'s step 1 doc (`Subscription.hs:39–41`) plus its "Failure modes" list
(add the load-checkpoint `UsageError` case).

**Notifier startup (finding G).** In `Notification.hs`, widen the error type
(Decision Log entry; update the Haddock at lines 65–75 and the re-export consumers do
not pattern-match, so only the constructor used in `acquireOrThrow` line 258 changes):

```haskell
data NotifierStartError
    = -- | The initial dedicated connection could not be acquired.
      NotifierConnectError !ConnectionError
    | -- | The connection was acquired but the initial @LISTEN@ failed
      -- (the connection has been released; nothing leaks).
      NotifierListenError !SomeException
    deriving stock (Show)
    deriving anyclass (Exception)
```

Then bracket `startNotifier`'s acquisition window (lines 123–137) — the module already
imports `bracketOnError` and uses this exact pattern in its reconnect path
(lines 194–203), so mirror it:

```haskell
startNotifier connString schema mHandler = liftIO $ do
    chan <- newBroadcastTChanIO
    catGenVar <- newTVarIO Map.empty
    let channel = toPgIdentifier (schema <> ".events")
    bracketOnError (acquireOrThrow connString) Connection.release $ \conn -> do
        Notifications.listen conn channel
            `catch` \(e :: SomeException) ->
                case asyncExceptionFromException e of
                    Just (ae :: SomeAsyncException) -> throwIO ae
                    Nothing -> throwIO (NotifierListenError e)
        connRef <- newTVarIO conn
        thread <- Async.async (listenerLoop chan catGenVar connRef channel connString mHandler)
        pure Notifier{tickChan = chan, listenerThread = thread, listenerConnRef = connRef, categoryGenerations = catGenVar}
```

`bracketOnError` releases the connection if `listen` fails, if the translate-throw
fires, if `Async.async` itself fails, or if an async exception lands anywhere in the
window; on success the connection's ownership passes to `listenerConnRef` /
`stopNotifier` exactly as today.

M3 tests (one new module `kiroku-store/test/Test/StartupFailureSurfacing.hs`, plus an
addition to `kiroku-store/test/Test/SubscriptionRegistry.hs` if more natural —
implementer's choice, registered wherever they land):

1. *Checkpoint-load failure fails startup loudly.* Under
   `withLoadCheckpointHookForTest (\_ -> pure (Just (Left <someUsageError>)))`
   (construct the `Pool.UsageError` value the same way
   `Test.CatchupDbErrorNoPrematureSwitch` builds its injected fetch error), subscribe
   with a handler that records whether it was ever called, and assert `wait` returns
   `Left` carrying that `UsageError` within the timeout **and** the handler was never
   invoked (no silent replay-from-zero). With an `#eventHandler` installed, also
   assert the recorded events contain `KirokuEventSubscriptionDbError ... LoadCheckpoint ...`
   followed by `KirokuEventSubscriptionStopped` with a `StopWorkerCrashed` reason. On
   pre-M3 code, `wait` does not resolve (the worker happily catches up from 0), so
   assert-on-`wait`-with-timeout fails.
2. *Subscribe/cancel storm leaks nothing.* In a loop of 200 iterations: spawn
   `Async.async (subscribe store cfg)` and immediately `Async.cancel` it (this lands
   async exceptions at random points in the pre-fork window); when the spawn won the
   race, `cancel` the returned handle and `wait` it. Afterwards assert the publisher's
   subscriber registry is empty (`readTVarIO (Pub.subscribers (store ^. #publisher))`
   — the `EventPublisher (..)` export already exposes the field; assert
   `IntMap.null`) and the store's `subscriptionRegistry` map is empty. On pre-M3 code
   this fails intermittently but reliably across 200 iterations (each leaked entry is
   permanent). Mark the iteration count in a comment as a determinism/runtime
   trade-off.
3. The notifier-startup bracket has no deterministic in-suite fault injection (making
   `LISTEN` fail on a healthy ephemeral PostgreSQL requires killing the connection in
   a sub-millisecond window). Its acceptance is: the code-review-verifiable
   `bracketOnError` structure mirroring the reconnect path, the widened
   `NotifierStartError` compiling against all callers, and the existing
   `Test.FailureInjection` listener tests still passing. Record this residual risk in
   Surprises & Discoveries if anything unexpected appears.

Acceptance: new tests fail before, pass after; `cabal test all` passes (the adapter
and metrics packages compile against the widened `NotifierStartError` — they do not
pattern-match it today).

### Milestone 4 — Documentation truth and final validation

Scope: Haddock-only edits plus full validation. Fix finding H in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

- `defaultRetryPolicy` (lines 180–185): replace "up to five redeliveries of a single
  event" with "up to five total deliveries of a single event — the first delivery
  plus four redeliveries".
- `retryMaxAttempts` field doc (lines 173–176): replace "Maximum redeliveries of one
  event before dead-lettering it" with "Maximum total deliveries of one event (the
  first delivery counts as attempt 1) before dead-lettering it"; keep the `<= 1`
  sentence, which is already consistent with the code.
- The `Retry` constructor doc (lines 153–159): after "Redelivery is bounded by the
  subscription's 'RetryPolicy'", add that the bound counts total deliveries, not
  redeliveries.

In `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, the `DeadLetterMaxAttempts`
constructor doc (line 125–126): state that the `Int` records **total deliveries** of
the event (matching `Worker.hs`'s 1-based `attempt` recorded at lines 658 and 695).
Do not change `deadLetterSummary` / `deadLetterReasonJson` output text — the rendered
strings say "attempts", which is accurate under the clarified definition, and changing
stored `reason_summary` text shapes is out of scope.

Then run the full validation (Concrete Steps below), update the Status/Progress rows
for EP-1 in
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`,
and write the Outcomes & Retrospective entry **including the final bridge termination
contract for EP-2** (queue element type, terminal `TVar` shape, consumer-visible
behavior per worker-exit class).


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), inside the Nix dev shell
(`nix develop`, or automatic with direnv) so `cabal`, GHC 9.12.4, and the PostgreSQL
binaries that `ephemeral-pg` boots are on `PATH`.

Build just the store package while iterating:

```bash
cabal build kiroku-store
```

Run the store's test suite with per-example output:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

Successful output ends like this (counts will grow as milestones add tests):

```text
Finished in 92.41 seconds
214 examples, 0 failures
Test suite kiroku-store-test: PASS
```

Run only one milestone's specs while developing it, using hspec's `--match` against
the new module's `describe` string (give each new module a distinctive one, e.g.
`describe "stream bridge termination"`):

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "stream bridge termination"'
```

To demonstrate the before/after behavior for each milestone's tests (acceptance
requires fail-before/pass-after), add the test module and run it **before** changing
the source under test; expect timeout-driven failures such as:

```text
  1) stream bridge termination consumer receives the worker's exception when the worker dies
       expected: stream pull to throw TestBoom within 10s
        but got: timed out waiting on atomically (readTBQueue ...)
```

Then apply the source change and re-run; the same command must report `0 failures`.

After each milestone, run the whole workspace (this also recompiles
`shibuya-kiroku-adapter`, which consumes the bridge, and every other in-repo consumer
of `kiroku-store`):

```bash
just test
```

(`just test` is `cabal test all`; `just build` is `cabal build all`.) Note for the M3
constructor rename: `rg -n "NotifierStartError"` across the repo must show only
`kiroku-store/src/Kiroku/Store/Notification.hs` and the re-export lines in
`kiroku-store/src/Kiroku/Store.hs`; if new call sites have appeared since this plan was
written, update their patterns.

Commit at each milestone boundary with a Conventional Commits message, for example:

```text
fix(kiroku-store): terminate bridge streams with the worker's outcome

Worker death now rethrows to the stream consumer instead of blocking it
forever; cancelAction no longer blocks on a full queue. (EP-1 M1)
```


## Validation and Acceptance

The overall behavior being bought: **no subscription path can stop silently.**
Acceptance per milestone, phrased as observable behavior:

- M1: A consumer of `subscriptionAckStream` whose worker is killed (fetch-hook crash in
  the test; overflow or dead-letter DB error in production) receives the worker's
  exception from its next stream pull within seconds instead of blocking forever —
  the new test in `kiroku-store/test/Test/StreamBridgeTermination.hs` times out before
  the change and passes after. A consumer whose worker stops cleanly (handler `Stop`)
  or is cancelled sees normal end-of-stream. `cancelAction` returns promptly with a
  full queue and a stopped consumer.
- M2: With a `decodeHook` that throws once, a live `AllStreams` subscriber still
  receives all appended events (delayed by at most one tick) and the operator's
  `eventHandler` log contains a `KirokuEventPublisherLoopError`; before the change the
  subscriber starves forever. With an `eventHandler` that always throws, a
  subscription still delivers events and `wait` resolves `Right ()` on handler `Stop`;
  before the change the worker dies on its first lifecycle emit.
- M3: With an injected checkpoint-load failure, `wait` resolves `Left` with the
  injected `UsageError` and the subscription handler is never invoked; before the
  change the handler replays from position 0 and `wait` never resolves. A 200-iteration
  subscribe/cancel storm leaves the publisher's subscriber `IntMap` and the store's
  `subscriptionRegistry` both empty; before the change entries leak. The notifier
  change is accepted structurally (bracket mirrors the reconnect path) plus the
  existing `Test.FailureInjection` listener suite passing.
- M4: The corrected Haddocks state five **total deliveries** for the default policy;
  `rg -n "redeliveries" kiroku-store/src` shows no remaining claim of five
  redeliveries. `cabal test all` passes from a clean state.

Final gate, run from the repo root:

```bash
just build && just test
```

with expected tail output:

```text
Test suite kiroku-store-test: PASS
...
All test suites passed.
```

(Note: a transient `codd` "DB and expected schemas do not match" line from dependent
packages' test setup is known benign noise; judge by the hspec PASS lines.)


## Idempotence and Recovery

Every step is an ordinary source edit plus test run — safe to repeat, no migrations,
no destructive operations, no schema or wire-format changes. The milestones are
independent enough to land as separate commits; if a milestone must be backed out,
`git revert` of its commit restores the previous behavior without affecting the others
(M3's `subscribe` restructure and M1's bridge change touch disjoint files; M2's
`emitOrDrop` is additive). The only cross-package compile impact is M3's
`NotifierStartError` widening; recovery from a missed caller is a compile error, not a
runtime fault — fix the pattern match and rebuild. If a new test is flaky on a loaded
machine (the storm test in M3 is timing-sensitive only in how *often* it would have
caught the old bug, not in whether the new code passes), raise its timeout rather than
weakening its assertion, and record the adjustment in Surprises & Discoveries.


## Interfaces and Dependencies

No new package dependencies. Everything uses libraries already in
`kiroku-store/kiroku-store.cabal`: `async` (`Control.Concurrent.Async`: `async`,
`asyncWithUnmask`, `cancel`, `waitCatch`, `AsyncCancelled`), `stm`
(`TBQueue`, `TVar`, `orElse`, `retry`), `base` (`Control.Exception`: `mask`,
`bracketOnError`, `catch`, `try`, `throwIO`, `fromException`,
`asyncExceptionFromException`, `SomeAsyncException`), `streamly-core`
(`Streamly.Data.Stream.unfoldrM`, and `uncons` in tests), `hasql-pool`
(`Pool.UsageError`, already an `Exception`), and the test suite's existing `hspec` /
`ephemeral-pg` stack via `kiroku-test-support`.

Signatures that must exist at the end of each milestone:

- M1, in `Kiroku.Store.Subscription.Stream` (public types unchanged):
  `subscriptionAckStream :: KirokuStore -> SubscriptionConfig -> Natural -> IO (Stream IO AckItem, IO ())`
  and `subscriptionStream :: KirokuStore -> SubscriptionConfig -> Natural -> IO (Stream IO RecordedEvent, IO ())`,
  now backed internally by `TBQueue AckItem` plus
  `TVar (Maybe BridgeTermination)` where
  `data BridgeTermination = BridgeClosedCleanly | BridgeCrashed !SomeException`
  (internal, not exported). Consumer-visible contract: end-of-stream on clean
  stop/cancel; rethrow on crash. **This contract is what EP-2
  (`docs/plans/57-harden-shibuya-adapter-ack-contract-and-overflow-policy.md`)
  consumes; record its final landed form in Outcomes & Retrospective.**
- M2, in `Kiroku.Store.Observability`:
  `KirokuEventPublisherLoopError !SomeException` (new `KirokuEvent` constructor) and
  `emitOrDrop :: Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()` (exported).
- M3, in `Kiroku.Store.Subscription.Worker`:
  `withLoadCheckpointHookForTest :: (SubscriptionConfig -> IO (Maybe (Either Hasql.Pool.UsageError (Maybe Data.Int.Int64)))) -> IO a -> IO a`
  (exported, test-only seam). In `Kiroku.Store.Notification`:
  `data NotifierStartError = NotifierConnectError !ConnectionError | NotifierListenError !SomeException`
  (re-exported unchanged-by-name from `Kiroku.Store`). `subscribe`'s public signature
  `subscribe :: MonadIO m => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle`
  is unchanged; its internal acquire/release pairing is the structure EP-3
  (`docs/plans/58-stop-publisher-fan-out-work-for-category-and-consumer-group-subscribers.md`)
  extends with a target-conditional publisher registration — keep the pairs
  composable.
- M4 introduces no interfaces.
