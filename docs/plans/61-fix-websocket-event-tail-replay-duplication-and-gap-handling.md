---
id: 61
slug: fix-websocket-event-tail-replay-duplication-and-gap-handling
title: "Fix WebSocket event tail replay duplication and gap handling"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Fix WebSocket event tail replay duplication and gap handling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-6 of the master plan
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.
It has no dependencies on any other child plan and may start immediately.


## Purpose / Big Picture

The `kiroku-metrics` package serves a WebSocket endpoint, `/ws/events`, that streams
every event appended to a Kiroku event store to a connected client as JSON, in
global-position order. A client may ask for history first ("replay everything after
position N, then keep going live"). The endpoint's documented contract is in-order,
complete, gap-free delivery. A 2026-06-10 audit found three ways the implementation
breaks that contract:

1. **Duplicate delivery (MEDIUM).** When a client subscribes with a `from_position`
   while other writers are appending concurrently, the history replay can read past
   the position at which the live broadcast was attached, send those extra events,
   and then send them *again* when they arrive through the live broadcast queue.
   A client keeping a projection or a cursor sees the same global position twice.

2. **Silent gap on replay error (MEDIUM).** If a database read fails during replay,
   the client gets one `error` message — and then the live stream starts anyway,
   permanently missing every event between the failure point and the attach
   position. The client has no way to detect the hole. The sibling category loop in
   the same module already terminates the stream on a DB error; the replay path is
   inconsistent with it.

3. **Wrong status on unknown path (LOW).** The `subscriptionsApp` WAI application's
   documentation says unknown paths return a 404 JSON body, but the code returns
   HTTP 200 with an empty JSON array — indistinguishable from "no subscriptions".

After this plan: a client that subscribes with `from_position` while appends race the
replay receives **each global position exactly once**; a replay that hits a database
error sends an `error` message and **terminates the tail** (the client can reconnect
and resume from its last seen position — no silent hole); and an HTTP `GET` of an
unknown path on `subscriptionsApp` returns **HTTP 404** with the package's standard
`{"error":"Not found"}` body. Each behavior is proven by a deterministic automated
test driving a real WebSocket client or a real HTTP request against a real server
backed by a real (ephemeral) PostgreSQL.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1: `replayHistory` in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` returns
      the highest delivered position (`Just covered`) or `Nothing` after a surfaced
      read error; `eventTail` filters the broadcast with `> covered` and skips the
      broadcast loop entirely on `Nothing`.
- [ ] M1: deterministic duplicate-delivery regression test added to
      `kiroku-metrics/test/Test/WebSocketSpec.hs` (publisher-thread `decodeHook` gate;
      fails against the old code, passes against the new).
- [ ] M1: replay-error fail-stop test added to
      `kiroku-metrics/test/Test/WebSocketSpec.hs` (rename the `events` table, subscribe
      with `from_position`, assert `error` frame then tail teardown via the
      publisher's subscriber count returning to 0).
- [ ] M1: `cabal test kiroku-metrics:kiroku-metrics-test` green; haddocks on
      `eventTail`/`replayHistory` updated to state the covered-position contract.
- [ ] M2: `subscriptionsApp` unknown path returns 404 `{"error":"Not found"}`;
      haddock states the body shape; direct-mount warp test added to
      `kiroku-metrics/test/Test/SubscriptionsSpec.hs`.
- [ ] Wrap-up: full suite green (`cabal test kiroku-metrics:kiroku-metrics-test`),
      master plan registry row for EP-6 and its progress checkbox updated,
      conventional commits made, Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. One pre-implementation discovery is recorded in the Decision Log: the
in-flight-batch attach race found while designing the fix, deliberately left out of
scope.)


## Decision Log

- Decision: Fix the duplication (finding A) with the **tracked covered-position**
  variant — `replayHistory` returns the highest global position actually sent
  (at least the attach position), and the broadcast filter keeps only events
  strictly above it — rather than clamping replay pages with
  `V.takeWhile ((<= attachPos) . globalPosition)`.
  Rationale: the clamp discards events the replay already holds in memory and
  relies on the live queue still containing copies of them. That reliance is
  unsound twice over: the tail subscribes with the `DropOldest` overflow policy,
  so during a long replay the queue may have evicted exactly those boundary
  batches (the clamp would convert a duplication bug into a *loss* bug), and the
  in-flight-batch race described below means a batch past the attach position may
  never reach this queue at all. Delivering what we hold and deduplicating with a
  precise boundary is strictly safer, and costs nothing extra (no re-read; the
  filter is one comparison per event either way).
  Date: 2026-06-11

- Decision: Fix the replay-error gap (finding B) by **terminating the tail** after
  sending the `ErrorMsg` — no bounded retry loop.
  Rationale: this exactly mirrors `categoryLoop` in the same module (which already
  stops the tail on a category read error), keeping one failure semantic for the
  whole channel: "an `error` frame may be the last thing you receive on this tail".
  The client owns retry policy — it knows its last seen global position and can
  resubscribe with `from_position` set to it, which is also the only recovery that
  works across a process restart. A server-side retry would duplicate that logic,
  hide transient outages from the operator, and still need a terminate path when
  retries are exhausted.
  Date: 2026-06-11

- Decision: The `subscriptionsApp` unknown-path body (finding C) is
  `{"error":"Not found"}` with status 404.
  Rationale: that is byte-for-byte the shape the package already uses for unknown
  paths in `Kiroku.Metrics.Server.httpApp` (line 213) and `Kiroku.Metrics.JSON.jsonApp`
  (its final fallback), so remote clients need one decoder. The haddock currently
  promises "a 404 JSON body" without a shape; it will be updated to state this shape.
  Date: 2026-06-11

- Decision: Make the duplicate-delivery test deterministic with a **thread-discriminating
  `decodeHook` gate** (block only when the calling thread is the publisher's own
  thread), not a stress/race test.
  Rationale: `decodeHook` (a per-event `RecordedEvent -> IO RecordedEvent` hook in
  `Kiroku.Store.Settings.StoreSettings`) runs on *both* the publisher fan-out path and
  the `readAllForward` read path used by the replay, so a hook that blocked
  unconditionally would deadlock the replay too. Comparing `myThreadId` with
  `asyncThreadId (publisherThread store.publisher)` (both publicly reachable —
  the test suite already imports `EventPublisher (..)`) stalls only the publisher,
  freezing `publisherPosition` at a known stale value. That turns the racy
  "appends concurrent with replay" window into a deterministic, repeatable state:
  the replay provably reads past the attach position on every run, so the test
  fails on the old code every time and passes on the fix every time.
  Date: 2026-06-11

- Decision: Add `hasql` and `warp` to the `kiroku-metrics-test` test-suite
  `build-depends` (for the fault-injection `ALTER TABLE` session and the
  direct-mount `testWithApplication` server respectively).
  Rationale: both are already direct dependencies of the `kiroku-metrics` *library*
  (and `hasql` of `kiroku-store`), so this adds nothing to any build closure. The
  project's recorded nix-closure concern (test-only deps like `ephemeral-pg` leaking
  into `nix build`) applies to *executables*, which is why the example executable is
  gated behind the `example` cabal flag; test suites are not part of the Nix package
  closure and already depend on `kiroku-test-support`. No new flag or gating needed.
  Date: 2026-06-11

- Decision: A fourth defect discovered while designing the fix — the
  **in-flight-batch attach race** — is recorded here and explicitly left out of
  scope. The publisher's fan-out (`fetchAndBroadcast` in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`, lines 219-251)
  snapshots the subscriber registry, delivers to the snapshotted queues, and only
  then advances `lastPublished`. A tail that registers its queue *after* the
  snapshot but reads `publisherPosition` *before* the advance gets an attach
  position below the in-flight batch, yet never receives that batch on its queue;
  if the replay's last page happens to end exactly at the attach position, the
  batch is delivered by neither path. The tracked-covered-position fix
  opportunistically narrows this (any in-flight events the final replay page reads
  are delivered and deduplicated) but does not close it.
  Rationale for deferring: it is a distinct defect in `kiroku-store` (publisher
  registration/advance ordering), not in the `kiroku-metrics` tail; its window is a
  single fan-out cycle (microseconds); it was not in the audited findings for EP-6;
  and a real fix belongs next to EP-3's registration work on the publisher. The
  implementer must copy this paragraph into the master plan's Surprises &
  Discoveries section when closing this plan so it is triaged.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All paths below are relative to the repository root. The work touches one package,
