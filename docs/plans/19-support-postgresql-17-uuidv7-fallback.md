---
id: 19
slug: support-postgresql-17-uuidv7-fallback
title: "Support PostgreSQL 17 UUIDv7 fallback"
kind: exec-plan
created_at: 2026-05-17T03:38:14Z
intention: "intention_01krt007ehe50admrt7zf8hd7r"
---

# Support PostgreSQL 17 UUIDv7 fallback

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku should run on PostgreSQL 17 as well as PostgreSQL 18. Today the schema and embedded codd bootstrap migration say "Requires PostgreSQL 18+" and define `events.event_id UUID PRIMARY KEY DEFAULT uuidv7()`. PostgreSQL 17 does not provide `uuidv7()` as a built-in function, so `initializeSchema` and `kiroku-store-migrations` fail before any event can be appended.

After this change, a fresh PostgreSQL 17 database can initialize the schema, append an event with a database-side default `event_id`, and run Kiroku's Haskell append/read tests. PostgreSQL 18 should continue to use its built-in `pg_catalog.uuidv7()` when available. The observable proof is a migration/schema test that creates the schema on PostgreSQL 17, inserts into `events` without specifying `event_id`, and observes a UUID whose version nibble is `7`, plus the existing Haskell append tests continuing to pass.


## Progress

- [x] Add a PostgreSQL 17-compatible `uuidv7()` fallback function before `events.event_id DEFAULT uuidv7()` is parsed in `kiroku-store/sql/schema.sql`. (Completed 2026-05-17)
- [x] Add the same fallback to the embedded bootstrap migration in `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`, or add a new forward migration if the bootstrap file is already considered released. (Completed 2026-05-17; edited the unreleased bootstrap migration to keep it synchronized with `schema.sql`.)
- [x] Update SQL benchmark scripts under `kiroku-store/bench/sql/` so direct benchmark inserts continue to work on PostgreSQL 17. (Completed 2026-05-17; benchmark call sites still use `uuidv7()`, and `run_benchmarks.sh` now fails early if the schema has not provided it.)
- [x] Add regression tests that prove direct SQL default event id generation works and produces UUIDv7-shaped identifiers. (Completed 2026-05-17; added direct default-id probes to `kiroku-store-test` and `kiroku-store-migrations-test`.)
- [x] Update user-facing documentation that currently states PostgreSQL 18 is required. (Completed 2026-05-17; updated production deployment, schema migration, design, and implementation docs to say PostgreSQL 17 or newer.)
- [x] Run format, package tests, and at least one manual PostgreSQL version check or clearly record why it was not possible. (Completed 2026-05-17; `nix develop -c cabal test kiroku-store-test`, `nix develop -c cabal test kiroku-store-migrations-test`, and `nix develop -c just fmt` passed. `nix develop -c postgres --version` reported PostgreSQL 18.3; no PostgreSQL 17 server was available in the active dev shell.)


## Surprises & Discoveries

- The repository already pre-generates UUIDv7 event ids in the Haskell append interpreter, so the database default is a fallback for direct SQL use and schema validity, not the hot Haskell append path. Evidence: `kiroku-store/src/Kiroku/Store/Effect.hs` imports `Data.UUID.V7 qualified as V7`, and `prepareEvents` calls `V7.genUUIDs` for every `EventData` whose `eventId` is `Nothing`.
- The TypeID implementation named by the user is local source, not a published dependency needed by Kiroku. Evidence: `mori registry show shinzui/typeid-hs --full` reports `/Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs`, and `/Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs/database/v0.0.1/01_uuidv7.sql` contains a small PL/pgSQL `uuid_generate_v7()` implementation.
- Validation ran against PostgreSQL 18.3 from the Nix development shell. Evidence: `nix develop -c postgres --version` printed `postgres (PostgreSQL) 18.3`. The PostgreSQL 17 runtime path is covered by the guarded SQL and direct-default tests, but it was not executed locally in this session because the active shell did not provide a PostgreSQL 17 server.
- `codd` still emits its pre-existing PostgreSQL 18 strict-schema warning under `LaxCheck`, but the migration test applies the migration and passes. Evidence: `kiroku-store-migrations-test` printed `Warn: Not all features of PostgreSQL version v18 may be supported by codd` and ended with `1 example, 0 failures`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Backfill an unqualified `uuidv7()` function in the schema instead of renaming the column default to `uuid_generate_v7()`.
  Rationale: The current schema, migration, design docs, and benchmark SQL already call `uuidv7()`. Keeping that name minimizes churn and matches PostgreSQL 18's built-in function name. On PostgreSQL 17, Kiroku will provide the missing name. On PostgreSQL 18, the implementation must avoid replacing the built-in and should let the built-in remain authoritative.
  Date: 2026-05-17
