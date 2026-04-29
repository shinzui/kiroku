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

- [x] Milestone 1: Audit findings document (2026-04-29; 30 findings F1–F30: 3 must-fix [F1 listener leak, F6 unbounded broadcast, F18 Category live-mode filter] + at-least-once Haddock contract; 8 should-fix [4 cross-plan to EP-5, 4 deferred-with-rationale]; 2 cross-plan to EP-2/EP-6; remainder no-issue)
  - [x] Read every file in `kiroku-store/src/Kiroku/Store/Subscription/` and the supporting `Notification.hs`
  - [x] Trace each delivery path end-to-end (live, catch-up, post-cancellation, post-disconnect, post-handler-Stop) and record what events the consumer sees
  - [x] Classify every finding by severity
  - [x] Cross-link cross-plan findings (Notifier connection failure → EP-5 observability; backpressure → consumer-facing config; etc.) in the MasterPlan
- [x] Milestone 2: Land must-fix corrections (2026-04-29; 76/76 tests pass; adapter 5/5 pass)
  - [x] F1: release reconnected listener connection on shutdown (commit 6041e8f)
  - [x] F18: correct `Category` live-mode filter via DB-driven loop (commit bd107d4)
  - [x] F6: bounded per-subscriber backpressure with overflow policy (commit 2c3f3f4)
  - [x] At-least-once delivery contract Haddock on `Subscription.hs` + `Subscription/Effect.hs` (commit fe69688)
  - [x] Regression tests using deterministic STM/MVar barriers — F1 uses pid round-trip, F18 uses MVar barrier on first catch-up event, F6 uses MVar release + publisher-position synchronisation. Existing `threadDelay`-based tests left untouched per Decision Log; EP-6 owns the conversion.
  - [x] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

### Milestone 1 audit (2026-04-29) — 27 findings

The audit walked every file listed under Concrete Steps and traced every delivery
path. Findings are grouped by component and labelled `EP-3.F<n>`. Severity legend:

  * **Must-fix-before-production** — landing in M2.
  * **Should-fix** — recommended but not blocking; deferred-with-rationale.
  * **No-issue** — confirmed correct; documenting for the deferred-findings register.
  * **Cross-plan** — surfaces in another plan's domain; recorded in MasterPlan.

