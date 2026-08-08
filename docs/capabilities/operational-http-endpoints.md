---
title: "Operational HTTP endpoints: metrics, health, and event streaming"
type: Capability
description: "Serve in-process metrics as JSON and Prometheus exposition, liveness/readiness/detailed health, a subscription-status endpoint, and a WebSocket channel for live metrics and events, without pulling a web framework into the core library."
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
  - Kiroku.Metrics.Server
  - Kiroku.Metrics.Collector
  - Kiroku.Metrics.Health
  - Kiroku.Metrics.WebSocket
requires:
  - CAP-14
  - CAP-11
evidence:
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

## Usage

```haskell
let settings = defaultConnectionSettings connString
      & #eventHandler .~ metricsEventHandler collector
withMetricsServerWithStore settings store port $ \_ -> runApp
```

## Limits

- The bare `startMetricsServer` mounts a **rejecting `stubWebSocketApp`** ("not yet implemented");
  the real WebSocket/event-streaming path is only mounted by `startMetricsServerWithStore`, which
  binds an actual `KirokuStore`. Choose the store-backed starter if you want the live socket.
- The self-verifying `kiroku-metrics-example` executable is gated behind the `-fexample` flag
  (default **off**) because its `ephemeral-pg` / `kiroku-test-support` dependencies are not on
  Hackage.
- The collector is STM-only and non-blocking; snapshots are point-in-time.
