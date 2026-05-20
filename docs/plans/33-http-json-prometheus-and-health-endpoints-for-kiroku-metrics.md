---
id: 33
slug: http-json-prometheus-and-health-endpoints-for-kiroku-metrics
title: "HTTP JSON Prometheus And Health Endpoints For Kiroku Metrics"
kind: exec-plan
created_at: 2026-05-20T04:16:54Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
master_plan: "docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md"
---

# HTTP JSON Prometheus And Health Endpoints For Kiroku Metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is the second of four child plans under the MasterPlan
`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`. It
**hard-depends on EP-1**
(`docs/plans/32-kiroku-metrics-package-foundation-and-in-process-metrics-collector.md`),
which must be Complete first: this plan renders the `MetricsSnapshot` value and
reads it through the `KirokuMetrics` collector that EP-1 defines. This plan owns
the MasterPlan Integration Point IP-3 (the Warp server and the WebSocket-handler
seam); EP-3 fills that seam.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store; EP-1 added the package
`kiroku-metrics` with an in-process metrics collector (`KirokuMetrics`) and an
immutable, JSON-encodable `MetricsSnapshot` you can read at any time with
`snapshotMetrics`. What is still missing is a way to *reach those metrics over
the network*.

After this plan, a developer who has a running `KirokuStore` and a wired-in
`KirokuMetrics` collector can start a small HTTP server (the Warp web server) on
a configurable port and observe:

- `GET /metrics` → the whole snapshot as JSON.
- `GET /metrics/<subscription-name>` → the per-subscription slice as JSON, or 404
  if that subscription has never been seen.
- `GET /metrics/prometheus` → the snapshot rendered in Prometheus
  text-exposition format (the format a Prometheus server scrapes), which
  `promtool check metrics` accepts.
- `GET /health/live` → a fast liveness probe (HTTP 200 when the process and
  collector are responsive, 503 otherwise).
- `GET /health/ready` → a readiness probe (HTTP 200 when no subscription is
  overflow-stopped or lagging beyond a threshold and all configured dependency
  checks pass, 503 otherwise).
- `GET /health` → a detailed, human-readable health document combining the
  readiness verdict with the metrics snapshot.

You can *see it working* by starting the server in `ghci` or a tiny `main`,
appending events, and running `curl` against each endpoint — transcripts are in
Validation and Acceptance — and by piping the Prometheus output through
`promtool check metrics`.

This plan also builds the **combined WAI application** with a WebSocket-upgrade
seam (using `websocketsOr`, exactly as `shibuya-metrics` does) but leaves the
WebSocket handler as a documented stub. EP-3
(`docs/plans/34-websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store.md`)
replaces the stub without changing the server's structure.


## Progress

- [ ] M1: Web dependencies added to `kiroku-metrics.cabal`; `Kiroku.Metrics.Config` (config record + `defaultConfig`) and `Kiroku.Metrics.Server` (Warp server, `websocketsOr` with stub WS handler, `MetricsServer` handle, `start/stop/withMetricsServer`) compile; server starts and a placeholder route responds.
- [ ] M2: `Kiroku.Metrics.JSON` — `GET /metrics` and `GET /metrics/<name>` return snapshot JSON; verified with `curl`.
- [ ] M3: `Kiroku.Metrics.Prometheus` — `GET /metrics/prometheus` returns valid text-exposition; verified with `promtool check metrics`.
- [ ] M4: `Kiroku.Metrics.Health` — `/health/live`, `/health/ready`, `/health` with `DependencyCheck` list and a built-in `postgresPing`; verified with `curl` and status codes; an integration test covering all endpoints passes.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The server takes only `KirokuMetrics` plus a `[DependencyCheck]` and a
  `WS.ServerApp`; it does **not** take the `KirokuStore` directly.
  Rationale: Everything store-specific is captured in closures the caller builds —
  the `postgresPing` dependency check closes over the store's pool, and (in EP-3)
  the WebSocket app closes over the store. Keeping the store out of the server
  signature minimizes coupling and makes the seam EP-3 fills a single value
  (`WS.ServerApp`).
  Date: 2026-05-19

- Decision: Hand-roll Prometheus text exposition instead of depending on
  `prometheus-client`.
  Rationale: Matches the MasterPlan Decision Log and what `shibuya-metrics`
  actually does; keeps the snapshot the single source of truth and avoids a global
  registry. Output is validated with `promtool check metrics`.
  Date: 2026-05-19


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What EP-1 delivered (your inputs)

