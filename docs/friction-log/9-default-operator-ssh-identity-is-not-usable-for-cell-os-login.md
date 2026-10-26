---
type: Friction Entry
title: "Default operator SSH identity is not usable for cell OS Login"
description: "The default SSH identity produced agent parsing errors and cell authentication failures, requiring a temporary registered key before privileged proof setup could run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:54:16Z"
frictionId: FRIC-9
status: "resolved"
impact: detour
kind: environment
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/load-testing-infra"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
workaround: "Use a task-specific key registered on the same current OS Login account with a one-hour expiry; explicitly revoke it and delete the temporary pair during cleanup."
resolution: "At the user's request, registered Yujin's three existing public keys from Sungkyung's authorized_keys in the current OS Login profile without expiration. Verified normal Yujin SSH and sudo PostgreSQL access, then stopped the VM and released the lease. No private keys were copied."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T16:54:17Z"
    change: "Keep authentication scoped to an expiring task key and verify its removal on exit."
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T17:08:18Z"
    change: "Replace the temporary-key workaround with permanent authorization for Yujin as the replacement development machine."
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
