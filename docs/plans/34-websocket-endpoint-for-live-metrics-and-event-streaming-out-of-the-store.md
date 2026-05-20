---
id: 34
slug: websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store
title: "WebSocket Endpoint For Live Metrics And Event Streaming Out Of The Store"
kind: exec-plan
created_at: 2026-05-20T04:16:54Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
master_plan: "docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md"
---

# WebSocket Endpoint For Live Metrics And Event Streaming Out Of The Store

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is the third of four child plans under the MasterPlan
`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`. It
**hard-depends on EP-2**
(`docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md`):
it fills the WebSocket-handler seam (MasterPlan Integration Point IP-3) that EP-2
left stubbed. It transitively depends on EP-1
(`docs/plans/32-kiroku-metrics-package-foundation-and-in-process-metrics-collector.md`)
for the collector and snapshot. This plan owns Integration Point IP-4 (the
WebSocket message protocol and the `RecordedEvent` JSON encoding).


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. EP-1 built an in-process metrics
collector; EP-2 exposed it over HTTP (JSON, Prometheus, health) and built the Warp
server with a WebSocket-upgrade seam that currently rejects all WebSocket
connections with "WebSocket endpoint not yet implemented".

This plan makes the WebSocket real, and in doing so delivers the strategic payoff
of the whole initiative: **streaming events out of the store over a network
socket**. After this plan, a client (a browser dashboard, a `websocat` CLI, or any
non-Haskell service) can open a WebSocket to the metrics server and:

- On `ws://host:9091/ws/metrics` — receive a metrics snapshot immediately on
  connect, then receive a fresh snapshot every `wsPushIntervalUs` microseconds
  (default 1s) for as long as it stays connected; send `{"type":"ping"}` and get
  `{"type":"pong"}`.
- On `ws://host:9091/ws/events` — **subscribe to the store's live event stream**
  and receive each appended `RecordedEvent` as a JSON message in global-position
  order, as it happens. Optionally the client asks to start from a chosen global
  position (replaying history first, then continuing live) and/or restrict to a
  single category. This turns an append into a push to every connected watcher,
  with no polling and no Haskell subscription code on the client side.

You can *see it working* with `websocat`: connect to `/ws/events`, append events
to the store from another process, and watch the JSON events arrive on the socket
in real time. The end-to-end test in this plan does exactly that programmatically.

The event tail is built entirely on **public `kiroku-store` APIs** and creates
**no persistent subscription** — it does not write to the `subscriptions`
checkpoint table, so transient watchers leave no trace and never trigger a
full-store replay. See the Decision Log.


## Progress

- [ ] M1: `Kiroku.Metrics.WebSocket` module: protocol types (`ClientMessage`/`ServerMessage`), path dispatch, connection limiting + ping thread, and the **metrics channel** (snapshot on connect + periodic push + ping/pong). EP-2's stub replaced; `enableWebSocket` makes `/ws/metrics` functional.
- [ ] M2: **Event channel** on `/ws/events`: live "from-now" tail via `subscribePublisher`; `recordedEventToJSON`; client `subscribe_events`/`unsubscribe_events`; clean teardown on disconnect.
- [ ] M3: Optional `fromPosition` replay (via `runStoreIO store . readAllForward`) and optional `category` filter (via `runStoreIO store . readCategory` driven by `publisherPosition`); end-to-end WebSocket test (append → receive events + metric updates over a real socket).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Two WebSocket paths — `/ws/metrics` and `/ws/events` — dispatched
  inside one `WS.ServerApp` by inspecting the pending request path, rather than
  one socket multiplexing both payload families.
  Rationale: The metrics payload (a snapshot) and the event payload (a
  `RecordedEvent`) are unrelated; separate paths keep each protocol simple and let
  a client open only what it needs. `websocketsOr` hands the single `ServerApp`
  every upgrade; `Network.WebSockets.pendingRequest` exposes the path to dispatch
  on.
  Date: 2026-05-19