`kiroku-metrics`, which provides HTTP and WebSocket observability endpoints for a
running Kiroku event store. The store itself lives in `kiroku-store`; this plan
changes nothing there, but you must understand three of its pieces to follow the
fixes.

**Global positions are gap-free integers.** Every event appended to the store gets a
`GlobalPosition` (a newtype over `Int64`, defined in
`kiroku-store/src/Kiroku/Store/Types.hs`). Positions are assigned under a row lock
on the `$all` stream, so they are strictly increasing *and contiguous*: after
position N, the next event is N+1. "Deliver each event exactly once in order" is
therefore equivalent to "the client observes the integers N+1, N+2, ... each exactly
once".

**The event publisher** (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`)
is a single broadcaster thread per store. It wakes on a notification, reads new
events from the database, runs the store's optional `decodeHook` over the batch
(`decodeEvents stSettings rawEvents`, line 233), pushes the batch into every
registered subscriber's bounded STM queue (`TBQueue (Vector RecordedEvent)`), and
finally advances its `lastPublished :: TVar GlobalPosition` (line 247). Three public
functions matter here, all exported from that module: `subscribePublisher` (register
a queue; returns the queue, a status `TVar`, and an unsubscribe action),
`publisherPosition` (read `lastPublished`), and the `EventPublisher (..)` record
itself, whose `publisherThread :: Async ()` field the new test uses to recognize the
publisher's thread. Note that `publisherPosition` is the *broadcast* cursor, not the
database head: it lags the database whenever the publisher has not yet fetched,
decoded, or delivered the newest events.

**The decode hook.** `kiroku-store/src/Kiroku/Store/Settings.hs` defines
`StoreSettings { enrichEvent, decodeHook }`. `decodeHook :: Maybe (RecordedEvent ->
IO RecordedEvent)` runs once per event on *every* surfaced-event path: the effectful
reads in `kiroku-store/src/Kiroku/Store/Effect.hs` (so `readAllForward` applies it on
the caller's thread) and the publisher loop above (on the publisher's thread). Tests
wire it through `defaultConnectionSettings connStr & #storeSettings . #decodeHook .~ ...`
(`ConnectionSettings` in `kiroku-store/src/Kiroku/Store/Connection.hs` carries a
`storeSettings` field; both records derive `Generic`, and the test suite already uses
`generic-lens` `#field` labels this way for `#eventHandler`).

**The WebSocket event tail** lives in
`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`. A client connects to `/ws/events`
and sends a JSON `{"type":"subscribe_events", "from_position": N?, "category": C?}`
message. For the no-category case, `eventTail` (lines 349-379) does, in order:

1. register a broadcast queue with `subscribePublisher ... DropOldest` (line 366);
2. snapshot the attach position: `attachPos <- unGP <$> atomically (publisherPosition
   store.publisher)` (line 367);
3. if `from_position` was given, send `event_stream_started` and call
   `replayHistory store conn p attachPos` (lines 371-373);
4. enter `broadcastLoop` (lines 400-413), draining the queue forever and sending each
   event that passes the filter `keep`; under a `from_position` replay the filter is
   `\e -> unGP e.globalPosition > attachPos` (line 378).

`replayHistory` (lines 382-395) pages through `readAllForward` from the requested
position: it stops once its cursor is `>= attachPos`, but each page reads up to
`eventReadLimit` (500, line 338) events with **no upper bound**, and it sends the
whole page. That is finding A: if appends raced the replay (or the publisher simply
lags the database — same observable state), the final page contains events with
positions above `attachPos`. They are sent once by the replay; because the queue was
registered *before* `attachPos` was snapshotted, the publisher later broadcasts those
same events into the queue, and the `> attachPos` filter passes them — sent twice.

Finding B is in the same function: on `Left err` from `readAllForward` (line 390) it
sends one `ErrorMsg` and returns `()`. `eventTail` has no idea the replay failed and
proceeds to `broadcastLoop`, so the client receives live events with a permanent,
undetectable hole between the failed cursor and `attachPos`. Contrast `categoryLoop`
(lines 420-442): its `drainTo` returns `Nothing` after a read error and the loop
stops the tail (line 430, "a DB error already surfaced; stop the tail").

Finding C is in `kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs`.
`subscriptionsApp` (lines 50-60) is a WAI `Application` (WAI is the standard Haskell
web-server interface: an `Application` maps a request to a response) serving
`GET /subscriptions` and `GET /subscriptions/<name>`. Its haddock (line 47) says
"Any other path returns a 404 JSON body", but the fallback (line 60) responds
`status200` with `[]`. When mounted through `Kiroku.Metrics.Server.httpApp` the
fallback is unreachable (the router only forwards exact 1- and 2-segment
`/subscriptions` paths, lines 192-193 of
`kiroku-metrics/src/Kiroku/Metrics/Server.hs`), but `subscriptionsApp` is publicly
re-exported from `Kiroku.Metrics` and usable as a standalone app, so the contract is
real. The package's standard not-found body is
`{"error":"Not found"}` (see `httpApp` line 213 and the fallback in
`kiroku-metrics/src/Kiroku/Metrics/JSON.hs`).

**The test suite.** `kiroku-metrics/kiroku-metrics.cabal` defines test-suite
`kiroku-metrics-test` (hspec). `kiroku-metrics/test/Main.hs` wraps all specs in
`withSharedMigratedPostgres` from `kiroku-test-support`
(`kiroku-test-support/src/Kiroku/Test/Postgres.hs`), which boots one ephemeral
PostgreSQL (via the `ephemeral-pg` library — a real `postgres` process in a temp
dir, no external service needed) and hands each `withMigratedTestDatabase` call its
own freshly migrated database, identified by a connection string. The existing
`kiroku-metrics/test/Test/WebSocketSpec.hs` shows the full pattern this plan reuses:
start a store with `withStore`, start the real server with
`startMetricsServerWithStore (defaultConfig{port = 0})`, and drive `/ws/events` with
the `websockets` library's `WS.runClient` against `127.0.0.1` and the assigned port.
Its helpers (`sendJSON`, `waitForType`, `readEventType`, `look`,
`waitForSubscriberCount`, `appendStoreEvents`, `requireJust`) are all reused below.
Note `appendStoreEvents` appends with `ExpectedVersion = NoStream`, so each test
stream name may be used for only one append call; use distinct stream names per
append. The note in the cabal file about gating test-only dependencies behind the
`example` flag applies to the example *executable* only; test suites may depend on
anything already in scope (see Decision Log).


## Plan of Work

Two milestones. Milestone 1 fixes the event-tail contract (findings A and B) in
`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` with two new end-to-end tests.
Milestone 2 fixes the `subscriptionsApp` 404 (finding C) with one new test. They are
independent and separately verifiable; do M1 first because it is the substance of
the plan.


### Milestone 1 — Exactly-once replay handoff and fail-stop replay errors

Scope: `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` (the `eventTail` and
`replayHistory` functions only) plus `kiroku-metrics/test/Test/WebSocketSpec.hs` and
the test-suite stanza of `kiroku-metrics/kiroku-metrics.cabal`. At the end of this
milestone, a `/ws/events` client that subscribes with `from_position` while the
database is ahead of the broadcast receives each global position exactly once, a
replay database error terminates the tail instead of leaving a silent gap, and both
behaviors are locked in by deterministic tests that fail on the pre-fix code.

**Edit 1: change `replayHistory` to return the covered position or a failure.**
Replace the current definition (lines 382-395) with one returning
`IO (Maybe Int64)`: `Just covered` means "the client has been sent every event with
global position in `(from, covered]`, and `covered >= attachPos`"; `Nothing` means
"a read error occurred and was surfaced as an `ErrorMsg`; the caller must terminate
the tail". The accumulator starts at `attachPos` (if the replay finds nothing past
the cursor, the broadcast queue still covers everything above `attachPos`) and is
raised to the last position of every page actually sent:

```haskell
{- | Page history from the requested position up to @attachPos@ with
'readAllForward'. Returns @Just covered@ — the highest global position the
client is now guaranteed to have received (at least @attachPos@; more when the
final page read past it) — or @Nothing@ after a read error, which has already
been surfaced to the client as an 'ErrorMsg'; the caller must then terminate
the tail rather than continue with a gap (mirrors 'categoryLoop').
-}
replayHistory :: KirokuStore -> WS.Connection -> Int64 -> Int64 -> IO (Maybe Int64)
replayHistory store conn from attachPos = go from attachPos
  where
    go cursor covered
        | cursor >= attachPos = pure (Just covered)
        | otherwise = do
            res <- runStoreIO store (readAllForward (GlobalPosition cursor) (fromIntegral eventReadLimit))
            case res of
                Left err -> do
                    sendMsg conn (ErrorMsg (T.pack ("replay error: " <> show err)))
                    pure Nothing
                Right evs
                    | V.null evs -> pure (Just covered)
                    | otherwise -> do
                        sendEvents conn evs
                        let lastPos = unGP (V.last evs).globalPosition
                        go lastPos (max covered lastPos)
```

**Edit 2: make `eventTail` consume the result.** In the `Nothing`-category branch
(lines 364-379), keep the from-now case exactly as it is semantically (filter
`const True`), and rewrite the `from_position` case to use the covered position and
to skip the broadcast loop on failure. `for_` over the `Maybe` (already imported
from `Data.Foldable`) expresses "terminate on `Nothing`" with no new control flow:

```haskell
        Nothing -> do
            (queue, statusVar, unsubscribe) <-
                atomically (subscribePublisher store.publisher cfg.wsEventQueueCap DropOldest)
            attachPos <- unGP <$> atomically (publisherPosition store.publisher)
            flip finally unsubscribe $
                case mFrom of
                    Nothing -> do
                        sendMsg conn (EventStreamStarted attachPos)
                        broadcastLoop conn queue statusVar (const True)
                    Just p -> do
                        sendMsg conn (EventStreamStarted p)
                        mCovered <- replayHistory store conn p attachPos
                        for_ mCovered $ \covered ->
                            broadcastLoop conn queue statusVar
                                (\e -> unGP e.globalPosition > covered)
```

When `replayHistory` returns `Nothing`, `eventTail` simply returns; the surrounding
`finally` deregisters the broadcast queue, the tail thread ends, and the connection
stays open for the client to resubscribe (the receive loop in `handleEvents` is
untouched). Update the haddock on `eventTail` (lines 340-348) to document the new
boundary contract: "replay covers `(from, covered]`; the broadcast filter passes only
`> covered`; a replay error ends the tail after an `error` message".

Why this is correct: the queue was registered before `attachPos` was read, so every
batch the publisher broadcasts from then on lands in the queue. Replay delivers
`(from, covered]` from the database exactly once; the filter drops the queue's
copies of anything `<= covered`; everything `> covered` reaches the client only via
the queue. No position can pass both paths, and (modulo the out-of-scope in-flight
race recorded in the Decision Log) no position can pass neither.

