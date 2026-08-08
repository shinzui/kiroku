---
title: "Append events with optimistic concurrency"
type: Capability
description: "Append events to one or many streams atomically with an expected-version precondition, all-or-nothing per call, with read-your-own-writes and typed conflict errors."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Append
  - Kiroku.Store.Error
requires:
  - CAP-2
evidence:
  - kind: test
    resource: kiroku-store/test/Test/Properties.hs
    proves: Property-based append/expected-version round-trips, empty-batch rejection, reserved-stream rejection, and stream-name validation.
  - kind: test
    resource: kiroku-store/test/Test/Concurrency.hs
    proves: Concurrent appends resolve to WrongExpectedVersion / conflict outcomes correctly, and single-stream appends retry transient serialization/deadlock failures.
  - kind: guide
    resource: docs/user/appending-events.md
    proves: The append API, ExpectedVersion semantics, and idempotent event-id preparation.
---

# Append events with optimistic concurrency

Write immutable events to a stream with an `ExpectedVersion` precondition. `appendToStream` is the
cheapest path (a single CTE, all-or-nothing per call, read-your-own-writes); `appendMultiStream`
appends to several streams atomically in one transaction. Both run against an acquired store —
see [store acquisition](store-acquisition.md).

## Usage

```haskell
appendToStream (StreamName "order-42") (ExactVersion 0) [orderPlaced]
```

## Limits

- The third field of `WrongExpectedVersion` / `WrongExpectedVersionConflict` is a **placeholder**
  and is always `StreamVersion 0`: on a mismatch the append returns zero rows and the store does
  not issue an extra read. A caller needing the live version must call `getStream`.
- `appendToStream` retries **once** on PostgreSQL `40001`/`40P01`; event ids are prepared before
  the first attempt so the retry is idempotent.
- Empty batches are rejected: `appendToStream []` fails with `EmptyAppendBatch` before any pool
  work, while `appendMultiStream []` is an explicit no-op. Stream names are validated up front
  (reserved `$all`, plus a 512-byte bound because the NOTIFY payload embeds the name).
- `StoreError` evolves additively; exhaustive matches must be revisited on upgrade.
