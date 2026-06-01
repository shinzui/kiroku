---
id: 5
slug: metrics-and-event-streaming-http-endpoint-package
title: "Metrics And Event-Streaming HTTP Endpoint Package"
kind: master-plan
created_at: 2026-05-20T04:16:50Z
intention: "intention_01ks1saptfe6j8e98dvce7mvgf"
---

# Metrics And Event-Streaming HTTP Endpoint Package

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku is a PostgreSQL-backed event store. Its core library is the package
`kiroku-store` (modules under `Kiroku.Store.*`). Today the store has **no
metrics endpoint**: an operator who wants to know throughput, subscription
health, pool saturation, or notifier reconnect storms can only wire the two
in-process callbacks the store already exposes — `eventHandler :: Maybe
(KirokuEvent -> IO ())` and `observationHandler :: Maybe (Observation -> IO
())`, both fields on `Kiroku.Store.Connection.ConnectionSettingsM` — and build
their own counters and HTTP surface. There is no scrape target for Prometheus,
no JSON status endpoint, no health/readiness probe, and no way for an external
consumer to *watch events flow out of the store over the network*.

This initiative introduces that infrastructure as a **new package**,
`kiroku-metrics`, modelled on the existing `shibuya-metrics` package
(`mori://shinzui/shibuya/packages/shibuya-metrics`, on disk at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-metrics`) which
provides HTTP/JSON, Prometheus, and WebSocket metrics endpoints for the Shibuya
queue framework. The package is a *sister* package to `kiroku-store` in the same
spirit as the existing `kiroku-otel` package: it depends on `kiroku-store` and
the web libraries, but `kiroku-store` gains **no new dependency** and ideally
**no code change at all**, because the callback seams and public read accessors
needed to observe the store already exist (`eventHandler`, `observationHandler`,
`Kiroku.Store.Subscription.EventPublisher.publisherPosition`, and the public
`EventPublisher` subscriber registry).

After the whole initiative is complete, a developer who has a running
`KirokuStore` can:

- Construct an in-process **metrics collector** that consumes the store's
  existing `KirokuEvent` and `Observation` callbacks plus a couple of public
  read accessors, and produce an atomic **metrics snapshot** at any time (total
  events appended store-wide, active subscriber count, pool connection stats,
  and lifecycle counters: notifier reconnects, publisher pool errors,
  per-phase subscription database errors, subscriptions started / caught-up /
  stopped by reason, hard-deletes issued, and per-subscription positions plus
  **lag** — the gap between the store's global position and each subscription's
  last-known position, the Marten/EventStoreDB readiness signal described in the
  Decision Log).
- Start a small HTTP server (Warp) on a configurable port and observe:
  `GET /metrics` returning the snapshot as JSON; `GET /metrics/prometheus`
  returning Prometheus text-exposition format that `promtool` accepts and a
  Prometheus server can scrape; `GET /health/live` and `GET /health/ready`
  returning Kubernetes-style probes (200 / 503) plus `GET /health` for a
  detailed human-readable status.
- Connect a WebSocket client to the same server and (a) receive a metrics
  snapshot followed by periodic live metric updates, and (b) — the strategic
  payoff of building this infrastructure — **subscribe to the store's live
  event stream and receive each appended `RecordedEvent` as JSON over the
  socket**, optionally filtered to a category or replayed from a chosen global
  position. This turns the event store into something a browser dashboard, a
  CLI tail, or a non-Haskell service can watch in real time without writing a
  Haskell subscription.
- Point the existing **operator CLI** (`kiroku-cli`, the `kiroku` binary) at a
  *running worker* and inspect its **live subscription registry** over the
  network: `kiroku subscriptions status --remote-url http://worker:9091` (or
  `KIROKU_REMOTE_URL`) issues `GET /subscriptions` to that worker's metrics server
  and renders each subscription's name, consumer-group member, current FSM phase
  (`catching_up`/`live`/`paused`/`reconnecting`/`retrying`), and current global
  cursor — using the same table/JSON renderer the in-process command already uses.
  The standalone `kiroku` binary becomes a **pure remote client**: its previous
  local mode (open the binary's *own* store and read a registry that is always
  empty, because the binary runs no subscriptions) is **removed**, along with the
  `--database-url`/`--schema`/`--pool-size` options. The legitimate in-process case
  stays in the embeddable library (`renderKirokuCommandWithStore`, handed the host
  worker's own store). This is the operator-facing payoff of putting an HTTP
  surface on the worker.
- Read a self-contained user guide and run a single example program that boots
  an ephemeral store, starts the server, appends events, and prints the curl
  and `websocat` transcripts that prove every endpoint works.

**In scope:**

- A new `kiroku-metrics` Cabal package wired into `cabal.project`, `flake.nix`,
  `nix/haskell-overlay.nix`, and `mori.dhall`.
- An in-process metrics collector and an immutable, JSON-encodable snapshot
  type, driven entirely by the store's existing public callback seams and read
  accessors (no `kiroku-store` source change required).
- HTTP/JSON metrics endpoints, a Prometheus text-exposition endpoint, and
  liveness/readiness/detailed health endpoints with pluggable dependency
  checks (a PostgreSQL ping is the built-in one).
- A WebSocket endpoint that pushes live metric updates **and** streams events
  out of the store, with a small JSON message protocol for both.
- A `GET /subscriptions` (and `GET /subscriptions/<name>`) HTTP endpoint that
  reports a worker's **live subscription registry** (read through the public
  `Kiroku.Store.Subscription.subscriptionStates`), plus a `--remote-url` mode on
  the `kiroku-cli` operator command that queries it. The endpoint lives in
  `kiroku-metrics`; the client lives in `kiroku-cli`; the shared wire shape is the
  CLI's existing `SubscriptionStatusRow` JSON.
- A user guide (`docs/user/metrics.md`, linked from `docs/user/README.md` and
  cross-linked from `docs/user/observability.md`) and a runnable, tested
  example program.

**Explicitly out of scope:**

