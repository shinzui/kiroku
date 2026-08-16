# Changelog

## 0.4.0.0 — 2026-08-16

### Breaking Changes

* **The payload of migration `0010` is corrected, which changes its checksum.**
  `pg-migrate` keys an applied migration by `(component, migration)` and
  verifies the exact SHA-256 of its payload bytes, so a database that already
  applied `0010` from 0.3.2.0 or 0.3.2.1 will fail every `up` and `verify` with
  a `MigrationChecksumMismatch` until its ledger row is re-baselined. Run
  `ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql` against such a
  database once, before migrating; it rewrites that one checksum and touches
  nothing else. A database that never reached `0010` — every PostgreSQL 17
  upgrade, which is what this release fixes — needs nothing: `0010` is still
  pending there and applies from the corrected payload.

  Editing a released payload is normally forbidden by this package, and a
  forward migration is the documented remedy. There is none available here: the
  withdrawn payload fails at DDL parse time, so no migration ordered after it
  can ever run. 0.3.2.0 and 0.3.2.1 are deprecated on Hackage.

### Fixes

* Migration `0010` no longer defaults `history_retention_leases.lease_id` to an
  unqualified `uuidv7()` (BUG-1). `uuidv7()` is a PostgreSQL 18 builtin; on
  PostgreSQL 17 the name comes from the fallback `0001` installs into the
  Kiroku schema, reachable only through the `search_path` that `0001` itself
  sets. `0010` therefore parsed on a fresh install, where `0001` had just run in
  the same session, and failed with SQLSTATE 42883 on every ordinary upgrade of
  a database already bootstrapped through `0009`. Reported by Kioku; confirmed
  and fixed against PostgreSQL 17.10.

### New Features

* `kiroku.uuidv7()` is now the component's version-independent, always
  schema-qualified UUIDv7 generator. `0010` publishes it on PostgreSQL 18 as an
  alias for the builtin, and PostgreSQL 17 already had it from `0001`'s
  fallback. Migrations after `0001` can name one generator that resolves without
  any session state on every supported PostgreSQL version.
* Added forward migration `0011`, which converges databases that applied the
  withdrawn `0010`: it publishes `kiroku.uuidv7()` where missing and binds
  `lease_id`'s stored default to it. It is a no-op on a database that applied
  the corrected `0010`. Verified on PostgreSQL 17.10 and 18.4: a converged
  database and a fresh install dump identically.

### Other Changes

* The test suite covers the upgrade path that this defect broke — applying the
  pending tail of the plan in a session that never ran `0001` and cannot reach
  the Kiroku schema through `search_path`. The suite connects as role `kiroku`,
  whose default `"$user"` `search_path` entry resolves to the Kiroku schema, so
  every previous case was masked from exactly this class of failure. The new
  case fails on the withdrawn payload against PostgreSQL 17 and passes on the
  corrected one; on PostgreSQL 18 the builtin makes both payloads parse, so
  PostgreSQL 17 coverage is what guards this.
* The `ledger-fixups/` scripts ship in the source distribution.

## 0.3.2.1 — 2026-08-15

### Other Changes

* Built with `ghc-options: -Wall -Werror=incomplete-patterns`, matching every
  other package in the repository. The `kiroku-store-migrate` executable
  renames a local binding that shadowed `Options.Applicative`'s `command`, and
  the test-suite imports `EphemeralPg.Config` for the ambiguous `user` field.
  No library API or runtime behavior changed.

## 0.3.2.0 — 2026-08-13

### New Features

* Added forward migration `0010`, which installs durable replay-history
  retention leases, a per-schema singleton coordinator, a partial active-lease
  index, and statement-level `DELETE`/`TRUNCATE` guards for `events`,
  `stream_events`, and `streams`. Active retention is refused with SQLSTATE
  `KR001` even when the existing hard-delete GUC is enabled.

## 0.3.1.0 — 2026-08-13

### New Features

* Added forward migration `0009`, which publishes the frozen, structurally read-only
  `kiroku.subscription_checkpoints_v1` relation for exact durable subscription-member
  checkpoints. Database readers can receive schema usage and view selection without access to
  Kiroku's private checkpoint table; no role or grant is created automatically.

## 0.3.0.0 — 2026-07-14

### Breaking Changes

* Upgraded `pg-migrate` to 1.1.0.0. `kiroku-store-migrate check` now takes the
  manifest as `--manifest PATH` instead of a positional argument, matching
  `new --manifest`.

### New Features

* `kiroku-store-migrate up` and `repair` accept explicit `--wait` and
  `--no-statement-timeout` overrides; omitting an execution flag now preserves
  the application's configured runner settings instead of discarding them.
* Successful migration, repair, and history-import runs are no longer replaced
  by an error when advisory unlock or statement-timeout restoration fails; the
  durable report is preserved and the cleanup observation attached to it.

### Fixes

* Adding or removing a migration SQL file without listing it in the manifest no
  longer silently reuses a stale compile-time embedding: the embedding module now
  forces GHC to revalidate manifest membership on every build it runs.

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
