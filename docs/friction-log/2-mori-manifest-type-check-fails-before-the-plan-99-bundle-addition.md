---
type: Friction Entry
title: "Mori manifest type-check fails before the Plan 99 bundle addition"
description: "The existing mori.dhall dependency helpers do not type-check against their pinned schema, preventing whole-manifest validation of the new friction bundle declaration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-25T13:52:58Z"
frictionId: FRIC-2
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/kiroku"
plan: "docs/plans/99-repair-the-append-category-column-workload-cell-and-measure-migration-0012-s-write-cost.md"
workaround: "Validate the new friction bundle strictly and compare the bundle declaration locally; leave the pre-existing dependency-schema migration outside this benchmark plan."
resolution: "Strict bundle checks pass; the existing dependency-schema mismatch predates this plan and is retained as a manifest-validation limitation outside the benchmark change."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-25T13:53:08Z"
    change: "Retain the pre-existing whole-manifest type error without expanding Plan 99 into a schema migration."
---
# Mori manifest type-check fails before the Plan 99 bundle addition

## Attempted

dhall type --file mori.dhall after declaring the friction-log bundle

## Encountered

The testDep helper passes versionConstraint to a pinned schema constructor that rejects that field; the same failure reproduces on HEAD before all Plan 99 edits.

```text
Error: Wrong type of function argument; unexpected versionConstraint in Schema.Dependency.WithAugmentation at mori.dhall:7:9. Reproduced on git show HEAD:mori.dhall.
```

## Workaround

Validate the new friction bundle strictly and compare the bundle declaration locally; leave the pre-existing dependency-schema migration outside this benchmark plan.
