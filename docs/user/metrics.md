# Metrics, Health, And Event Streaming Over HTTP

The `kiroku-metrics` package exposes a running Kiroku store's operational metrics
over HTTP (JSON and Prometheus), Kubernetes-style health probes, a live
subscription-status endpoint, a durable checkpoint inventory, and a WebSocket that pushes live metrics **and
streams events out of the store** to any network client.

Like [`kiroku-otel`](opentelemetry.md), it is a **sister package** to
`kiroku-store`: it depends on `kiroku-store`, but the core library gains no web
dependency and no code change. The collector is a pure external consumer of the
store's existing callback seams (the same `eventHandler`/`observationHandler`
described in [Observability](observability.md)) plus a couple of public read
accessors.

> **Deployment assumption — no built-in auth or TLS.** The server has no
> authentication, TLS, or rate limiting. It binds all interfaces; use network
> isolation or a sidecar/ingress that terminates TLS and authentication. Treat
> `/metrics`, `/health`, `/subscriptions`, `/subscription-checkpoints`, and the WebSocket as you would any
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
- [Durable subscription checkpoints over HTTP](#durable-subscription-checkpoints-over-http)
- [Cross-origin browser access (CORS)](#cross-origin-browser-access-cors)
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

New hosts wanting every store-backed route bind the providers explicitly:

```haskell
let cfg = defaultConfig{port = 9091}
providers <- storeServerProviders cfg metrics store
withMetricsServerWithProviders cfg metrics [postgresPing store] providers $ \server ->
  useServer server
```

`ServerProviders` contains `webSocketServer`, optional `subscriptionStatus` and
optional `checkpointInventory`. `defaultServerProviders` rejects upgrades and leaves
both read providers absent. Record updates allow custom sources. The legacy store
starter wires the WebSocket and durable inventory while keeping the live route's
published unconfigured 404; it does not opt into the live registry automatically.

`combinedAppWithProviders cfg metrics deps providers` is the CORS-wrapped, prefix-mountable
WAI application. A host strips its prefix from `pathInfo`; the composition also escapes
that relative path for WebSocket dispatch and retains the query string. The bare
`httpAppWithProviders` router requires the host to apply CORS. `enableWebSocket = False`
prevents upgrade dispatch, including through legacy starters.

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

All JSON responses are `application/json`. The wire keys are **snake_case**.

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
| `{"type":"subscribe_metrics"}` | metrics | Request a fresh snapshot now. |
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
| `{"type":"error","message":"…"}` | A non-fatal error. |

### The `RecordedEvent` wire shape

Produced by `recordedEventToJSON`. **Note:** the protocol envelope and metrics keys
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

### Semantics

- **Live-from-now by default**, built on the public `EventPublisher` broadcast — it
  creates **no persistent subscription** and writes nothing to the `subscriptions`
  checkpoint table, so transient watchers leave no trace.
- **Backpressure is `DropOldest`** (bounded by `wsEventQueueCap`): a slow client
  loses the oldest undelivered batches rather than stalling the publisher or other
  subscribers.
- **`from_position` replay**: history from that position is paged out first, then
  the live tail continues, with no duplicate at the boundary.
- **`category` filter** is SQL-filtered (`readCategory`) because broadcast events
  carry no stream name; it gates on the global position advancing.

### `websocat` transcript

```text
$ websocat ws://localhost:9091/ws/events
{"type":"subscribe_events"}
{"type":"event_stream_started","from_position":42}
# (append OrderCreated to orders-7 from another shell)
{"type":"event","event":{"eventType":"OrderCreated","globalPosition":43, ...}}
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

## Try it

The package ships a self-verifying example that boots an ephemeral store, starts
the server, appends events, and checks every endpoint over real HTTP and a real
WebSocket. Running it is a test that the documented behavior holds:

```bash
cabal run -fexample kiroku-metrics-example
```

```text
[1/8] ephemeral postgres ready
[2/8] store + collector + metrics server on port 59196
[3/8] appended 3 events to orders-1
[4/8] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/8] CORS: preflight and GET from https://ops.example.com allowed; https://evil.example.com undecorated
[6/8] GET /subscription-checkpoints store_position=3 with no durable checkpoints (this example runs no subscription)
[7/8] WebSocket /ws/events received event eventType=OrderRefunded
[8/8] kiroku-metrics-example: all checks passed (snapshot global position = 4)
```

The source is `kiroku-metrics/example/Main.hs`; it is the authoritative,
compiling reference for the wiring pattern above.

## See Also

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
