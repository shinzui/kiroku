# Changelog

## Unreleased

## 0.2.0.0 — 2026-07-10

### Breaking Changes

* Replaced the Codd runner surface with the native `kirokuMigrations` component
  and `kirokuMigrationPlan`; consumers now compose and run `pg-migrate` plans.
* Replaced timestamped runtime identities with manifest-ordered `0001` through
  `0007` identities while preserving every SQL payload byte.

### New Features

* Added checked-in Codd history mappings and manifest-backed `SamePayload`
  evidence for current `codd` and legacy `codd_schema` ledgers.
* Mounted the reusable `pg-migrate-cli` command tree and native exclusive
  migration authoring helper.
* Added fresh, repeat, concurrent, strict verification, Codd import,
  partial-row, audit, and source-preservation tests; Kiroku's full store suite
  now consumes the native plan through `kiroku-test-support`.
* Isolated the Codd expected-schema writer behind the disabled-by-default
  `expected-schema-tool` flag so predecessor libraries do not enter the normal
  production closure.

### New Features

* `kiroku-store-migrate new "<description>"` scaffolds a new migration file
  stamped with the real current UTC time to the second and a schema-qualified,
  idempotent SQL skeleton, so filenames always sort in codd's authoring order
  and never collide. Backed by the new `Kiroku.Store.Migrations.New` module.
* A portable, checked-in codd expected-schema snapshot under
  `expected-schema/v18/` plus a strict drift-gate example in
  `kiroku-store-migrations-test`: `cabal test kiroku-store-migrations-test` now
  fails on any un-snapshotted schema change. Regenerate the snapshot with the
  new `kiroku-write-expected-schema` executable after a schema-shape change.
  The snapshot is captured under a fixed `kiroku` database identity so the test
  passes on any machine, and the write tool is cabal-flag-gated
  (`expected-schema-tool`) off under nix so it never enters the `nix build`
  closure.
* `Kiroku.Store.Migrations.Guards` exposes reusable pure migration validators
  for timestamp sentinels, duplicate timestamps, body linting, and SHA-256
  lockfile manifests. `kiroku-store-migrations-test` now enforces embed parity,
  body lint, the checked-in `migrations.lock`, and a codd ledger canary.
* `kiroku-store-migrate lock` regenerates `migrations.lock` from
  `sql-migrations/`, making shipped migration body edits visible in review and
  CI.
* The historical ledger-fixup script is now dual-schema aware: it targets
  `codd.sql_migrations` for codd 0.1.8+ ledgers and falls back to
  `codd_schema.sql_migrations` for pre-upgrade databases.
* Hardened the apply path: unknown `kiroku-store-migrate` arguments now exit 2
  with usage, bare invocation and `up` are the only apply commands, embedded
  migrations force codd's single-try retry policy, and concurrent applies are
  serialized with a shared PostgreSQL advisory lock.
* Added operator tooling: `kiroku-store-migrate verify` strict-checks a live
  database against the expected-schema snapshot embedded in the binary,
  `kiroku-store-migrate status` reports applied and pending ledger entries, and
  `Kiroku.Store.Migrations.missingMigrations` lets applications fail fast at
  startup when framework migrations have not been applied.

## 0.1.1.0 — 2026-05-31

### New Features

* Forward migration `2026-05-29-15-26-04-add-subscription-dead-letters.sql`:
  creates the `kiroku.dead_letters` table (per consumer-group member, with a
  foreign key to `kiroku.events`) and its recency index, supporting per-event
  dead-letter recording for subscriptions (MasterPlan 6 / plan 40).

## 0.1.0.0 — 2026-05-23

### New Features

* Initial release of the migration package.
* Embeds Kiroku's codd SQL migrations and exposes
  `Kiroku.Store.Migrations`.
* Provides the `kiroku-store-migrate` executable for applying the event store
  schema before application startup.
* Bootstraps the dedicated `kiroku` PostgreSQL schema and installs Kiroku
  tables, indexes, functions, and triggers there.
