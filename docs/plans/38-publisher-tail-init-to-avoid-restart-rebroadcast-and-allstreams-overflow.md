---
id: 38
slug: publisher-tail-init-to-avoid-restart-rebroadcast-and-allstreams-overflow
title: "Publisher tail-init: stop re-broadcasting all history on restart (AllStreams overflow footgun)"
kind: exec-plan
created_at: 2026-05-25T23:25:00Z
---


# Publisher tail-init: stop re-broadcasting all history on restart (AllStreams overflow footgun)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`EventPublisher` initializes its `lastPublished` cursor to `GlobalPosition 0` on
every process start (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs:124`,
`pos <- newTVarIO (GlobalPosition 0)`). `lastPublished` is an **in-memory, per-process**
`TVar` — it is not persisted — so each restart begins at 0. On the first wakeup the
`publisherLoop` reads `readAllForward` from `pos` in `publisherBatchSize` (1000) batches,
broadcasting each batch to **every registered subscriber's bounded queue** and looping
while batches are full (`fetchAndBroadcast`, lines 191-223). The net effect: on every
restart the publisher **re-reads and re-broadcasts the entire store history**.

For `AllStreams` subscribers this is correctness-safe in the happy path — the live loop
drops already-seen events via `freshEvents = filter (> cursor)`
(`Subscription/Worker.hs:257`) after its own DB catch-up. But it has two real downsides:

1. **Spurious overflow → healthy subscriber killed on restart.** The per-subscriber queue
   is bounded at `queueCapacity * publisherBatchSize` (default `16 * 1000 = 16000` events;
   see `Subscription/Types.hs:99-100`). A subscriber registers its queue *before* catch-up
   begins, so while it is still catching up (not yet draining the live queue) the publisher
   can fill that queue with the re-broadcast history. When history exceeds the capacity (or
   the subscriber drains slower than the publisher fills), `deliverBatch`
   (EventPublisher.hs:225-233) trips the overflow policy: under `DropSubscription` (the
   default) it marks the subscriber `Overflowed` and the worker throws
   `SubscriptionOverflowed` — a **healthy subscriber dies purely because of a restart**;
   under `DropOldest` it silently drops the oldest batches (event loss with checkpoint
   advance).
2. **Wasted work.** Re-reading and re-decoding the whole store every restart is pure
   overhead — the events the subscriber needs from history are already served by its own
   catch-up DB read.

After this change, the publisher initializes `lastPublished` to the **current store tail**
at startup (one cheap query against the `$all` stream row in `streams`), so it only
broadcasts genuinely-new events going forward. Each subscriber's catch-up phase already
reads history directly from the database, so no event is missed. The restart
re-broadcast — and the overflow risk it creates — is gone.

Correctness is non-negotiable: a subscription must never miss an event that belongs to its
target. Tail-init is acceptable only because the subscription worker has two independent
delivery paths. Events at or below the publisher's current cursor are delivered by the
worker's catch-up SQL reads. Events above that cursor are delivered either by the publisher
queue for ordinary `AllStreams` subscribers or by the DB-driven live loops for `Category`
and consumer-group subscribers. A missed NOTIFY may delay delivery until the 30-second
safety poll, but it must not create a gap.

Each subscription's own global position remains independent. The persisted checkpoint in
the `subscriptions` table, loaded by `Subscription.Worker.loadCheckpoint`, is the cursor
that says how far that named subscription has caught up. `EventPublisher.lastPublished` is
not a subscription checkpoint and must never be written into the `subscriptions` table or
used to skip catch-up. Tail-init only changes the shared publisher broadcast cursor; a
subscription at position 5 and another at position 500 must continue to catch up from their
own saved positions.

Acceptance command:

```bash
cabal test kiroku-store
```

must report `0 failures`, including new specs that prove both sides of the contract:
restart history is not rebroadcast into a blocked subscriber's live queue, and a subscriber
still receives every event at or after its checkpoint across restart, during catch-up, and
after it has entered live mode. With `lastPublished` still seeded to `GlobalPosition 0`,
the overflow-focused spec overflows deterministically because the wakeup rebroadcasts
history into the blocked subscriber's queue.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Root-cause + impact analysis (this document). 2026-05-25.
- [x] Critical verification against the current codebase; corrected the tail query, error-handling, and test design. 2026-05-25.
- [x] M1: initialize `lastPublished` to the store tail at publisher startup, failing store acquisition if the tail read fails. Implemented in `SQL.currentGlobalPositionStmt`, `EventPublisher.startPublisher`, and `Connection.withStore` cleanup. 2026-05-26.
- [x] M2: regression tests (restart + AllStreams + DropSubscription + blocked catch-up + history > queue capacity → no overflow, no loss; plus post-catch-up live event delivery). Added `Test.PublisherRestartNoRebroadcast` with restart overflow, post-catch-up live delivery, and independent-checkpoint scenarios. 2026-05-26.
- [x] M3: CHANGELOG entry. Added an Unreleased fixed entry for publisher restart history rebroadcast. 2026-05-26.
- [x] Validation: `cabal build kiroku-store:kiroku-store-test` passed. 2026-05-26.
- [x] Validation: `cabal test kiroku-store` passed with 163 examples and 0 failures. 2026-05-26.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- `lastPublished` is correctness-load-bearing in two roles: the publisher's own read
  cursor AND the wake signal every live subscriber gates on. Tail-init only changes "where
  broadcasting starts," not the wake-signal semantics, so it does not affect delivery
  correctness — catch-up (DB read) covers all history below the tail.
- The overflow risk is **race-dependent**: if the publisher drains 0→tail before any
  subscriber registers (subscribers register as the host starts them), the re-broadcast
  delivers to an empty subscriber set and no overflow occurs. The bug bites when a
  subscriber registers and enters catch-up while the publisher is still re-broadcasting.
  Tail-init removes the race entirely.
- This is the only place the publisher reads `readAllForward` from a non-live position; no
  other consumer depends on the publisher starting at 0.
- Verification correction: the cheapest and most semantically direct tail source is
  `streams.stream_version WHERE stream_id = 0`, not `max(stream_version)` over
  `stream_events`. The bootstrap migration seeds the `$all` row with `stream_id = 0`
  and `stream_version = 0`, and every append CTE advances that row in the same statement
  that inserts `$all` junction rows. Querying `streams` is one primary-key lookup and also
  preserves the empty-store answer without `COALESCE`.
- Verification correction: a restarted publisher does not rebroadcast immediately on
  `withStore`; `publisherLoop` blocks until a notifier tick or the 30-second safety poll.
  A deterministic regression must create a tick after the subscriber has registered and is
  blocked in catch-up, otherwise the old behavior may appear to pass because the publisher
  has not woken yet.
- Verification correction: defaulting the startup tail read to 0 on `Pool.use` error would
  silently resurrect the dangerous restart behavior during pool exhaustion or SQL/session
  errors. Existing publisher fetch errors are safe to continue from because the publisher is
  already running and can retry on the next poll, but a failed startup tail read means the
  publisher does not know its initial cursor. `startPublisher` should fail store acquisition
  in that case so `withStore` cannot start in the known-bad mode.
- Verification correction: because `withStore` currently creates the pool, starts the
  notifier, then starts the publisher inside its acquire action, making `startPublisher`
  fail fast means acquire can now fail after earlier resources exist. The implementation
  must add exception cleanup around acquire or reorder work so a failed tail read cannot
  leak the pool or notifier.
- Correctness check: an append that happens after the startup tail read but before the
  publisher's `dupTChan` is installed may not wake the publisher immediately, because the
  publisher's personal channel copy did not exist when the notifier wrote the tick. This is
  still not a missed event: the publisher cursor remains at the older tail, and the safety
  poll will later read and broadcast from that cursor. A subscriber that starts in the
  meantime either catches the event from SQL if `publisherPosition` has advanced, or waits
  for the later broadcast if it has not. This race should be explicitly documented in code
  comments or tests so future maintainers do not "fix" it by reverting to history
  rebroadcast.
- Correctness check: per-subscription checkpoints remain distinct. The implementation must
  not initialize, bump, clamp, or otherwise rewrite any `subscriptions.last_seen` row from
  the publisher's startup tail. A behind subscriber must still load its own checkpoint and
  catch up from there, even if the publisher was initialized to the current store tail.
- Implementation discovery: the overflow regression must continue into live mode before it
  can prove the old behavior fails. If the handler returns `Stop` while still in catch-up
  at position 1002, `runWorker` exits normally before `liveLoop` observes the
  `Overflowed` status flag. The implemented test therefore blocks the first catch-up event,
  appends position 1002 to wake the publisher, waits for catch-up to enter live mode, and
  then appends position 1003 as the stop event. With the old cursor-at-zero behavior,
  `wait` surfaces `SubscriptionOverflowed`; with tail-init, the handler sees exactly
  positions 1 through 1003.
- Implementation discovery: several existing notifier/advisory-lock tests opened
  `withStore` on an unmigrated `EphemeralPg.withCached` database because they previously
  did not issue store-table SQL. Tail-init intentionally makes `withStore` read
  `streams` during acquisition, so those tests now use `withMigratedTestDatabase` like the
  rest of the store lifecycle tests.


## Decision Log

Record every decision made while working on the plan.

- Decision: Initialize `lastPublished` from the **store tail** (max `$all` global position),
  not from the `subscriptions` checkpoint table.
  Rationale: `lastPublished` is a single shared broadcast cursor; per-subscription
  checkpoints differ and give no single correct value (min → re-broadcast almost
  everything; max → risk a behind subscriber missing live events). The store tail is the
  natural "only broadcast new events" anchor and keeps the publisher decoupled from
  subscription semantics. Behind subscribers still get history via their own catch-up DB
  read.
  Date: 2026-05-25

- Decision: Do the tail read once, at `startPublisher`, before spawning `publisherLoop`.
  Rationale: A single `SELECT stream_version FROM streams WHERE stream_id = 0` is cheap
  and removes the startup re-read entirely. Reading lazily in the loop would reintroduce a
  window where `lastPublished = 0`.
  Date: 2026-05-25

- Decision: Fail `startPublisher`/`withStore` if the initial tail query returns a
  `Pool.UsageError` instead of defaulting to `GlobalPosition 0`.
  Rationale: Falling back to 0 on startup would preserve availability at the cost of
  reviving the exact overflow footgun this plan removes. `withStore` already cannot operate
  usefully unless the database and migrations are available; surfacing the startup failure
  is safer than starting a publisher with a cursor known to be wrong.
  Date: 2026-05-25

- Decision: Read the tail from `streams`, not `stream_events`.
  Rationale: The migration creates the `$all` stream as `streams(stream_id = 0,
  stream_name = '$all', stream_version = 0)`. Every append statement updates that row before
  inserting `$all` junction rows. Therefore `streams.stream_version` is the canonical tail,
  costs one primary-key lookup, and returns 0 for an empty store without aggregate/null
  handling.
  Date: 2026-05-25

- Decision: Add acquisition cleanup in `withStore` if `startPublisher` can fail during the
  initial tail read.
  Rationale: `bracket acquire release action` does not run `release` when `acquire` itself
  throws. The current acquire action creates a pool and starts a notifier before the
  publisher starts. If the new tail query throws after those resources exist, the
  implementation must stop the notifier and release the pool explicitly using
  `onException`, or perform the tail read before starting the notifier.
  Date: 2026-05-25

- Decision: Treat "no missed subscription events" as the primary invariant; overflow
  avoidance is only valid if that invariant is preserved.
  Rationale: The publisher is an optimization and live wake mechanism, not the source of
  truth for catch-up. The database is the source of truth. The implementation and tests must
  prove that events before the startup tail are served by catch-up, events appended during
  catch-up are still served exactly once, and events appended after catch-up are delivered
  by live mode.
  Date: 2026-05-25

- Decision: Keep per-subscription checkpoints fully independent from the publisher's
  startup tail.
  Rationale: `lastPublished` is a shared publisher cursor and wake signal. It is not the
  cursor of any particular subscription. The correct resume point for a subscription is
  `subscriptions.last_seen` for that subscription name and consumer-group member, so this
  plan must not add any code that copies the startup tail into subscription checkpoint
  storage.
  Date: 2026-05-25

- Decision: Make the restart-overflow regression stop on a post-catch-up live event at
  position 1003 rather than returning `Stop` at catch-up position 1002.
  Rationale: `SubscriptionOverflowed` is observed by `liveLoop`, not by the catch-up SQL
  loop. Stopping during catch-up can hide the pre-fix overflow flag, so the regression must
  force the worker to cross the catch-up/live boundary before expecting the old behavior to
  fail.
  Date: 2026-05-26


## Outcomes & Retrospective

Completed on 2026-05-26. `EventPublisher.startPublisher` now reads
`SQL.currentGlobalPositionStmt`, which performs `SELECT stream_version FROM streams WHERE
stream_id = 0`, and seeds `lastPublished` to that value before spawning `publisherLoop`.
If `Pool.use` returns a `UsageError`, startup throws the error instead of falling back to
`GlobalPosition 0`. `Connection.withStore` now wraps staged acquisition with
`onException`, so a publisher startup failure stops a previously started notifier and
releases the pool.

The regression coverage lives in `kiroku-store/test/Test/PublisherRestartNoRebroadcast.hs`.
It proves that a restarted publisher does not rebroadcast 1001 historical events into a
blocked `AllStreams` subscriber with `queueCapacity = 1`, that a subscriber still receives
a live event appended after restart catch-up, and that two subscription names with
different saved checkpoints resume independently after another restart.

Validation passed with `cabal test kiroku-store`: 163 examples, 0 failures.


## Context and Orientation

- `EventPublisher` (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`):
  `startPublisher` (110-134) creates `pos <- newTVarIO (GlobalPosition 0)` and spawns
  `publisherLoop`. `publisherLoop`/`fetchAndBroadcast` (180-223) reads
  `SQL.readAllForwardStmt` from `pos`, broadcasts via `deliverBatch`, advances `posVar`,
  and loops while batches are full. `publisherBatchSize = 1000` (91); safety poll = 30 s.