EP-1 created the package `kiroku-metrics` (directory `kiroku-metrics/`, Cabal file
`kiroku-metrics/kiroku-metrics.cabal`) with these public modules:

- `Kiroku.Metrics.Types` — the immutable snapshot:

  ```haskell
  data MetricsSnapshot = MetricsSnapshot
    { store         :: !StoreGauges
    , counters      :: !LifecycleCounters
    , subscriptions :: !(Data.Map.Strict.Map Text SubscriptionMetrics)
    }
  data StoreGauges = StoreGauges
    { globalPosition, poolEstablishedTotal, poolTerminatedTotal :: !Int64
    , activeSubscribers, poolConnecting, poolReady, poolInUse :: !Int }
  data LifecycleCounters = LifecycleCounters { {- many !Int64 counters -} }
  data SubscriptionMetrics = SubscriptionMetrics
    { lastKnownPosition, lag, dbErrorCount :: !Int64, lastStopReason :: !(Maybe Text) }
  instance ToJSON MetricsSnapshot   -- and for the sub-records
  ```

  (The full field list is in EP-1's Plan of Work / Interfaces sections. Treat the
  field names there as authoritative when rendering Prometheus.)

- `Kiroku.Metrics.Collector` — `data KirokuMetrics` (opaque),
  `snapshotMetrics :: KirokuMetrics -> IO MetricsSnapshot`, plus the constructor
  and callback wrappers used to *populate* the collector (you do not need those
  here; the caller wires them when opening the store).

This plan reads metrics only through `snapshotMetrics`. It does not touch the
collector internals.

### The model to copy: `shibuya-metrics`

A near-identical package already exists for the Shibuya framework. Read it before
writing code; you will mirror its structure with kiroku types substituted. On disk:

- `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics/src/Shibuya/Metrics/Server.hs`
  — the combined WAI app via `Network.Wai.Handler.WebSockets.websocketsOr`, the
  HTTP path router, `MetricsServerConfig`, `start/stop/withMetricsServer`.
- `.../Shibuya/Metrics/Config.hs` — the configuration record and `defaultConfig`.
- `.../Shibuya/Metrics/JSON.hs` — the JSON path handlers and `jsonResponse` helper.
- `.../Shibuya/Metrics/Prometheus.hs` — hand-rolled text exposition with
  `# HELP`/`# TYPE` lines and label escaping.
- `.../Shibuya/Metrics/Health.hs` — liveness/readiness/detailed health,
  `DependencyCheck = IO DependencyStatus`, and the analysis of per-processor health.
- `.../Shibuya/Metrics/Types.hs` — the server handle (`MetricsServer { serverThread
  :: Async (), serverPort :: Port }`) and the WebSocket protocol types (the
  protocol types are EP-3's concern, not this plan's).

The key structural difference: Shibuya's handlers call `getAllMetricsIO master`;
ours call `snapshotMetrics metrics`. Shibuya's per-item key is `ProcessorId`; ours
is the subscription-name `Text`. Shibuya renders per-processor gauges; we render
store-level gauges, lifecycle counters, and per-subscription lag.

### Web libraries (all in the GHC 9.12 package set; `shibuya-metrics` uses them)

`warp` (the HTTP server: `Network.Wai.Handler.Warp`), `wai` (the `Application`
type and request/response), `wai-websockets`
(`Network.Wai.Handler.WebSockets.websocketsOr`), `websockets`
(`Network.WebSockets`, for the `ServerApp` type and the stub's
`rejectRequest`/`acceptRequest`), `http-types` (status codes and headers).
`hasql` + `hasql-pool` for the `postgresPing` dependency check.

If any of these is missing from the Nix package set when you run `nix build`, add
a `callHackageDirect`/`doJailbreak` entry in `nix/haskell-overlay.nix` mirroring
the existing entries, and note it in Surprises & Discoveries. They are common
packages and are very likely already present.


## Plan of Work

Four milestones.

### Milestone M1 — Web dependencies, configuration, and the server scaffold with a stubbed WebSocket seam

Scope: extend the Cabal file with web dependencies and the new modules; implement
`Kiroku.Metrics.Config` and `Kiroku.Metrics.Server` so a server can be started
and stopped, the WebSocket upgrade is wired through `websocketsOr` to a stub, and
a placeholder HTTP route responds. At the end you can start the server and get a
known response from one path; JSON/Prometheus/health arrive in later milestones.

