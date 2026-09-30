---
id: 94
slug: converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention
title: "Converge the kiroku-metrics WebSocket protocol with the cross-project convention"
kind: exec-plan
created_at: 2026-09-30T22:35:20Z
intention: "intention_01m3t7a7jaeewbf71vqrzk4zd8"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T22:35:20Z
---

# Converge the kiroku-metrics WebSocket protocol with the cross-project convention

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is EP-5 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md).
It implements the improvement request
[IR-12, Converge the WebSocket protocol with the cross-project convention](../improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md),
canonically `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-12`, filed by the keiro
runtime UI initiative (`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). Every
commit made under this plan carries three trailers:

```text
MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
```


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell. Its HTTP sister package,
`kiroku-metrics`, serves two WebSocket paths from the same Warp server as its JSON endpoints:
`/ws/metrics` pushes metrics snapshots, and `/ws/events` streams appended events out of the store
in global-position order, optionally replaying history from a chosen position and optionally
filtered to one category. Two browser applications are about to be built against that surface:
the composed keiro runtime UI (which drives kiroku's, shibuya's, pgmq's, and keiro's WebSocket
surfaces with one client core) and, possibly, a standalone Kiroku UI for users who adopt only the
event store. The keiro-ui initiative wrote a structural convention that every WebSocket
inspection endpoint in the stack should fit, and asked kiroku (IR-12) to audit its two paths
against it, close every gap that can be closed additively, document the rest as deviations, and
publish a conformance mapping the client core is built against.

After this plan, three things are true that are not true today.

First, a client that stops caring about metrics can say so: `/ws/metrics` accepts a new
`{"type":"unsubscribe_metrics"}` frame that stops the periodic snapshot push, and
`{"type":"subscribe_metrics"}` restarts it, so the convention's explicit subscribe/unsubscribe
lifecycle holds on both paths while the shipped push-on-connect behaviour stays exactly as it is
for existing clients.

Second, every `error` frame carries a stable machine-readable `code` next to its human `message`,
and the overflow signal the user guide has always promised is actually delivered: a slow
`/ws/events` client that lost batches under the bounded drop-oldest queue receives
`{"type":"error","code":"event_stream_overflowed","message":"..."}` in-band and knows to re-read
from its last position. Today that frame is unreachable (see Context and Orientation), so a browser
tail can silently show a gapped feed as if it were complete.

Third, every `event` frame on `/ws/events` carries the resolved source stream name as a new
optional key `original_stream_name` on the event object, resolved server-side through the public
batch lookup, so a browser that only has the WebSocket can label a live tail with stream names
instead of surrogate integers. The REST browse pages of plan 88 use the same key and the same
encoder, so one client decoder serves both.

Seeing it work is a `websocat` session against any store-backed metrics server:

```text
$ websocat ws://localhost:9091/ws/events
{"type":"subscribe_events"}
{"type":"event_stream_started","from_position":42}
# (append OrderCreated to orders-7 from another shell)
{"type":"event","event":{"eventType":"OrderCreated","globalPosition":43,"originalStreamId":9,"original_stream_name":"orders-7", ...}}
```

and, on the metrics path:

```text
$ websocat ws://localhost:9091/ws/metrics
{"type":"snapshot","metrics":{...}}
{"type":"snapshot","metrics":{...}}
{"type":"unsubscribe_metrics"}
# (silence: no more periodic snapshots)
{"type":"subscribe_metrics"}
{"type":"snapshot","metrics":{...}}
{"type":"snapshot","metrics":{...}}
```

Nothing that is published today changes shape: the frame inventory, every existing field, the
camelCase keys of the event object, the queue capacity and drop-oldest semantics, and the path
dispatch are byte-for-byte what they were, and the existing `Test.WebSocketSpec` passes without a
single edit. The user guide gains a conformance mapping that names, for every element of the
convention, the kiroku frame that realises it or the recorded deviation.


## Progress

- [ ] M1: IR-12 moved from `accepted` to `in_progress` (timestamp advanced, bundle log entry,
      strict validation green).
- [ ] M1: `kiroku-store`: `Subscriber` gains `subDropped :: TVar Word64`; the `DropOldest` branch
      of `deliverBatchSTM` increments it; new `PublisherSubscription` record and
      `subscribePublisherWith`; `subscribePublisher` kept as a compatibility wrapper; changelog
      bullets under the unreleased heading.
- [ ] M1: `kiroku-store/test/Test/PublisherDropCounter.hs` proves the counter deterministically
      (cap 1, two batches, counter 1, queue holds the newest batch); registered; store suite
      green; `cabal bench kiroku-store:kiroku-shibuya-overhead` recorded before and after.
- [ ] M2: `Kiroku.Metrics.WebSocket`: `UnsubscribeMetrics` client frame, `CodedError` server frame
      with the three codes, `recordedEventToJSONResolved` (or reuse of plan 88's), per-connection
      stream-name cache in the tail, overflow detection from the drop counter,
      `overflowNotice` exported for testing; changelog bullets under `## Unreleased`.
- [ ] M2: `kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs` (frame shapes pinned,
      unsubscribe/resubscribe on the metrics path, `original_stream_name` on the live and
      category paths, `replay_failed` and `category_read_failed` codes end to end,
      `overflowNotice` cases); registered; whole metrics suite green with `Test.WebSocketSpec`
      untouched.
- [ ] M3: `docs/user/metrics.md` WebSocket section updated (new frames, the `code` vocabulary,
      the `original_stream_name` key, the conformance mapping table); CAP-17 and the
      capabilities log updated and validated; IR-12 body gains "Implementation Evidence";
      all repository validations green.
- [ ] M3: ADR distillation pass recorded in Outcomes (no ADR expected; see Decision Log);
      closing provenance revision recorded.


## Surprises & Discoveries

- Planning (2026-09-30): the overflow `error` frame documented in `docs/user/metrics.md`
  ("a slow client loses the oldest undelivered batches and is told in-band by an `error` frame")
  and enumerated as a published delivery semantic in
  [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  is never emitted. `broadcastLoop` in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` sends it
  only when the subscriber's status is `Overflowed`, but `deliverBatchSTM` in
  `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` sets `Overflowed` only under
  `DropSubscription`; under `DropOldest`, the policy the WebSocket uses, it silently discards the
  oldest queued batch (`tryReadTBQueue` then `writeTBQueue`) and leaves the status `Active`. The
  module's own comment admits it: "Defensively surfaces an `Overflowed` status (not set under
  `DropOldest`, but handled)". This plan closes that gap with a drop counter in the publisher
  (Milestone 1) rather than documenting a deviation, because both the convention and ADR-9
  already promise the signal.
- Planning (2026-09-30): IR-12's candidate gap "idle-connection server pings may not run on both
  paths" is wrong against source. `handleMetrics` and `handleEvents` both wrap their bodies in
  `WS.withPingThread conn 30 (pure ())`, which sends a WebSocket ping every 30 seconds on every
  connection. The conformance mapping records server idle pings as met with the 30-second
  precedent the convention names.


## Decision Log

- Decision: Every change is additive at the wire and, where possible, at the Haskell API. No
  published frame, field, path, status, or documented semantic is renamed, removed, re-typed, or
  given a new meaning; `dispatchPath`, `recordedEventToJSON`, `wsEventQueueCap`, `DropOldest`,
  and the existing `Test.WebSocketSpec` are untouched.
  Rationale: [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  freezes the shipped surface and allows only additive growth; IR-12's Boundaries section makes
  any breaking change unacceptable; `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` freezes the
  dialect from the client side. The existing spec passing unmodified is IR-12's first acceptance
  item and the cheapest proof that nothing shipped moved.
  Date: 2026-09-30

- Decision: Error codes are carried by a new `ServerMessage` constructor
  `CodedError !Text !Text` (code, message) encoding to `{"type":"error","code":c,"message":m}`;
  the existing `ErrorMsg !Text` constructor and its encoding stay exactly as they are, and the
  three places that build error frames today switch to `CodedError` with the codes
  `replay_failed`, `category_read_failed`, and `event_stream_overflowed`.
  Rationale: Adding a constructor is additive for Haskell callers that only construct or encode
  frames (pattern matches on `ServerMessage` in this repository are the `ToJSON` instance alone),
  and it keeps `toJSON (ErrorMsg m)` byte-identical by construction rather than by a `Maybe`
  field that must be threaded correctly. A client that ignores `code` sees exactly yesterday's
  frame; a client that switches on it no longer depends on message text, which ADR-9 says is not
  a contract.
  Date: 2026-09-30

- Decision: The unreachable overflow signal is fixed, not documented as a deviation. The
  publisher counts dropped batches per subscriber in a new `subDropped :: TVar Word64` field on
  `Subscriber`, incremented inside the existing `DropOldest` branch of `deliverBatchSTM`; a new
  `subscribePublisherWith` returns a `PublisherSubscription` record that exposes the counter, and
  `subscribePublisher` becomes a wrapper that returns the same triple it returns today. The
  WebSocket tail reads the counter after every batch and emits one `event_stream_overflowed`
  error per observed increase.
  Rationale: The convention (area 5) requires overflow to be signalled in-band, ADR-9 lists that
  signal among the published delivery semantics, and the user guide has promised it since the
  package shipped; recording "we never send it" would document a defect. The counter is exact
  where a global-position gap heuristic is not (a hard delete can also produce a gap, and category
  tails never overflow because they are SQL-driven). The ordinary delivery path (`not full`) is
  untouched, so the per-batch hot path of the publisher gains no work; the increment runs only
  when a batch is already being dropped. `Subscriber (..)` is exported with its fields, so the new
  field is a PVP-major change to `kiroku-store`, which the cohort release (plan 96) already
  carries for plans 88 and 89.
  Date: 2026-09-30

- Decision: `/ws/metrics` gains `unsubscribe_metrics`, which cancels the periodic push loop, and
  `subscribe_metrics` additionally restarts that loop when it is stopped while keeping its shipped
  meaning of "send a snapshot now". Push-on-connect stays.
  Rationale: The convention wants a connection to watch nothing until it subscribes; the shipped
  dialect pushes on connect and that behaviour is frozen. Accepting an unsubscribe frame and
  letting subscribe restart the loop gives a convention-shaped lifecycle to new clients without
  changing what an old client experiences. The push loop already runs in its own thread, so the
  change is a `TVar (Maybe (Async ()))` in the same shape `handleEvents` uses for its tail.
  Date: 2026-09-30

- Decision: `event` frames gain the optional key `original_stream_name` on the event object,
  resolved with the public `lookupStreamNames` through a per-connection `Map StreamId StreamName`
  cache, one batched lookup per delivered batch covering only ids the connection has not seen.
  The encoder is `recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value`
  in `Kiroku.Metrics.WebSocket`, owned by plan 88; this plan introduces it only if plan 88 has not
  landed, with exactly that name, type, and module.
  Rationale: [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
  keeps the name off `RecordedEvent` because carrying it on every `$all` read row measured about
  13% on `$all` pages, and it names the batch lookup as the intended resolution path. A transient
  WebSocket watcher is not a subscription worker and not an append; the lookup runs on the tail
  path only, and the cache means a stable set of streams costs one round trip per new stream, not
  per batch. The keiro-ui conventions require a new key on the frozen camelCase event object to
  be snake_case, and plan 88's Decision Log already fixed the key name so REST items and WebSocket
  frames share one decoder. `null` is emitted when an id cannot be resolved (the stream was hard
  deleted between publish and lookup) rather than dropping the event.
  Date: 2026-09-30

- Decision: Snapshot-then-delta on `/ws/events` is a documented deviation, not additively
  closed. The `event_stream_started` acknowledgement, which carries the `from_position` the
  tail starts from, is recorded as the frame that plays the snapshot role.
  Rationale: An append-only feed has no current state to snapshot; the convention itself
  distinguishes state surfaces (`update` after `snapshot`) from log-tail surfaces (`event`
  frames), and the acknowledgement already gives the client the one fact a snapshot would give
  it, the position from which the feed is complete.
  Date: 2026-09-30

- Decision: Nothing in this plan changes `dispatchPath`, hard-codes an absolute URL, or assumes
  the application is mounted at the root of a host.
  Rationale: keiro will mount the exported `kiroku-metrics` WAI application behind a path prefix
  (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`), and the composed deployment
  is the keiro-ui initiative's primary target; the WebSocket dispatch on `WS.requestPath` is
  keiro's to rewrite, not ours to assume.
  Date: 2026-09-30

- Decision: No version bump and no release in this plan. Changelog bullets go under
  `## Unreleased` in `kiroku-metrics/CHANGELOG.md` and under the unreleased heading of
  `kiroku-store/CHANGELOG.md`; MasterPlan 13's release plan
  (`docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`)
  assigns `kiroku-metrics` 0.2.0.0 and `kiroku-store` 0.10.0.0 for the whole cohort and moves
  IR-12 to `completed`.
  Rationale: Four sibling plans change the same two packages in the same window; one cohort
  release with one version set is what the keiro-ui initiative pins against, and publishing is
  irreversible and requires the user's explicit confirmation.
  Date: 2026-09-30

- Decision: No new ADR is planned. The distillation pass at the end decides whether the
  conformance mapping needs a record beyond the user guide.
  Rationale: ADR-9 §1 names `docs/user/metrics.md` as the normative inventory of the published
  surface and fixes the rule for how it may grow; a conformance table is an application of that
  rule, and the drop counter is a library detail rather than a boundary decision.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Terms used in this plan

A **WebSocket** is a long-lived two-way connection that starts as an HTTP request carrying
`Upgrade: websocket` and then exchanges **frames** in both directions on the same socket. In
`kiroku-metrics` every frame is a JSON object with a required `type` key naming the frame kind.
A **client frame** goes from the browser to the server; a **server frame** goes the other way.
An **event tail** is a server-side loop that forwards every newly appended event to one
connection. The **global position** is the monotonically increasing sequence number of an event
in the store-wide `$all` log; **replay** means paging history from a chosen global position before
switching to live delivery. A **fan-in read** is any read that returns events from many streams;
such events carry only the surrogate integer `originalStreamId`, never a stream name (ADR-1).
The **publisher** (`EventPublisher`) is the one thread per `KirokuStore` that reads newly
appended events and pushes them, as batches (`Vector RecordedEvent`), into one bounded STM queue
per registered subscriber; the WebSocket tail is one such subscriber. **Drop-oldest** is the
overflow policy the tail uses: when a subscriber's queue is full the publisher discards the oldest
queued batch to make room for the newest. A **WAI `Application`** is the standard Haskell value a
web server such as Warp runs; `kiroku-metrics` composes its HTTP router and its WebSocket handler
into one with `websocketsOr`. **PVP** is the Haskell Package Versioning Policy: a change to an
exported datatype's definition is a major bump; an addition is a minor bump.

### The WebSocket surface as it exists

Everything below is under `kiroku-metrics/`, version 0.1.0.10 in `kiroku-metrics.cabal`. The
package's `common` stanza enables `DuplicateRecordFields`, `OverloadedRecordDot`,
`OverloadedStrings`, `RecordWildCards`, `LambdaCase`, `DerivingStrategies`, and `DeriveAnyClass`,
and builds with `-Wall -Werror=incomplete-patterns`. The library depends on `aeson`, `async`,
`base`, `bytestring`, `containers`, `hasql`, `hasql-pool`, `http-types`, `kiroku-cli`,
`kiroku-store`, `stm`, `text`, `time`, `uuid`, `vector`, `wai`, `wai-websockets`, `warp`, and
`websockets`; nothing this plan needs is missing.

`src/Kiroku/Metrics/WebSocket.hs` owns the protocol and the handlers. Its export list is
`ClientMessage (..)`, `ServerMessage (..)`, `recordedEventToJSON`, `WebSocketState (..)`,
`newWebSocketState`, and `websocketApp`. The protocol types are:

```haskell
data ClientMessage
    = Ping
    | SubscribeMetrics
    | SubscribeEvents !(Maybe Int64) !(Maybe Text)   -- from_position, category
    | UnsubscribeEvents
    deriving stock (Eq, Show)

data ServerMessage
    = Pong
    | Snapshot !MetricsSnapshot
    | Event !Value
    | EventStreamStarted !Int64
    | Goodbye
    | ErrorMsg !Text
    deriving stock (Eq, Show)
```

`FromJSON ClientMessage` dispatches on the `type` string (`ping`, `subscribe_metrics`,
`subscribe_events` with optional `from_position` and `category`, `unsubscribe_events`) and
`fail`s on any other type; `recvMsg` turns a failed decode into `Nothing`, and both receive
loops ignore `Nothing`, which is how the server ignores unknown client frames. `ToJSON
ServerMessage` produces `{"type":"pong"}`, `{"type":"snapshot","metrics":…}`,
`{"type":"event","event":…}`, `{"type":"event_stream_started","from_position":N}`,
`{"type":"goodbye"}`, and `{"type":"error","message":"…"}`.

`recordedEventToJSON :: RecordedEvent -> Value` builds the event object with eleven camelCase
keys: `eventId`, `eventType`, `streamVersion`, `globalPosition`, `originalStreamId` (an integer
surrogate), `originalVersion`, `payload`, `metadata`, `causationId`, `correlationId`,
`createdAt`. That casing is frozen by ADR-9; a key added later must be snake_case.

`websocketApp cfg m store st` dispatches on `WS.requestPath (WS.pendingRequest pending)` through
`dispatchPath`, which strips a query string and matches exactly `/ws/metrics` or `/ws/events`,
rejecting anything else; it also enforces the `wsMaxConnections` bound through `WebSocketState`.

`handleMetrics cfg m pending` accepts the connection, wraps the body in
`WS.withPingThread conn 30 (pure ())` (a WebSocket-level ping every 30 seconds), sends one
`Snapshot`, starts `metricsPushLoop` in an `async` (linked with `link` so a crash propagates),
and runs `metricsReceiveLoop`, which answers `Ping` with `Pong` and `SubscribeMetrics` with a
fresh `Snapshot`. `finally` cancels the push thread and sends `Goodbye`. There is no way to stop
the periodic push short of disconnecting.

`handleEvents cfg store pending` accepts, wraps in the same ping thread, and keeps a
`TVar (Maybe (Async ()))` for the current tail: `SubscribeEvents from cat` stops any running tail
and starts `eventTail`, `UnsubscribeEvents` stops it, `Ping` answers `Pong`; `finally` stops the
tail and sends `Goodbye`. `eventTail` has three shapes. With a category it sends
`EventStreamStarted start` and runs `categoryLoop`, a database-driven loop over `readCategory`
gated on the publisher position (no broadcast queue is involved, so it can never overflow). Without
a category it subscribes to the publisher with
`subscribePublisher store.publisher cfg.wsEventQueueCap DropOldest`, reads the attach position,
sends `EventStreamStarted`, optionally replays history with `replayHistory` (paging
`readAllForward` up to the attach position and returning the highest covered position, or
`Nothing` after sending `ErrorMsg "replay error: …"`), and then runs `broadcastLoop conn queue
statusVar keep`, which forever reads a batch from the queue, sends the kept events, and, if the
status `TVar` reads `Overflowed`, sends `ErrorMsg "event stream overflowed; some events dropped"`.
`sendEvents` maps `recordedEventToJSON` over a batch and sends one `Event` frame per event.
`categoryLoop` sends `ErrorMsg "category read error: …"` and stops on a read failure.

The three `ErrorMsg` sites and their intended codes under this plan are therefore: replay failure
(`replay_failed`), category read failure (`category_read_failed`), and overflow
(`event_stream_overflowed`).

### Why the overflow frame never fires today

`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` exports `EventPublisher (..)`,
`Subscriber (..)`, `SubscriberStatus (..)`, `startPublisher`, `stopPublisher`,
`subscribePublisher`, and `publisherPosition`. The registered subscriber is:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue (Vector RecordedEvent))
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    }

