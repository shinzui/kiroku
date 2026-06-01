# Metrics, Health, And Event Streaming Over HTTP

The `kiroku-metrics` package exposes a running Kiroku store's operational metrics
over HTTP (JSON and Prometheus), Kubernetes-style health probes, a live
subscription-status endpoint, and a WebSocket that pushes live metrics **and
streams events out of the store** to any network client.

Like [`kiroku-otel`](opentelemetry.md), it is a **sister package** to
`kiroku-store`: it depends on `kiroku-store`, but the core library gains no web
dependency and no code change. The collector is a pure external consumer of the
store's existing callback seams (the same `eventHandler`/`observationHandler`
described in [Observability](observability.md)) plus a couple of public read
accessors.

> **Deployment assumption — no built-in auth or TLS.** The server has no
> authentication, TLS, or rate limiting. Bind it to an internal interface, or run
> it behind a sidecar/ingress that terminates TLS and authentication. Treat
> `/metrics`, `/health`, `/subscriptions`, and the WebSocket as you would any
> internal scrape/admin surface.

## Contents

- [Wiring the collector](#wiring-the-collector)
- [Starting the server](#starting-the-server)
- [HTTP endpoints](#http-endpoints)
- [Prometheus metric reference](#prometheus-metric-reference)
- [Interpreting the metrics](#interpreting-the-metrics)
- [The WebSocket protocol](#the-websocket-protocol)
- [Subscription status over HTTP](#subscription-status-over-http)
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

Lifecycle: `withMetricsServerWithStore cfg metrics store deps` (bracketed,
recommended) or `startMetricsServerWithStore … >>= … ; stopMetricsServer`. The
`deps :: [DependencyCheck]` list drives readiness; `postgresPing store` is the
built-in PostgreSQL ping.

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

## Prometheus metric reference

Metric names are a stable public contract for dashboards. The endpoint emits:

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `kiroku_events_appended_total` | counter | — | Total events appended store-wide (the gap-free global position == high-water mark). |
| `kiroku_active_subscribers` | gauge | — | Currently registered subscribers (broadcast + in-process subscriptions). |
| `kiroku_pool_connections` | gauge | `state="connecting\|ready\|in_use"` | Pool connections by state. |
| `kiroku_pool_established_total` | counter | — | Pool connections established. |
| `kiroku_pool_terminated_total` | counter | — | Pool connections terminated. |
| `kiroku_notifier_reconnecting_total` | counter | — | Notifier reconnection attempts started. |
| `kiroku_notifier_reconnected_total` | counter | — | Notifier reconnections completed. |
| `kiroku_publisher_pool_errors_total` | counter | — | EventPublisher read-query pool errors. |
| `kiroku_subscription_db_errors_by_phase_total` | counter | `phase="load\|fetch\|save"` | Subscription database errors by phase. |
| `kiroku_subscriptions_started_total` | counter | — | Subscription workers started. |
| `kiroku_subscriptions_caught_up_total` | counter | — | Subscriptions that reached live mode. |
| `kiroku_subscriptions_paused_total` | counter | — | Subscription pauses (backpressure). |
| `kiroku_subscriptions_resumed_total` | counter | — | Subscription resumes after pause. |
| `kiroku_subscriptions_reconnecting_total` | counter | — | Subscription live-fetch reconnects. |
| `kiroku_subscriptions_retrying_total` | counter | — | Subscription event redeliveries. |
| `kiroku_subscriptions_dead_lettered_total` | counter | — | Events written to dead letters. |
| `kiroku_subscriptions_stopped_total` | counter | `reason="handler\|cancelled\|overflow\|crashed"` | Subscription stops by reason. |
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
are snake_case, but the per-event payload fields are **camelCase**:

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

## Try it

The package ships a self-verifying example that boots an ephemeral store, starts
the server, appends events, and checks every endpoint over real HTTP and a real
WebSocket. Running it is a test that the documented behavior holds:

```bash
cabal run kiroku-metrics-example
```

```text
[1/6] ephemeral postgres ready
[2/6] store + collector + metrics server on port 57277
[3/6] appended 3 events to orders-1
[4/6] HTTP /metrics, /prometheus, /health/live, /health/ready all OK
[5/6] WebSocket /ws/events received event eventType=OrderRefunded
[6/6] kiroku-metrics-example: all checks passed (snapshot global position = 4)
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
