---
id: 16
slug: evaluate-codd-for-first-class-schema-migrations
title: "Evaluate codd for first-class schema migrations"
kind: exec-plan
created_at: 2026-05-16T19:02:01Z
intention: "intention_01krs2kgzqe62t3b31rd6af3k6"
---

# Evaluate codd for first-class schema migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Before this plan, Kiroku created its PostgreSQL schema by running one embedded `kiroku-store/sql/schema.sql` file during every `withStore` startup. That was convenient for a brand-new database, but it was not a real migration story: it could not safely rename columns, change constraints, split tables, or evolve production databases as the library gained new schema versions.

This plan evaluated whether `codd` should become the migration engine behind a first-class Kiroku migration package. A first-class migration package means a consumer can depend on a Kiroku-provided Cabal package, call a documented function or executable before opening `withStore`, and get the correct schema version plus future Kiroku migrations without copying SQL files by hand. The follow-up correction on 2026-05-23 made `kiroku-store-migrations` the only owner of schema SQL by deleting `kiroku-store/sql/schema.sql` and `Kiroku.Store.Schema`; `kiroku-store` now assumes migrations have already run.

The observable outcome is a small consumer-style scenario: start an empty PostgreSQL database, run the Kiroku migration package against it, then open `withStore` and append/read an event. A second run of the same migration command reports no pending migrations, proving the path is repeatable. The core `kiroku-store` package no longer contains migration SQL or a runtime DDL initializer.


## Progress

- [x] Milestone 1: Prove `codd` can run Kiroku's current schema as versioned migrations from this repository. Completed 2026-05-16T19:12:20Z.
- [x] Milestone 2: Build a first-class Kiroku migration package API and a consumer-facing executable. Completed 2026-05-16T19:12:20Z.
- [x] Milestone 3: Adjust store startup so runtime use does not require DDL privileges by default. Completed 2026-05-16T19:12:20Z.
- [x] Milestone 4: Add consumer integration tests and documentation for local, CI, and production use. Completed 2026-05-16T19:12:20Z.
- [x] Follow-up: remove duplicated migration ownership from `kiroku-store` so only `kiroku-store-migrations/sql-migrations` carries schema SQL. Completed 2026-05-23.
- [x] Follow-up: centralize migrated ephemeral PostgreSQL test setup and optimize fixture startup with one cached server plus per-example template database clones. Completed 2026-05-23T20:04:09Z.


## Surprises & Discoveries

- `codd` is registered locally as `mzabani/codd` at `/Users/shinzui/Keikaku/hub/haskell/codd-project`, with one curated doc at `/Users/shinzui/Keikaku/hub/haskell/codd-project/docs/adoption-for-haskell-services.md`. Evidence:

```text
mori registry search codd
mzabani/codd                  library  /Users/shinzui/Keikaku/hub/haskell/codd-project
  └ codd  library  haskell
```

- `codd` has a programmatic library API, not only a CLI. `Codd.applyMigrations` accepts `Maybe [AddedSqlMigration m]`; when this argument is `Just`, callers can provide migrations embedded in a Haskell package instead of asking `codd` to collect SQL files from disk. Evidence from `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd.hs`:

```haskell
applyMigrations ::
  (MonadUnliftIO m, CoddLogger m, MonadThrow m, EnvVars m, NotInTxn m) =>
  CoddSettings ->
  Maybe [AddedSqlMigration m] ->
  DiffTime ->
  VerifySchemas ->
  m ApplyResult
```

- `codd` is forward-only and has no rollback or dry-run mode. The local adoption note calls it viable but pre-1.0, single-maintainer, and strict about one unified schema snapshot per consuming service. This is a real operational risk for a library-published migration package.

- Building `codd` with this repository's GHC 9.12.2 / `time-1.14` toolchain required a targeted `allow-newer: haxl:time` entry because `codd` depends on `haxl`, and `haxl-2.5.1.1` declares `time <1.13`. Evidence:

```text
Could not resolve dependencies:
haxl => time>=1.4 && <1.13
```

- `codd` can parse and apply Kiroku's current schema without weakening the SQL. The migration test applies the embedded bootstrap SQL, verifies the `$all` stream, opens `withStore`, appends and reads one event, and runs migrations again successfully. Evidence:

```text
codd migration spike
  applies Kiroku migrations, opens the store without startup DDL, and is repeatable [✔]

Finished in 0.7740 seconds
1 example, 0 failures
```