#### Notifier (`kiroku-store/src/Kiroku/Store/Notification.hs`)

  * **F1 — Reconnected listener connection leaks on shutdown.** *Must-fix.*
    `listenerLoop` (`Notification.hs:66-79`) acquires `newConn` after a connection
    error and recurses with `go newConn`. The fresh connection is held in the
    closure's `currentConn` argument, but `Notifier.listenerConn` (set at
    `startNotifier` time, line 52) still references the *original* connection.
    `stopNotifier` (`Notification.hs:58-62`) calls `Connection.release` on
    `listenerConn` only — the reconnected connection is never released. A long-lived
    store that experiences several listener reconnects across its lifetime leaks
    one Postgres connection per reconnect, all held until process exit. M2 fix
    is to thread the current connection through a `TVar` so `stopNotifier` can
    release whichever connection is current at shutdown time.

  * **F2 — Listener thread dies if reconnection fails.** *Should-fix; defer.* Inside
    the catch handler (`Notification.hs:74-79`), `acquireOrFail connStr` is called
    after the 1-second sleep; if it fails, the exception propagates out of the
    catch (the catch only wraps the `forever waitForNotifications` LHS), the
    recursion is abandoned, and the `Async.async` thread dies. The store's other
    components (publisher, pool) keep running; consumers see no events delivered
    via the listener path, but the publisher's 30-second safety poll still drives
    progress. Severity is *should-fix* because correctness is preserved (events
    still surface, with up-to-30s latency), but observability is poor (no signal
    the listener died). Deferred-with-rationale: the proper fix is a retry loop
    around `acquireOrFail` with backoff, plus an observability hook for "listener
    died after N retries"; both are best done as part of EP-5's observation-handler
    enrichment.

  * **F3 — Reconnection loop has no observability hook.** *Should-fix.* Cross-plan
    with EP-5: every retry burns a `threadDelay 1s` and re-LISTENs silently.
    Recommended fix in EP-5 is to thread the optional `observationHandler` into
    the `Notifier` or add a `notifierObservationHandler` callback so reconnection
    events surface to operators.

  * **F4 — `acquireOrFail` uses `fail`.** *No-issue (documented).* `fail` produces
    an `IOError` that propagates from `withStore`'s acquire phase. Consumers
    catching `IOException` see it; consumers expecting a structured error do not.
    EP-2.M2 already added a structured `SchemaInitError`; an analogous structured
    error for listener-acquire failure could be added in EP-4's lifecycle work
    but the current behaviour is acceptable: a store that cannot establish the
    listener is unusable, and `fail` produces a clear "Notifier: failed to acquire
    connection" message.

  * **F5 — Lifecycle ordering is correct.** *No-issue.* `withStore` (`Connection.hs:125-129`)
    stops the publisher first (which depends on the notifier's tick channel),
    then the notifier (which closes its dedicated connection), then releases the
    pool. Reverse-acquire order. Cancellation propagates correctly via `Async.cancel`
    + `waitCatch`. Confirmed by tracing.

#### EventPublisher (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`)

  * **F6 — Broadcast `TChan` is unbounded.** *Must-fix.* The publisher's
    `broadcastChan :: TChan (Vector RecordedEvent)` (line 42) and each subscriber's
    `dupTChan` (line 85) form an unbounded queue: `writeTChan` never blocks, never
    drops, never retries — it just appends. A subscriber whose handler is slow,
    blocked, or stuck causes its personal `dupTChan` to grow indefinitely; over
    minutes of high-throughput appends this leads to OOM in the host process.
    Other subscribers are unaffected by the slow subscriber's queue (they have
    their own `dupTChan`s), so the failure mode is: one slow subscription
    silently kills the *entire* process. This is the highest-risk finding for
    production. M2 fix is to replace the broadcast model with a per-subscriber
    bounded `TBQueue` and a configurable overflow policy
    (default: cancel the slow subscription with a structured error).

  * **F7 — Pool errors silently swallowed in publisher loop.** *Should-fix; cross-plan
    with EP-5.* `fetchAndBroadcast` (`EventPublisher.hs:104-110`) discards pool
    errors with `Left _err -> pure ()`, relying on the 30-second safety poll for
    eventual retry. There is no observability hook — operators do not learn that
    the publisher cannot reach the database. Cross-plan: EP-5 owns the
    observation-handler enrichment.

  * **F8 — `publisherBatchSize = 1000` hard-coded.** *Should-fix; defer.*
    `EventPublisher.hs:53` defines `publisherBatchSize = 1000`. At very high event
    rates (≫ 1000 events/sec) this caps publisher throughput at one batch per
    DB round-trip. The publisher's tight loop (`fetchAndBroadcast` recurses when
    it gets a full batch) compensates somewhat, but the value is not configurable
    without a code change. Deferred: add to `ConnectionSettings` later if a real
    workload demands it; today's adapter benchmark does not stress this.

  * **F9 — 30-second safety poll can deliver large batches at once.** *No-issue
    (documented).* If the listener is dead and the safety poll is the only source
    of progress, subscribers see up to 30 seconds of events in a single batch
    when the publisher fires. This is the intended correctness fallback. M2
    Haddock should mention the latency expectation.

  * **F10 — Publisher reads `$all` only.** *No-issue.* By design: subscribers that
    need category filtering apply it client-side (or — after F11's fix — drop
    the broadcast entirely for category targets). The publisher cannot
    pre-filter at source because it serves all subscribers, who may want
    different subsets.

  * **F11 — `lastPublished` and `writeTChan` updated atomically.** *No-issue.*
    `EventPublisher.hs:116-118` advances `posVar` in the same `atomically` block
    as the broadcast write. So any worker that reads `pubPos` *after* the broadcast
    sees the new position, and any worker that reads it *before* sees the old
    position and re-runs catch-up. The catch-up converges to live mode invariant
    holds.

  * **F12 — Publisher uses application pool.** *Should-fix; cross-plan with EP-5.*
    `Pool.use pool ...` for the publisher's read takes a connection from the
    same `hasql-pool` that application appends use. Under pool exhaustion, the
    publisher cannot make progress. The 30-second safety poll exacerbates this
    because every safety-poll firing then takes 30+ seconds to recover. EP-5
    should evaluate dedicating one connection to the publisher (similar to the
    Notifier's dedicated `LISTEN` connection).

#### Worker — catch-up phase (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`)

  * **F13 — `loadCheckpoint` swallows DB errors.** *Should-fix; defer.*
    `loadCheckpoint` (`Worker.hs:43-49`) returns `GlobalPosition 0` for both
    "no checkpoint yet" and "DB error reading checkpoint". The latter silently
    re-processes every event. Severity is should-fix — at-least-once handlers
    must be idempotent so the *correctness* impact is bounded — but the
    *observability* impact is poor (no signal that something is wrong).
    Deferred: differentiate via the EP-5 observation-handler enrichment or
    surface as a `SubscriptionResult` variant at that point.

  * **F14 — dupTChan-creation-precedes-thread-spawn invariant holds.** *No-issue.*
    `Subscription.hs:38-43` calls `subscribePublisher` (which dupTChans the
    broadcast channel) *before* `Async.async`, so any broadcast that occurs
    between catch-up's last `pubPos` read and the live-mode entry is queued in
    the worker's dupTChan and observed in the next `readTChan`. No events
    lost. M2 will add a regression test.

  * **F15 — Catch-up race is benign.** *No-issue.* The race "publisher advances
    between `readTVar pubPosVar` and `fetchBatch`" can leave the worker with
    `cursor < newest pubPos` when it exits catch-up, but the events past `cursor`
    are already in the worker's dupTChan (created at subscribe time, before
    spawn — see F14). The worker enters live mode and reads them. Verified
    by code path inspection; M2 will add a regression test.

  * **F16 — `fetchBatch` for `Category` filters at source.** *No-issue.*
    `Worker.hs:111-115` calls `readCategoryForwardStmt` which JOINs `streams`
    on `category = $2`. Correct.

  * **F17 — `processEvents` saves checkpoint at batch tail.** *No-issue (must
    document).* Continue → checkpoint at `globalPosition` of last event in the
    batch; Stop → checkpoint at the just-handled event's position. This is the
    at-least-once boundary: any cancellation or crash between the last handler
    return and the next checkpoint save causes the *whole batch* to replay.
    This is the contract M2 will document explicitly in Haddock.