**Edit 3: cabal test deps.** In `kiroku-metrics/kiroku-metrics.cabal`, add `hasql`
to the `kiroku-metrics-test` `build-depends` (any bounds matching the library's,
`>=1.10 && <1.11`). It is needed by the fault-injection test below
(`Hasql.Session.sql`). While in the file, also add `warp >=3.4 && <3.5` for
Milestone 2's test.

**Test 1: deterministic duplicate-delivery regression.** Add a third `it` block to
`kiroku-metrics/test/Test/WebSocketSpec.hs`:
`"delivers each global position exactly once when the replay overlaps live appends"`.
The trick is to freeze the publisher (and therefore `publisherPosition`) while the
database moves ahead, which is exactly the state a concurrent-append race produces,
but held open deterministically. Install a `decodeHook` that blocks only on the
publisher's own thread until a gate opens:

```haskell
gateVar <- newTVarIO True -- open; the test closes it to freeze the publisher
storeVar <- newTVarIO Nothing
let publisherGate e = do
        mStore <- readTVarIO storeVar
        for_ mStore $ \s -> do
            me <- myThreadId
            when (me == asyncThreadId (publisherThread s.publisher)) $
                atomically (readTVar gateVar >>= check)
        pure e
    settings =
        defaultConnectionSettings connStr
            & #storeSettings . #decodeHook .~ Just publisherGate
```

(`myThreadId` from `Control.Concurrent`; `asyncThreadId` from
`Control.Concurrent.Async`; `for_`/`when` from `Data.Foldable`/`Control.Monad`;
`readTVarIO` from `Control.Concurrent.STM`. The spec already imports
`EventPublisher (..)`, which provides `publisherThread`.)

One pitfall shapes the scenario: `replayHistory` returns immediately when the
requested position already equals the attach position (`cursor >= attachPos` on
entry, no DB read at all), so reproducing the overshoot requires
`from < attachPos < database head`. The test therefore first lets the publisher
advance to a nonzero position, then freezes it, then appends past it.

The scenario, inside `withMigratedTestDatabase`/`withStore settings`/
`startMetricsServerWithStore` exactly as the existing replay test:

1. With the gate open, append two events to stream `ws-race-a` (global positions
   1-2) and wait for the publisher to broadcast them:
   `waitForPublisherPosition store 2 5_000_000` — a new helper mirroring the
   existing `waitForSubscriberCount`, blocking in STM on
   `publisherPosition store.publisher` reaching the target or a `registerDelay`
   timeout.
2. Close the gate (`atomically (writeTVar gateVar False)`), then append three more
   events to stream `ws-race-b` (positions 3-5). The publisher wakes on the
   notification, fetches the batch, and blocks inside the hook before delivering
   or advancing `lastPublished`, so `publisherPosition` is pinned at 2. (No
   polling needed: the gate makes it impossible for the position to advance, and
   it cannot strand a pre-close batch because step 1 only completes after the
   1-2 batch was fully delivered.)
3. Connect a `WS.runClient` to `/ws/events`, send
   `{"type":"subscribe_events","from_position":0}`, and read the
   `event_stream_started` frame. The tail registered its queue and snapshotted
   `attachPos = 2`; the replay's `readAllForward` (on the tail's thread, not the
   publisher's, so not gated) reads positions 1-5 in one page — overshooting the
   attach position by exactly the audit's mechanism (events 3-5 are past
   `attachPos` with no upper bound on the page). Read five `event` frames and
   record their `event.globalPosition` values (expect `[1,2,3,4,5]`).