- `deliverBatch` (225-233): on a full queue, `DropSubscription` marks `Overflowed`,
  `DropOldest` drops the oldest batch.
- Subscriber side: `subscribePublisher` registers the bounded queue (149-165) *before*
  catch-up; `liveLoop` (`Subscription/Worker.hs:224-257`) dedupes via `freshEvents`.
- Queue capacity: `queueCapacity` default 16 batches (`Subscription/Types.hs:99-100`),
  so 16 × `publisherBatchSize` = 16000 events.
- The store tail in SQL should be read from the `$all` stream row:
  `SELECT stream_version FROM streams WHERE stream_id = 0`. The bootstrap migration
  `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
  creates that row with `stream_version = 0`, and every append CTE in
  `kiroku-store/src/Kiroku/Store/SQL.hs` updates it in the `all_update` CTE. The
  `stream_events` `$all` rows still materialize each event's global position, but an
  aggregate over those rows is more work and has an empty-store `NULL` case to handle.
- Tests currently live mostly in `kiroku-store/test/Main.hs`, while focused modules are
  listed under the `kiroku-store-test` stanza's `other-modules` in
  `kiroku-store/kiroku-store.cabal`. If M2 adds
  `kiroku-store/test/Test/PublisherRestartNoRebroadcast.hs`, also add
  `Test.PublisherRestartNoRebroadcast` to `other-modules` and import/run its `spec` from
  `kiroku-store/test/Main.hs`.
- `withStore` in `kiroku-store/src/Kiroku/Store/Connection.hs` uses `bracket acquire
  release`. If `acquire` throws after allocating a resource, `release` is not called.
  Because the new publisher startup can throw on the initial tail query, M1 must either
  guard the staged acquire with `Control.Exception.onException` cleanup or move the tail
  read before the notifier starts.
- `publisherPosition` is the boundary used by `Subscription.Worker.catchUp`: when the
  worker's checkpoint cursor is below `publisherPosition`, it reads SQL batches until it
  reaches that position. For ordinary `AllStreams`, live mode then consumes batches from
  the publisher's `TBQueue` and filters out stale entries with `freshEvents = filter
  ((> cursor) . globalPosition)`. Tail-init must preserve this handoff: if the publisher
  cursor starts at the store tail, all pre-existing history is necessarily catch-up work,
  not queue work.
- `subscriptions.last_seen` is the durable, per-subscription cursor. It is keyed by
  `(subscription_name, consumer_group_member)`, so ordinary subscriptions and each
  consumer-group member can be at different global positions. The publisher tail is a
  process-local cursor in `EventPublisher.lastPublished`; it is shared across subscribers
  and exists only to decide what the publisher should broadcast next.


## Plan of Work

### M1 — Initialize `lastPublished` to the store tail

In `startPublisher`, before `newTVarIO`, query the current tail and seed `pos` with it.
Add a small statement such as `SQL.currentGlobalPositionStmt :: Statement () Int64` in
`kiroku-store/src/Kiroku/Store/SQL.hs`:

```haskell
currentGlobalPositionStmt :: Statement () Int64
currentGlobalPositionStmt =
    preparable
        "SELECT stream_version FROM streams WHERE stream_id = 0"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))