Cabal changes (`kiroku-metrics/kiroku-metrics.cabal`): add to the `library`
`build-depends` — `warp >=3.4`, `wai >=3.2`, `wai-websockets >=3.0`,
`websockets >=0.13`, `http-types >=0.12`, `hasql >=1.10`, `hasql-pool >=1.2`,
`bytestring >=0.11`. Add to `exposed-modules` — `Kiroku.Metrics.Config`,
`Kiroku.Metrics.Server`, `Kiroku.Metrics.JSON`, `Kiroku.Metrics.Prometheus`,
`Kiroku.Metrics.Health`. Add the same web deps to the test-suite `build-depends`
where the integration test needs them (`warp`, `wai`, `http-types`, plus an HTTP
client such as `http-client >=0.7` to hit the endpoints; add it to the test-suite
deps and, if absent from Nix, to the overlay).

`Kiroku.Metrics.Config` (mirror `shibuya-metrics`' `Config.hs`):

```haskell
data MetricsServerConfig = MetricsServerConfig
  { port              :: !Int     -- default 9091 (shibuya defaults 9090; pick 9091 to avoid a clash)
  , enableJSON        :: !Bool    -- default True
  , enablePrometheus  :: !Bool    -- default True
  , enableWebSocket   :: !Bool    -- default True (the seam; EP-3 makes it functional)
  , wsPushIntervalUs  :: !Int     -- default 1_000_000 (1s); consumed by EP-3
  , wsMaxConnections  :: !Int     -- default 100; consumed by EP-3
  , readinessMaxLag   :: !Int64   -- default 10_000; a subscription lagging beyond this fails readiness
  , livenessTimeoutUs :: !Int     -- default 1_000_000 (1s)
  }
defaultConfig :: MetricsServerConfig
```

> `readinessMaxLag` is the kiroku analogue of Marten's `maxEventLag` (default 100
> there; we default higher because kiroku's lag is an *upper bound*, see EP-1's
> limitation note). `wsPushIntervalUs`/`wsMaxConnections` exist now so EP-3 needs
> no config change — IP-3 requires EP-3 to add no new *required* field.

`Kiroku.Metrics.Server`:

```haskell
data MetricsServer = MetricsServer { serverThread :: !(Async ()), serverPort :: !Int }

-- The seam: the WebSocket application is a parameter. EP-2 supplies a stub.
startMetricsServerWith
  :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> IO MetricsServer
startMetricsServer
  :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO MetricsServer
startMetricsServer cfg m deps = startMetricsServerWith cfg m deps stubWebSocketApp
stopMetricsServer :: MetricsServer -> IO ()
withMetricsServer  :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> (MetricsServer -> IO a) -> IO a

combinedApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> Application
combinedApp cfg m deps wsApp =
  WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps)

-- The stub: rejects the upgrade with a clear message. Replaced by EP-3.
stubWebSocketApp :: WS.ServerApp
stubWebSocketApp pending = WS.rejectRequest pending "WebSocket endpoint not yet implemented"
```

`httpApp` routes on `Network.Wai.pathInfo`:

- `["metrics"]` (when `enableJSON`) → JSON all (M2)
- `["metrics","prometheus"]` (when `enablePrometheus`) → Prometheus (M3) — note:
  match this *before* the single-segment `["metrics", name]` pattern so
  `prometheus` is not treated as a subscription name
- `["metrics", name]` (when `enableJSON`) → JSON one subscription (M2)
- `["health"]`, `["health","live"]`, `["health","ready"]` (when `enableJSON`) →
  health (M4)
- `["ws"]` (when `enableWebSocket`) → a 404 JSON body documenting that this path
  is a WebSocket upgrade endpoint (`use ws:// protocol`); the real upgrade is
  handled by `websocketsOr` above
- anything else → 404 JSON `{"error":"Not found"}`

For M1, the JSON/Prometheus/health branches can return a placeholder 200/501 so
the module compiles; you flesh them out in M2–M4. Start the server with
`Warp.runSettings (Warp.setPort cfg.port (Warp.setHost "*" Warp.defaultSettings))`
inside `Control.Concurrent.Async.async`, returning the `Async` handle.

Acceptance M1: in `ghci` (`cabal repl kiroku-metrics`) or a scratch `main`,
`withMetricsServer defaultConfig metrics [] $ \srv -> ...` starts; `curl
http://localhost:9091/ws` returns the documented 404; `curl
http://localhost:9091/anything` returns `{"error":"Not found"}`. (`metrics` here is
a collector from EP-1; in `ghci` you can build one against a real `withStore` or,
for a pure smoke test, use EP-1's `newKirokuMetricsWith` test seam with static
readers.)