4. Open the gate: `atomically (writeTVar gateVar True)`. The publisher finishes
   decoding and broadcasts positions 3-5 into the tail's queue. Old code: the
   filter `> attachPos = > 2` passes them and the client receives 3, 4, 5 a
   second time. Fixed code: the filter is `> covered = > 5` and they are dropped.
5. Append one event to stream `ws-race-c` (position 6) and read exactly one more
   `event` frame; assert its position is 6. On the old code this read returns
   position 3 (the first duplicate) and the test fails; on the fixed code it
   returns 6.
6. Assert the full received sequence is `[1,2,3,4,5,6]`, and additionally assert
   quiescence: a final `WS.receiveData` wrapped in `timeout 500_000` returns
   `Nothing` (no seventh frame — guards against duplicates arriving after the
   live event).

Add a small helper next to `readEventType` to extract positions:

```haskell
-- | Read until an @event@ message, returning its @event.globalPosition@.
readEventPosition :: WS.Connection -> IO Int64
readEventPosition conn = do
    v <- waitForType conn "event"
    case look ["event", "globalPosition"] v of
        Just (Number n) -> pure (truncate (toRealFloat n :: Double))
        other -> expectationFailure ("event without globalPosition: " <> show other) >> error "no position"
```

**Test 2: replay-error fail-stop.** Add a fourth `it` block:
`"terminates the tail after a replay error instead of streaming with a gap"`. No
gate is needed here (use plain `defaultConnectionSettings`). First make the replay
actually read: append two events to stream `ws-err-a` (positions 1-2) and wait with
`waitForPublisherPosition store 2 5_000_000`, so a later `from_position: 0`
subscription sees `attachPos = 2 > 0` and must hit the database (with
`attachPos == from` the replay returns without reading and no error could occur).
Then inject a real database failure by breaking the schema the read depends on:
`readAllForwardSQL` joins the `events` table
(`kiroku-store/src/Kiroku/Store/SQL.hs`, lines 507-521), and each test owns a
disposable database, so renaming the table is safe and total:

```haskell
renamed <- Pool.use store.pool (Session.sql "ALTER TABLE events RENAME TO events_hidden")
renamed `shouldBe` Right ()
```

(`Pool.use` from `hasql-pool` — already a test dep — and `Session.sql` from
`hasql`, added in Edit 3. `store.pool` is a public field of `KirokuStore`; the
pool's connections have `search_path` set to the `kiroku` schema, so the unqualified
name resolves. The store's publisher will also start logging read errors to its
optional handler — harmless here; do not wire `metricsEventHandler` in this test.)

Then connect, send `{"type":"subscribe_events","from_position":0}`, read the
`event_stream_started` frame, and assert the next frame is
`{"type":"error", ...}` whose `message` contains `"replay error"` (use
`waitForType conn "error"` and `look ["message"]`). Now prove the tail actually
terminated rather than proceeding to the live loop: while keeping the client
connected, call `waitForSubscriberCount store 0 5_000_000` (existing helper). On the
fixed code the tail thread returned and its `finally` deregistered the broadcast
queue, so the count drops to 0 with the client still connected. On the old code the
tail is sitting in `broadcastLoop`, the subscriber stays registered, and the helper
fails with "subscriber count did not reach 0; still 1" — a faithful behavioral
signature of the gap bug.

Acceptance for Milestone 1: `cabal test kiroku-metrics:kiroku-metrics-test` passes
from the repository root; reverting only the two `WebSocket.hs` edits (keeping the
tests) makes Test 1 fail at step 5 (position 3 received where 6 expected) and Test 2
fail at the subscriber-count assertion. The two pre-existing WebSocket tests
(from-now streaming; boundary replay) still pass unmodified — the from-now filter
semantics were deliberately untouched.


### Milestone 2 — `subscriptionsApp` unknown paths return the documented 404

Scope: `kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs` and
`kiroku-metrics/test/Test/SubscriptionsSpec.hs`. At the end, a `GET` of any path the
app does not serve returns HTTP 404 with `{"error":"Not found"}`, matching both the
haddock and the rest of the package.

**Edit:** in `subscriptionsApp` (line 60), replace

```haskell
        _ -> respond (jsonResponse status200 (encode ([] :: [SubscriptionStatusRow])))
```

with

```haskell
        _ -> respond (jsonResponse status404 (encode (object ["error" .= ("Not found" :: Text)])))
```

