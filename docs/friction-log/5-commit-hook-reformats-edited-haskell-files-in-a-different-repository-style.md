---
type: Friction Entry
title: "Commit hook reformats edited Haskell files in a different repository style"
description: "The mandatory treefmt commit hook rewrites the surrounding formatting of edited source files, widening the semantic review and requiring restaging and revalidation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:29:28Z"
frictionId: FRIC-5
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Retain required formatting only in already-edited files, inspect whitespace-insensitive SQL diffs, restage, and run the normal hook again."
---
# Commit hook reformats edited Haskell files in a different repository style

## Attempted

Commit the verified namespace worker and migration with the normal repository hooks.

## Encountered

treefmt exited 1 after reformatting twelve edited Haskell files, including the large test driver and SQL module.

```text
hook id: treefmt; files were modified by this hook; unexpected changes detected, --fail-on-change is enabled
```

## Workaround

Retain required formatting only in already-edited files, inspect whitespace-insensitive SQL diffs, restage, and run the normal hook again.
