---
title: "Protected replay history"
type: Capability
description: "Protect long global rebuilds with durable renewable retention leases and short one-stream repairs with transaction-scoped history guards."
generated:
  by: openai/gpt-5
  at: "2026-08-13T21:59:54Z"
capabilityId: CAP-21
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.7.0.0"
packages:
  - kiroku-store
  - kiroku-store-migrations
interface:
  - Kiroku.Store.HistoryRetention
  - Kiroku.Store.HistoryRetention.Types
  - Kiroku.Store.Lifecycle
requires:
  - CAP-4
  - CAP-6
  - CAP-8
evidence:
  - kind: test
    resource: kiroku-store/test/Test/HistoryRetention.hs
    proves: Validated durable lease lifecycle, effect events, typed hard-delete conflicts, both coordinator race outcomes, raw SQLSTATE KR001 defense, and release or passive-expiry recovery.
  - kind: test
    resource: kiroku-store/test/Test/StreamHistoryGuard.hs
    proves: Exact guarded metadata and paging, blocking across home and linked mutations, rollback release, and repeated deadlock-free hard-delete/multi-append races.
  - kind: test
    resource: kiroku-store/test/Test/PerformanceStructure.hs
    proves: Ordinary statements and INSERT/UPDATE triggers exclude retention coordination while active lookup uses its partial index and the unchanged controlled workload gate passes.
  - kind: module
    resource: kiroku-store-migrations/migrations/0010.sql
    proves: Schema-owned coordinator, constrained durable lease evidence, active-lease index, and DELETE/TRUNCATE enforcement in the triggering table schema.
  - kind: guide
    resource: docs/user/history-retention.md
    proves: Copyable long-rebuild and one-transaction repair flows plus renewal, expiry, ownership, SQLSTATE, and lock-order boundaries.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T21:59:54Z"
    document_timestamp: "2026-08-13T21:59:54Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against migration 0010, public lease and guard types, internal coordinator and
      affected-stream algorithms, focused PostgreSQL concurrency/raw-SQL/performance suites,
      package changelogs, and user and production operations documentation.
---

# Protected replay history

Acquire a durable replay-history lease before rebuilding from `$all` or a category through a fixed
inclusive frontier. The lease survives process restart, is renewed with database time, expires
passively within a bounded interval, and blocks supported hard delete plus GUC-enabled direct
deletion while active. For a short repair, lock one stream and read its ordered history in the
same application-owned transaction.

## Usage

```haskell
lease <- acquireHistoryRetentionLease request
let ceiling = protectedThrough lease
-- Rebuild only through ceiling, renewing before expiresAt.
_ <- releaseHistoryRetentionLease
       (HistoryRetentionLeaseHandle (leaseId lease) (owner lease))

repair <- runTransaction $ do
  locked <- lockStreamHistoryForReplayTx stream
  case locked of
    Left unavailable -> pure (Left unavailable)
    Right info -> do
      events <- readStreamForwardTx stream (StreamVersion 0) 256
      pure (Right (info, events))
```

## Limits

- Lease duration is one second through one hour. Expiry is passive; renewal never resurrects an
  expired or released lease.
- The first policy blocks every Kiroku data-table deletion while any lease is active, even when a
  narrower intersection check might be possible. Direct SQL receives SQLSTATE `KR001`.
- Owner matching prevents accidental mutation; PostgreSQL roles and grants provide authorization.
- A guarded transaction returns soft-delete and truncate metadata but the caller decides whether
  that history is complete enough to repair. `readStreamForwardTx` does not run `decodeHook`.
- A transaction combining both mechanisms acquires or renews the lease before taking the stream
  guard. Ordinary append, read, soft-delete, undelete, and logical-truncate paths do neither.