- `codd` warns that PostgreSQL 18 may not be fully supported yet. Kiroku requires PostgreSQL 18 for `uuidv7()`, so strict snapshot verification should remain a separate hardening milestone before recommending strict production drift checks. Evidence:

```text
Warn: Not all features of PostgreSQL version v18 may be supported by codd.
```

- The initial implementation left a duplicate schema owner in `kiroku-store`: `Kiroku.Store.Schema` embedded `kiroku-store/sql/schema.sql`, while `kiroku-store-migrations` embedded a timestamped bootstrap copy. Removing the duplication required changing `kiroku-store` tests to apply the migration SQL before opening `withStore`; making the test suite depend on the migration library caused a Cabal component cycle because `kiroku-store-migrations` tests already depend on `kiroku-store`. Evidence:

```text
rejecting: kiroku-store:*test (cyclic dependencies; conflict set: kiroku-store, kiroku-store-migrations)
```

- `ephemeral-pg`'s initdb cache removes PostgreSQL cluster initialization cost, but it does not cache a post-migration schema because the cached directory is created before PostgreSQL starts. Its snapshot API can restore a data directory, but it restarts the server behind the existing handle and is a poor fit for repeated per-example fixture cleanup. The practical optimization is one cached PostgreSQL server per suite, one migrated template database, and per-example `CREATE DATABASE ... TEMPLATE ...` clones.

- A standalone `kiroku-test-support` package cannot depend on `kiroku-store` without creating a Cabal package cycle: `kiroku-store` tests need the support package, while the support package would need `kiroku-store` to open `withStore`. The support package therefore owns only PostgreSQL/migration fixture setup and returns a connection string; each test suite opens its own `KirokuStore`.


## Decision Log

- Decision: Treat this plan as an evaluation with an implementation path, not an unconditional adoption of `codd`.
  Rationale: The requested work is to evaluate whether to use `codd`. The tool has a strong fit because it supports embedded Haskell migrations, but its forward-only and pre-1.0 status must be proven acceptable in this repository before committing the public API.
  Date: 2026-05-16

- Decision: Name the consumer package `kiroku-store-migrations` unless implementation discovers a strong repository convention for `kiroku-migrate`.
  Rationale: Earlier documentation uses `kiroku-migrate` as a generic phrase for a future migration tool. The public package should make its ownership and scope obvious next to `kiroku-store`, `kiroku-otel`, and `shibuya-kiroku-adapter`. The executable can still be named `kiroku-store-migrate`.
  Date: 2026-05-16

- Decision: Do not make `kiroku-store` depend on `codd`.
  Rationale: Runtime event-store users should not pay for migration-tool dependencies in the core library. A separate package lets deploy jobs depend on `codd` while normal application code keeps depending only on `kiroku-store`.
  Date: 2026-05-16

- Decision: Preserve `Kiroku.Store.Schema.initializeSchema` during the transition, but introduce a way for `withStore` to skip startup DDL.
  Rationale: Existing tests and development workflows rely on auto-initialization. Production consumers need to run migrations under an elevated role and run the application under a lower-privilege role, so startup must not require `CREATE` and `TRIGGER` forever.
  Date: 2026-05-16

- Decision: Reopen the completed plan and remove `Kiroku.Store.Schema`, `ConnectionSettingsM.schemaInitialization`, `SchemaInitialization`, and `kiroku-store/sql/schema.sql` instead of preserving a compatibility initializer.
  Rationale: Keeping a runtime DDL bootstrap in `kiroku-store` after creating `kiroku-store-migrations` duplicated schema ownership and invited drift. The migration package is now the only source of schema SQL, while `kiroku-store` only sets `search_path` and starts runtime components.
  Date: 2026-05-23

- Decision: Let `kiroku-store` tests apply the bootstrap SQL file from `kiroku-store-migrations/sql-migrations` directly instead of depending on `kiroku-store-migrations`.
  Rationale: A direct test dependency on `kiroku-store-migrations` creates a package cycle when tests are enabled, because the migration package's integration test imports `kiroku-store`. Reading the SQL file in the core test fixture keeps one SQL source without adding a library dependency cycle.
  Date: 2026-05-23