#### Worker — live phase

  * **F18 — `Category` live-mode does not filter.** *Must-fix.* `Worker.hs:120-136`
    documents this as a Phase 2a simplification: live broadcasts contain all
    events from `$all`, and `filterEvents` for `Category` returns the input
    unchanged. A category subscription in live mode therefore receives events
    from streams in *all* categories. The acceptance test in M2 catches this:
    subscribe to category `"order"`, append events to streams `order-1`,
    `user-1`, `order-2` interleaved while the subscription is in live mode;
    before the fix, the handler sees the `user-1` event too. M2 fix: replace
    the live-mode TBQueue read for category subscriptions with a DB-driven
    loop that wakes on `lastPublished` advancing and queries with
    `readCategoryForwardStmt`. Decision Log records the rationale for this
    over the alternative (extending `RecordedEvent` with `category`).

  * **F19 — Handler returns `Stop` mid-batch in live mode.** *No-issue.*
    `processEvents` saves the checkpoint at the just-handled event and the
    worker exits cleanly. Verified by code path tracing; the existing
    "cancels a running subscription cleanly" test indirectly covers this.

  * **F20 — `liveLoop` does not update `lastPublished`.** *No-issue.* The
    publisher owns `lastPublished`; workers read it during catch-up only.
    A worker's processed position is private to the subscription
    (`subscriptions.last_processed_position` row in the DB). No invariant
    violation.

  * **F21 — `liveLoop`'s `_cursor` is unused.** *No-issue.* Cosmetic; the
    cursor is implicit in the dupTChan/TBQueue. Defer to EP-6 if it does
    a Worker cleanup pass.

