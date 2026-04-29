---
id: 3
slug: subscription-system-robustness-audit
title: "Subscription system robustness audit"
kind: exec-plan
created_at: 2026-04-29T14:06:22Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Subscription system robustness audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` ships an in-process subscription system that lets consumers run handlers over the live event stream. Three components cooperate: a `Notifier` that holds a dedicated PostgreSQL connection on which `LISTEN <schema>.events` is issued and writes a `()` tick to a broadcast `TChan` on every NOTIFY; an `EventPublisher` that wakes on a tick, reads new events from the database in batches, and broadcasts them to all subscriber `TChan`s; and a per-subscription `Worker` that catches up from a checkpoint by querying the database directly until it reaches the publisher's position, then enters a "live" phase where it reads from its broadcast `TChan`. The contract a consumer programs against — at-least-once delivery? exactly-once? backpressure semantics? what happens on database disconnect? — is a public commitment that downstream services will assume and code against.

After this plan, the package has a written audit of every component of the subscription system, classifying every finding by severity. Every must-fix issue has landed: most importantly, the documented but real *gap* in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` lines 117–136 where `Category` subscriptions in *live* mode pass *all* events through (the worker comment admits this is a "Phase 2a simplification"); the unbounded broadcast `TChan` in the `EventPublisher` (a slow subscriber blocks publishing for everyone — a head-of-line blocking risk); the cancellation-vs-checkpoint races in the `Worker`; and the implicit at-least-once delivery contract (which must be made explicit in Haddocks so handler authors know to be idempotent).

A reader can verify the change by running `cabal test kiroku-store`, the new deterministic subscription tests (which replace the existing `threadDelay`-based synchronization), and a new failure-injection scenario that drops the listener connection mid-subscription.


## Progress

- [ ] Milestone 1: Audit findings document
  - [ ] Read every file in `kiroku-store/src/Kiroku/Store/Subscription/` and the supporting `Notification.hs`
  - [ ] Trace each delivery path end-to-end (live, catch-up, post-cancellation, post-disconnect, post-handler-Stop) and record what events the consumer sees
  - [ ] Classify every finding by severity
  - [ ] Cross-link cross-plan findings (Notifier connection failure → EP-5 observability; backpressure → EP-2 API; etc.) in the MasterPlan
- [ ] Milestone 2: Land must-fix corrections
  - [ ] Implement `Category` live-mode filtering (or document the behavioural change)
  - [ ] Add bounded backpressure to `EventPublisher` broadcast (or document the head-of-line risk)
  - [ ] Make the at-least-once delivery contract explicit in Haddocks
  - [ ] Replace `threadDelay`-based test synchronization with deterministic STM-based barriers (or coordinate with EP-6)
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

(None yet. The findings document produced in Milestone 1 will be reflected here with file:line references and severity classification.)

Initial leads identified during MasterPlan research:

- `Worker.filterEvents` (`Subscription/Worker.hs:120-136`) for `Category` subscriptions in live mode returns all events unfiltered. The comment in the source admits this is a documented gap. Severity: must-fix-before-production. Proposed fix: either (1) re-query the database in live mode to apply the SQL category filter (a perf cost), (2) cache the stream-id-to-category map in the publisher and pass category alongside events, or (3) include the source stream's category in the `RecordedEvent` so the worker can filter in-process. Each has tradeoffs; the audit recommends one.
- The `EventPublisher` broadcast `TChan` (`Subscription/EventPublisher.hs:45`, `newBroadcastTChanIO`) is unbounded. A slow subscriber that doesn't drain its `dupTChan` causes `writeTChan` to enqueue unboundedly in memory. STM `TChan` does not block writers when readers are slow — the channel just grows. Severity: must-fix-before-production for any service expecting bounded memory. Proposed fix: bounded `TBQueue` per subscriber with a backpressure policy (drop-oldest, block-publisher, kill-slow-subscriber); document the choice.
- Notifier connection failure path (`Notification.hs:67-79`) catches a `SomeException`, sleeps 1 second, reconnects, re-LISTENs, and resumes. During the 1s window, NOTIFYs are missed. The `EventPublisher`'s 30-second safety poll covers correctness, but there is no observability surfaced — the consumer has no idea the listener crashed. Severity: should-fix; cross-plan with EP-5 for the observability hook.
- The `EventPublisher` swallows pool errors silently (`EventPublisher.hs:107-110`). Same observability concern.
- Worker cancel during checkpoint save: `processEvents` (`Subscription/Worker.hs:141-162`) calls `saveCheckpoint` *after* the handler returns `Continue` for every event in a batch. If the worker is cancelled between handler-return and checkpoint-save, the events have been *acted on* by the handler but no checkpoint advance is persisted. On restart the events are replayed. This is the at-least-once contract; confirm it is documented.
- Worker cancel during `processEvents` mid-batch: cancellation is asynchronous. Cancel raises `AsyncCancelled` between any two `IO` operations. If cancel arrives between handler-return-Continue and the next handler call, the state is "events 1..i processed, events i+1..n not". On restart, events 1..i are replayed because no checkpoint was saved. Confirm and document.
- Worker handler-throws: the handler is `RecordedEvent -> IO SubscriptionResult`. If the handler raises an exception, what happens? The worker thread dies; the consumer sees this via `Async.waitCatch` returning `Left e`. Confirm; document the contract that handler exceptions are uncaught and the subscription terminates.
- `runSubscription` (`Subscription/Effect.hs:62-71`) uses `localUnliftIO env (ConcUnlift Persistent (Limited 1))`. The `Limited 1` means only one concurrent unlift; this is correct because the worker is single-threaded. Confirm with a test that two concurrent handler calls (impossible by design but a future regression risk) would error rather than corrupt state.
- `subscriptionStream` (`Subscription/Stream.hs:33-67`) provides a Streamly bridge with a bounded `TBQueue`. This is the *pull-based* path with backpressure on the consumer side; the *push-based* `subscribe` path has no backpressure (see broadcast `TChan` finding above). Document this contrast clearly.
- The existing subscription tests in `kiroku-store/test/Main.hs:556-830` use `threadDelay 100_000` and `threadDelay 200_000` for synchronization. This is fragile under load. EP-6 owns test-quality, but this plan's fix milestone should replace these with deterministic STM-based barriers if it lands new subscription tests.


## Decision Log

- Decision: Make the at-least-once delivery contract a *required* output of this plan, even if no code changes are needed to honour it. The contract should be in the Haddock for `subscribe`, `Subscription.subscribe`, and `EventHandler`.
  Rationale: Handler authors who do not know the contract will write non-idempotent handlers and silently produce wrong results on subscription restart. This is the single highest-leverage documentation improvement in the package.
  Date: 2026-04-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to have only the working tree and this file. Every necessary piece of context is repeated below.

`kiroku-store` is a PostgreSQL event-store library written in Haskell. It exposes a public `subscribe` operation that runs a handler over events as they are appended to the store. The implementation lives across these files:

- `kiroku-store/src/Kiroku/Store/Notification.hs` — the `Notifier`. Holds a dedicated `Hasql.Connection.Connection` (separate from the `hasql-pool`), issues `LISTEN <schema>.events`, runs a thread that calls `Notifications.waitForNotifications` and writes a `()` tick to a broadcast `TChan` on every NOTIFY received. On any exception (other than `AsyncCancelled`), waits 1 second and re-acquires + re-LISTENs.
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — the `EventPublisher`. Holds a personal `dupTChan` of the Notifier's tick channel and its own broadcast `TChan` of `Vector RecordedEvent`. The `publisherLoop` waits for either a tick or a 30-second safety poll, drains all pending ticks (debouncing), then queries `readAllForwardStmt` from `lastPublished` for up to `publisherBatchSize = 1000` events, broadcasts them to all subscribers, and updates the `lastPublished :: TVar GlobalPosition`. If the batch is full, it loops immediately (drains a backlog).
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — per-subscription worker. `runWorker` loads the checkpoint from `subscriptions` table, runs the catch-up phase (queries the database directly in batches of `batchSize` until it reaches `pubPosVar`), then enters live mode reading from the `dupTChan` of the publisher's broadcast. Each batch goes through `processEvents` which calls the user-supplied handler for each event; on `Continue` for all events it persists a single checkpoint at the batch tail; on `Stop` it persists a checkpoint at the just-handled event and exits.
- `kiroku-store/src/Kiroku/Store/Subscription.hs` — the IO-based `subscribe` entrypoint. Wires up `subscribePublisher` (gets a `dupTChan`) + `lastPublished` `TVar` + spawns the worker via `Async.async`. Returns a `SubscriptionHandle` with `cancel = Async.cancel thread` and `wait = Async.waitCatch thread`.
- `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — the higher-order `Subscription :: Effect` GADT and its interpreter. The interpreter uses `localUnliftIO env (ConcUnlift Persistent (Limited 1))` to convert the caller's `Eff`-based handler to `IO` for the worker thread.
- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — `SubscriptionName`, `SubscriptionTarget` (`AllStreams` or `Category CategoryName`), `SubscriptionResult` (`Continue` or `Stop`), `SubscriptionConfigM`, `SubscriptionHandleM`.
- `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` — a Streamly bridge: wraps a subscription in a bounded `TBQueue` and exposes a Streamly `Stream IO RecordedEvent`. The handler is fixed by the bridge to push events onto the queue; cancellation writes a `Nothing` sentinel to wake any blocked reader.

The subscription system is started inside `withStore` (`Connection.hs:81-96`): on acquire, the Notifier is started, then the EventPublisher is started (depending on the Notifier's tick channel). On release, the Publisher is stopped first (because it depends on the Notifier), then the Notifier, then the pool. Each of these stop functions calls `Async.cancel` followed by `Async.waitCatch`.

Concurrency primitives in use: STM `TChan` (unbounded broadcast), `dupTChan` (per-subscriber view), `TVar` (the `lastPublished` global position), `TBQueue` (only in the Streamly bridge), `Async` (worker, publisher, notifier threads), `bracket` (lifecycle).

The schema and database integration are owned by EP-1 (Schema/CTE/concurrency audit). This plan reads them but does not modify SQL.

Existing test coverage in `kiroku-store/test/Main.hs:556-830`: catch-up from position 0; live delivery; checkpoint persistence and resume; category filtering during catch-up; cancellation; live delivery from initially-empty store; rapid appends without losing events; effectful API. All tests use `threadDelay` for synchronisation between subscription start and event production. The `waitWithTimeout` helper at `Main.hs:880-887` is the timeout primitive.

A note on schema-scoped channels: the Notifier listens on `<schema>.events` (e.g. `public.events`). The schema name is taken from `KirokuStore.schema` (which comes from `ConnectionSettings.schema`). This is the *only* place the schema name is currently used in the package — the SQL statements do not prefix table names with the schema. EP-4 owns the multi-tenancy decision; this plan only flags it as cross-plan context.


## Plan of Work

### Milestone 1 — Audit findings document

Goal: produce a written audit of every component of the subscription system, classifying each finding by severity.

What will exist at the end: each item in the Audit Checklist below has a finding entry in Surprises & Discoveries with severity classification. The audit traces every delivery path end-to-end and confirms the at-least-once contract holds (or identifies the path where it does not).

Verification: every checklist item has a corresponding entry. Cross-plan items are listed in the MasterPlan's Surprises & Discoveries.

### Milestone 2 — Land must-fix corrections

Goal: land code changes for every must-fix finding plus the at-least-once contract documentation.

Specific fixes expected (subject to confirmation in Milestone 1):

- `Category` live-mode filter. The proposed fix (subject to perf measurement) is to include the original stream's category in `RecordedEvent` (one extra column in the read query) so the worker can filter in-process at zero extra database cost. Alternative: have the publisher publish a `(StreamId, CategoryName)` map updated lazily as new streams appear. Choose the simpler option that meets the existing performance baseline.
- Bounded subscriber backpressure. Replace each subscriber's `dupTChan` with a wrapper that enforces a configurable maximum queue depth (e.g. 10,000 events). On overflow, the policy choice is: (1) cancel the slow subscription and surface an error, (2) drop oldest, or (3) block the publisher. Recommend (1) for production safety; document explicitly. The configuration field belongs on `SubscriptionConfig`.
- At-least-once contract Haddock. Add a `-- ===== Delivery Semantics =====` section to `Subscription.hs` and `Subscription/Effect.hs` that reads roughly: "Events are delivered at least once. After a handler returns `Continue`, the checkpoint is persisted at the *batch* boundary, not the event boundary. If the worker is cancelled or crashes between handler-return and checkpoint-save, the events in the batch will be re-delivered on the next subscription with the same name. Handlers must therefore be idempotent or process duplicates correctly."
- `withSubscription` bracket — coordinate with EP-2 which owns this fix.
- Deterministic test synchronization — coordinate with EP-6 which owns the test suite restructure. If a regression test for any must-fix finding is needed before EP-6 lands, write it with a deterministic STM barrier (e.g. an `MVar` or `TVar` set inside the handler to coordinate with the test thread) rather than `threadDelay`.

What will exist at the end: green test suite with new deterministic tests for the must-fix items. Decision Log enumerates each fix and each formally deferred should-fix item.


## Concrete Steps

### Milestone 1 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal test kiroku-store        # confirm baseline green

Files to read in full:

- `kiroku-store/src/Kiroku/Store/Notification.hs` (88 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` (140 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (167 lines)
- `kiroku-store/src/Kiroku/Store/Subscription.hs` (40 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` (81 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` (66 lines)
- `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` (68 lines)
- `kiroku-store/src/Kiroku/Store/Connection.hs` (103 lines, the lifecycle wiring)
- `kiroku-store/test/Main.hs` lines 556–830 (existing subscription tests)

For each finding, write a small reproducer if the answer is empirical (e.g. "does cancelling between handler-Continue and checkpoint-save cause an event to be re-delivered?"). Reproducers go in `kiroku-store/test/Main.hs` so they survive as regression tests; if they require new module support, make them minimal and self-contained.

### Audit Checklist

Notifier:
- Connection acquisition: `acquireOrFail` calls `fail` on initial-acquire failure (`Notification.hs:82-87`). What happens to `withStore` if the listener can't connect? Trace: `withStore` calls `startNotifier`, which calls `acquireOrFail`, which calls `fail` — propagated via `IO` exception, not caught. The result is `withStore` itself fails. Confirm and decide whether this is the right behaviour.
- Reconnection loop (`Notification.hs:67-79`): catches `SomeException`, sleeps 1s, retries. What is the consumer's signal that this happened? Currently nothing. Cross-plan with EP-5.
- The dedicated connection bypasses the pool. It must not leak. Confirm `stopNotifier` calls `Connection.release` (it does, line 62). Confirm the lifecycle order in `withStore` calls `stopNotifier` before `Pool.release` (it does).

EventPublisher:
- Broadcast `TChan` is unbounded. A slow subscriber that does not drain causes the in-memory queue to grow until `OutOfMemory`. Severity: must-fix.
- Pool errors during `fetchAndBroadcast` (`EventPublisher.hs:104-110`) are silently swallowed. Severity: should-fix; cross-plan with EP-5.
- `publisherBatchSize = 1000` is hard-coded (`EventPublisher.hs:53`). Decide: is this configurable enough? At very high event rates, what is the catch-up time after a 30-second safety-poll fallback? Quantify.
- Safety poll at 30 seconds (`EventPublisher.hs:57`). If the listener is dead and the safety poll is the only source of progress, subscribers see batches of up to 30s of events delivered at once. Document.
- The publisher's read uses `readAllForwardStmt` from `SQL.hs`. Confirm the publisher reads from `$all` only — `Category` subscriptions cannot get filter-at-source from this layer.
- `lastPublished` `TVar` is updated transactionally with the broadcast (`EventPublisher.hs:116-118`). Confirm: after a successful broadcast, every concurrent subscriber's catch-up loop will see the new `pubPos` and exit catch-up. This is the "catch-up converges to live mode" invariant.

Worker — catch-up phase:
- `loadCheckpoint` (`Worker.hs:43-49`) returns `GlobalPosition 0` on `Left _err` or `Right Nothing`. The same return is used for "no checkpoint yet" and "database error reading checkpoint". The latter could silently start a fresh subscription that re-processes all events. Severity: should-fix; differentiate via logging at minimum.
- `catchUp` loop (`Worker.hs:61-75`): reads `pubPos` once per iteration; if cursor reaches it, exits. Race: between the `pubPos` read and the subsequent `fetchBatch`, the publisher may advance further. The worker exits catch-up at the lower position, but enters live mode and starts reading from the broadcast `TChan`. Events between the lower and the new publisher position are *not* in the worker's `dupTChan` (because it was duped after subscribe), so they are missed. Confirm: `subscribePublisher` is called *before* the worker is spawned (`Subscription.hs:30`), so the dupTChan exists from the start of catch-up, meaning every broadcast since dupTChan creation is in the worker's queue. The race is benign because the missing events appear in the queue rather than being lost. Confirm with a test.
- `fetchBatch` (`Worker.hs:98-115`) for `Category` uses `readCategoryForwardStmt` (filter-at-source). Correct.
- `processEvents` (`Worker.hs:141-162`) runs the handler, persists checkpoint at batch end if all `Continue`, persists at the Stop event if `Stop`. This is the at-least-once boundary: a crash between any handler call and the next produces re-delivery from the previous checkpoint.

Worker — live phase:
- `liveLoop` (`Worker.hs:78-95`) reads from `dupTChan`. For `AllStreams`, all events pass; for `Category`, `filterEvents` is a no-op and all events pass. Severity: must-fix.
- A handler that returns `Stop` mid-batch in live mode: the checkpoint is persisted at the just-handled event; the worker exits cleanly. Confirm with a test.
- `dupTChan` queue per subscriber: unbounded (see EventPublisher finding). Severity: must-fix (same finding, different observation).

Lifecycle:
- `cancel` in `SubscriptionHandle` calls `Async.cancel`. The worker is in `IO`. Cancellation raises `AsyncCancelled` at the next blocking call — which is either `atomically (readTChan liveChan)` (live phase) or `Pool.use ...` (catch-up phase). Both are safe interruption points for `IO`. Confirm.
- `wait` calls `Async.waitCatch` — returns `Either SomeException ()`. On graceful exit (handler `Stop` or cancellation completing), what does the consumer see?
  - Handler returns `Stop` for some event → worker thread exits normally → `wait` returns `Right ()`.
  - Cancellation → `AsyncCancelled` exception → `wait` returns `Left (SomeException AsyncCancelled)`.
  - Handler throws → exception propagates → `wait` returns `Left e`.
  Confirm; document.
- Cancel during checkpoint save: if cancel fires after the handler returns `Continue` but before `saveCheckpoint`, the events are processed but no checkpoint advance is persisted. On restart they are replayed. Confirm; document as the at-least-once contract.

`Subscription.Effect` higher-order interpreter:
- `localUnliftIO env (ConcUnlift Persistent (Limited 1))` — Persistent means the environment outlives any single handler call (correct, the worker lives across many calls); Limited 1 means at most one unlift at a time (correct, the worker is single-threaded). Document the rationale in a Haddock note on `runSubscription`.
- `wait` from the returned `SubscriptionHandle` is `IO` even when the handler is `Eff`-based. The handle does not lift back into `Eff`. This is an ergonomics gap — coordinate with EP-2.

`Subscription.Stream` Streamly bridge:
- Queue capacity is a `Natural` parameter to `subscriptionStream`. Backpressure: the bridge handler `atomically $ writeTBQueue queue (Just event)` blocks when full. This is consumer-side backpressure — correct for pull-based consumption.
- Cancel writes `Nothing` to the queue to wake any blocked reader (`Subscription/Stream.hs:54-56`). What if the reader is also being cancelled? Confirm no deadlock.
- The bridge ignores the user-supplied handler (`Subscription/Stream.hs:32-33` comment). Document explicitly in Haddock.


### Milestone 2 commands

For each must-fix finding, the workflow is:

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. Add a deterministic regression test
    $EDITOR kiroku-store/test/Main.hs
    cabal test kiroku-store        # confirm new test fails
    # 2. Land the fix (one fix per commit)
    $EDITOR kiroku-store/src/Kiroku/Store/Subscription/{Worker,EventPublisher,Stream,Effect}.hs
    $EDITOR kiroku-store/src/Kiroku/Store/Subscription.hs
    cabal test kiroku-store        # confirm green
    # 3. Commit
    git commit -m "fix(subscription): <one-line summary>

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/3-subscription-system-robustness-audit.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

For the at-least-once contract Haddock, it does not need a regression test but should be reviewed by the user before landing.


## Validation and Acceptance

Milestone 1 is complete when every Audit Checklist item has a finding entry, every cross-plan item is listed in the MasterPlan's Surprises & Discoveries, and the Decision Log records the rationale for every method choice.

Milestone 2 is complete when:

- `cabal test kiroku-store` passes with the new tests included.
- Every must-fix finding has a corresponding commit and regression test.
- The at-least-once contract Haddock is in `Subscription.hs` and `Subscription/Effect.hs`.
- The Decision Log enumerates each fix and each formally deferred should-fix item.
- The MasterPlan's Exec-Plan Registry status for EP-3 is "Complete".

Acceptance behaviours that a human can verify:

- Category live-mode filter test: subscribe to category `"order"`; append events to `order-1`, `user-1`, `order-2` interleaved; the handler should see only `order-*` events. Before the fix, the handler sees `user-1` events too.
- Subscriber backpressure test: subscribe with a deliberately slow handler; append 100,000 events. The publisher's memory should be bounded and the slow subscriber should either be killed (chosen policy) or have its queue capped at the configured limit. Before the fix, memory grows unbounded.
- Replay-on-restart test: append 10 events; subscribe; in the handler, after processing event 5, throw an exception. Restart the subscription. The handler should see events 1..5 again because the checkpoint was last saved before event 5's batch. Confirms the at-least-once contract.


## Idempotence and Recovery

The audit milestone is read-only. The fix milestone produces commits that must each leave the test suite green.

Performance regressions of more than 5% on the existing subscription benchmarks are a stop-the-line condition; the fix must be reformulated. The benchmarks live under `kiroku-store/bench/`.


## Interfaces and Dependencies

Files this plan modifies:

- `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — Category live-mode filter, possibly the `RecordedEvent` shape if the chosen fix adds category data. Note: changes to `RecordedEvent` cross-plan with EP-2 (public types).
- `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` — bounded backpressure, observability hooks (cross-plan with EP-5).
- `kiroku-store/src/Kiroku/Store/Subscription.hs` — at-least-once Haddock; `withSubscription` bracket if landed here (or in EP-2).
- `kiroku-store/src/Kiroku/Store/Subscription/Effect.hs` — at-least-once Haddock; possible `withSubscription` Eff variant.
- `kiroku-store/src/Kiroku/Store/Notification.hs` — observability hook for reconnection (cross-plan with EP-5).
- `kiroku-store/src/Kiroku/Store/SQL.hs` — only if the chosen Category-filter fix needs new SQL (cross-plan with EP-1).
- `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — possible new fields on `SubscriptionConfig` (e.g. queue capacity).
- `kiroku-store/test/Main.hs` — new deterministic regression tests for every must-fix.

External dependencies. No new packages expected.

Module-level interface contracts:

- `Kiroku.Store.Subscription.SubscriptionHandle` — owned by EP-2. This plan may add lifecycle invariants and request `withSubscription` from EP-2.
- `Kiroku.Store.Subscription.subscribe` — owned by this plan; the at-least-once contract is documented here.
- `Kiroku.Store.Types.RecordedEvent` — owned by EP-2; if a field is added (e.g. `category`), coordinate.

Cross-plan integration points (per the MasterPlan):

- EP-1 owns `SQL.hs`. Any new SQL statement here is added by EP-1 on this plan's request.
- EP-2 owns `withSubscription`, `RecordedEvent` field changes, and the broader API contract.
- EP-4 owns multi-tenancy (Notifier already uses schema-scoped channel name; if multi-tenant scoping evolves, the listener must follow).
- EP-5 owns observability metrics (subscriber lag, publisher queue depth, listener reconnections).
- EP-6 owns the test suite restructure including deterministic synchronization.