- Instrumenting the hot append/read path inside `kiroku-store` with per-call
  counters or latency histograms. Auto-memory `project_append_perf_constraints.md`
  records that round-trip count dominates append cost and that singleton-SQL and
  round-trip-restructuring experiments were ruled out by benchmark; we will not
  add synchronous work to that path. Throughput is instead derived for free from
  the monotonic, gap-free global position (`publisherPosition` == total events
  ever appended store-wide). Per-operation counters via an optional *wrapping*
  `Store` interpreter are recorded as possible future work, not built here.
- Authentication, TLS, and rate limiting on the metrics server. Like
  `shibuya-metrics`, the server is intended to bind on an internal network or
  behind a sidecar/ingress that terminates TLS and auth. The user guide states
  this deployment assumption.
- A pull-based historical event query API over HTTP (paginated `GET /events`).
  The WebSocket live tail plus optional position-replay covers the streaming
  use case; a REST read API is a separable follow-up noted in the Decision Log.
- Persisting any metrics. The collector is in-memory and resets on process
  restart; durability is Prometheus's job once it scrapes.
- An OpenTelemetry **metrics** bridge. The `iand675/hs-opentelemetry` checkout
  pinned in `cabal.project` *does* now carry a metrics API (Counter,
  UpDownCounter, Histogram, Gauge, ObservableGauge/Counter, an SDK
  `MetricReader`, an OTLP metric exporter, and a Prometheus exporter), but only
  on commits *after* the pinned `adc464b` (2025-12-30), on the breaking **api
  0.4** line, and unreleased to Hackage. Adopting it would force a repo-wide
  `hs-opentelemetry` 0.3→0.4 upgrade (pin bump, new `sdk`/`exporters/otlp`/
  `exporters/prometheus` source-repo-packages, nix-overlay entries, and
  `kiroku-otel` fixups). Per the Decision Log, this is **deferred**; the
  collector snapshot (IP-1) is deliberately shaped as the seam a future
  `kiroku-metrics-otel` sister package would read via `ObservableGauge`
  callbacks, so deferral costs nothing structurally.


## Decomposition Strategy

The initiative was decomposed by **functional concern** so each child plan
produces an independently verifiable behavior and the hard dependencies form a
short linear chain rather than a web.

1. **Package foundation + metrics source first (EP-1).** Every endpoint needs
   two things that do not exist yet: the `kiroku-metrics` package itself (with
   its build wiring so it compiles under both `cabal` and `nix`), and an
   in-process collector that turns the store's callback signals into a
   snapshot. These are consolidated into one foundation plan because the
   collector is the single source of truth all later plans read, and because
   creating the package and its snapshot type in one place keeps the build
   green from the first commit. EP-1 is verifiable entirely at the unit level
   (feed the collector a scripted `KirokuEvent`/`Observation` sequence and a
   fake store, snapshot, assert) and with one integration test that wires the
   collector into a real `withTestStore` and asserts after a real subscription
   runs. It needs no web dependency at all.

2. **HTTP endpoints next (EP-2).** With the collector and snapshot in place, the
   JSON, Prometheus, and health endpoints are pure renderings of a snapshot plus
   a Warp server. This plan adds the web dependencies to the package, defines the
   server handle and configuration, and — critically — builds the combined WAI
   application using `websocketsOr` with a **WebSocket-handler seam left as a
   stub**, so EP-3 can fill in the real WebSocket app without restructuring the
   server. EP-2 delivers a working scrape target verifiable with `curl` and
   `promtool`.

