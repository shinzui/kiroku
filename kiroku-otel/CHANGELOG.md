# kiroku-otel changelog

## Unreleased

### Added — subscription-state tracing (`Kiroku.Otel.Subscription`, MasterPlan 6 EP-5)

- `subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` — a ready-made
  `eventHandler` callback that turns the subscription worker's finite-state
  lifecycle into OpenTelemetry spans. Install it on `ConnectionSettings`
  (or a per-subscription) `eventHandler` and every subscription emits spans.
- Short, promptly-ending spans (the SDK only exports a span on `endSpan`, so
  there is no worker-lifetime span): per-episode `kiroku.subscription.catchup` /
  `paused` / `reconnecting` / `retrying`, per-batch `kiroku.subscription.fetch`,
  and standalone `kiroku.subscription.dead_letter` / `db_error`. Each carries a
  `kiroku.*` attribute set (subscription name, state, consumer-group member/size,
  checkpoint position, attempt, batch rows, event position, dead-letter/stop
  reason); the span-name and attribute-key constants are exported.
- The library still depends only on `hs-opentelemetry-api`; `kiroku-store` gains
  no OpenTelemetry dependency. The handler keeps its open spans in a thread-safe
  `MVar` keyed by `(subscription name, member)`. Requires a **batch span
  processor** so the synchronous callback never blocks the worker on export.

## 0.1.0.0 — 2026-05-23

### New Features

- Initial release. Exposes `Kiroku.Otel.TraceContext` with two helpers:
  - `injectTraceContext :: SpanContext -> EventData -> EventData` — encodes
    the supplied `SpanContext` to W3C `traceparent` / `tracestate` strings
    and merges them into the event's `metadata` JSON object. Existing keys
    in `metadata` are preserved.
  - `extractTraceContext :: RecordedEvent -> Maybe SpanContext` — reads
    the same JSON keys back out and decodes them through
    `OpenTelemetry.Propagator.W3CTraceContext.decodeSpanContext`. Returns
    `Nothing` when `metadata` is absent, is not a JSON object, lacks a
    `traceparent` key, or carries an unparseable value. Never throws.