```

Export the statement from `Kiroku.Store.SQL`. In
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`, run it with
`Pool.use pool (Session.statement () SQL.currentGlobalPositionStmt)` before allocating the
`lastPublished` TVar. On `Right tailPos`, seed `pos <- newTVarIO (GlobalPosition tailPos)`.
On `Left err`, fail startup by throwing the `Pool.UsageError` (it is an exception type in
`hasql-pool`) rather than silently using 0. On an empty but correctly migrated store the
query returns 0 because the `$all` row exists, so no special empty-store fallback is needed.
Spawn `publisherLoop` as before.

Because `Publisher.startPublisher` may now throw, update the acquire path in
`kiroku-store/src/Kiroku/Store/Connection.hs` so partially acquired resources are cleaned
up. One acceptable shape is:

```haskell
acquire = do
    p <- Pool.acquire poolConfig
    flip onException (Pool.release p) $ do
        n <- Notifier.startNotifier cs s evtHandler
        flip onException (Notifier.stopNotifier n) $ do
            pub <- Publisher.startPublisher p (Notifier.tickChan n) evtHandler stSettings
            pure KirokuStore{...}
```

Import `onException` from `Control.Exception`. Preserve the existing normal `release`
ordering (`Publisher.stopPublisher`, then `Notifier.stopNotifier`, then `Pool.release`).

