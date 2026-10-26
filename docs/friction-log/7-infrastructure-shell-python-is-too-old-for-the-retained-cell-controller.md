---
type: Friction Entry
title: "Infrastructure shell Python is too old for the retained cell controller"
description: "The infrastructure shell selects Python 3.13 while the retained controller calls Python 3.14 uuid.uuid7, causing failure before a lease call and requiring an explicit interpreter during resume."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:46:45Z"
frictionId: FRIC-7
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Preserve the failed journal, audit that acquisition was not attempted, use the explicit Python 3.14 interpreter, and add tested journal support for unattempted acquisition."
resolution: "Documented the Python 3.14 requirement and added tested pre-acquire journal recovery without permitting ambiguous acquisitions or submitted-trial retries."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T16:54:17Z"
    change: "Use an explicit current interpreter when the infrastructure shell places Python 3.13 first."
---
# Infrastructure shell Python is too old for the retained cell controller

## Attempted

Resume the zero-trial proof journal inside the infrastructure development shell.

## Encountered

The controller raised AttributeError before allocating a lease ID; its resume guard had no representation for this pre-acquire failure.

```text
AttributeError: module 'uuid' has no attribute 'uuid7'
```

## Workaround

Preserve the failed journal, audit that acquisition was not attempted, use the explicit Python 3.14 interpreter, and add tested journal support for unattempted acquisition.
