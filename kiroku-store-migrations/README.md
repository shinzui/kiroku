# kiroku-store-migrations

`kiroku-store-migrations` owns schema evolution for `kiroku-store`.
It embeds Kiroku's timestamped SQL migrations and runs them through
`codd`, so a service can migrate its database before opening
`Kiroku.Store.withStore`.

Run the executable with codd's standard environment variables:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=kiroku user=kiroku_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=kiroku-store-migrations/expected-schema \
CODD_SCHEMAS=public \
kiroku-store-migrate
```

After migrations run, start the application with schema initialization
disabled:

```haskell
withStore
  (defaultConnectionSettings connString
    & #schemaInitialization .~ SkipSchemaInitialization)
  app
```

`codd` is forward-only. Once a migration has run in production,
reverting the Haskell package does not undo the database change. Repair
state by restoring from backup or by shipping another forward migration.

This first implementation runs with lax schema checking because Kiroku
does not yet ship a checked-in codd expected-schema snapshot. Operators
should treat the migration table as the source of applied-version truth
until strict snapshots are added.
