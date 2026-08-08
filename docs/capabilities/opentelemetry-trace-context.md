---
title: "OpenTelemetry W3C trace-context propagation"
type: Capability
description: "Inject a W3C traceparent/tracestate into an event's metadata on write and extract a SpanContext back on read, keeping kiroku-store free of any OpenTelemetry dependency."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-15
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-otel
interface:
  - Kiroku.Otel.TraceContext
requires:
  - CAP-7
evidence:
  - kind: test
    resource: kiroku-otel/test/Main.hs
    proves: injectTraceContext merges traceparent/tracestate while preserving other metadata keys, and extractTraceContext round-trips a SpanContext and returns Nothing (never throwing) on absent/unparseable metadata.
  - kind: module
    resource: kiroku-otel/src/Kiroku/Otel/TraceContext.hs
    proves: The two pure helpers over the OpenTelemetry 1.0 W3C propagator.
  - kind: guide
    resource: docs/user/opentelemetry.md
    proves: Propagating trace context through events.
---

# OpenTelemetry W3C trace-context propagation

`injectTraceContext :: SpanContext -> EventData -> EventData` encodes W3C
`traceparent`/`tracestate` into an event's `metadata` JSON (preserving existing keys), and
`extractTraceContext :: RecordedEvent -> Maybe SpanContext` reads them back, never throwing. The
canonical wiring injects through an [`enrichEvent` hook](interpreter-event-hooks.md) so trace
context is attached uniformly across every write path; extraction runs on the read side. Kept in a
separate package so `kiroku-store` gains no OpenTelemetry dependency.

## Usage

```haskell
storeSettings = defaultStoreSettings
  { enrichEvent = Just $ \ed -> do
      ctx <- captureCurrentSpan
      pure (injectTraceContext ctx ed)
  }
```

## Limits

- `extractTraceContext` returns `Nothing` (rather than failing) when `metadata` is absent, is not a
  JSON object, lacks `traceparent`, or carries an unparseable value.
- `injectTraceContext` is observably pure over an `IO`-typed OTel 1.0 encoder; it does not read
  ambient context — the caller supplies the `SpanContext`.
- Requires the OpenTelemetry 1.0 package family (`hs-opentelemetry-api ^>=1.0` and the W3C
  propagator).
