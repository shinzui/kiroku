---
type: Improvement Request
title: Protect replay history from concurrent lifecycle mutations
description: >-
  Give long-running fan-in rebuilds a renewable durable history-retention lease and give
  transactional single-stream repair a stream-history guard, so Kiroku lifecycle operations
  cannot delete or hide source events while a consumer is proving replay completeness.
generated:
  by: openai/gpt-5
  at: "2026-08-13T18:52:50Z"
timestamp: "2026-08-13T22:10:57Z"
requestId: IR-6
status: in_progress
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T18:52:50Z"
    document_timestamp: "2026-08-13T18:52:50Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Kiroku's multi-statement hard-delete interpreter, lifecycle SQL, logical
      truncate-before behavior, bounded replay request IR-1, and Keiro MasterPlan 41. A captured
      global position freezes only the replay ceiling; hard delete can still remove $all,
      category, and per-stream junctions while replay is in progress, and the current hard-delete
      path does not acquire the target stream row lock before deleting junctions.
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T22:10:57Z"
    document_timestamp: "2026-08-13T22:10:57Z"
    scope: implementation-evidence
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Re-reviewed migration 0010, the public transaction and effect surfaces, coordinator and
      affected-stream lock algorithms, 18 migration and 305 core-store examples, both raw-SQL
      coordinator race outcomes, linked-stream guard coverage, hot-path structural assertions,
      the unchanged controlled workload gate, user and operator documentation, ADR-7, CAP-21,
      the full repository build, all 422 tests, and nix flake check. Local implementation is
      complete; package publication and the clean downstream consumer remain pending.
verified:
  by: process:codex
  at: "2026-08-13T22:10:57Z"
---

# Improvement Request: Protect Replay History From Concurrent Lifecycle Mutations

## Status

In progress. Implemented in repository source by
[ExecPlan 73](../plans/73-protect-replay-history-with-retention-leases-and-stream-guards.md) as an
owning-library prerequisite of
`mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.
That intended artifact handle awaits a Keiro registry refresh; its producing path is
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md` in
`mori://shinzui/keiro`.

Migration `0010`, the validated public lease model, transaction and Effectful operations, raw-SQL
enforcement, affected-stream hard-delete lock order, stream-history guard, observability,
documentation, [ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md),
and [CAP-21](../capabilities/protected-replay-history.md) are complete locally. The request remains
`in_progress` until Milestone 5 publishes the independently versioned package cohort and verifies
the public API from a clean downstream consumer; no release is claimed here.