data SubscriberStatus = Active | Paused | Overflowed
```

and `subscribePublisher :: EventPublisher -> Natural -> OverflowPolicy -> STM (TBQueue (Vector
RecordedEvent), TVar SubscriberStatus, IO ())` creates one, registers it in
`subscribers :: TVar (IntMap Subscriber)` under a fresh id, and returns the queue, the status
variable, and an `unsubscribe` action. The publisher loop delivers each batch to every
subscriber through `deliverBatchSTM`:

```haskell
    deliverBatchSTM events sub = do
        full <- isFullTBQueue (subQueue sub)
        if not full
            then do
                status <- readTVar (subStatus sub)
                case status of
                    Paused -> writeTVar (subStatus sub) Active
                    Active -> pure ()
                    Overflowed -> pure ()
                writeTBQueue (subQueue sub) events
            else case subPolicy sub of
                PauseAndResume -> writeTVar (subStatus sub) Paused
                DropSubscription -> writeTVar (subStatus sub) Overflowed
                DropOldest -> do
                    _ <- tryReadTBQueue (subQueue sub)
                    writeTBQueue (subQueue sub) events
```

`Overflowed` is written only under `DropSubscription`. The WebSocket subscribes with
`DropOldest`, so its status never leaves `Active`, and the `broadcastLoop` check can never fire.
The other caller of `subscribePublisher` is the subscription worker
(`kiroku-store/src/Kiroku/Store/Subscription.hs`, around line 138), which uses the policy the
subscription configured; it must keep working unchanged, which is why `subscribePublisher` stays
as a wrapper.

The publisher loop is a measured path under
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md): MasterPlan 12 assigns
`cabal bench kiroku-store:kiroku-shibuya-overhead` to plans that touch it, and its
bare-subscribe layer is exactly the publisher-fed `$all` path. This plan touches only the
already-full branch, but it runs the benchmark before and after so the claim is evidence, not
assertion.

### The library reads the tail will use

`kiroku-store/src/Kiroku/Store/Read.hs` exports
`lookupStreamNames :: (HasCallStack, Store :> es) => [StreamId] -> Eff es (Map StreamId StreamName)`,
which resolves a batch of surrogate ids in one round trip and short-circuits an empty list without
touching the database. `StreamId` is a newtype over `Int64`, `StreamName` over `Text`, both in
`kiroku-store/src/Kiroku/Store/Types.hs`, both with `Ord` instances (so they key a `Map`). The
WebSocket module already runs effect programs with `runStoreIO store (…)`, which returns
`IO (Either StoreError a)`.

### Tests and how they boot a server

`kiroku-metrics/test/Main.hs` wraps `hspec` in `withSharedMigratedPostgres` and lists
`CollectorSpec`, `IntegrationSpec`, `ServerSpec`, `WebSocketSpec`, and `SubscriptionsSpec`; the
cabal `test-suite` stanza lists the same modules under `other-modules` and depends on `aeson`,
`async`, `containers`, `generic-lens`, `hasql`, `hasql-pool`, `hspec`, `http-client`,
`http-types`, `kiroku-cli`, `kiroku-metrics`, `kiroku-store`, `kiroku-test-support`, `lens`,
`scientific`, `stm`, `text`, `uuid`, `warp`, and `websockets`.

`kiroku-metrics/test/Test/WebSocketSpec.hs` is the pattern to copy. Each example runs inside
`withMigratedTestDatabase $ \connStr -> …`, builds the collector with
`newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)` over a
`TVar (Maybe KirokuStore)`, opens the store with the metrics handlers installed on
`defaultConnectionSettings connStr` (`& #eventHandler .~ Just (metricsEventHandler km Nothing)`),
starts `startMetricsServerWithStore (defaultConfig{port = 0}) km store []`, sleeps
`threadDelay 300_000`, and drives the socket with `WS.runClient "127.0.0.1" port "/ws/events"`
inside `timeout 15_000_000`. Its private helpers, which the new spec copies rather than imports,
are `sendJSON`, `recvValue`, `waitForType conn "event"`, `readEventType`, `readEventPosition`,
`look`, `globalPositionOf`, `readPosition`, `readSubscribers`, `waitForSubscriberCount`,
`waitForPublisherPosition`, `appendStoreEvents store stream n` (appends `n` events of type
`E1`..`En` with `NoStream`), and `requireJust`. Its fourth example shows how to force a replay
failure deterministically: `Pool.use store.pool (Session.script "ALTER TABLE events RENAME TO
events_hidden")` before the client subscribes with `from_position`.