#### Lifecycle and cancellation

  * **F22 — Cancel during `atomically (readTBQueue ...)` is safe.** *No-issue.*
    STM blocking operations are interruptible; `Async.cancel` raises
    `AsyncCancelled` which STM unwinds cleanly without a partial commit.

  * **F23 — Cancel during `Pool.use` is safe.** *No-issue.* Hasql sessions
    use interruptible socket reads; cancellation lands at the next blocking
    syscall and the connection is returned to the pool by the bracketed
    handler inside `Pool.use`.

  * **F24 — Cancel after handler-Continue, before `saveCheckpoint`, replays
    events on restart.** *No-issue (the at-least-once contract).* This is
    one of the at-least-once boundaries M2 will document. Same applies to
    cancellation between any two handler calls within `processEvents` —
    the partial work is not checkpointed and replays.

  * **F25 — Handler exception kills the worker thread.** *No-issue (must
    document).* `processEvents` does not catch exceptions thrown by the
    handler; the `Async.async` thread dies and `Async.waitCatch` returns
    `Left e`. M2 Haddock documents this contract: a handler that throws
    terminates the subscription. Consumers that want resilient handlers
    must catch their own exceptions and return `Continue`/`Stop` themselves.

#### Effect interpreter (`kiroku-store/src/Kiroku/Store/Subscription/Effect.hs`)

  * **F26 — `localUnliftIO ConcUnlift Persistent (Limited 1)` rationale.**
    *No-issue.* Already documented in `runSubscription`'s Haddock
    (`Subscription/Effect.hs:80-97`, landed in EP-2 M2). Persistent + Limited 1
    matches the worker's single-threaded design. Verified.

  * **F27 — `wait` is `IO` only.** *Cross-plan with EP-2 (already complete).*
    `SubscriptionHandle.wait :: IO (Either SomeException ())` — there is no
    `Eff`-lifted variant. EP-2.F27 noted this and recommended `withSubscription`
    (which EP-2 landed) as the ergonomic alternative. No M2 work needed here.

#### Streamly bridge (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`)

  * **F28 — Bridge ignores user-supplied handler.** *No-issue.* Documented in
    Haddock (`Subscription/Stream.hs:28-29`).

  * **F29 — Bridge `subscriptionStream` discards `wait`.** *Cross-plan with
    EP-2.F27 (already noted).* The Streamly stream silently hangs if the
    underlying worker crashes. EP-2 owns the lifecycle helper redesign;
    EP-3 does not change behaviour here.

#### Test suite

  * **F30 — Existing subscription tests use `threadDelay`.** *Cross-plan with
    EP-6.* `kiroku-store/test/Main.hs:716-990` synchronises with the publisher
    via `threadDelay 100_000`/`200_000` between subscribe-time and
    append-time. Fragile under load (e.g., on a busy CI runner the publisher's
    safety poll might fire before the appends arrive, or the dupTChan might
    not be ready). EP-6 owns the suite restructure. M2 will add new
    regression tests using deterministic STM/`MVar` barriers from the start;
    converting the existing tests is left to EP-6.

### Cross-plan items routed to MasterPlan

  * **F3, F7, F12, F13** — observability gaps routed to EP-5.
  * **F18 fix touches `SQL.hs`** — additive only (no new statement needed if
    the chosen fix is the DB-driven loop using existing `readCategoryForwardStmt`),
    but if a stream-id-to-category lookup is added later it crosses EP-1's
    domain. Tracked in MasterPlan integration points.
  * **F30** — test suite restructure is EP-6 territory; M2 adds new
    deterministic tests but does not refactor existing ones.

