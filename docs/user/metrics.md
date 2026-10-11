# Metrics, Health, And Event Streaming Over HTTP

The `kiroku-metrics` package exposes a running Kiroku store's operational metrics
over HTTP (JSON and Prometheus), Kubernetes-style health probes, a live
subscription-status endpoint, a durable checkpoint inventory, and a WebSocket that pushes live metrics **and
streams events out of the store** to any network client.

Like [`kiroku-otel`](opentelemetry.md), it is a **sister package** to
`kiroku-store`: it depends on `kiroku-store`, but the core library gains no web
dependency. The collector is a pure external consumer of the
store's existing callback seams (the same `eventHandler`/`observationHandler`
described in [Observability](observability.md)) plus a couple of public read
accessors.

> **Deployment assumption — no built-in auth or TLS.** The server has no
> authentication, TLS, or rate limiting. The starters and `kiroku-inspect` bind all interfaces; use network
> isolation or a sidecar/ingress that terminates TLS and authentication. Treat
> `/metrics`, `/health`, `/subscriptions`, `/subscription-checkpoints`,
> `/subscriptions/<name>/dead-letters`, browsing routes, and the WebSocket as you would any
> internal scrape/admin surface. CORS only tells browsers which pages may read
> responses; it does not replace the trusted-network or authenticating-proxy assumption.

## Contents

