---
title: "Store acquisition with connection pooling and schema isolation"
type: Capability
description: "Open a KirokuStore over a pooled hasql connection, isolated in a dedicated PostgreSQL schema, with a dedicated LISTEN connection and pluggable observation/event handlers."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Connection
  - Kiroku.Store.Notification
requires:
  - CAP-1
evidence:
  - kind: module
    resource: kiroku-store/src/Kiroku/Store/Connection.hs
    proves: KirokuStore/ConnectionSettings, defaultConnectionSettings (poolSize 10, schema "kiroku"), withStore, and the storeSettings/observationHandler/eventHandler wiring.
  - kind: test
    resource: kiroku-store/test/Test/NotifyGuard.hs
    proves: The dedicated LISTEN connection and per-schema notification channel behave correctly against a real ephemeral PostgreSQL.
  - kind: guide
    resource: docs/user/getting-started.md
    proves: Opening a store with withStore after migrations, and the schema search_path model.
---

# Store acquisition with connection pooling and schema isolation

A consumer runs Kiroku by acquiring a `KirokuStore` with `withStore`, which owns a hasql
connection pool, a dedicated `LISTEN` connection for subscriptions, and (when needed) a
publisher thread. Every pooled connection runs `SET search_path` so all Kiroku objects live in
a dedicated `kiroku` schema, leaving `public` free for the application. This capability
requires the schema to already exist — see [schema provisioning and migrations](schema-provisioning.md).

## Usage

```haskell
withStore (defaultConnectionSettings connString) $ \store ->
  -- append, read, subscribe against `store`
  pure ()
```

`ConnectionSettings` exposes `poolSize` (default 10), `schema` (default `"kiroku"`, authoritative
for object location and the `LISTEN <schema>.events` channel), `extraSearchPath`, `storeSettings`,
`observationHandler`, and `eventHandler`.

## Limits

- The subscription-state registry carried on the handle is **in-memory only** and is discarded
  when the store closes; it is live runtime state, not a persistence layer.
- `0.3.1.0` added `runKirokuStoreWith`, which installs an already-acquired handle into the
  effect stack without acquiring or releasing it; the caller then owns the handle lifetime.
- The `schema` field became authoritative for table resolution in `0.1.0.0` (previously it only
  named the notification channel); the runtime role needs privileges on the `kiroku` schema.
