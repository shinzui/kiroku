# Changelog

## Unreleased

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
