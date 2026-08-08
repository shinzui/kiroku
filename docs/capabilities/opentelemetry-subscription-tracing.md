---
title: "OpenTelemetry subscription tracing"
type: Capability
description: "Turn the subscription worker's finite-state lifecycle into OpenTelemetry spans through a ready-made KirokuEvent handler, with kiroku.* and messaging.* semantic-convention attributes."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-16
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.2.0.0"
packages:
  - kiroku-otel
interface:
  - Kiroku.Otel.Subscription
requires:
  - CAP-14
  - CAP-11
evidence:
  - kind: test
    resource: kiroku-otel/test/Main.hs
    proves: A database-backed $all worker with the handler installed emits the catch-up, live deliver, and stopped spans with the expected attributes, captured by an in-memory exporter.
  - kind: module
    resource: kiroku-otel/src/Kiroku/Otel/Subscription.hs
    proves: subscriptionTraceHandler and the exported span-name/attribute-key vocabulary.
  - kind: guide
    resource: docs/user/opentelemetry.md
    proves: Installing the trace handler and the required batch span processor.
---

# OpenTelemetry subscription tracing

`subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())` is a ready-made
[`eventHandler`](observability-events.md) that turns the
[subscription](live-subscriptions.md) worker's lifecycle into OpenTelemetry spans:
`kiroku.subscription.deliver` (once per batch, every target, both phases),
`catchup`/`paused`/`reconnecting`/`retrying`, `dead_letter`/`db_error`, and a terminal
`kiroku.subscription.stopped`. Spans carry both `kiroku.*` and generated `messaging.*`/`db.*`
semantic-convention attributes.

## Usage

```haskell
handler <- subscriptionTraceHandler tracer
let settings = defaultConnectionSettings connString & #eventHandler .~ handler
```

## Limits

- Requires a **batch span processor** so the synchronous callback never blocks the worker on
  export — the observability handler contract is synchronous.
- Spans are short and prompt-ending because the SDK only exports on `endSpan`; there is no
  worker-lifetime span. In-progress episodes are not visible until they end.
- Subscription-span coverage arrived in `0.2.0.0` (kiroku-otel); the `0.1.0.0` release provided
  only trace-context propagation (CAP-15), a separate capability in the same package.
