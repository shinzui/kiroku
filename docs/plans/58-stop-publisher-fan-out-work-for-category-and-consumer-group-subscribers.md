---
id: 58
slug: stop-publisher-fan-out-work-for-category-and-consumer-group-subscribers
title: "Stop publisher fan-out work for category and consumer-group subscribers"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Stop publisher fan-out work for category and consumer-group subscribers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a Postgres-backed event store. Every running store contains one background
"event publisher" thread (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`)
whose job is to read newly appended events from the database once and hand them to live
subscribers through bounded in-memory queues, so that many subscribers do not each poll
the database. Today that machinery does two kinds of work it should not do:

1. **Every subscription gets a publisher queue, but most never read it.** The
   `subscribe` function in `kiroku-store/src/Kiroku/Store/Subscription.hs` registers a
   bounded queue with the publisher for *every* subscription, yet only one of the three
   subscription shapes — a non-consumer-group subscription to all streams — ever reads
   that queue. Category subscriptions and consumer-group subscriptions go live through
   database-driven loops and never touch it. For them the queue silently fills to
   capacity (by default 16 batches of up to 1000 events each — potentially tens of
   megabytes of pinned event payloads per subscription, held for the subscription's
   whole lifetime), the publisher then burns work applying an overflow policy nobody
   observes, and one policy (`DropSubscription`) is outright inert: it sets a flag the
   category/group worker never reads, so the configured behavior simply does not happen.

2. **The publisher fetches full event rows even when nobody can consume them.** On
   every wakeup the publisher runs the full `$all`-stream read (1000-row batches, full
   JSON payloads, plus the user-supplied `decodeHook` transformation) even when its
   subscriber registry is empty. The only thing every other component actually needs
   from an idle publisher is its `lastPublished` position counter, which can be advanced
   with a single-row `SELECT`.

After this change: a process running only category and/or consumer-group subscriptions
holds **zero** publisher queues (no pinned batches, no overflow-policy churn, no inert
policy), and its publisher advances its position with a cheap single-row query instead
of fetching and decoding every appended event. You can see it working by running the new
tests in the `kiroku-store` test suite: one asserts the publisher's subscriber registry
stays empty while category/group subscriptions run; another counts `decodeHook`
invocations to prove the publisher fetches no rows while only non-queue subscribers
exist; and the existing subscription suite proves catch-up-to-live correctness for all
three subscription shapes is unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Check the implementation state of EP-1 (docs/plans/56) and record in this plan's Decision Log whether its `subscribe` bracketing has landed (it changes where the conditional registration slots in). Completed 2026-06-14: EP-1's `mask` + nested `bracketOnError` shape is present in `Kiroku.Store.Subscription.subscribe`, and the EP-3 conditional acquisition is being slotted into that acquire step.
- [x] M1: Define the `LiveSource` type in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` and thread it through `runWorker` in place of the unconditional `TBQueue`/`TVar SubscriberStatus` parameters. Completed 2026-06-14.
- [x] M1: Make `subscribe` in `kiroku-store/src/Kiroku/Store/Subscription.hs` call `Pub.subscribePublisher` only for non-group `AllStreams` subscriptions; no-op unsubscribe otherwise; preserve the cleanup/bracket structure. Completed 2026-06-14.
- [x] M1: Update the haddocks on `subscribe`, `runWorker`, and `SubscriptionConfigM` (`queueCapacity`/`overflowPolicy` apply only to non-group `AllStreams`). Completed 2026-06-14.
- [x] M1: Add registry-emptiness assertions (category-only, group-only, mixed, and unsubscribe-on-cancel) to `kiroku-store/test/Test/SubscriptionRegistry.hs`. Completed 2026-06-14.
- [x] M1: `just build` and `cabal test kiroku-store:kiroku-store-test` green; commit. Completed 2026-06-14; `kiroku-store-test` passed with 198 examples, 0 failures.
- [ ] M2: Restructure `fetchAndBroadcast` in `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` to snapshot the registry first and take a cheap-advance path (single-row `currentGlobalPositionStmt` + STM re-check) when the registry is empty.
- [ ] M2: Close the full-fetch attach race (Finding C): advance `lastPublished` and re-read the registry in one STM transaction after delivery, enqueueing the in-flight batch to late registrants; add a deterministic regression test (gate the publisher mid-broadcast via `decodeHook`, register a subscriber, assert no global position is skipped).
- [ ] M2: Add new test module `kiroku-store/test/Test/PublisherIdleAdvance.hs` (zero-subscriber advance with zero decode calls; category-only no-fetch; register-mid-stream transition with no gaps), register it in `kiroku-store/kiroku-store.cabal` and `kiroku-store/test/Main.hs`.
- [ ] M2: Update the `EventPublisher` module header and `startPublisher` haddock to describe the two-mode loop; `cabal test kiroku-store:kiroku-store-test` green; commit.
- [ ] M3: Run the full suite (`just test`) covering all three subscription target shapes; optionally run `just bench-regression`; record evidence in this plan.
- [ ] M3: Update `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md` (EP-3 registry row status, the two EP-3 progress checkboxes); write this plan's Outcomes & Retrospective; commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Replace `runWorker`'s unconditional `TBQueue (Vector RecordedEvent)` and
  `TVar SubscriberStatus` parameters with a single per-target `LiveSource` sum type
  (queue-fed / category-notify / group-db-driven), computed once in `subscribe`, rather
  than passing `Maybe (TBQueue, TVar)` alongside the existing
  `(consumerGroup, target)` dispatch.
  Rationale: the worker currently dispatches its live strategy by re-inspecting the
  config in `nextInput`; a bare `Maybe` would leave two parallel sources of truth (the
  config shape and the queue's presence) that can disagree. A dedicated sum makes the
  invariant "only non-group AllStreams owns a queue" a matter of construction in one
  place (`subscribe`), makes the `Paused` branch's queue access total by pattern match,
  and is self-documenting at the call site.
  Date: 2026-06-11

- Decision: In the worker's `Paused` state, the non-queue `LiveSource` constructors
  return `QueueDrained` immediately (a defensive no-op) instead of calling `error`.
  Rationale: the FSM only enters `Paused` via the `QueueBackpressured` input, which only
  the queue-fed live branch produces, so the case is unreachable by construction — but a
  total, harmless handler is preferable to a partial function in a long-lived worker
  thread. The unreachability argument is recorded in a code comment.
  Date: 2026-06-11

- Decision: The publisher's cheap-advance path re-checks registry emptiness *inside the
  same STM transaction* that writes `lastPublished`, and falls through to a full row
  fetch if a subscriber registered concurrently.
  Rationale: without the atomic re-check there is a real lost-event window: a subscriber
  whose `subscribePublisher` registration commits after the publisher's registry
  snapshot but before the cheap position write could finish catch-up against the *old*
  position, go live blocked on its queue, and permanently miss the events the cheap
  advance skipped over (they were never enqueued and its checkpoint gate never re-reads
  them). The atomic re-check makes the two commit orders both safe; see "Why the
  transition edge is safe" in Plan of Work, Milestone 2.
  Date: 2026-06-11

- Decision: Do not validate or reject `queueCapacity` / `overflowPolicy` on category or
  consumer-group configs; document them as inert for those targets instead.
  Rationale: `defaultSubscriptionConfig` (see `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`,
  around line 336) populates both fields for every config, so every existing caller
  "sets" them; rejecting would break all category/group callers for no behavioral gain.
  After this plan the fields are structurally unused for those targets (no queue exists),
  which is strictly better than today's silently-inert `DropSubscription`.
  Date: 2026-06-11

- Decision: Measure "the publisher fetched no rows" via `decodeHook` invocation counts
  (the `StoreSettings` hook the publisher applies to every fetched batch) rather than
  adding a new `KirokuEvent` constructor for publisher fetches.
  Rationale: `decodeHook` already fires exactly once per row fetched by the publisher's
  broadcast path (`decodeEvents` in `fetchAndBroadcast`), the counting pattern already
  exists in `kiroku-store/test/Test/InterpreterHooks.hs`, and `KirokuEvent` is a public
  exported sum that EP-1 (docs/plans/56) is concurrently extending with a publisher
  liveness signal — adding another constructor here would invite churn and merge
  conflicts. The tests are designed so no *worker* fetch can run in the measured window,
  making attribution unambiguous (see Milestone 2 test design).
  Date: 2026-06-11

- Decision: This plan SOFT-depends on EP-1
  (`docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`)
  and must *extend, not rewrite*, the exception-safe bracketing EP-1 adds around
  publisher-queue registration in `subscribe`; EP-1 should ideally land first.
  Rationale: per the master plan (docs/masterplans/9, "Integration Points"), EP-1 adds
  masking/bracketing around the register-then-fork window in
  `kiroku-store/src/Kiroku/Store/Subscription.hs` and wraps the publisher loop's
  exception envelope in `EventPublisher.hs`; this plan changes *what* is registered
  (conditionally, per target) and *what* the loop fetches, but the acquire/release
  structure and the loop's exception envelope belong to EP-1. If EP-1 has not landed
  when this plan starts, implement against the current `finally`-based cleanup and note
  it here so the EP-1 author slots the conditional acquisition into their bracket.
  Date: 2026-06-11

- Decision: Fix the full-fetch attach race (Finding C) in this plan's Milestone 2 by
  delivering the in-flight batch to late registrants inside the same STM transaction
  that advances `lastPublished`, rather than (a) assigning the fix to EP-1 or
  (b) advancing the position before delivery.
  Rationale: (a) EP-1 owns the publisher loop's *exception envelope*, not its
  delivery/advance ordering, and this plan's M2 already rebuilds `fetchAndBroadcast`
  around exactly this atomic snapshot-recheck-plus-write shape — fixing the race here is
  the same edit, in the same tested function. (b) Advancing `lastPublished` before
  delivery also closes the attach race (a late registrant's catch-up gate would see the
  advanced position and re-read the batch from SQL) but opens a crash-loss window under
  EP-1's continue-on-error policy: if the loop's iteration dies between the advance and
  the delivery, the next iteration refetches from the already-advanced position and the
  batch is never enqueued for *existing* live AllStreams workers. Late-registrant
  delivery has neither problem; duplicates are impossible for the snapshot cohort and
  filtered by `> cursor` for the late cohort. The race was discovered 2026-06-11 while
  drafting docs/plans/61 (EP-6) and is recorded in the master plan's Surprises section.
  Date: 2026-06-11

- Decision: Pruning the `categoryGenerations` map in
  `kiroku-store/src/Kiroku/Store/Notification.hs` is explicitly OUT of scope.
  Rationale: master-plan decision (docs/masterplans/9, Decision Log, "Defer these
  LOW/INFO findings"): the map is bounded by category cardinality in practice; deferred
  without a child plan.
  Date: 2026-06-11

- Decision: EP-1's exception-safe `subscribe` bracketing has landed before EP-3
  implementation began, so conditional publisher registration is implemented inside
  that existing `bracketOnError` acquisition rather than by adding a second lifecycle
  bracket.
  Rationale: the current `subscribe` code already uses `mask`, `bracketOnError` for
  publisher acquisition, and a second `bracketOnError` for state-registry insertion.
  Keeping EP-3's conditional queue acquisition in the first acquisition preserves
  EP-1's async-exception safety and avoids competing cleanup paths.
  Date: 2026-06-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained: it defines every term and names every file you need.
All paths are relative to the repository root (`kiroku`).

### What the pieces are

**Event store.** `kiroku-store` is a Haskell library implementing an event store on
PostgreSQL: appenders write immutable events to named streams; every event also gets a
strictly monotonic **global position** on a virtual `$all` stream (implemented as the
row `stream_id = 0` in the `streams` table, whose `stream_version` column is the current
global tail). "Catch-up" reads page through history with SQL; "live" delivery pushes new
events to subscribers as they are appended.

**Subscription.** A long-lived consumer created by `subscribe` in
`kiroku-store/src/Kiroku/Store/Subscription.hs` (lines 105–171 at the time of writing).
A subscription has a durable **checkpoint** (a row in the `subscriptions` table keyed by
subscription name and consumer-group member) recording the last processed global
position, so a restart resumes where it left off. Each subscription has a **target**
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`): `AllStreams` (every event) or
`Category CategoryName` (only streams whose name prefix matches a category, filtered in
SQL). Independently, a subscription may belong to a **consumer group**
(`consumerGroup :: Maybe ConsumerGroup`): N processes each take a deterministic
hash-partition of streams, again filtered in SQL. That yields three live-delivery
shapes, dispatched in the worker:

- non-group + `AllStreams` — the only shape that consumes the publisher's queue;
- non-group + `Category` — wakes on a per-category counter, re-queries the DB;
- any consumer-group member (either target) — wakes when the global position advances,
  re-queries the DB with the partition predicate.

**Worker.** `runWorker` in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`
(signature at lines 132–155) is the thread behind each subscription. It drives a pure
finite-state machine (FSM, in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`) whose
states are `CatchingUp`, `Live`, `Paused` (recoverable backpressure), `Reconnecting`,
`Retrying`, `Stopped`. The dispatch among the three live shapes is `nextInput`'s `Live`
case at Worker.hs lines 228–248: the `(Nothing, AllStreams)` branch reads the
publisher's queue (with a staleness filter `V.filter ((> c) . globalPosition)` at line
243 — remember this filter, the correctness argument in Milestone 2 leans on it); the
`(Nothing, Category …)` branch runs `liveLoopCategoryNotify` (lines 433–480); the
`(Just _, _)` branch runs `liveLoopDbDriven` (lines 499–537). The `runWorker` haddock
itself says (line 111): "the broadcast TBQueue is unused for category subscriptions".
Catch-up for *every* shape (the `CatchingUp` branch, lines 216–227) fetches from the
database via `fetchBatch` (lines 542–576) until its cursor reaches the publisher's
`lastPublished` position — so every worker, queue-consuming or not, depends on
`lastPublished` advancing. `liveLoopDbDriven` additionally *gates* on `lastPublished`
advancing (lines 512–517).

**Event publisher.** `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`.
One per store (`startPublisher`, lines 136–162; held in the `publisher` field of
`KirokuStore` in `kiroku-store/src/Kiroku/Store/Connection.hs`, line 146). It keeps a
registry `subscribers :: TVar (IntMap Subscriber)` of bounded queues, and a
`lastPublished :: TVar GlobalPosition`. Its loop (`publisherLoop`, lines 200–273) wakes
on a NOTIFY tick from the **notifier** (`kiroku-store/src/Kiroku/Store/Notification.hs`,
which LISTENs on a dedicated connection and also bumps per-category generation counters)
or on a 30-second safety poll, then runs `fetchAndBroadcast` (lines 219–251): read up to
1000 full event rows past `lastPublished` with `SQL.readAllForwardStmt`, apply the
user-configurable **decodeHook** (`StoreSettings.decodeHook`,
`kiroku-store/src/Kiroku/Store/Settings.hs` line 70, applied via `decodeEvents` line
94 — a per-event `RecordedEvent -> IO RecordedEvent` transformation), deliver the batch
to every registered queue (`deliverBatch`, lines 253–273), then advance `lastPublished`.
On overflow of one subscriber's queue, `deliverBatch` applies that subscriber's
**overflow policy** (`OverflowPolicy` in Subscription/Types.hs): `PauseAndResume` (the
default — set a `Paused` flag and stop pushing; the worker drains and re-catches-up),
`DropOldest` (evict the oldest batch), or `DropSubscription` (set `Overflowed`; the
queue-reading worker throws `SubscriptionOverflowed`).

**The cheap position query.** `currentGlobalPositionStmt` in
`kiroku-store/src/Kiroku/Store/SQL.hs` (lines 447–452) is
`SELECT stream_version FROM streams WHERE stream_id = 0` — a single-row primary-key read
of the global tail. `startPublisher` already uses it once at startup (line 150) to seed
`lastPublished`. By contrast `readAllForwardStmt` (lines 431–436, SQL at lines 507+)
joins `stream_events` to `events` and returns full payload rows.

**The other registrant.** `subscribe` is not the only caller of `subscribePublisher`:
the WebSocket event tail in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` (line 366)
registers a transient queue directly for live "$all" tailing. This is a genuine
queue-consuming subscriber, and because it goes through the same registry, the
registry-emptiness check in Milestone 2 automatically accounts for it. No change to
`kiroku-metrics` is needed.

### The three defects this plan fixes (audit findings, verified 2026-06-10/11)

**Finding A (MEDIUM — memory waste and an inert policy).** `subscribe`
(Subscription.hs lines 113–118) calls `Pub.subscribePublisher` unconditionally, so
category and consumer-group subscriptions each own a publisher queue they never read.
Consequences, per such subscription, for its whole lifetime: the queue fills to capacity
(default `queueCapacity = 16` batches × up to 1000 `RecordedEvent`s with full JSON
payloads — potentially tens of megabytes pinned); under the default `PauseAndResume` the
publisher flips it `Paused` and skips it forever after; under `DropOldest` it rotates
the queue on every fetched batch (pure STM churn); under `DropSubscription` it sets
`Overflowed` — a flag only the queue-reading live branch (Worker.hs lines 232–235) ever
observes — so the configured policy is silently inert.

**Finding B (MEDIUM — wasted database and decode work).** `fetchAndBroadcast`
(EventPublisher.hs lines 219–251) runs `readAllForwardStmt` and `decodeEvents` on every
tick and every safety poll regardless of registry contents. With zero queue-consuming
subscribers (the common deployment shape once Finding A is fixed: processes running only
category/group subscriptions), all of that work produces nothing except the side effect
of advancing `lastPublished` — which a single-row `currentGlobalPositionStmt` provides.
`lastPublished` must keep advancing even with an empty registry, because every worker's
catch-up gate and the consumer-group live gate read it.

**Finding C (MEDIUM — event loss on attach; discovered 2026-06-11 while drafting
docs/plans/61, pre-existing in today's code).** The full-fetch path has the same race
this plan's cheap-advance path defends against, and it loses events rather than work.
`fetchAndBroadcast` snapshots the registry (`readTVarIO subsVar`, EventPublisher.hs line
240), delivers the fetched batch to that snapshot, and only afterwards advances
`lastPublished` (line 247). A subscriber whose `subscribePublisher` registration commits
between the snapshot and the position write never receives that in-flight batch through
its queue — and the loss can be permanent, not merely late. Call the pre-advance
position P0 and the batch's last position P1. The new worker's catch-up gate
(`nextInput CatchingUp` in Worker.hs, the `c >= pubPos` check) still reads P0, so a
worker whose saved checkpoint `c` already sits in `[P0, P1)` declares itself caught up
immediately, goes `Live`, and blocks on a queue the batch never reached. Every later
batch starts above P1 and passes the worker's `> cursor` staleness filter, so the events
in `(c, P1]` are silently skipped until something forces a re-catch-up (a pause or a
reconnect). The fix belongs to this plan's Milestone 2, which already rebuilds this
function: after delivering to the snapshot, advance `lastPublished` and re-read the
registry in **one** STM transaction, delivering the in-flight batch to any subscriber
that registered after the snapshot (their queues are freshly created and empty, so the
enqueue cannot block; any duplicate arriving later via their own SQL catch-up is dropped
by the worker's `> cursor` filter). This is the same atomic snapshot-recheck-plus-write
shape Milestone 2 uses on the cheap-advance path.

### Relationship to EP-1 (soft dependency)

This plan is **EP-3** of the master plan
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.
It has no hard dependencies but **SOFT-depends on EP-1**
(`docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`),
because both plans modify the same two files: `subscribe` in
`kiroku-store/src/Kiroku/Store/Subscription.hs` and the publisher loop in
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. The master plan's
Integration Points section fixes the division of labor: EP-1 adds masking/bracketing
around the register-then-fork window in `subscribe` (so every acquired resource —
publisher-queue registration, state-registry entry — is released on every exit path,
including async exceptions before the worker thread exists) and wraps the publisher
loop's exception envelope; **this plan must extend that bracketing — making the
acquisition conditional on the subscription target — not rewrite it**, and must preserve
EP-1's exception envelope around the loop body. EP-1 should land first. Plan 56 is now
fully authored: its Milestone 3 specifies `mask` plus nested `bracketOnError` around the
acquisition-then-fork window. Check its implementation state when you start: if EP-1's
bracket has landed, slot the conditional acquisition into its acquire step (do not
introduce a second, competing bracket); if it has not, implement against the code as it
stands (the `finally cleanup` structure at Subscription.hs lines 142–161) and record in
this plan's Decision Log and Surprises sections that EP-1 must thread its bracket around
the now-conditional acquisition.

Explicitly OUT of scope (master-plan decision): pruning the `categoryGenerations` map in
`kiroku-store/src/Kiroku/Store/Notification.hs` (deferred; bounded by category
cardinality in practice).

### Building and testing

The repository is a cabal multi-package project (`cabal.project` at the root) with a Nix
flake providing the toolchain. Enter the dev shell first if your environment does not
already have GHC 9.12.4 and cabal on PATH:

```bash
cd /path/to/kiroku
nix develop          # only if cabal/ghc are not already available
just build           # = cabal build all
just test            # = cabal test all
```

The kiroku-store suite alone (the one this plan touches) is:

```bash
cabal test kiroku-store:kiroku-store-test
```

The suite (`kiroku-store/test/Main.hs`) wraps everything in
`withSharedMigratedPostgres` from `kiroku-test-support` (`Kiroku.Test.Postgres`), which
boots a throwaway PostgreSQL via `ephemeral-pg` and runs the schema migrations — no
external database or `just up` is required for tests. Individual specs obtain a fresh
database with `withMigratedTestDatabase` and build stores with helpers from
`kiroku-store/test/Test/Helpers.hs`: `withTestStoreSettings` (line 80), `makeEvent`,
`waitForPublisher` (line 267 — STM-blocks until `lastPublished` reaches a target; this
helper is also the proof that cheap advance works), `waitForSubscriptionLive` +
`caughtUpEventHandler` (lines 279–300 — an MVar barrier opened by the
`KirokuEventSubscriptionCaughtUp` observability event). To run a subset, pass an hspec
match:

```bash
cabal test kiroku-store:kiroku-store-test --test-options='--match "publisher"'
```


## Plan of Work

The work is three milestones. Milestone 1 makes publisher-queue registration conditional
on the subscription shape (Finding A). Milestone 2 teaches the publisher to advance its
position cheaply when its registry is empty (Finding B) — it builds on Milestone 1,
because only after M1 does "registry empty" coincide with "only category/group
subscriptions running". Milestone 3 is the integration validation sweep and master-plan
bookkeeping. Commit at the end of each milestone with a Conventional Commits message
(examples given per milestone).

### Milestone 1 — Only non-group AllStreams subscriptions register a publisher queue

*Scope.* Restructure the worker's live-input parameters around an explicit per-target
`LiveSource` value and make `subscribe` register with the publisher only when the worker
will actually read the queue. At the end of this milestone, starting a category or
consumer-group subscription leaves the publisher's `subscribers` IntMap untouched
(observable from a test via the exported `subscribers` field), all three shapes still
pass the existing suite, and the new registry assertions pass.

*Why a new type.* `runWorker` currently always receives `liveQueue :: TBQueue (Vector
RecordedEvent)` and `statusVar :: TVar SubscriberStatus` (Worker.hs lines 132–155) and
*separately* re-derives the live strategy from `(consumerGroup config, target config)`
in `nextInput` (lines 228–248). If we merely made the queue optional (`Maybe`), the
config shape and the queue's presence would be two parallel sources of truth that could
disagree. Instead, compute the strategy once, in `subscribe`, as a sum type that carries
the queue only in the branch that owns one.

*Edits, in order.*

1. In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, define and export a new
   type (place it near the top of the module, after the imports; add `LiveSource (..)`
   to the export list):

   ```haskell
   -- | How a worker obtains live-mode batches, fixed at 'subscribe' time from the
   -- config's (consumerGroup, target) shape. Only 'LiveFromPublisherQueue' owns a
   -- registration with the EventPublisher; the other shapes are DB-driven and the
   -- publisher must do no fan-out work for them (ExecPlan 58 / MasterPlan 9 EP-3).
   data LiveSource
       = -- | Non-group AllStreams: read the publisher's bounded queue; the status
         -- TVar carries Paused/Overflowed backpressure signals.
         LiveFromPublisherQueue !(TBQueue (Vector RecordedEvent)) !(TVar SubscriberStatus)
       | -- | Non-group Category: wake on the named category's NOTIFY generation
         -- counter and re-query the database ('liveLoopCategoryNotify').
         LiveFromCategoryNotify !Text
       | -- | Consumer-group member (either target): wake when the global position
         -- advances and re-query with the partition predicate ('liveLoopDbDriven').
         LiveFromGroupPolling
   ```

2. Change `runWorker`'s signature: replace the two parameters
   `TBQueue (Vector RecordedEvent) ->` and `TVar SubscriberStatus ->` with
   `LiveSource ->` (keep the position: second argument, after `Pool`). Rename the
   binding from `liveQueue`/`statusVar` to `liveSource`. The `catGenVar` and
   `pubPosVar` parameters stay — `LiveFromCategoryNotify` still needs the generation
   map and `LiveFromGroupPolling` still needs the position TVar.

3. In `nextInput` (Worker.hs lines 228–248), dispatch the `Live c` case on `liveSource`
   instead of `(consumerGroup config, target config)`:

   ```haskell
   Live c -> case liveSource of
       LiveFromPublisherQueue liveQueue statusVar -> do
           writeIORef posRef c
           atomically $ do
               status <- readTVar statusVar
               ... -- body unchanged from the current (Nothing, AllStreams) branch
       LiveFromCategoryNotify cat ->
           liveExitToInput =<< liveLoopCategoryNotify pool config stateVar catGenVar cat emit posRef c stSettings
       LiveFromGroupPolling ->
           liveExitToInput =<< liveLoopDbDriven pool config stateVar pubPosVar emit posRef c stSettings
   ```

   The bodies of all three branches are unchanged; only the scrutinee changes. Note
   `fetchBatch` (lines 542–576) still dispatches its SQL on
   `(consumerGroup config, target config)` — leave it alone; it serves catch-up and the
   DB-driven loops for all four config shapes and has nothing to do with the queue.

4. In the `Paused{}` branch of `nextInput` (lines 256–260, which drains the queue and
   clears the status flag), match on `liveSource`: for `LiveFromPublisherQueue q sv`
   keep the current drain-and-clear body; for the other two constructors return
   `pure QueueDrained` with a comment that the FSM only enters `Paused` via the
   `QueueBackpressured` input, which only the queue branch produces, so this is
   defensive totality, not a live path (see Decision Log).

5. Update the `runWorker` haddock (lines 106–131): phase 2 now reads "for
   `LiveFromPublisherQueue`, reads from the bounded TBQueue the publisher delivers to;
   for `LiveFromCategoryNotify` / `LiveFromGroupPolling`, re-queries the database — no
   publisher queue exists for these shapes." Delete the parenthetical "(the broadcast
   TBQueue is unused for category subscriptions)".

6. In `kiroku-store/src/Kiroku/Store/Subscription.hs`, replace the unconditional
   registration (lines 113–118) with a conditional acquisition that yields the
   `LiveSource` and the matching release action:

   ```haskell
   (liveSource, unsubscribe) <- case (consumerGroup config, target config) of
       (Nothing, AllStreams) -> do
           (queue, statusVar, unsub) <-
               atomically $
                   Pub.subscribePublisher
                       (store ^. #publisher)
                       (queueCapacity config)
                       (overflowPolicy config)
           pure (LiveFromPublisherQueue queue statusVar, unsub)
       (Nothing, Category (CategoryName cat)) ->
           pure (LiveFromCategoryNotify cat, pure ())
       (Just _, _) ->
           pure (LiveFromGroupPolling, pure ())
   ```

   You will need to import `LiveSource (..)` from
   `Kiroku.Store.Subscription.Worker` and `CategoryName (..)` from
   `Kiroku.Store.Types`. The existing `cleanup = unsubscribe >> atomically (…registry
   delete…)` (lines 142–153) keeps its shape — for non-queue shapes `unsubscribe` is
   `pure ()` and cleanup degenerates to the registry delete. **Bracketing rule:** if
   EP-1 (docs/plans/56) has landed, its Outcomes section documents the mask/bracket it
   wrapped around acquisition-then-fork — slot this `case` inside EP-1's acquire step
   so the conditional registration is covered by the same async-exception protection;
   do not introduce a second, competing bracket. If EP-1 has not landed, keep today's
   structure (acquire, registry-insert, `Async.async (runWorker … \`finally\`
   cleanup)`) and note the hand-off in this plan's Decision Log.

7. Update the call to `runWorker` (line 159): pass `liveSource` in place of
   `queue statusVar`.

8. Update the `subscribe` haddock: the step-3 description (lines 46–51) is still
   accurate; extend the failure-modes bullet about `SubscriptionOverflowed` (lines
   93–99) and the `queueCapacity`/`overflowPolicy` field docs in
   `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` (lines 245–252) to state that
   the queue, its capacity, and the overflow policy exist **only** for non-group
   `AllStreams` subscriptions; for category and consumer-group subscriptions no
   publisher queue is created and these fields have no effect.

9. Tests. Extend `kiroku-store/test/Test/SubscriptionRegistry.hs` with a spec (name it
   e.g. `describe "publisher queue registration"`) asserting, via the exported
   `subscribers` field of `EventPublisher` (import
   `Kiroku.Store.Subscription.EventPublisher (EventPublisher (..))` and read
   `IntMap.size <$> readTVarIO (subscribers (store ^. #publisher))`):

   - after subscribing a `Category` subscription, registry size is 0;
   - after subscribing a consumer-group member (`consumerGroup = Just (ConsumerGroup 0 2)`,
     either target), registry size is still 0;
   - after additionally subscribing a non-group `AllStreams` subscription, size is 1;
   - after cancelling that AllStreams subscription (and `waitCatch`), size returns
     to 0 — proving the conditional release still runs;
   - cancelling the category/group subscriptions never changes the count.

   These are behavioral memory-shape assertions: "a category subscription's process
   holds no publisher queue" is exactly "the publisher's registry has no entry for it",
   and the inert-`DropSubscription` defect becomes structurally impossible (no queue ⇒
   no overflow ⇒ no flag nobody reads).

*Acceptance for M1.* `just build` succeeds; `cabal test
kiroku-store:kiroku-store-test` is green, including the new registry assertions and all
pre-existing specs for the three shapes (`Test.Category`, `Test.CategoryIdleNoSpin`,
`Test.ConsumerGroup*`, `Test.SubscriptionPauseResume`, `Test.SubscriptionReconnect`,
`Test.PublisherRestartNoRebroadcast`). Commit as:

```text
feat(kiroku-store)!: register publisher queues only for non-group AllStreams subscriptions
```

(The `!` is because `runWorker`'s signature changes; it is an exposed module. The
public `subscribe` API is unchanged.)

### Milestone 2 — Publisher advances by single-row query when no queue subscriber exists

*Scope.* Change `fetchAndBroadcast` so that with an empty subscriber registry the
publisher advances `lastPublished` using `SQL.currentGlobalPositionStmt` (single-row
read of `streams.stream_version where stream_id = 0`) instead of fetching and decoding
event rows; full-row fetching resumes the moment any queue subscriber registers. At the
end of this milestone, an instrumented test shows zero `decodeHook` calls while only
category/group subscribers (or no subscribers) exist, while `waitForPublisher` still
observes `lastPublished` reaching the tail, and a transition test shows a subscriber
registering between cheap-advance cycles misses nothing.

*Edit.* In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`, restructure
`fetchAndBroadcast` (lines 219–251) into a dispatcher and two paths:

```haskell
fetchAndBroadcast = do
    subs <- readTVarIO subsVar
    if IntMap.null subs then cheapAdvance else fullFetch

-- No queue-consuming subscriber is registered: nobody can receive a broadcast
-- batch, but lastPublished must keep advancing — every worker's catch-up gate
-- and the consumer-group live gate read it. Advance it from the $all tail
-- (streams.stream_id = 0) with a single-row read instead of fetching rows.
cheapAdvance = do
    result <- Pool.use pool (Session.statement () SQL.currentGlobalPositionStmt)
    case result of
        Left err -> for_ mHandler ($ KirokuEventPublisherPoolError err)
        Right tailPos -> do
            -- Re-check emptiness in the SAME transaction as the position write:
            -- if a subscriber registered after our snapshot, do NOT advance past
            -- events its queue never received — fall through to a full fetch.
            raced <- atomically $ do
                subs' <- readTVar subsVar
                if IntMap.null subs'
                    then do
                        GlobalPosition cur <- readTVar posVar
                        writeTVar posVar (GlobalPosition (max cur tailPos))
                        pure False
                    else pure True
            when raced fullFetch

fullFetch = do
    GlobalPosition pos <- readTVarIO posVar
    result <- Pool.use pool (Session.statement (pos, publisherBatchSize) SQL.readAllForwardStmt)
    case result of
        ... -- the existing body of fetchAndBroadcast, unchanged, with its
            -- trailing "if full batch then fetch again" recursing to fullFetch
```

Notes on the shape: `when` needs `Control.Monad (when)` in the import list; the `max`
is belt-and-braces monotonicity (only this loop writes `posVar`, and the `$all` tail
can only be ≥ the last published position, but making monotonicity locally evident
costs nothing); the error case emits the same `KirokuEventPublisherPoolError` the full
path emits, so EP-1's operator signal for a stalled broadcast is preserved on both
paths, and the 30-second safety poll retries exactly as before. **EP-1 coordination:**
if EP-1 has landed, its publisher-loop exception envelope (wrapping the loop body so
user callbacks cannot kill the thread) must surround both `cheapAdvance` and
`fullFetch`; make the change inside EP-1's wrapper, not around it.

*Closing the full-fetch attach race (Finding C).* While `fullFetch` is open on the
operating table, also change its tail. Today it delivers the batch to the registry
snapshot and then advances `posVar` in a separate `atomically`; a subscriber registering
between the snapshot and the advance can permanently miss the batch (the full mechanism
is spelled out in "Context and Orientation", Finding C). Replace the trailing
`atomically (writeTVar posVar newPos)` with one transaction that (1) re-reads
`subsVar`, (2) enqueues `events` to every subscriber whose key was **not** in the
snapshot (their queues are newly created and empty, so `writeTBQueue` cannot block; skip
the overflow-policy dance — a fresh queue cannot be full), and (3) writes `posVar`.
After this, every subscriber either received the batch in its queue or registered after
the position advance — in which case its catch-up gate reads the advanced position and
its SQL catch-up covers the batch; the `> cursor` staleness filter in the worker's live
branch (Worker.hs line 243) drops any double delivery. Test it deterministically in
`Test/PublisherIdleAdvance.hs` (or a sibling module): block the publisher mid-broadcast
with a gating `decodeHook` (discriminate the publisher's thread via
`asyncThreadId (publisherThread pub)` — the pattern docs/plans/61 uses for the same
problem), register a fresh AllStreams subscription whose checkpoint sits inside the
in-flight batch's range, release the gate, and assert the subscriber observes every
global position exactly once. This test fails before the change (the worker hangs
missing the in-flight positions) and passes after.

Also update the module header (lines 1–17) and the `startPublisher` haddock (lines
123–135) to describe the two modes: "with at least one registered subscriber the loop
fetches and broadcasts full event batches; with an empty registry it advances
`lastPublished` from the `$all` tail with a single-row query and fetches nothing."

*Why the transition edge is safe (record this reasoning in code comments and keep it
here).* The hazard: a subscriber registering between cheap-advance cycles must not miss
events. Concretely, suppose `lastPublished = P0`, events exist up to `P > P0`, the
registry is empty, and a new non-group AllStreams subscription is being created while
the publisher runs a cheap cycle. Registration (`subscribePublisher`, EventPublisher.hs
lines 177–193) is a single STM transaction inserting into `subsVar`; the cheap advance's
position write re-reads `subsVar` in its own single STM transaction. STM serializes the
two, leaving exactly two orders:

- *Registration commits first.* The cheap transaction sees a non-empty registry,
  refuses to advance, and falls through to `fullFetch`, which reads from `P0` and
  delivers everything to the new queue. No event skips the queue while a queue exists.
- *Cheap write commits first* (`lastPublished` jumps to `P`). Then the subscriber's
  registration — and everything its worker subsequently does — happens after that
  commit. The worker catches up from its durable checkpoint by SQL (`fetchBatch`,
  Worker.hs lines 216–227), repeatedly re-reading `lastPublished`, and cannot leave
  `CatchingUp` until its cursor `c ≥ lastPublished ≥ P` — so every event at or below
  `P` (including everything the cheap advance "skipped") is delivered from the
  database, not the queue. Events after `P` are fetched by the publisher's next cycle
  (the registry is now non-empty, so it full-fetches from `P`) and enqueued; any
  overlap between the SQL catch-up and the queue is discarded by the worker's
  staleness filter `V.filter ((> c) . globalPosition)` (Worker.hs line 243), which is
  precisely the existing protection for "events appended during catch-up may be both
  fetched from SQL and waiting in the queue". The same re-catch-up design also covers
  the `Paused`/resume path.

Category and consumer-group workers never read the queue at all (after M1 they have
none): category live mode wakes on the notifier's per-category generation counter and
re-queries SQL; group live mode gates on `lastPublished` advancing — which both cheap
and full cycles provide — and re-queries SQL. The kiroku-metrics WebSocket tail
(`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` line 366) registers through the same
`subscribePublisher`, so its presence flips the publisher to full-fetch mode exactly
like a store subscription; its attach-position protocol is unchanged.

*Tests.* Create `kiroku-store/test/Test/PublisherIdleAdvance.hs`, add
`Test.PublisherIdleAdvance` to `other-modules` of `test-suite kiroku-store-test` in
`kiroku-store/kiroku-store.cabal`, and call its `spec` from
`kiroku-store/test/Main.hs` (import plus one line in the `hspec $ do` block). Three
specs, using the `decodeHook`-counting pattern from
`kiroku-store/test/Test/InterpreterHooks.hs` (an `IORef Int` bumped inside
`defaultStoreSettings{decodeHook = Just countingHook}` wired through the connection
settings) and the helpers in `kiroku-store/test/Test/Helpers.hs`:

1. *Zero subscribers: position advances, nothing decoded.* Build a store whose
   `decodeHook` increments a counter. Create **no** subscriptions. Append N (say 25)
   events, then `waitForPublisher store (GlobalPosition n)` for the expected tail.
   Assert the counter is 0. Before this milestone the publisher fetches and decodes
   all N events here, so this test **fails before and passes after** — implement it
   first and watch it fail to confirm it pins the behavior. (The publisher is the
   only possible decoder in this test: there are no workers, and the test performs no
   reads, and the append path never decodes.)

2. *Category-only: no publisher row fetches.* Subscribe a category subscription on
   category `"pubidle-a"` (use `caughtUpEventHandler` + `waitForSubscriptionLive` to
   wait until it is live), then snapshot the decode counter. Append M (say 30) events
   to streams in a *different* category `"pubidle-b"`, `waitForPublisher` to the new
   tail, and assert (a) the decode-counter delta is 0 and (b) the publisher registry
   is still empty (`IntMap.null` on `subscribers`). Attribution is unambiguous: the
   category worker for `pubidle-a` cannot fetch in this window — its live loop blocks
   on the `pubidle-a` generation counter, which appends to `pubidle-b` never bump, and
   its 30-second safety poll cannot fire within the test (keep the window well under
   30 s; this is the same isolation argument `Test/CategoryIdleNoSpin.hs` already
   relies on). So any decode call would have to be the publisher's — and there must be
   none. Liveness check: finally append one event to `pubidle-a` and assert the
   handler receives it (the counter then rises by exactly the rows the *worker*
   fetches, which is expected and not asserted against).

3. *Register-mid-stream transition: no gaps.* With no subscribers, append N events and
   `waitForPublisher` (cheap advances have moved `lastPublished` to the tail without
   enqueuing anything). Then subscribe a fresh non-group `AllStreams` subscription
   (checkpoint starts at 0), wait for caught-up, append M more events, and wait for
   the handler to have seen all N+M. Assert the recorded global positions are exactly
   1..N+M with no gaps and no duplicates *processed* (at-least-once allows redelivery
   only across restarts; within one run this sequence must be gapless). This exercises
   the cheap→full transition and the catch-up gate + staleness filter reasoning above.

*Acceptance for M2.* `cabal test kiroku-store:kiroku-store-test
--test-options='--match "PublisherIdleAdvance"'` (or the describe-string you choose) is
green; spec 1 demonstrably failed before the EventPublisher edit; the full kiroku-store
suite is green. Commit as:

```text
feat(kiroku-store): advance publisher position by single-row query when no queue subscriber is registered
```

### Milestone 3 — Whole-suite validation, docs sweep, master-plan bookkeeping

*Scope.* Prove catch-up→live correctness for all three target shapes end-to-end, finish
documentation, and update the coordinating documents. Nothing new is built here; this
milestone exists so the initiative-level invariants are checked once after both edits
are in.

Run the full multi-package suite from the repo root (`just test`, which is
`cabal test all`); every package must pass — pay particular attention to
`kiroku-metrics` (its WebSocket tail and Prometheus collector consume the publisher and
`subscriptionStates`) and `shibuya-kiroku-adapter` (its processors are built on
`subscribe`). Optionally run `just bench-regression` (requires a captured baseline in
`kiroku-store/bench/results/baseline.csv`; the benchmarks exercise append/read SQL
paths this plan does not touch, so this is a sanity check, not a gate). Re-read the
final haddocks of `subscribe`, `runWorker`, and the `EventPublisher` module header for
consistency with the implemented shape. Then update
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`:
set EP-3's registry row to Complete and tick the two EP-3 progress boxes
("Category/consumer-group subscriptions no longer register publisher queues",
"Publisher fetches full rows only when an AllStreams subscriber exists"), noting any
coordination outcome with EP-1 in its Surprises section if applicable. Finally, fill in
this plan's Outcomes & Retrospective and Progress sections and commit:

```text
docs(plans): complete ExecPlan 58 and update MasterPlan 9 EP-3 status
```

*Acceptance for M3.* `just test` output ends with every suite reporting 0 failures;
the master plan and this plan reflect completion.


## Concrete Steps

All commands run from the repository root. If `cabal`/`ghc` are not on PATH, prefix a
`nix develop` shell.

1. Orient and confirm the soft dependency's state:

   ```bash
   git log --oneline -10
   ls docs/plans | grep -E '^(56|58)-'
   ```

   Open `docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`
   and check its Progress section. If EP-1 is implemented, read its Outcomes for the
   `subscribe` bracket shape and the publisher exception envelope before editing either
   file; record what you found in this plan's Decision Log.

2. Baseline build and test (expect green before you change anything):

   ```bash
   just build
   cabal test kiroku-store:kiroku-store-test
   ```

   Expected tail of the test output:

   ```text
   ... examples, 0 failures
   Test suite kiroku-store-test: PASS
   ```

   (The exact example count grows during this plan. A codd "DB and expected schemas do
   not match" LaxCheck line in test logs, if present, is benign noise — judge by the
   PASS line.)

3. Milestone 1 edits, in this order (details in Plan of Work):
   `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (add `LiveSource`, change
   `runWorker`, re-dispatch `nextInput`'s `Live` and `Paused` branches, haddock), then
   `kiroku-store/src/Kiroku/Store/Subscription.hs` (conditional acquisition, pass
   `liveSource`, haddock), then
   `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` (field haddocks only), then
   `kiroku-store/test/Test/SubscriptionRegistry.hs` (new assertions). Build and test:

   ```bash
   just build
   cabal test kiroku-store:kiroku-store-test
   git add -A && git commit -m 'feat(kiroku-store)!: register publisher queues only for non-group AllStreams subscriptions'
   ```

4. Milestone 2: first write the failing test. Create
   `kiroku-store/test/Test/PublisherIdleAdvance.hs` with spec 1 (zero-subscriber decode
   count), register the module in `kiroku-store/kiroku-store.cabal` (other-modules) and
   `kiroku-store/test/Main.hs`, then run it and confirm it fails for the right reason:

   ```bash
   cabal test kiroku-store:kiroku-store-test --test-options='--match "publisher idle"'
   ```

   Expected before the fix (the publisher decoded the appended rows):

   ```text
   1) ... advances lastPublished without decoding any rows when no subscriber is registered
        expected: 0
         but got: 25
   ```

   Then edit `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`
   (`fetchAndBroadcast` → dispatcher + `cheapAdvance` + `fullFetch`, plus haddocks),
   add specs 2 and 3, and re-run until green:

   ```bash
   cabal test kiroku-store:kiroku-store-test
   git add -A && git commit -m 'feat(kiroku-store): advance publisher position by single-row query when no queue subscriber is registered'
   ```

5. Milestone 3:

   ```bash
   just test
   # optional, only if kiroku-store/bench/results/baseline.csv is populated:
   just bench-regression
   ```

   Expected: every package's suite prints `PASS`. Update
   `docs/masterplans/9-...md` (EP-3 row → Complete; tick the two EP-3 checkboxes),
   update this plan's living sections, and commit:

   ```bash
   git add -A && git commit -m 'docs(plans): complete ExecPlan 58 and update MasterPlan 9 EP-3 status'
   ```

Keep the Progress checklist in this file current at every stopping point, and append a
revision note at the bottom of this file for any change of course.


## Validation and Acceptance

Acceptance is behavioral and measurable, matching the audit's remediation criteria:

1. **No publisher queue for category/consumer-group subscriptions (Finding A).** With a
   store running one `Category` subscription and one consumer-group member, reading the
   publisher's registry (`readTVarIO (subscribers (store ^. #publisher))`) yields an
   empty `IntMap`; adding a non-group `AllStreams` subscription raises the size to 1;
   cancelling it returns the size to 0. Verified by the new assertions in
   `kiroku-store/test/Test/SubscriptionRegistry.hs`. Consequence checks: no batches can
   pin memory for non-queue subscriptions (no queue exists to fill), and the
   inert-`DropSubscription` defect is structurally gone.

2. **No publisher row fetches without a queue subscriber (Finding B).** In
   `kiroku-store/test/Test/PublisherIdleAdvance.hs`: with zero subscribers, appending
   25 events and waiting for `lastPublished` to reach the tail leaves the `decodeHook`
   call counter at exactly 0 (this spec fails before the M2 edit with a count equal to
   the appended rows — capture that failing output as evidence); with only a category
   subscriber live, appending 30 events to a different category advances
   `lastPublished` to the tail with a decode-count delta of exactly 0 and an
   still-empty registry. That `waitForPublisher` returns at all *is* the proof that the
   cheap advance keeps the catch-up and group gates fed.

3. **Catch-up→live correctness for all three shapes is unchanged.** The transition spec
   in `Test/PublisherIdleAdvance.hs` shows a fresh AllStreams subscription created
   after a run of cheap advances still processes positions 1..N+M gaplessly. The
   pre-existing suite must stay green: `Test.Category`, `Test.CategoryIdleNoSpin`
   (idle no-spin for category and group), `Test.ConsumerGroup` /
   `Test.ConsumerGroupEffect` / `Test.ConsumerGroupSql`,
   `Test.SubscriptionPauseResume` (queue backpressure for the AllStreams shape),
   `Test.SubscriptionReconnect`, `Test.PublisherRestartNoRebroadcast`,
   `Test.SubscriptionRegistry`, `Test.SubscriptionState`,
   `Test.SubscriptionRetryDeadLetter`, `Test.FailureInjection`,
   `Test.CatchupDbErrorNoPrematureSwitch`. Run with
   `cabal test kiroku-store:kiroku-store-test`; the run must end `0 failures` /
   `PASS`. Cross-package consumers must also pass: `just test` covers
   `kiroku-metrics` (WebSocket tail registers a real queue and must still flip the
   publisher into full-fetch mode) and `shibuya-kiroku-adapter`.

Failure interpretation: a hang inside `waitForPublisher` in any test means
`lastPublished` stopped advancing — most likely the cheap path was taken with a
registered subscriber or its error branch silently swallowed a pool error; a failure in
the transition spec (missing low positions) means the atomic emptiness re-check was
omitted or broken — re-read "Why the transition edge is safe" in Milestone 2.


## Idempotence and Recovery

Every step is safe to repeat. The plan changes only Haskell sources, test sources, one
cabal file, and documentation — no schema migrations, no data, no generated files —so
`git checkout -- <file>` (or `git reset --hard` to a milestone commit) is a complete
rollback at any point. Builds and test runs are idempotent; the test suite provisions
its own throwaway PostgreSQL via `ephemeral-pg` per run, so no external database state
can drift. If a milestone is interrupted midway, re-run `just build` to find the
incomplete edit (the `runWorker` signature change in M1 makes any missed call site a
compile error, which is the intended safety net), finish it, and re-run the suite.
Commit at each milestone boundary so a bad step can be reverted independently;
Milestone 2 is purely additive on top of Milestone 1 and can be reverted alone (revert
the EventPublisher edit and the new test module/cabal/Main.hs lines) without
re-breaking M1's behavior.

Coordination risk (soft dependency): if EP-1 lands *between* your milestones, rebase
and re-read EP-1's Outcomes for the bracket and exception-envelope shapes before
continuing; the division of labor in Context and Orientation tells you which side owns
what. Record the merge outcome in Surprises & Discoveries.


## Interfaces and Dependencies

No new libraries. Everything uses dependencies already declared in
`kiroku-store/kiroku-store.cabal`: `stm` (TVar/TBQueue/atomically), `async`,
`hasql`/`hasql-pool` (`Pool.use`, `Session.statement`), `containers`
(`Data.IntMap.Strict`), `vector`, and for tests `hspec`, `ephemeral-pg` (via
`kiroku-test-support`), `lens`/`generic-lens` (the `^.`/`#field` access convention used
throughout).

Modules and the surfaces that must exist at the end of each milestone:

- After M1, `Kiroku.Store.Subscription.Worker`
  (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`) exports
  `LiveSource (..)` with constructors `LiveFromPublisherQueue (TBQueue (Vector
  RecordedEvent)) (TVar SubscriberStatus)`, `LiveFromCategoryNotify Text`,
  `LiveFromGroupPolling`; and `runWorker` has the signature

  ```haskell
  runWorker ::
      (MonadIO m) =>
      Pool ->
      LiveSource ->
      TVar SubscriptionState ->
      TVar GlobalPosition ->
      TVar (Map Text Word64) ->
      SubscriptionConfig ->
      Maybe (KirokuEvent -> IO ()) ->
      StoreSettings ->
      m ()
  ```

  `Kiroku.Store.Subscription.subscribe` keeps its public signature
  `(MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle` and is the
  only constructor of `LiveSource` values in the library.

- After M2, `Kiroku.Store.Subscription.EventPublisher` keeps its entire export list
  unchanged (`EventPublisher (..)`, `Subscriber (..)`, `SubscriberStatus (..)`,
  `startPublisher`, `stopPublisher`, `subscribePublisher`, `publisherPosition`); the
  change is internal to `publisherLoop`/`fetchAndBroadcast`. It now also uses
  `Kiroku.Store.SQL.currentGlobalPositionStmt :: Statement () Int64` (already imported
  module; the statement is already used by `startPublisher`). The external contract of
  `lastPublished` is strengthened, not changed: it still advances monotonically to the
  `$all` tail whether or not subscribers exist.

- Consumers that must keep working unmodified: `kiroku-metrics`
  (`Kiroku.Metrics.WebSocket` registering via `subscribePublisher`;
  `Kiroku.Metrics.Collector`/`Prometheus` reading `subscriptionStates`),
  `shibuya-kiroku-adapter` (builds processors on `subscribe`), and the
  `Kiroku.Store.Subscription.Stream` bridge. Downstream repo note: `keiro` consumes
  `kiroku-store` by git pin, so this change reaches it only after a push and pin bump;
  no API it uses changes (only the unexposed-in-practice `runWorker` shape).


---

*Revision note (2026-06-11).* Folded in Finding C — the pre-existing full-fetch attach
race in `fetchAndBroadcast` (a subscriber registering between the registry snapshot and
the `lastPublished` advance can permanently miss the in-flight batch), discovered while
drafting docs/plans/61 (EP-6) and assigned to this plan by the master plan because
Milestone 2 already rebuilds this function around the required atomic
snapshot-recheck-plus-write shape. Changes: defects section retitled to three findings
with the full race mechanism; Milestone 2 gained the late-registrant delivery edit and a
deterministic regression test; Progress gained one M2 item; Decision Log gained the
fix-placement decision (late-registrant delivery over advance-before-delivery, with the
crash-loss-window rationale). Also refreshed the EP-1 status note: docs/plans/56 is now
fully authored (was a skeleton when this plan was first drafted).
