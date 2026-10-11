---
title: "Operational HTTP endpoints: metrics, health, and event streaming"
type: Capability
description: "Serve in-process metrics as JSON and Prometheus exposition, liveness/readiness/detailed health, a subscription-status endpoint, durable cross-process checkpoint inventory, and a WebSocket channel for live metrics and events, bounded stream/category/event and subscription dead-letter inspection in the unreleased cohort, with coded WebSocket errors, explicit metrics lifecycle, ordered overflow notices, bounded tail name resolution and host-configured default-off browser CORS, with discovery at /capabilities and standalone hosting through kiroku-inspect, without pulling a web framework into the core library."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-17
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-metrics
interface:
  - Kiroku.Metrics.Capabilities
  - Kiroku.Metrics.Standalone
  - Kiroku.Metrics.DeadLetters
  - Kiroku.Metrics.Browse
  - Kiroku.Metrics.Server
  - Kiroku.Metrics.Checkpoints
  - Kiroku.Metrics.Collector
  - Kiroku.Metrics.Cors
  - Kiroku.Metrics.Health
  - Kiroku.Metrics.WebSocket
requires:
  - CAP-14
  - CAP-11
evidence:
  - kind: test
    resource: kiroku-metrics/test/Test/CapabilitiesSpec.hs
    proves: Pinned discovery codecs describe actual provider wiring, configured switches, custom WebSockets, prefix mounts and CORS without invoking providers.
  - kind: test
    resource: kiroku-metrics/test/Test/StandaloneSpec.hs
    proves: A database URL serves store inspection and a real event tail with deterministic cleanup, bounded option resolution and executable signal/exit behavior.
  - kind: test
    resource: kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs
    proves: Additive frames, real stop/resume and resolved tails, sanitized failures, bounded FIFO cache, scoped workers and production overflow notices before survivors with cursor recovery.
  - kind: test
    resource: kiroku-store/test/Test/PublisherDropCounter.hs
    proves: Actual DropOldest batches increment the counter and retain newest data, other policies do not, and the legacy wrapper deregisters idempotently.
  - kind: test
    resource: kiroku-metrics/test/Test/DeadLettersSpec.hs
    proves: Read-only dead-letter pages preserve structured reasons, opaque cursors, HEAD and sanitized errors with mounted CORS and compatible legacy routes.
  - kind: test
    resource: kiroku-metrics/test/Test/BrowseSpec.hs
    proves: Bounded category/prefix stream pages, exclusive event cursors, batched name resolution, HEAD and structured validation through the shared server.
  - kind: test
    resource: kiroku-metrics/test/Test/CheckpointsSpec.hs
    proves: Durable rows survive stopped workers, quiescent inventories agree across store handles, live responses remain compatible, mounted WebSockets work, and supervised lifetimes clean up listeners.
  - kind: test
    resource: kiroku-metrics/test/Test/CorsSpec.hs
    proves: Disabled application identity, validated origins, cache-correct HTTP grants and preflights, and real WebSocket origin refusal before upgrade.
  - kind: test
    resource: kiroku-metrics/test/Test/IntegrationSpec.hs
    proves: The collector wired into a real ephemeral-Postgres-backed store with a live $all subscription produces a snapshot that reflects real store activity, not scripted inputs.
  - kind: test
    resource: kiroku-metrics/test/Test/WebSocketSpec.hs
    proves: The live WebSocket event/metrics channel streams from a running store.
  - kind: test
    resource: kiroku-metrics/test/Test/ServerSpec.hs
    proves: The JSON, Prometheus, and health HTTP endpoints serve their documented payloads.
  - kind: guide
    resource: docs/user/metrics.md
    proves: Wiring the collector handler and serving the endpoints.
---

# Operational HTTP endpoints: metrics, health, and event streaming

A sister package to `kiroku-store` that exposes operational surface over HTTP without a web
framework in the core. Wire `metricsEventHandler` into the
[observability event stream](observability-events.md), then serve JSON/Prometheus metrics,
liveness/readiness/detailed health (with a built-in `postgresPing`), a `/subscriptions` endpoint
reporting live [subscription](live-subscriptions.md) status, and a WebSocket channel for live
metrics and events (with optional replay).

The unreleased inspection cohort adds explicit, default-off CORS across HTTP, preflight
and WebSocket upgrades. Hosts configure validated origins with `Kiroku.Metrics.Cors`;
this is browser access policy, not authentication. It also adds
`GET /subscription-checkpoints`, exact persisted checkpoints with a same-snapshot
append frontier, independently of the process-local live registry. `ServerProviders`
and the four `...WithProviders` functions provide the common composition boundary;
legacy starter signatures remain available.

## Usage

```haskell
let cfg = defaultConfig{port = 9091}
withMetricsServerWithStore cfg collector store [postgresPing store] $ \_ -> runApp
```

## Limits

- The bare `startMetricsServer` mounts a **rejecting `stubWebSocketApp`** ("not yet implemented");
  store-backed starters and `storeServerProviders` mount the real channels. Custom hosts
  declare channels in `webSocketChannels`; discovery combines this with the enable switch.
- The self-verifying `kiroku-metrics-example` executable is gated behind the `-fexample` flag
  (default **off**) because its `ephemeral-pg` / `kiroku-test-support` dependencies are not on
  Hackage.
- Durable checkpoint inventory is unpaginated and proportional to checkpoint row count; avoid overlapping client polls.
- The collector is STM-only and non-blocking; snapshots are point-in-time.

The unreleased cohort also adds `StoreBrowser` and the bounded `/streams`,
`/categories`, and `/events` inspection routes. Stream-name pages use stable
UTF-8 byte order, category enumeration retains locale order, and event items
include an additive `original_stream_name`. This feature's exact index-layout
write-cost acceptance and publication remain pending.

The unreleased `GET`/`HEAD /subscriptions/<name>/dead-letters` route wraps
`subscriptionDeadLetters`. All-member work scales with historical member count
times page size; prefer member-scoped polling for large groups.

The unreleased WebSocket convergence retains the shipped dialect and documents
its convention mapping in the guide. Metrics pushes can stop and resume; event
tails resolve original names with at most one lookup per batch and 4096 cached
names. Coded errors sanitize failures. Real drop-oldest overflow is signalled
before survivors, so clients recover from their last contiguous pre-notice cursor.
Cumulative append-under-observer performance acceptance remains with the release.

The unreleased cohort is self-describing at `/capabilities` and self-hosting through
`kiroku-inspect`. The executable opens a migrated store and serves read routes,
but runs no subscriptions: its live registry and per-worker metrics are empty.
Discovery labels process-local answers and performs no database access.