- Decision: Add a workspace-only `kiroku-test-support` package for migrated ephemeral PostgreSQL fixtures.
  Rationale: The migration SQL application and ephemeral database setup had been duplicated in `kiroku-store` and `shibuya-kiroku-adapter` tests. A shared package removes that duplication without using `hs-source-dirs: ../...`, which Cabal warns is not suitable for source distributions. The package does not depend on `kiroku-store`; callers receive a migrated connection string and open `withStore` locally.
  Date: 2026-05-23

- Decision: Optimize migrated database fixtures with PostgreSQL template database cloning rather than `EphemeralPg.Snapshot.restoreSnapshot`.
  Rationale: `ephemeral-pg` caches initdb output, not a migrated running database. Template database cloning keeps one cached server alive for the suite, migrates once, and gives every example an isolated database with normal PostgreSQL semantics.
  Date: 2026-05-23

- Decision: Accept `codd` for the first implementation, but ship `kiroku-store-migrate` with `LaxCheck` until Kiroku has a checked-in expected-schema snapshot for PostgreSQL 18.
  Rationale: The integration test proves embedded migrations work and are repeatable. Strict checking is the main long-term reason to use `codd`, but this repository does not yet contain a generated expected schema and upstream emits a PostgreSQL 18 support warning.
  Date: 2026-05-16

- Decision: Keep the local `mzabani/codd` optional package path and add a targeted `allow-newer: haxl:time`.
  Rationale: `codd` is not already part of this workspace, and the local registry path is the source of truth found through `mori`. The narrow `allow-newer` is required for the current GHC 9.12.2 toolchain and avoids globally relaxing bounds.
  Date: 2026-05-16


## Outcomes & Retrospective

Implemented a new `kiroku-store-migrations` Cabal package with embedded timestamped SQL migrations, a `Kiroku.Store.Migrations` API, and a `kiroku-store-migrate` executable. The 2026-05-23 follow-up removed the duplicate runtime schema initializer from `kiroku-store`; `withStore` now assumes the configured schema has already been migrated and no longer exposes `SchemaInitialization`.

The consumer-style migration test proves the important behavior: an empty ephemeral PostgreSQL database can be migrated by `codd`, opened through `withStore`, used to append and read an event, and migrated again without duplicate DDL failure. Documentation now describes the forward-only model and the production privilege split.

Strict schema verification remains deferred. The package currently uses `LaxCheck` because there is no checked-in expected-schema snapshot yet, and `codd` warns that PostgreSQL 18 support may be incomplete.

Validation completed on 2026-05-16. `nix fmt` formatted the tree successfully. `cabal build kiroku-store-migrations` succeeded. The focused migration test passed with one example and zero failures. `kiroku-store:kiroku-store-test` passed 128 examples, `kiroku-store-migrations:kiroku-store-migrations-test` passed one example, and `kiroku-otel:kiroku-otel-test` passed six examples. `cabal test all` did not complete because optional dependency suites outside this plan failed: `codd-test` could not execute `hspec-discover`, `hasql-notifications-test` could not open its database, and `shibuya-kiroku-adapter` failed to build against the current local `shibuya-core` API because `Envelope` now requires an `attributes` field.

Follow-up validation on 2026-05-23: `cabal build --disable-benchmarks lib:kiroku-store lib:kiroku-store-migrations` succeeded. `cabal test --disable-benchmarks kiroku-store:kiroku-store-test` passed 158 examples with zero failures. `cabal test --disable-benchmarks kiroku-store-migrations:kiroku-store-migrations-test` passed one example with zero failures.

Performance follow-up validation on 2026-05-23: before the optimization, `cabal test --disable-benchmarks kiroku-store:kiroku-store-test` reported `Finished in 114.3938 seconds` and shell `real 143.02`. After the shared template-database fixture, the same suite reported `Finished in 31.1215 seconds` and shell `real 48.14`. The Shibuya adapter baseline from commit `f96ac8c` reported `Finished in 4.5370 seconds` and shell `real 39.82`; after the shared fixture, `cabal test --disable-benchmarks shibuya-kiroku-adapter:shibuya-kiroku-adapter-test` reported `Finished in 2.5434 seconds`.


## Context and Orientation

Kiroku is a Haskell PostgreSQL event-store library. The main runtime package is `kiroku-store`, defined in `kiroku-store/kiroku-store.cabal`. Its current schema lives in the separate `kiroku-store-migrations` package under `kiroku-store-migrations/sql-migrations`. The bootstrap migration creates four tables: `streams`, `events`, `stream_events`, and `subscriptions`. It also creates indexes and PostgreSQL trigger functions for notifications, immutability, hard-delete protection, and truncate protection.