Acceptance: `cabal build all` clean; existing suite green.

### M2 — Regression test

Add `kiroku-store/test/Test/PublisherRestartNoRebroadcast.hs`, add it to
`kiroku-store/kiroku-store.cabal` under the test suite's `other-modules`, import it in
`kiroku-store/test/Main.hs`, and run `PublisherRestartNoRebroadcast.spec` near the other
subscription specs. Use `Kiroku.Test.Postgres.withMigratedTestDatabase` directly so the test
can close and reopen `withStore` against the same migrated database.

The first scenario should be deterministic and should prove "no overflow, no loss while
catching up":

1. In the first `withStore`, pre-populate 1001 events. This is more than one
   `publisherBatchSize` of 1000, and it is enough to overflow a subscriber whose
   `queueCapacity` is 1 if those events are rebroadcast while the worker is not draining
   live batches. Close this store handle.
2. Reopen `withStore` against the same connection string. This simulates a process restart:
   the database still has the 1001 events, but the in-memory `EventPublisher.lastPublished`
   is newly initialized.
3. Subscribe an `AllStreams` subscriber named uniquely for this spec, with
   `queueCapacity = 1`, `overflowPolicy = DropSubscription`, and a catch-up `batchSize`
   small enough to keep the handler in catch-up while the publisher wakes. The handler
   should record each `globalPosition`, signal an `MVar` when it sees the first catch-up
   event, then block on another `MVar` so it cannot drain the publisher queue.