The store suite lives in `kiroku-store/test/`; `Test/Helpers.hs` exports `withTestStore` (a
bracket that opens a `KirokuStore` on a fresh migrated database), `makeEvent`, `waitForPublisher`,
and `waitWithTimeout`; `kiroku-store/test/Main.hs` and the `kiroku-store-test` stanza register
each spec module. `Test/PublisherIdleAdvance.hs` and `Test/PublisherRestartNoRebroadcast.hs` are
existing publisher-level specs.

### Documentation and knowledge bundles touched

`docs/user/metrics.md` is the package user guide. Its "The WebSocket protocol" section has the
two-path description, "Client → server" and "Server → client" tables, "The `RecordedEvent` wire
shape" table, "Semantics", and a `websocat` transcript; "Wire-format stability" cites ADR-9. This
plan edits only the WebSocket section and the "See Also" list.

`docs/capabilities/operational-http-endpoints.md` is capability `CAP-17` in the profile-governed
`capabilities` OKF bundle (validated by `just capabilities-validate`); its `description`,
`evidence`, and body must mention the converged protocol, and `docs/capabilities/log.md` receives
a dated `**Update**` entry. Do not change `generated.at`, `since`, or `capabilityId`.

`docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md`
is IR-12 in the `improvement-requests` OKF bundle governed by
`mori/improvement-requests-profile.dhall`. MasterPlan 13 moved it to `accepted` with its Status
section citing this plan. Every status change advances `timestamp`, adds a dated entry to
`docs/improvement-requests/log.md`, and passes the strict validation in Concrete Steps (the
validator prints "missing profile-recommended field: reviews" lines for machine-authored
requests; those are advisory and pre-existing).