`Kiroku.Store.Connection.withStore` in `kiroku-store/src/Kiroku/Store/Connection.hs` no longer runs database definition language, abbreviated DDL. DDL is database-definition work such as `CREATE TABLE` or `CREATE TRIGGER`. `withStore` only acquires the connection pool, sets `search_path` for pooled connections, starts the notifier, and starts the event publisher. Operators must run the migration package before opening the store.

The repository recorded the original migration gap in checked-in plans. `docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md` described the problem as F7: the old `initializeSchema` path was idempotent only for additive DDL. `docs/plans/partition-ready-schema.md` is parked, but it names the likely first non-trivial schema change: preparing `events` and `stream_events` for future time-based partitioning. That parked plan explicitly said the work should decide whether to extract schema management before modifying the schema; this plan did that extraction and the 2026-05-23 follow-up removed the old runtime copy.

`codd` is a Haskell PostgreSQL migration tool. In this plan, a migration is one named SQL file whose filename begins with a UTC timestamp such as `2026-05-16-19-10-00-kiroku-bootstrap.sql`. `codd` records which migrations have already run in its own internal PostgreSQL schema, applies pending migrations in order, and can compare the actual database schema to an expected schema snapshot checked into version control. A snapshot is a directory of files that represent database objects; `codd` uses it to detect schema drift.

The local `codd` source and docs were found through `mori`, as required by this repository's `AGENTS.md` instructions:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
mori registry search codd
mori registry show mzabani/codd --full
mori registry docs mzabani/codd
```

The relevant `codd` modules are:

`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd.hs` exposes `applyMigrations`, `applyMigrationsNoCheck`, `ApplyResult`, `CoddSettings`, and `VerifySchemas`.

`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Parsing.hs` exposes `AddedSqlMigration`, `PureStream`, `parseAddedSqlMigration`, and `parseMigrationTimestamp`.

`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Environment.hs` exposes `CoddSettings` and `getCoddSettings`. `CoddSettings` includes the migration connection string, migration directories, expected schema representation, schema selection, roles to check, retry policy, transaction isolation, and schema extraction options.

The local `codd` adoption note at `/Users/shinzui/Keikaku/hub/haskell/codd-project/docs/adoption-for-haskell-services.md` says this exact library-contributes-migrations pattern is supported because `applyMigrations` accepts in-memory migrations. It also names the friction: `codd` is forward-only, pre-1.0, single-maintainer, and expects one whole-database expected-schema snapshot owned by the final service or deployable application.


## Plan of Work

This work proceeds through four milestones. Milestone 1 is a spike with a hard go/no-go gate. If `codd` cannot reliably parse, apply, and verify Kiroku's current schema from an embedded Haskell list, stop after Milestone 1, record a no-go decision in this file, and do not build public API on top of it. If Milestone 1 passes, continue to package extraction.

### Milestone 1 — Prove the `codd` fit

Create a temporary proof of concept inside the repository that converts the then-current runtime schema SQL into a timestamped migration and runs it through `codd` against an ephemeral PostgreSQL database. The goal is not to settle public API names yet; the goal is to prove `codd` accepts the current SQL, creates its internal tracking schema, records the migration, and can run a second time with no duplicate DDL failure.

Add `codd` to the local development plan in the least invasive way. If `codd` is not available from the package index configured for this project, add the local registered path from `mori registry show mzabani/codd --full` to `cabal.project` as an `optional-packages` entry:

```text
optional-packages:
  /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/codd.cabal
