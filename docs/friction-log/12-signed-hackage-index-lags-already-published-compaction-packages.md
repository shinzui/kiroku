---
type: Friction Entry
title: "Signed Hackage index lags already published compaction packages"
description: "A fresh isolated Cabal consumer required repeated signed-index refreshes after all six package pages and byte-verified tarballs were already available."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-28T11:45:46Z"
frictionId: FRIC-12
status: "accepted"
impact: slowdown
kind: environment
origin: "mori://shinzui/kiroku"
affects: "https://hackage.haskell.org"
affectedVersion: "unknown"
plan: "docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md"
workaround: "Retain every index attempt and wait for authenticated registry metadata to include both exact pins; do not use local archives or relax bounds for the release acceptance proof."
resolution: "The fifth authenticated index refresh included both exact releases at index-state 2026-10-28T11:40:47Z. Treat signed-index propagation as expected release latency, retain attempts and verify index inclusion before resolving; no source override or weakened bound is needed."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-28T11:49:05Z"
    change: "Accept propagation latency after the exact pinned registry consumer began building from the refreshed signed index."
---
# Signed Hackage index lags already published compaction packages

## Attempted

Run cabal update in a fresh CABAL_DIR, then cabal list --simple-output kiroku-store before resolving exact kiroku-store 0.13.0.0 and kiroku-store-migrations 0.7.3.0 pins.

## Encountered

The first signed index ended at 07:55:25Z; refreshes advanced only to 11:40:43Z, including the first upload but omitting the migration package uploaded one second later. All six direct archives and preferred versions were already verified.

```text
cabal update: The index-state is set to 2026-10-28T11:40:43Z. cabal list includes kiroku-store 0.13.0.0 but omits kiroku-store-migrations 0.7.3.0.
```

## Workaround

Retain every index attempt and wait for authenticated registry metadata to include both exact pins; do not use local archives or relax bounds for the release acceptance proof.
