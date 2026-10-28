---
title: "Selective event compaction"
type: Capability
description: "Preview and apply reviewed physical event deletion using identity-bound manifests, deterministic witnesses and an append-only audit ledger."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-28T05:32:17Z"
capabilityId: CAP-22
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.13.0.0"
packages:
  - kiroku-store
  - kiroku-store-migrations
  - kiroku-cli
interface:
  - Kiroku.Store.Compaction
  - Kiroku.Store.Compaction.Types
  - Kiroku.Store.Read
  - Kiroku.Cli.Compaction
requires:
  - CAP-8
  - CAP-9
  - CAP-21
evidence:
  - kind: test
    resource: kiroku-store/test/Test/CompactionManifest.hs
    proves: Validated immutable manifests, canonical bytes, fixed SHA-256 vectors and permutation properties.
  - kind: test
    resource: kiroku-store/test/Test/CompactionPreview.hs
    proves: Snapshot-consistent read-only validation, complete refusal witnesses and ledger recognition.
  - kind: test
    resource: kiroku-store/test/Test/CompactionApply.hs
    proves: Exact atomic deletion, rollback on count/reference races, lease ordering, durable idempotence and retained-envelope equality.
  - kind: test
    resource: kiroku-cli/test/Test/Compaction.hs
    proves: Embedded commands, valid JSON, confirmed digest before database access, structured exit codes and standalone refusal.
  - kind: module
    resource: kiroku-store-migrations/migrations/0017.sql
    proves: Immutable identity and constrained append-only compaction ledger.
  - kind: guide
    resource: docs/user/compaction.md
    proves: Reviewed workflow, archive responsibility, refusal recovery, lease margins, sizing and storage maintenance.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-28T05:32:17Z"
    document_timestamp: "2026-10-28T05:32:17Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Checked against migration 0017, public manifest and reference types, shared
      preview/apply implementation, live compaction and CLI tests, ADR-22 and
      operator guidance. Publication is the next release-plan gate.
---

# Selective event compaction

The consumer proves redundancy and archives envelopes; Kiroku validates the exact
identity, event memberships and stream-head witnesses before deleting selected
originated events and explicitly acknowledged links. Preview is read-only. Apply
revalidates under the retention coordinator and ordered stream locks, leaves heads
and retained envelopes unchanged, and commits an append-only ledger record.
Reapplying a recorded digest returns the original record without deleting again.

The embeddable CLI requires explicit manifest-digest confirmation before accessing
the store. The standalone remote client refuses these commands. Database privileges
and host authorization control destructive access.

## Limits

- Migration `0017` is required. A restored clone retains its source store identity.
- A manifest selects at most 100,000 events; link fan-out, affected stream count and
  ledger size are not bounded by that selection limit. Start with 10,000 by stream.
- Active replay-history leases refuse apply. Coordinator hold delays lease work;
  keep measured chunk durations inside renewal margins.
- Causation checks are validation-time best-effort because no causation foreign key
  exists. Concurrent links/dead letters abort the whole apply on count/FK guards.
- The ledger contains counts, heads and digests, not deleted IDs or payloads. Keep
  the reviewed manifest and archive. Space reclamation is separate PostgreSQL work.