The request strengthens the bounded logical replay window requested by
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`. IR-1 correctly states that a
captured global upper position does not stop later hard deletion from changing visible history.
This request adds the missing opt-in coordination contract for consumers whose completion proof
requires history to remain stable for the duration of a rebuild.


## Implementation Evidence

- `kiroku-store-migrations/migrations/0010.sql` owns the schema-local coordinator, constrained
  durable lease rows, partial active-lease index, SQLSTATE `KR001`, and the six statement-level
  destructive-operation triggers. The 18-example migration suite proves the ten-entry native
  manifest and exact catalog contract while retaining the seven-entry Codd import boundary.
- `Kiroku.Store.HistoryRetention` and `Kiroku.Store.HistoryRetention.Types` expose the validated
  transaction and mockable effect surface. `Test.HistoryRetention` proves the lifecycle,
  post-commit events, typed hard-delete conflict, both coordinator race outcomes, raw `DELETE` and
  `TRUNCATE` refusal, release, and passive-expiry recovery.
- `Test.StreamHistoryGuard` proves exact metadata and pagination plus blocking of append, link,
  soft delete, undelete, logical truncate, origin hard delete, and linked-origin hard delete; it
  also proves rollback release and repeated deadlock-free hard-delete/multi-append races.
- `Test.PerformanceStructure` proves no INSERT/UPDATE retention trigger, no retention reference in
  ordinary append/read/lifecycle statements, pre-pool validation, and indexed active lookup. The
  final unchanged controlled gate passed at `0.82x` and `0.83x` against its `0.90x` maximum after
  the prescribed repeated-noise investigation.
- All 422 repository tests, `just build`, strict ADR/capability validation, and
  `nix flake check` pass. Publication evidence and a clean Hackage consumer are intentionally
  deferred to the release-confirmed milestone.


## Context

Keiro rebuilds projections by capturing a global head and paging retained `$all` or category
history through that inclusive bound. A schema-changing rebuild can run for minutes or hours and
commits replay progress in many transactions. It cannot hold one PostgreSQL snapshot or row lock
for the complete run.

Kiroku's `hardDeleteStream` interpreter in `kiroku-store/src/Kiroku/Store/Effect.hs` runs a
Read-Committed transaction containing several destructive statements. It first resolves the
stream ID, then removes the stream's `$all` junctions for originated events, their remaining
junctions, the target stream's own junctions, orphan dead letters and event payloads, and finally
the stream row. The initial stream lookup does not lock the stream row. A projection replay can
therefore read an early page, observe a later hard delete, and finish with a source set that never
existed as one stable retained window.

The current deletion triggers require the session-local
`kiroku.enable_hard_deletes = 'on'` setting. Kiroku documents this as accidental-deletion
protection rather than authorization. The setting does not coordinate with replays; once enabled,
deletion can proceed while a consumer believes its captured head remains reconstructible.

Targeted per-stream repair has a shorter but related race. It can read and reproject one stream in
one surrounding transaction, and `StreamInfo.truncateBefore` tells it whether the retained
per-stream history is complete at inspection time. A concurrent `setStreamTruncateBefore`, soft
delete, or hard delete can change what ordered stream reads expose between metadata inspection and
the last read unless both sides share a lifecycle lock. Taking a shared lock on the stream row is
not enough with the present hard-delete order because hard delete removes junction rows before it
attempts to delete and lock the stream row.

The source-of-truth owner is Kiroku. Keiro must not protect history by locking Kiroku private
tables, inspecting private deletion SQL, or creating a second lifecycle registry.


## Requested Change

Provide two related public coordination primitives: a durable renewable lease for long-running
fan-in replay and a transaction-scoped guard for one-stream repair. Both must compose with
Kiroku's lifecycle implementation rather than rely on downstream conventions.


### Durable fan-in history-retention lease

Add Kiroku-owned persisted lease state and public transaction-composable operations with these
semantics:

1. A caller acquires a lease before reading the first replay page. Acquisition serializes with
   hard deletion, captures or validates the protected global frontier, and returns a unique lease
   ID plus database-derived expiry time.
2. While any lease is active, Kiroku prevents hard deletion from changing replay-visible history
   covered by that lease. A correct first implementation may conservatively refuse every hard
   delete while any lease is active. A narrower implementation may permit a delete only after
   proving that none of its removed `$all`, category, home, or link junctions intersects any
   protected window.
3. The lease uses PostgreSQL time, has a bounded duration, and must be renewed before expiry.
   Renewal extends only the same still-active lease; it never resurrects an expired lease.
4. Release is idempotent and ownership-aware. Releasing or expiring one lease does not affect
   other active leases.
5. A caller that cannot renew must stop applying replay work before the lease expires. Reacquiring
   after expiry creates a new protection interval and requires the caller to restart or revalidate
   its replay; it does not retroactively prove that history stayed stable during the gap.
6. Acquisition, renewal, and release are available as public `Hasql.Transaction.Transaction`
   combinators so Keiro can compose lease state with its own rebuild metadata. Effect-level
   wrappers through the mockable `Store` API may additionally support ordinary consumers.
7. Inventory and typed conflict results expose active/expired/released state without exposing the
   private lease table or requiring downstream raw SQL.

One possible public vocabulary is:

```haskell
newtype HistoryRetentionLeaseId = HistoryRetentionLeaseId UUID

data HistoryRetentionLease = HistoryRetentionLease
    { leaseId :: HistoryRetentionLeaseId
    , owner :: Text
    , reason :: Text
    , protectedThrough :: GlobalPosition
    , expiresAt :: UTCTime
    }

acquireHistoryRetentionLeaseTx ::
    HistoryRetentionRequest ->
    Tx.Transaction (Either HistoryRetentionConflict HistoryRetentionLease)

renewHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseId -> NominalDiffTime ->
    Tx.Transaction (Either HistoryRetentionRenewalError HistoryRetentionLease)

releaseHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseId -> Tx.Transaction HistoryRetentionReleaseResult
```

The final names and whether acquisition captures the authoritative append frontier or validates a
caller-supplied frontier belong to Kiroku. The required invariant is that acquisition and hard
delete share one database coordination point, so exactly one establishes its precondition first.

Hard-delete enforcement must be defense in depth. The supported `hardDeleteStream` path performs
an early typed lease check before deleting any junction. The database deletion guard also refuses
a raw GUC-enabled deletion while a conflicting lease is active, so the current advisory GUC
cannot accidentally bypass an API-level replay guarantee. A separately documented superuser
emergency override, if one exists, is outside ordinary application behavior and must be explicit
and observable.


### Transaction-scoped stream-history guard

Expose a transaction statement that locks one stream's lifecycle and returns its complete
`StreamInfo` before a caller reads ordered history:

```haskell
lockStreamHistoryForReplayTx ::
    StreamName ->
    Tx.Transaction (Either StreamHistoryUnavailable StreamInfo)
