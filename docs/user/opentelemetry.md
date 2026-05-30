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

## Tracing Subscription State

The helpers above propagate trace context on individual *events*. A separate
opt-in handler turns a subscription **worker's lifecycle** into spans, so the
finite state machine described in [Subscriptions](subscriptions.md#worker-states)
— catch up, go live, pause under backpressure, reconnect, retry, dead-letter —
shows up on a trace timeline.

`Kiroku.Otel.Subscription` exposes a factory that builds a `KirokuEvent`
callback from an OpenTelemetry `Tracer`:

```haskell
import Kiroku.Otel.Subscription (subscriptionTraceHandler)
import Control.Lens ((&), (.~))
import Kiroku.Store

-- tracer :: OpenTelemetry.Trace.Core.Tracer  (from your TracerProvider)
handler <- subscriptionTraceHandler tracer

settings :: ConnectionSettings
settings =
  defaultConnectionSettings connStr
    & #eventHandler .~ Just handler
```

It consumes the same `KirokuEvent` stream covered in
[Observability](observability.md); install it as the `eventHandler` and every
subscription emits spans thereafter. (Compose it with your own logging handler
by fanning the event out to both.)

### Span model

Each span is **short and ends promptly** — the SDK only exports a span when it
*ends*, so a single span held open for the worker's lifetime would be invisible
while the worker runs and lost on a crash. The model is therefore:

| Span | Opened on | Ended on |
|------|-----------|----------|
| `kiroku.subscription.catchup` | `Started` | `CaughtUp` |
| `kiroku.subscription.fetch` | each live `Fetched` | immediately (per batch) |
| `kiroku.subscription.paused` | `Paused` | `Resumed` |
| `kiroku.subscription.reconnecting` | first `Reconnecting` | next `CaughtUp` (later attempts add a `reconnect.attempt` span event) |
| `kiroku.subscription.retrying` | first `Retrying` of a poison event | `DeadLettered` (status `Error`) or the worker moving on (status `Ok`) |
| `kiroku.subscription.dead_letter` | an immediate dead-letter (no retry) | immediately |

The honest limitation: an *in-progress* episode (a pause that has not resumed
yet) does not appear in the backend until it ends. For "what state is the worker
in right now," use the `currentState` handle accessor
([Observability](observability.md#reading-a-subscriptions-current-state)).

### Attribute keys

Every span carries a `kiroku.*` attribute set (the constants are exported from
`Kiroku.Otel.Subscription`):

- `kiroku.subscription.name`
- `kiroku.subscription.state` — `"catchup"`, `"live"`, `"paused"`, `"reconnecting"`, `"retrying"`
- `kiroku.consumer_group.member` / `kiroku.consumer_group.size` — only for group members
- `kiroku.checkpoint.global_position`, `kiroku.subscription.attempt`,
  `kiroku.batch.rows`, `kiroku.event.global_position`,
  `kiroku.dead_letter.reason`, `kiroku.subscription.stop_reason`

### Use a batch span processor

The `eventHandler` callback runs **synchronously on the worker loop's thread**
(one thread per consumer-group member). Opening and ending a span is cheap and
in-memory, but the *export* may block — so configure your `TracerProvider` with
a **batch span processor** (the SDK default), which exports on a background
thread. With a simple/synchronous processor a slow exporter would stall the
worker.

### End to end through Shibuya

The same identity travels onto Shibuya's per-message spans. The
[Shibuya Adapter](shibuya-adapter.md) stamps `kiroku.subscription.name`,
`kiroku.consumer_group.member`, `kiroku.event.type`, and
`kiroku.event.global_position` onto each `Envelope`, which Shibuya merges into
the span it opens for the message. So a single trace is followable from a kiroku
subscription into Shibuya's processing, tagged with the same keys on both sides.

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
