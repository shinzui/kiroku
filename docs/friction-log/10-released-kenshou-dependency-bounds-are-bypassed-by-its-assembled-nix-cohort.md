---
type: Friction Entry
title: "Released Kenshou dependency bounds are bypassed by its assembled Nix cohort"
description: "Building the current Kenshou operator required a matched compatibility pin and removal of unrelated runtime suite compilation before namespace evidence could run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T18:40:58Z"
frictionId: FRIC-10
status: logged
impact: detour
kind: tooling
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/keiro-runtime-kenshou"
affectedVersion: "2129bb917da811ef1e90198d91db873cc8d05b7b"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Pin strict-mutable-base 1.1.0.0 identically in both arms, verified against Hackage and its upstream tag. Build a narrow operator retaining Kenshou commands and selftests plus Plan 54 metadata, omitting unrelated runtime suites."
---
# Released Kenshou dependency bounds are bypassed by its assembled Nix cohort

## Attempted

Build kenshou-released at 2129bb917da811ef1e90198d91db873cc8d05b7b and prepare a matched namespace payload.

## Encountered

Effectful 2.6.1.0 was assembled with strict-mutable-base 2.x despite its published <2 bound; compilation failed on IORef prime. An unrelated Shibuya metrics/core mismatch also prevented the stock operator build.

```text
Retained build-operator.log and build-operator-fixed.log in kiroku-store/bench/results/ep54-kenshou.
```

## Workaround

Pin strict-mutable-base 1.1.0.0 identically in both arms, verified against Hackage and its upstream tag. Build a narrow operator retaining Kenshou commands and selftests plus Plan 54 metadata, omitting unrelated runtime suites.