### Coordinating with the sibling plans of MasterPlan 13

Plan 88 (`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`,
EP-3) owns the enriched event encoder `recordedEventToJSONResolved :: Map StreamId StreamName ->
RecordedEvent -> Value` in `Kiroku.Metrics.WebSocket`, which is `recordedEventToJSON` plus the
key `original_stream_name` (the resolved name as a JSON string, or `null`). Before Milestone 2,
run:

```bash
grep -n "recordedEventToJSONResolved" kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs
```

If it prints a definition, plan 88 has landed: import nothing new, use the function, and do not
redefine it. If it prints nothing, define it in this plan exactly as specified in Milestone 2,
export it, and add a one-line note to plan 88's Revision Notes saying the encoder now exists and
plan 88 must reuse it. Record which branch applied in Surprises & Discoveries. No other sibling
plan touches `WebSocket.hs` or `EventPublisher.hs`; plan 90 (CORS) wraps the composed application
in `Server.hs` and is unaffected by frame changes; plans 87 and 89 add HTTP routes only.

The two changelogs are shared. `kiroku-metrics/CHANGELOG.md` has (or will have, from whichever
sibling lands first) a `## Unreleased` section; add this plan's bullets there under
`### New Features`. `kiroku-store/CHANGELOG.md` has, from plans 88 or 89, an unreleased heading;
add this plan's bullets there under `### Breaking Changes` (the `Subscriber` field) and
`### New Features` (`subscribePublisherWith`); if neither sibling has landed, create the
`## Unreleased` heading yourself. Plan 96 dates and numbers both.

### Relevant architecture decisions

Local ADRs read for this plan (the others were scanned by heading and are not relevant):

- [ADR-9, Published HTTP and WebSocket wire shapes are frozen and served only by sister packages](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`): the paths, the client and server frame
  inventories, the event object's eleven camelCase keys, and the documented delivery semantics
  (including the in-band overflow error) are published; a field is never removed or re-typed; a
  new optional field, a new frame type, and a new documented behaviour are additive; new keys are
  snake_case even on the camelCase event object; `error` message text is not a contract; servers
  ignore unknown client frames and clients must ignore unknown server frames and fields; a change
  to a published encoder updates the user guide in the same change and a new surface ships with a
  test that pins its key set. Every change in this plan is one of the additive kinds, and
  Milestone 2's spec pins the key sets.
- [ADR-1, Resolve stream names via lookup, not a RecordedEvent field](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md):
  `RecordedEvent` carries only `originalStreamId` because a name on every `$all` row cost about
  13%; `lookupStreamNames` is the intended batch resolution. The tail resolves names that way,
  cached per connection.
- [ADR-5, Three-tier performance regression gates](../adr/0005-three-tier-performance-regression-gates.md):
  structural checks and controlled workloads are authoritative. The publisher change is off the
  not-full delivery path; the overhead benchmark is run before and after as evidence.

Cross-repository decisions, cited by the canonical handles the keiro-ui bundle publishes:

- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`: the WebSocket convention is the structural
  superset both shipped dialects fit; shipped dialects are frozen and converge only additively.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`: push is a hint, poll is truth; a client that
  misses frames recovers by re-reading, which is what the overflow code tells it to do.
- The conventions document, `mori://shinzui/keiro-ui`,
  `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending; on this machine
  `/Users/shinzui/Keikaku/bokuno/keiro-ui/docs/architecture/inspection-api-conventions.md`).
  Area 5 lists the ten elements the conformance mapping must cover: typed `type`-tagged frames;
  explicit subscribe and unsubscribe; `ping`/`pong`; `from_position` replay cursors where the
  domain has them; an initial `snapshot` after subscribe; incremental `update` or `event` frames;
  servers ping idle connections (30-second precedent); in-band `error` frames including overflow;
  `goodbye` before server-initiated close; bounded drop-oldest queues with overflow signalled
  in-band.
- `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`: keiro will mount this package's
  WAI application behind a path prefix, so nothing here may assume an absolute mount path.

`mori path` may report the keiro-ui handles as not found because registry observation lags fresh
commits (plans 69, 87, and 90 recorded the same); per repository policy the canonical URIs are
retained.

### The audit, settled

Against the ten convention elements, the shipped surface stands as follows; the conformance table
in Milestone 3 restates this for users.

Typed `type`-tagged frames: met on both paths. Explicit subscribe/unsubscribe: met on
`/ws/events` (`subscribe_events`/`unsubscribe_events`); a documented deviation on `/ws/metrics`
(push on connect, `subscribe_metrics` only requests a snapshot), additively closed by
`unsubscribe_metrics` and the restart semantics of `subscribe_metrics`. `ping`/`pong`: met on
both paths. Replay cursors: met (`from_position`). Initial `snapshot` after subscribe: met on
`/ws/metrics` (the connect snapshot, and one per `subscribe_metrics`); a documented deviation on
`/ws/events`, where `event_stream_started` plays the role. Incremental frames: met (`snapshot`
pushes on the metrics path, `event` on the events path). Server idle pings: met on both paths
(30 seconds, `withPingThread`); IR-12's suspicion to the contrary is corrected. In-band `error`
frames: met in shape, but the overflow instance is unreachable; additively closed by the drop
counter and the `event_stream_overflowed` code. `goodbye` before server-initiated close: met on
both paths. Bounded drop-oldest queues: met (`wsEventQueueCap`, `DropOldest`).


## Plan of Work

### Milestone 1: count dropped batches in the publisher

Scope: make the overflow signal observable at the library level. At the end, `kiroku-store`
exposes a per-subscriber dropped-batch counter through an additive subscription function, the
existing function and the subscription worker are unchanged in behaviour, a deterministic store
test proves the counter, and the overhead benchmark shows the not-full path did not move. Nothing
in `kiroku-metrics` changes yet.

First move IR-12 from `accepted` to `in_progress`: in
`docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md`
set `status: in_progress`, advance `timestamp` to the current UTC time, and under `## Status`
change the acceptance paragraph (which links this plan) to say implementation is under way. Add a
dated `**Implementation**` entry to `docs/improvement-requests/log.md` and run the strict bundle
validation from Concrete Steps.

In `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`:

Add `Data.Word (Word64)` to the imports and a fourth field to `Subscriber`, with Haddock:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue (Vector RecordedEvent))
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    , subDropped :: !(TVar Word64)
    -- ^ Batches discarded from 'subQueue' under 'DropOldest' because the queue
    -- was full. Never reset; a consumer compares successive reads. Stays zero
    -- under the other policies.
    }
```

Define the record a caller receives and the new subscription function, keeping the old one as a
wrapper so `Kiroku.Store.Subscription` and any external caller compile and behave as before:

```haskell
-- | What 'subscribePublisherWith' hands back: the bounded queue the publisher
-- fills, the status the publisher writes, the dropped-batch counter it
-- increments under 'DropOldest', and the action that deregisters the
-- subscriber (idempotent).
data PublisherSubscription = PublisherSubscription
    { subscriptionQueue :: !(TBQueue (Vector RecordedEvent))
    , subscriptionStatus :: !(TVar SubscriberStatus)
    , subscriptionDropped :: !(TVar Word64)
    , unsubscribe :: !(IO ())
    }

subscribePublisherWith ::
    EventPublisher ->
    -- | Queue capacity (number of batches)
    Natural ->
    OverflowPolicy ->
    STM PublisherSubscription

-- | The original interface: the queue, the status, and the unsubscribe action.
-- Equivalent to 'subscribePublisherWith' with the counter discarded.
subscribePublisher ::
    EventPublisher -> Natural -> OverflowPolicy ->
    STM (TBQueue (Vector RecordedEvent), TVar SubscriberStatus, IO ())
subscribePublisher pub cap policy = do
    s <- subscribePublisherWith pub cap policy
    pure (subscriptionQueue s, subscriptionStatus s, unsubscribe s)
```

Move the body of today's `subscribePublisher` into `subscribePublisherWith`, adding
`dropped <- newTVar 0` and `subDropped = dropped` to the `Subscriber` it builds, and returning
the record. Export `PublisherSubscription (..)` and `subscribePublisherWith` from the module
(after `subscribePublisher` in the export list). In `deliverBatchSTM`, change only the
`DropOldest` branch:

```haskell
                DropOldest -> do
                    _ <- tryReadTBQueue (subQueue sub)
                    modifyTVar' (subDropped sub) (+ 1)
                    writeTBQueue (subQueue sub) events
