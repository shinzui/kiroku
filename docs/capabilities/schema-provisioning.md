---
title: "Schema provisioning and migrations"
type: Capability
description: "Install and version-control the Kiroku PostgreSQL schema through an embedded, manifest-ordered pg-migrate component and the kiroku-store-migrate executable before any application opens a store."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store-migrations
interface:
  - Kiroku.Store.Migrations
  - Kiroku.Store.Migrations.History.Codd
  - kiroku.subscription_checkpoints_v1
evidence:
  - kind: test
    resource: kiroku-store-migrations/test/Main.hs
    proves: Applies the ten-entry manifest against ephemeral PostgreSQL, preserves all seven legacy payload checksums, and proves the frozen SQL checkpoint relation plus replay-retention coordinator, lease, trigger, and index contracts.
  - kind: module
    resource: kiroku-store-migrations/src/Kiroku/Store/Migrations.hs
    proves: Exposes kirokuMigrations (the compile-time-embedded component) and kirokuMigrationPlan, validated against the manifest at build time.
  - kind: guide
    resource: docs/user/schema-migrations.md
    proves: The operator command set (plan, list, check, up, verify, status, new, repair) and DATABASE_URL configuration.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T21:59:54Z"
    document_timestamp: "2026-08-13T21:59:54Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against the ten-entry manifest, native and Codd-import migration suites, focused
      PostgreSQL checkpoint-relation and replay-retention schema tests, and the updated operator
      and schema guides.
---

# Schema provisioning and migrations

`kiroku-store` does **not** run DDL when a store is acquired. A consumer installs and
upgrades the `kiroku` schema out of band with this package: a native
[`pg-migrate`](https://raw.githubusercontent.com) component embedded at compile time, plus
the `kiroku-store-migrate` executable. Applications compose `kirokuMigrations` with their own
components in explicit dependency order, or run the executable at deploy time before startup.

The native manifest currently has ten entries. The first seven preserve the importable Codd
payloads; `0008`, `0009`, and `0010` are native-only. Migration `0009` publishes the supported, frozen
`kiroku.subscription_checkpoints_v1` relation for least-privilege database readers while leaving
the underlying checkpoint table private. Migration `0010` adds the replay-history retention
coordinator, durable lease evidence, active-lease index, and destructive-operation triggers.

## Usage

```bash
kiroku-store-migrate up --database-url "$DATABASE_URL"
```

```haskell
-- Compose the embedded component with your own migrations, in order.
plan = either (error . show) id kirokuMigrationPlan
```

## Limits

- The runtime moved from Codd to `pg-migrate` in `0.2.0.0`: the public API now exports the
  native `kirokuMigrations` component and `kirokuMigrationPlan` rather than the earlier Codd
  settings/runner surface, and the CLI is the standard `pg-migrate-cli` tree keyed on
  `DATABASE_URL` (the `CODD_*` surface is gone). A database previously managed by Codd is
  adopted non-destructively through `kirokuCoddHistoryMappings` / `kirokuCoddSourcePayloads`
  (`SamePayload` evidence), not by re-running.
- `verify` compares the declared plan against the `pgmigrate` ledger; it does **not** compare
  live schema objects against an expected-schema snapshot (that snapshot and its writer were
  removed in `0.2.0.0`).
- Migrations are forward-only; there are no down-migrations.