adding `status404` to the `Network.HTTP.Types` import, `object` and `(.=)` to the
`Data.Aeson` import, and `Data.Text (Text)` to the imports. The unused
`SubscriptionStatusRow (..)` import remains used by the by-name filter. Update the
haddock (line 47) to "Any other path returns a 404 with body
@{\"error\": \"Not found\"}@."

**Test:** the server router shields this branch (3-segment paths 404 in `httpApp`
before reaching `subscriptionsApp`), so the test must mount the app directly, which
is also its public standalone contract. In
`kiroku-metrics/test/Test/SubscriptionsSpec.hs` add:

```haskell
    it "returns the documented 404 JSON body for unknown paths when mounted standalone" $
        Warp.testWithApplication (pure (subscriptionsApp (pure []))) $ \port -> do
            mgr <- newManager defaultManagerSettings
            req <- parseRequest ("http://127.0.0.1:" <> show port <> "/definitely/not/a/route")
            resp <- httpLbs req mgr
            statusCode (responseStatus resp) `shouldBe` 404
            Aeson.decode (responseBody resp)
                `shouldBe` Just (Aeson.object ["error" Aeson..= ("Not found" :: Text)])
```

with `import Network.Wai.Handler.Warp qualified as Warp` (the `warp` test dep from
Edit 3), `responseStatus` added to the existing `Network.HTTP.Client` import list,
`statusCode` from `Network.HTTP.Types.Status`, and `subscriptionsApp` added to the
`Kiroku.Metrics` import list. (`httpLbs` does not throw on non-2xx for requests
built with `parseRequest`, so the 404 arrives as a normal response.) No database is
needed; the provider is `pure []`.

Acceptance for Milestone 2: the new test passes; flipping the status back to
`status200` makes it fail with `200 /= 404`. The pre-existing by-name tests
(`/subscriptions/<known>` → one row, `/subscriptions/<unknown>` → `[]` with 200)
still pass, because a recognized-but-empty name is a 200-with-`[]`, distinct from an
unrecognized *path*. The expected wire exchange:

```text
GET /definitely/not/a/route HTTP/1.1
Host: 127.0.0.1:<port>

HTTP/1.1 404 Not Found
Content-Type: application/json

{"error":"Not found"}
```


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, inside the project dev shell
(the shell provides `ghc-9.12.4`, `cabal`, and the PostgreSQL binaries that
`ephemeral-pg` execs; no external database needs to be running — the test suite
boots its own).

1. Confirm a clean baseline before touching anything:

   ```bash
   cabal build kiroku-metrics
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
   ```

   Expect every example to pass (output ends with something like
   `N examples, 0 failures`).

2. Milestone 1 edits: `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` (Edits 1-2),
   `kiroku-metrics/kiroku-metrics.cabal` (Edit 3), then the two new tests in
   `kiroku-metrics/test/Test/WebSocketSpec.hs`. Iterate on just the new examples:

   ```bash
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
     --test-options='--match "exactly once"'
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
     --test-options='--match "terminates the tail"'
   ```

3. Prove the regression tests bite: `git stash push -- kiroku-metrics/src` (stashes
   only the source fix, keeping the tests), rerun the two commands above, and
   confirm both fail — Test 1 with a position mismatch at the live-event read
   (received `3`, expected `6`), Test 2 with
   `subscriber count did not reach 0; still 1`. Then `git stash pop` and rerun to
   green. Record the failing output snippets in Surprises & Discoveries.

4. Milestone 2 edits: `kiroku-metrics/src/Kiroku/Metrics/Subscriptions.hs`, then the
   new test in `kiroku-metrics/test/Test/SubscriptionsSpec.hs`:

   ```bash
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
     --test-options='--match "documented 404"'
   ```

5. Full verification: the whole suite, then the workspace build to catch any
   cross-package fallout (none expected; only `kiroku-metrics` changed):

   ```bash
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct
   cabal build all
   ```

6. Bookkeeping: in
   `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`,
   set the EP-6 registry row's Status to Complete and check the progress item
   "EP-6: WS replay neither duplicates past attach position nor falls through a
   gap"; copy the in-flight-batch race note from this plan's Decision Log into the
   master plan's Surprises & Discoveries. Update this plan's Progress, Surprises &
   Discoveries, and Outcomes & Retrospective. Commit with conventional messages,
   for example:

   ```text
   fix(kiroku-metrics): deliver each event exactly once across the ws replay/live boundary

   fix(kiroku-metrics): terminate the /ws/events tail on a replay read error

   fix(kiroku-metrics): return the documented 404 for unknown subscriptionsApp paths
   ```

   (One combined commit is also acceptable; keep the message scoped to
   `kiroku-metrics`.)


## Validation and Acceptance

The plan is done when all of the following hold, each observable by running a
command and reading its output.

1. **Exactly-once across the replay/live boundary.** The new WebSocketSpec example
   ("delivers each global position exactly once when the replay overlaps live
   appends") passes: with the publisher deterministically frozen at position 2 and
   five events already in the database, a client subscribing with
   `from_position: 0` receives positions 1-5 exactly once (replay, overshooting the
   attach position), then — after the publisher is released and a sixth event is
   appended — position 6 and nothing else within the 500 ms quiescence window. Run:

   ```bash
   cabal test kiroku-metrics:kiroku-metrics-test --test-show-details=direct \
     --test-options='--match "exactly once"'
   ```

   On the pre-fix code this same test fails deterministically (the frame after the
   gate opens carries position 1 again — the audit's duplicate delivery, reproduced
   on every run, not probabilistically).

2. **Fail-stop on replay error.** The new example ("terminates the tail after a
   replay error instead of streaming with a gap") passes: with the `events` table
   renamed away, subscribing with `from_position: 0` yields an `error` frame whose
   message contains `replay error`, and the publisher's subscriber count returns to
   0 while the client is still connected — the tail is gone, so no gapped live
   stream can follow. On the pre-fix code the count stays at 1 and the test fails.

3. **Documented 404.** The new SubscriptionsSpec example passes: a standalone-mounted
   `subscriptionsApp` answers `GET /definitely/not/a/route` with status 404 and body
   `{"error":"Not found"}` (transcript in Milestone 2).

4. **No regressions.** The full `kiroku-metrics-test` suite passes (the two
   pre-existing WebSocket examples — from-now streaming with cleanup, and the
   non-racing boundary replay — and all Subscriptions examples among them), and
   `cabal build all` succeeds.


## Idempotence and Recovery

Every step is safe to repeat. The source edits are plain code changes with no
migrations, no schema changes, and no generated files; re-running any `cabal build`
or `cabal test` command is idempotent. Each test example gets a private, freshly
migrated, throwaway database from `withMigratedTestDatabase`, so destructive test
actions (the `ALTER TABLE events RENAME` fault injection) cannot leak between
examples or runs — the database is dropped with the ephemeral server. If a test run
is interrupted, `ephemeral-pg`'s cached server directory cleans itself up on the
next run; simply rerun the test command. If the regression-bite check (Concrete
Step 3) goes wrong, `git stash list` / `git stash pop` restores the fix; nothing in
that step touches the tests. If the gate-based test ever hangs (a bug in the test,
not the code under test — e.g. the gate was never opened), the per-example
`timeout 15_000_000` wrappers used throughout the spec abort it with a clear
"client timed out" failure rather than wedging the suite.


## Interfaces and Dependencies

No new packages enter the repository and no library dependency changes; the only
cabal change is adding `hasql >=1.10 && <1.11` and `warp >=3.4 && <3.5` to the
`kiroku-metrics-test` test-suite stanza in `kiroku-metrics/kiroku-metrics.cabal`
(both already build as library deps of this workspace — closure-neutral; see
Decision Log).

At the end of Milestone 1, `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` must
contain:

```haskell
replayHistory :: KirokuStore -> WS.Connection -> Int64 -> Int64 -> IO (Maybe Int64)
```

with the contract: `Just covered` ⇒ every event in `(from, covered]` was sent and
`covered >= attachPos`; `Nothing` ⇒ an `ErrorMsg` was sent and the caller must not
enter `broadcastLoop`. `eventTail` keeps its existing signature
(`MetricsServerConfig -> KirokuStore -> WS.Connection -> Maybe Int64 -> Maybe Text ->
IO ()`); the module's export list is unchanged (`replayHistory` stays internal). The
wire protocol (`ClientMessage`/`ServerMessage` JSON shapes) is unchanged — no new
message types; clients need no updates.

At the end of Milestone 2, `Kiroku.Metrics.Subscriptions.subscriptionsApp ::
SubscriptionStatusProvider -> Network.Wai.Application` keeps its signature; only its
unknown-path response changes to `status404` with body
`{"error":"Not found"}`, encoded via the existing
`Kiroku.Metrics.JSON.jsonResponse :: Status -> LBS.ByteString -> Response`.

Public APIs from other workspace packages relied on (read-only, all pre-existing):
`Kiroku.Store.Subscription.EventPublisher` (`EventPublisher (..)` for
`publisherThread`, `subscribePublisher`, `publisherPosition`),
`Kiroku.Store.Settings.StoreSettings` (`decodeHook`),
`Kiroku.Store.Connection.KirokuStore` (`pool`, `publisher`), and
`Kiroku.Store` reads (`readAllForward`, `runStoreIO`). Test-side libraries:
`websockets` (`WS.runClient`), `hasql`/`hasql-pool` (`Session.sql`, `Pool.use`),
`warp` (`testWithApplication`), `http-client`, `hspec`, `generic-lens` — all already
in the test stanza except `hasql` and `warp` as noted.
