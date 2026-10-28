---
type: Architecture Decision Record
title: Physical event compaction is manifest-driven witness-validated and ledgered
description: Delete only explicitly selected events after locked witness validation, preserving retained history and recording digest-keyed durable audit evidence.
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-28T05:10:33Z"
docId: ADR-22
status: Accepted
date: 2026-10-27
timestamp: "2026-10-28T05:10:33Z"
originatingPlan: docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md
---

# Physical event compaction is manifest-driven, witness-validated and ledgered

## Context

Consumers sometimes prove that selected originated events are redundant while
other events in the same streams must remain. Logical truncate-before hides
per-stream history but reclaims no payload space. Whole-stream deletion discards
more than the reviewed set. The consumer, rather than Kiroku, owns equivalence,
archives and authorization. [ADR-7](0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md)
defines destructive coordination; [ADR-21](0021-store-identity-is-a-schema-installed-clone-shared-singleton.md)
defines clone-shared store identity. [ADR-4](0004-explicit-subscription-checkpoint-lifecycle.md)
leaves checkpoint policy with consumers.

## Decision

Accept only validated, digest-sealed manifests naming the store identity, an
operation label, reference policies, event IDs, originating streams and versions,
global positions, acknowledged link memberships and every affected stream head.
Canonical binary encodings have versioned domain prefixes and SHA-256 digests;
JSON is a transport whose decoder validates the manifest digest. Consumers may
rehearse the same manifest against a restored clone sharing the source identity.

Preview runs the common validator on one read-only repeatable-read snapshot,
without row locks or writes. It returns typed accumulated refusals, a deterministic
sealed report, or a stored already-applied record. Expected refusals are values;
connection, transaction and invariant failures are StoreError values.

Apply checks identity before any lock, then takes the ADR-7 coordinator, refuses
active leases, and probes the ledger before stream locks. An already-recorded
manifest with zero surviving selected IDs returns immediately without stream
locks. A recorded digest with surviving IDs refuses as a ledger conflict.
Unrecorded work locks every affected stream in ascending internal ID order and
reruns the same validator before its first DELETE.

Every reference class is accounted for explicitly. Links require exact per-event
acknowledgement. Dead letters refuse by default and are removed only by a sealed
policy. Causation dependents outside the whole selected set also refuse by default;
allowing dangling causation is explicit. Causation refusal is validation-time
best-effort: these soft IDs have no foreign key or lock, so a dependent appended
to an unlisted stream after validation is not detected.

Junction deletion uses exact `(event_id, stream_id)` pairs. A concurrent link into
an unlisted stream survives that WHERE clause and its foreign key aborts payload
deletion. Dead-letter and row-count races also abort the entire transaction.
Count guards raise SQLSTATE KRCMP with a manifest digest in DETAIL and are mapped
in the shared transaction error mapper. The standard apply effect additionally
maps its own 23503 foreign-key failure to CompactionConcurrentMutation. Direct
transaction composers may receive UnexpectedServerError 23503 for that race.
Both mean rollback, fresh preview and retry; no partial deletion commits.

The ledger insertion commits in the same transaction as deletion. A unique
manifest digest, stored report digest, verified counts, name-sorted head witnesses
and database-supplied apply metadata provide durable idempotence and audit evidence.
Ledger readers preserve stored digests verbatim so audits can detect corruption.
The ledger does not store the selected event list; the consumer archive does.
Use the operation label for an archive locator.

Retained event envelopes and memberships are neither rewritten nor renumbered.
Stream high-water versions and the global append frontier remain unchanged, so
expected-version appends continue normally and cursor reads skip physical gaps.
The visible global head may decrease after tail deletion. No NOTIFY is emitted.
Ordinary append/read SQL, triggers, locks and round trips gain no compaction work.

A manifest has at most 100,000 selections. This does not bound link fan-out or the
number of affected streams. Operators chunk by stream and measure apply duration
well inside lease-renewal margins, since coordinator holders delay renewals too.
PostgreSQL privileges remain the authorization boundary; the session hard-delete
setting is an accident guard. No remote apply surface is provided.

## Consequences

Deletion is an explicit, auditable exceptional operation on an otherwise
append-only store. Restarts do not lose idempotence evidence. Appends to affected
streams wait during apply; guarded repairs block apply. Every manifest adds one
ledger row. Removed IDs can be appended again, so duplicate-ID retry protection
is lost for exactly those IDs. A worker attempting to dead-letter a removed event
will encounter the existing foreign-key failure behavior.

Deleted tuples become reusable through PostgreSQL maintenance; filesystem space
reclamation is separate operational work. Large deletes can produce substantial
WAL. Preview is advisory and may become stale; apply always revalidates.

## Alternatives considered

A whole-stream rewrite or copy-transform renumbers retained history and breaks
checkpoint/link identities. Declarative age/count scavenging would make Kiroku
choose consumer policy. Tombstone-then-scavenge adds a second durable state without
improving the single validated transaction. Inferring idempotence from absence
cannot distinguish previously applied work from events that never existed.
Refusing every linked event forces unrelated link-stream destruction. An internal
checkpoint guard embeds consumer policy; consumers can compose their own guard
with applyCompactionTx instead. Whole-stream fallback, crypto-shredding, filesystem
reclamation and an HTTP apply endpoint are deliberately excluded.