- Decision: Use the TypeID PL/pgSQL algorithm as the fallback body, adapted to expose `uuidv7()`.
  Rationale: The user pointed to this implementation, and it is simple: it takes the current Unix timestamp in milliseconds, overlays those six timestamp bytes onto random UUID bytes, and sets the UUID version bits to `7`. That is enough for Kiroku's default-id fallback and keeps the implementation database-local.
  Date: 2026-05-17
- Decision: Keep Haskell append-time UUID generation unchanged.
  Rationale: The hot append path already generates UUIDv7 ids client-side via `mmzk-typeid`, sends concrete UUID arrays to SQL, and does not depend on the column default. Changing that path is unnecessary for PostgreSQL 17 support and would add behavioral risk.
  Date: 2026-05-17
- Decision: Edit the bootstrap migration directly instead of adding a second forward migration.
  Rationale: The bootstrap migration was created during the current unreleased migration-package work and already mirrors `kiroku-store/sql/schema.sql`. Keeping the bootstrap synchronized avoids forcing new databases to apply a broken PostgreSQL 17 bootstrap and then a repair migration.
  Date: 2026-05-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed on 2026-05-17. Kiroku now defines a guarded schema-local `uuidv7()` fallback before `events.event_id DEFAULT uuidv7()` is parsed in both `kiroku-store/sql/schema.sql` and the embedded bootstrap migration. PostgreSQL 18 continues to use `pg_catalog.uuidv7()` because the fallback block skips creation when the built-in function exists.

The test suite now proves the database default directly by inserting into `events` without an `event_id` and checking the returned UUID version nibble. The same assertion exists in the migration package, proving both schema initialization paths. Benchmark scripts retain their existing `uuidv7()` calls and now fail early with a clear message if a stale database lacks the function.

Validation passed with the active PostgreSQL 18.3 dev shell:

```text
nix develop -c cabal test kiroku-store-test
129 examples, 0 failures

nix develop -c cabal test kiroku-store-migrations-test
1 example, 0 failures

nix develop -c just fmt
formatted 3 files (0 changed)

nix develop -c postgres --version
postgres (PostgreSQL) 18.3
```

The remaining gap is direct execution on a PostgreSQL 17 server. The implementation is designed for that runtime path and guarded to leave PostgreSQL 18 untouched, but this session's available dev shell only exposed PostgreSQL 18.3.


## Context and Orientation

Kiroku is a Haskell PostgreSQL event-store library. An event store records immutable event rows and lets callers read them back by stream or by the global `$all` sequence. The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

The current project metadata is available through `mori`. From the repository root, `mori show --full` identifies the project as `shinzui/kiroku`, a Haskell library with packages `kiroku-store`, `kiroku-store-migrations`, `shibuya-kiroku-adapter`, and `kiroku-otel`. It also declares dependencies including `hasql/hasql`, `hasql:hasql-pool`, `hasql:hasql-transaction`, `MMZK1526/mmzk-typeid`, and `shinzui/ephemeral-pg`. Always use `mori` before guessing dependency APIs; do not search `/nix/store`.

The schema currently lives in two places. `kiroku-store/sql/schema.sql` is embedded by `kiroku-store/src/Kiroku/Store/Schema.hs` through `embedFile "sql/schema.sql"` and run by `initializeSchema`. `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` is embedded by `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` through `embedDir "sql-migrations"` and run by `runKirokuMigrations` via codd. Both SQL files currently contain:

```sql
-- Requires PostgreSQL 18+ (for uuidv7())
...
CREATE TABLE IF NOT EXISTS events (
    event_id       UUID         PRIMARY KEY DEFAULT uuidv7(),
    ...
);
```