4. After the first catch-up event is blocked in the handler, append one more event. This
   append emits the NOTIFY tick that wakes the publisher. Before M1, the publisher cursor is
   0, so it reads positions 1..1000 into the one-batch queue, loops, then overflows on the
   next historical batch. After M1, the publisher cursor is 1001, so it broadcasts only the
   new live event.
5. Release the handler. Let the worker's catch-up loop read and process positions 1..1002
   from SQL. Have the handler return `Stop` when it records `GlobalPosition 1002`; this
   makes the test finish without needing a sleep or a second live append. Assert that
   `wait` returns `Right ()`, not `SubscriptionOverflowed`, and that the collected positions
   are exactly `GlobalPosition 1` through `GlobalPosition 1002` with no duplicates. The
   existing `does not replay catch-up events when switching to all-stream live mode` spec
   already covers stale live-queue deduplication, so this regression should stay focused on
   restart rebroadcast overflow.

This spec fails before M1 (the re-broadcast overflows the queue) and passes after.

Add a second scenario that proves live delivery still works after restart tail-init:

1. Pre-populate a small store, for example 3 events, and close the first `withStore`.
2. Reopen `withStore` against the same database. Subscribe an `AllStreams` subscriber from
   checkpoint 0 with `queueCapacity = 1`.
