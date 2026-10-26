---
type: Friction Entry
title: "Cell workflow needs infrastructure shell tools on operator PATH"
description: "Direct cell publishing and IAP setup lacked zstd and socat in the ordinary operator shell, delaying the proof before any trial submission."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:43:01Z"
frictionId: FRIC-6
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/load-testing-infra"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Use the infrastructure dev shell and resume the same owned journal without resetting the original budget."
resolution: "Documented use of the infrastructure dev shell, which supplies zstd and socat, and completed setup with that environment."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T16:54:17Z"
    change: "Publish and IAP prerequisites are now explicit in the retained harness instructions."
---
# Cell workflow needs infrastructure shell tools on operator PATH

## Attempted

Publish the namespace Linux closure and run the lifecycle proof through the retained cell controller.

## Encountered

payload-publish could not start the compressor; later IAP template setup reported socat not found. The zero-trial journal released its lease and verified all four instances stopped.

```text
compressing Nix closure: No such file or directory (os error 2); iap-ssh: socat not found on PATH
```

## Workaround

Use the infrastructure dev shell and resume the same owned journal without resetting the original budget.
