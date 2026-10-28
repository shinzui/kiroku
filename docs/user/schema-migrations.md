# Schema Migrations

Kiroku ships one native `pg-migrate` component in
`kiroku-store-migrations`. Apply it before an application opens `kiroku-store`;
the event-store library itself never runs schema DDL.

The component is named `kiroku`, has no component dependencies, and currently
contains seventeen ordered native migrations. Its checked-in
`kiroku-store-migrations/migrations/manifest` is authoritative. SQL bytes are
embedded at compile time and deployed services do not discover migration files
at runtime. The first seven entries preserve the historical Codd payloads
byte-for-byte; `0008` through `0017` are ten native-only forward migrations.

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
`0008` through `0017` as pending. Before running `up`, follow the stopped-worker
and write-pause requirements below for the pending migrations. It must report seven `AlreadyApplied`
outcomes and ten `AppliedNow` outcomes. A final `verify` must be clean across all seventeen native
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

## Migration 0012 needs a maintenance window

`0012` (kiroku-store-migrations 0.6.0.0) adds `stream_events.category`,
backfills it on every existing `$all` junction row from the source stream's
category, adds the check constraint `ck_stream_events_all_category`, and builds
the partial index `ix_stream_events_all_by_category` that category reads now
use. kiroku-store 0.9.0.0 requires it: its append statements write the new
column, so they fail with SQLSTATE `42703` against a schema that has not applied
`0012`. The reverse also holds: after `0012`, kiroku-store 0.8 and older fail
every append with SQLSTATE `23514`, because their `$all` rows carry no
category. There is no rolling-deploy path across this migration:

1. rehearse `0012` on a restored clone to time the window;
2. stop every process that appends with the old library (readers may keep
   running; their reads work on either schema);
3. apply `0012`;
4. run the `VACUUM` below;
5. start the processes on kiroku-store 0.9.

Consuming projects can run the `kiroku-upgrade` Seihou blueprint's
`0.8.0.2 -> 0.9.0.0` edge, which classifies their databases and deploy
automation and hands the operator this sequence.

The migration runs in one transaction, and its duration grows with the number
of events in the store. The backfill rewrites every `$all` row, the constraint
check reads the table once, and the index build reads the `$all` rows again.
Appends are blocked until it commits, so on a large store apply it in a
maintenance window. Afterwards run:

```sql
VACUUM (ANALYZE) kiroku.stream_events;
```

That reclaims the row versions the backfill replaced and refreshes planner
statistics for the new index. A failure at any point rolls the whole migration
back, including the temporarily disabled `no_update_stream_events` trigger.

## Migrations 0013 and 0014 need stopped workers

Stop every subscription worker and prevent restarts before running
`kiroku-store-migrate up` for `0013` and `0014`
(kiroku-store-migrations 0.7.0.0, required by kiroku-store 0.10.0.0).
`0013` derives `consumer_group_size` for each subscription name as the highest
stored member index plus one. `0014` adds `target_kind` and `target_category`,
initially leaving legacy checkpoints unbound, and drops the legacy `stream_name`
column. A running worker can save incompatible size or binding metadata, so keep
all workers stopped through migration and configuration review.

Before restarting, confirm the intended group size and historical subscription
target. Startup validates persisted topology and binding before delivery; adopt
an unbound legacy target explicitly through the configured target-binding policy
only after verifying its identity. An incomplete legacy group can derive a smaller
size and refuse startup with `ConsumerGroupSizeMismatch`. Ordinary resize alone
can skip the backlog of a member that never checkpointed: its new row starts at
the existing group's minimum, above events that member never processed. Read
[Incomplete legacy groups](consumer-groups.md#incomplete-legacy-groups) before
changing those checkpoints. Dedicated recovery implementation is deferred; no
validated recovery procedure is provided. If history must be retained, keep the
workers stopped and establish the recovery requirement first.

The consumer upgrade instructions are in the
[`0.9.0.1 -> 0.10.0.0` edge](../../blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md).

## Migration 0015 blocks appends during its index build

`0015` (kiroku-store-migrations 0.7.1.0, required by kiroku-store 0.11.0.0)
creates the byte-ordered stream-name index `ix_streams_browse_name` with a plain
transactional `CREATE INDEX`. Its `SHARE` lock on `kiroku.streams` blocks writes
to that table, so every append waits until the build commits. Build duration
grows with the number of streams, rather than the number of events.

For a large store, rehearse `kiroku-store-migrate up` on a restored clone to time
the build, schedule a write pause, and stop appending processes before applying
`0015`. Run `verify` and resume appends after the migration commits. See the
[`0.10.0.0 -> 0.11.0.0` edge](../../blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md)
for the rest of the consumer upgrade.

## Store identity and compaction ledger

Migration `0017` installs the immutable `kiroku.store_identity` singleton and
empty append-only `kiroku.event_compactions` ledger. Read the identity through
`storeIdentity` or `storeIdentityTx`; a restored clone shares its source identity
so a maintenance manifest can be rehearsed against the clone. Both new tables
reuse the existing mutation and hard-delete guards, with no change to ordinary
append or read paths.
