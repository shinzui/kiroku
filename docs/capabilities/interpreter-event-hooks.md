---
title: "Interpreter-level event enrich and decode hooks"
type: Capability
description: "Transform every event on the write path (enrichEvent) and the read/subscription path (decodeHook) through interpreter-level hooks wired once on ConnectionSettings, with an allocation-free fast path when absent."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-7
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Settings
requires:
  - CAP-3
  - CAP-4
evidence:
  - kind: test
    resource: kiroku-store/test/Test/InterpreterHooks.hs
    proves: enrichEvent fires on append and decodeHook fires on reads and the subscription pipeline, uniformly across the entry points, with the no-op default adding no traversal.
  - kind: module
    resource: kiroku-store/src/Kiroku/Store/Settings.hs
    proves: StoreSettings/defaultStoreSettings and the enrichEvents/decodeEvents helpers reused by the interpreter, publisher, and worker.
---

# Interpreter-level event enrich and decode hooks

Wire `StoreSettings { enrichEvent, decodeHook }` onto `ConnectionSettings.storeSettings` to
transform events uniformly: `enrichEvent` runs on the [append](append-with-optimistic-concurrency.md)
path before encoding, and `decodeHook` runs after decoding on the
[read](reading-events.md) and subscription paths. Both default to `Nothing` with a `pure` fast
path that adds no traversal or allocation.

## Usage

```haskell
defaultStoreSettings
  { enrichEvent = Just $ \ed -> do
      ctx <- captureCurrentSpan
      pure (ed & #metadata %~ injectTraceContext ctx)
  }
```

## Limits

- The hooks run everywhere the interpreter, publisher, and worker surface events — **except**
  `appendToStreamTx` and the other direct `Tx`-level building blocks, which bypass `enrichEvent`
  (apply `enrichEventsIO` manually) — see transactional append composition (CAP-6).
- `enrichEvent` and `decodeHook` are `IO` actions run inline on the store's hot paths; a slow hook
  slows every append/read/delivery.