```

Do not commit that path if it is only needed for the spike and the final dependency should come from Hackage. If implementation keeps a path override, explain why in the Decision Log.

Create a temporary or test-only module under `kiroku-store/test/Test/CoddSpike.hs` or directly in a new `kiroku-store-migrations` package if the package is already being introduced. The spike should use `Codd.Parsing.parseAddedSqlMigration` with a filename like `2026-05-16-00-00-00-kiroku-bootstrap.sql`. Feed the existing schema SQL as a `PureStream` so the migration is a Haskell value rather than a file discovered from disk.

Acceptance for this milestone is behavioral: one test starts an empty PostgreSQL database, applies the embedded migration with `Codd.applyMigrations`, asserts the `streams` table exists and contains the `$all` row, applies the same migration again, and observes no duplicate-object failure.

If the spike fails because the schema SQL uses syntax `codd` cannot parse, first inspect whether the issue is caused by comments, PL/pgSQL dollar quoting, trigger statements, or `uuidv7()`. If the SQL can be mechanically split into several valid migrations without changing database behavior, proceed. If it requires weakening Kiroku's schema or bypassing `codd` parsing entirely, record a no-go decision.

### Milestone 2 — Build `kiroku-store-migrations`

Add a new Cabal package at `kiroku-store-migrations/kiroku-store-migrations.cabal`. This package owns schema evolution for `kiroku-store`. It should expose `Kiroku.Store.Migrations` and, if practical, an executable named `kiroku-store-migrate`.

Create `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` as the baseline schema for new consumers. Future schema changes add new timestamped SQL files in the same directory instead of editing the bootstrap migration after release.

Create `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` with a small public API. The exact type may be refined during implementation, but it must provide these capabilities:

```haskell
module Kiroku.Store.Migrations
  ( runKirokuMigrations
  , kirokuMigrations
  ) where
```

`kirokuMigrations` returns the embedded Kiroku migrations as `[AddedSqlMigration m]`, using `file-embed` to include the package's `sql-migrations` directory and `parseAddedSqlMigration` to validate timestamps and SQL.

`runKirokuMigrations` accepts enough settings for a consumer to run migrations in a deploy job. Prefer accepting `CoddSettings` directly at first, because it avoids inventing a half-complete wrapper around `codd` configuration. The function should call:

```haskell
applyMigrations settings (Just migrations) connectTimeout StrictCheck
```

If `StrictCheck` is too strict for bootstrap because the repository does not yet have an expected-schema snapshot, use `LaxCheck` for the first implementation and record the reason in the Decision Log. The final acceptance target is strict verification with a checked-in expected schema, because schema-equality verification is the primary reason to choose `codd`.

The executable `kiroku-store-migrate` should be thin. It should read standard `codd` environment variables through `Codd.Environment.getCoddSettings`, run `runKirokuMigrations`, and exit non-zero on migration or strict schema verification failure. It should not parse the Kiroku application connection settings; the migration connection belongs to deployment.

Add the new package to `cabal.project`:

```text
packages:
  kiroku-store
  kiroku-store-migrations
  shibuya-kiroku-adapter
  kiroku-otel
```

Acceptance for this milestone is that `cabal build kiroku-store-migrations` succeeds, the executable runs against an empty ephemeral database, and the module API can be imported by a small test program.

### Milestone 3 — Separate runtime startup from schema creation

The first implementation introduced an opt-out startup DDL switch. The 2026-05-23 follow-up finished the separation by removing the switch and the old initializer entirely. `kiroku-store/src/Kiroku/Store/Connection.hs` now assumes migrations already ran, sets each pooled connection's `search_path`, starts the notifier, and starts the event publisher. It no longer imports `Kiroku.Store.Schema`, and `kiroku-store/kiroku-store.cabal` no longer exposes that module or depends on `file-embed` for schema SQL.

The preferred production path is:

1. Run `kiroku-store-migrate` or `Kiroku.Store.Migrations.runKirokuMigrations` under a migration role.
2. Start the application under the lower-privilege runtime role with `defaultConnectionSettings connString`.

Acceptance for this milestone is that existing tests pass after migrating their disposable databases, and the migration package integration test proves a database migrated by `kiroku-store-migrations` can be opened through `withStore`.

### Milestone 4 — Consumer tests and documentation

Add integration tests that exercise the package the way a downstream service would use it. Put tests under `kiroku-store-migrations/test/Main.hs` if the new package owns the behavior, or under `kiroku-store/test` if that keeps ephemeral PostgreSQL helpers simpler.

The minimum consumer scenario is:

1. Start an ephemeral PostgreSQL database.
2. Build `CoddSettings` for that database, including a temporary expected-schema directory.
3. Run Kiroku migrations.
4. Open `withStore` using `defaultConnectionSettings connString` updated to skip schema initialization.
5. Append one event and read it back through the public API.
6. Run migrations again and assert it succeeds with no pending changes.

Document the workflow in a new `kiroku-store-migrations/README.md` and update `docs/PRODUCTION-DEPLOYMENT.md`. The README must explain `codd`'s forward-only model in plain language: once a migration has run in production, reverting the package version does not undo database changes; operators must write a new forward migration to repair state.

Acceptance for this milestone is that a novice can follow the README against a local database and observe the schema being created, the event-store API working, and the second migration run being a no-op.


## Concrete Steps

All commands run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

First confirm project identity and dependency locations through `mori`:

```bash
mori show --full
mori registry search codd
mori registry show mzabani/codd --full
mori registry docs mzabani/codd
```

Expected evidence includes:

```text
Name: shinzui/kiroku
Packages: kiroku-store, shibuya-kiroku-adapter, kiroku-otel
Dependencies include hasql/hasql, hasql-pool, ephemeral-pg, shibuya

