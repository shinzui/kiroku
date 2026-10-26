---
type: Friction Entry
title: "Deployed cell descriptor is incompatible with the available cell client"
description: "The current infrastructure cell client rejects the deployed alpha descriptor broker field before upload, blocking controlled namespace performance trials."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-10-26T16:51:41Z"
frictionId: FRIC-8
status: "accepted"
impact: blocked
kind: interface
origin: "mori://shinzui/kiroku"
affects: "mori://shinzui/load-testing-infra"
plan: "docs/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions.md"
resolution: "Preserve the rejected legacy cellctl attempt. The user selected Kenshou, whose current source supports optional instances.broker; the legacy client remains unchanged, and namespace performance evidence is still required."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-10-26T17:22:13Z"
    change: "Use the preferred Kenshou workflow for M3 instead of treating repair of the older direct client as a prerequisite."
---
# Deployed cell descriptor is incompatible with the available cell client

## Attempted

Submit the lifecycle proof using the built infrastructure client and deployed PostgreSQL 18 cell.

## Encountered

cellctl rejected descriptor decoding before uploading work. The controller released the lease; no benchmark executed and no comparison was admitted.

```text
decoding cell descriptor: unknown field `broker`, expected one of `postgres`, `drivers`, `monitoring` at line 13 column 12
```
