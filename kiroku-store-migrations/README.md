# kiroku-store-migrations

`kiroku-store-migrations` owns Kiroku's PostgreSQL schema as one native
`pg-migrate` component named `kiroku`. The component embeds an ordered manifest
and seven immutable SQL payloads, so applications can compose it with other
libraries without copying Kiroku SQL.

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
kiroku-store-migrate check kiroku-store-migrations/migrations/manifest
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
source-ledger preservation. `cabal test kiroku-store:kiroku-store-test` consumes
the same native plan through `kiroku-test-support` and proves the complete store
behavior, including append and read scenarios.

## Recovery

Migrations are forward-only. Before a persistent upgrade, take a backup. If an
applied migration is bad, either restore that backup or append a corrective
migration. Do not delete or rewrite an applied `pgmigrate.migrations` row except
through the reviewed `pg-migrate` repair workflow.

The historical script under `ledger-fixups/` remains checked in only as source
evidence for databases that previously needed Codd timestamp repair. New native
migrations use component-local numeric identities and do not use timestamped
filenames.