mzabani/codd
Path: /Users/shinzui/Keikaku/hub/haskell/codd-project
Package: codd
Docs: adoption-haskell-services
```

Before changing code, inspect the current migration schema and startup path:

```bash
sed -n '1,220p' kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql
sed -n '1,260p' kiroku-store/src/Kiroku/Store/Connection.hs
sed -n '1,220p' kiroku-store/kiroku-store.cabal
sed -n '1,120p' kiroku-store-migrations/kiroku-store-migrations.cabal
```

Inspect the relevant `codd` API on disk:

```bash
sed -n '1,140p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd.hs
sed -n '50,240p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Environment.hs
sed -n '160,230p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Parsing.hs
sed -n '1240,1275p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Parsing.hs
```

After Milestone 1 code exists, run the focused migration spike test. Replace the test pattern with the actual Hspec description if the implementer chooses a different name:

```bash
cabal test kiroku-store:kiroku-store-test --test-options='--match "codd migration spike"'
```

Expected result:

```text
1 example, 0 failures
```

After adding the package, build it:

```bash
cabal build kiroku-store-migrations
```

Expected result:

```text
Build profile: -w ghc-9.12.2 -O1
Dependency resolution and build steps for the new package appear here.
Build completed successfully.
```

Run the full test suite after each milestone that changes public code:

```bash
cabal test all
```

Expected result:

```text
Test suite kiroku-store-test: PASS
Test suite kiroku-otel-test: PASS
Test suite shibuya-kiroku-adapter-test: PASS
```

If a new `kiroku-store-migrations-test` suite is added, it must also appear in the successful output.

Run formatting before the final commit:

```bash
nix fmt
```

Commit messages must use Conventional Commits and include this plan trailer:

```text
ExecPlan: docs/plans/16-evaluate-codd-for-first-class-schema-migrations.md
Intention: intention_01krs2kgzqe62t3b31rd6af3k6
```


## Validation and Acceptance

The evaluation accepts `codd` only if all of these are true:

1. `codd` can parse and apply the current Kiroku schema as timestamped SQL migrations without weakening the schema.
2. Migrations can be embedded and provided through `applyMigrations settings (Just migrations) ...`, so consumers do not need to locate Kiroku SQL files on disk.
3. A second migration run against the same database succeeds without reapplying the bootstrap migration.
4. A database migrated by `kiroku-store-migrations` can be used by `kiroku-store` to append and read events.
5. Runtime startup can skip schema initialization so the application user does not need DDL privileges.
6. The documentation states the forward-only rollback tradeoff and the owner of expected schema snapshots.

The main acceptance command is:

```bash
cabal test all
```

The end-to-end acceptance behavior is:

```text
Given an empty PostgreSQL database,
when kiroku-store-migrate runs with CODD_CONNECTION pointing at that database,
then the database contains streams, events, stream_events, and subscriptions,
and streams contains stream_id = 0 with stream_name = '$all'.

Given the migrated database,
when a service opens Kiroku.Store.withStore,
then startup succeeds without running schema DDL,
and appendToStream followed by readStreamForward returns the appended event.

