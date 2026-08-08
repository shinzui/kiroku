---
title: "Observability event stream"
type: Capability
description: "Install a synchronous eventHandler that receives a typed KirokuEvent stream covering store-internal thread health and the full subscription lifecycle, hardened so a throwing handler cannot kill a store thread."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-14
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Observability
requires:
  - CAP-2
evidence:
  - kind: test
    resource: kiroku-store/test/Test/PublisherCallbackResilience.hs
    proves: A synchronous exception from an observability handler is dropped and reported without killing the publisher loop or stalling live subscriptions.
  - kind: module
    resource: kiroku-store/src/Kiroku/Store/Observability.hs
    proves: The KirokuEvent taxonomy (notifier/publisher/subscription lifecycle/batch/live-fetch) and the emitOrDrop hardening.
  - kind: guide
    resource: docs/user/observability.md
    proves: Wiring an eventHandler and interpreting the event taxonomy.
---

# Observability event stream

Install an `eventHandler` on [`ConnectionSettings`](store-acquisition.md) to receive a typed
`KirokuEvent` stream: notifier reconnects, publisher pool errors, per-subscription DB errors, the
subscription lifecycle (started/paused/resumed/reconnecting/retrying/dead-lettered/stopped),
per-batch delivery, and live-fetch signals. This is the foundation the OpenTelemetry and metrics
packages build on. Pool-lifecycle `Observation`s are surfaced separately via `observationHandler`.

## Usage

```haskell
defaultConnectionSettings connString
  & #eventHandler .~ \ev -> logKirokuEvent ev
```

## Limits

- Handlers run **synchronously on the emitting thread** (publisher, worker, notifier). A slow
  handler stalls that loop; keep handlers fast, or hand off asynchronously. `emitOrDrop` drops
  synchronous exceptions from the handler and rethrows async ones, so a throwing handler cannot
  kill a store thread — but it also means a buggy handler silently loses events.
- `KirokuEvent` evolves additively; exhaustive matches must be revisited on upgrade.
- There is no built-in Prometheus exporter here; that lives in the operational HTTP endpoints
  package (CAP-17), which consumes this event stream.
