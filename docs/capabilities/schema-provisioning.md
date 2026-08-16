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
    proves: Applies the eleven-entry manifest against ephemeral PostgreSQL 17 and 18 (`just test-matrix`), preserves all seven legacy payload checksums, applies the pending tail in a session that never ran the bootstrap and cannot reach the Kiroku schema through search_path, pins the UUIDv7 generator to the route its major requires, and proves the frozen SQL checkpoint relation plus replay-retention coordinator, lease, trigger, and index contracts.
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

The native manifest currently has eleven entries. The first seven preserve the importable Codd
payloads; `0008` through `0011` are native-only. Migration `0009` publishes the supported, frozen
`kiroku.subscription_checkpoints_v1` relation for least-privilege database readers while leaving
the underlying checkpoint table private. Migration `0010` adds the replay-history retention
coordinator, durable lease evidence, active-lease index, and destructive-operation triggers, and
publishes `kiroku.uuidv7()` as the component's version-independent UUIDv7 generator. Migration
`0011` converges databases that applied the withdrawn 0.3.2.x payload of `0010`.

Every migration after `0001` names its objects `kiroku.<name>`, including functions: only `0001`
sets `search_path`, so only `0001` may rely on it. This holds on every PostgreSQL version the
component supports, 17 and 18 alike. `just test-matrix` runs every suite against
both majors; the migration suite reports which route published `kiroku.uuidv7()` on the
server it ran against, so each leg states the half of the matrix it covered.

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
- `0.4.0.0` corrects the payload of `0010`, which was unapplicable to an already-bootstrapped
  PostgreSQL 17 database (BUG-1), and therefore changes its checksum. A database that already
  applied the withdrawn 0.3.2.0/0.3.2.1 payload must have its ledger row re-baselined with
  `kiroku-store-migrations/ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql` before it can
  be migrated further. This is the one case where a released payload was edited rather than
  corrected forward; a payload that fails at DDL parse time admits no forward correction.