3. Let the handler process the 3 catch-up events and signal a `caughtUp` barrier when it
   sees `GlobalPosition 3`, but return `Continue` instead of `Stop`.
4. After the barrier, append a fourth event. The subscriber must receive
   `GlobalPosition 4` through live mode and then return `Stop`.
5. Assert the collected positions are exactly `[1,2,3,4]`. This guards against a tail-init
   implementation that advances `lastPublished` in a way that strands a live event above
   the subscriber's catch-up cursor.

Add a third scenario that proves per-subscription checkpoints are still independent:

1. Pre-populate 10 events and close the first `withStore`.
2. Reopen the store and run one `AllStreams` subscription named `tail-init-sub-a` until it
   processes positions 1 through 3 and stops. This should persist
   `subscriptions.last_seen = 3` for that name.
3. Run another `AllStreams` subscription named `tail-init-sub-b` until it processes
   positions 1 through 7 and stops. This should persist `last_seen = 7` for that different
   name.
4. Close and reopen the store again so the publisher tail initializes to 10.
5. Resubscribe `tail-init-sub-a` and assert it receives positions 4 through 10. Resubscribe
   `tail-init-sub-b` and assert it receives positions 8 through 10. Neither subscription
   may be advanced to 10 merely because the publisher was tail-initialized to 10.

### M3 — CHANGELOG