```

The `not full` branch, `PauseAndResume`, and `DropSubscription` are not touched. Update the
module header's description of overflow handling (it currently says `DropOldest` "drops the
oldest batch"; add "and counts the drop in `subDropped`") and the `Subscriber` Haddock. Check
whether `Kiroku.Store` or `Kiroku.Store.Subscription` re-export `subscribePublisher` (at planning
time `Kiroku.Store.Subscription` imports it qualified as `Pub.subscribePublisher` and does not
re-export it, so nothing else changes); if a re-export exists, add the new names beside it.

Search the repository for any other construction of `Subscriber` or exhaustive pattern on it
(`grep -rn "Subscriber{" --include='*.hs' kiroku-store kiroku-metrics shibuya-kiroku-adapter
kiroku-otel kiroku-cli`); the constructor is built only inside `subscribePublisherWith`, and the
`-Wall -Werror=incomplete-patterns` build will report any exhaustive record pattern elsewhere.

**Store test.** Create `kiroku-store/test/Test/PublisherDropCounter.hs` with
`spec :: Spec`, `describe "publisher drop counter"`, using `withTestStore` from `Test.Helpers`.
One example with three assertions:

1. Subscribe with `atomically (subscribePublisherWith store.publisher 1 DropOldest)` (capacity
   one batch) and never read the queue. Append one event to stream `drop-a` and wait for the
   publisher position to reach 1 (`waitForPublisher` or an STM wait on `publisherPosition`), then
   append one event to stream `drop-b` and wait for position 2. Each append wakes the publisher
   through the notifier, so the two events arrive as two separate batches, and the second
   delivery finds the queue full. Wait (STM, with a `registerDelay` timeout of five seconds) until
   `readTVar (subscriptionDropped s)` is `1`; assert it, and assert `readTVar (subscriptionStatus s)`
   is still `Active`.
2. Drain the queue with `tryReadTBQueue`: exactly one batch is present and its single event's
   `globalPosition` is `GlobalPosition 2` (the newest batch survived; the oldest was dropped).
3. Subscribe a second subscriber with `subscribePublisher store.publisher 1 DropOldest` (the
   wrapper), repeat the two appends on fresh streams, and assert the wrapper's queue behaves as
   before (one batch present after the second append) so the compatibility path is exercised;
   then call both `unsubscribe` actions twice and assert `IntMap.size <$> readTVar (subscribers
   store.publisher)` returns to its starting value (idempotent deregistration, unchanged).

If the two events ever arrive in one batch (the publisher woke once for both), the test would see
a count of zero; avoid that by waiting for the publisher position between appends as described,
and if it still happens record the observation in Surprises & Discoveries and add a
`threadDelay 100_000` between the appends. Register the module in `kiroku-store/test/Main.hs`
and in the `other-modules` of the `kiroku-store-test` stanza in `kiroku-store/kiroku-store.cabal`.

**Changelog.** Under the unreleased heading of `kiroku-store/CHANGELOG.md` (create
`## Unreleased` if no sibling plan has), add under `### Breaking Changes`: "`Subscriber` gains a
`subDropped :: TVar Word64` field counting batches discarded under `DropOldest`; code that
constructs or exhaustively matches the record must add it." Under `### New Features`:
"`subscribePublisherWith` returns a `PublisherSubscription` record exposing the dropped-batch
counter; `subscribePublisher` is unchanged and remains the triple-returning form."

**Benchmark evidence.** Before editing, run
`cabal bench kiroku-store:kiroku-shibuya-overhead` and keep the output; after the edit run it
again and paste both bare-subscribe rows into Surprises & Discoveries. The not-full path is
untouched, so the rows should agree within noise; a movement beyond noise means the edit landed on
the wrong branch and must be revisited before Milestone 2.

Acceptance for Milestone 1: `cabal build all` is warning-free (the store, the metrics package,
and the adapter all compile against the widened record),
`cabal test kiroku-store-test --test-options='--match "publisher drop counter"'` passes, the
whole store suite is green, and the two benchmark transcripts are recorded.

### Milestone 2: the additive protocol changes in `kiroku-metrics`

Scope: implement the three additive changes in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`
and prove them with a new spec while the existing spec stays untouched. At the end, a server
started by `startMetricsServerWithStore` honours `unsubscribe_metrics`, sends coded errors, sends
the overflow error when batches were dropped, and labels every tailed event with its stream name.

**Protocol types.** Add one constructor to each protocol type:

```haskell
data ClientMessage
    = Ping
    | SubscribeMetrics
    | SubscribeEvents !(Maybe Int64) !(Maybe Text)
    | UnsubscribeEvents
    | -- | (Metrics channel) stop the periodic snapshot push; @subscribe_metrics@ restarts it.
      UnsubscribeMetrics
    deriving stock (Eq, Show)

data ServerMessage
    = ...
    | ErrorMsg !Text
    | -- | A non-fatal error with a stable machine-readable @code@ beside the @message@.
      CodedError !Text !Text
    deriving stock (Eq, Show)
```

Extend `FromJSON ClientMessage` with `"unsubscribe_metrics" -> pure UnsubscribeMetrics` and
`ToJSON ServerMessage` with:

```haskell
    toJSON (CodedError code msg) =
        object ["type" .= ("error" :: Text), "code" .= code, "message" .= msg]
```

Every other `toJSON` equation is untouched. Define the three codes as named constants next to
the instance so the tests and the guide use one spelling:

```haskell
-- | @code@ values carried by 'CodedError' frames. Published once shipped (ADR-9).
errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed :: Text
errorCodeReplayFailed = "replay_failed"
errorCodeCategoryReadFailed = "category_read_failed"
errorCodeEventStreamOverflowed = "event_stream_overflowed"
```

Export the three constants. Switch the three error sites: `replayHistory` sends
`CodedError errorCodeReplayFailed (T.pack ("replay error: " <> show err))`; `categoryLoop` sends
`CodedError errorCodeCategoryReadFailed (T.pack ("category read error: " <> show err))`; the
overflow site is rewritten below. Keep the message texts unchanged so the existing spec's
`T.isInfixOf "replay error"` assertion holds.

**Metrics channel lifecycle.** Rewrite `handleMetrics` so the push loop is tracked like the
events tail:

```haskell
handleMetrics cfg m pending = do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (pure ()) $ do
        sendMsg conn . Snapshot =<< snapshotMetrics m
        pushVar <- newTVarIO Nothing
        let stopPush = do
                mt <- atomically (readTVar pushVar)
                for_ mt cancel
                atomically (writeTVar pushVar Nothing)
            startPush = do
                running <- atomically (readTVar pushVar)
                case running of
                    Just _ -> pure ()
                    Nothing -> do
                        t <- async (metricsPushLoop cfg m conn)
                        link t
                        atomically (writeTVar pushVar (Just t))
        startPush
        finally
            ( forever $ do
                cmd <- recvMsg conn
                case cmd of
                    Just Ping -> sendMsg conn Pong
                    Just SubscribeMetrics -> do
                        sendMsg conn . Snapshot =<< snapshotMetrics m
                        startPush
                    Just UnsubscribeMetrics -> stopPush
                    _ -> pure ()
            )
            (stopPush >> sendMsg conn Goodbye)
```

`metricsPushLoop` is unchanged. `metricsReceiveLoop` is folded into the handler above (delete it
if nothing else uses it). The observable behaviour for an existing client is identical: a
snapshot on connect, one every `wsPushIntervalUs`, `pong` for `ping`, a snapshot for
`subscribe_metrics`. The only new behaviour is that `unsubscribe_metrics` silences the periodic
push and a later `subscribe_metrics` resumes it. Because `link` is applied to each started push
thread, a push-loop crash still propagates as before.

**Resolved event encoder and the name cache.** If the coordination check in Context and
Orientation found no `recordedEventToJSONResolved`, define and export it beside
`recordedEventToJSON`:

```haskell
{- | 'recordedEventToJSON' plus one additional snake_case key,
@original_stream_name@: the source stream's name resolved from the map (a JSON
string), or @null@ when the map has no entry. The camelCase keys are the frozen
published shape; the new key is optional and clients must tolerate its absence.
Shared by the REST browse pages and the WebSocket event tail.
-}
recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value
recordedEventToJSONResolved names e =
    case recordedEventToJSON e of
        Object o -> Object (KM.insert "original_stream_name" name o)
        other -> other
  where
    name = maybe Null (\(StreamName n) -> String n) (Map.lookup e.originalStreamId names)
```

with `Data.Aeson.KeyMap qualified as KM`, `Data.Map.Strict (Map)` and `qualified as Map`, and
`StreamName (..)` imported. Then give the tail a cache. Change `sendEvents` to take the resolver
state and to resolve before sending:

```haskell
-- | Per-connection cache of resolved stream names for the event tail.
type NameCache = TVar (Map StreamId StreamName)

