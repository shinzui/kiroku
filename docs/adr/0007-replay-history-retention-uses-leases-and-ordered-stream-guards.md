---
type: Architecture Decision Record
title: Replay-history retention uses leases and ordered stream guards
description: "Protect global rebuilds with durable database-time leases and one-stream repairs with transaction-scoped guards, using a dedicated coordinator and excluding ordinary hot paths."
generated:
  by: openai/gpt-5
  at: "2026-08-13T21:59:54Z"
docId: ADR-7
status: Accepted
date: 2026-08-13
timestamp: "2026-08-13T21:59:54Z"
originatingPlan: docs/plans/73-protect-replay-history-with-retention-leases-and-stream-guards.md
---

# ADR-0007: Replay-history retention uses leases and ordered stream guards

- **Related:** [ExecPlan 73](../plans/73-protect-replay-history-with-retention-leases-and-stream-guards.md);
  [IR-6](../improvement-requests/protect-replay-history-from-concurrent-lifecycle-mutations.md);
  [ADR-3](0003-dedicated-kiroku-schema.md);
  [ADR-4](0004-explicit-subscription-checkpoint-lifecycle.md);
  [ADR-5](0005-three-tier-performance-regression-gates.md);
  `mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.

## Context

A captured global append frontier bounds a replay but does not retain the rows below it. Supported
hard delete and GUC-enabled direct SQL can remove payload and junction rows while a long rebuild is
paging. A shorter one-stream repair can likewise observe metadata and ordered pages across
different lifecycle states unless both reads share a transaction lock.

The protection must survive a process crash, compose with application-owned SQL, cover links as
well as home events, and avoid adding a lock, statement, round trip, or trigger to append and
ordinary read paths. Kiroku can coordinate supported operations, but PostgreSQL privileges—not a
caller-supplied owner label or session GUC—remain the authorization boundary.

## Decision

Use two explicit mechanisms with one global lock order.

- Long rebuilds acquire durable, renewable rows in `history_retention_leases`. PostgreSQL supplies
  their timestamps, expiry is derived without a worker, and requested remaining lifetime is
  limited to one second through one hour. Lease ownership prevents accidental mutation by a
  different operational identity but is not a secret or authorization credential.
- Serialize lease acquisition, renewal, supported hard delete, and raw `DELETE`/`TRUNCATE` through
  the singleton row in `history_retention_coordinator`. Keep this coordinator separate from the
  `$all` stream row so ordinary append never waits on lease administration.
- Conservatively reject every Kiroku data-table `DELETE` and `TRUNCATE` while any lease is active,
  regardless of its protected frontier. Supported hard delete returns a typed conflict; direct
  GUC-enabled SQL raises SQLSTATE `KR001`. There is no ordinary application bypass.
- A one-stream repair takes `FOR SHARE` on its `streams` row through
  `lockStreamHistoryForReplayTx`. Supported hard delete first takes the coordinator, then locks the
  target and every stream containing a junction for its originated events in ascending
  `stream_id`, then removes junction and payload rows. This covers a guard held on a linked stream
  and gives Kiroku-owned lifecycle algorithms one deterministic order.
- `readStreamForwardTx` reuses the production ordered statement inside the caller's transaction.
  It cannot run the IO-only `decodeHook`; callers that depend on the hook apply equivalent decoding
  outside the transaction. When composing a lease and guard, callers take the lease first.
- Keep retention work off ordinary append, `$all`/category/per-stream read, soft-delete,
  undelete, and logical-truncate statements. The migration installs no INSERT or UPDATE retention
  trigger. Deterministic statement/trigger assertions and ADR-5's unchanged controlled workload
  gate enforce this exclusion.

## Consequences

**Positive**

- A committed lease protects a stable retained global set through a database-derived ceiling and
  survives owner-process restart until release or bounded passive expiry.
- Transaction-scoped guards make one-stream metadata and paging stable against every supported
  mutation that could change its home or linked history.
- Direct destructive SQL cannot accidentally bypass the guarantee merely by enabling the existing
  hard-delete GUC.
- Ordinary hot paths retain their previous SQL, trigger count, coordinator independence, and
  round-trip behavior.

**Negative**

- Any active lease blocks all Kiroku data-table deletion, even deletion provably above or unrelated
  to its frontier. Operators must renew responsibly and may wait up to one hour after an abandoned
  maximum-duration lease.
- Hard delete now pays coordinator lookup and affected-stream discovery/locking costs. This bounded
  cost belongs to a rare destructive path and cannot be eliminated without weakening serialization.
- Public transaction combinators expose a lock order callers must respect when deliberately
  composing lease and stream-guard work.
- A superuser can still disable triggers or perform physical maintenance. Such work is outside the
  application guarantee and requires a coordinated maintenance window.

## Alternatives Considered

- **Lock the `$all` stream row for lease coordination.** Rejected because every append updates that
  row; lease administration would enter the hottest global write path.
- **Use one advisory-lock key.** Rejected because collision and multi-schema scoping require more
  convention and are less inspectable than a schema-owned singleton row.
- **Block only deletes intersecting `protectedThrough`.** Deferred because hard delete crosses
  `$all`, home, and linked junctions; conservative rejection is easier to prove and operate.
- **Lock only the hard-delete target stream.** Rejected because deleting origin A removes A's
  junctions linked into guarded stream B.
- **Run a background expiry worker.** Rejected because database-time predicates provide crash-safe
  passive expiry without another thread, connection, or failure lifecycle.
- **Put retention checks on append or ordinary reads.** Rejected because immutable additions do not
  invalidate retained history and the extra coordination would violate the hot-path contract.
