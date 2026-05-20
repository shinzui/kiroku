# OpenTelemetry

Kiroku can carry W3C trace context on every event so a consumer reading an
event later — a projection, a subscription, a process manager — can continue
the trace that produced it. The `kiroku-otel` package provides pure helpers
to write and read that context; the store's append/read hooks let you apply
them automatically.

`kiroku-otel` is a separate package so `kiroku-store` stays free of any
`hs-opentelemetry` dependency. Opt in by depending on `kiroku-otel` directly.

## The Wire Format

Trace context lives in the event's `metadata` JSONB column as W3C
trace-context strings:

```json
{
  "traceparent": "00-<32-hex traceId>-<16-hex spanId>-<2-hex flags>",
  "tracestate":  "<vendor entries, optional>"
}
```

Any other keys in `metadata` are preserved. This is a plain JSON convention,
so consumers that do not use `kiroku-otel` (for example the
[Shibuya Adapter](shibuya-adapter.md), which copies `traceparent` into its
envelope) can still read it.

## The Helpers

`Kiroku.Otel.TraceContext` exposes two pure functions:

```haskell
injectTraceContext :: SpanContext -> EventData -> EventData
extractTraceContext :: RecordedEvent -> Maybe SpanContext
```

`injectTraceContext` encodes a `SpanContext` into `traceparent` / `tracestate`
and merges them into the event's `metadata`. Existing keys are preserved; any
existing `traceparent` / `tracestate` are overwritten (the W3C spec mandates
exactly one of each). If `metadata` is absent or not a JSON object, it starts
from an empty object.

`extractTraceContext` pulls a `SpanContext` back out of a `RecordedEvent`'s
`metadata`. It returns `Nothing` — and never throws — when `metadata` is
absent, is not an object, lacks `traceparent`, or holds a `traceparent` that
fails W3C parsing.

```haskell
import Kiroku.Otel.TraceContext (extractTraceContext)

handle :: RecordedEvent -> IO ()
handle event =
  case extractTraceContext event of
    Just ctx -> withLinkedSpan ctx (process event)
    Nothing  -> process event
```

## Enriching On Append, Reading On Decode

You can apply these helpers by hand on each event, but the store's
`StoreSettings` hooks apply them to every event automatically:

- `enrichEvent` fires on the **append** path, on the typed `EventData`, before
  the SQL encoder runs. Use it to inject the current span into outgoing
  events.
- `decodeHook` fires on the **read and subscription** paths, on the
  `RecordedEvent` about to be surfaced. Use it to attach derived metadata,
  decrypt, or redact.

```haskell
import Control.Lens ((&), (.~))
import Kiroku.Store
import Kiroku.Otel.TraceContext (injectTraceContext)

settings :: ConnectionSettings
settings =
  defaultConnectionSettings connStr
    & #storeSettings .~
        defaultStoreSettings
          { enrichEvent = Just $ \ed -> do
              ctx <- captureCurrentSpanContext   -- from your OTel setup
              pure (injectTraceContext ctx ed)
          }
```

Wire the resulting `StoreSettings` into `ConnectionSettings` via its
`storeSettings` field; `withStore` copies it onto the store handle so the
interpreter reaches it for every event.

Both hooks default to `Nothing`, in which case the interpreter takes a pure
fast path that does no extra allocation and no traversal — there is no cost
when you do not use them.

## Caveat: Direct Transaction Callers

The `enrichEvent` hook fires inside the `Store` interpreter
(`runStorePool`). Callers that bypass the interpreter and use
`Kiroku.Store.Transaction.appendToStreamTx` directly do **not** get
enrichment. Opt in manually with `enrichEventsIO` before building the
prepared event list:

```haskell
import Kiroku.Store.Transaction (enrichEventsIO)

enriched <- enrichEventsIO storeSettings rawEvents
-- then prepare and append within your transaction
```

The high-level `runTransactionAppending` wrapper (see
[Appending Events](appending-events.md)) goes through the normal path, so it
honors `enrichEvent` without extra work.

## Package Dependencies

`kiroku-otel` depends on `hs-opentelemetry-api` (`>=0.3 && <0.4`) and
`hs-opentelemetry-propagator-w3c` (`>=0.1 && <0.2`). `SpanContext`,
`wrapSpanContext`, and the W3C propagator come from those packages; capturing
the current span context is the responsibility of your application's
OpenTelemetry tracer setup.

## See Also

- [Observability](observability.md) — operational events and metrics, which
  complement tracing.
- [Shibuya Adapter](shibuya-adapter.md) — propagates `traceparent` into
  Shibuya envelopes.
- [Appending Events](appending-events.md) — where `enrichEvent` runs.
