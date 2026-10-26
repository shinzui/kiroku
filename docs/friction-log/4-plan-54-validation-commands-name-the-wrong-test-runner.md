---
type: Friction Entry
title: "Plan 54 validation commands name the wrong test runner"
description: "Plan 54 describes Tasty flags for the current Hspec store suite, requiring source inspection to choose a working focused command."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:17:39Z"
frictionId: FRIC-4
status: "resolved"
impact: nuisance
kind: documentation
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Use --test-options=\"--match namespace\" and correct the living plan."
resolution: "Corrected the living plan to identify Hspec and use --match namespace; the focused command passes."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T16:27:15Z"
    change: "Fix the documented runner instead of carrying a contributor workaround."
---
# Plan 54 validation commands name the wrong test runner

## Attempted

Read and execute the namespace acceptance command in plan 54

## Encountered

The plan prescribes -p namespace and says not to use Hspec --match, but test/Main.hs invokes hspec.

## Workaround

Use --test-options="--match namespace" and correct the living plan.