Given the same database,
when kiroku-store-migrate runs a second time,
then it exits successfully and reports no pending Kiroku migrations.
```

If strict schema verification is part of the final package, add one test that intentionally changes the expected schema directory or creates a drift object and proves `StrictCheck` fails. If strict verification is deferred, the Decision Log must explain the blocker and `docs/PRODUCTION-DEPLOYMENT.md` must tell operators to start with lax checking.


## Idempotence and Recovery

All proof-of-concept and integration tests must use ephemeral PostgreSQL databases or disposable local databases. They are safe to rerun because a failed test database is discarded.

Do not run a new migration package against a shared development or production database until Milestone 1 and Milestone 2 tests pass. `codd` is forward-only: once it records a migration in a real database, reverting the Haskell package does not undo the database change. Recovery from a bad real migration is another forward migration or a database restore from backup.

The bootstrap migration file must not be edited after it has been released to consumers. If the baseline schema needs to change after release, add a new timestamped migration. Editing an already-released migration creates a mismatch between new databases and databases that already ran the original SQL.

If `ConnectionSettings` changes and tests fail widely, verify first that the test fixture migrates its disposable database before opening `withStore`. Do not reintroduce runtime DDL in `kiroku-store`; the 2026-05-23 Decision Log records the breaking-change decision to remove the compatibility initializer.

If `codd` strict schema snapshots produce noisy diffs because of PostgreSQL version differences, first constrain validation to the PostgreSQL major version Kiroku already requires. If noise remains under the same PostgreSQL major version, log the issue in Surprises & Discoveries and decide whether `codd` remains suitable.


## Interfaces and Dependencies

Repository interfaces:

`kiroku-store/src/Kiroku/Store/Connection.hs` owns `ConnectionSettingsM m`, `ConnectionSettings`, `defaultConnectionSettings`, and `withStore`. It no longer owns schema creation. `withStore` sets `search_path` to the configured schema and assumes the objects were created by migrations.

`kiroku-store-migrations/sql-migrations` is the source for schema SQL. Treat future schema changes as migrations first. Do not add a second schema script under `kiroku-store`.

New package interfaces:

`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` must expose embedded migrations and a runner. Initial target:

```haskell
kirokuMigrations ::
  (Monad m, EnvVars m) =>
  m [AddedSqlMigration m]

runKirokuMigrations ::
  CoddSettings ->
  DiffTime ->
  VerifySchemas ->
  IO ApplyResult
```

The exact constraints may need to become `MonadUnliftIO`, `CoddLogger`, `MonadThrow`, or `NotInTxn`, matching `Codd.applyMigrations`. Prefer a simple `IO` API for public consumers and a more general internal helper only if tests need it.

`kiroku-store-migrations/app/Main.hs` should read `Codd.Environment.getCoddSettings` and call the public runner.

External dependencies, located with `mori`:

`codd` from `mzabani/codd` supplies:

```haskell
applyMigrations ::
  (MonadUnliftIO m, CoddLogger m, MonadThrow m, EnvVars m, NotInTxn m) =>
  CoddSettings ->
  Maybe [AddedSqlMigration m] ->
  DiffTime ->
  VerifySchemas ->
  m ApplyResult
```

`Codd.Parsing.parseAddedSqlMigration` supplies:

```haskell
parseAddedSqlMigration ::
  (Monad m, MigrationStream m s, EnvVars m) =>
  String ->
  s ->
  m (Either String (AddedSqlMigration m))
```

`file-embed` supplies `embedDir` or `embedFile` for shipping SQL migrations inside the Haskell package.

`ephemeral-pg` is already used by `kiroku-store` tests and should be used for migration integration tests so they do not require a developer-owned PostgreSQL database.

Operational environment variables for the executable follow `codd` conventions:

```bash
CODD_CONNECTION=postgres://postgres@127.0.0.1:5432/kiroku
CODD_MIGRATION_DIRS=unused-when-using-embedded-migrations
CODD_EXPECTED_SCHEMA_DIR=kiroku-store-migrations/expected-schema
CODD_SCHEMAS=kiroku
```

Even though embedded migrations bypass disk-based migration collection, `CoddSettings` still contains `sqlMigrations` and `onDiskReps`, so the executable should either require valid `codd` environment variables or construct `CoddSettings` explicitly from a smaller Kiroku-specific configuration. Prefer starting with standard `codd` environment variables because they are documented by upstream and reduce custom surface area.


## Revision Note — 2026-05-23

Reopened the completed plan because the initial implementation created `kiroku-store-migrations` but left duplicate schema SQL and schema initialization in `kiroku-store`. This revision records the follow-up correction: `kiroku-store-migrations/sql-migrations` is now the only schema SQL owner, `kiroku-store/sql/schema.sql` and `Kiroku.Store.Schema` were removed, `withStore` no longer runs DDL, tests migrate disposable databases before opening the store, and validation was rerun for both changed packages.


## Revision Note — 2026-05-23 Performance Follow-Up

Added a shared `kiroku-test-support` fixture package and recorded the before/after measurements for migrated ephemeral PostgreSQL tests. The fixture uses one cached `ephemeral-pg` server per suite, migrates a template database once, and gives each example a fresh PostgreSQL database cloned from that template.
