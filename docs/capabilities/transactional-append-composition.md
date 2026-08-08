---
title: "Transactional append composition"
type: Capability
description: "Atomically compose a single-stream append with a caller-supplied hasql transaction, so an event and the application state it drives commit or roll back together."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Transaction
requires:
  - CAP-3
evidence:
  - kind: test
    resource: kiroku-store/test/Test/Transaction.hs
    proves: runTransactionAppending commits append+continuation atomically, condemns on append conflict so the continuation never runs, and surfaces both conflict and connection failures typed.
  - kind: module
    resource: kiroku-store/src/Kiroku/Store/Transaction.hs
    proves: The runTransaction escape hatch, appendToStreamTx building block, and the runTransactionAppending* wrappers with their retry and $all-lock semantics.
---

# Transactional append composition

Run an arbitrary `Hasql.Transaction.Transaction` against the store's pool with `runTransaction`, or
use the recommended `runTransactionAppending` / `runTransactionAppendingResource` wrappers to
atomically compose a single-stream [append](append-with-optimistic-concurrency.md) with a
caller-supplied continuation — the primary API for downstream projection consumers that must write
an event and their own read-model rows in one transaction.

## Usage

```haskell
runTransactionAppending store name expectedVersion events $ \appendResult ->
  updateReadModel appendResult   -- runs only if the append succeeds
```

## Limits

- The default (non-`NoRetry`) variants retry the whole body on serialization conflicts, so the
  continuation may run more than once — it must be idempotent or side-effect-free until commit.
- `appendToStreamTx` **bypasses the `enrichEvent` hook**; callers must apply `enrichEventsIO`
  (or `prepareEventsIO`) themselves. It also does not enforce reserved-stream rejection.
- The append updates Kiroku's global `$all` row and PostgreSQL holds that row lock until the
  transaction ends, so every statement the continuation runs afterward blocks all other appends
  store-wide. Keep continuations minimal and run append-independent work first.
- A mock `Store` interpreter cannot execute an opaque transaction; `RunTransaction` /
  `RunTransactionNoRetry` are expected to be rejected by mocks.
