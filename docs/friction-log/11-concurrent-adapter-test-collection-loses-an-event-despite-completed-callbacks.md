---
type: Friction Entry
title: "Concurrent adapter test collection loses an event despite completed callbacks"
description: "The PostgreSQL 17 release matrix exposed non-atomic event collection in an existing four-processor adapter test, requiring a fixture correction and rerun."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T05:17:47Z"
frictionId: FRIC-11
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku/packages/shibuya-kiroku-adapter"
affectedVersion: "unreleased"
plan: "docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md"
workaround: "Replace the affected test handler collection with atomicModifyIORef, then rerun the adapter suite on PostgreSQL 17 before accepting the matrix."
resolution: "The affected four-processor test now uses atomicModifyIORef for its shared event list; all 45 adapter examples pass on PostgreSQL 17 and 18."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T05:19:44Z"
    change: "Resolve the adapter test collector race after verifying the corrected fixture on both supported PostgreSQL majors."
---
# Concurrent adapter test collection loses an event despite completed callbacks

## Attempted

nix develop .#postgresql17 --no-write-lock-file -c cabal test all --test-show-details=direct

## Encountered

The consumer group policy test reached its completed-callback count but the shared collected list omitted position 3 from the expected 1..40 sequence.

```text
test/Main.hs:1276:40: expected positions [1..40]; collected positions omitted 3. The four processors used modifyIORef on one shared list while countVar advanced atomically.
```

## Workaround

Replace the affected test handler collection with atomicModifyIORef, then rerun the adapter suite on PostgreSQL 17 before accepting the matrix.
