# kiroku-store-migrations

`kiroku-store-migrations` owns schema evolution for `kiroku-store`.
It embeds Kiroku's timestamped SQL migrations and runs them through
`codd`, so a service can migrate its database before opening
`Kiroku.Store.withStore`.

Run the executable with codd's standard environment variables:

```bash
CODD_CONNECTION='host=/tmp port=5432 dbname=kiroku user=kiroku_admin' \
CODD_MIGRATION_DIRS=unused-for-embedded-migrations \
CODD_EXPECTED_SCHEMA_DIR=unused-for-unverified-embedded-migrations \
CODD_SCHEMAS=kiroku \
kiroku-store-migrate
```

The bootstrap migration creates a dedicated `kiroku` schema and installs
every Kiroku table, index, function, and trigger inside it, leaving
`public` free for application objects. `CODD_SCHEMAS=kiroku` tells codd to
track that schema. The runtime role therefore needs privileges on the
`kiroku` schema (for example `USAGE` plus the table privileges it uses),
not on `public`.

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

This first implementation runs without codd expected-schema verification
because Kiroku does not yet ship a checked-in codd expected-schema
snapshot. `CODD_EXPECTED_SCHEMA_DIR` is still required by codd's settings
parser, but this executable does not read from it. Operators should treat
the migration table as the source of applied-version truth until strict
snapshots are added.
