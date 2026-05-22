---
id: 20
slug: install-kiroku-objects-in-a-dedicated-schema
title: "Install Kiroku objects in a dedicated schema"
kind: exec-plan
created_at: 2026-05-17T22:10:24Z
intention: intention_01krvzp0ffewy9baedxxg1w80t
---

# Install Kiroku objects in a dedicated schema

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku currently installs its PostgreSQL tables, indexes, sequences, trigger functions, and triggers into whichever schema appears first in a connection's `search_path`; with default PostgreSQL settings that means `public`. After this change, a fresh Kiroku installation creates and uses a dedicated PostgreSQL schema named `kiroku`, leaving the `public` schema free for application-owned objects or other libraries. A PostgreSQL schema is a namespace inside one database; moving Kiroku objects under `kiroku` lets operators inspect, grant privileges on, back up, or eventually drop Kiroku-owned database objects as one named group.

The behavior is visible without reading code: after startup schema initialization or `kiroku-store-migrate`, `SELECT table_schema, table_name FROM information_schema.tables WHERE table_name IN ('streams', 'events', 'stream_events', 'subscriptions')` returns rows under `kiroku`, and a complementary query against `public` returns no Kiroku tables. Normal store operations still work through the Haskell API, including appends, reads, subscriptions, durable checkpoints, UUIDv7 defaults, and hard-delete protections.


## Progress

- [x] (2026-05-17 22:10Z) Researched the current schema bootstrap SQL, embedded migration package, connection settings, notification path, tests, docs, and benchmark SQL.
- [x] (2026-05-17 22:10Z) Created this ExecPlan with `bun agents/skills/exec-plan/init-plan.ts --title "Install Kiroku objects in a dedicated schema"`.
- [x] (2026-05-21) Milestone 1: Make fresh schema initialization install every Kiroku-owned object under `kiroku` and make runtime sessions resolve unqualified SQL there. Added `__KIROKU_SCHEMA__` sentinel + `CREATE SCHEMA`/`SET search_path` to `schema.sql`; `initializeSchema` now substitutes the quoted schema; `quoteIdentifier` added to `Kiroku.Store.Schema`; `defaultConnectionSettings` defaults `schema = "kiroku"`; `initScript` sets `search_path` first. `cabal test kiroku-store:kiroku-store-test` → 152 examples, 0 failures.
- [x] (2026-05-21) Milestone 2: Update codd migrations, migration tests, and operator docs so production-style migration installs and verifies the `kiroku` schema. Bootstrap migration regenerated from `schema.sql` (sentinel → `kiroku`), re-syncing the consumer-group divergence. `testCoddSettings` now uses `IncludeSchemas [SqlSchema "kiroku"]`; bootstrap/UUID asserts are `kiroku.`-qualified; added `assertSchemaPlacement` (all four tables in `kiroku`, none in `public`). `CODD_SCHEMAS=kiroku` in both READMEs. `cabal test kiroku-store-migrations:kiroku-store-migrations-test` → 1 example, 0 failures.
- [ ] Milestone 3: Update direct SQL tests, benchmark scripts, and documentation to prove `public` stays clean while existing store behavior still works.


## Surprises & Discoveries