```

The lock remains held by the surrounding transaction. Kiroku's supported soft-delete,
undelete, truncate-before, and hard-delete paths must take conflicting locks before changing that
stream's visibility or deleting any of its junctions. In particular, hard delete resolves and
locks the target stream row before its first junction deletion. A caller can then:

1. acquire the guard;
2. refuse `deletedAt /= Nothing` or `truncateBefore > 0` according to its own completeness policy;
3. read the stream forward inside the same transaction; and
4. atomically update its projection state.

The opaque result or documentation must make clear that protection ends with the surrounding
transaction. It is not a durable lease and must not be stored as one.


## Lifecycle and Failure Semantics

Lease acquisition and hard delete use deterministic locking and cannot deadlock when several
leases, appends, and lifecycle operations race. If a global advisory transaction lock is used as
the coordinator, its key and shared/exclusive modes are a Kiroku-owned internal detail; callers do
not calculate it.

An active lease does not make deleted history reappear. It protects the retained history visible
when acquisition commits. If a hard delete commits first, subsequent acquisition protects the
post-delete store. The returned frontier and acquisition result give the caller one exact point
from which its replay guarantee begins.

Lease rows are operational evidence. They record creation, renewal, release or expiry, owner and
reason without event payloads. Expired rows may be retained for bounded audit or pruned through a
supported operation, but an abandoned row must not block hard deletion forever.

Logical truncate-before, soft deletion, and undelete do not affect `$all` or category reads, so a
global fan-in lease need not block them. The transaction-scoped stream guard does block them
because they affect ordered reads of the guarded stream.


## Boundaries

This request does not promise a long-lived PostgreSQL snapshot. Appends continue while a lease is
active, and a bounded replay still uses its captured inclusive frontier. The lease prevents
destructive loss of retained source history; it does not freeze new writes.

It does not make Kiroku understand projection catalogs, target generations, deduplication, or
promotion. Keiro owns the decision to acquire, renew, release, or condemn a rebuild when lease
maintenance fails.

It does not authorize hard deletion. Existing application authorization and privilege separation
remain necessary. This request adds replay coordination to the accidental-deletion guard; it does
not turn the GUC into a complete security boundary against superusers or disabled triggers.

It does not require every ordinary read to acquire a lease. Consumers that accept Kiroku's
current visibility semantics continue reading without coordination. The cost is opt-in for
workflows that need a stable retained replay window.

It does not block physical database backup, restore, or external superuser maintenance that
bypasses Kiroku entirely. Such operations must follow their own maintenance-window protocol.


## Acceptance

1. Acquiring a lease on a populated store returns a durable ID, protected frontier, and
   database-derived expiry; rolling back the acquisition transaction creates no active lease.
2. A hard delete racing lease acquisition is serializable at the coordination boundary: if the
   lease wins, deletion returns a typed retention conflict and changes no rows; if deletion wins,
   acquisition protects the resulting retained store and reports its post-delete frontier.
3. While a lease is active, repeated `$all` and category paging through its captured frontier sees
   no history disappear even when `hardDeleteStream` is attempted concurrently.
4. The database deletion guard also rejects a direct `DELETE` using the ordinary
   `kiroku.enable_hard_deletes` GUC while a conflicting lease is active.
5. Renewal before expiry extends the lease using database time. Renewal after expiry returns a
   typed failure and does not recreate protection.
6. Release is idempotent; releasing one of several leases leaves the others effective. After the
   final lease expires or is released, hard delete succeeds normally.
7. A process crash followed by lease expiry does not block hard deletion indefinitely, and lease
   inventory makes the abandoned/expired evidence observable.
8. `lockStreamHistoryForReplayTx` plus a complete ordered stream read in one transaction blocks
   concurrent soft delete, undelete, truncate-before, and hard delete until the reader transaction
   commits or rolls back.
9. Hard delete locks the target stream before deleting its first junction, so no partial deletion
   can occur while a transaction-scoped stream guard is held.
10. A guarded caller sees exact `deletedAt` and `truncateBefore` state and can refuse incomplete
    history before executing its own mutation.
11. Existing append concurrency, ordinary unguarded reads, logical truncation, hard-delete cleanup,
    observability events, and deletion-trigger tests remain green.
12. Public Haddocks and lifecycle documentation include copyable long-rebuild lease and
    one-transaction stream-repair examples, plus explicit expiry and emergency-override behavior.


## Requested Deliverables

- A `kiroku-store-migrations` change for durable retention leases and database-level deletion
  enforcement.
- Public transaction combinators and, where appropriate, mockable `Store` operations for acquire,
  renew, release, and inventory.
- A public transaction-scoped stream-history guard and corrected hard-delete lock ordering.
- Deterministic concurrency, rollback, expiry, multiple-lease, trigger-bypass, and deadlock tests.
- Lifecycle, production-deployment, and Haddock documentation.
- Telemetry that identifies retention conflicts, acquisitions, renewals, releases, and expiry
  without event payloads.
- Changelog entries and a released Kiroku package cohort whose registry versions and upstream tags
  provide authoritative dependency evidence for downstream adoption.
