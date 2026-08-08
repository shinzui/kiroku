---
title: "Logical truncate-before compaction"
type: Capability
description: "Set a per-stream truncate-before marker that hides events below a version from ordered per-stream reads, without deleting anything, to support snapshot-and-compact rehydration."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-9
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.3.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Lifecycle
requires:
  - CAP-8
evidence:
  - kind: test
    resource: kiroku-store/test/Test/TruncateBefore.hs
    proves: The marker hides per-stream reads at or below it, leaves the $all log/readCategory/subscriptions unaffected, is idempotent and reversible, returns Nothing for missing/soft-deleted streams, and rejects $all.
---

# Logical truncate-before compaction

`setStreamTruncateBefore` sets a per-stream cursor below which ordered per-stream reads hide
events; `clearStreamTruncateBefore` removes it. No events are deleted and the operation is fully
reversible. It extends [stream lifecycle](stream-lifecycle.md) with a compaction marker: append a
snapshot event at version `V`, then set the marker to `V` so rehydration starts there. The marker
surfaces on `StreamInfo.truncateBefore`.

## Usage

```haskell
setStreamTruncateBefore (StreamName "order-42") (StreamVersion 100)
```

## Limits

- The marker affects only `readStreamForward` / `readStreamBackward` /
  `readStreamForwardStream`. The global `$all` log, `readCategory`, subscriptions, and existence
  probes are deliberately **unaffected**, so global history stays complete — a subscription or
  `$all` reader still sees the "compacted" events.
- Returns `Nothing` for a missing or soft-deleted stream and rejects `$all` with
  `ReservedStreamName`.
- This is a newer capability (`0.3.0.0`) than the delete/undelete operations it sits beside; a
  consumer pinning an earlier release does not have it.