{- | Resolve the source stream names of a batch through the public batch lookup,
consulting and extending the per-connection cache so an id costs one round trip
the first time it is seen on this connection and none afterwards. A lookup
failure leaves the cache unchanged and the batch is sent with @null@ names
rather than dropped; the store remains the source of truth (a client that needs
the name can fetch the stream page).
-}
resolveNames :: KirokuStore -> NameCache -> Vector RecordedEvent -> IO (Map StreamId StreamName)
resolveNames store cacheVar evs = do
    cached <- readTVarIO cacheVar
    let wanted = filter (`Map.notMember` cached) (nub (map (.originalStreamId) (V.toList evs)))
    if null wanted
        then pure cached
        else do
            res <- runStoreIO store (lookupStreamNames wanted)
            case res of
                Left _ -> pure cached
                Right found -> do
                    let merged = Map.union cached found
                    atomically (writeTVar cacheVar merged)
                    pure merged

sendEvents :: KirokuStore -> NameCache -> WS.Connection -> Vector RecordedEvent -> IO ()
sendEvents store cacheVar conn evs
    | V.null evs = pure ()
    | otherwise = do
        names <- resolveNames store cacheVar evs
        V.mapM_ (sendMsg conn . Event . recordedEventToJSONResolved names) evs
```

`nub` comes from `Data.List`; a batch has at most a few hundred events and typically a handful of
distinct ids, so the quadratic `nub` is fine (or use `Map.keys . Map.fromList` with unit values).
Allocate the cache once per tail, in `eventTail`
(`cacheVar <- newTVarIO Map.empty` at the top), and thread `store cacheVar` through
`replayHistory`, `broadcastLoop`, `categoryLoop`, and their `sendEvents` calls. The cache is
per-connection so a hard-deleted stream that is later re-created with the same name under a new
id is never confused: ids, not names, are the keys. `lookupStreamNames` is called with the
already-filtered id list; on an empty list it returns without a round trip, and `resolveNames`
skips the call entirely.

**Overflow detection.** Subscribe with the counter and check it after every batch:

```haskell
{- | Compare the dropped-batch counter with the value seen at the previous
check; when it grew, the frame to send. Exported so the decision is unit-testable
without forcing a real overflow.
-}
overflowNotice :: Word64 -> Word64 -> Maybe ServerMessage
overflowNotice previous current
    | current > previous =
        Just $
            CodedError
                errorCodeEventStreamOverflowed
                ( "event stream overflowed; "
                    <> T.pack (show (current - previous))
                    <> " undelivered batch(es) dropped since the last notice; re-read from your last position"
                )
    | otherwise = Nothing
```

In `eventTail`'s no-category branch replace the `subscribePublisher` call with
`subscribePublisherWith store.publisher cfg.wsEventQueueCap DropOldest` and use the record's
fields (`subscriptionQueue`, `subscriptionStatus`, `subscriptionDropped`, `unsubscribe`). Give
`broadcastLoop` the counter and a `seen` accumulator:

```haskell
broadcastLoop store cacheVar conn queue statusVar droppedVar keep = go 0
  where
    go seen = do
        batch <- atomically (readTBQueue queue)
        sendEvents store cacheVar conn (V.filter keep batch)
        status <- atomically (readTVar statusVar)
        case status of
            Overflowed -> sendMsg conn (CodedError errorCodeEventStreamOverflowed "event stream overflowed; some events dropped")
            _ -> pure ()
        dropped <- readTVarIO droppedVar
        for_ (overflowNotice seen dropped) (sendMsg conn)
        go dropped
```

The `Overflowed` arm is kept as the defensive path the module always had, now coded. Because the
notice is sent after the batch that follows the drop, the client learns of the loss no later than
the next delivered batch, which is the earliest moment it could act on it; an idle connection with
nothing to deliver after the drop learns of it on the next batch, and the message states the count
so a client can size its re-read. Update the module header (the drop-oldest sentence now says the
tail is told in-band through the counter) and the Haddocks of `eventTail`, `broadcastLoop`, and
`sendEvents`. Export `overflowNotice`, `NameCache` is internal.

**Changelog.** In `kiroku-metrics/CHANGELOG.md` under `## Unreleased`, `### New Features`: the
`unsubscribe_metrics` client frame and the resume semantics of `subscribe_metrics`; the `code`
field on `error` frames with the three codes; the `original_stream_name` key on `event` frames;
and the now-delivered overflow notice (name the previous unreachability plainly, so a reader
understands why a client may start seeing a frame it never saw before). If this plan introduced
`recordedEventToJSONResolved`, list it as a new export.

**Tests.** Create `kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs`, register it in
`kiroku-metrics/test/Main.hs` (import and call `WebSocketConvergenceSpec.spec`) and in the
test-suite `other-modules`. Copy the private helpers from `WebSocketSpec.hs` (`sendJSON`,
`recvValue`, `waitForType`, `readEventType`, `look`, `readPosition`, `readSubscribers`,
`waitForPublisherPosition`, `appendStoreEvents`, `requireJust`) and add `readEventField conn key`
that reads until an `event` frame and returns `look ["event", key]`. Write:

Under `describe "Kiroku.Metrics.WebSocket (frames)"`, database-free:

1. Pre-existing server frames are byte-identical: assert `toJSON` of `Pong`, `Goodbye`,
   `EventStreamStarted 7`, `ErrorMsg "x"`, and `Event (object ["k" .= (1 :: Int)])` equals the
   literal `object`s `{"type":"pong"}`, `{"type":"goodbye"}`,
   `{"type":"event_stream_started","from_position":7}`, `{"type":"error","message":"x"}`, and
   `{"type":"event","event":{"k":1}}` (for `Snapshot`, assert `look ["type"]` is `"snapshot"`
   and `look ["metrics"]` is present, using a snapshot taken from a fresh `newKirokuMetrics`).
2. `toJSON (CodedError "replay_failed" "boom")` equals
   `{"type":"error","code":"replay_failed","message":"boom"}`, and the three constants spell
   `replay_failed`, `category_read_failed`, `event_stream_overflowed`.
3. `eitherDecode "{\"type\":\"unsubscribe_metrics\"}"` is `Right UnsubscribeMetrics`, and every
   previously accepted client frame still decodes to its constructor.
4. `recordedEventToJSONResolved` adds exactly one key: build a `RecordedEvent` by hand
   (`originalStreamId = StreamId 9`), assert the resolved object's key set is the eleven
   camelCase keys plus `original_stream_name`, that the value is `"orders-7"` when the map has
   `StreamId 9 ↦ StreamName "orders-7"`, and `Null` when the map is empty; assert that removing
   the key yields exactly `recordedEventToJSON` of the same event.
5. `overflowNotice 0 0` and `overflowNotice 3 3` are `Nothing`; `overflowNotice 0 2` is
   `Just (CodedError "event_stream_overflowed" msg)` with `"2"` in `msg`; `overflowNotice 2 5`
   mentions `"3"`.

Under `describe "Kiroku.Metrics.WebSocket (convergence, real server)"`, each booting a server as
`WebSocketSpec` does but with `serverCfg = defaultConfig{port = 0, wsPushIntervalUs = 200_000}`:

6. Unsubscribe stops the push and subscribe resumes it: connect to `/ws/metrics`, receive the
   connect `snapshot`, then receive one more (proves periodic push), send
   `{"type":"unsubscribe_metrics"}`, drain any frame that arrives within 300 ms (a push may be
   in flight), then assert `timeout 700_000 (WS.receiveData conn)` is `Nothing` (no snapshot in
   more than three intervals); send `{"type":"subscribe_metrics"}` and assert a `snapshot`
   arrives within one second and a second one within 700 ms (periodic push resumed); send
   `{"type":"ping"}` and assert `pong`.
7. `original_stream_name` on the live path: subscribe to `/ws/events` with no options, append
   two events to `conv-live-1` and one to `conv-live-2`, and assert the three `event` frames
   carry `original_stream_name` `"conv-live-1"`, `"conv-live-1"`, `"conv-live-2"` in that order.
8. `original_stream_name` on the replay and category paths: append two events to `conv-cat-1`
   before connecting; subscribe with `from_position` 0 and assert both replayed frames name
   `conv-cat-1`; then, on a new connection, subscribe with `category` `"conv-cat"`, append one
   event to `conv-cat-2`, and assert the frame names `conv-cat-2`.
9. `replay_failed` end to end: repeat the fourth `WebSocketSpec` example (rename `events`
   before subscribing with `from_position`) and assert the `error` frame's `code` is
   `replay_failed` and its `message` still contains `replay error`.
10. `category_read_failed` end to end: subscribe with a category, then rename the `events`
    table, append one event (the append fails, so instead trigger the read by appending
    before the rename to a stream in the category and renaming immediately after the publisher
    position advances; if the read has already drained, send `subscribe_events` again with the
    category to force a fresh `readCategory` from the cursor), and assert an `error` frame with
    `code` `category_read_failed` arrives; if this proves impossible to make deterministic,
    record why in Surprises & Discoveries and rely on the encoder test plus a direct assertion
    that the category branch constructs `CodedError errorCodeCategoryReadFailed` (a
    `grep`-level structural check is acceptable evidence for a code constant).
