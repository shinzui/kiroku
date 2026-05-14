# kiroku-otel changelog

## Unreleased

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