### M2 — Implementation outcomes (2026-04-29)

  * **F1 fix landed (commit 6041e8f).** `Notifier.listenerConn` is now a
    `TVar Connection` updated on each successful reconnection;
    `stopNotifier` releases the *current* connection. Two latent bugs
    surfaced and were fixed alongside: (a) `Hasql.Connection.use`'s
    cleanup-after-interruption can swallow the original exception and
    return `Left DriverSessionError`, in which case `waitForNotifications`
    returns normally rather than propagating; the new loop treats any
    return as a reconnect signal. (b) An async cancellation between
    `acquireOrFail` and the TVar write would have leaked the new
    connection; `bracketOnError` in the reconnect path releases it.
    The connection is now tagged with `application_name = 'kiroku-listener'`
    so the regression test can verify via `pg_stat_activity` that no
    listener backend remains after `withStore` exits.

  * **F18 fix landed (commit bd107d4).** Category subscriptions now use
    `liveLoopCategoryDriven` in `Subscription/Worker.hs`: the worker
    waits via STM for `lastPublished` to advance past its cursor, then
    queries `readCategoryForwardStmt` directly. The broadcast TBQueue
    is unused for Category targets. The dead `filterEvents` helper was
    removed.

  * **F6 fix landed (commit 2c3f3f4).** Replaced the unbounded broadcast
    `TChan` with a per-subscriber registry of bounded `TBQueue`s. New
    config fields: `queueCapacity :: Natural` (default 16 batches) and
    `overflowPolicy :: OverflowPolicy` (default `DropSubscription`). The
    publisher iterates the registry and applies the policy on full;
    `DropSubscription` flips a status `TVar` that the worker observes
    on its next STM read and surfaces as `SubscriptionOverflowed` via
    `Async.waitCatch`. `Subscription.subscribe` wraps `runWorker` in
    `finally unsubscribe` so the publisher's registry is always cleaned
    up. New dependency: `containers` (for `IntMap.Strict`).

  * **At-least-once Haddock landed (commit fe69688).** A "Delivery
    semantics" section on both `Subscription.subscribe` and
    `Subscription.Effect.subscribe` enumerates the replay boundaries
    (cancel-after-Continue, mid-batch cancellation, transient publisher
    pool errors) and the failure-mode table for `wait` (clean exit,
    AsyncCancelled, SubscriptionOverflowed, handler exception).

  * **Deferred-with-rationale.** F2 (listener dies on reacquire failure),
    F3/F7/F12/F13 (observability hooks), F8 (configurable batch size),
    F29 (`subscriptionStream` lifecycle), F30 (existing test refactor).
    Decision Log entries above record each.

  * **Regression evidence.** `cabal test kiroku-store` ends 76/76 passing
    (was 73/73); `cabal test shibuya-kiroku-adapter` ends 5/5 passing.
    Three new tests added: F1 connection-leak verifier, F18 live-mode
    category filter, F6 SubscriptionOverflowed surfacing. Haddock builds
    clean. No existing test was modified.

  * **API impact.** `SubscriptionConfig` gains two required fields
    (`queueCapacity`, `overflowPolicy`); call sites in
    `kiroku-store/test/Main.hs`, `kiroku-store/bench/ShibuyaOverhead.hs`,
    and `shibuya-kiroku-adapter/.../Kiroku.hs` were updated. The
    `defaultSubscriptionConfig` smart constructor sets safe defaults so
    new consumers can adopt without seeing the new fields. The new
    typed exception `SubscriptionOverflowed` is exported from
    `Kiroku.Store.Subscription.Types` (and re-exported via
    `Kiroku.Store`).


## Decision Log

- Decision: Make the at-least-once delivery contract a *required* output of this plan, even if no code changes are needed to honour it. The contract should be in the Haddock for `subscribe`, `Subscription.subscribe`, and `EventHandler`.
  Rationale: Handler authors who do not know the contract will write non-idempotent handlers and silently produce wrong results on subscription restart. This is the single highest-leverage documentation improvement in the package.
  Date: 2026-04-29

