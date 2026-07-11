# Changelog

## Unreleased

## 0.2.0.0 — 2026-07-11

### Breaking Changes

* Migrated the package's runtime from Codd to `pg-migrate`. The public API now
  exports the native `kirokuMigrations` component and `kirokuMigrationPlan`
  instead of Codd settings, runner, ledger-status, and schema-check wrappers.
* Replaced timestamped runtime identities with manifest-ordered `0001` through
  `0007` identities while preserving every SQL payload byte.
* Replaced the Codd CLI and `CODD_*` configuration surface with the standard
  `pg-migrate-cli` command tree and `DATABASE_URL`. `verify` now compares the
  declared plan with the `pgmigrate` ledger; it does not compare live schema
  objects with an expected-schema snapshot.

### New Features

* Added a manifest-backed, compile-time-embedded migration component that
  applications can compose with other libraries in explicit dependency order.
* Added checked-in Codd history mappings and `SamePayload` evidence for safe,
  non-replaying import from current `codd` and legacy `codd_schema` ledgers.
  Shared-ledger consumers can combine Kiroku's exported payloads and mappings
  with their own components before importing.
* Added the standard `pg-migrate-cli` planning, inspection, execution,
  verification, status, and numeric migration-authoring commands.
* Added fresh-apply, rerun, concurrent-apply, strict ledger verification, Codd
  import, partial-row rejection, audit, and source-preservation coverage. The
  full Kiroku store suite now consumes the same native plan through
  `kiroku-test-support`.
* Appended `0008-schema-management-comment`, a non-destructive observable
  native-runner canary. Fresh and imported-prefix tests prove it applies once,
  verifies strictly, and reruns as `AlreadyApplied` without changing historical
  payloads or Codd mappings.

### Changed

* Preserved the seven historical SQL payloads byte-for-byte while moving their
  authoritative ordering to `migrations/manifest`; `migrations.lock` remains
  the source evidence used during Codd history import.
* Removed Codd, `codd-extras`, `file-embed`, and `postgresql-simple` from the
  normal library and executable dependency closure.
* Removed the orphaned Codd expected-schema snapshot, its writer executable, the
  Cabal flag that gated it, and the accompanying Nix closure workaround. Codd
  ledger history import remains supported independently through
  `pg-migrate-import-codd`.

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