11. Existing frames still flow: after all of the above, `waitForSubscriberCount store 0` holds
    (tails deregister), proving the drop-counter subscription's `unsubscribe` is wired into the
    `finally` as before.

The overflow frame's end-to-end emission is not asserted on a real socket: forcing the
broadcast loop to fall behind the publisher depends on socket buffering and thread scheduling,
and a conditional assertion would be flaky. The deterministic proof is split across Milestone 1
(the counter increments exactly when a batch is dropped) and example 5 (the counter increase
produces the coded frame); Milestone 3's guide says so.

Acceptance for Milestone 2: `cabal test kiroku-metrics-test` passes in full, with
`kiroku-metrics/test/Test/WebSocketSpec.hs` unchanged (`git diff --stat -- kiroku-metrics/test/Test/WebSocketSpec.hs`
prints nothing), and `nix fmt` is a no-op.

### Milestone 3: documentation, capability, request evidence, and distillation

Scope: make the converged protocol discoverable and give the keiro-ui client core the mapping it
is built against. At the end, a reader of `docs/user/metrics.md` can see every new frame with
example JSON and every convention element with its kiroku realisation, and every repository
validation passes.

In `docs/user/metrics.md`, inside "The WebSocket protocol":

- In "Client → server", add the row
  `{"type":"unsubscribe_metrics"}` | metrics | Stop the periodic snapshot push; `subscribe_metrics` resumes it.
  and extend the `subscribe_metrics` row: "Request a fresh snapshot now, and resume the periodic
  push if it was stopped."
- In "Server → client", replace the `error` row with
  `{"type":"error","code":"…","message":"…"}` | A non-fatal error. `code` is a stable machine-readable value (table below); `message` is human text and may change.
  and add a short "Error codes" table: `replay_failed` (history replay hit a store error; the tail
  ended, resubscribe), `category_read_failed` (a category page read failed; the tail ended,
  resubscribe), `event_stream_overflowed` (this client fell behind and the oldest undelivered
  batches were dropped; re-read from your last position through the REST browse API or
  resubscribe with `from_position`). Note that frames produced before this version carried no
  `code`.
- In "The `RecordedEvent` wire shape", add the row `original_stream_name` | string or `null` |
  The source stream's name, resolved server-side from `originalStreamId`; `null` if the stream
  cannot be resolved. Keep the note that the camelCase keys are frozen and that this key, being
  new, is snake_case; say that the same object is served by the REST browse endpoints.
- In "Semantics", extend the `DropOldest` bullet: the server counts dropped batches per
  connection and sends `error` with `code` `event_stream_overflowed` after the next delivered
  batch; state that the signal is delivered from this version on (earlier versions documented it
  but never sent it), and that a category tail cannot overflow because it is read from the
  database rather than the broadcast.
- Add a subsection "Conformance with the cross-project WebSocket convention" with two
  sentences of framing (the keiro runtime UI initiative's convention, cited as
  `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level
  URI pending, and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`; kiroku's shipped dialect
  is frozen per ADR-9 and converges only additively) and one table with the columns
  Convention element | `/ws/metrics` | `/ws/events` | Status, covering: typed `type`-tagged
  frames (met, met); explicit subscribe/unsubscribe (`subscribe_metrics`/`unsubscribe_metrics`,
  additively closed, push-on-connect retained; `subscribe_events`/`unsubscribe_events`, met);
  `ping`/`pong` (met, met); replay cursor (not applicable; `from_position`, met); initial
  `snapshot` after subscribe (met, sent on connect and on `subscribe_metrics`; documented
  deviation, `event_stream_started` plays the role); incremental frames (`snapshot`, met;
  `event`, met); server idle pings (met, 30 s; met, 30 s); in-band `error` with overflow
  signalling (not applicable; met, `event_stream_overflowed`, additively closed); `goodbye`
  before server close (met, met); bounded drop-oldest queue (not applicable; met,
  `wsEventQueueCap`). Add a closing sentence that "additively closed" means an old client
  observes no change.
- Update the `websocat` transcript to show `original_stream_name` in the `event` line.
- In "See Also", add the conventions document and keiro-ui ADR-2 as cross-repository
  references.

Update `docs/capabilities/operational-http-endpoints.md` (CAP-17): extend `description` and the
body to say the WebSocket surface conforms to the cross-project inspection convention with an
explicit metrics-channel lifecycle, coded error frames, delivered overflow signalling, and
resolved stream names on tailed events; add an `evidence` entry for
`kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs` and one for
`kiroku-store/test/Test/PublisherDropCounter.hs`; add a dated `**Update**: CAP-17 …` entry to
`docs/capabilities/log.md`. Run `just capabilities-validate`.

Update IR-12's body (status stays `in_progress`): add an "Implementation Evidence" section
listing the audit outcome per element, the three additive changes with their frames, the
corrected idle-ping finding, the overflow finding and its fix, the test files, and the guide
section; advance `timestamp`; add a log entry; validate.

Finalize the `## Unreleased` changelog bullets. Then perform the distillation pass: reread the
Decision Log and Surprises & Discoveries and decide whether anything is durable project context
beyond what ADR-9 already records. The expected outcome is no new ADR, because ADR-9 §1 makes the
guide the normative inventory and the conformance table is an application of its rules; if the
implementer concludes that the "documented deviation" category or the drop counter's semantics
deserve a record, allocate one with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`,
write it, add the bundle log entry, and run `just adr-validate`. Record the decision in Outcomes
& Retrospective either way, write the retrospective, and record the closing provenance revision
(`--mode implement`) on this plan.

Acceptance for Milestone 3: `nix fmt` is a no-op, `cabal build all` and `cabal test all` pass,
`nix build .#kiroku-metrics` and `nix build .#kiroku-store` succeed, `just capabilities-validate`
and the strict improvement-request validation pass, `git diff --check` is clean, and the guide's
conformance table lists all ten convention elements with a status for each path.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell from `.envrc`).

Baseline first:

```bash
git status --short --branch
cabal build all
cabal test kiroku-metrics-test
cabal bench kiroku-store:kiroku-shibuya-overhead
```

Expected: a clean tree on `master`, the metrics suite green, and a benchmark table whose
bare-subscribe rows you copy into this plan before editing anything. If the baseline fails, stop
and record it.

Milestone 1 edits and checks:

```bash
# edit docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md  (status: in_progress, timestamp, Status paragraph)
# edit docs/improvement-requests/log.md                                                            (dated Implementation entry)
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
# edit kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs   (subDropped, PublisherSubscription, subscribePublisherWith, DropOldest branch)
# write kiroku-store/test/Test/PublisherDropCounter.hs
# edit kiroku-store/test/Main.hs                                       (+ PublisherDropCounter.spec)
# edit kiroku-store/kiroku-store.cabal                                 (+ test other-modules)
# edit kiroku-store/CHANGELOG.md                                       (unreleased bullets)
grep -rn "Subscriber{" --include='*.hs' kiroku-store kiroku-metrics shibuya-kiroku-adapter kiroku-otel kiroku-cli
nix fmt
cabal build all
cabal test kiroku-store-test --test-options='--match "publisher drop counter"'
cabal test kiroku-store-test
cabal bench kiroku-store:kiroku-shibuya-overhead
```

Expected tail of the focused run:

```text
publisher drop counter
  counts one dropped batch under DropOldest, keeps the newest batch, and leaves the wrapper unchanged [✔]

Finished in 2.1 seconds
1 example, 0 failures
```

Commit:

```text
feat(store): count batches dropped under DropOldest per publisher subscriber

Add subDropped to Subscriber, increment it on the DropOldest branch only,
and expose it through subscribePublisherWith; subscribePublisher is unchanged.

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
```

Milestone 2 edits and checks:

```bash
grep -n "recordedEventToJSONResolved" kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs   # decides the coordination branch
# edit kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs   (UnsubscribeMetrics, CodedError, codes, handleMetrics, encoder, cache, overflowNotice, broadcastLoop)
# edit kiroku-metrics/CHANGELOG.md                       (## Unreleased / ### New Features)
# write kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs
# edit kiroku-metrics/test/Main.hs                       (+ WebSocketConvergenceSpec.spec)
# edit kiroku-metrics/kiroku-metrics.cabal               (+ test other-modules)
nix fmt
cabal build kiroku-metrics
cabal test kiroku-metrics-test --test-options='--match "Kiroku.Metrics.WebSocket ("'
cabal test kiroku-metrics-test
git diff --stat -- kiroku-metrics/test/Test/WebSocketSpec.hs
```

Expected focused tail (the exact example titles are yours to word; the counts are the point):