3. **WebSocket streaming last among the runtime plans (EP-3).** The WebSocket
   endpoint is the most novel piece and carries the dual purpose the user
   called out: live metric push *and* streaming events out of the store. It
   fills the EP-2 seam, adds the client/server message protocol, the live
   metrics push loop (mirroring `shibuya-metrics`' `WebSocket.hs`), and the
   event-stream tail built on the **public** `EventPublisher` broadcast
   (`subscribePublisher`) for "from-now" delivery and `readAllForward` for
   optional position-replay — neither of which pollutes the persistent
   `subscriptions` checkpoint table. It owns the `RecordedEvent` JSON wire
   encoding.

4. **Documentation and a runnable example (EP-4).** The endpoints carry real
   operational subtleties (the no-auth deployment assumption, the global-position
   throughput interpretation, the live-tail "from-now" semantics, the
   per-subscription-position limitation) that deserve a focused user guide plus a
   runnable, tested example so the docs are demonstrably correct rather than
   aspirational.

5. **Remote subscription status for the operator CLI (EP-5).** Added after the
   initial four-plan decomposition (see the Decision Log entry dated 2026-06-01).
   The `kiroku-cli` operator command can list live subscriptions only from its own
   process-local registry; it cannot inspect a running worker in another process.
   EP-5 closes that gap with a `GET /subscriptions` endpoint on the EP-2 server
   (reading the live registry through `subscriptionStates`) and a `--remote-url`
   client mode on the CLI. It is a distinct functional concern — operator
   introspection of a remote worker — that bridges two packages (`kiroku-metrics`
   server, `kiroku-cli` client) and reuses the **live registry**, a richer,
   more-current source than EP-1's callback-collector snapshot. It hard-depends on
   EP-2 (server, router, config) and is independent of EP-3 and EP-4. Keeping it
   separate from EP-2 lets the EP-2 scrape target ship and be proven first, and
   keeps the cross-package CLI concern out of EP-2's snapshot-rendering scope.

**Alternatives considered and rejected.** (a) *A single mega-plan*: rejected —
the work spans package creation, an in-memory collector, three HTTP renderings,
a WebSocket protocol with two distinct payload families, and docs; that is far
more than five milestones across unrelated modules, which the MasterPlan
guidance says to split. (b) *Putting the collector inside `kiroku-store`* (as
`shibuya-core` holds `Shibuya.Runner.Metrics`): rejected — Shibuya's runtime
*updates its holder inline*, so the holder must live in core; Kiroku's runtime
instead *emits callbacks*, so Kiroku's collector can be a pure external consumer
of public APIs. Keeping it in the new package leaves `kiroku-store`
dependency-light and unchanged, exactly as `kiroku-otel` is a sister package
that never touches core. (c) *Folding the WebSocket into EP-2*: rejected — the
event-streaming protocol is a first-class deliverable (the user's stated reason
for building this infrastructure) and is the riskiest part; isolating it makes
its design explicit and lets the HTTP scrape target ship and be proven first.
(d) *Splitting metrics-WebSocket from event-WebSocket into two plans*: rejected —
they share one Warp server, one `websocketsOr` upgrade, and one connection
lifecycle; separating them would duplicate the connection-management code and
create an artificial integration point. (e) *Folding the `/subscriptions`
endpoint + CLI remote client into EP-2*: rejected — it spans a second package
(`kiroku-cli`), reads a different data source (the live registry, not the
collector snapshot), and adds a cross-package dependency and an HTTP client; it is
a separable operator-facing concern best shipped after EP-2's scrape target is
proven. (f) *Reading subscription status from EP-1's `MetricsSnapshot.subscriptions`
map instead of the live registry*: rejected — the snapshot observes positions only
at lifecycle callback points and is shaped for lag/health, whereas the registry
reports the *current* FSM phase and cursor of every running subscription, which is
what an operator status command needs.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Kiroku-Metrics Package Foundation And In-Process Metrics Collector | docs/plans/32-kiroku-metrics-package-foundation-and-in-process-metrics-collector.md | None | None | Complete |
| 2 | HTTP JSON, Prometheus, And Health Endpoints For Kiroku Metrics | docs/plans/33-http-json-prometheus-and-health-endpoints-for-kiroku-metrics.md | EP-1 | None | Complete |
| 3 | WebSocket Endpoint For Live Metrics And Event Streaming Out Of The Store | docs/plans/34-websocket-endpoint-for-live-metrics-and-event-streaming-out-of-the-store.md | EP-2 | None | Complete |
| 4 | Kiroku Metrics And Event-Stream User Guide And Runnable Example | docs/plans/35-kiroku-metrics-and-event-stream-user-guide-and-runnable-example.md | EP-2 | EP-3, EP-5 | Not Started |
| 5 | Remote Subscription-Status HTTP Endpoint And Kiroku-CLI Remote Client | docs/plans/52-remote-subscription-status-http-endpoint-and-kiroku-cli-remote-client.md | EP-2 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The hard dependencies form a chain `EP-1 → EP-2 → {EP-3, EP-4, EP-5}`:

- **EP-2 hard-depends on EP-1.** The JSON, Prometheus, and health renderers are
  pure functions of the `MetricsSnapshot` type and read it through the
  `KirokuMetrics` collector handle, both defined by EP-1 in the new
  `kiroku-metrics` package. None of EP-2's rendering code type-checks before the
  snapshot type and `snapshotMetrics` accessor exist. EP-1 also creates the
  package and its build wiring (`cabal.project`, `flake.nix`,
  `nix/haskell-overlay.nix`, `mori.dhall`), without which EP-2 has no package to
  add web dependencies and modules to.

- **EP-3 hard-depends on EP-2.** The WebSocket app is mounted by the same Warp
  server through the `websocketsOr` upgrade that EP-2 builds in
  `Kiroku.Metrics.Server`. EP-2 deliberately leaves the WebSocket handler as a
  documented stub seam (IP-3); EP-3 fills it. EP-3 also reuses EP-2's
  configuration record and server handle. The live-metrics-push half of EP-3
  reads the same snapshot accessor as EP-2; the event-streaming half consumes
  the *public* `kiroku-store` APIs directly (`subscribePublisher`,
  `publisherPosition`, `readAllForward`), so it has no extra hard dependency
  beyond the server seam.

- **EP-4 hard-depends on EP-2 and soft-depends on EP-3 and EP-5.** The user guide
  and the runnable example need a working HTTP server to demonstrate (EP-2). The
  example is most compelling once the WebSocket event tail exists (EP-3) and the
  guide should document the `/subscriptions` endpoint and the CLI remote command
  (EP-5), so EP-4 should ideally follow both; but it can start against the HTTP
  endpoints as soon as EP-2 is complete and have its WebSocket and
  subscription-status sections filled in when EP-3 and EP-5 land.

- **EP-5 hard-depends on EP-2.** The `GET /subscriptions` endpoint mounts on the
  same Warp server and HTTP router (`Kiroku.Metrics.Server.httpApp`) and reuses
  the `MetricsServerConfig` that EP-2 builds; it adds the route through an optional
  subscription-status provider seam (IP-5) without changing EP-2's existing
  signatures. EP-5 reads the live registry through the *public*
  `Kiroku.Store.Subscription.subscriptionStates`, so it has no extra hard
  dependency beyond the server. It is independent of EP-1's collector (it does not
  read `MetricsSnapshot`) and of EP-3's WebSocket seam.

**Parallelism:** Only EP-1 can start immediately. After EP-1 completes, EP-2 is
the sole next step. After EP-2 completes, EP-3, EP-4, and EP-5 may proceed in
parallel (EP-4 finishing its WebSocket section after EP-3 and its
subscription-status section after EP-5).


## Integration Points

These are the shared artifacts multiple child plans touch. Each names the owning
plan (which defines it) and how later plans consume it. Child plans must keep
these descriptions byte-consistent.

### IP-1 — `KirokuMetrics` collector + `MetricsSnapshot` type (owned by EP-1)

The single source of truth every endpoint reads. EP-1 defines, in the new
package `kiroku-metrics` (module `Kiroku.Metrics.Collector` and the snapshot
type in `Kiroku.Metrics.Types`):

```haskell
-- An opaque in-memory handle holding STM counters/gauges and a per-subscription map.
data KirokuMetrics

-- Construct a collector. Reads store-level gauges from the live store handle on snapshot.
newKirokuMetrics :: KirokuStore -> IO KirokuMetrics

-- Wrap into the store's existing callback seams; compose with a user callback.
-- Wire these into ConnectionSettings BEFORE withStore so the collector sees every event.
metricsEventHandler       :: KirokuMetrics -> Maybe (KirokuEvent  -> IO ()) -> (KirokuEvent  -> IO ())
metricsObservationHandler :: KirokuMetrics -> Maybe (Observation -> IO ()) -> (Observation -> IO ())

-- Read an atomic, immutable, JSON-encodable snapshot at any time.
snapshotMetrics :: KirokuMetrics -> IO MetricsSnapshot
```