- Decision: Fix F18 (Category live-mode filter) by giving Category subscriptions a dedicated DB-driven live loop that bypasses the broadcast entirely, rather than (a) extending `RecordedEvent` with a `category` field or (b) maintaining an in-process `StreamId → CategoryName` cache.
  Rationale: Option (a) modifies the public `RecordedEvent` type owned by EP-2 (already complete) and changes every read path to populate the new field — large blast radius. Option (b) requires a new SQL statement plus an in-memory cache invalidation story (what if a stream is hard-deleted and its id reused?) and still does occasional DB queries on first encounter. The chosen DB-driven loop reuses the existing `readCategoryForwardStmt` (which already filters at source), waits on `lastPublished` advancing via STM, and is structurally identical to a never-exiting catch-up. The cost is one DB query per tick for category subscribers, which is acceptable: typical projection workloads run at ≤ tens of ticks per second after the publisher's debouncing, and the publisher's `publisherBatchSize = 1000` already amortises the round-trip.
  Date: 2026-04-29

- Decision: Fix F6 (unbounded broadcast) by replacing `TChan` + `dupTChan` with a per-subscriber bounded `TBQueue` registry inside the publisher. Default `queueCapacity = 10000` events, default `overflowPolicy = DropSubscription` (cancel the slow subscriber and surface a structured error via `Async.waitCatch`).
  Rationale: Among the three policies (block-publisher, drop-oldest, drop-subscription), only drop-subscription provides head-of-line-blocking-free production safety: a slow subscription cannot affect other subscribers' delivery latency, cannot grow memory unboundedly, and surfaces *as a typed error* the operator can act on. The drop-oldest policy silently corrupts at-least-once into "events sometimes skipped". The block-publisher policy reintroduces the head-of-line problem this fix is supposed to solve. Drop-subscription is the safest default; consumers who prefer drop-oldest can opt in via `overflowPolicy = DropOldest`.
  Date: 2026-04-29

- Decision: Use `Effectful.Exception.bracket` (already imported in `Subscription/Effect.hs`) for the publisher subscriber registry's `bracket (subscribe, unsubscribe)` lifecycle, threading the unsubscribe action through `Subscription.subscribe` rather than expecting callers to remember it. The `cancel` action in the returned `SubscriptionHandle` includes the unsubscribe.
  Rationale: A subscription's queue must be removed from the publisher's registry when the worker terminates, otherwise the publisher writes to a queue with no reader, eventually filling it (and triggering the overflow policy on a subscription that *was* cancelled — wrong signal). Hooking unsubscribe into `cancel` is symmetric with the existing `Async.cancel` and matches the existing `withSubscription` bracket semantics.
  Date: 2026-04-29