```text
Kiroku.Metrics.WebSocket (frames)
  keeps every pre-existing server frame byte-identical [✔]
  encodes coded error frames and spells the three codes [✔]
  decodes unsubscribe_metrics and every existing client frame [✔]
  adds exactly original_stream_name to the resolved event object [✔]
  emits an overflow notice only when the drop counter grew [✔]
Kiroku.Metrics.WebSocket (convergence, real server)
  stops the periodic push on unsubscribe_metrics and resumes it on subscribe_metrics [✔]
  labels live-tail events with original_stream_name [✔]
  labels replayed and category-tail events with original_stream_name [✔]
  codes a replay failure as replay_failed [✔]
  codes a category read failure as category_read_failed [✔]
  deregisters every tail on disconnect [✔]
Kiroku.Metrics.WebSocket (endpoints)
  ... (the four pre-existing examples, unchanged) ...

15 examples, 0 failures
```

and an empty `git diff --stat` for the old spec. Commit as
`feat(kiroku-metrics): converge the WebSocket protocol additively with the inspection convention`
with the three trailers.

Milestone 3 edits and checks:

```bash
# edit docs/user/metrics.md                                   (WebSocket section, conformance table, See Also)
# edit docs/capabilities/operational-http-endpoints.md, docs/capabilities/log.md
# edit docs/improvement-requests/converge-the-websocket-protocol-with-the-cross-project-convention.md, docs/improvement-requests/log.md
# edit kiroku-metrics/CHANGELOG.md, kiroku-store/CHANGELOG.md   (final wording)
just capabilities-validate
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
nix fmt
cabal build all
cabal test all
nix build .#kiroku-metrics
nix build .#kiroku-store
git diff --check
```

Expected: every command exits zero (the improvement-request validator's "missing
profile-recommended field: reviews" lines are advisory). Commit as
`docs(kiroku-metrics): document the converged WebSocket protocol and its conformance mapping`
with the three trailers, then record the closing provenance revision:

```bash
bun agents/skills/exec-plan/record-provenance.ts revision \
  --plan docs/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md \
  --model <your-model-id> --harness claude-code --mode implement \
  --note "IR-12 implemented: drop counter, coded errors, unsubscribe_metrics, original_stream_name, conformance mapping"
```


## Validation and Acceptance

The plan is accepted when every item below is observed, mapped to IR-12's acceptance list:

1. A client written against the shipped protocol operates unchanged: `Test.WebSocketSpec` passes
   with no edits, and the frame-pinning example proves `toJSON` of every pre-existing server
   frame is byte-identical (IR-12 acceptance 1).
2. Every change is additive: `git diff` of `WebSocket.hs` shows new constructors, new functions,
   and edited handler bodies, but no removed or renamed constructor, no changed `toJSON`
   equation for an existing constructor, no change to `dispatchPath`, and no change to
   `recordedEventToJSON`'s key list (IR-12 acceptance 2).
3. The conformance mapping in `docs/user/metrics.md` lists all ten convention elements, each
   marked met, additively closed, or documented deviation, naming the kiroku frame(s)
   (IR-12 acceptance 3).
4. The new frames and fields use snake_case (`unsubscribe_metrics`, `code`,
   `original_stream_name`) and are documented with example JSON (IR-12 acceptance 4).
5. Against a running store-backed server: `unsubscribe_metrics` silences periodic snapshots and
   `subscribe_metrics` resumes them; every `event` frame on a live, replayed, and category tail
   carries the correct `original_stream_name`; a replay failure yields `code` `replay_failed`
   and a category read failure yields `code` `category_read_failed`.
6. At the library level, a `DropOldest` subscriber with capacity one that receives two batches
   without reading shows `subscriptionDropped` equal to one with status still `Active`, and
   `overflowNotice` turns that increase into the `event_stream_overflowed` frame.
7. The overhead benchmark's bare-subscribe rows before and after Milestone 1 agree within noise
   and are recorded in Surprises & Discoveries.
8. CAP-17, IR-12 (`in_progress` with evidence), both changelogs, and the guide are updated and
   every bundle validates; no version has been bumped and nothing has been published.


## Idempotence and Recovery

Every change is additive source code, tests, documentation, and changelog text; there is no
migration and no destructive operation. Re-running any build, test, benchmark, or validation
command is safe. Tests use a fresh migrated database per example and OS-assigned ports, so reruns
cannot collide. The `ALTER TABLE events RENAME` used to force read failures happens inside a
throwaway test database.

If `cabal build all` fails after Milestone 1 with an incomplete-patterns or missing-field error
in another package, that package constructs or exhaustively matches `Subscriber`; add the
`subDropped` field there and record it in Surprises & Discoveries. If the drop-counter test sees
a count of zero, the two appends were published as one batch; wait on the publisher position
between them as the milestone describes, and if needed add a short delay. If example 6 is flaky
on a loaded machine, lengthen the silent window and the resume timeouts proportionally
(the intervals are chosen at 200 ms so the test stays under two seconds; the ratios matter, not
the absolute values) and record the change.

If a milestone is interrupted, the tree still builds after each commit because each commit is
scoped to compile on its own (the store change before its metrics consumer). To roll back, revert
the milestone's commits in reverse order; nothing outside the repository observes the change until
plan 96 releases, which this plan does not do. IR-12 must stay `in_progress` until plan 96 has
release evidence; never set `completed` from a local build.


## Interfaces and Dependencies

At the end of Milestone 1, `kiroku-store` (`Kiroku.Store.Subscription.EventPublisher`) exposes:

```haskell
data Subscriber = Subscriber
    { subQueue :: !(TBQueue (Vector RecordedEvent))
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    , subDropped :: !(TVar Word64)          -- new
    }

data PublisherSubscription = PublisherSubscription   -- new
    { subscriptionQueue :: !(TBQueue (Vector RecordedEvent))
    , subscriptionStatus :: !(TVar SubscriberStatus)
    , subscriptionDropped :: !(TVar Word64)
    , unsubscribe :: !(IO ())
    }

subscribePublisherWith :: EventPublisher -> Natural -> OverflowPolicy -> STM PublisherSubscription   -- new
subscribePublisher :: EventPublisher -> Natural -> OverflowPolicy
                   -> STM (TBQueue (Vector RecordedEvent), TVar SubscriberStatus, IO ())            -- unchanged
```

with the semantics that `subDropped` increments by one for each batch discarded under
`DropOldest` and never changes under `PauseAndResume` or `DropSubscription`. This is a PVP-major
change (record definition), absorbed by the cohort's `kiroku-store` 0.10.0.0 in plan 96.

At the end of Milestone 2, `kiroku-metrics` (`Kiroku.Metrics.WebSocket`) exposes, in addition to
today's exports:

```haskell
data ClientMessage = ... | UnsubscribeMetrics
data ServerMessage = ... | CodedError !Text !Text
errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed :: Text
recordedEventToJSONResolved :: Map StreamId StreamName -> RecordedEvent -> Value   -- owned by plan 88; introduced here only if absent
overflowNotice :: Word64 -> Word64 -> Maybe ServerMessage
```

Wire contract owned by this plan (published once shipped, per ADR-9):

```json
{"type":"unsubscribe_metrics"}
{"type":"error","code":"replay_failed","message":"replay error: ..."}
{"type":"error","code":"category_read_failed","message":"category read error: ..."}
{"type":"error","code":"event_stream_overflowed","message":"event stream overflowed; N undelivered batch(es) dropped ..."}
{"type":"event","event":{"eventId":"...","eventType":"...","streamVersion":1,"globalPosition":43,"originalStreamId":9,"originalVersion":1,"payload":{},"metadata":null,"causationId":null,"correlationId":null,"createdAt":"...","original_stream_name":"orders-7"}}
```

The `message` texts are not contract; the `code` values and the `original_stream_name` key are.

Dependencies: no new library dependency in either package. `Data.Word`, `Data.Map.Strict`,
`Data.Aeson.KeyMap`, and `Data.List` come from `base`, `containers`, and `aeson`, all already
present. The only runtime service is PostgreSQL with the existing Kiroku migrations. Locate
dependency sources through `mori registry show <project> --full` (for example `haskell/aeson`,
`haskell/stm`, `haskell/containers`) when behaviour is uncertain; for `websockets`, which is not in
the corpus, unpack the exact version from `dist-newstyle/cache/plan.json` out of
`~/.cabal/packages`; do not inspect `/nix/store`.

Dependency direction is unchanged: `kiroku-metrics` depends on `kiroku-cli` and `kiroku-store`;
nothing depends on `kiroku-metrics`. Sibling plans this plan coordinates with, by path: plan 88
(`docs/plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md`) for the
shared encoder, and plan 96
(`docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`) for
the release that completes IR-12.