Add a `## Unreleased` entry in `kiroku-store/CHANGELOG.md` describing the tail-init and the
removed restart re-broadcast / overflow footgun.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
cabal build all
cabal test kiroku-store
```

To prove M2 exercises the fix: revert M1 (re-seed `pos` to 0) and confirm the new spec
overflows/fails, then restore.

Do not rely on waiting for the 30-second safety poll in the regression test. The live append
after subscriber registration is the intended wakeup, because it creates the same race in a
bounded test time.


## Validation and Acceptance

- `cabal test kiroku-store` green including `Test.PublisherRestartNoRebroadcast`.
- The spec asserts no spurious overflow and exactly-once-after-checkpoint delivery on a
  populated-store restart; it fails when `lastPublished` is re-seeded to 0.
- A separate restart-tail-init live-delivery spec asserts that a subscriber catches up to
  the startup tail, then receives an event appended after catch-up via live mode. This must
  pass with `queueCapacity = 1`; small capacity is intentional because correctness must not
  depend on a large queue.
- A per-subscription checkpoint spec asserts that two subscriptions with different
  persisted `last_seen` values resume from their own positions after a restart, even though
  the shared publisher cursor starts at the store tail.
- All existing subscription specs (AllStreams catch-up/live, Category, consumer-group)
  still pass — tail-init must not change delivery for any subscriber that starts behind the
  tail (catch-up covers it).
- `withStore` should fail if `SQL.currentGlobalPositionStmt` cannot run at startup. This
  behavior can be covered with a narrow unit/integration test only if the suite already has
  a convenient invalid-schema or broken-pool fixture; otherwise document it in the code path
  and rely on the existing `Pool.use` exception behavior from `hasql-pool`.
- A startup failure during the tail read must not leave a `kiroku-listener` connection or
  pool resources alive. This can be validated by a focused failure-injection test if
  practical; otherwise inspect the `onException` structure in `Connection.withStore` during
  review.


## Idempotence and Recovery

Source-only change; no schema/migration. `git checkout -- kiroku-store` reverts it.
Re-running build/test is safe; the ephemeral PostgreSQL fixture creates fresh databases for
tests. The restart regression intentionally reuses one migrated test database across two
`withStore` lifetimes; the test itself owns both lifetimes and remains idempotent.


## Interfaces and Dependencies

- Touches `EventPublisher.startPublisher` and adds one read statement in `SQL.hs`. No public
  API change (`lastPublished`/`publisherPosition` types unchanged), although `withStore`
  now fails fast if the initial tail read fails.
- Touches `Connection.withStore` acquire cleanup if the implementation keeps the tail read
  inside `Publisher.startPublisher` and throws from there.
- Coordinate with the in-flight Category live-loop wake change (plan 37): tail-init changes
  the *timing* at which a caught-up subscriber first observes `pubPos`; it does not change
  the wake semantics. The two are independent and compatible.


## Revision Notes

- 2026-05-25 — Created. No rei `intention` linked (rei worker disabled during the
  originating incident; link one if scheduled through rei). Source: the kiroku subscription
  review that followed the rei 581% CPU incident.
- 2026-05-25 — Verified critically against the current codebase and revised. The plan now
  uses `streams.stream_version` for the `$all` tail instead of aggregating
  `stream_events`, fails startup on tail-read errors instead of falling back to 0, and
  defines a deterministic restart regression that wakes the publisher after subscriber
  registration. It also records the required `withStore` acquire cleanup so fail-fast
  startup does not leak the pool or notifier.
- 2026-05-25 — Tightened the plan around the primary correctness invariant: subscriptions
  must never miss target events. Added explicit reasoning for startup-tail and missed-NOTIFY
  races, and added a second regression scenario proving post-catch-up live delivery still
  works after restart tail-init.
- 2026-05-25 — Clarified that per-subscription global positions remain independent. The
  publisher startup tail is not a subscription checkpoint, must not update
  `subscriptions.last_seen`, and now has a dedicated regression scenario covering two
  subscriptions resuming from different checkpoints after restart.
- 2026-05-26 — Implemented the plan. The restart-overflow regression was adjusted to stop
  on a post-catch-up live event so the pre-fix overflow flag is observed by `liveLoop`, and
  existing unmigrated notifier/advisory-lock fixtures were moved to `withMigratedTestDatabase`
  because `withStore` now validates the migrated store schema during publisher startup.
