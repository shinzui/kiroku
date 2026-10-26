---
type: Friction Entry
title: "Default operator SSH identity is not usable for cell OS Login"
description: "The default SSH identity produced agent parsing errors and cell authentication failures, requiring a temporary registered key before privileged proof setup could run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:54:16Z"
frictionId: FRIC-9
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/load-testing-infra"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Use a task-specific key registered on the same current OS Login account with a one-hour expiry; explicitly revoke it and delete the temporary pair during cleanup."
resolution: "The existing operator identity remains unchanged; future runs need an explicitly usable registered identity. The task key was revoked and removed after setup."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T16:54:17Z"
    change: "Keep authentication scoped to an expiring task key and verify its removal on exit."
---
# Default operator SSH identity is not usable for cell OS Login

## Attempted

Create the lease-owned diagnostic template through the infrastructure IAP SSH wrapper.

## Encountered

The wrapper selected the default operator identity and failed public-key authentication after bounded retries.

```text
Error parsing user input; Permission denied (publickey,keyboard-interactive).
```

## Workaround

Use a task-specific key registered on the same current OS Login account with a one-hour expiry; explicitly revoke it and delete the temporary pair during cleanup.
