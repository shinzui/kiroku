---
type: Friction Entry
title: "Plan benchmark commands require the Nix development environment"
description: "The plan bare Cabal command cannot find its required GHC 9.12.4 in the ordinary shell and needs the repository Nix environment."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T13:38:52Z"
frictionId: FRIC-1
status: "resolved"
impact: detour
kind: documentation
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/99-repair-the-append-category-column-workload-cell-and-measure-migration-0012-s-write-cost.md"
workaround: "Prefix build, test and benchmark commands with nix develop --no-write-lock-file -c."
resolution: "The plan and performance gate guide now show the Nix development environment required by these commands."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T13:41:59Z"
    change: "Document the working Nix invocation after the plain-shell build failed."
---
# Plan benchmark commands require the Nix development environment

## Attempted

cabal build kiroku-store:kiroku-store-bench-workload-gate kiroku-store:kiroku-store-test

## Encountered

Cabal could not locate ghc-9.12.4 on PATH.

```text
Error: [Cabal-5490] Cannot find the program 'ghc'. User-specified path 'ghc-9.12.4' does not refer to an executable and the program is not on the system path.
```

## Workaround

Prefix build, test and benchmark commands with nix develop --no-write-lock-file -c.