`UUIDv7` means a UUID whose high-order bytes encode time, so B-tree primary-key inserts are more locality-friendly than purely random UUIDv4 inserts. PostgreSQL 18 provides a built-in `uuidv7()` function. PostgreSQL 17 does not. The Haskell append path mostly avoids the default by generating ids in `kiroku-store/src/Kiroku/Store/Effect.hs`: `prepareEvents` calls `Data.UUID.V7.genUUIDs` from `mmzk-typeid` for `EventData.eventId = Nothing`, then `buildAppendParams` sends the generated UUID array to `kiroku-store/src/Kiroku/Store/SQL.hs`. The database default still matters for direct SQL users, benchmark SQL scripts, migrations, and successful schema creation on PostgreSQL 17.

The user suggested the local TypeID SQL implementation at `/Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs/database/v0.0.1`. `mori registry search typeid` shows both `MMZK1526/mmzk-typeid` and `shinzui/typeid-hs`; `mori registry show shinzui/typeid-hs --full` gives the source path. The relevant file is `/Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs/database/v0.0.1/01_uuidv7.sql`:

```sql
create or replace function uuid_generate_v7()
returns uuid
as $$
declare
  unix_ts_ms bytea;
  uuid_bytes bytea;
begin
  unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
  uuid_bytes = uuid_send(gen_random_uuid());
  uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
  uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
  return encode(uuid_bytes, 'hex')::uuid;
end
$$
language plpgsql
volatile;
```

For Kiroku, adapt that body to create `uuidv7()` when the server does not already expose `pg_catalog.uuidv7()`. The implementation relies on `clock_timestamp()`, `int8send`, `uuid_send`, `gen_random_uuid()`, `overlay`, `set_byte`, and `encode`, which are PostgreSQL-side functions. `gen_random_uuid()` is available in supported modern PostgreSQL installations; if a local PostgreSQL 17 build reports it missing, add `CREATE EXTENSION IF NOT EXISTS pgcrypto;` before creating the fallback function and record that discovery in this plan.

The benchmark SQL scripts under `kiroku-store/bench/sql/` call `uuidv7()` directly in several files: `setup.sql`, `bench_append_single.sql`, `bench_append_batch_10.sql`, `bench_append_batch_100.sql`, `bench_append_batch_1000.sql`, `bench_append_concurrent.sql`, `bench_append_concurrent_batch.sql`, `bench_mixed.sql`, and `bench_mixed_write.sql`. These scripts source the schema through `kiroku-store/bench/sql/run_benchmarks.sh` and `kiroku-store/bench/sql/setup.sql`, so once the schema creates a fallback `uuidv7()` on PostgreSQL 17, the scripts should continue to work without changing each call site.

Documentation that currently names PostgreSQL 18 as a hard requirement includes `docs/PRODUCTION-DEPLOYMENT.md`, `docs/user/schema-migrations.md`, `docs/DESIGN.md`, and `docs/IMPLEMENTATION.md`. Update the first two as user-facing docs in this plan. Update design docs only if they are still treated as current project truth; if they are historical implementation notes, add a short caveat instead of rewriting old design decisions.


## Plan of Work

Milestone 1 adds the database fallback in the source schema and proves it with the existing schema-initialization path. At the end of this milestone, `kiroku-store/sql/schema.sql` defines a PostgreSQL 17-compatible `uuidv7()` before `events` is created, `initializeSchema` can run on a fresh database, and a direct SQL insert without `event_id` succeeds. Acceptance is a focused test in `kiroku-store/test/Main.hs` or `kiroku-store/test/Test/Helpers.hs` that queries `event_id` after default insertion and checks the string form has version `7` at the UUID version position.

Milestone 2 brings the migration package to the same database state. At the end of this milestone, `kiroku-store-migrations` applies a bootstrap schema that works on PostgreSQL 17 and PostgreSQL 18. If the existing bootstrap migration has not been released, edit `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` to match `schema.sql`. If it has been released, leave the file intact and add a new timestamped migration that creates the fallback function only when it is missing. Acceptance is `cabal test kiroku-store-migrations-test`.

Milestone 3 updates docs and SQL benchmark assumptions. At the end of this milestone, user-facing docs say PostgreSQL 17 or newer is supported, with a note that Kiroku backfills `uuidv7()` only when PostgreSQL does not provide it. Benchmark SQL continues to use `uuidv7()` and relies on schema setup to define it. Acceptance is a documentation grep that no current user-facing page still says PostgreSQL 18 is required as an unconditional rule.

Milestone 4 validates the whole repo. At the end of this milestone, package tests compile and run, formatting is clean, and the plan records the exact verification outputs. If local `ephemeral-pg` only starts one PostgreSQL version, run that version and record the version with `SHOW server_version_num`; if both PostgreSQL 17 and 18 are available, run the focused schema/default-id test against both.


