# Schema Migrations

Kiroku ships one native `pg-migrate` component in
`kiroku-store-migrations`. Apply it before an application opens `kiroku-store`;
the event-store library itself never runs schema DDL.

The component is named `kiroku`, has no component dependencies, and currently
contains seven ordered migrations. Its checked-in
`kiroku-store-migrations/migrations/manifest` is authoritative. SQL bytes are
embedded at compile time and deployed services do not discover migration files
at runtime.

## Running the executable

```bash
kiroku-store-migrate plan
kiroku-store-migrate up --database-url "$DATABASE_URL"
kiroku-store-migrate verify --database-url "$DATABASE_URL"
```

The executable also accepts `DATABASE_URL` as the application-owned default.
No `CODD_*` environment variable is required. `verify` strictly compares the
declared plan with the versioned `pgmigrate` ledger. A clean report proves that
all declared payload identities and checksums are present in order; it does not
claim that every live schema object matches a snapshot.

Run migrations with a privileged role, then open the store with a lower
privilege role:

```haskell
import Database.PostgreSQL.Migrate
import Hasql.Connection.Settings qualified as Settings
import Kiroku.Store
import Kiroku.Store.Migrations

main :: IO ()
main = do
  plan <- either (fail . show) pure kirokuMigrationPlan
  migrated <- runMigrationPlan defaultRunOptions (Settings.connectionString connString) plan
  either (fail . show) (const (withStore (defaultConnectionSettings connString) app)) migrated
```

Applications composing Kiroku with other libraries should use
`kirokuMigrations` and pass all components to `migrationPlan` in explicit
dependency order.

## Existing Codd databases

Do not run the native plan directly against a database whose seven Kiroku
migrations already appear in `codd.sql_migrations` or
`codd_schema.sql_migrations`. First import that history with
`kirokuCoddSourceConfig`, `kirokuCoddHistoryMappings`, and
`importCoddHistory`. The importer:

1. reads the supported Codd ledger under its cooperating advisory lock;
2. requires all seven complete rows and rejects partial or duplicate history;
3. verifies each historical payload through the checked-in SHA-256 lock file;
4. writes equivalent applied rows and audit evidence to `pgmigrate`; and
5. leaves the Codd source objects unchanged.

After import, run strict `verify`, then `up`. `up` must report
`AlreadyApplied` for all seven Kiroku migrations. A missing row, checksum
mismatch, or partial nontransactional row is a cutover blocker.

## Authoring and recovery

Create new migrations with the standard authoring command:

```bash
kiroku-store-migrate new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "describe the forward schema change"
```

Review both the new SQL file and appended manifest line. Keep Kiroku objects
schema-qualified and never edit a released payload. Migrations are
forward-only: recover by restoring a pre-migration backup or appending a new
corrective migration.