`MetricsSnapshot` is an immutable record with a `ToJSON` instance. Its shape is
informed by the closest precedents (see Decision Log): Marten's
`FetchEventStoreStatistics` (a store-wide event/sequence count — for Kiroku the
gap-free `globalPosition` *is* both the highest sequence and the high water
mark) and `AllProjectionProgress` plus EventStoreDB persistent-subscription gap
stats (per-consumer **lag**). Concretely the snapshot carries: a `store` section
(`globalPosition`, `activeSubscribers`, pool connection gauges), a `counters`
section (one field per `KirokuEvent`-derived counter, listed in EP-1), and a
`subscriptions` map keyed by `SubscriptionName` with each subscription's
`lastKnownPosition`, derived `lag` (`globalPosition − lastKnownPosition`),
`dbErrorCount`, and `lastStopReason`. EP-2 renders this snapshot as JSON and
Prometheus and computes health from it; EP-3 pushes it over WebSocket. The lag
limitation (the collector observes a subscription's position only at
`Started`/`CaughtUp`/`Stopped` events, not per processed event, because the
store does not emit per-event progress) is owned and documented by EP-1 and
restated by EP-2's readiness check and EP-4's guide.

Note the distinction from EP-5's data source: this snapshot's `subscriptions` map
is **callback-derived** (positions observed only at lifecycle points, plus lag and
counters) and exists for metrics/health. EP-5's `/subscriptions` endpoint instead
reads the **live registry** (`Kiroku.Store.Subscription.subscriptionStates`),
which reports each subscription's *current* FSM phase and cursor from the worker's
live state cell. The two are complementary and EP-5 does not consume this snapshot
(see IP-5 and the Decision Log entry dated 2026-06-01).

### IP-2 — The `kiroku-metrics` package and its build wiring (owned by EP-1)

EP-1 creates `kiroku-metrics/kiroku-metrics.cabal` plus the source tree, and
registers the package in `cabal.project` (add `kiroku-metrics` to `packages:`),
`flake.nix` (add to the `packages` output set), `nix/haskell-overlay.nix` (add a
`callCabal2nix` entry mirroring `kiroku-otel`), and `mori.dhall` (add a
`Schema.Package` entry). EP-1 keeps the dependency footprint minimal (no web
libraries — only `base`, `stm`, `containers`, `text`, `time`, `aeson`,
`kiroku-store`). EP-2 extends the *same* cabal file's `build-depends` with the
web libraries (`warp`, `wai`, `wai-websockets`, `websockets`, `http-types`) and
adds its modules to `exposed-modules`; EP-3 adds one more module. Each plan must
keep the cabal file building after its own changes.

### IP-3 — The Warp server and WebSocket-handler seam (owned by EP-2, consumed by EP-3)

