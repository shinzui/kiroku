# Schema Migrations

Kiroku ships one native `pg-migrate` component in
`kiroku-store-migrations`. Apply it before an application opens `kiroku-store`;
the event-store library itself never runs schema DDL.

The component is named `kiroku`, has no component dependencies, and currently
contains eleven ordered native migrations. Its checked-in
`kiroku-store-migrations/migrations/manifest` is authoritative. SQL bytes are
embedded at compile time and deployed services do not discover migration files
at runtime. The first seven entries preserve the historical Codd payloads
byte-for-byte; `0008` through `0011` are native-only forward migrations.

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

After import, inspect strict `verify`: it must report the first seven entries as applied and only
`0008` through `0011` as pending. Then run `up`; it must report seven `AlreadyApplied`
outcomes and four `AppliedNow` outcomes. A final `verify` must be clean across all eleven native
entries. A missing
legacy row, checksum mismatch, partial nontransactional row, or any other unexpected issue is a
cutover blocker.

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

"Schema-qualified" includes functions. Only `0001` sets `search_path`, and only
`0001` may rely on it; a later migration runs in whatever session the operator's
upgrade uses. Write `kiroku.<name>` for every Kiroku object, and
`kiroku.uuidv7()` — never bare `uuidv7()` — for a UUIDv7 value. The component
publishes `kiroku.uuidv7()` on every supported PostgreSQL version: `0001`'s
fallback on 17, and `0010`'s alias for the builtin on 18. A migration that
names `uuidv7()` unqualified parses on a fresh install, where `0001` has just
run in the same session, and fails with SQLSTATE 42883 on every upgrade. That
was BUG-1, fixed in `kiroku-store-migrations` 0.4.0.0.

## Upgrading from kiroku-store-migrations 0.3.2.x

0.4.0.0 corrects the payload of `0010`, which changes its checksum. A database
that already applied `0010` — PostgreSQL 18, or a fresh PostgreSQL 17 install
performed by 0.3.2.0/0.3.2.1 — fails `up` and `verify` with a
`MigrationChecksumMismatch` until its ledger row is re-baselined. Run
`kiroku-store-migrations/ledger-fixups/2026-08-16-rebaseline-0010-checksum.sql`
against it once, then migrate normally; forward migration `0011` converges the
schema. A database still pending on `0010`, which is every PostgreSQL 17
database the defect blocked, needs nothing.