- Decision: Build the event tail on the public `EventPublisher` broadcast
  (`subscribePublisher`) for live delivery and `runStoreIO store . readAllForward`
  / `readCategory` for replay/category, not on a named `subscribe`/
  `subscriptionStream`.
  Rationale: Named subscriptions checkpoint by name in the `subscriptions` table; a
  transient socket using a fresh name would replay the whole store from position 0
  and leave orphan checkpoint rows. `subscribePublisher` delivers newly-appended
  events to a bounded queue with zero checkpoint involvement — exactly a from-now
  tail. Historical replay reuses the public effectful `readAllForward`; category
  filtering reuses `readCategory` (the broadcast carries no stream name, so a
  category filter cannot be applied to broadcast events directly). This keeps the
  whole plan on public APIs with no `kiroku-store` change. (MasterPlan Decision
  Log records the same.)
  Date: 2026-05-19

- Decision: Encode `RecordedEvent` with an explicit `recordedEventToJSON ::
  RecordedEvent -> Value` function inside `kiroku-metrics`, not a `ToJSON`
  instance.
  Rationale: `RecordedEvent` has no `ToJSON` today and `kiroku-store` keeps its
  `Types` module instance-light; a library-level orphan instance is undesirable.
  An explicit function is orphan-free and keeps the wire shape documented in one
  place (EP-4's guide). If a public `ToJSON RecordedEvent` is later wanted, the
  non-orphan home is `kiroku-store`'s `Kiroku.Store.Types`, decided then.
  Date: 2026-05-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The seam EP-2 left (your entry point)

EP-2 built `Kiroku.Metrics.Server` (file `kiroku-metrics/src/Kiroku/Metrics/Server.hs`)
with the combined WAI app:

```haskell
combinedApp cfg m deps wsApp =
  WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps)

startMetricsServerWith :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> IO MetricsServer
startMetricsServer cfg m deps = startMetricsServerWith cfg m deps stubWebSocketApp   -- the stub you replace
```

`WS.ServerApp` is `Network.WebSockets.PendingConnection -> IO ()`. EP-2's
`stubWebSocketApp` rejects every upgrade. This plan provides the real
`WS.ServerApp` (named `websocketApp`) that closes over the config, the collector,
**and the `KirokuStore`** (needed for event streaming — EP-2 deliberately kept the
store out of the *server* signature so the store enters here via the closure), and
a convenience starter that wires it. After this plan, the recommended entry point
becomes:

```haskell
startMetricsServerWithStore
  :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> [DependencyCheck] -> IO MetricsServer
startMetricsServerWithStore cfg m store deps =
  startMetricsServerWith cfg m deps (websocketApp cfg m store)
```

Add `startMetricsServerWithStore` (and a `withMetricsServerWithStore` bracket) to
`Kiroku.Metrics.Server` and re-export from `Kiroku.Metrics`. Leave EP-2's
`startMetricsServer` (stub) in place for callers who do not want the WebSocket; do
not change its type.

### The metrics inputs (from EP-1)

- `Kiroku.Metrics.Collector`: `KirokuMetrics`, `snapshotMetrics :: KirokuMetrics ->
  IO MetricsSnapshot`.
- `Kiroku.Metrics.Types`: `MetricsSnapshot` with `ToJSON`. The metrics channel
  sends `MetricsSnapshot` JSON.

### The event-streaming inputs (public `kiroku-store` APIs)

All of these are already public; this plan needs **no `kiroku-store` change**.

- **Live from-now tail.** `Kiroku.Store.Subscription.EventPublisher` (exposed
  module) exports:

  ```haskell
  subscribePublisher
    :: EventPublisher -> Numeric.Natural.Natural -> OverflowPolicy
    -> STM (TBQueue (Data.Vector.Vector RecordedEvent), TVar SubscriberStatus, IO ())
  publisherPosition :: EventPublisher -> STM GlobalPosition
  data SubscriberStatus = Active | Overflowed
  ```

  Get the publisher from the store handle: `store.publisher`
  (`KirokuStore` field, `Kiroku.Store.Connection.KirokuStore (..)`). Call
  `atomically (subscribePublisher store.publisher cap DropOldest)` to register a
  bounded broadcast queue; the returned `IO ()` is the **unsubscribe** action you
  MUST run on disconnect (otherwise the publisher keeps delivering to a dead
  queue). Use `DropOldest` (`Kiroku.Store.Subscription.Types.OverflowPolicy`): a
  slow socket consumer should lose old events, not crash the publisher fan-out.
  Read batches with `atomically (readTBQueue queue)`, which yields a
  `Vector RecordedEvent` (one publisher batch). Each batch is already in
  ascending global-position order.

- **Replay / catch-up and category.** Run the public effectful reads in `IO` via
  `Kiroku.Store.Effect.runStoreIO`:

  ```haskell
  runStoreIO   :: KirokuStore -> Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)
  readAllForward :: (Store :> es) => GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
  readCategory   :: (Store :> es) => CategoryName -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
  ```

  e.g. `runStoreIO store (readAllForward (GlobalPosition cursor) 500)` returns
  `IO (Either StoreError (Vector RecordedEvent))`. `readAllForward`/`readCategory`
  are cursor-*exclusive* (return events with position strictly greater than the
  cursor), matching how the subscription worker pages.

- **`RecordedEvent` fields** (`Kiroku.Store.Types`, re-exported from
  `Kiroku.Store`), all public, for `recordedEventToJSON`:

  ```haskell
  data RecordedEvent = RecordedEvent
    { eventId :: !EventId          -- newtype over Data.UUID.UUID
    , eventType :: !EventType      -- newtype Text
    , streamVersion :: !StreamVersion        -- newtype Int64
    , globalPosition :: !GlobalPosition      -- newtype Int64
    , originalStreamId :: !StreamId          -- newtype Int64
    , originalVersion :: !StreamVersion
    , payload :: !Data.Aeson.Value
    , metadata :: !(Maybe Data.Aeson.Value)
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    , createdAt :: !Data.Time.UTCTime
    }
  ```

  Note `RecordedEvent` carries the source stream's *surrogate id*
  (`originalStreamId`), **not** the stream name, so a category filter cannot be
  applied to broadcast events in-process — which is exactly why category filtering
  goes through `readCategory` (filtered in SQL) instead of the broadcast.

### The model to copy: `shibuya-metrics`' WebSocket

`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs`
shows the connection lifecycle to mirror: a `WebSocketState` with a
connection-count `TVar` and a max; `acquireConnection`/`releaseConnection`;
`WS.acceptRequest`; `WS.withPingThread conn 30 (pure ())` for keepalive; an
`async` push loop `link`ed to the receive loop; and `finally` cleanup that
releases the slot and sends a goodbye. Reuse this exact shape for the metrics
channel and adapt it for the event channel (where the "push loop" reads the
broadcast queue instead of polling metrics).
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics/src/Shibuya/Metrics/Types.hs`
shows the `ClientMessage`/`ServerMessage` tagged-JSON encoding to mirror.


## Plan of Work

Three milestones.

### Milestone M1 — Protocol types, path dispatch, and the metrics channel

Scope: create `Kiroku.Metrics.WebSocket` with the protocol types, the
connection-limiting/ping scaffolding, the path dispatcher, and a working metrics
channel. Replace EP-2's stub so `/ws/metrics` works. At the end, a `websocat`
client on `/ws/metrics` gets a snapshot on connect and periodic updates.

Add module `Kiroku.Metrics.WebSocket` to `exposed-modules`. New deps for the
library: `async >=2.2`, `unliftio >=0.2` (or just `async` + `safe-exceptions`/
`finally` from `base`/`Control.Exception` — `async` plus `Control.Exception` is
enough; avoid pulling extra deps), `vector >=0.13` (for the broadcast batch type),
`stm` (already present). Reuse `aeson`, `text`, `bytestring`, `websockets`.

Protocol types (in `Kiroku.Metrics.WebSocket` or a small `Kiroku.Metrics.Protocol`
module; pick one and re-export from `Kiroku.Metrics`). The protocol is tagged
JSON (`{"type": "..."}`):

```haskell
data ClientMessage
  = Ping
  | SubscribeMetrics                                  -- (metrics channel) start/refresh snapshot
  | SubscribeEvents { fromPosition :: Maybe Int64     -- Nothing = from-now
                    , category     :: Maybe Text }    -- Nothing = all streams
  | UnsubscribeEvents
  deriving stock (Eq, Show)

data ServerMessage
  = Pong
  | Snapshot MetricsSnapshot                          -- metrics channel
  | Event Value                                        -- event channel; Value = recordedEventToJSON e
  | EventStreamStarted { fromPosition :: Int64 }      -- ack: streaming from this position
  | Goodbye
  | ErrorMsg Text
```

Write `FromJSON ClientMessage` and `ToJSON ServerMessage` by hand (tagged on a
`"type"` field: `"ping"`, `"subscribe_metrics"`, `"subscribe_events"`,
`"unsubscribe_events"` / `"pong"`, `"snapshot"`, `"event"`,
`"event_stream_started"`, `"goodbye"`, `"error"`). `Snapshot` embeds the
`MetricsSnapshot` ToJSON under a `"metrics"` key; `Event` embeds the event JSON
under an `"event"` key.

Connection scaffolding (mirror `shibuya-metrics`): a `WebSocketState { connCount
:: TVar Int, maxConns :: Int }` created once per server (allocate it inside
`websocketApp` via a top-level `IORef`/closure, or pass it in; simplest is to
allocate it in `startMetricsServerWithStore` and capture it). `acquireConnection`
returns `False` when at capacity → `WS.rejectRequest pending "Too many
connections"`.

`websocketApp :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> WS.ServerApp`:

```haskell
websocketApp cfg m store pending = do
  let path = WS.requestPath (WS.pendingRequest pending)   -- e.g. "/ws/metrics" or "/ws/events?from=10"
  case dispatchPath path of
    MetricsPath -> handleMetrics cfg m pending
    EventsPath  -> handleEvents  cfg m store pending
    UnknownPath -> WS.rejectRequest pending "Unknown WebSocket path; use /ws/metrics or /ws/events"
```

`handleMetrics`: acquire slot (reject if full); `conn <- WS.acceptRequest
pending`; `WS.withPingThread conn 30 (pure ())` for keepalive; send the initial
`Snapshot` (`snapshotMetrics m`); spawn a push loop (`async`) that every
`cfg.wsPushIntervalUs` sends a fresh `Snapshot`; run a receive loop that answers
`Ping` with `Pong` and ignores other messages; `finally` cancel the push loop,
send `Goodbye`, release the slot. (You may send the snapshot only when it changed,
as shibuya does, but unconditional periodic push is simpler and fine for v1 —
record the choice.)

Replace the stub: change `startMetricsServer`'s default? No — leave
`startMetricsServer` as the stub variant (EP-2 contract) and add
`startMetricsServerWithStore`/`withMetricsServerWithStore` that pass `websocketApp`.

Acceptance M1: with a server started via `startMetricsServerWithStore` and a real
store, `websocat ws://localhost:9091/ws/metrics` prints a `{"type":"snapshot",...}`
message immediately and another every ~1s; sending `{"type":"ping"}` yields
`{"type":"pong"}`.

### Milestone M2 — Event channel: live from-now tail

Scope: implement `handleEvents` for the default (from-now, all-streams) case and
`recordedEventToJSON`. At the end, a client on `/ws/events` that sends
`{"type":"subscribe_events"}` receives every newly-appended event as JSON.

`recordedEventToJSON :: RecordedEvent -> Value` — an `object` with keys
`eventId` (UUID as text), `eventType` (text), `streamVersion` (number),
`globalPosition` (number), `originalStreamId` (number), `originalVersion`
(number), `payload` (the raw `Value`), `metadata` (the `Maybe Value`),
`causationId`/`correlationId` (UUID-as-text or null), `createdAt` (ISO-8601 via
aeson's `UTCTime` instance). Document this shape; EP-4 publishes it.

`handleEvents cfg m store pending`:

1. Acquire a slot (reject if full); `conn <- WS.acceptRequest pending`;
   `WS.withPingThread conn 30 (pure ())`.
2. Wait for the first `ClientMessage`. If `SubscribeEvents{fromPosition=Nothing,
   category=Nothing}` (or a path/query that means the same), start a from-now tail:
   - `(queue, statusVar, unsubscribe) <- atomically (subscribePublisher
     store.publisher cap DropOldest)` with `cap` a reasonable bound (e.g. 256
     batches; expose as a config field with a default so IP-3's "no new *required*
     field" holds — add `wsEventQueueCap :: Natural` to `MetricsServerConfig` with
     a default, which is additive and keeps EP-2's `defaultConfig` working).
   - Read the current position (`atomically (publisherPosition store.publisher)`)
     and send `EventStreamStarted{fromPosition = that}`.
   - Loop: `batch <- atomically (readTBQueue queue)`; for each event in the
     `Vector` send `Event (recordedEventToJSON e)`; also observe `statusVar` —
     if `Overflowed`, send `ErrorMsg "event stream overflowed"` and continue (under
     `DropOldest` the publisher does not set `Overflowed`, but handle it
     defensively).
   - `finally` the loop with `unsubscribe` and `Goodbye`, and release the slot.
3. A `receive` concurrent task handles `Ping`→`Pong` and `UnsubscribeEvents`
   (which cancels the tail loop). Use the `async`+`link`+`finally` pattern.

> Backpressure note: `subscribePublisher`'s bounded queue plus `DropOldest` means
> a slow WebSocket client cannot stall the publisher or other subscribers; it just
> drops the oldest undelivered batches. This is the right default for a telemetry
> tail (matching the `DropOldest` doc in `Kiroku.Store.Subscription.Types`).

Acceptance M2: with the server running and a client connected to `/ws/events`
having sent `{"type":"subscribe_events"}`, appending an event from another process
(e.g. via `cabal repl` calling `appendToStream`) causes a `{"type":"event",...}`
message to arrive on the socket within the publisher's tick.

### Milestone M3 — Replay-from-position, category filter, and the end-to-end test

Scope: extend `handleEvents` for `fromPosition` (catch-up replay then live) and
`category` (SQL-filtered live), and add the end-to-end test.

- **`fromPosition = Just p`, no category:** before attaching to the broadcast,
  page history with `runStoreIO store (readAllForward (GlobalPosition cursor)
  limit)` from `cursor = p` until you reach the current `publisherPosition`,
  sending each event. Then attach to the broadcast (as M2) but **drop events whose
  `globalPosition <= cursor`** to avoid duplicating the catch-up tail (the worker
  does the same: `V.filter ((> cursor) . globalPosition)`). Send
  `EventStreamStarted{fromPosition = p}` before catch-up.
- **`category = Just c`:** do not use the broadcast (it has no names). Instead run
  a DB-driven loop: `cursor` starts at `fromPosition` (or current position for
  from-now); repeatedly (a) wait until `publisherPosition > cursor`
  (`atomically $ readTVar/check`, exactly as `Worker.liveLoopCategoryDriven`),
  (b) `runStoreIO store (readCategory (CategoryName c) (GlobalPosition cursor)
  limit)`, (c) send each returned event and advance `cursor` to the last event's
  position. This mirrors the subscription worker's category-live strategy and uses
  only public APIs.
- Handle `Left StoreError` from `runStoreIO` by sending `ErrorMsg` and continuing
  (or closing) — do not crash the connection silently.

End-to-end test (`kiroku-metrics/test/...`): start a real store + collector +
server via `startMetricsServerWithStore` on an OS-assigned port; open a WebSocket
client (the `websockets` library's `runClient`) to `/ws/events`; send
`subscribe_events`; from the test thread `appendToStream` three events; assert the
client receives three `{"type":"event"}` messages with the expected `eventType`s
in order. Add a second assertion on `/ws/metrics`: connect, receive a snapshot,
and confirm `store.globalPosition` reflects the appended events. Use timeouts so a
hang fails the test rather than blocking.

Acceptance M3: `cabal test kiroku-metrics` green including the end-to-end
WebSocket test; manual `websocat` replay (`/ws/events` with `{"type":
"subscribe_events","fromPosition":0}`) replays history then continues live.


## Concrete Steps

Run from the repository root inside `nix develop`. `websocat` is a handy manual
client; if it is not in the dev shell, the automated test uses the `websockets`
library's client and is sufficient — note in Progress which you used.

1. M1: add `Kiroku.Metrics.WebSocket` to `exposed-modules` and the new deps
   (`async`, `vector`) to `kiroku-metrics.cabal`; write the protocol types,
   scaffolding, dispatcher, and `handleMetrics`; add `startMetricsServerWithStore`
   /`withMetricsServerWithStore` to `Kiroku.Metrics.Server`; re-export from
   `Kiroku.Metrics`. Build:

   ```bash
   cabal build kiroku-metrics
   ```

   Manual check (two terminals; server started in `ghci` via
   `startMetricsServerWithStore defaultConfig m store []`):

   ```bash
   websocat ws://localhost:9091/ws/metrics
   # expect a {"type":"snapshot",...} immediately, then ~1/s; type {"type":"ping"} -> {"type":"pong"}
   ```

2. M2: implement `recordedEventToJSON` and the from-now `handleEvents`; rebuild;
   manual check:

   ```bash
   # terminal A:
   websocat ws://localhost:9091/ws/events
   # then send:  {"type":"subscribe_events"}
   # terminal B (ghci): appendToStream store (StreamName "orders-1") AnyVersion [makeEvent "OrderCreated" payload]
   # terminal A should print: {"type":"event","event":{...,"eventType":"OrderCreated",...}}
   ```

3. M3: implement `fromPosition` replay and `category` filtering; add the
   end-to-end test; then:

   ```bash
   cabal test kiroku-metrics
   ```

   Expected: the WebSocket end-to-end spec passes (3 events appended → 3 event
   messages received in order).

4. Commit after each milestone with all three trailers:

   ```text
   feat(kiroku-metrics): stream events out over WebSocket

   MasterPlan: docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md
   ExecPlan: docs/plans/34-websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store.md
   Intention: intention_01ks1saptfe6j8e98dvce7mvgf
   ```


## Validation and Acceptance

Complete when:

1. `cabal build kiroku-metrics` and `nix build .#kiroku-metrics` succeed.
2. `cabal test kiroku-metrics` is green, including the end-to-end WebSocket test
   (EP-1 and EP-2 specs continue to pass).
3. Behavioral, observable over a real socket:
   - `/ws/metrics` delivers a snapshot on connect and periodic snapshots; `ping`
     → `pong`.
   - `/ws/events` with `subscribe_events` delivers each appended `RecordedEvent`
     as `{"type":"event",...}` in global-position order, live, with no polling and
     no row written to the `subscriptions` table (verify by querying
     `SELECT count(*) FROM subscriptions` before and after a tail session — it
     does not increase).
   - `fromPosition` replays history from that position then continues live without
     duplicating the boundary event.
   - `category` restricts the stream to that category's events only.
   - Disconnecting a client runs `unsubscribe` (the publisher's subscriber count,
     visible in `/metrics` as `store.activeSubscribers`, returns to its prior
     value).
4. The EP-2 server structure is unchanged except for additive
   `startMetricsServerWithStore`/`withMetricsServerWithStore` and at most additive
   `MetricsServerConfig` fields with defaults (`wsEventQueueCap`); EP-2's
   `startMetricsServer` and `defaultConfig` still compile and behave as before.


## Idempotence and Recovery

All edits are additive. Re-running builds/tests is safe. WebSocket connections are
bounded by `wsMaxConnections`; a leaked `ghci` connection is freed on `:r`/quit.
Every event-tail path installs its `unsubscribe`/cleanup under `finally`, so an
exception or client disconnect always deregisters the broadcast subscriber — if
you observe `store.activeSubscribers` not returning to baseline after a
disconnect, the `finally` wiring is wrong; fix it before considering the milestone
done. The end-to-end test uses an ephemeral database and an OS-assigned port.


## Interfaces and Dependencies

New module `Kiroku.Metrics.WebSocket` (and optionally `Kiroku.Metrics.Protocol`):

- `ClientMessage (..)`, `ServerMessage (..)` with `FromJSON`/`ToJSON`.
- `recordedEventToJSON :: RecordedEvent -> Data.Aeson.Value`.
- `websocketApp :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> WS.ServerApp`.
- `WebSocketState` + `newWebSocketState :: Int -> IO WebSocketState` (connection limiting).

Additions to `Kiroku.Metrics.Server`: `startMetricsServerWithStore`,
`withMetricsServerWithStore`. Additive field on `MetricsServerConfig`:
`wsEventQueueCap :: Numeric.Natural.Natural` (default e.g. 256), set in
`defaultConfig`.

New libraries: `async`, `vector` (the broadcast batch `Vector RecordedEvent`).
Reused: `websockets`, `aeson`, `text`, `bytestring`, `stm` (EP-2/EP-1 deps).

Consumed-from `kiroku-store` (all public; no `kiroku-store` change):
`Kiroku.Store.Connection.KirokuStore (..)` (`publisher` field),
`Kiroku.Store.Subscription.EventPublisher` (`subscribePublisher`,
`publisherPosition`, `SubscriberStatus (..)`),
`Kiroku.Store.Subscription.Types.OverflowPolicy (DropOldest)`,
`Kiroku.Store.Effect.runStoreIO`, `Kiroku.Store.Read.readAllForward`,
`Kiroku.Store.Read.readCategory`, `Kiroku.Store.Types.RecordedEvent (..)` and the
newtype accessors, `Kiroku.Store.Types.GlobalPosition (..)`,
`Kiroku.Store.Types.CategoryName (..)`.

This plan owns IP-4 (protocol + `recordedEventToJSON`); EP-4 documents the wire
shapes it defines. It must keep `kiroku-store` unchanged.
