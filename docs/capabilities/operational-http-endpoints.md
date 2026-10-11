---
title: "Operational HTTP endpoints: metrics, health, and event streaming"
type: Capability
description: "Serve in-process metrics as JSON and Prometheus exposition, liveness/readiness/detailed health, a subscription-status endpoint, durable cross-process checkpoint inventory, and a WebSocket channel for live metrics and events, bounded stream/category/event and subscription dead-letter inspection in the unreleased cohort, with host-configured default-off browser CORS, without pulling a web framework into the core library."
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
  the real WebSocket/event-streaming path is only mounted by `startMetricsServerWithStore`, which
  binds an actual `KirokuStore`. Choose the store-backed starter if you want the live socket.
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
