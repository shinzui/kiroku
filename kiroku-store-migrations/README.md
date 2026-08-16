# kiroku-store-migrations

`kiroku-store-migrations` owns Kiroku's PostgreSQL schema as one native
`pg-migrate` component named `kiroku`. The component embeds an ordered manifest
and eleven SQL payloads, so applications can compose it with other libraries
without copying Kiroku SQL. The first seven payloads are immutable historical
Codd bytes; `0008` through `0011` are native-only forward migrations.

## Public API

```haskell
import Kiroku.Store.Migrations

kirokuMigrations :: Either DefinitionError MigrationComponent
kirokuMigrationPlan :: Either PlanError MigrationPlan
```

Applications with more than one component should consume `kirokuMigrations`
and build their own explicit dependency-ordered plan. The single-component
`kirokuMigrationPlan` is convenient for Kiroku-only deployments.

Existing databases can import their Codd ledger through
`Kiroku.Store.Migrations.History.Codd`:

```haskell
kirokuCoddHistoryMappings :: NonEmpty HistoryMapping
kirokuCoddSourcePayloads :: Map FilePath ByteString
kirokuCoddManifestText :: Text

kirokuCoddSourceConfig
  :: ConnectionProvider
  -> Bool
  -> Text
  -> Confirmation
  -> Either CoddDefinitionError CoddSourceConfig
```

The mapping selects the seven historical timestamped Codd names, verifies the
checked-in `migrations.lock` SHA-256 evidence against the exact embedded native
bytes, and maps them to `kiroku/0001-kiroku-bootstrap` through
`kiroku/0007-stream-truncate-before`. Import writes only the `pgmigrate` ledger;
it never executes already-applied SQL. Consumers with a shared Codd ledger can
combine the exported names, payload map, manifest text, and history mappings
with their own component evidence before constructing one atomic import.

## CLI

`kiroku-store-migrate` mounts the standard `pg-migrate-cli` command groups:

```bash
kiroku-store-migrate --help
kiroku-store-migrate plan
kiroku-store-migrate list
kiroku-store-migrate check --manifest kiroku-store-migrations/migrations/manifest
kiroku-store-migrate up --database-url "$DATABASE_URL"
kiroku-store-migrate verify --database-url "$DATABASE_URL"
kiroku-store-migrate status --database-url "$DATABASE_URL"
```

Database commands accept `--database-url`. When it is omitted the executable
uses `DATABASE_URL`. Local `plan`, `list`, `check`, and `new` commands need no
database environment variable. `verify` compares the declared plan strictly
with the `pgmigrate` ledger; it is not a live schema snapshot comparison.

For Haskell callers:

```haskell
import Database.PostgreSQL.Migrate
import Hasql.Connection.Settings qualified as Settings
import Kiroku.Store.Migrations

main :: IO ()
main = do
  plan <- either (fail . show) pure kirokuMigrationPlan
  result <- runMigrationPlan defaultRunOptions (Settings.connectionString databaseUrl) plan
  either (fail . show) (const (pure ())) result
```

## Authoring

The authoritative source is `migrations/manifest`; each line names one SQL file
in execution order. Create the next numeric file with the standard CLI:

```bash
kiroku-store-migrate new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "add widget index"
```

The helper exclusively creates the inferred file and atomically appends its
name to the manifest. Never edit a released payload. Correct mistakes with a
new forward migration. The seven initial payloads intentionally retain their
exact historical bytes, including old comments, because Codd import uses
`SamePayload` evidence.

Run the package suite after every migration change:

```bash
cabal test kiroku-store-migrations:kiroku-store-migrations-test
```

It proves manifest order, legacy SHA-256 parity, fresh apply, strict verify,
idempotent rerun, concurrent locking, current Codd V5 import, legacy
`codd_schema` import, partial-row rejection, import audit records, and
source-ledger preservation. The relation contract suite also proves the frozen
`kiroku.subscription_checkpoints_v1` catalog, non-null value semantics,
owner-rights privilege isolation, structural read-only behavior, downstream
view survival, and indexed query plan. It also applies the plan's pending tail
in a session that never ran `0001` and cannot reach the Kiroku schema through
`search_path`, which is the upgrade shape BUG-1 lived in.
`cabal test kiroku-store:kiroku-store-test` consumes the same native plan
through `kiroku-test-support` and proves the complete store behavior, including
append and read scenarios.

### Both PostgreSQL majors

The suites reach PostgreSQL through `ephemeral-pg`, which runs whichever server
is on `PATH`, and the default dev shell carries only PostgreSQL 18. Migration
behavior differs by major -- `uuidv7()` is a builtin on 18 and comes from
`0001`'s fallback on 17 -- so a single-major run cannot cover this package.
Run both:

```bash
just test-matrix        # every suite, on PostgreSQL 17 and then 18
just test-pg 17         # one major
```

Each recipe enters the matching `nix develop .#postgresql<major>` shell and
refuses to run if that major is not the one on `PATH`. The suite reports the
route it exercised, so a run states which half of the matrix it covered:

```
PostgreSQL 17 UUIDv7 generator: kiroku.uuidv7() via 0001's fallback
PostgreSQL 18 UUIDv7 generator: kiroku.uuidv7() via 0010's alias for the builtin
```

Run the matrix before releasing this package, and after any migration change
that touches version-dependent behavior.

Migration `0010` adds replay-history retention leases, the per-schema
coordinator, an indexed active-lease predicate, and statement-level
`DELETE`/`TRUNCATE` guards on the three event-store data tables. Migration
`0011` converges databases that applied the withdrawn 0.3.2.x payload of `0010`
(see below).

## The `kiroku.uuidv7()` generator

`uuidv7()` is a PostgreSQL 18 builtin. On PostgreSQL 17 `0001` installs a
fallback into the Kiroku schema, and it does so under its own
`SET search_path`, so the bare name resolves only in a session that ran `0001`.
Every migration after `0001` runs in whatever session the operator's upgrade
happens to use, so none of them may name it unqualified — that is BUG-1, fixed
in 0.4.0.0.

`0010` therefore publishes `kiroku.uuidv7()` on every supported major version:
PostgreSQL 17 already has it from `0001`, and PostgreSQL 18 gets a thin alias
for the builtin. **New migrations that need a UUIDv7 value must call
`kiroku.uuidv7()`, never bare `uuidv7()`.** The qualified name resolves without
any session state on every version the component supports.

The same rule holds for every other object: name it `kiroku.<name>`. Only
`0001` may rely on `search_path`, because it is the only migration guaranteed
to have set it.

## Recovery

Migrations are forward-only. Before a persistent upgrade, take a backup. If an
applied migration is bad, either restore that backup or append a corrective
migration. Do not delete or rewrite an applied `pgmigrate.migrations` row except
through the reviewed `pg-migrate` repair workflow.

`ledger-fixups/` holds operator scripts that adjust the migration ledger's
bookkeeping without touching your schema. Read the header of a script before
running it; each states exactly which databases need it.

* `2026-07-05-realign-kiroku-migration-timestamps.sql` is historical, kept as
  source evidence for databases that once needed Codd timestamp repair. New
  native migrations use component-local numeric identities.
* `2026-08-16-rebaseline-0010-checksum.sql` re-baselines `0010`'s stored
  checksum for databases that applied the withdrawn 0.3.2.0/0.3.2.1 payload.
  Required before migrating such a database onto 0.4.0.0 or later; see the
  changelog.