### Milestone M2 — JSON endpoints

Scope: implement `Kiroku.Metrics.JSON` and wire it into `httpApp`. At the end,
`GET /metrics` returns the full snapshot JSON and `GET /metrics/<name>` returns
one subscription's metrics or 404.

```haskell
jsonApp :: KirokuMetrics -> Application                 -- routes /metrics and /metrics/<name>
jsonResponse :: Status -> LBS.ByteString -> Response    -- helper, application/json
```

`GET /metrics`: `snap <- snapshotMetrics m; respond (jsonResponse status200
(encode snap))`.

`GET /metrics/<name>`: look up `name` in `snap.subscriptions`; `Just sm` →
200 with `encode sm`; `Nothing` → 404 with `{"error":"subscription not
found","subscription":name}`.

Acceptance M2: `curl -s localhost:9091/metrics | jq .store.globalPosition` prints
the number of events appended; `curl -s localhost:9091/metrics/<name> | jq .lag`
prints a number for a known subscription; an unknown name returns HTTP 404.

### Milestone M3 — Prometheus endpoint

Scope: implement `Kiroku.Metrics.Prometheus` (hand-rolled text exposition) and
wire `/metrics/prometheus`. At the end the endpoint returns valid Prometheus text
that `promtool` accepts.

Mirror `shibuya-metrics`' `Prometheus.hs`: a `Data.ByteString.Builder` with
`# HELP`/`# TYPE` lines per metric followed by sample lines. Emit, at minimum:

```text
# HELP kiroku_events_appended_total Total events appended store-wide (gap-free global position).
# TYPE kiroku_events_appended_total counter
kiroku_events_appended_total <store.globalPosition>
# HELP kiroku_active_subscribers Currently registered subscribers.
# TYPE kiroku_active_subscribers gauge
kiroku_active_subscribers <store.activeSubscribers>
# HELP kiroku_pool_connections Pool connections by state.
# TYPE kiroku_pool_connections gauge
kiroku_pool_connections{state="connecting"} <store.poolConnecting>
kiroku_pool_connections{state="ready"} <store.poolReady>
kiroku_pool_connections{state="in_use"} <store.poolInUse>
# TYPE kiroku_pool_established_total counter
kiroku_pool_established_total <store.poolEstablishedTotal>
# TYPE kiroku_pool_terminated_total counter
kiroku_pool_terminated_total <store.poolTerminatedTotal>
# ... one counter per LifecycleCounters field, e.g.:
# TYPE kiroku_notifier_reconnecting_total counter
kiroku_notifier_reconnecting_total <counters.notifierReconnecting>
# ... subscription gauges, labelled by name:
# TYPE kiroku_subscription_position gauge
kiroku_subscription_position{subscription="<name>"} <sm.lastKnownPosition>
# TYPE kiroku_subscription_lag gauge
kiroku_subscription_lag{subscription="<name>"} <sm.lag>
# TYPE kiroku_subscription_db_errors_total counter
kiroku_subscription_db_errors_total{subscription="<name>"} <sm.dbErrorCount>
```

Escape label values exactly as `shibuya-metrics` does (`\` → `\\`, `"` → `\"`,
newline → `\n`). Use `text/plain; version=0.0.4; charset=utf-8` as the
content-type. The response body is `Builder.toLazyByteString`.

> Naming: Prometheus convention is `snake_case` metric names with a unit suffix
> and `_total` on counters. Keep names stable once shipped — they become a public
> contract for dashboards; EP-4 documents the full list.

Acceptance M3:

```bash
curl -s localhost:9091/metrics/prometheus | promtool check metrics
```

exits 0 with no complaints (`promtool` ships with the `prometheus` package; if
unavailable in the dev shell, validate the format by eye against the snippet above
and have the integration test assert that the body starts with `# HELP` and
contains `kiroku_events_appended_total`).

### Milestone M4 — Health endpoints and dependency checks

Scope: implement `Kiroku.Metrics.Health`, wire the three `/health*` routes, and
add a built-in PostgreSQL dependency check. Add an integration test exercising all
endpoints. At the end, liveness/readiness/detailed health behave correctly and
the test suite proves it.