EP-2 builds `Kiroku.Metrics.Server` with the combined WAI application using
`Network.Wai.Handler.WebSockets.websocketsOr` (exactly as
`shibuya-metrics`' `Server.hs` does), routing the WebSocket upgrade to a handler
and everything else to the HTTP router. EP-2 defines the server handle
(`MetricsServer`), the configuration record (`MetricsServerConfig` with fields
including `port`, `enableJSON`, `enablePrometheus`, `enableWebSocket`,
`wsPushIntervalUs`, `wsMaxConnections`, health thresholds), and the lifecycle
functions (`startMetricsServer`, `stopMetricsServer`, `withMetricsServer`). The
WebSocket handler argument is a **stub** in EP-2 (it rejects the upgrade with a
clear "WebSocket not yet implemented" close, and the HTTP `["ws"]` path returns
a 404 documenting the protocol). EP-3 replaces the stub with the real
`Kiroku.Metrics.WebSocket.websocketApp` without changing the server's structure
or the config record. The config record is the shared contract: EP-3 reads
`wsPushIntervalUs`/`wsMaxConnections`/`enableWebSocket` but adds no new required
field (any event-stream tuning it needs gets a defaulted field so EP-2's
`defaultConfig` and existing call sites still compile).

EP-5 extends this same server with a second, independent seam: an **optional
subscription-status provider** (`Maybe (IO [SubscriptionStatusRow])`) threaded
through `httpApp`/`combinedApp` to serve `GET /subscriptions`. Like the WebSocket
seam, it adds no required `MetricsServerConfig` field and leaves EP-2's existing
starters working (the provider defaults to `Nothing`, and `/subscriptions` then
returns a configured-404). EP-5 adds the 5-argument `startMetricsServerWith'` and
a `withMetricsServerSubscriptions` convenience without altering EP-2's or EP-3's
entry points. See IP-5.

### IP-4 — Event-stream WebSocket protocol + `RecordedEvent` JSON encoding (owned by EP-3)

EP-3 owns the WebSocket message protocol (a tagged-JSON `ClientMessage` /
`ServerMessage` family covering both the metrics channel and the event-stream
channel) and the wire encoding of `RecordedEvent`. `RecordedEvent`
(`Kiroku.Store.Types`) has **no `ToJSON` instance** today and `kiroku-store`
deliberately keeps its `Types` module instance-light. To avoid an orphan
instance leaking from a library, EP-3 defines an explicit encoder function
`recordedEventToJSON :: RecordedEvent -> Data.Aeson.Value` inside the
`kiroku-metrics` package (not a typeclass instance), reading the public
`RecordedEvent` fields. EP-4's guide documents the on-the-wire JSON shape this
function produces. Should a `ToJSON RecordedEvent` instance later be wanted on
the public surface, the Decision Log notes adding it to `kiroku-store` as the
non-orphan home; EP-3 does not add it there to keep the dependency direction
one-way (`kiroku-metrics` → `kiroku-store`).

### IP-5 — Subscription-status wire JSON contract + the server provider seam (owned by EP-5)

EP-5 owns the subscription-status wire shape and the way the endpoint is fed. The
wire shape is the CLI's **existing** local-status JSON — a JSON array of objects
`{subscription, member, phase, global_position}` — defined once by the `ToJSON`/
`FromJSON` instances of `SubscriptionStatusRow` in
`kiroku-cli/src/Kiroku/Cli/Subscription/Status.hs`. This is the single source of
truth for the shape, consumed two ways:

- **Server (`kiroku-metrics`):** `Kiroku.Metrics.Subscriptions.subscriptionsApp`
  serves `GET /subscriptions` and `GET /subscriptions/<name>` by running an
  injected `type SubscriptionStatusProvider = IO [SubscriptionStatusRow]` and
  encoding the rows with the shared `ToJSON`. The canonical provider is
  `storeSubscriptionStatus store = subscriptionStatusRows <$> subscriptionStates
  store`, built by the caller who owns the `KirokuStore` (so the server stays
  store-agnostic, per IP-3 and EP-2's design). To reuse the row type and encoder,
  `kiroku-metrics` gains a `build-depends` on `kiroku-cli`; the direction
  `kiroku-metrics → kiroku-cli → kiroku-store` has no cycle.

- **Client (`kiroku-cli`):** `kiroku subscriptions status --remote-url URL`
  GETs `<URL>/subscriptions`, decodes `[SubscriptionStatusRow]` with the shared
  `FromJSON`, and renders with the existing `renderSubscriptionStatusRows`. The
  CLI adds only `http-client`/`http-client-tls` (it does **not** depend on
  `kiroku-metrics`); it stays web-server-free.

EP-4's guide documents the on-the-wire JSON shape and the CLI remote command. A
round-trip test (`decode . encode == id`) and a cross-package shape test keep the
two sides byte-consistent.


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1: `kiroku-metrics` package created and wired into `cabal.project`, `flake.nix`, `nix/haskell-overlay.nix`, `mori.dhall` (builds empty under cabal; flake evaluates via `nix build --dry-run`)
- [x] EP-1: `MetricsSnapshot` type + `KirokuMetrics` collector + callback wrappers + `snapshotMetrics`; unit test feeding scripted events (8 examples)
- [x] EP-1: Integration test wiring the collector into a real `withMigratedTestDatabase`, running a subscription, asserting counters/positions/lag
- [x] EP-2: Web dependencies added; `Kiroku.Metrics.Server` Warp server with `websocketsOr` and a stubbed WebSocket seam; `MetricsServerConfig`/`MetricsServer` lifecycle
- [x] EP-2: JSON endpoints (`/metrics`, `/metrics/:subscription`) rendering the snapshot
- [x] EP-2: Prometheus text-exposition endpoint (`/metrics/prometheus`) — `promtool` absent from the dev shell, so format validated by eye + integration-test substring assertion
- [x] EP-2: Health endpoints (`/health/live`, `/health/ready`, `/health`) with pluggable dependency checks (PostgreSQL ping built in)
- [x] EP-3: WebSocket protocol types + metrics channel (snapshot on connect, periodic live updates), filling the EP-2 seam (`startMetricsServerWithStore` wires the real `websocketApp`)
- [x] EP-3: Event-stream channel — live "from-now" tail via `subscribePublisher` (`DropOldest`, `wsEventQueueCap`), optional category filter and replay-from-position via `readAllForward`/`readCategory`; `recordedEventToJSON`
- [x] EP-3: End-to-end WebSocket test (append events, observe event messages in order + metric snapshot over a real socket) + a replay-then-live test; `nix build .#kiroku-metrics` green after a `wai-websockets` overlay fix
- [ ] EP-4: `docs/user/metrics.md` guide (endpoints, JSON shapes, Prometheus names, WebSocket protocol, no-auth deployment assumption, lag limitation), linked from `docs/user/README.md` and `docs/user/observability.md`
- [ ] EP-4: Runnable, tested example program (ephemeral store → server → append → curl + WebSocket transcripts)
- [x] EP-5: `GET /subscriptions` + `GET /subscriptions/<name>` on the EP-2 server, reading the live registry through an optional provider seam (`startMetricsServerWith'`/`withMetricsServerSubscriptions`); shared `SubscriptionStatusRow` JSON codec in `kiroku-cli`
- [x] EP-5: `kiroku subscriptions status --remote-url URL` (or `KIROKU_REMOTE_URL`) fetches and renders the endpoint over HTTP (reusing the existing renderer); standalone binary is now a pure remote client (DB options/`withStore` removed), opening no local store
- [x] EP-5: Round-trip + exact-keys + cross-package shape + end-to-end tests (boot store + subscription + server, assert the CLI remote command reports the live subscription at phase `live`, cursor 3); `nix build .#kiroku-cli .#kiroku-metrics` green


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery (2026-05-19, during decomposition research): `kiroku-store` requires
  **no source change** for any of this work. The store already exposes every seam
  the collector needs — `eventHandler`/`observationHandler` callback fields on
  `Kiroku.Store.Connection.ConnectionSettingsM`, the public
  `Kiroku.Store.Subscription.EventPublisher.publisherPosition`, the public
  `EventPublisher` record with its `subscribers :: TVar (IntMap Subscriber)`
  field (count via `IntMap.size`), and the public `subscribePublisher` /
  `Kiroku.Store.Read.readAllForward` for event streaming. This is what makes the
  sister-package decomposition (like `kiroku-otel`) clean.

- Discovery (2026-05-19): `iand675/hs-opentelemetry` gained a full metrics
  implementation (commit `8a4ed7a`, *"feat: metrics implementation (API + SDK +
  exporters + build scaffolding) (#219)"*) including a Prometheus exporter, but
  only *after* the commit `adc464b` (2025-12-30) currently pinned in
  `cabal.project`, and on the breaking **api 0.4** line (commit `dd7b634`),
  unreleased to Hackage. See the Decision Log entry on deferring the OTel bridge.

- Discovery (2026-06-01, motivating EP-5): since the initial decomposition,
  `kiroku-store` gained a **live subscription registry** —
  `subscriptionRegistry :: TVar (Map (SubscriptionName, Int32) (Unique, TVar
  SubscriptionState))` on `KirokuStore` (`Kiroku.Store.Connection`), read by the
  public `Kiroku.Store.Subscription.subscriptionStates :: KirokuStore -> IO (Map
  (SubscriptionName, Int32) SubscriptionStateView)`. Each entry's `TVar
  SubscriptionState` cell is written by the worker on every FSM transition, so the
  registry reports the *current* phase (`catching_up`/`live`/`paused`/
  `reconnecting`/`retrying`) and cursor of every running subscription; a stopped
  subscription is absent (its `finally` cleanup removes the token-guarded entry).
  This is a richer, more-current subscription source than EP-1's callback-derived
  `MetricsSnapshot.subscriptions` map, and it is exactly what an operator status
  command needs. The `kiroku-cli` package already consumes it in-process
  (`subscriptionStates` → `SubscriptionStatusRow`) but is limited to its own
  process-local registry. EP-5 exposes it over HTTP so the CLI can read a remote
  worker.


- Discovery (2026-06-01, during EP-1/M1 implementation): The
  `Kiroku.Store.Observability.KirokuEvent` taxonomy is **richer than the original
  decomposition assumed**. Every subscription lifecycle constructor now carries a
  trailing `SubscriptionGroupContext` (`NonGroup` | `GroupMember member size`),
  `KirokuEventSubscriptionDbError` has a 4th `SubscriptionGroupContext` field, and
  there are additional constructors: `KirokuEventSubscriptionPaused`, `...Resumed`,
  `...Reconnecting`, `...Fetched`, `...Delivered` (with `SubscriptionDeliveryPhase`),
  `...Retrying`, `...DeadLettered` (with `DeadLetterReason`). EP-1's `MetricsSnapshot`
  / `LifecycleCounters` (IP-1) is therefore being implemented against this fuller
  set — additive counters for the new events plus the original ones — so the IP-1
  shape EP-2/EP-3 consume is broader than the snippet in IP-1. The four public
  collector function signatures and the `MetricsSnapshot`/`ToJSON` contract are
  unchanged; the additions are extra `counters` fields, which IP-1 already permits
  as additive.

- Discovery (2026-06-01, EP-2 complete): The **IP-3 seam is live and ready for
  EP-3**. `Kiroku.Metrics.Server` exposes `startMetricsServerWith :: ... ->
  WS.ServerApp -> IO MetricsServer` and `combinedApp :: ... -> WS.ServerApp ->
  Application` built on `websocketsOr`; `startMetricsServer` wires the rejecting
  `stubWebSocketApp`. EP-3 supplies a real `WS.ServerApp` and a convenience starter
  without changing the server structure or adding a required `MetricsServerConfig`
  field (the `ws*` fields exist). For **EP-4**: the JSON wire keys are snake_case
  (`store.global_position`, `last_known_position`, …) and the shipped Prometheus
  metric names are enumerated in EP-2's Outcomes & Retrospective — EP-4's guide
  should document those exact names/keys. Two implementation notes that ripple
  outward: `postgresPing` uses `Hasql.Session.script` (no `Session.sql` in this
  hasql), and subscription db-error metrics are split into
  `kiroku_subscription_db_errors_by_phase_total{phase}` and
  `kiroku_subscription_db_errors_total{subscription}` to keep Prometheus label sets
  consistent.

- Discovery (2026-06-01, EP-3 complete): **IP-4 is now concrete and IP-3 is
  filled.** `Kiroku.Metrics.WebSocket` exposes `websocketApp :: MetricsServerConfig
  -> KirokuMetrics -> KirokuStore -> WebSocketState -> WS.ServerApp` (the
  `WebSocketState` arg is a small refinement of the IP-3 sketch so the connection
  limit is shared across connections), plus the recommended entry points
  `startMetricsServerWithStore` / `withMetricsServerWithStore` on
  `Kiroku.Metrics.Server`. EP-2's `startMetricsServer` (stub) and `defaultConfig`
  are unchanged; the only config addition is the defaulted `wsEventQueueCap ::
  Natural` (256). **For EP-4's guide:** the protocol envelope and metrics keys are
  snake_case (`from_position`, `event_stream_started`, …), but the per-event
  payload from `recordedEventToJSON` uses **camelCase** field names (`eventId`,
  `eventType`, `streamVersion`, `globalPosition`, `originalStreamId`,
  `originalVersion`, `payload`, `metadata`, `causationId`, `correlationId`,
  `createdAt`) — document both. The WebSocket paths are `/ws/metrics` and
  `/ws/events`; the event channel requires a `subscribe_events` message
  (`{from_position?, category?}`); there is no query-string variant. The
  **category** live path is implemented but lacks an automated test.

- Discovery (2026-06-01, EP-3, build wiring): the first full `nix build
  .#kiroku-metrics` exposed a pinned-nixpkgs breakage — `wai-websockets`'
  `wai-websockets-example` executable depends on `wai-app-static`, which fails to
  compile (a `crypton`/`memory` `ByteArrayAccess (Digest MD5)` skew). Fixed in
  `nix/haskell-overlay.nix` with `overrideCabal (_: { executableHaskellDepends =
  []; }) prev.wai-websockets` (the example exe is flag-gated off, so dropping its
  deps is safe; `dontCheck` did not help because it is an executable, not test,
  dep). This affects any package depending on `wai-websockets`, i.e. since EP-2.
  Also: a Nix flake only sees git-tracked files, so new sources must be `git
  add`-ed before `nix build`.

- Discovery (2026-06-01, EP-5 complete): **IP-5 is implemented and the provider seam
  composes cleanly with EP-3.** `Kiroku.Metrics.Server` now threads `Maybe
  SubscriptionStatusProvider` through `combinedApp`/`httpApp`; EP-2's Warp body became
  `startMetricsServerWith'` (5-arg) and every prior starter
  (`startMetricsServer`/`startMetricsServerWith`/EP-3's `startMetricsServerWithStore`)
  delegates with a `Nothing` provider, so no EP-2/EP-3 call site changed and no required
  `MetricsServerConfig` field was added. `kiroku-metrics` now depends on `kiroku-cli`
  (acyclic: `kiroku-metrics → kiroku-cli → kiroku-store`). Two build-wiring facts:
  `kiroku-cli` had to be **added to the overlay and the flake `packages`** (it was
  neither before), and the standalone-binary rework broke the existing `kiroku-cli`
  tests (the old `StandaloneOptions`/`StatusOptions` shapes), which were rewritten.
  **For EP-4's guide:** document `GET /subscriptions` and `GET /subscriptions/<name>`
  (JSON array of `{subscription, member, phase, global_position}`), the
  `kiroku subscriptions status --remote-url URL` / `KIROKU_REMOTE_URL` command, that the
  standalone binary is remote-only (no `--database-url`/`--schema`/`--pool-size`), and
  that an unwired provider yields `404 {"error":"subscription status not configured"}`.

## Decision Log

- Decision: Build the metrics/observability surface as a **new sister package**
  `kiroku-metrics` that depends on `kiroku-store`, rather than adding endpoints or
  a metrics holder inside `kiroku-store`.
  Rationale: The user asked for a new package and to look at `shibuya-metrics` for
  inspiration. `shibuya-metrics` is a separate package over `shibuya-core`, and
  Kiroku already follows the sister-package pattern with `kiroku-otel` (keeps
  `kiroku-store` free of the `hs-opentelemetry` dependency). The crucial
  asymmetry with Shibuya: Shibuya's runtime *updates an in-memory holder inline*
  (so `Shibuya.Runner.Metrics`/`Master` must live in core), whereas Kiroku's
  runtime *emits callbacks* (`KirokuEvent`, `Observation`). A Kiroku collector
  can therefore be a pure external consumer of public APIs, so the entire
  infrastructure — collector included — fits in the new package and
  `kiroku-store` stays unchanged.
  Date: 2026-05-19

- Decision: Decompose into **four** child plans (package+collector → HTTP
  endpoints → WebSocket+event-streaming → docs+example) with a linear
  `EP-1 → EP-2 → {EP-3, EP-4}` chain.
  Rationale: Functional-concern boundaries; each plan yields an independently
  verifiable behavior; the HTTP scrape target ships and is proven before the
  novel WebSocket/event-streaming work; docs follow the runtime. See Decomposition
  Strategy for alternatives rejected (mega-plan, collector-in-core,
  WebSocket-folded-into-HTTP, metrics-WS-split-from-event-WS).
  Date: 2026-05-19

- Decision: Shape the `MetricsSnapshot` after **Marten** and **EventStoreDB**
  precedent, the two closest mature event stores (Marten is also
  PostgreSQL-backed).
  Rationale: User asked to research them. Marten exposes
  `FetchEventStoreStatistics` (highest event sequence number + counts) and
  `AllProjectionProgress` (per-projection recorded position), and bases its async
  daemon health check on **lag** between each projection and the **high water
  mark** (`maxEventLag`, default 100). EventStoreDB's `GET /stats` returns node
  stats as JSON and its persistent-subscription stats expose the **gap** between
  consumer position and stream end (plus parked-message counts). Both converge on:
  a store-wide sequence/throughput figure, a per-consumer position, and a
  per-consumer **lag** as the primary health signal. Kiroku's global position is
  *gap-free* (documented in `Kiroku.Store.Types.GlobalPosition`), so unlike Marten
  it needs no separate high-water-mark to tolerate sequence gaps:
  `highWaterMark == globalPosition == publisherPosition`, and
  `lag = globalPosition − subscriptionPosition`. The snapshot and the readiness
  check (IP-1, EP-2) adopt this lag signal.
  Date: 2026-05-19

- Decision: **Defer** an OpenTelemetry **metrics** bridge; ship an OTel-free core
  and leave the collector snapshot as the seam.
  Rationale: The user raised leveraging `hs-opentelemetry`'s new metrics support.
  Investigation of the on-disk checkout showed the metrics API/SDK/exporters
  (including a Prometheus exporter) exist but landed in commit `8a4ed7a` (#219),
  *after* the pinned `adc464b` (2025-12-30) and on the breaking **api 0.4** line
  (`dd7b634`), and are unreleased to Hackage. Adopting them would force a
  repo-wide `hs-opentelemetry` 0.3→0.4 upgrade — bump the `cabal.project` git
  pin, add `sdk`/`exporters/otlp`/`exporters/prometheus` as source-repo-packages
  with matching nix-overlay entries, and fix `kiroku-otel` (pinned `api >=0.3 &&
  <0.4`) — i.e. an unreleased, recently-restructured dependency in the
  foundation. The user chose to **defer OTel and leave a seam**. The collector
  snapshot (IP-1) is the seam: a future `kiroku-metrics-otel` sister package can
  register `ObservableGauge`/`ObservableCounter` callbacks that read
  `snapshotMetrics` and export via OTLP and/or `hs-opentelemetry-exporter-prometheus`.
  Recorded as future work, not built here.
  Date: 2026-05-19

- Decision: Stream events out over WebSocket using the **public**
  `subscribePublisher` broadcast for a live "from-now" tail, with optional
  catch-up/replay via `readAllForward`; do **not** create a named, persistent
  subscription for transient WebSocket clients.
  Rationale: Kiroku subscriptions checkpoint by `SubscriptionName` in the
  `subscriptions` table; a transient socket tail using a fresh name would either
  replay the whole store from position 0 (bad) or leave orphan checkpoint rows.
  `EventPublisher.subscribePublisher` (a public function on an exposed module)
  delivers every newly-appended event to a bounded queue with **zero** checkpoint
  involvement — exactly a live tail. Historical replay from a chosen position
  reuses `Kiroku.Store.Read.readAllForward`. This keeps the event-streaming half
  of EP-3 on public APIs with no `kiroku-store` change and no checkpoint
  pollution.
  Date: 2026-05-19

- Decision: Derive throughput from the gap-free global position rather than
  instrumenting the append/read hot path.
  Rationale: Auto-memory `project_append_perf_constraints.md` records that
  round-trip count dominates append latency and that SQL-shape experiments were
  ruled out by benchmark; adding synchronous counter work to the interpreter is
  unwanted. `publisherPosition` already equals the cumulative count of events
  appended store-wide (gap-free), giving a free `kiroku_events_appended_total`
  counter. Per-operation counters via an optional *wrapping* `Store` interpreter
  are noted as future work.
  Date: 2026-05-19

- Decision: Render Prometheus text by hand (as `shibuya-metrics` actually does)
  rather than depending on `prometheus-client`.
  Rationale: `shibuya-metrics` lists `prometheus-client` but its `Prometheus.hs`
  hand-rolls the text-exposition format and does not use the library's global
  registry. Hand-rolling from the snapshot keeps EP-2 dependency-light, avoids a
  global mutable registry, and keeps the snapshot the single source of truth. The
  output is validated with `promtool check metrics`.
  Date: 2026-05-19


- Decision: Add a **fifth child plan (EP-5)** for a remote subscription-status
  HTTP endpoint plus a `kiroku-cli` `--remote-url` client, after the initial
  four-plan decomposition.
  Rationale: The user asked for an endpoint that lets the new `kiroku-cli`
  interrogate a *running worker* and inspect subscription status, using the live
  registry that tracks subscriptions in a `TVar`, modelled on how `shibuya` and
  `message-db-hs` expose what's running. This is a distinct operator-introspection
  concern that bridges two packages and reads a different data source than EP-1's
  collector, so it is a sibling plan hard-depending only on EP-2's server, not a
  change to EP-1/EP-2/EP-3. Both reference projects expose running state the same
  way — a `TVar` registry read on demand into immutable rows and served as JSON
  over warp/wai (`message-db-hs`'s `jsonMetricsApp`/`jsonSubscriptionApp`,
  `shibuya-metrics`'s `GET /metrics` from its processor registry) — which EP-5
  mirrors with `GET /subscriptions`.
  Date: 2026-06-01

- Decision: EP-5 reads the **live registry** (`subscriptionStates`), not EP-1's
  `MetricsSnapshot.subscriptions`, and serves it through an **optional provider
  closure** rather than passing the `KirokuStore` into the server.
  Rationale: The registry reports current phase and cursor per running
  subscription (written on every FSM transition); the collector snapshot is
  callback-derived and shaped for lag/health. EP-2 keeps the store out of the
  server signature on purpose (store-specific behavior lives in caller-built
  closures, like `postgresPing`); EP-5 follows that rule, so `/subscriptions` is
  fed by `storeSubscriptionStatus store = subscriptionStatusRows <$>
  subscriptionStates store` and the server stays store-agnostic. When no provider
  is wired the endpoint returns a configured-404, so EP-2's call sites compile
  unchanged.
  Date: 2026-06-01

- Decision: Keep one wire shape for subscription status — the CLI's existing
  `SubscriptionStatusRow` JSON (`{subscription, member, phase, global_position}`) —
  owned by `kiroku-cli`, with `kiroku-metrics` depending on `kiroku-cli` to reuse
  the encoder, and the CLI remote client decoding the same shape.
  Rationale: One codec, no drift; the local and remote CLI commands render through
  the identical `renderSubscriptionStatusRows`. The dependency direction
  `kiroku-metrics → kiroku-cli → kiroku-store` is acyclic (`kiroku-cli` does not
  depend on `kiroku-metrics`), and `kiroku-cli` stays web-server-free, adding only
  a light `http-client` for the remote call. See IP-5.
  Date: 2026-06-01

- Decision: As part of EP-5, convert the standalone `kiroku` binary into a **pure
  remote client** and **remove** its local store-opening mode and its
  `--database-url`/`--schema`/`--pool-size` options.
  Rationale: The standalone binary runs no subscriptions, so its local mode read
  an always-empty registry — it was useless (its own help text said so). Remote is
  the only sensible standalone behavior; the legitimate in-process read stays in
  the embeddable library API (`renderKirokuCommandWithStore`, given the host
  worker's own store). `app/Main.hs` is untouched because the
  `standaloneParserInfo`/`resolveStandaloneOptions`/`runStandaloneCommand`
  signatures are preserved; the endpoint resolves from `--remote-url` or the new
  `KIROKU_REMOTE_URL` env var. Decided with the user on 2026-06-01 (the standalone
  local mode was called out as useless).
  Date: 2026-06-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-06-01 — Added **EP-5** (`docs/plans/52-remote-subscription-status-http-endpoint-and-kiroku-cli-remote-client.md`):
  a `GET /subscriptions` / `GET /subscriptions/<name>` endpoint on the EP-2 metrics
  server (reading the live `subscriptionStates` registry through an optional
  provider seam) plus a `kiroku subscriptions status --remote-url URL` client mode,
  so the `kiroku-cli` operator command can inspect a running worker's live
  subscriptions over the network instead of only its process-local registry.
  Updated Vision & Scope (new capability + in-scope bullet), Decomposition Strategy
  (item 5 + rejected alternatives e/f), Exec-Plan Registry (new row 5; EP-4 soft
  dep += EP-5), Dependency Graph (`EP-1 → EP-2 → {EP-3, EP-4, EP-5}`), Integration
  Points (new **IP-5**; clarified IP-1's collector-vs-registry distinction;
  extended IP-3 to note EP-5's provider seam), Progress (three EP-5 milestones),
  Surprises & Discoveries (the live registry), and the Decision Log (three EP-5
  decisions). Modelled on how `shibuya-metrics` and `message-db-hs` expose their
  in-memory registries over warp/wai.

- 2026-06-01 — EP-5 scope sharpened (user decision): the standalone `kiroku` binary
  becomes a **pure remote client**. Its useless local store-opening mode and the
  `--database-url`/`--schema`/`--pool-size` options are **removed**; the endpoint
  resolves from `--remote-url` or `KIROKU_REMOTE_URL`. The legitimate in-process
  read stays in the embeddable library API (`renderKirokuCommandWithStore`).
  Reflected in EP-5 (plan 52) and in this MasterPlan's Vision & Scope and Decision
  Log.