- [Wiring the collector](#wiring-the-collector)
- [Starting the server](#starting-the-server)
- [Wire-format stability](#wire-format-stability)
- [HTTP endpoints](#http-endpoints)
- [Prometheus metric reference](#prometheus-metric-reference)
- [Interpreting the metrics](#interpreting-the-metrics)
- [The WebSocket protocol](#the-websocket-protocol)
- [Subscription status over HTTP](#subscription-status-over-http)
- [Dead letters over HTTP](#dead-letters-over-http)
- [Browsing streams, categories and events](#browsing-streams-categories-and-events-unreleased)
- [Durable subscription checkpoints over HTTP](#durable-subscription-checkpoints-over-http)
- [Cross-origin browser access (CORS)](#cross-origin-browser-access-cors)
- [Discovering the surface](#discovering-the-surface)
- [Running the standalone server](#running-the-standalone-server)
- [Try it](#try-it)
- [See Also](#see-also)

## Wiring the collector

The collector turns the store's callback signals into a snapshot. There is **one
non-obvious step**: the collector's callbacks must be installed on
`ConnectionSettings` *before* `withStore` opens the store (so the collector sees
every event from the first append), yet a snapshot also reads store-level gauges
(global position, subscriber count) from the live store handle, which does not
exist until the store is open.

The supported pattern resolves this with `newKirokuMetricsWith`, which builds the
collector from two STM readers, and a `TVar (Maybe KirokuStore)` that is filled in
once the store opens:

```haskell
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (.~))
import Data.IntMap.Strict qualified as IntMap
import Kiroku.Metrics
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher (EventPublisher (..), publisherPosition)
import Kiroku.Store.Types (GlobalPosition (..))

bootMetrics :: Text -> IO ()
bootMetrics connStr = do
  storeVar <- newTVarIO Nothing
  metrics  <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
  let settings =
        defaultConnectionSettings connStr
          & #eventHandler       .~ Just (metricsEventHandler       metrics Nothing)
          & #observationHandler .~ Just (metricsObservationHandler metrics Nothing)
  withStore settings $ \store -> do
    atomically (writeTVar storeVar (Just store))
    withMetricsServerWithStore (defaultConfig {port = 9091}) metrics store [postgresPing store] $ \srv -> do
      putStrLn ("metrics server on port " <> show srv.serverPort)
      {- run your subscriptions and append events; the endpoints reflect them -}
      pure ()

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
  readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
  readTVar storeVar >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))
```

The `Maybe (… -> IO ())` passthrough argument to `metricsEventHandler` /
`metricsObservationHandler` lets the collector **compose with an existing logger**:
pass `Just myLogger` instead of `Nothing` and both run. The collector's own updates
are non-blocking STM, satisfying the [fast-callback
constraint](observability.md#wiring-the-callbacks) — the store invokes these
callbacks synchronously on the emitting thread, so they must not block.

If you do not need the live event/metrics WebSocket, use `withMetricsServer`
(or `startMetricsServer`/`stopMetricsServer`) instead of the
`…WithStore` variant; it takes the same arguments minus the `KirokuStore`.

The store-backed starter also serves the durable checkpoint inventory, independently
of the live status provider. For both live and durable reads, use the provider binding
shown below.

## Starting the server

`MetricsServerConfig` controls the server. `defaultConfig` enables everything on
port 9091:

| Field | Default | Meaning |
|-------|---------|---------|
| `port` | `9091` | TCP port. `0` binds an OS-assigned free port (reported in `serverPort`). |
| `enableJSON` | `True` | Serve the JSON metrics and health endpoints. |
| `enablePrometheus` | `True` | Serve `GET /metrics/prometheus`. |
| `enableWebSocket` | `True` | Enable the WebSocket upgrade paths. |
| `wsPushIntervalUs` | `1_000_000` | Live metrics-push interval (µs) on `/ws/metrics`. |
| `wsMaxConnections` | `100` | Max concurrent WebSocket connections. |
| `wsEventQueueCap` | `256` | Per-connection event-tail broadcast queue capacity (batches). |
| `readinessMaxLag` | `10_000` | A subscription lagging beyond this fails readiness. |
| `livenessTimeoutUs` | `1_000_000` | Snapshot time budget for the liveness probe (µs). |
| `cors` | `corsDisabled` | Allowed browser origins for HTTP, preflight, and WebSocket upgrades. Disabled sends no CORS headers and leaves upgrades open. |

Lifecycle: `withMetricsServerWithStore cfg metrics store deps` (bracketed,
recommended) or `startMetricsServerWithStore … >>= … ; stopMetricsServer`. The
`deps :: [DependencyCheck]` list drives readiness; `postgresPing store` is the
built-in PostgreSQL ping.

Every starter waits for Warp readiness before returning and propagates bind or setup
failure. Bracketed starters supervise unexpected server termination and release the
server when the callback ends or fails. The callback runs in a supervised thread.

New hosts wanting every store-backed route bind the providers explicitly.
When importing the full umbrella, qualify configuration record updates to
distinguish their labels from the standalone option records:

```haskell
import Kiroku.Metrics.Config qualified as Config

let cfg = defaultConfig{Config.port = 9091}
providers <- storeServerProviders cfg metrics store
withMetricsServerWithProviders cfg metrics [postgresPing store] providers $ \server ->
  useServer server
```

`ServerProviders` contains `webSocketServer`, optional `subscriptionStatus` and
optional `checkpointInventory`, `storeBrowsing` and `deadLetters`, plus declared
`webSocketChannels`.
`defaultServerProviders` rejects upgrades and leaves every read provider absent. Record updates allow custom sources. The legacy store
starter wires the WebSocket, durable inventory, browse reads and dead letters while keeping the live route's
published unconfigured 404; it does not opt into the live registry automatically.

`combinedAppWithProviders cfg metrics deps providers` is the CORS-wrapped, prefix-mountable
WAI application. A host strips its prefix from `pathInfo`; the composition also escapes
that relative path for WebSocket dispatch and retains the query string. The bare
`httpAppWithProviders` router requires the host to apply CORS. `enableWebSocket = False`
prevents upgrade dispatch, including through legacy starters.

Every server reports its wiring at [`/capabilities`](#discovering-the-surface).

## Wire-format stability

Every JSON body, HTTP status, Prometheus metric name, WebSocket frame, and event
field documented on this page is a **published contract** governed by
[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
(`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`), the HTTP-layer analogue of
ADR-6's frozen SQL relations:

- A published field is never removed, renamed, or re-typed; a frame's `type` and
  its meaning never change; a route's path never changes.
- New optional fields, new frame types, new routes, new metrics, and new members
  of an enumerated vocabulary (such as `phase`) may be added. Clients must ignore
  what they do not recognize.
- An incompatible change ships as a new path or a new frame type; the old one
  stays for its documented compatibility window.
- New keys are snake_case everywhere, including on the camelCase event object,
  whose shipped casing is frozen and is not precedent.
- The human-readable text of an `error` string or `message` field is not a
  contract; switch on status codes, not wording.

Changing an encoder in `kiroku-metrics` means changing this page in the same
commit — read the record first. `kiroku-store` itself owns no wire format and
gains no web dependency; the surface lives here, in a sister package.

## HTTP endpoints

All JSON responses are `application/json`. New wire keys are **snake_case**;
the published event object retains its camelCase keys. Store-backed servers also
serve [dead letters](#dead-letters-over-http).

### `GET /metrics`

The full snapshot — `store` gauges, `counters` (monotonic lifecycle counters), and
a `subscriptions` map keyed by subscription name. Abbreviated (the `counters`
object carries every counter from the [Prometheus reference](#prometheus-metric-reference)):

```bash
curl -s localhost:9091/metrics | jq .
```

```json
{
  "store": {
    "global_position": 42,
    "active_subscribers": 1,
    "pool_connecting": 0,
    "pool_ready": 1,
    "pool_in_use": 0,
    "pool_established_total": 2,
    "pool_terminated_total": 0
  },
  "counters": {
    "subscriptions_started": 1,
    "subscriptions_caught_up": 1,
    "events_delivered": 42,
    "batches_delivered": 3
  },
  "subscriptions": {
    "inventory-projection": {
      "last_known_position": 42,
      "lag": 0,
      "db_error_count": 0,
      "last_stop_reason": null
    }
  }
}
```

### `GET /metrics/<subscription>`

One subscription's `SubscriptionMetrics` object, or `404` if the name is unknown:

```bash
curl -s localhost:9091/metrics/inventory-projection
```

```json
{ "last_known_position": 42, "lag": 0, "db_error_count": 0, "last_stop_reason": null }
```

### `GET /metrics/prometheus`

Prometheus text-exposition format (`text/plain; version=0.0.4`). See the
[Prometheus metric reference](#prometheus-metric-reference) for the full set:

```bash
curl -s localhost:9091/metrics/prometheus | head
```

```text
# HELP kiroku_events_appended_total Total events appended store-wide (gap-free global position).
# TYPE kiroku_events_appended_total counter
kiroku_events_appended_total 42
# HELP kiroku_active_subscribers Currently registered subscribers.
# TYPE kiroku_active_subscribers gauge
kiroku_active_subscribers 1
```

### `GET /health/live`, `GET /health/ready`, `GET /health`

Kubernetes-style probes. Each returns **HTTP 200** when healthy and **HTTP 503**
when not, with a JSON body.

- **`/health/live`** — can a snapshot be taken within `livenessTimeoutUs`? Proves
  the process and collector are responsive.

  ```json
  { "alive": true }
  ```

- **`/health/ready`** — ready to serve: no subscription overflow-stopped, none
  lagging beyond `readinessMaxLag`, and every `DependencyCheck` healthy.

  ```json
  {
    "ready": true,
    "lag_ok": true,
    "no_overflow": true,
    "dependencies": [ { "name": "postgres", "healthy": true, "latency_ms": 1, "error": null } ]
  }
  ```

- **`/health`** — the readiness verdict plus the full snapshot, for humans:
  `{ "status": { … readiness … }, "metrics": { … snapshot … } }`.

Add your own dependency check by appending an `IO DependencyStatus` action to the
`deps` list. It runs on every readiness check; an unhealthy result (or one beyond
`readinessMaxLag`) flips `/health/ready` to 503.

### `GET /subscription-checkpoints`

The durable, cross-process checkpoint inventory. Store-backed starters wire this route;
see [Durable subscription checkpoints over HTTP](#durable-subscription-checkpoints-over-http).

## Browsing streams, categories and events (unreleased)

A store-backed server (`withMetricsServerWithStore`, or `storeServerProviders`)
serves these read-only routes. Hosts can supply a custom `StoreBrowser` in
`ServerProviders.storeBrowsing`; without one the routes return a structured
404 `store_browsing_not_configured`. They share the server's CORS policy.

| Route | Parameters and result |
| --- | --- |
| `GET /streams` | `category`, literal `prefix`, exclusive name `from`, `limit`; stream summaries |
| `GET /streams/<name>` | One summary, or 404 `stream_not_found` |
| `GET /streams/<name>/events` | Exclusive stream-version `from`, `limit`, `direction=forward` or `backward` |
| `GET /categories` | Exclusive category-name `from`, `limit`; distinct category names |
| `GET /categories/<name>/events` | Exclusive global-position `from`, `limit`; forward category events |
| `GET /events` | Exclusive global-position `from`, `limit`, `direction=forward` or `backward` |
| `GET /events/<uuid>` | One event as it appears in the global log, or 404 `event_not_found` |

HEAD uses the same status and headers with no body. Other methods return 405
with `Allow: GET, HEAD`. Invalid parameters return 400
`invalid_query_parameter`; invalid UUIDs return `invalid_event_id`. `/streams/$all`
is reserved; use `/events` for the global log. Limits default to 100 and have a
maximum of 1000; hosts can use `mkBrowseLimits` and `storeBrowserWith` to lower
them. Numeric cursors are non-negative Int64 decimal values. Zero selects the
beginning forward and newest backward.

```bash
curl -s 'localhost:9091/streams?category=orders&limit=10' | jq .
curl -s 'localhost:9091/streams?category=orders&prefix=orders-order_&limit=10' | jq .
curl -s 'localhost:9091/events?from=0&limit=10' | jq .
```

Pages contain `items` and include `next_cursor` only when another item was
observed. Echo that cursor verbatim as `from`; when absent, the page is exhausted.
Stream names use stable UTF-8 byte order, including Unicode names. This puts
TypeIDs in ID-generation order within a category; it does not promise event or
commit order. Prefixes are literal: `%` and `_` have no wildcard meaning.
Category enumeration retains database locale order. Pages describe the current
store, without a cross-request snapshot; concurrent inserts/deletes can change
later pages.

Summaries contain `stream_id`, `name`, `category`, `version`, `created_at`,
`deleted_at`, and `truncate_before`. Soft-deleted summaries remain visible and
hard-deleted streams disappear. Ordered per-stream event reads honor truncation;
global and category reads retain their existing lifecycle semantics. Events
preserve the documented camelCase shape and add `original_stream_name`, resolved
once per returned page, or null if its original stream row no longer exists.
Connection and decode errors use sanitized structured error envelopes.

Migration 0015 adds one partial byte-order name index shared by category and
prefix browsing. Its transactional build requires a write pause or maintenance
window. Final-layout write-cost and cumulative release acceptance remain open;
this unreleased surface has not been published to Hackage.

## Prometheus metric reference

Metric names, types, and label names are a published contract for dashboards
(see [Wire-format stability](#wire-format-stability)). The endpoint emits:

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `kiroku_events_appended_total` | counter | — | Total events appended store-wide (the gap-free global position == high-water mark). |
| `kiroku_active_subscribers` | gauge | — | Currently registered subscribers (broadcast + in-process subscriptions). |
| `kiroku_pool_connections` | gauge | `state="connecting\|ready\|in_use"` | Pool connections by state. |
| `kiroku_pool_established_total` | counter | — | Pool connections established. |
| `kiroku_pool_terminated_total` | counter | — | Pool connections terminated. |
| `kiroku_notifier_reconnecting_total` | counter | — | Notifier reconnection attempts started. |
| `kiroku_notifier_reconnected_total` | counter | — | Notifier reconnections completed. |
| `kiroku_publisher_decode_failures_total` | counter | — | Typed publisher hook failures; excludes subscriber retry attempts. |
| `kiroku_publisher_pool_errors_total` | counter | — | EventPublisher read-query pool errors. |
| `kiroku_subscription_db_errors_by_phase_total` | counter | `phase="load\|fetch\|save"` | Subscription database errors by phase. |
| `kiroku_subscriptions_started_total` | counter | — | Subscription workers started. |
| `kiroku_subscriptions_caught_up_total` | counter | — | Subscriptions that reached live mode. |
| `kiroku_subscriptions_paused_total` | counter | — | Subscription pauses (backpressure). |
| `kiroku_subscriptions_resumed_total` | counter | — | Subscription resumes after pause. |
| `kiroku_subscriptions_reconnecting_total` | counter | — | Subscription live-fetch reconnects. |
| `kiroku_subscription_handler_stalls_total` | counter | — | Advisory handler stall warnings; enabled only by explicit subscription configuration. |
| `kiroku_subscriptions_retrying_total` | counter | — | Subscription event redeliveries. |
| `kiroku_subscriptions_dead_lettered_total` | counter | — | Events written to dead letters. |
| `kiroku_subscriptions_stopped_total` | counter | `reason="handler\|cancelled\|overflow\|crashed\|undecodable"` | Subscription stops by reason. |
| `kiroku_live_fetches_total` | counter | — | Live-mode database fetches. |
| `kiroku_batches_delivered_total` | counter | — | Non-empty batches delivered to handlers. |
| `kiroku_events_delivered_total` | counter | — | Events delivered to handlers. |
| `kiroku_hard_deletes_total` | counter | — | Hard-delete transactions issued. |
| `kiroku_subscription_position` | gauge | `subscription` | Last-known global position per subscription. |
| `kiroku_subscription_lag` | gauge | `subscription` | Lag behind the global position per subscription (upper bound). |
| `kiroku_subscription_db_errors_total` | counter | `subscription` | Database errors per subscription. |

## Interpreting the metrics

**Throughput is free from the global position.** `kiroku_events_appended_total`
*is* the store's gap-free global position (see
[`GlobalPosition`](reading-events.md)), which equals both the total events ever
appended store-wide and the high-water mark. There is no per-append counter on the
hot path; throughput is `rate(kiroku_events_appended_total[1m])` in Prometheus.

**Lag is an upper bound.** The collector observes a subscription's position only at
**lifecycle** callback points (`Started`, `CaughtUp`, `Stopped`), not per processed
event — the store does not emit per-event progress. So `lag = max 0
(global_position − last_known_position)` is an *upper bound*: a subscription that
quietly caught up between lifecycle events shows its last lifecycle position until
the next one. `readinessMaxLag` defaults higher than Marten's `maxEventLag` (100)
for this reason. This lineage — a store-wide sequence figure plus per-consumer lag
as the readiness signal — follows Marten (`FetchEventStoreStatistics` +
`AllProjectionProgress`) and EventStoreDB persistent-subscription gap stats.

For the *current* phase and cursor of every running subscription (not an upper
bound), use [`/subscriptions`](#subscription-status-over-http), which reads the
live registry directly.

## The WebSocket protocol

Two paths, dispatched by URL. Messages are tagged JSON (`{"type": "..."}`).

- **`ws://host:9091/ws/metrics`** — a metrics channel: a `snapshot` on connect,
  then a fresh `snapshot` every `wsPushIntervalUs`; `ping` → `pong`.
- **`ws://host:9091/ws/events`** — an event channel: after a `subscribe_events`
  message, one `event` message per appended `RecordedEvent` in global-position
  order, live.

### Client → server

| Message | Channel | Meaning |
|---------|---------|---------|
| `{"type":"ping"}` | both | Keepalive; answered with `pong`. |
| `{"type":"subscribe_metrics"}` | metrics | Request a fresh snapshot now and resume periodic push if stopped. |
| `{"type":"unsubscribe_metrics"}` | metrics | Stop periodic snapshots; `subscribe_metrics` resumes them. |
| `{"type":"subscribe_events","from_position":N,"category":"orders"}` | events | Start streaming. Both fields optional: omit `from_position` for "from now"; omit `category` for all streams. |
| `{"type":"unsubscribe_events"}` | events | Stop the current tail. |

### Server → client

| Message | Meaning |
|---------|---------|
| `{"type":"pong"}` | Answer to `ping`. |
| `{"type":"snapshot","metrics":{ … MetricsSnapshot … }}` | A metrics snapshot (same shape as `GET /metrics`). |
| `{"type":"event","event":{ … RecordedEvent … }}` | One appended event (shape below). |
| `{"type":"event_stream_started","from_position":N}` | Acknowledgement that streaming has begun from position `N`. |
| `{"type":"goodbye"}` | The connection is being torn down. |
| `{"type":"error","code":"…","message":"…"}` | A stable machine-readable code with human text that may change. |

### Error codes (unreleased)

| Code | Meaning and recovery |
| --- | --- |
| `replay_failed` | History read failed; the tail ended. Resubscribe after recovery. |
| `category_read_failed` | Category read failed; the tail ended. Resubscribe after recovery. |
| `live_decode_failed` | An applicable typed decode failure ended the live tail without partial data. Repair decoding and resubscribe. |
| `event_stream_overflowed` | Old undelivered batches were dropped. Re-read through REST or resubscribe with `from_position` from the last contiguous **pre-notice** cursor. |

Older errors carried no `code`; clients must tolerate that. A tail error leaves
its connection open for ping or resubscription. Messages contain sanitized text.


### The `RecordedEvent` wire shape

Produced by `recordedEventToJSONResolved` for tail frames and REST browse items.
The original `recordedEventToJSON` encoder retains its eleven-key shape. **Note:** the protocol envelope and metrics keys
are snake_case, but the per-event payload fields are **camelCase**. Both halves are
frozen as shipped; a key added to this object later is snake_case (see
[Wire-format stability](#wire-format-stability)):

| Field | JSON type | Meaning |
|-------|-----------|---------|
| `eventId` | string (UUID) | The event's stable id. |
| `eventType` | string | Application-level type discriminator. |
| `streamVersion` | number | Position in the stream being read. |
| `globalPosition` | number | Position in the global `$all` sequence (the subscription cursor). |
| `originalStreamId` | number | Surrogate id of the source stream (not the stream name). |
| `originalVersion` | number | Position in the source stream. |
| `payload` | any JSON | The event body. |
| `metadata` | any JSON or `null` | The event metadata. |
| `causationId` | string (UUID) or `null` | Causing event's id. |
| `correlationId` | string (UUID) or `null` | Workflow correlation id. |
| `createdAt` | string (ISO-8601) | Append timestamp. |
| `original_stream_name` | string or `null` | Source stream name resolved from `originalStreamId`, or null when unavailable. This additive key is snake_case. |

### Semantics

- **Live-from-now by default**, built on the public `EventPublisher` broadcast — it
  creates **no persistent subscription** and writes nothing to the `subscriptions`
  checkpoint table, so transient watchers leave no trace.
- **Backpressure is `DropOldest`** (bounded by `wsEventQueueCap`): a slow client
  loses the oldest undelivered batches rather than stalling the publisher or other
  subscribers. The server samples the dropped-batch count atomically with dequeue
  and sends `event_stream_overflowed` **before** the affected survivor batch. Keep
  the pre-notice contiguous cursor, mark later live events as hints and re-read
  from that saved cursor. Earlier releases documented this notice but never sent it.
  Category tails read the database directly and cannot overflow a broadcast queue.
- **`from_position` replay**: history from that position is paged out first, then
  the live tail continues, with no duplicate at the boundary.
- **`category` filter** is SQL-filtered (`readCategory`) because broadcast events
  carry only source IDs; it gates on the global position advancing.
- **Name resolution** uses at most one batched lookup per delivered batch and a
  per-tail FIFO cache retaining at most 4096 names. Empty/warm batches do no lookup;
  missing names remain null, and evicted names may be fetched again. The cache is
  discarded on unsubscribe, resubscribe or disconnect.
- **Metrics lifecycle** retains push-on-connect. Unsubscribe cancels and joins
  the push worker; repeated subscribe requests snapshots and keeps one worker.

### Conformance with the cross-project WebSocket convention

The convention is defined by `mori://shinzui/keiro-ui`,
`docs/architecture/inspection-api-conventions.md` (artifact-level URI pending),
and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`.
Kiroku's shipped dialect is frozen by [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
and converges additively in this unreleased cohort.

| Convention element | `/ws/metrics` | `/ws/events` | Status |
| --- | --- | --- | --- |
| Typed frames | `type` tagged | `type` tagged | Met |
| Subscribe/unsubscribe | `subscribe_metrics` / `unsubscribe_metrics`; push-on-connect retained | `subscribe_events` / `unsubscribe_events` | Metrics additively closed; events met |
| Ping/pong | `ping` / `pong` | `ping` / `pong` | Met |
| Replay cursor | Not applicable | `from_position` | Met where applicable |
| Initial snapshot | Connect and subscribe `snapshot` | `event_stream_started` supplies the starting position | Metrics met; events documented deviation |
| Incremental frames | Periodic complete `snapshot` | `event` | Metrics documented deviation from deltas; events met |
| Server idle pings | WebSocket ping every 30 seconds | WebSocket ping every 30 seconds | Met |
| In-band errors / overflow | Overflow not applicable | Coded `error`; `event_stream_overflowed` before survivors | Events additively closed |
| Goodbye before server close | `goodbye` on teardown, best effort on dead sockets | Same | Met |
| Bounded drop-oldest queue | Not applicable | `wsEventQueueCap`, exact dropped-batch count | Met where applicable |

“Additively closed” retains published frames and behaviors for old clients;
new fields and the repaired overflow notice may appear and must be tolerated.
The events path remains idle until subscribed; metrics retains its connect push.

### `websocat` transcript

```text
$ websocat ws://localhost:9091/ws/events
{"type":"subscribe_events"}
{"type":"event_stream_started","from_position":42}
# (append OrderCreated to orders-7 from another shell)
{"type":"event","event":{"eventType":"OrderCreated","globalPosition":43,"original_stream_name":"orders-7", ...}}
```

## Subscription status over HTTP

A worker that wires the subscription-status provider exposes its **live**
subscription registry — the *current* FSM phase and cursor of every running
subscription, written on every transition (unlike the lag metric, which is an upper
bound). Wire it with `withMetricsServerSubscriptions … (storeSubscriptionStatus
store)` (or pass the provider to `startMetricsServerWith'`).

```bash
curl -s localhost:9091/subscriptions | jq .
```

```json
[ { "subscription": "inventory-projection", "member": 0, "phase": "live", "global_position": 42 } ]
```

- `GET /subscriptions` — all running subscriptions (one row per
  `(subscription, member)`); `phase` is one of
  `catching_up`, `live`, `paused`, `reconnecting`, `retrying`. A stopped
  subscription is **absent**.
- `GET /subscriptions/<name>` — just that name's rows (empty array if none).
- A server started **without** a provider returns
  `404 {"error":"subscription status not configured"}`.

The operator CLI can query a *running worker* over the network — see
[Operator CLI](operator-cli.md):

```bash
kiroku subscriptions status --remote-url http://worker:9091
kiroku subscriptions status --remote-url http://worker:9091 --format json
KIROKU_REMOTE_URL=http://worker:9091 kiroku subscriptions status
```

## Durable subscription checkpoints over HTTP

`GET /subscription-checkpoints` returns one object with the authoritative append frontier
and every persisted checkpoint, ordered by subscription name then numeric member.
This example was captured from the real PostgreSQL route test:

```bash
curl -s localhost:9091/subscription-checkpoints | jq .
```

```json
{
  "store_position": 20,
  "checkpoints": [
    {"subscription": "alpha", "member": 2, "checkpoint_position": 5, "updated_at": "2026-10-10T17:35:35.395016Z"},
    {"subscription": "alpha", "member": 10, "checkpoint_position": 3, "updated_at": "2026-10-10T17:35:35.394805Z"},
    {"subscription": "zeta", "member": 2, "checkpoint_position": 7, "updated_at": "2026-10-10T17:35:35.394296Z"}
  ]
}
```

`store_position` is the greatest global position ever allocated, including deleted events;
it is captured in the same SQL statement snapshot as the rows. `checkpoint_position`
is the exact committed position of that member. `updated_at` is the last successful
checkpoint write time, which does not prove the position advanced. Member zero can mean
an ungrouped worker or member zero of a consumer group; a row cannot distinguish them.
An empty store returns `{"store_position":0,"checkpoints":[]}`.

The live `/subscriptions` registry describes only workers in the answering process;
stopped workers disappear and their live cursors may be ahead of persisted progress.
Durable rows remain after a worker stops and do not require a live status provider.
Processes sharing a database observe the same durable facts for the same snapshot;
separate requests can observe intervening commits. `/subscriptions/checkpoints` still
addresses a live subscription named `checkpoints`.

This read is unpaginated and proportional to the number of checkpoint rows. The server
performs one inventory read per GET or HEAD, with no background polling. Clients should
wait for each request to finish before polling again. Unknown query parameters are ignored.
Decode the Int64 positions losslessly: JavaScript `Number` rounds integers above 2^53.
`store_position - checkpoint_position` is a **position distance**, not lag or an exact
backlog for category, filtered, or grouped consumers.

GET and HEAD return the same status and headers; HEAD has no body. Other methods return
405 with `Allow: GET, HEAD`. Errors on this new route use the structured envelope:

```json
{"error":{"code":"checkpoint_inventory_unavailable","message":"The event store is unavailable."}}
```

| Status | Code | Meaning |
|--------|------|---------|
| 404 | `checkpoint_inventory_not_configured` | No inventory provider was wired. |
| 503 | `checkpoint_inventory_unavailable` | A typed connection failure occurred. |
| 500 | `event_decode_failed` | A typed decode failure occurred. |
| 500 | `store_error` | Another typed store operation failed. |
| 405 | `method_not_allowed` | Use GET or HEAD. |
| 404 | `not_found` | Unknown path when `checkpointsApp` is mounted standalone. |

Messages omit connection strings, raw errors and event payloads. Thrown exceptions propagate
through the host's normal exception handling. Older routes retain their string error bodies.
This route is currently unreleased; after the inspection cohort ships, ADR-9 freezes its
fields and types, with additions limited to optional fields. See the
[Haskell inventory API](subscriptions.md#reading-durable-checkpoints) and
[public SQL relation](schema.md#subscription_checkpoints_v1) for the same durable facts.

## Cross-origin browser access (CORS)

CORS is the browser protocol that allows a page to read responses from another origin
(scheme, host and port). Without an explicit grant, a dashboard served elsewhere cannot
read this server's `/metrics` response.

```haskell
import Kiroku.Metrics

origin <- either (fail . show) pure (allowedOrigin "https://ops.example.com")
let cfg = defaultConfig{port = 9091, cors = corsAllowOrigins [origin]}
withMetricsServerWithStore cfg metrics store [postgresPing store] $ \server -> runApp server
```

`allowedOrigin` accepts explicit HTTP(S) origins with ASCII DNS, IPv4 or bracketed IPv6
hosts and ports from 0 to 65535. It rejects `*`, `null`, user information, malformed
hosts/ports, raw Unicode hosts, and paths, queries or fragments. Configuration trims
surrounding whitespace, tolerates one trailing slash, normalizes scheme/host case and
default ports, and compares equivalent IPv6 representations. Supply internationalized
names in their ASCII form. Request origins must be single valid origins with no trailing
slash or surrounding whitespace; duplicate Origin headers never receive a grant.

The following excerpts show requests to the running server (transport headers omitted):

```text
$ curl -si -X OPTIONS http://localhost:9091/metrics \
    -H 'Origin: https://ops.example.com' -H 'Access-Control-Request-Method: GET'
HTTP/1.1 204 No Content
Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers
Access-Control-Allow-Methods: GET, HEAD, OPTIONS
Access-Control-Allow-Origin: https://ops.example.com

$ curl -si http://localhost:9091/metrics -H 'Origin: https://ops.example.com'
HTTP/1.1 200 OK
Vary: Origin
Content-Type: application/json
Access-Control-Allow-Origin: https://ops.example.com

$ curl -si http://localhost:9091/metrics -H 'Origin: https://evil.example.com'
HTTP/1.1 200 OK
Vary: Origin
Content-Type: application/json
```

With an enabled policy, ordinary responses always vary on Origin, including responses
without an Origin or with an unlisted/malformed one. Only allowed origins receive
`Access-Control-Allow-Origin`, echoing their request value once. Existing Vary tokens
are preserved without duplicates; `Vary: *` stays intact. Allowed GET/HEAD preflights
receive 204 with `GET, HEAD, OPTIONS` and validated requested header names. Plain OPTIONS
and disallowed preflights reach the ordinary router. A requested method other than GET
or HEAD receives 403 `cors_method_not_allowed`; malformed header names or duplicate
requested methods receive 400 `invalid_cors_request`. These new errors use the structured
`{"error":{"code":"...","message":"..."}}` envelope; existing route errors keep their
published string shape.

Configure `allowCredentials = True` when authenticated browser requests must include
credentials, for example through an authenticating proxy. It adds
`Access-Control-Allow-Credentials: true` for allowed origins. Wildcard grants are
unrepresentable, and authentication remains the host's responsibility. `maxAgeSeconds`
adds `Access-Control-Max-Age` on successful preflights when nonnegative; Nothing or a
negative value emits no max-age header. For example:

```haskell
let policy = (corsAllowOrigins [origin]){allowCredentials = True, maxAgeSeconds = Just 3600}
```

Browsers do not enforce HTTP CORS on WebSockets. When origins are configured, this
middleware checks them before upgrade: unlisted, malformed or duplicate origins receive
HTTP 403 `origin_not_allowed` before any frame. Allowed origins and nonbrowser clients
with no Origin can connect. Under the default disabled policy every application response
is unchanged and upgrades remain open to any origin. Every server starter applies the
policy to HTTP and WebSocket dispatch. Hosts mounting the exported bare `httpApp` apply
`corsMiddleware cfg.cors` themselves.

A single-origin deployment needs no CORS policy. Serve the UI and proxy the API from the
same origin; this illustrative Caddyfile strips `/kiroku` before forwarding, including
WebSockets (configure authentication separately):

```caddyfile
ops.example.com {
    handle_path /kiroku/* {
        reverse_proxy 127.0.0.1:9091
    }
    handle {
        root * /srv/kiroku-ui
        file_server
    }
}
```

The new structured error keys become published when released, following
[Wire-format stability](#wire-format-stability). Header values reflect host configuration.
This CORS implementation is currently unreleased and ships with the inspection cohort.

## Dead letters over HTTP

Store-backed starters automatically serve `GET` and `HEAD
/subscriptions/<name>/dead-letters`. Custom hosts set the `deadLetters` field of
`ServerProviders` to `Just (storeDeadLetters store)` or their own provider.
Subscription names containing `/` must percent-encode it as `%2F`.

```bash
curl -s 'http://localhost:9091/subscriptions/inventory-projection/dead-letters?limit=50'
```

A real worker-produced response captured by the HTTP test:

```json
{
  "items": [
    {
      "attempt_count": 1,
      "created_at": "2026-10-11T01:33:01.248556Z",
      "dead_letter_id": 7,
      "event_id": "01a12897-85b9-7217-97ad-4622a7772a6c",
      "global_position": 2,
      "member": 0,
      "reason": {
        "detail": "unknown SKU",
        "kind": "poison"
      },
      "reason_summary": "poison: unknown SKU",
      "subscription": "worker"
    }
  ]
}
```

The response is `{"items": [...]}` with an optional `next_cursor`. Each item has:

| Field | Meaning |
| --- | --- |
| `dead_letter_id` | Stable identity of the parked row. |
| `subscription`, `member` | Subscription and historical consumer-group member; ungrouped subscriptions use 0. |
| `global_position`, `event_id` | Original event position and UUID, usable with `GET /events/<event_id>`. Parse Int64 JSON numbers losslessly, including above 2^53. |
| `reason` | Stored JSON unchanged, including `poison`, `invalid_payload`, `max_attempts_exceeded`, `decode_failure`, or `other` reasons. |
| `reason_summary` | Operator-facing summary. |
| `attempt_count` | Number of delivery attempts recorded by the worker. |
| `created_at` | UTC RFC 3339 timestamp. |

Pages are newest first by `(global_position DESC, dead_letter_id DESC)`. Echo
`next_cursor` verbatim in `from`; clients treat it as opaque. It is omitted on
the last page. `limit` defaults to 100 and accepts 1 through 1000; `member`
optionally selects one non-negative Int32 member. The cursor stays valid if its
row is hard-deleted. Reads observe live state, without a cross-request snapshot.
Unknown names return `200 {"items":[]}`. Reasons are JSON values, not strings.

All-member reads include historical members, with work proportional to member
count times page size. Member-scoped polling is preferable for large groups;
avoid overlapping polls. The existing per-member index serves both shapes.

| Code | HTTP status |
| --- | --- |
| `invalid_query_parameter` | 400, with `parameter`, `value` and `reason` details |
| `method_not_allowed` | 405, `Allow: GET, HEAD` |
| `dead_letters_not_configured` | 404 |
| `dead_letters_unavailable` | 503 |
| `event_decode_failed`, `store_error` | 500 |
| `not_found` | 404 on an unknown standalone-app path |

Missing values, duplicate recognized parameters, signs, malformed UTF-8 and
integer overflow are rejected before a provider call. Unknown parameters are
ignored. Errors use the structured envelope; older routes retain their published
string errors. Store errors are sanitized. HEAD preserves GET status and headers
with no response body.

This is a read-only surface: POST, DELETE and other methods return 405. Redrive,
delete and retry-policy changes require separate safety semantics. The route
joins the [published wire contract](#wire-format-stability) when released.

## Discovering the surface

`GET /capabilities` describes the configured application, regardless of the
`enableJSON`, `enablePrometheus` or `enableWebSocket` switches. HEAD returns the
same status and headers with no body; other methods return structured 405
`method_not_allowed` with `Allow: GET, HEAD`. Discovery performs no database
access and contains no absolute URLs or origin allowlist.

```bash
curl -s http://localhost:9091/capabilities | jq .
```

The response captured from the real standalone test (compiled version before
the cohort release):

```json
{
  "package": "kiroku-metrics",
  "version": "0.2.0.0",
  "routes": {
    "metrics": true,
    "prometheus": true,
    "health": true,
    "subscriptions_live": true,
    "subscriptions_checkpoints": true,
    "dead_letters": true,
    "browse": true,
    "websocket_metrics": true,
    "websocket_events": true
  },
  "cors": {"enabled": true},
  "process_local": ["metrics", "prometheus", "health", "subscriptions_live", "websocket_metrics"]
}
```

`package` identifies this surface and `version` comes from the Cabal-generated
package version (`kirokuMetricsVersion`), rather than a separately maintained
string. Route booleans reflect switches and provider presence. An available
route can still return a temporary failure; this is wiring discovery, not a
readiness probe. `cors.enabled` means explicit origins are configured.

`process_local` identifies answers about this process, including Prometheus.
Live subscriptions and metrics in a standalone server are empty because it runs
no workers; durable inventory, dead letters and history read the shared database.
The same durable facts may be observed from different processes, subject to
intervening commits between requests.

WebSocket booleans combine `enableWebSocket` with `ServerProviders.webSocketChannels`.
`storeServerProviders` and the legacy store starters declare both channels.
`defaultServerProviders` and plain starters declare none. Legacy
`startMetricsServerWith` / `startMetricsServerWith'` and `combinedApp` cannot
inspect their opaque caller-supplied app and conservatively report none; custom
hosts use providers and declare their actual channels. Disabling WebSockets
prevents upgrade dispatch even for a custom declared app.

These new keys join the published contract on release. Clients should ignore
unknown keys and render screens using these booleans. For a complete client
workflow see [Building an inspection UI](../guides/building-an-inspection-ui.md).

## Running the standalone server

`kiroku-inspect` ships in `kiroku-metrics` and serves the inspection backend from
an already migrated database, without writing a Haskell host program:

```bash
DATABASE_URL='postgresql://localhost/kiroku' kiroku-inspect --port 9091 --cors-origin http://localhost:5173
```

```text
kiroku-inspect: connected to schema "kiroku"; listening on port 9091
kiroku-inspect: routes browse=on subscriptions_checkpoints=on dead_letters=on subscriptions_live=on websocket_events=on cors=on
kiroku-inspect: this process runs no subscriptions; /subscriptions, /metrics, and /health reflect only this process
```

The banner appears only after successful binding. Port zero selects a free port
and reports the actual port. The server runs no subscription workers:
`/subscriptions` answers `200 []`, `/metrics` has an empty `subscriptions` map,
and readiness checks its own PostgreSQL connection. Browse, checkpoint,
dead-letter and event-tail routes read the store. The executable does not apply
migrations or serve static UI files.

| Flag | Environment fallback | Default / meaning |
| --- | --- | --- |
| `--database-url URL` | `DATABASE_URL` | Required; libpq connection string passed verbatim |
| `--schema NAME` | `KIROKU_INSPECT_SCHEMA` | `kiroku`; already migrated schema, including notification channel |
| `--pool-size N` | `KIROKU_INSPECT_POOL_SIZE` | 10; positive connection pool size |
| `--port N` | `KIROKU_INSPECT_PORT` | 9091; 0–65535, zero selects a free port |
| `--cors-origin ORIGIN` (repeatable) | `KIROKU_INSPECT_CORS_ORIGINS` (comma-separated) | None; explicit HTTP(S) origins, wildcard refused |
| `--cors-allow-credentials` / `--no-cors-allow-credentials` | `KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS` | false; environment accepts `true`, `false`, `1`, `0` |
| `--ws-max-connections N` | `KIROKU_INSPECT_WS_MAX_CONNECTIONS` | 100; positive connection limit |

Flags override variables, including malformed variables. An explicit negative
credentials flag overrides environment True; the two flags are mutually
exclusive. Empty environment values count as unset. Numeric values require ASCII
decimal digits and are range-checked before narrowing to machine integers.
An explicitly empty database URL or schema is an error. URL-bearing records
have no `Show` instance, startup banners omit the connection string and runtime
failure diagnostics are redacted.

SIGINT and SIGTERM request a joined shutdown, print
`kiroku-inspect: shutting down`, release the server and store, and exit 0.
Usage/resolution errors exit 2; startup or runtime failure exits 1. No bind-address
option is available: the listener binds every interface. Restrict access with a
controlled network/firewall or an authenticating TLS proxy. CORS is browser
access policy, not authentication. For one-origin deployments a reverse proxy
can serve the page and API together without enabling CORS.

## Try it

The package ships a self-verifying example that boots an ephemeral store, starts
the server, appends events, and checks every endpoint over real HTTP and a real
WebSocket. Running it is a test that the documented behavior holds:

```bash
cabal run -fexample kiroku-metrics-example
```

```text
[1/11] ephemeral postgres ready
[2/11] store + collector + metrics server on port 64815
[3/11] appended 3 events to orders-1
[4/11] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/11] CORS: preflight and GET from https://ops.example.com allowed; https://evil.example.com undecorated
[6/11] GET /subscription-checkpoints store_position=3 with no durable checkpoints (this example runs no subscription)
[7/11] Stream browsing and historical events resolve original stream names
[8/11] GET /subscriptions/example/dead-letters returned an empty page (this example runs no subscription)
[9/11] GET /capabilities reports browse, checkpoints, dead letters, and the event tail
[10/11] WebSocket /ws/events received event eventType=OrderRefunded
[11/11] kiroku-metrics-example: all checks passed (snapshot global position = 4)
```

The source is `kiroku-metrics/example/Main.hs`; it is the authoritative,
compiling reference for the wiring pattern above.

## See Also

- Cross-project convention: `mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md` (artifact-level URI pending), and `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`.

- [Observability](observability.md) — the raw `eventHandler`/`observationHandler`
  callbacks this package aggregates.
- [Operator CLI](operator-cli.md) — `kiroku subscriptions status`, including the
  `--remote-url` remote-worker mode that reads `/subscriptions`.
- [OpenTelemetry](opentelemetry.md) — the other sister package, for per-event trace
  context.
- [Subscriptions](subscriptions.md) — the lifecycle these metrics report on.
- [ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
  — the wire-format stability contract and the sister-package ownership boundary
  behind everything on this page.

Lifecycle JSON adds `publisher_decode_failures` and
`subscriptions_stopped_undecodable`; decode failures are separate from publisher
programming errors and worker crashes.

Lifecycle JSON additionally includes `subscription_handler_stalls`. This counts
warnings, including repeated warnings for one pending invocation. It does not
advance the subscription's last-known position or imply that an event was
acknowledged. The OpenTelemetry subscription observer leaves span state unchanged
on these advisory events.