- Decision: Defer F2 (listener dies on reacquire failure) to EP-5. The fix is a retry loop with exponential backoff plus an observation-handler hook for "listener died after N retries". EP-5 owns the observation enrichment.
  Rationale: Correctness is preserved today (the publisher's safety poll keeps subscribers fed). Adding a retry loop without the observation hook would mask the failure entirely; better to land both together.
  Date: 2026-04-29

- Decision: Defer F3, F7, F12, F13 (observability gaps in Notifier reconnect, publisher pool errors, publisher pool sharing, checkpoint load errors) to EP-5.
  Rationale: All four are observability holes; EP-5 owns the observation-handler enrichment that exposes them as a coherent set of metrics rather than four independent log lines.
  Date: 2026-04-29

- Decision: Defer F8 (configurable `publisherBatchSize`) until a real workload demands it.
  Rationale: 1000 events per batch handles every workload the adapter benchmark currently stresses. Adding a knob without a concrete demand creates an API commitment with no validation. Revisit if a future stream measures throughput-bound on this constant.
  Date: 2026-04-29

- Decision: Defer F29 (`subscriptionStream` discards `wait`) to a future EP-2/EP-3 collaboration.
  Rationale: The fix requires changing `subscriptionStream`'s return type or introducing a separate "stream + handle" pair, which is an API surface change. EP-2 (already complete) declined to expand the surface in M2; revisit when a consumer reports a real issue. The current behaviour (Streamly stream silently hangs on worker crash) is documented behaviour as of EP-2's findings.
  Date: 2026-04-29

- Decision: Add new regression tests using deterministic STM/`MVar` barriers; do *not* refactor the existing `threadDelay`-based subscription tests.
  Rationale: The existing tests pass under load on the current setup. EP-6 owns the suite restructure and will convert all tests at once. Mixing styles in this commit would confuse the EP-6 work later.
  Date: 2026-04-29


## Outcomes & Retrospective

### What was achieved

EP-3 produced a written audit of the subscription system (30 findings,
F1–F30) and landed every must-fix item plus the at-least-once Haddock
contract:

* **F1** (listener-conn leak on reconnect) → fixed; `Notifier` now
  tracks the current connection in a `TVar` and `stopNotifier` always
  releases the live socket.
* **F6** (unbounded broadcast TChan) → fixed; per-subscriber bounded
  `TBQueue` registry with `OverflowPolicy` (`DropSubscription` default,
  `DropOldest` opt-in) replaces the broadcast model.
* **F18** (Category live-mode passes everything through) → fixed;
  Category subscriptions now use a DB-driven live loop reusing
  `readCategoryForwardStmt`.
* **At-least-once contract** → made explicit in Haddock on both the
  IO and Eff `subscribe` entrypoints.

A second-order benefit: while writing the F1 regression test, we
discovered that `Hasql.Connection.use`'s cleanup-after-interruption can
swallow the original exception and return `Left DriverSessionError`;
the original listener loop's `forever waitForNotifications` would then
loop indefinitely on a dead connection without ever reaching the catch
handler. The new loop treats any return from `waitForNotifications` as
a reconnect signal, so this latent bug is fixed for free.

### What was deferred

Six should-fix items deferred-with-rationale (Decision Log):
F2 (listener dies on reacquire failure), F3/F7/F12/F13 (observability
gaps), F8 (configurable batch size), F29 (`subscriptionStream` discards
`wait`), F30 (existing test refactor). All routed to EP-5 or EP-6 with
a Decision Log entry naming the rationale.

### Lessons learned

  * Reading the dependency's source matters. The `Hasql.Connection.use`
    error path was not obvious from its type signature; the original
    Notifier code looked correct on paper. The fix had to detect that
    `waitForNotifications` *returning* (rather than throwing) means a
    swallowed error.

  * The bounded-backpressure refactor (F6) had a wide blast radius —
    `SubscriptionConfig` gained two required fields, every call site in
    tests, benchmarks, and the adapter had to be updated. The
    `defaultSubscriptionConfig` smart constructor (added in EP-2) made
    this less painful; future API changes should land alongside an
    update to the smart constructor.

  * Choosing `DropSubscription` over `DropOldest`/`BlockPublisher` as
    the default is a production-safety decision: surfacing a typed
    error is better than silently corrupting at-least-once semantics.
    Consumers who prefer best-effort delivery opt in explicitly.

  * The DB-driven Category live loop (F18) is structurally a
    never-exiting catch-up; the implementation collapses to ~10 lines
    once the broadcast detour is removed. Category subscriptions are
    now strictly simpler than AllStreams subscriptions, despite being
    more "specialised." Worth flagging for EP-6 if it does a worker
    cleanup pass.

### Production-readiness verdict for the subscription subsystem

Subscriptions are now production-ready in the following sense:

* No correctness bugs remain in the delivery path. Category filtering
  works in both catch-up and live modes; AllStreams broadcast is
  bounded; the listener does not leak connections on reconnect.
* The at-least-once contract is documented; handler authors who read
  the Haddock will know what idempotence guarantees they must provide.

Operational polish remains: observability gaps (F3, F7, F12, F13)
mean operators have limited visibility into reconnect storms, publisher
pool errors, and checkpoint-load failures. EP-5 owns this work. The
listener still dies on reacquire failure (F2) — correctness is
preserved by the publisher's safety poll, but a long DB outage will
leave the listener thread dead until process restart. EP-5 should
bundle this with the observation-handler enrichment.


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
