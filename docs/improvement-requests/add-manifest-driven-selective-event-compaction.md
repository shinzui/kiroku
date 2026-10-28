---
type: Improvement Request
title: Add manifest-driven selective event compaction
description: >-
  Add a public transactional Kiroku operation that validates an immutable event manifest and
  removes exactly those selected originated events while preserving every retained event's
  identity, stream version, global position, links, and future append correctness.
generated:
  by: openai/gpt-5
  at: "2026-08-22T13:40:36Z"
timestamp: "2026-10-28T11:52:14.298426+00:00"
requestId: IR-14
status: completed
completedAt: "2026-10-28T11:52:14.298426+00:00"
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-10T16:10:46Z"
    scope: authoring-metadata
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked the required title, description, request identity, lifecycle, origin and
      timestamp metadata against the bundle profile. This is an authoring-metadata
      review only; source claims, implementation acceptance and release evidence were
      not reviewed here.
---

# Improvement Request: Add Manifest-Driven Selective Event Compaction

## Status

Completed under
[MasterPlan 11](../masterplans/11-manifest-driven-selective-event-compaction.md).
The typed identity, reference inventory, manifest, read-only preview, atomic apply,
ledger, operator guide and embeddable CLI are released. All six coordinated
packages and documentation are published with annotated tags and GitHub releases.
The fresh registry-only external consumer passed migration, preview, apply,
identical reapply, ledger, unchanged retained envelopes/head and append at version 4.
[Release evidence](../releases/2026-10-28-selective-compaction/README.md) records the
exact sources, hashes, tags, isolated build plan and witness.

Proposed by
`mori://shinzui/mori/masterplans/27-record-event-provenance-and-manage-the-store-lifecycle`
for the hard-gated consumer
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`.
That plan remains blocked until this request is implemented, released, and inspected from the
released source. Filing the request does not authorize compaction of any live store.


## Context

Kiroku Store 0.8 exposes whole-stream soft delete, hard delete, undelete, and reversible logical
truncate-before operations through `Kiroku.Store.Lifecycle`. None can remove a reviewed subset of
events from otherwise live streams. Whole-stream hard delete removes the source events' derived
memberships and can also remove links to those events, so a downstream consumer cannot safely use
it to compact redundant occurrences while retaining meaningful events in the same stream.

Mori has the first concrete consumer. Before August 2026 its Repository ingest repeatedly recorded
unchanged ref targets. A restored-registry inventory found 475,058 adjacent same-target
`RefObserved` occurrences as a candidate upper bound inside Repository streams that also contain
changesets, content hashes, history rewrites, day boundaries, signals, and state-changing ref
observations. Mori can conservatively classify candidates, archive their complete envelopes, and
produce a reviewed manifest, but it must not reproduce Kiroku's table, link, stream-head, lease,
or subscription invariants in private SQL.

`mori://shinzui/kiroku/okf/adrs/concepts/ADR-7` already requires destructive lifecycle operations
to coordinate with durable history-retention leases and ordered stream guards. Selective
compaction must join that same coordination model. It must preserve the high-water stream version
used by optimistic appends even when deleted occurrences leave gaps in ordered reads. Retained
events must not be renumbered or reinserted: their event IDs, original stream versions, global
positions, payloads, metadata, typed causation/correlation, and surviving memberships are immutable
facts.


## Requested Change

Add a supported manifest-driven selective-compaction contract to `kiroku-store`. The exact public
names are Kiroku's to choose, but the contract must provide a typed immutable manifest, a read-only
preview/validation operation, a transactional apply operation, a closed refusal/error vocabulary,
and a deterministic result report.

The manifest must identify the store and operation definition, carry a caller-supplied root digest,
and list selected event identities with enough immutable witnesses to prevent applying a stale or
misdirected manifest. At minimum each selected item identifies the event ID, originating stream,
original stream version, and global position. The operation validates the complete manifest before
deleting its first row.

Apply must use one database transaction and remove exactly the selected originated events and
their Kiroku-derived memberships. It must leave every retained event row and membership unchanged,
leave each affected stream's append high-water version unchanged, and support subsequent
expected-version appends. It must preserve unrelated and retained links. If a selected event has a
non-derived link or another reference that the manifest did not explicitly and safely account for,
the operation refuses rather than broadening the deletion.

The operation must participate in ADR-7's lifecycle coordination. It refuses while any
history-retention lease is active and uses the established deterministic affected-stream lock
order. It also refuses on store identity mismatch, manifest or event witness mismatch, missing or
additional selected events, stream-head drift, unexpected links, unsupported topology, or another
condition that makes the requested transaction ambiguous.

Preview and apply return canonical counts and digests for selected events, deleted derived
memberships, retained witnesses, and affected stream heads. Reapplying an already completed exact
manifest is an observable no-op with the same logical report; a partially matching store is an
error. Kiroku emits the existing lifecycle observability evidence or a new typed equivalent so an
operator can audit preview, refusal, and successful apply without reading private tables.


## Boundaries

Kiroku owns validation and mutation of its event-store invariants. It does not own Mori's
Repository-specific candidate classifier, cutoff, archive format, lifecycle-definition ledger, or
production approval. The generic API must not decide that an event is semantically redundant.

