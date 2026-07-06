# kiroku-store-migrations

`kiroku-store-migrations` owns schema evolution for `kiroku-store`.
It embeds Kiroku's timestamped SQL migrations and runs them through
`codd`, so a service can migrate its database before opening
`Kiroku.Store.withStore`.

## Applying migrations

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

The apply path applies the embedded migrations and records each one in
codd's ledger table. With codd 0.1.8 and newer, fresh databases use
`codd.sql_migrations`; older databases that still have
`codd_schema.sql_migrations` are renamed to `codd` on first contact. When
writing operator SQL, check `to_regclass('codd.sql_migrations')` first and
fall back to `to_regclass('codd_schema.sql_migrations')` only for pre-upgrade
databases. The apply path does **not** verify the result against the
expected-schema snapshot (see "Verifying the schema" below — that check runs
at test/CI time). `CODD_EXPECTED_SCHEMA_DIR` is still required by codd's
settings parser, but this executable does not read from it. Treat the ledger
table as the source of applied-version truth.

`kiroku-store-migrate` accepts bare invocation and `up` as apply commands.
Unknown arguments fail with usage and exit code 2 before reading
`CODD_CONNECTION`, so a typo cannot accidentally apply migrations.

### Concurrent applies and retries

The executable serializes migration applies with a PostgreSQL session-level
advisory lock on the target database. This protects multi-replica deploys where
two processes start migration at the same time: the second process waits for
the first to finish, then observes zero pending migrations. The lock is released
when the migration process closes its dedicated lock connection, including on
exceptions or process exit. One migrator per deploy is still the clearest
operational pattern; the lock is a safety net.

The embedded runner also forces codd's retry policy to a single try, ignoring
`CODD_RETRY_POLICY` for this executable. codd 0.1.8 cannot re-read in-memory
embedded migrations during a retry (`Re-reading in-memory streams is not yet
implemented`), so retrying masks the original database error with an unrelated
crash. A single attempt preserves the real failure.

After migrations run, start the application normally:

```haskell
withStore (defaultConnectionSettings connString) app
```

## Authoring a new migration

Do not hand-name migration files. Scaffold them:

```bash
cd kiroku-store-migrations
cabal run kiroku-store-migrate -- new "add widget index"
```

This stamps the **real current UTC time to the second** into the filename
and writes a `kiroku.`-qualified, idempotent SQL skeleton under
`sql-migrations/`, printing the path it created and a recompile reminder:

```text
Created sql-migrations/2026-07-05-20-56-59-add-widget-index.sql
Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`).
```

(By default the file is written under `sql-migrations/`; set
`KIROKU_MIGRATIONS_DIR` to write elsewhere, for example in a test.) Fill in
the body with your DDL, keeping it idempotent (`IF NOT EXISTS`, `ADD COLUMN
IF NOT EXISTS`, etc.) and hard-qualifying every object as `kiroku.<name>`,
following the style of the existing incremental migrations (for example
`sql-migrations/2026-06-24-09-42-22-stream-truncate-before.sql`, which does
`ALTER TABLE kiroku.streams ADD COLUMN IF NOT EXISTS …`). The scaffolded
skeleton is a `CREATE TABLE IF NOT EXISTS kiroku.example (…)` plus a
schema-qualified index and a `-- TODO` — replace it with your real DDL.

### Why the filename must be a real UTC timestamp

codd orders migrations by filename and decides whether a migration has
already been applied by looking its *name* up in the codd ledger — it does
**not** hash the file body. So filenames must sort in true authoring order
and must be unique. The
`YYYY-MM-DD-HH-MM-SS-<slug>.sql` format sorts lexicographically ==
chronologically because every field is fixed-width and zero-padded.

The test `migrationFileNameSpec` in `test/Main.hs` enforces this and rejects
names that look *hand-assigned* rather than sampled from a clock:

- the seconds field must not be `00`,
- the time must not be exactly UTC midnight (`HH-MM` not `00-00`),
- all migration timestamps must be unique and strictly increasing.

These rules exist because migrations were once named with rounded *sentinel*
timestamps (`…-00-00-00-…`, `…-00-00-01-…`) that did not sort in authoring
order and collided in codd's timestamp-keyed ledger — a bug that forced a
mass rename and a ledger-repair script (see "Renaming a migration" below).
The scaffolder samples the wall clock, so it never produces a sentinel. In
the astronomically unlikely event the sampled time lands on a `00`-seconds
or midnight boundary, nudge the seconds by one; the guard's failure message
tells you exactly which file offended. A round-trip test (`scaffolderSpec`)
proves the scaffolder's output always satisfies `migrationFileNameSpec`.

### Recompile caveat: the migrations are embedded at compile time

`src/Kiroku/Store/Migrations.hs` embeds the whole `sql-migrations/` directory
into the library at **compile time** with Template Haskell
(`$(embedDir "sql-migrations")` on its last line). Adding or editing a `.sql`
file does **not** by itself cause a recompile, so a stale build can run the
*old* set of migrations. After scaffolding or editing a migration, force the
module to rebuild — touch the embed comment in `Migrations.hs`, run `cabal
clean`, or edit that module — before running the tests or the executable, so
`embedDir` re-captures the directory.

### Lockfile and integrity gates

`migrations.lock` records a SHA-256 checksum for every embedded migration
body. Regenerate it only for a deliberate, reviewed change to the migration
set:

```bash
cd kiroku-store-migrations
cabal run kiroku-store-migrate -- lock
```

The command reads `sql-migrations/` (or `KIROKU_MIGRATIONS_DIR` when set),
writes `migrations.lock`, and prints the number of migrations written. In
normal development the lockfile changes when you add a new migration. Editing
a shipped migration body without regenerating the lockfile is a test failure
that names the file.

`cabal test kiroku-store-migrations-test` also enforces two authoring gates.
The embed-parity test compares the compiled-in migration names with the
on-disk `sql-migrations/` listing, so adding a `.sql` file without rebuilding
`Kiroku.Store.Migrations` fails instead of shipping a stale executable. The
body lint rejects future migrations that mention `search_path`, create or
alter unqualified objects, or use `CREATE INDEX CONCURRENTLY` without codd's
`-- codd: no-txn` directive. The bootstrap migration is grandfathered because
it intentionally sets `search_path` once for historical schema creation.

## Verifying the schema: the drift gate

The migration test suite strict-checks the migrated database against a
checked-in *expected-schema snapshot* under `expected-schema/v18/` (the `v18`
segment is the PostgreSQL major version the snapshot was captured against).
The snapshot is a codd-generated directory tree describing every table,
column, index, constraint, function, and trigger the migrations should
produce in the `kiroku` schema. `cabal test kiroku-store-migrations-test`
applies the embedded migrations to a throwaway PostgreSQL and fails if the
live schema differs from the snapshot in any way — a dropped column, a
renamed index, an altered constraint — even one no hand-written assertion
happens to probe.

**When you change the schema shape** (add or alter a table, index,
constraint, function, or trigger via a new migration), regenerate the
snapshot and commit the diff:

```bash
cd kiroku-store-migrations
cabal run kiroku-write-expected-schema
git status                 # shows changes under expected-schema/v18/
git add expected-schema
```

Then run `cabal test kiroku-store-migrations-test` and confirm it passes.
Review the `git diff` of the snapshot the same way you review code: it should
reflect exactly the change your migration makes and nothing else. An
unexpected diff line is a real schema change you did not intend.

**The snapshot is portable.** `kiroku-write-expected-schema` pins the
throwaway PostgreSQL superuser to a fixed name (`kiroku`), so the captured
role and object owners are deterministic. The strict test passes on any
machine and in CI, not just the author's — you will not see your local OS
username anywhere in `expected-schema/`.

**The write tool is flag-gated.** `kiroku-write-expected-schema` is built
behind the cabal flag `expected-schema-tool` (on by default), which is
disabled under nix, so it never drags its `ephemeral-pg` dependency into the
`nix build .#kiroku-store-migrations` closure. `cabal run
kiroku-write-expected-schema` works in the dev shell; `nix build` does not
compile the tool. The library and the `kiroku-store-migrate` executable still
build under nix.

The **drift gate is a developer/CI check**, enforced by `cabal test
kiroku-store-migrations-test` against the in-repo `expected-schema/v18/`
snapshot. It is wired in the test (and in the checked runner
`runKirokuMigrations`, via `onDiskReps = Left <dir>`) directly to the
snapshot directory, not through `CODD_EXPECTED_SCHEMA_DIR`. The **apply
path** — the `kiroku-store-migrate` executable you run in production — is
deliberately kept as an unchecked run (`runKirokuMigrationsNoCheck`) and does
not consult `CODD_EXPECTED_SCHEMA_DIR`; the snapshot exists to catch drift in
development and CI, not to gate a production apply.

## Renaming a migration: the `ledger-fixups/` discipline

**Prefer never to rename a migration.** Because you scaffold with `new`,
filenames are correct from birth and there is nothing to rename. This section
is the escape hatch for the rare case where a migration that has *already
run* on a long-lived database must be renamed anyway (for example, to repair
a historical sentinel name).

codd identifies an applied migration by its **filename**, with no body
checksum. Renaming a shipped file therefore makes codd believe the renamed
file is a brand-new, un-applied migration and re-run it — which for a
non-idempotent migration corrupts the database, and even for an idempotent
one leaves a bogus duplicate ledger row. To rename safely you must, in the
same change, ship a one-time **ledger-fixup**: a transactional, idempotent
SQL script that `UPDATE`s the `name` (and `migration_timestamp`) columns of
the codd ledger from the old identity to the new one, so codd sees the
renamed migrations as already applied and skips them.

The repository already contains the template:
`ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`. It was
written when the migrations were renamed from sentinel timestamps to real
authoring times. Model any new fixup on it:

- **Transactional** — wrap the whole script in `BEGIN; … COMMIT;` so it is
  all-or-nothing.
- **Idempotent** — remap each row 1:1 onto brand-new values, so a second run
  matches no rows and neither `UNIQUE(name)` nor `UNIQUE(migration_timestamp)`
  can be violated.
- **Bookkeeping only** — it changes codd's ledger, never your schema.

**When to run a ledger-fixup:** once per long-lived database (staging,
production, persistent local), **before** the next `kiroku-store-migrate` run
that carries the renamed files. This includes downstream databases that ran
kiroku's migrations bundled with a consumer's own ledger — for example keiro,
which maintains a *combined* kiroku↔keiro ledger; the fixup's new timestamps
are chosen not to collide with keiro's rows. **Ephemeral and
template-per-suite test databases never need it** — they apply every
migration from scratch under the new names.

Apply a fixup inside a transaction with `psql`:

```bash
psql "host=/tmp port=5432 dbname=kiroku user=kiroku_admin" \
  --single-transaction \
  --file=kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql
```

The checked-in fixup detects `codd.sql_migrations` first and falls back to
`codd_schema.sql_migrations` for databases that have not yet been touched by
codd 0.1.8. Keep future fixups dual-schema aware the same way.

## Forward-only recovery

codd has no `down`/rollback step. Once a migration has run against a
database, reverting the Haskell package (checking out an older commit,
downgrading `kiroku-store-migrations`) does **not** undo the database change —
the schema stays changed and codd's ledger still records the migration as
applied. There are exactly two ways to recover from a bad migration that has
already run in production:

1. **Restore from backup.** If you took a backup before migrating (always do,
   for a persistent database), restore it. This is the only way to *remove* a
   change codd already applied.

   ```bash
   pg_restore --clean --if-exists --dbname=kiroku kiroku-pre-migrate.dump
   ```

2. **Ship another forward migration.** Author a new migration (with `new`)
   that corrects the problem — dropping the errant column, restoring the
   constraint — and apply it the normal way. This is the right choice when
   data written since the bad migration must be preserved.

**How to diagnose.** Inspect codd's ledger to see exactly what ran and when:

```sql
SELECT name, migration_timestamp
FROM codd.sql_migrations
ORDER BY migration_timestamp;
```

For old databases that have not yet run codd 0.1.8, use
`codd_schema.sql_migrations` until the first upgraded apply renames it.

To detect *drift* — a database whose schema no longer matches the migrations
— run the strict gate against a fresh throwaway database (`cabal test
kiroku-store-migrations-test`) and, for a live database, compare its shape to
the checked-in `expected-schema/v18/` snapshot. A failing strict test or a
snapshot mismatch tells you the schema changed out from under the migration
history.