- (2026-05-21) `kiroku-store/sql/schema.sql` and the bootstrap migration
  `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`
  are **not** currently identical, contrary to the Context section's
  assumption. Commit `76c6574` ("feat(store): per-member subscription
  checkpoints + schema convergence (EP-1 M2)") added `consumer_group_member`
  and `consumer_group_size` columns plus the convergence
  `ALTER TABLE`/`CREATE UNIQUE INDEX` block to `schema.sql`, but the bootstrap
  migration still has the old `subscriptions` definition
  (`subscription_name TEXT NOT NULL UNIQUE`, no consumer-group columns). The
  `diff` confirming this:

  ```text
  <     subscription_name     TEXT         NOT NULL,
  <     consumer_group_member INT          NOT NULL DEFAULT 0,
  <     consumer_group_size   INT          NOT NULL DEFAULT 1,
  ---
  >     subscription_name TEXT         NOT NULL UNIQUE,
  ```

  Since Milestone 2 must make the bootstrap migration "match the final
  fresh-install behavior from `schema.sql`", syncing the schema-relocation
  change is the moment to re-sync the consumer-group divergence too. The
  migration is regenerated as a verbatim copy of `schema.sql` with the
  `__KIROKU_SCHEMA__` sentinel replaced by the literal `kiroku`. The
  convergence `ALTER`/`CREATE INDEX` statements are harmless no-ops on a fresh
  install (the columns already exist; the old auto-named constraint never
  existed).


## Decision Log

- Decision: Keep the SQL statements in `kiroku-store/src/Kiroku/Store/SQL.hs` unqualified and make every Kiroku-owned connection set `search_path` to the configured schema.
  Rationale: The prepared statements currently refer to `streams`, `events`, `stream_events`, and `subscriptions` hundreds of times. Setting `search_path` preserves the existing statement text, keeps a future custom schema setting possible, and matches the current comments that unqualified names resolve through the database search path.
  Date: 2026-05-17

- Decision: Default `ConnectionSettings.schema` should become `"kiroku"` and should control both `search_path` and the `LISTEN` channel.
  Rationale: Today the field only controls notification channel construction while table resolution depends on connection-string `search_path`. That split is the main source of misconfiguration. Making the field authoritative for both table resolution and notifications gives users a single setting and satisfies the goal that Kiroku installs into its own schema by default.
  Date: 2026-05-17

- Decision: The bootstrap SQL should create `kiroku` explicitly and set `search_path` to `kiroku, pg_catalog` before creating objects.
  Rationale: `CREATE SCHEMA IF NOT EXISTS kiroku` makes fresh installs idempotent. Putting `pg_catalog` in the path keeps built-in functions visible while avoiding accidental fallback to `public` for Kiroku object names.
  Date: 2026-05-17

- Decision: Keep PostgreSQL 18's `pg_catalog.uuidv7()` as the preferred UUID generator and create a fallback function inside `kiroku`, not `public`, on PostgreSQL 17.
  Rationale: The user asked to leave `public` clean. An unqualified `DEFAULT uuidv7()` can resolve to `pg_catalog.uuidv7()` on PostgreSQL 18 or to `kiroku.uuidv7()` on PostgreSQL 17 when sessions use the `kiroku, pg_catalog` search path.
  Date: 2026-05-17

- Decision: Take the schema-configurable ("sentinel") path for `schema.sql`,
  not the static hardcoded-`kiroku` path. `schema.sql` uses a literal
  `__KIROKU_SCHEMA__` token in `CREATE SCHEMA` and `SET search_path`;
  `Kiroku.Store.Schema.initializeSchema` replaces it with the configured,
  double-quoted schema identifier before executing the script, so the
  `ConnectionSettings.schema` field genuinely controls where objects install
  via `withStore`. `just init-schema` substitutes the literal `kiroku` with
  `sed` before piping to `psql`.
  Rationale: The plan's Interfaces section names this the preferred approach and
  it makes `initializeSchema` actually use its `Text` argument. A purely
  hardcoded `schema.sql` combined with a configurable runtime `search_path`
  would silently install objects in `kiroku` while runtime statements looked in
  the configured schema — an inconsistency worse than the status quo.
  Date: 2026-05-21

- Decision: `setval('streams_stream_id_seq', ...)` and every other Kiroku
  object reference in `schema.sql` stay unqualified after the `SET search_path`
  line, rather than being rewritten to `kiroku.`-qualified or `::regclass`
  forms. Because `SET search_path TO <schema>, pg_catalog` runs first in the
  same session, unqualified text-to-`regclass` resolution already lands in the
  Kiroku schema. This keeps the sentinel to exactly two sites and the file
  readable.
  Rationale: Fewer substitution sites means less chance of a half-quoted
  identifier; the search path already guarantees correct resolution.
  Date: 2026-05-21

- Decision: The bootstrap migration is regenerated as a verbatim copy of
  `schema.sql` with `__KIROKU_SCHEMA__` replaced by the bare identifier
  `kiroku` (codd parses the file directly and cannot run the Haskell sentinel
  substitution). Editing the initial migration in place is acceptable because
  the project is explicitly experimental and unreleased (`README.md` "Status"
  section), so no production database has applied it.
  Rationale: Keeping the migration a literal projection of `schema.sql` keeps
  the two in sync (also fixing the pre-existing consumer-group divergence) and
  satisfies the "match fresh-install behavior" requirement.
  Date: 2026-05-21

- Decision: `quoteIdentifier :: Text -> Text` lives in `Kiroku.Store.Schema`
  (exported) and is imported by `Kiroku.Store.Connection`, rather than being
  duplicated in both modules.
  Rationale: Both the sentinel substitution (Schema) and the runtime
  `search_path` init (Connection) need identical identifier quoting; one source
  of truth avoids drift.
  Date: 2026-05-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a Haskell event store backed by PostgreSQL. The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The `mori.dhall` file identifies this repository as `shinzui/kiroku`, with `kiroku-store` as the core Haskell library and `kiroku-store-migrations` as the embedded codd migration package. A PostgreSQL event store records immutable event payloads in a database and links those events into named streams, including the global `$all` stream whose position is used for subscriptions and catch-up reads.

The canonical bootstrap SQL lives in `kiroku-store/sql/schema.sql`. That file currently creates a `uuidv7()` fallback function, tables named `streams`, `events`, `stream_events`, and `subscriptions`, supporting indexes, trigger functions named `notify_events()`, `prevent_mutation()`, `protect_deletion()`, and `protect_truncation()`, and triggers on `streams`, `events`, and `stream_events`. The same SQL is copied into the first codd migration at `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`. The two files are currently identical and should remain logically equivalent for fresh installs.

Startup schema initialization is implemented by `kiroku-store/src/Kiroku/Store/Schema.hs`. It embeds `kiroku-store/sql/schema.sql` with `file-embed` and runs it with `Hasql.Session.script`. The `initializeSchema :: Pool -> Text -> m ()` function receives a schema name but ignores it today. Its Haddock explicitly says the argument is unused and that SQL names resolve through PostgreSQL `search_path`. In PostgreSQL, `search_path` is a session setting that tells the database which schema to search first when a query uses an unqualified object name such as `streams`.

Runtime SQL statements live in `kiroku-store/src/Kiroku/Store/SQL.hs`. They are all unqualified: they say `FROM streams`, `INSERT INTO events`, `DELETE FROM stream_events`, `FROM subscriptions`, and so on. This is safe only when every pooled connection has a `search_path` that resolves those names to the intended Kiroku schema. The direct test helpers in `kiroku-store/test/Test/Helpers.hs` also use unqualified direct SQL for assertions such as `SELECT COUNT(*) FROM events`, `INSERT INTO events ...`, and `TRUNCATE events`.

Connection setup lives in `kiroku-store/src/Kiroku/Store/Connection.hs`. `ConnectionSettings.schema` currently defaults to `"public"` and its documentation says it only controls the notification channel name. `withStore` builds a `hasql-pool` pool with an `initSession` that sets timeout values, optionally calls `initializeSchema`, then starts the notifier. `Kiroku.Store.Notification.startNotifier` creates a separate PostgreSQL connection and issues `LISTEN <schema>.events`; the trigger function in `schema.sql` publishes notifications with `pg_notify(TG_TABLE_SCHEMA || '.events', payload)`. For notifications to wake subscriptions, the table's actual schema and the listener's configured schema must match byte-for-byte.

Production-style migrations are in `kiroku-store-migrations`. `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` embeds timestamped SQL files and passes them to `Codd.applyMigrations`. `kiroku-store-migrations/test/Main.hs` applies migrations to an ephemeral PostgreSQL database, verifies that `$all` exists, verifies UUIDv7 defaults, opens `withStore` with `SkipSchemaInitialization`, appends an event, reads it back, and reruns migrations to prove repeatability. This test currently checks `IncludeSchemas [SqlSchema "public"]` and queries unqualified `streams` and `events`, so it must move to `kiroku`.

The dependency lookup rule in `AGENTS.md` was followed during plan creation. `mori show --full` identified this project. `mori registry search codd`, `mori registry show mzabani/codd --full`, and `mori registry docs mzabani/codd` showed that codd supports programmatic in-memory migrations and schema selection. The local codd docs and source confirm `CODD_SCHEMAS` is a space-separated list of schemas to check and that the Haskell API uses `IncludeSchemas [SqlSchema "..."]`.


## Plan of Work

Milestone 1 changes the development/bootstrap path. Edit `kiroku-store/sql/schema.sql` so the first DDL statements are `CREATE SCHEMA IF NOT EXISTS kiroku;` followed by `SET search_path TO kiroku, pg_catalog;`. Change the PostgreSQL 17 UUID fallback guard so it checks both `pg_catalog.uuidv7()` and `kiroku.uuidv7()` rather than any function named `uuidv7()` in the current path, then create the fallback as `kiroku.uuidv7()` or rely on the search path after it has been set. Keep `events.event_id DEFAULT uuidv7()` so PostgreSQL 18 resolves the built-in from `pg_catalog` and PostgreSQL 17 resolves the fallback from `kiroku`. Update sequence maintenance to use the schema-safe regclass form, for example `setval('kiroku.streams_stream_id_seq'::regclass, ...)`, because `setval(text, bigint)` depends on name resolution. Leave table, index, trigger, and function names unqualified after the `SET search_path`; that keeps the file readable while making the target schema explicit.

In the same milestone, update `kiroku-store/src/Kiroku/Store/Connection.hs`. Change `defaultConnectionSettings` so `schema = "kiroku"`. Update the `schema` field Haddock to say the field controls the target schema, `search_path`, and the notification channel. Extend `initScript` so every pooled connection runs `SET search_path TO <schema>, pg_catalog` before timeout settings. Because schema names are SQL identifiers, do not interpolate raw user text directly into SQL. Add a small helper in this module, for example `quoteIdentifier :: Text -> Text`, that double-quotes the configured schema name and escapes any embedded double quote as two double quotes. Use it in `SET search_path TO "kiroku", pg_catalog`. Keep `Notifier.startNotifier cs s ...` using the unquoted logical schema value, because `hasql-notifications` receives a PostgreSQL identifier value for the channel and the trigger publishes `TG_TABLE_SCHEMA || '.events'`.

Finish Milestone 1 by updating `kiroku-store/src/Kiroku/Store/Schema.hs`. `initializeSchema` should no longer ignore its `Text` argument. The minimum acceptable implementation is to pass the schema name through to an updated SQL script if the project supports only the default `kiroku` schema; the better implementation is to make the bootstrap script schema-configurable by replacing a sentinel such as `__KIROKU_SCHEMA__` before execution. If choosing the configurable path, change `schema.sql` to use the sentinel in `CREATE SCHEMA`, `SET search_path`, fallback guard, and the `setval` regclass literal, then have `initializeSchema` quote the schema identifier and quote the regclass string safely. The acceptance criterion is that `withStore (defaultConnectionSettings connString)` creates Kiroku objects in `kiroku`, starts subscriptions listening on `kiroku.events`, and all existing API tests that use the default settings pass.

Milestone 2 updates the production migration path. Make `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` match the final fresh-install behavior from `kiroku-store/sql/schema.sql`. This is the initial migration in an experimental project, so editing it is acceptable only if this repository has not released it to production users; if it has been released, replace this instruction with a new timestamped forward migration that creates `kiroku`, copies or moves existing `public` objects, and updates defaults, functions, triggers, and sequences. The current docs already say migrations are forward-only, so record that judgment in this plan's Decision Log if implementation discovers a release boundary.

Update `kiroku-store-migrations/test/Main.hs` so `testCoddSettings` uses `IncludeSchemas [SqlSchema "kiroku"]`. Change `assertBootstrapApplied`, `bootstrapStmt`, `defaultUuidStmt`, and any other direct migration test SQL to schema-qualified names such as `kiroku.streams` and `kiroku.events`, or set the verification pool's `initSession` to `SET search_path TO kiroku, pg_catalog` and add a separate assertion that `public` does not contain Kiroku tables. The stronger acceptance check is both: direct schema-qualified queries prove where objects exist, and a clean-public query proves they do not exist in `public`.

Milestone 3 updates the rest of the repository around the new default. In `kiroku-store/test/Test/Helpers.hs`, keep direct helper SQL unqualified when it runs through `store.pool`, because Milestone 1 makes the pool's `search_path` authoritative. Add one or more tests in `kiroku-store/test/Main.hs` under the existing `"schema initialization"` describe block. The tests should assert that `to_regclass('kiroku.streams')`, `to_regclass('kiroku.events')`, `to_regclass('kiroku.stream_events')`, and `to_regclass('kiroku.subscriptions')` are non-null, while `to_regclass('public.streams')`, `to_regclass('public.events')`, `to_regclass('public.stream_events')`, and `to_regclass('public.subscriptions')` are null. Add a notification-oriented test if there is not already one that proves a live subscription receives an append under the default schema; this guards the `kiroku.events` channel alignment.

Update docs in `README.md`, `docs/user/schema.md`, `docs/user/schema-migrations.md`, and `kiroku-store-migrations/README.md`. Replace examples that say `CODD_SCHEMAS=public` with `CODD_SCHEMAS=kiroku`. Explain that Kiroku creates the `kiroku` schema by default and that runtime roles need privileges on that schema rather than on `public`. Revise comments in `kiroku-store/src/Kiroku/Store/Schema.hs` and `kiroku-store/src/Kiroku/Store/Connection.hs` so they no longer describe `public` as the default target or say the schema argument is unused.

Finally inspect `kiroku-store/bench/sql/*.sql` and the `justfile`. The benchmark scripts are raw `psql` files that currently assume unqualified names resolve to the Kiroku tables. The most robust update is to add `SET search_path TO kiroku, pg_catalog;` to `kiroku-store/bench/sql/setup.sql`, `kiroku-store/bench/sql/reset.sql`, and every standalone benchmark SQL file that can be run independently by `pgbench`; alternatively schema-qualify every Kiroku table and function reference. Update `just init-schema` to run the updated schema file as before, then add a note that it creates the `kiroku` schema.


## Concrete Steps

All commands below run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Before editing, re-run the repository and dependency orientation commands so the implementer starts from current facts:

```bash
mori show --full
mori registry search codd
mori registry show mzabani/codd --full
rg -n "public|search_path|CREATE TABLE|CREATE FUNCTION|CREATE TRIGGER|streams|events|stream_events|subscriptions|uuidv7" \
  kiroku-store kiroku-store-migrations docs/user README.md justfile
```

The important expected facts are that this repo is `shinzui/kiroku`, the `kiroku-store` package contains the runtime, `kiroku-store-migrations` contains codd migrations, codd is available at `/Users/shinzui/Keikaku/hub/haskell/codd-project`, and the current schema files contain unqualified `CREATE TABLE IF NOT EXISTS streams`, `events`, `stream_events`, and `subscriptions`.

Implement Milestone 1 edits in these files:

```text
kiroku-store/sql/schema.sql
kiroku-store/src/Kiroku/Store/Connection.hs
kiroku-store/src/Kiroku/Store/Schema.hs
```

After editing, verify that the schema file contains the dedicated schema setup and does not create unqualified objects before the `SET search_path` line:

```bash
sed -n '1,80p' kiroku-store/sql/schema.sql
rg -n "public-schema|schema argument is unused|schema = \"public\"|SET search_path" kiroku-store/src kiroku-store/sql/schema.sql
```

Expected result: the first command shows `CREATE SCHEMA IF NOT EXISTS kiroku;` and `SET search_path TO kiroku, pg_catalog;` near the top, and the second command no longer finds comments claiming the schema argument is unused or defaulting to `public`.

Implement Milestone 2 edits in these files:

```text
kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql
kiroku-store-migrations/test/Main.hs
kiroku-store-migrations/README.md
docs/user/schema-migrations.md
```

Check that migration docs and tests refer to `kiroku`:

```bash
rg -n "CODD_SCHEMAS|IncludeSchemas|SqlSchema|public\\.(streams|events|stream_events|subscriptions)|kiroku\\.(streams|events|stream_events|subscriptions)" \
  kiroku-store-migrations docs/user/schema-migrations.md
```

Expected result: `CODD_SCHEMAS=kiroku` appears in docs, `IncludeSchemas [SqlSchema "kiroku"]` appears in `kiroku-store-migrations/test/Main.hs`, and any direct table assertions either use `kiroku.<table>` or explicitly assert `public.<table>` is absent.

Implement Milestone 3 edits in these files:

```text
kiroku-store/test/Main.hs
kiroku-store/test/Test/Helpers.hs
kiroku-store/bench/sql/*.sql
README.md
docs/user/schema.md
justfile
```

Use `rg` to catch stale assumptions:

```bash
rg -n "public|CODD_SCHEMAS=public|schema = \"public\"|public-schema fallback|unused.*schema|FROM events|FROM streams|TRUNCATE events|uuidv7\\(\\)" \
  README.md docs/user kiroku-store/src kiroku-store/test kiroku-store/bench/sql kiroku-store-migrations justfile
```

Some unqualified SQL references should remain in `Kiroku.Store.SQL` and test helpers because runtime `search_path` handles them. Stale documentation that says Kiroku installs into `public` or that `ConnectionSettings.schema` is only a notification setting should be gone.

Run formatting and tests:

```bash
nix fmt
cabal test kiroku-store:kiroku-store-test
cabal test kiroku-store-migrations:kiroku-store-migrations-test
```

Expected successful test output is package-dependent, but it should end with `Test suite kiroku-store-test: PASS` and `Test suite kiroku-store-migrations-test: PASS`. If local time is limited, `cabal test all` is the broader final command:

```bash
cabal test all
```

If implementation includes benchmark SQL edits, smoke-test the benchmark setup against a local database only after confirming PostgreSQL is available:

```bash
just reset-database
psql -d kiroku -Atc "SELECT to_regclass('kiroku.streams') IS NOT NULL, to_regclass('public.streams') IS NULL"
```

Expected output:

```text
t|t
```


## Validation and Acceptance

The primary acceptance criterion is a fresh database initialized through `withStore` has Kiroku objects in `kiroku` and not in `public`, while the Haskell API behaves exactly as before. Add or update automated tests so `cabal test kiroku-store:kiroku-store-test` proves all of the following in one ephemeral PostgreSQL run: `withStore (defaultConnectionSettings connString)` succeeds, `to_regclass('kiroku.streams')`, `to_regclass('kiroku.events')`, `to_regclass('kiroku.stream_events')`, and `to_regclass('kiroku.subscriptions')` are present, the matching `public` regclass checks are absent, appending to a new stream succeeds, reading that stream returns the appended event, a direct insert into `events` without `event_id` returns a UUIDv7-shaped value, and a live subscription wakes from `LISTEN/NOTIFY` after an append.

The production migration acceptance criterion is that `cabal test kiroku-store-migrations:kiroku-store-migrations-test` applies embedded codd migrations, sees `$all` in `kiroku.streams`, sees no Kiroku tables in `public`, opens the store with `SkipSchemaInitialization`, appends and reads an event, and applies migrations again without trying to recreate objects or failing schema checks. The codd settings in this test must use `IncludeSchemas [SqlSchema "kiroku"]`.

The documentation acceptance criterion is that a user following `kiroku-store-migrations/README.md` or `docs/user/schema-migrations.md` runs with `CODD_SCHEMAS=kiroku`, understands that Kiroku creates a dedicated schema, and understands that runtime users need access to `kiroku` rather than unmanaged privileges on `public`. The schema reference in `docs/user/schema.md` should name objects as `kiroku.streams`, `kiroku.events`, `kiroku.stream_events`, and `kiroku.subscriptions` at least once near the top, then may use short names after explaining that short names assume `search_path` is set to `kiroku, pg_catalog`.

Manual verification on a local PostgreSQL database should look like this:

```bash
just reset-database
psql -d kiroku -Atc "SELECT table_schema, table_name FROM information_schema.tables WHERE table_name IN ('streams','events','stream_events','subscriptions') ORDER BY table_schema, table_name"
```

Expected output:

```text
kiroku|events
kiroku|stream_events
kiroku|streams
kiroku|subscriptions
```

Then confirm public is clean:

```bash
psql -d kiroku -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('streams','events','stream_events','subscriptions')"
```

Expected output:

```text
0
```


## Idempotence and Recovery

Fresh bootstrap remains idempotent when it uses `CREATE SCHEMA IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `DROP TRIGGER IF EXISTS` followed by `CREATE TRIGGER`, and `INSERT ... ON CONFLICT DO NOTHING`. `SET search_path` is session-local and safe to run on every pooled connection. `SELECT setval(... GREATEST(...))` is safe to rerun because it moves the sequence to at least the current maximum `streams.stream_id`.

Changing the first codd migration is safe only before that migration is released to real users. If implementation discovers that users may already have applied `2026-05-16-00-00-00-kiroku-bootstrap.sql`, do not silently rewrite history. Instead, add a new timestamped migration under `kiroku-store-migrations/sql-migrations/` that creates `kiroku` and migrates or recreates objects in a forward-only way. For a live database that already has Kiroku objects in `public`, a safe production migration must be planned separately: it needs an outage or controlled maintenance window, must take a backup first, must move tables and dependent sequences/functions/triggers with `ALTER ... SET SCHEMA` where possible, and must verify that application connections use the new `search_path` before writes resume.

If tests fail because unqualified runtime SQL cannot find tables, inspect `SHOW search_path` through the same `hasql-pool` connection that failed. The likely recovery is to fix `ConnectionSettings.initSession` so it sets the configured schema before any prepared statement runs. If subscriptions stop waking but polling eventually catches up, inspect the channel names: `notify_events()` publishes `TG_TABLE_SCHEMA || '.events'`, and the notifier listens to `settings.schema <> ".events"`. Those must both be `kiroku.events` under the default configuration.

If local database commands leave a developer database in an unwanted state, use the existing development reset:

```bash
just reset-database
```

This drops and recreates the local `kiroku` database, then runs the bootstrap SQL. Do not use destructive commands against any non-local database unless the operator explicitly approves and a backup exists.


## Interfaces and Dependencies

`Kiroku.Store.Connection` keeps the public type `ConnectionSettingsM m` and field `schema :: Text`, but the field's semantics change from notification-only to target schema plus notification schema. `defaultConnectionSettings :: Text -> ConnectionSettings` must default this field to `"kiroku"`. `withStore :: MonadUnliftIO m => ConnectionSettings -> (KirokuStore -> m a) -> m a` must ensure pooled sessions run with `search_path` set to the configured schema before schema initialization or normal store statements are used.

`Kiroku.Store.Schema.initializeSchema :: MonadIO m => Pool -> Text -> m ()` must use its `Text` schema argument. It may do this by running a static default-`kiroku` SQL script if the project intentionally supports only that schema for now, but the preferred interface is schema-configurable without changing the public function signature. If helper functions are added for quoting identifiers or replacing placeholders, keep them internal to `Kiroku.Store.Schema` or `Kiroku.Store.Connection` unless another module genuinely needs them.

`Kiroku.Store.Notification.startNotifier :: MonadIO m => Text -> Text -> Maybe (KirokuEvent -> IO ()) -> m Notifier` remains unchanged. Its second argument must still be the logical schema name, and the default call path from `withStore` must pass `"kiroku"`.

`Kiroku.Store.SQL` should not need a public interface change. Its unqualified statements continue to be valid because `withStore` controls `search_path`. If implementation chooses schema-qualified SQL instead, it must explain how prepared statements remain reusable across custom schemas; that path is more invasive and should be avoided unless search-path initialization proves impossible.

`Kiroku.Store.Migrations.runKirokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> m ApplyResult` remains unchanged. Its embedded SQL should create the `kiroku` schema, and tests should use codd's `IncludeSchemas [SqlSchema "kiroku"]`. The local codd dependency at `/Users/shinzui/Keikaku/hub/haskell/codd-project` documents and implements schema selection through `SchemaSelection`, `IncludeSchemas`, `SqlSchema`, and the `CODD_SCHEMAS` environment variable.

PostgreSQL 17 or later is the database service. PostgreSQL 18 provides `pg_catalog.uuidv7()`. PostgreSQL 17 requires Kiroku's fallback function, which must live in the `kiroku` schema. `hasql`, `hasql-pool`, and `hasql-notifications` remain the database libraries used by runtime code. `ephemeral-pg` remains the integration-test PostgreSQL provider.
