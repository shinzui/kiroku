# Schema Migrations

Kiroku ships schema migrations in the `kiroku-store-migrations` package.
Use this package to create or upgrade the PostgreSQL schema before an
application opens `kiroku-store`.

The package embeds its SQL migrations into the Haskell library and the
`kiroku-store-migrate` executable at build time. A deployed service does
not need to locate Kiroku migration `.sql` files on disk. The SQL files
are part of the source package, compiled into the executable with
`file-embed`, parsed as `codd` migrations, and passed to `codd` through
its library API.


## Why Migrations Are Separate

`kiroku-store` no longer embeds schema DDL or runs schema creation on
startup. All schema creation and upgrades live in this package.

Production deployments should split schema changes from normal runtime
traffic:

1. Run migrations with a privileged migration role.
2. Run the application with a lower-privilege runtime role.
3. Open the store with the runtime role after migrations have succeeded.

This lets the application user avoid `CREATE` and `TRIGGER` privileges
during normal startup.


## Running The Executable

The executable is named `kiroku-store-migrate`. It reads standard `codd`
environment variables for the migration connection and schema checking
configuration.

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=kiroku user=kiroku_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=kiroku-store-migrations/expected-schema \
CODD_SCHEMAS=kiroku \
kiroku-store-migrate
```

`CODD_MIGRATION_DIRS` is still required by `codd` settings even though
Kiroku supplies embedded migrations to the `codd` library. The value is
not used for discovering Kiroku migrations.

Kiroku installs all of its objects into a dedicated `kiroku` schema rather
than `public`, so `CODD_SCHEMAS=kiroku` is the schema codd should track.
Grant the runtime role privileges on the `kiroku` schema (such as `USAGE`
and the table privileges the application uses); it does not need
privileges on `public`.

Run the command again after it succeeds. The second run should complete
without reapplying the bootstrap migration.


## Running From Haskell

Services that prefer a deploy helper executable can call the library API
directly:

```haskell
import Codd (VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrations)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runKirokuMigrations settings (secondsToDiffTime 5) LaxCheck
  pure ()
```

`runKirokuMigrations` uses `codd` as a library. It builds Kiroku's
embedded SQL files as `AddedSqlMigration` values and calls `codd` with
those in-memory migrations instead of asking `codd` to read Kiroku SQL
from a filesystem directory.


## Opening The Store After Migration

After migrations have run, open the store normally:

```haskell
import Kiroku.Store

main :: IO ()
main = withStore (defaultConnectionSettings connString) app
```

`withStore` assumes the configured schema already exists and contains the
Kiroku tables, functions, triggers, and indexes.


## Forward-Only Model

`codd` is forward-only. Once a migration has run in production,
reverting the Haskell package does not undo the database change. Recovery
from a bad migration means restoring from backup or shipping another
forward migration that repairs the state.

Do not edit a migration file after it has been released to users. Add a
new timestamped migration for every schema change.


## Current Schema Checking Status

The first migration package runs with `LaxCheck`. This applies and
records migrations, but it does not fail the command when the live
database differs from a checked-in expected-schema snapshot.

Strict `codd` schema verification is intentionally deferred until Kiroku
ships an expected-schema snapshot for the PostgreSQL version it supports.
Kiroku supports PostgreSQL 17 or newer. PostgreSQL 18 provides the
built-in `pg_catalog.uuidv7()` function, while PostgreSQL 17 receives a
Kiroku-managed PL/pgSQL `uuidv7()` fallback from the bootstrap schema
before `events.event_id DEFAULT uuidv7()` is parsed.