This request does not add a whole-stream fallback, renumber retained events, recreate retained
events at new positions, promise that an archive can restore original positions, or weaken
append-only protection outside the validated transaction. It does not promise filesystem
shrinkage: physical deletion may create reusable PostgreSQL space, while returning relation files
to the operating system is a separate maintenance operation.

Implementation and release do not authorize a consumer to compact production. The consuming
project remains responsible for a verified archive, domain-level equivalence proof, restored-clone
rehearsal, current lease/checkpoint checks, and explicit operator authorization.


## Acceptance

1. A public `kiroku-store` preview validates a manifest without mutating any event-store row and
   returns deterministic witnesses suitable for explicit operator confirmation.
2. Apply is one transaction: interruption before commit changes nothing, and success removes
   exactly the selected events and derived memberships reported by the manifest.
3. Retained events preserve byte-equivalent payload and metadata, event IDs, original stream
   versions, global positions, typed causal identities, and all surviving memberships.
4. Ordered per-stream, category, and `$all` reads skip physical gaps without renumbering; existing
   checkpoints continue forward; and a new expected-version append succeeds from the unchanged
   pre-compaction stream high-water version.
5. Tests cover selected events with ordinary derived memberships, retained linked events,
   selected events with unexpected links, several affected streams, concurrent append/head drift,
   an active history-retention lease, manifest corruption, a missing event, repeated apply, and a
   transaction failure before commit.
6. Every unsafe or ambiguous case refuses through a typed closed error and leaves all rows
   unchanged. The API never silently widens the manifest.
7. The implementation uses ADR-7's coordinator and deterministic affected-stream lock order and
   adds no statement, trigger, lock, or round trip to ordinary append and read paths.
8. Public Haddock and operator documentation distinguish selective physical deletion, logical
   truncate-before, whole-stream hard delete, reusable database space, and filesystem reclamation.
9. The capability ships in versioned `kiroku-store` and migration packages as needed, with
   PVP-appropriate bounds, annotated release tags, changelog entries, and a clean external consumer
   proving the released API.


## Requested Deliverables

Deliver the typed manifest, preview, transactional apply, closed errors, and deterministic report
through public `kiroku-store` effect and transaction APIs; any necessary manifest-ordered database
migration; lifecycle observability; focused property, concurrency, failure-injection, and
release-consumer tests; and user/operator documentation. An embeddable `kiroku-cli` preview/apply
surface may be included, but higher-level selection policy and production authorization remain in
the consuming project.


## Delivery

Released at commit `7511adf7ed57bc30a330bfb6431451e5004fd9f0`:

- [kiroku-store 0.13.0.0](https://hackage.haskell.org/package/kiroku-store-0.13.0.0)
- [kiroku-store-migrations 0.7.3.0](https://hackage.haskell.org/package/kiroku-store-migrations-0.7.3.0)
- [kiroku-cli 0.3.0.0](https://hackage.haskell.org/package/kiroku-cli-0.3.0.0)
- [kiroku-otel 0.3.0.1](https://hackage.haskell.org/package/kiroku-otel-0.3.0.1)
- [kiroku-metrics 0.4.0.1](https://hackage.haskell.org/package/kiroku-metrics-0.4.0.1)
- [shibuya-kiroku-adapter 0.7.0.1](https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.7.0.1)

The Store annotated tag object is `4d5f39320db76e8518d6e350430f40f12926b69d`
and peels to that commit. All six tag objects and peeled commits are retained in
[remote-tags.txt](../releases/2026-10-28-selective-compaction/remote-tags.txt).
Downloaded Hackage source SHA-256 values match every pre-upload archive in
[artifacts.json](../releases/2026-10-28-selective-compaction/artifacts.json); the
migration archive contains all seventeen manifest entries ending in `0017.sql`.
The fresh Cabal consumer pins Store 0.13.0.0 and migrations 0.7.3.0, has no local
dependency override, and produces this witness:

```text
clean consumer verified: kiroku-store 0.13.0.0, kiroku-store-migrations 0.7.3.0, store StoreIdentity 01a1825a-8900-7579-aaff-49b8206eee12, manifest "b15157c4728297ca8d3475fcd9303a3e5c526cf87f889bdc1b1b1acbcf0bfec6", selected 1, applied CompactionId 01a1825a-8911-7f5d-9ac1-cbf2f8763e40, surviving versions [1,3], appended at version 4
disposable PostgreSQL stopped cleanly
```

All repository suites pass on PostgreSQL 17/18, alongside 52 structural checks,
the unchanged 17-case controlled workload/spread gate, Nix/package checks and
catalogue/ADR validation. ADR-21 and ADR-22 record the durable contract.

The downstream standalone `stream compact ...` operator surface belongs to
`mori://shinzui/keiro/packages/keiro-ops`. A Keiro-owned improvement request should
reuse `Kiroku.Cli.Compaction` renderers and the digest-confirmed outcome runner.
That follow-up is outside this Kiroku MasterPlan; this release and proof supply
its prerequisite without adding an HTTP mutation endpoint or authorizing any
production compaction.