## Concrete Steps

All commands run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

First confirm dependency and project context:

```bash
mori show --full
mori registry search typeid
mori registry show shinzui/typeid-hs --full
sed -n '1,120p' /Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs/database/v0.0.1/01_uuidv7.sql
```

Expected evidence is that `shinzui/typeid-hs` is located at `/Users/shinzui/Keikaku/work/libraries/haskell/typeid-hs`, and the SQL file defines `uuid_generate_v7()` using timestamp bytes plus random UUID bytes.

Edit `kiroku-store/sql/schema.sql`. Replace the top PostgreSQL 18 requirement comment with a PostgreSQL 17+ support comment and insert the fallback before the `CREATE TABLE IF NOT EXISTS streams` statement. Use a `DO` block so PostgreSQL 18 does not attempt to replace the built-in function:

```sql
-- Kiroku Store Schema
-- Supports PostgreSQL 17+.
-- PostgreSQL 18 provides pg_catalog.uuidv7(); PostgreSQL 17 needs this
-- public-schema fallback before events.event_id DEFAULT uuidv7() is parsed.
DO $$
BEGIN
    IF to_regprocedure('pg_catalog.uuidv7()') IS NULL
       AND to_regprocedure('uuidv7()') IS NULL THEN
        EXECUTE $fn$
            CREATE FUNCTION uuidv7()
            RETURNS uuid
            AS $body$
            DECLARE
                unix_ts_ms bytea;
                uuid_bytes bytea;
            BEGIN
                unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
                uuid_bytes = uuid_send(gen_random_uuid());
                uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
                uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
                RETURN encode(uuid_bytes, 'hex')::uuid;
            END
            $body$
            LANGUAGE plpgsql
            VOLATILE
        $fn$;
    END IF;
END
$$;
```

If `CREATE FUNCTION uuidv7()` fails on PostgreSQL 17 because `gen_random_uuid()` is unavailable, change the block to execute `CREATE EXTENSION IF NOT EXISTS pgcrypto;` before the function creation. Record the exact error in Surprises & Discoveries and update this plan before continuing.

Apply the same SQL block to `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` before `CREATE TABLE IF NOT EXISTS streams` if the bootstrap is still editable. If the bootstrap is immutable because it has already been released, instead add a new file under `kiroku-store-migrations/sql-migrations/` with a timestamp later than `2026-05-16-00-00-00`, for example `2026-05-17-00-00-00-postgresql-17-uuidv7-fallback.sql`, containing only the fallback block.

Add focused tests. Prefer adding helpers in `kiroku-store/test/Test/Helpers.hs` because it already contains raw SQL helpers using `Hasql.Statement`. Add a helper that runs:

```sql
INSERT INTO events (event_type, data)
VALUES ('DefaultUuidGenerated', '{}'::jsonb)
RETURNING event_id::text
```

Then assert in `kiroku-store/test/Main.hs` that the returned text has `7` as the UUID version character. A UUID string has the shape `xxxxxxxx-xxxx-vxxx-xxxx-xxxxxxxxxxxx`; in Haskell, the version character is at zero-based index 14. Also query `SELECT current_setting('server_version_num')::int4` and include it in the failure message so a future reader knows which PostgreSQL major version was exercised.

Add a migration-package regression to `kiroku-store-migrations/test/Main.hs`. After `runKirokuMigrations`, execute the same direct default insert through a fresh connection or pool and assert that the returned UUID text has version `7`. This proves the embedded migration, not only the embedded schema script, carries the fallback.

Update docs:

```bash
rg -n "PostgreSQL 18|uuidv7\\(\\)|Requires PostgreSQL 18" docs README.md kiroku-store kiroku-store-migrations
```

Change user-facing statements in `docs/PRODUCTION-DEPLOYMENT.md` and `docs/user/schema-migrations.md` from "PostgreSQL 18 or newer" to "PostgreSQL 17 or newer". Include a note that PostgreSQL 18 uses its built-in `uuidv7()` and PostgreSQL 17 gets a Kiroku-managed PL/pgSQL fallback. Update `kiroku-store/sql/schema.sql` and the bootstrap migration comments. Leave historical benchmark reports alone unless they are phrased as current requirements.

Run formatting and tests:

```bash
just fmt
cabal test kiroku-store-test
cabal test kiroku-store-migrations-test
```

Expected successful test tail:

```text
All N examples passed
```

If the exact package target names differ under Cabal, use:

```bash
cabal test all
```

For a manual PostgreSQL check against the development database, start services if needed and run:

```bash
just up
just reset-database
psql -d kiroku -Atc "SHOW server_version_num; SELECT uuidv7()::text;"
```

Expected output has a server version beginning with `17` or `18`, and a UUID whose third group starts with `7`, for example:

```text
170005
019...-....-7...-....-............
```


## Validation and Acceptance

Acceptance requires all of these behaviors:

On a fresh database, `initializeSchema` succeeds. The test exercises this through `withTestStore`, which calls `withStore` with default schema initialization.

Direct SQL can omit `event_id` and still insert an event:

```sql
INSERT INTO events (event_type, data)
VALUES ('DefaultUuidGenerated', '{}'::jsonb)
RETURNING event_id::text;
```

The returned UUID must have version `7`. It is acceptable that the random bits differ each run.

The codd migration package can apply Kiroku's embedded migrations and then perform the same direct SQL default insertion.

The existing Haskell append/read behavior is unchanged: events with `EventData.eventId = Nothing` still append and read back through `appendToStream` and `readStreamForward`, using client-side UUIDv7 generation from `mmzk-typeid`.

Run:

```bash
cabal test kiroku-store-test
cabal test kiroku-store-migrations-test
```

Both commands must exit 0. If a PostgreSQL 17 executable is available locally, run the focused tests with that version and record the `SHOW server_version_num` output in Progress. If only PostgreSQL 18 is available locally, still land the fallback because the SQL is guarded by `to_regprocedure`, and record the unverified PostgreSQL 17 runtime gap in Outcomes & Retrospective.


## Idempotence and Recovery

The fallback block is intentionally idempotent. Re-running it on PostgreSQL 18 should do nothing because `pg_catalog.uuidv7()` exists. Re-running it on PostgreSQL 17 should do nothing after Kiroku creates `uuidv7()` in the active schema. `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION` for existing triggers, and `DROP TRIGGER IF EXISTS` plus `CREATE TRIGGER` are already part of Kiroku's idempotent schema-init model.

If a partially applied local database has tables but no fallback function, run the fallback `DO` block manually through `psql` and then re-run schema initialization. If a migration was added with codd and fails, do not edit an already-applied migration in a shared or production database. Add a later forward migration that fixes the function body or creates the missing extension.

If the fallback function body must be changed after release, ship a new forward migration with `CREATE OR REPLACE FUNCTION uuidv7()` guarded so it only targets the Kiroku-created function and does not replace `pg_catalog.uuidv7()` on PostgreSQL 18. Before doing that, inspect `pg_proc` or use `to_regprocedure` to distinguish `pg_catalog.uuidv7()` from the schema-local fallback.


## Interfaces and Dependencies

No new Haskell dependency is required. Keep using `mmzk-typeid` from `kiroku-store/kiroku-store.cabal` for client-side UUIDv7 generation in `kiroku-store/src/Kiroku/Store/Effect.hs`.

The database interface added by this plan is:

```sql
uuidv7() RETURNS uuid
```

On PostgreSQL 18, this is the built-in `pg_catalog.uuidv7()`. On PostgreSQL 17, Kiroku creates a schema-local PL/pgSQL function with the same call shape before any table default references it.

The Haskell modules involved are:

`kiroku-store/src/Kiroku/Store/Schema.hs` embeds `kiroku-store/sql/schema.sql` and exposes `initializeSchema :: (MonadIO m) => Pool -> Text -> m ()`. This interface should not change.

`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` embeds `kiroku-store-migrations/sql-migrations/*.sql` and exposes `runKirokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult`. This interface should not change.

`kiroku-store/src/Kiroku/Store/Effect.hs` contains `prepareEvents :: (MonadIO m) => [EventData] -> m [PreparedEvent]`, which should continue to call `Data.UUID.V7.genUUIDs` for caller-omitted ids.

`kiroku-store/test/Test/Helpers.hs`, `kiroku-store/test/Main.hs`, and `kiroku-store-migrations/test/Main.hs` are the expected test edit points. Use `hasql` statements for direct SQL probes, matching existing helpers such as `countEvents` and `bootstrapStmt`.
