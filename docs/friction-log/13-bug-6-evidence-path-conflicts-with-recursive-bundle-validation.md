---
type: Friction Entry
title: "BUG-6 evidence path conflicts with recursive bundle validation"
description: "Plan 104 prescribed Markdown evidence inside the bug bundle, where recursive validation classifies it as another bug report."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-30T18:43:46Z"
frictionId: FRIC-13
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/104-preserve-asynchronous-cancellation-across-observability-and-recovery.md"
workaround: "Retain the validation summary as current-head-validation.txt alongside existing non-concept evidence and correct plan links."
resolution: "Corrected plan 104 to retain non-concept evidence as .txt and set fixedVersion to unreleased; BUG-6 now adds no bundle validation findings."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-30T18:44:05Z"
    change: "Reconciled the prescribed evidence path and fixed-report metadata with the pinned recursive bundle contract."
---
# BUG-6 evidence path conflicts with recursive bundle validation

## Attempted

Write current-head-validation.md and run strict bug-bundle validation as prescribed by plan 104.

## Encountered

The evidence document was checked against every required Bug Report field.

```text
evidence/BUG-6/current-head-validation: missing required field: type
```

## Workaround

Retain the validation summary as current-head-validation.txt alongside existing non-concept evidence and correct plan links.
