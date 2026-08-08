---
title: "Stream lifecycle: soft delete, hard delete, undelete"
type: Capability
description: "Soft-delete a stream (reversible, hidden from reads), hard-delete it (purge payloads and dead letters), or undelete a soft-deleted stream, with hard deletes gated by a session GUC."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-8
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Lifecycle
requires:
  - CAP-2
  - CAP-3
evidence:
  - kind: test
    resource: kiroku-store/test/Test/ReadStream.hs
    proves: Soft-deleted streams read empty and undelete restores visibility.
  - kind: test
    resource: kiroku-store/test/Test/Properties.hs
    proves: Soft/hard-delete and undelete transitions and reserved-name rejection.
  - kind: module
    resource: kiroku-store/src/Kiroku/Store/Lifecycle.hs
    proves: softDeleteStream/hardDeleteStream/undeleteStream and the hard-delete GUC/trigger gating.
  - kind: guide
    resource: docs/user/lifecycle.md
    proves: When to soft- versus hard-delete and how to enable hard deletes.
---

# Stream lifecycle: soft delete, hard delete, undelete

Streams are created implicitly by [append](append-with-optimistic-concurrency.md); this capability
manages their end of life. `softDeleteStream` hides a stream from ordered reads reversibly;
`undeleteStream` restores it; `hardDeleteStream` purges the stream's own events (and their dead
letters) that no other stream references. Runs against an acquired
[store](store-acquisition.md).

## Usage

```haskell
softDeleteStream (StreamName "order-42")
-- hard delete requires the session GUC to be set first:
-- SET kiroku.enable_hard_deletes = on;
hardDeleteStream (StreamName "order-42")
```

## Limits

- The `kiroku.enable_hard_deletes` GUC and the `protect_deletion` / `protect_truncation` triggers
  are **advisory guardrails, not a security boundary** — they prevent accidents, not a determined
  or privileged actor.
- Hard delete is irreversible and removes only events the target stream owns and no other stream
  links; it deletes matching `kiroku.dead_letters` rows first to satisfy the foreign key.
- There is no in-band audit row for deletes; audit via the observability event stream (CAP-14).
- `$all` is rejected with `ReservedStreamName`.