```haskell
type DependencyCheck = IO DependencyStatus
data DependencyStatus = DependencyStatus
  { name :: !Text, healthy :: !Bool, latencyMs :: !(Maybe Int), errorMsg :: !(Maybe Text) }
  deriving stock (Eq, Show)   -- with ToJSON

-- Built-in dependency check: SELECT 1 through the store's pool.
postgresPing :: KirokuStore -> DependencyCheck

data LivenessStatus  = LivenessStatus  { alive :: !Bool }
data ReadinessStatus = ReadinessStatus { ready :: !Bool, lagOk :: !Bool, noOverflow :: !Bool, dependencies :: ![DependencyStatus] }
  -- both with ToJSON

checkLiveness  :: MetricsServerConfig -> KirokuMetrics -> IO LivenessStatus
checkReadiness :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO ReadinessStatus
```

- **Liveness**: `timeout cfg.livenessTimeoutUs (snapshotMetrics m)` → `alive =
  isJust result`. Proves the collector and store `TVar`s are reachable within the
  budget. Maps to HTTP 200/503.
- **Readiness**: take a snapshot; `noOverflow` = no subscription has
  `lastStopReason == Just "overflow"`; `lagOk` = every subscription's `lag <=
  cfg.readinessMaxLag`; run all `depChecks`; `ready = noOverflow && lagOk && all
  (.healthy) deps`. Maps to HTTP 200/503.
- **Detailed `/health`**: 200/503 by the readiness verdict, body combining the
  `ReadinessStatus` and the full snapshot.

`postgresPing store`: time a `Hasql.Pool.use (store.pool) (Session.sql "SELECT
1")`; on `Right` → `DependencyStatus "postgres" True (Just ms) Nothing`; on `Left
e` → `DependencyStatus "postgres" False (Just ms) (Just (pack (show e)))`.

Integration test (`kiroku-metrics/test/...`): reuse EP-1's `withTestStore` +
collector wiring; start the server on an ephemeral port (`port = 0` lets Warp pick
one — capture it via `setBeforeMainLoop`/`setPort 0` and Warp's assigned-port
hook, or bind a fixed high port and tolerate it); use an HTTP client
(`http-client`) to GET each endpoint and assert: `/metrics` is 200 and parses as
JSON with a numeric `store.globalPosition`; `/metrics/prometheus` is 200 and the
body contains `kiroku_events_appended_total`; `/health/live` is 200;
`/health/ready` is 200 when healthy; an unknown subscription path is 404. Append
events first and assert `globalPosition` increased; add a failing dependency check
and assert `/health/ready` is 503.

Acceptance M4: `cabal test kiroku-metrics` is green including the new
all-endpoints integration test.


## Concrete Steps

Run from the repository root inside `nix develop`.

1. M1: edit `kiroku-metrics/kiroku-metrics.cabal` (deps + exposed-modules), write
   `Kiroku.Metrics.Config` and `Kiroku.Metrics.Server`, then:

   ```bash
   cabal build kiroku-metrics
   ```

2. Smoke-test the server manually. In one terminal:

   ```bash
   cabal repl kiroku-metrics
   ```
   ```haskell
   -- inside ghci, with a collector `m` built from a real store (see EP-1):
   srv <- startMetricsServer defaultConfig m []
   ```
   In another terminal:

   ```bash
   curl -i http://localhost:9091/ws
   curl -i http://localhost:9091/nope
   ```

   Expected: `/ws` → 404 with a JSON note about the WebSocket protocol; `/nope` →
   404 `{"error":"Not found"}`.

3. M2: implement `Kiroku.Metrics.JSON`, wire routes, rebuild, and:

   ```bash
   curl -s http://localhost:9091/metrics | jq .
   ```

   Expected (abridged):

   ```json
   {
     "store": { "globalPosition": 12, "activeSubscribers": 1, "poolReady": 9, "poolInUse": 1, "...": "..." },
     "counters": { "subscriptionsStarted": 1, "...": "..." },
     "subscriptions": { "my-projection": { "lastKnownPosition": 12, "lag": 0, "dbErrorCount": 0, "lastStopReason": null } }
   }
   ```

4. M3: implement `Kiroku.Metrics.Prometheus`, wire the route, rebuild, and:

   ```bash
   curl -s http://localhost:9091/metrics/prometheus | head
   curl -s http://localhost:9091/metrics/prometheus | promtool check metrics && echo "promtool OK"
   ```

   Expected: `# HELP`/`# TYPE` lines then samples; `promtool OK`.

5. M4: implement `Kiroku.Metrics.Health`, wire routes, add the integration test,
   then:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9091/health/live   # 200
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9091/health/ready  # 200
   curl -s http://localhost:9091/health | jq .ready
   cabal test kiroku-metrics
   ```

6. Commit after each milestone with all three trailers:

   ```text
   feat(kiroku-metrics): add JSON metrics endpoints

   MasterPlan: docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md
   ExecPlan: docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md
   Intention: intention_01ks1saptfe6j8e98dvce7mvgf
   ```


## Validation and Acceptance

Complete when:

1. `cabal build kiroku-metrics` and `nix build .#kiroku-metrics` succeed.
2. `cabal test kiroku-metrics` is green, including the all-endpoints integration
   test (EP-1's specs continue to pass).
3. Behavioral, observable with `curl` against a running server backed by a real
   store with appended events:
   - `GET /metrics` → 200, JSON, `store.globalPosition` equals the number of
     appended events.
   - `GET /metrics/<known-subscription>` → 200 with that subscription's metrics;
     `GET /metrics/<unknown>` → 404.
   - `GET /metrics/prometheus` → 200, body passes `promtool check metrics` (or, if
     `promtool` is unavailable, the integration test asserts the body begins with
     `# HELP` and contains `kiroku_events_appended_total`).
   - `GET /health/live` → 200 while running; `GET /health/ready` → 200 when no
     subscription is overflow-stopped and none lags beyond `readinessMaxLag` and
     all dependency checks pass; flip to 503 by supplying a dependency check that
     returns `healthy = False` and observe `/health/ready` → 503.
4. The WebSocket seam is in place: `combinedApp`/`startMetricsServerWith` accept a
   `WS.ServerApp`, `startMetricsServer` uses the rejecting stub, and `GET /ws`
   returns the documented 404. EP-3 can replace the stub without touching the
   server structure.


## Idempotence and Recovery

All edits are additive and safe to repeat. Re-running `cabal build` is harmless.
If a web dependency is missing under Nix, add an overlay entry (mirroring existing
ones) and re-run `nix build`; record it in Surprises & Discoveries. Servers
started in `ghci` are torn down by `stopMetricsServer`/`withMetricsServer` (the
`bracket` form); if a manual `ghci` session leaks a bound port, `:r`/quitting
`ghci` releases it. The integration test uses an ephemeral database
(`EphemeralPg`) and an OS-assigned port (`port = 0`) to avoid collisions on repeat
runs.


## Interfaces and Dependencies

New modules in `kiroku-metrics`:

- `Kiroku.Metrics.Config` — `MetricsServerConfig (..)`, `defaultConfig`.
- `Kiroku.Metrics.Server` — `MetricsServer (..)`, `startMetricsServer`,
  `startMetricsServerWith`, `stopMetricsServer`, `withMetricsServer`,
  `combinedApp`, `stubWebSocketApp`, `httpApp`.
- `Kiroku.Metrics.JSON` — `jsonApp`, `jsonResponse`.
- `Kiroku.Metrics.Prometheus` — `prometheusApp` (+ internal renderers).
- `Kiroku.Metrics.Health` — `DependencyCheck`, `DependencyStatus (..)`,
  `LivenessStatus (..)`, `ReadinessStatus (..)`, `checkLiveness`,
  `checkReadiness`, `postgresPing`.

Update `Kiroku.Metrics` (umbrella) to re-export the server lifecycle, the config,
the health types, and `DependencyCheck`/`postgresPing` so a consumer needs one
import.

New libraries: `warp`, `wai`, `wai-websockets`, `websockets`, `http-types`,
`bytestring`, `hasql`, `hasql-pool` (library); `http-client` (test). Reused from
EP-1: `Kiroku.Metrics.Collector` (`KirokuMetrics`, `snapshotMetrics`),
`Kiroku.Metrics.Types` (`MetricsSnapshot` and sub-records). Reused from
`kiroku-store`: `KirokuStore (..)` (for `postgresPing` over `store.pool`).

Seam handed to EP-3 (IP-3): `startMetricsServerWith ... (wsApp :: WS.ServerApp)`
and `combinedApp ... wsApp`. EP-3 will provide a real `WS.ServerApp` (closing over
the `KirokuStore` and `KirokuMetrics`) and a convenience starter; it must not need
any new *required* field on `MetricsServerConfig` (the `ws*` fields already exist).
This plan must keep `kiroku-store` unchanged.
