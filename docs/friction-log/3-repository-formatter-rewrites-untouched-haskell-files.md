---
type: Friction Entry
title: "Repository formatter rewrites untouched Haskell files"
description: "The configured nix fmt defaults differ from the checked-in Haskell style, producing unrelated rewrites while formatting this plan."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T20:21:30Z"
frictionId: FRIC-3
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/103-close-the-subscription-worker-observability-and-decode-filter-gaps-from-rev-2.md"
workaround: "Retain formatting only for changed code and restore unrelated formatter-only changes after verifying against the original formatting baseline."
resolution: "The tracked fourmolu.yaml selects a different style from existing source files, and the commit hook enforces it. Accept formatting changes in the eleven edited Haskell files, restore only verified formatter-only changes in unrelated files, and preserve fourmolu.yaml unchanged."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T20:23:49Z"
    change: "Keep repository-wide formatting outside Plan 103 while retaining the successful formatter check and recording the local override."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T20:30:08Z"
    change: "The commit hook shares the same local override; validate under repository formatting defaults without retaining unrelated rewrites."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T20:31:24Z"
    change: "Correct the earlier mistaken ignored-config diagnosis: git ls-files confirms the configuration is tracked; retain required formatting on edited files and run the normal hook."
---
# Repository formatter rewrites untouched Haskell files

## Attempted

Run the required nix fmt check after implementing Plan 103.

## Encountered

The formatter reported 165 changed files, including untouched append SQL and benchmark modules.

```text
formatted 191 files (165 changed)
```

## Workaround

Retain formatting only for changed code and restore unrelated formatter-only changes after verifying against the original formatting baseline.
