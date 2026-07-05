---
id: 67
slug: add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations
title: "Add a portable strict codd expected-schema drift gate for kiroku migrations"
kind: exec-plan
created_at: 2026-07-05T19:09:18Z
intention: "intention_01kwstss55e79aafxgtcw6631j"
master_plan: "docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md"
---

# Add a portable strict codd expected-schema drift gate for kiroku migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is an event-store library written in Haskell (`shinzui/kiroku`). The package
`kiroku-store-migrations` owns how kiroku's PostgreSQL schema evolves: it embeds a set of
timestamped SQL files (`kiroku-store-migrations/sql-migrations/*.sql`) and applies them
through **codd** — the Haskell migration library `mzabani/codd` — which records each applied
migration by filename in a ledger table and can, optionally, compare the resulting live
database against a checked-in **expected-schema snapshot**.

Today kiroku has **no** such snapshot and never performs that comparison. Its migration test
(`kiroku-store-migrations/test/Main.hs`) sets `onDiskReps = Right (DbRep Null Map.empty
Map.empty)` — an empty *in-memory* representation — and only ever calls
`runKirokuMigrationsNoCheck`. That means a migration that silently changes the schema (a
dropped column, a renamed index, an altered constraint that the hand-written `assert*`
queries do not happen to probe) is caught by *nothing*. The checked runner
`runKirokuMigrations` exists in the code but is unused and unbacked by any snapshot, and the
package README says so outright ("Kiroku does not yet ship a checked-in codd expected-schema
snapshot").

**What you gain after this change.** After this plan, `kiroku-store-migrations` ships a
checked-in codd snapshot under `kiroku-store-migrations/expected-schema/vNN/` (where `NN` is
the PostgreSQL major version the snapshot was captured against — determined empirically, see
below), and `cabal test kiroku-store-migrations-test` gains a new example that applies every
migration to a throwaway database and asserts, with codd's `StrictCheck`, that the live schema
is **byte-for-byte equal** to that snapshot. Any un-snapshotted schema change now fails the
test. Crucially, the snapshot is **portable from the first commit**: the throwaway PostgreSQL
server's superuser is pinned to the fixed, machine-independent name `kiroku`, so the captured
role and object owners are deterministic on every developer's machine and in CI — not just the
author's. You can see it working: `cabal run kiroku-write-expected-schema` regenerates the
tree; `grep -R "$(whoami)" kiroku-store-migrations/expected-schema` finds nothing (no
OS-username leak); `cabal test kiroku-store-migrations-test` passes on a machine whose OS user
is arbitrary; perturbing one column in the snapshot makes the strict example fail; and `nix
build .#kiroku-store-migrations` still succeeds because the new generator executable is gated
behind a cabal flag that nix turns off (kiroku's `ephemeral-pg` dependency has no buildable
derivation in the pinned nix Haskell set, so an ungated executable would break `nix build`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `kiroku-store-migrations/app/WriteExpectedSchema.hs` and the
      `flag expected-schema-tool` + `executable kiroku-write-expected-schema` stanza to the
      cabal file; `cabal build kiroku-write-expected-schema` succeeds (flag default `True`).
- [ ] M2: Pin the ephemeral-pg superuser to `kiroku` in the generator; run
      `cabal run kiroku-write-expected-schema`; observe the actual `vNN` directory written;
      `git add` the tree; grep proves no OS-username leak.
- [ ] M3: Change `testCoddSettings`'s `onDiskReps` to `Left <dir>`; add `kirokuPgConfig` +
      `withKirokuPg` helpers and a `findExpectedSchemaDir` helper; add the `StrictCheck`
      example calling `runKirokuMigrations ... StrictCheck` and expecting `SchemasMatch`;
      `cabal test kiroku-store-migrations-test` is green including the strict example.
- [ ] M4: Negative test — perturb one column objrep in the snapshot, confirm the strict
      example FAILS with a different-schemas diff, restore, confirm it passes again. The break
      is never committed.
- [ ] M5: Wrap the `kiroku-store-migrations` derivation in `nix/haskell-overlay.nix` in
      `overrideCabal` with `configureFlags = [ "-f-expected-schema-tool" ]` and
      `executableHaskellDepends = [ ]`; `git add` the new files and the whole
      `expected-schema/` tree; `nix build .#kiroku-store-migrations` succeeds.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05 (seed — codd role/owner capture): codd **always** captures the connecting
  user's role and the database owner, regardless of `namespacesToCheck` or
  `extraRolesToCheck`. In this repo's pinned codd
  (`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Representations/Database.hs`,
  lines 297–298) `readRepresentationsFromDbWithSettings` computes
  `rolesToCheck = (SqlRole . Text.pack . user $ migsConnString) : extraRolesToCheck`. Under
  `ephemeral-pg` the connecting user defaults to the local OS username, so an on-disk strict
  snapshot generated with the default config leaks that username into `roles/<osuser>`, into
  `db-settings` (`owner`, `public_privileges`), and into every object's `owner` field. Because
  `StrictCheck` compares the full `DbRep` (roles + db-settings + schemas), you **cannot** fix
  this by deleting files; you must make the identity deterministic by pinning the ephemeral-pg
  user. This is why EP-2 builds the gate portable from the first commit rather than shipping a
  leaky snapshot and fixing it later. (Mechanism carried over from keiro plan 87.)
- 2026-07-05 (seed — the nix build-closure trap): `nix build .#kiroku-store-migrations` builds
  the package library **and all executables** (only the *test suite* is skipped, via
  `dontCheck` at `nix/haskell-overlay.nix:118`). The new `kiroku-write-expected-schema`
  executable depends on `ephemeral-pg`, whose derivation does **not** build in this repo's
  pinned nixpkgs Haskell set. Adding the executable naively therefore breaks `nix build`. The
  fix mirrors the existing `kiroku-metrics` derivation
  (`nix/haskell-overlay.nix:140-158`): a cabal `flag` turned off with
  `configureFlags = [ "-f-<flag>" ]` **plus** `executableHaskellDepends = [ ]`, because
  `cabal2nix` lists an executable's build-depends regardless of flag conditionals. Both are
  required. (Source: memory `project_nix_executable_test_dep_closure`, confirmed against the
  current overlay.)
- 2026-07-05 (seed — `withCachedConfig` is not exported): `EphemeralPg` exports `withCached`
  (which hard-wires `defaultConfig`, i.e. an empty user), `startCached`, `stop`, and
  `Config (..)` with its `user :: Text` field — but it does **not** export `withCachedConfig`.
  Verified by reading the module export list in
  `/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg.hs`. So to
  run a *cached* server with a pinned user you must call `startCached config cacheConfig` and
  manage teardown yourself with `finally`/`bracket` + `Pg.stop`; you cannot pass a user to
  `Pg.withCached`. This shapes both the generator and the test helper.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the drift gate **portable from the first commit** rather than shipping a
  machine-dependent snapshot and fixing it in a later plan.
  Rationale: kiroku has no snapshot today, so there is no interim leaky state worth a separate
  plan; building it portable in one stream is strictly cleaner than deliberately shipping a
  broken one. codd always captures the connecting role and DB owner, so portability *requires*
  a deterministic pinned identity, not zero role files.
  Date: 2026-07-05

- Decision: Pin the ephemeral-pg PostgreSQL superuser to the literal name `kiroku` (via
  `Pg.defaultConfig { Pg.user = "kiroku" }` + `Pg.startCached`), for both the generator
  executable and the strict test.
  Rationale: A fixed, non-empty user is passed to `initdb --username=` and becomes part of the
  initdb cache key, so it is deterministic on every machine and CI. `kiroku` matches the schema
  name. It is per-repo and does not conflict with keiro's `keiro` pin (keiro's combined
  snapshot is generated by keiro's own tool in the keiro repo).
  Date: 2026-07-05

- Decision: Keep `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]` unchanged — there is
  **no** re-scoping to do.
  Rationale: kiroku is already correctly scoped to its own `kiroku` schema. Unlike keiro (which
  had to move its tables out of the `kiroku` schema and re-scope its gate to `keiro`), kiroku
  owns and drift-gates the `kiroku` schema and only that. This decision distinguishes EP-2 from
  its keiro model (keiro plan 87), which *did* re-scope.
  Date: 2026-07-05

- Decision: Gate the new `kiroku-write-expected-schema` executable behind a cabal
  `flag expected-schema-tool` (default `True`, `manual: False`) and disable it in
  `nix/haskell-overlay.nix`.
  Rationale: `nix build` compiles executables and `ephemeral-pg` has no buildable derivation in
  the pinned Haskell set, so an ungated exe breaks `nix build .#kiroku-store-migrations`. The
  `kiroku-metrics` derivation (overlay lines 140–158) is the proven in-repo pattern. Default
  `True` keeps `cabal run kiroku-write-expected-schema` working in the dev shell; nix passes
  `-f-expected-schema-tool` to turn it off.
  Date: 2026-07-05

- Decision: Deliver the generator as a **separate executable**
  (`kiroku-write-expected-schema`), not a subcommand of `kiroku-store-migrate`.
  Rationale: The apply tool (`kiroku-store-migrate`, owned by EP-1) must build under nix and
  must *not* depend on `ephemeral-pg`; the generator inherently needs `ephemeral-pg`. Keeping
  them as separate executables lets the flag gate exactly one of them, mirroring keiro's split
  of `keiro-migrate` from `keiro-write-expected-schema`. EP-2 does not touch `app/Main.hs`.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Every path is repository-relative
from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

### What "schema drift" and "expected-schema snapshot" mean

A PostgreSQL **schema** is a namespace inside one database (not the whole database). kiroku
places all of its tables in a schema called `kiroku` (its bootstrap migration issues
`CREATE SCHEMA IF NOT EXISTS kiroku;` and every table is hard-qualified `kiroku.<table>`).
**Schema drift** is the situation where the migration SQL files and the actual database shape
fall out of sync — for example a migration is edited so it no longer produces the column an
older migration promised, or an index is renamed, and nothing notices. codd's remedy is an
**expected-schema snapshot**: a checked-in tree of small JSON files describing every table,
column, constraint, index, trigger, sequence, routine, role, and database setting. A test
applies all migrations to a throwaway database, reads back the live shape, and compares it to
the snapshot. If they differ, the test fails.

### codd, and the types this plan uses

codd is the Haskell library `mzabani/codd`, pinned in this repo from a fork by git in
`cabal.project` (`shinzui/codd-project`, `subdir: codd`). Its source on disk is at
`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd`. The public types that matter:

```haskell
data VerifySchemas = LaxCheck | StrictCheck
data ApplyResult   = SchemasDiffer SchemasPair | SchemasMatch DbRep | SchemasNotVerified
data CoddSettings  = CoddSettings
  { migsConnString    :: ConnectionString
  , sqlMigrations     :: [FilePath]
  , onDiskReps        :: Either FilePath DbRep   -- Left dir = read the snapshot from disk
  , namespacesToCheck :: SchemaSelection
  , extraRolesToCheck :: [SqlRole]
  , retryPolicy       :: RetryPolicy
  , txnIsolationLvl   :: TxnIsolationLvl
  , schemaAlgoOpts    :: SchemaAlgo
  }
data SchemaSelection = IncludeSchemas [SqlSchema] | AllNonInternalSchemas
```

`StrictCheck` throws on a mismatch (`applyMigrations` returns after verifying, and codd raises
a `user error` describing the differing objects); `LaxCheck` returns `SchemasDiffer` without
throwing. `onDiskReps = Left "kiroku-store-migrations/expected-schema"` means "read the
expected snapshot from that directory". codd writes and reads the snapshot under a subdirectory
named for the PostgreSQL **major version** — for example `v18` — so the on-disk tree root is
`kiroku-store-migrations/expected-schema/vNN/`, where `NN` is the server major version. **Do
not assume `NN` — observe it.** kiroku supports a PostgreSQL 17 fallback path, so on a PG17
server the directory would be `v17`. The sibling keiro repository, generated on this machine,
produced `v18`, so `v18` is the most likely value here — but the implementer must run the
generator and commit whatever `vNN` directory actually appears. Because codd reads
`expected-schema/<server-major>/`, the snapshot is inherently per-major-version: a snapshot
captured on PG18 will not be found by a test server running PG17 and vice versa.

The empty in-memory representation kiroku uses today, `DbRep Null Map.empty Map.empty`, is a
useful hint about codd's structure: `Null` is the db-settings slot, and the two empty maps are
the schemas map and the roles map — confirming that db-settings, schemas, and roles are three
explicit, comparable slots inside a `DbRep`.

### The migration runner module

`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` embeds the SQL files at compile time
(`embeddedMigrationFiles = $(embedDir "sql-migrations")`) and exposes two runners:

```haskell
runKirokuMigrations        :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
```

`runKirokuMigrations` applies all migrations and then compares the result to the expected
schema according to the `VerifySchemas` argument — this is the **checked** runner, currently
unused, and this plan is what finally wires it to a real snapshot. `runKirokuMigrationsNoCheck`
applies the same migrations but returns `SchemasNotVerified` without comparing (it still uses
codd's ledger and locking). Note both return `IO ApplyResult` in kiroku (keiro's no-check
runner returns `IO ()`; this is a small difference to keep in mind when adapting keiro code —
in kiroku you bind the result with `_ <-` if you do not need it).

### The migration test file

`kiroku-store-migrations/test/Main.hs` currently contains three relevant pieces:

- `migrationFileNameSpec` — a guard that rejects hand-assigned "sentinel" migration timestamps.
  **This plan does not touch it.** (It is shared with EP-1, which owns a separate
  `scaffolderSpec`; see the ownership note below.)
- the `codd migration spike` example — it acquires a throwaway server with `Pg.withCached`,
  builds settings with `testCoddSettings`, applies migrations with `runKirokuMigrationsNoCheck`,
  and runs many hand-written `assert*` queries (`assertBootstrapApplied`, `assertSchemaPlacement`,
  `assertDeadLettersTable`, `assertStreamTriggers`, and so on). These `assert*` helpers are
  narrow probes: they check specific objects, not the whole schema, which is exactly why a
  broad strict gate is valuable.
- `testCoddSettings :: Text -> CoddSettings` — builds `CoddSettings` with
  `onDiskReps = Right (DbRep Null Map.empty Map.empty)` and
  `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]`.

### ephemeral-pg (the throwaway-server library)

`EphemeralPg`, imported qualified as `Pg`, is the package `shinzui/ephemeral-pg` (source at
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`). It spins up a throwaway
PostgreSQL server for a test. `Pg.withCached :: (Database -> IO a) -> IO (Either StartError a)`
starts a *cached* server (initdb output is cached and reused across runs for speed) but
hard-wires `defaultConfig`, whose `user` field is `""`. When `user` is empty, ephemeral-pg
initialises the cluster with the **local OS username** as the PostgreSQL superuser and object
owner — which is precisely the identity that leaks into a strict snapshot (see Surprises &
Discoveries). `Pg.Config` has a `user :: Text` field; a non-empty value is passed straight to
`initdb --username=<user>` and included in the initdb cache key, so pinning `"kiroku"` is safe,
deterministic, and gets its own cache namespace. The exported cached entry point that accepts a
`Config` is:

```haskell
startCached :: Config -> CacheConfig -> IO (Either StartError Database)
```

`withCachedConfig` (the wrapper that would combine a `Config` with cached startup and automatic
teardown) is **not exported**. So to use a pinned user with initdb caching you must call
`Pg.startCached kirokuPgConfig Pg.defaultCacheConfig` and tear down with `finally`/`bracket`
and `Pg.stop`. Other exports used here: `Pg.defaultConfig`, `Pg.defaultCacheConfig`,
`Pg.connectionString`, `Pg.stop`, and the types `Pg.Config`, `Pg.Database`, `Pg.StartError`.

### The nix overlay and the build-closure trap

`nix/haskell-overlay.nix` defines each package's nix derivation. At line 118 today:

```nix
kiroku-store-migrations = dontCheck (
  doJailbreak (final.callCabal2nix "kiroku-store-migrations" ../kiroku-store-migrations { })
);
```

`dontCheck` skips the *test suite* (so the test's `ephemeral-pg` dependency never enters the
build), but `callCabal2nix` still builds the package **library and every executable**. Because
this plan adds an executable that depends on `ephemeral-pg` — which has no buildable derivation
in the pinned nixpkgs Haskell set — building it under nix would fail. The overlay already
solves the identical problem for `kiroku-metrics` at lines 140–158: it wraps the derivation in
`overrideCabal` and sets `configureFlags = [ "-f-example" ]` (turning off a cabal flag that
gates the example executable) **and** `executableHaskellDepends = [ ]` (because `cabal2nix`
emits an executable's build-depends into the derivation regardless of whether a flag would
exclude it at build time). This plan copies that pattern exactly for its own flag. One
kiroku-specific subtlety to note: `kiroku-store-migrations` has **two** executables
(`kiroku-store-migrate`, which must keep building under nix, and the new gated
`kiroku-write-expected-schema`). Emptying `executableHaskellDepends` strips the *combined* exe
dependency list, including `kiroku-store-migrate`'s (`base`, `codd`, `kiroku-store-migrations`,
`time`). That is safe here because every one of those is also in the library's
`libraryHaskellDepends` (`base`, `codd`, `time`) or is the package itself, so they remain
available in the build environment. This must be verified by an actual `nix build` (M5), and it
is called out as a reviewer caveat.

Finally, nix flakes only include **git-tracked** files. The generated
`expected-schema/vNN/` tree and the new `WriteExpectedSchema.hs` must be `git add`ed before
`nix build` (and before the flake can see them at all), even though they are not committed
until the end.

### Relationship to the sibling plans (all checked into this repo)

This plan is EP-2 of the MasterPlan
`docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md`.
It has **no hard dependencies**. EP-1
(`docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md`) adds a
migration scaffolder and can proceed fully in parallel. EP-3
(`docs/plans/68-document-kiroku-migration-authoring-verification-and-forward-only-recovery.md`)
documents the final workflow and soft-depends on this plan. EP-1 and EP-2 both edit
`kiroku-store-migrations/test/Main.hs` and `kiroku-store-migrations/kiroku-store-migrations.cabal`
but in disjoint functions/stanzas; whichever lands second rebases its edits onto the first
(a mechanical merge). EP-2 owns, in `test/Main.hs`: `testCoddSettings` (the `onDiskReps`
change), the new `StrictCheck` example, and the new `kirokuPgConfig`/`withKirokuPg`/
`findExpectedSchemaDir` helpers. EP-2 must **not** edit `migrationFileNameSpec` or EP-1's
`scaffolderSpec`. In the cabal file EP-2 owns the new `flag expected-schema-tool` and the new
`executable kiroku-write-expected-schema` stanza. EP-2 owns the entire nix change. EP-2 does
**not** touch `app/Main.hs` (EP-1's).

The direct code model for this plan is keiro's already-shipped
`keiro-write-expected-schema` executable and its portability plan
`/Users/shinzui/Keikaku/bokuno/keiro/docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md`.
The one deliberate difference from keiro plan 87: keiro re-scoped `namespacesToCheck` from
`kiroku` to `keiro`; **kiroku does not re-scope at all** — it is already correctly scoped to
`kiroku`.


## Plan of Work

The work is five milestones. M1 adds the generator executable and the cabal flag so the code
compiles and the flag exists (nothing generated yet). M2 pins the identity and generates the
snapshot, proving portability by inspection. M3 wires the test to read the snapshot and adds
the strict example. M4 proves the gate is meaningful with a negative test. M5 defuses the nix
build-closure trap and turns `nix build` green. Each milestone is independently verifiable.

### Milestone 1: add the generator executable and the cabal flag (build only)

Scope. Add a new file `kiroku-store-migrations/app/WriteExpectedSchema.hs` and, in
`kiroku-store-migrations/kiroku-store-migrations.cabal`, a `flag expected-schema-tool` and an
`executable kiroku-write-expected-schema` stanza gated on it. At the end of M1 the executable
compiles in the dev shell (flag default `True`) but has not yet been run and does not yet pin
the user or generate anything.

Create `kiroku-store-migrations/app/WriteExpectedSchema.hs`. It mirrors keiro's
`keiro-write-expected-schema` but (a) imports kiroku's runner, (b) uses kiroku's default output
directory, and (c) — the portability pin, applied here in one go so M1 already contains it —
starts a *cached* server with a pinned `kiroku` user via `Pg.startCached` + `finally` instead
of `Pg.withCached`. Note kiroku's `runKirokuMigrationsNoCheck` returns `IO ApplyResult`, so its
result is discarded with `_ <-`:

```haskell
module Main (main) where

import Codd (CoddSettings (..))
import Codd.AppCommands.WriteSchema (WriteSchemaOpts (WriteToDisk), writeSchema)
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Exception (finally)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import System.Environment (getArgs)

-- | Pin the throwaway PostgreSQL superuser to a fixed, machine-independent name
-- so the captured snapshot identity (the connecting role, the db owner, and every
-- object owner) is deterministic on every machine and in CI. codd always records
-- the connecting user's role and the database owner, so a non-deterministic user
-- would make the strict drift gate false-fail off the author's machine.
kirokuPgConfig :: Pg.Config
kirokuPgConfig = Pg.defaultConfig { Pg.user = "kiroku" }

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    -- 'Pg.withCachedConfig' is not exported, so we use 'Pg.startCached' (which
    -- accepts a Config carrying the pinned user) and tear down with 'finally'.
    started <- Pg.startCached kirokuPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let connStr = Pg.connectionString db
                    settings = coddSettings connStr outputDir
                _ <- runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)
                writeSchema settings (WriteToDisk (Just outputDir))
                putStrLn ("Wrote expected schema to " <> outputDir)
            )
                `finally` Pg.stop db

parseArgs :: [String] -> IO FilePath
parseArgs [] = pure "kiroku-store-migrations/expected-schema"
parseArgs [outputDir] = pure outputDir
parseArgs _ = fail "usage: cabal run kiroku-write-expected-schema -- [output-dir]"

coddSettings :: Text -> FilePath -> CoddSettings
coddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed
```

Now edit `kiroku-store-migrations/kiroku-store-migrations.cabal`. Add a flag stanza and the
executable stanza. Place the flag before the `library` stanza (conventional) or immediately
before the new executable — cabal does not care about order, but keep it readable. The flag:

```cabal
flag expected-schema-tool
  description:
    Build the kiroku-write-expected-schema executable, which regenerates the
    checked-in codd expected-schema snapshot. On by default so
    `cabal run kiroku-write-expected-schema` works in the dev shell. It depends
    on ephemeral-pg, which has no buildable source in the pinned Nix Haskell
    set, so nix turns it off with `-f-expected-schema-tool`.
  default:     True
  manual:      False
```

The executable stanza (note the `if !flag(...)` guard that makes it non-buildable when the flag
is off, exactly like `kiroku-metrics-example`):

```cabal
executable kiroku-write-expected-schema
  import:         common
  main-is:        WriteExpectedSchema.hs
  hs-source-dirs: app
  ghc-options:    -threaded -rtsopts -with-rtsopts=-N

  if !flag(expected-schema-tool)
    buildable: False

  build-depends:
    , attoparsec
    , base                     >=4.18 && <5
    , codd
    , ephemeral-pg             >=0.2  && <0.3
    , kiroku-store-migrations
    , text                     >=2.0  && <2.2
    , time                     >=1.12 && <1.15
```

Two notes on the stanza. First, `main-is: WriteExpectedSchema.hs` with `hs-source-dirs: app`
means both executables live in `app/` — `kiroku-store-migrate` uses `Main.hs`, the generator
uses `WriteExpectedSchema.hs`; that is fine because each executable names its own `main-is`.
Second, `ephemeral-pg >=0.2 && <0.3` is already the test suite's dependency bound, so it is a
known-good version bound; the generator reuses it.

Acceptance for M1. From the repo root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build kiroku-write-expected-schema
```

Expect a successful build (the flag defaults to `True`). Do not run it yet. If the build fails
on `Codd.AppCommands.WriteSchema` not being found, confirm the pinned codd exposes that module
(it does in this repo's pinned codd — verified at
`/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/AppCommands/WriteSchema.hs`,
which exports `WriteSchemaOpts (..)` and `writeSchema`).

### Milestone 2: generate the portable snapshot and inspect it

Scope. Run the generator, observe the actual `vNN` directory it writes, and prove by inspection
that the pinned `kiroku` identity is deterministic and no OS-username leaked. At the end of M2
the tree `kiroku-store-migrations/expected-schema/vNN/` exists and is staged in git.

Because M1 already applied the pin, the generator writes a portable snapshot on the first run.
From the repo root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal run kiroku-write-expected-schema
```

Expected final line:

```text
Wrote expected schema to kiroku-store-migrations/expected-schema
```

Now observe which major-version directory appeared — **do not assume `v18`**:

```bash
ls kiroku-store-migrations/expected-schema
```

Expected: a single directory named `vNN` (most likely `v18` on this machine; `v17` if the
server is PostgreSQL 17). Record the actual value in Progress and the Decision Log; every
subsequent path in this plan that says `vNN` means that observed directory.

Inspect the shape of the tree and prove portability:

```bash
find kiroku-store-migrations/expected-schema -maxdepth 3 -type d | sort
cat kiroku-store-migrations/expected-schema/vNN/db-settings
ls kiroku-store-migrations/expected-schema/vNN/roles
```

Expected: a `db-settings` file whose `owner` is `"kiroku"` (not your OS username); a
`roles/kiroku` file (a single deterministic role); and a `schemas/kiroku/` subtree containing
kiroku's tables (`streams`, `events`, `stream_events`, `subscriptions`, `dead_letters`) with
their columns, indexes, constraints, and triggers. Confirm no machine-specific username leaked
anywhere in the tree:

```bash
grep -R "$(whoami)" kiroku-store-migrations/expected-schema ; echo "exit=$?"
grep -R '"owner": "kiroku"' kiroku-store-migrations/expected-schema/vNN/db-settings
```

Expected: the first `grep` prints nothing and reports `exit=1` (grep found nothing — no leak);
the second confirms the deterministic `kiroku` owner is present. If instead you see your OS
username in `db-settings` or under `roles/`, the pin did not take effect — re-check that
`WriteExpectedSchema.hs` uses `Pg.startCached kirokuPgConfig ...` and not `Pg.withCached`.

Stage the generated tree so nix (which only sees git-tracked files) and later commits include
it. Do not commit yet:

```bash
git add kiroku-store-migrations/app/WriteExpectedSchema.hs kiroku-store-migrations/expected-schema
```

Acceptance for M2. `ls kiroku-store-migrations/expected-schema` shows exactly one `vNN`
directory; `grep -R "$(whoami)" kiroku-store-migrations/expected-schema` is empty; `db-settings`
and `roles/` carry the literal `kiroku` identity; the tree is staged in git.

### Milestone 3: wire the test to the snapshot and add the strict example

Scope. Edit `kiroku-store-migrations/test/Main.hs` to read the checked-in snapshot and add a
new `StrictCheck` example that fails on any drift. At the end of M3
`cabal test kiroku-store-migrations-test` passes, including the new example.

Four edits, all in EP-2-owned code (leave `migrationFileNameSpec` untouched):

1. Imports. Extend the codd import to bring in the extra `ApplyResult` constructors and
   `VerifySchemas (StrictCheck)`, import the checked runner, and import `finally`:

```haskell
import Codd (ApplyResult (SchemasNotVerified, SchemasMatch, SchemasDiffer), CoddSettings (..), VerifySchemas (StrictCheck))
import Control.Exception (finally)
import Kiroku.Store.Migrations (runKirokuMigrations, runKirokuMigrationsNoCheck)
```

   Two imports become unused after edit (2) below and must be removed to keep the build clean:
   `Codd.Representations.Types (DbRep (..))` (only used by the empty in-memory `DbRep`) and
   `Data.Map qualified as Map` (only used by `Map.empty`). Also narrow
   `import Data.Aeson (Value (Null))` to `import Data.Aeson (Value)` — `Value` is still used by
   `makeEvent`, but the `Null` constructor is only used by the empty `DbRep`. Leaving these
   imports in place would produce `-Wunused-imports` warnings.

2. `testCoddSettings`. Change its signature to take the expected-schema directory and set
   `onDiskReps = Left`. This mirrors keiro's `testCoddSettings connStr dir`:

```haskell
testCoddSettings :: Text -> FilePath -> CoddSettings
testCoddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }
```

   The existing `codd migration spike` example calls `testCoddSettings connStr`; update that
   call to pass a directory. Because that example uses `runKirokuMigrationsNoCheck`, which does
   **not** read `onDiskReps`, the directory value there is inert — passing the literal
   `"kiroku-store-migrations/expected-schema"` is sufficient and matches keiro's spike example:

```haskell
        coddSettings = testCoddSettings connStr "kiroku-store-migrations/expected-schema"
```

3. Add the pinned-identity helpers and a snapshot-directory resolver near the other top-level
   helpers. `withKirokuPg` mirrors `Pg.withCached`'s `Either StartError a` result shape but
   pins the user, so the strict example's `case result of Left ... Right ...` structure stays
   familiar. `findExpectedSchemaDir` mirrors the existing `findMigrationsDir` so the suite works
   whether it is run from the repo root or the package directory:

```haskell
-- | Pin the throwaway PostgreSQL superuser to the fixed name "kiroku" so the
-- captured snapshot identity (roles, owners, db-settings) is deterministic on
-- every machine and in CI. Mirrors 'Pg.withCached' but pins the user;
-- 'Pg.withCachedConfig' is not exported, so we use 'Pg.startCached' + 'finally'.
kirokuPgConfig :: Pg.Config
kirokuPgConfig = Pg.defaultConfig { Pg.user = "kiroku" }

withKirokuPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)
withKirokuPg action = do
    started <- Pg.startCached kirokuPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> pure (Left err)
        Right db -> Right <$> (action db `finally` Pg.stop db)

-- | Locate the checked-in expected-schema directory whether the suite runs from
-- the repository root or from the kiroku-store-migrations package directory.
findExpectedSchemaDir :: IO FilePath
findExpectedSchemaDir = do
    let candidates = ["kiroku-store-migrations/expected-schema", "expected-schema"]
    existing <- filterM doesDirectoryExist candidates
    case existing of
        dir : _ -> pure dir
        [] ->
            expectationFailure "Could not find kiroku-store-migrations/expected-schema"
                >> pure "kiroku-store-migrations/expected-schema"
```

   `filterM` and `doesDirectoryExist` are already imported by the test. Switch the existing
   spike example's server acquisition from `Pg.withCached` to `withKirokuPg` as well; this is a
   behaviour-preserving change (the `assert*` queries check object presence, triggers, and
   indexes — none depend on the superuser name) and keeps the file consistent. Its result
   handling (`case result of Left ... Right () ...`) is unchanged because `withKirokuPg`
   returns the same `Either Pg.StartError ()` shape.

4. Add the new strict example inside the existing `describe "codd migration spike"` block (or a
   sibling `describe`), modeled on keiro's "matches the checked-in expected schema":

```haskell
            it "matches the checked-in expected schema (StrictCheck)" $ do
                expectedSchemaDir <- findExpectedSchemaDir
                result <- withKirokuPg $ \db -> do
                    let coddSettings = testCoddSettings (Pg.connectionString db) expectedSchemaDir
                    runKirokuMigrations coddSettings (secondsToDiffTime 5) StrictCheck
                case result of
                    Left err -> expectationFailure ("Failed to start ephemeral PostgreSQL: " <> show err)
                    Right (SchemasMatch _) -> pure ()
                    Right SchemasNotVerified -> expectationFailure "StrictCheck did not verify schemas"
                    Right (SchemasDiffer _) -> expectationFailure "StrictCheck returned a schema mismatch without throwing"
```

   Note codd's `StrictCheck` *throws* on a mismatch rather than returning `SchemasDiffer`, so a
   real drift surfaces as a failed expectation via the thrown `user error` (hspec reports the
   exception). The `SchemasDiffer`/`SchemasNotVerified` branches are defensive and should not
   normally be reached; they make the intent explicit.

Acceptance for M3. From the repo root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal test kiroku-store-migrations-test
```

Expect all examples to pass, including "matches the checked-in expected schema (StrictCheck)".
If the strict example fails immediately with a diff mentioning your OS username, the test is
not using the pinned user — confirm the example calls `withKirokuPg`, not `Pg.withCached`. If
it fails because codd cannot find the snapshot, confirm the `vNN` directory in the tree matches
the test server's PostgreSQL major version (codd reads `expected-schema/<server-major>/`); if
the versions differ, align the environment or regenerate on the matching major version.

### Milestone 4: prove the gate is meaningful (negative test)

Scope. Demonstrate that the strict example actually catches drift by perturbing the snapshot,
observing a failure, and restoring. Nothing here is committed.

First, find a real column objrep in the generated tree (do not assume a filename — `ls` it):

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
find kiroku-store-migrations/expected-schema/vNN/schemas/kiroku/tables -maxdepth 3 -type f -path '*/cols/*' | head
```

Pick any one, for example the `stream_name` column of `streams`
(`.../tables/streams/cols/stream_name`). Back it up, perturb one field (for instance flip a
boolean such as `"notnull"` from `false` to `true`, or change a type/default), run the strict
test, and confirm it fails; then restore and confirm it passes:

```bash
COL=kiroku-store-migrations/expected-schema/vNN/schemas/kiroku/tables/streams/cols/stream_name
cp "$COL" /tmp/kiroku-negtest-col.bak
# Edit "$COL": change one field, e.g. "notnull": false -> "notnull": true
cabal test kiroku-store-migrations-test   # EXPECT: the StrictCheck example FAILS with a different-schemas diff
cp /tmp/kiroku-negtest-col.bak "$COL"
cabal test kiroku-store-migrations-test   # EXPECT: passes again
```

Expected failing output shape (codd raises a `user error` naming the differing object; the
exact object path reflects the column you perturbed):

```text
Error: DB and expected schemas do not match. Differing objects and their current DB schemas are: {"schemas/kiroku/tables/streams/cols/stream_name":["different-schemas",{...,"notnull":false,...}]}
user error (Exiting. Database's schema differ from expected.)
```

Acceptance for M4. The strict example fails when the snapshot is perturbed and passes after
restore. **Do not commit the intentional break.** If for any reason the file is left modified,
restore it from `/tmp/kiroku-negtest-col.bak` (or `git checkout -- kiroku-store-migrations/expected-schema`).

### Milestone 5: defuse the nix build-closure trap and turn `nix build` green

Scope. Gate the generator executable off under nix so `ephemeral-pg` never enters the build
closure, and confirm `nix build .#kiroku-store-migrations` succeeds. At the end of M5 the whole
change is staged and the nix build is green.

Edit `nix/haskell-overlay.nix`. Replace the current `kiroku-store-migrations` binding (lines
118–120) with an `overrideCabal`-wrapped version that turns the flag off and empties the
executable deps, mirroring `kiroku-metrics` (lines 140–158):

```nix
  kiroku-store-migrations = dontCheck (
    doJailbreak (
      overrideCabal
        (_: {
          # The kiroku-write-expected-schema executable (cabal flag
          # `expected-schema-tool`, on by default so
          # `cabal run kiroku-write-expected-schema` works in the dev shell)
          # depends on ephemeral-pg, which has no buildable source in this
          # nixpkgs Haskell set. Turn the flag off and drop the executable
          # deps so the library and the kiroku-store-migrate executable still
          # build under nix. cabal2nix lists exe deps regardless of flags, so
          # both the flag-off and the emptied deps are required.
          configureFlags = [ "-f-expected-schema-tool" ];
          executableHaskellDepends = [ ];
        })
        (final.callCabal2nix "kiroku-store-migrations" ../kiroku-store-migrations { })
    )
  );
```

`overrideCabal` is already in scope in this file (it is used unqualified by the `kiroku-metrics`
binding). Emptying `executableHaskellDepends` removes the *combined* executable dependency list
— including `kiroku-store-migrate`'s (`base`, `codd`, `kiroku-store-migrations`, `time`) — but
those are all covered by the library's `libraryHaskellDepends` or are the package itself, so
`kiroku-store-migrate` still builds. Verify this with the actual build below rather than
assuming it.

Before building, ensure every new file is git-tracked (nix flakes ignore untracked files):

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
git add kiroku-store-migrations/app/WriteExpectedSchema.hs \
        kiroku-store-migrations/kiroku-store-migrations.cabal \
        kiroku-store-migrations/expected-schema \
        kiroku-store-migrations/test/Main.hs \
        nix/haskell-overlay.nix
git status --short
```

Then build under nix:

```bash
nix build .#kiroku-store-migrations
```

Expected: the build succeeds. If it fails with an `ephemeral-pg` error, the flag or the emptied
deps did not take effect — confirm both `configureFlags = [ "-f-expected-schema-tool" ]` and
`executableHaskellDepends = [ ]` are present in the overlay and that the flag name matches the
cabal `flag expected-schema-tool` exactly. If it fails because `kiroku-store-migrate` cannot
find `base`/`codd`/`time`, those are missing from `libraryHaskellDepends`; in that case, rather
than fully emptying `executableHaskellDepends`, set it to the minimal list
`kiroku-store-migrate` needs from the nix Haskell set — but first re-confirm they are library
deps (they are, per the current cabal file), so a full empty should work.

Acceptance for M5. `nix build .#kiroku-store-migrations` succeeds with the generator gated off;
`git status` shows the new tracked files. Then commit (see Concrete Steps).


## Concrete Steps

Run everything from the repository root unless stated otherwise:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

1. M1 — add the generator and the cabal flag. Create
   `kiroku-store-migrations/app/WriteExpectedSchema.hs` (full source in Milestone 1). Add the
   `flag expected-schema-tool` and `executable kiroku-write-expected-schema` stanzas to
   `kiroku-store-migrations/kiroku-store-migrations.cabal` (full stanzas in Milestone 1). Build:

```bash
cabal build kiroku-write-expected-schema
```

2. M2 — generate and inspect the snapshot:

```bash
cabal run kiroku-write-expected-schema
ls kiroku-store-migrations/expected-schema
grep -R "$(whoami)" kiroku-store-migrations/expected-schema ; echo "exit=$?"
git add kiroku-store-migrations/app/WriteExpectedSchema.hs kiroku-store-migrations/expected-schema
```

Expected transcript tail:

```text
Wrote expected schema to kiroku-store-migrations/expected-schema
```

and the `grep` prints nothing with `exit=1`. Record the observed `vNN` directory name.

3. M3 — wire the test. Apply the four edits from Milestone 3 to
   `kiroku-store-migrations/test/Main.hs` (import changes, `testCoddSettings` signature +
   `onDiskReps = Left`, `kirokuPgConfig`/`withKirokuPg`/`findExpectedSchemaDir` helpers,
   switch the spike example to `withKirokuPg` and pass a dir to `testCoddSettings`, and the new
   `StrictCheck` example). Run:

```bash
cabal test kiroku-store-migrations-test
```

Expect all examples green, including "matches the checked-in expected schema (StrictCheck)".

4. M4 — negative test (from Milestone 4). Perturb one column objrep, run the test (expect the
   strict example to FAIL), restore, run again (expect pass). Never commit the break.

5. M5 — nix gate. Replace the `kiroku-store-migrations` binding in `nix/haskell-overlay.nix`
   with the `overrideCabal` version from Milestone 5. Stage all new files and build:

```bash
git add kiroku-store-migrations/kiroku-store-migrations.cabal \
        kiroku-store-migrations/test/Main.hs nix/haskell-overlay.nix
nix build .#kiroku-store-migrations
```

6. Commit. Use Conventional Commits with the required trailers. Commit the code, the cabal
   flag, the nix change, and the generated `expected-schema/vNN` tree together so the migrations
   and their expected result stay in lockstep. Suggested message:

```text
feat(migrations): add a portable strict codd expected-schema drift gate

Add a kiroku-write-expected-schema executable that spins up ephemeral
PostgreSQL with a pinned "kiroku" superuser, applies all migrations, and
writes a checked-in codd snapshot under expected-schema/vNN. Wire
runKirokuMigrations to onDiskReps = Left <dir> and add a StrictCheck test
example that fails on any un-snapshotted drift. Gate the generator behind a
cabal flag (expected-schema-tool) and disable it under nix so ephemeral-pg
never enters the nix build closure.

MasterPlan: docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md
ExecPlan: docs/plans/67-add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations.md
Intention: intention_01kwstss55e79aafxgtcw6631j
```


## Validation and Acceptance

The behavioral acceptance criteria, phrased as observable outcomes:

- `cabal test kiroku-store-migrations-test` reports all examples passing, including the strict
  example "matches the checked-in expected schema (StrictCheck)". This proves the checked runner
  `runKirokuMigrations ... StrictCheck` compares the migrated database against the checked-in
  snapshot and finds them equal.
- The negative test proves the gate is meaningful, not vacuous: perturbing one column objrep in
  `kiroku-store-migrations/expected-schema/vNN/schemas/kiroku/tables/<table>/cols/<col>` and
  running `cabal test kiroku-store-migrations-test` makes the strict example FAIL with a
  `different-schemas` diff; restoring the file makes it pass again.
- `grep -R "$(whoami)" kiroku-store-migrations/expected-schema` prints nothing (exit status 1):
  no machine-specific OS username appears anywhere in the snapshot. The snapshot's identity is
  the deterministic literal `kiroku` (`grep -R '"owner": "kiroku"'
  kiroku-store-migrations/expected-schema/vNN/db-settings` confirms it), so the gate passes on
  any machine and in CI regardless of the OS user. This is the portability guarantee.
- `nix build .#kiroku-store-migrations` succeeds: the library and the `kiroku-store-migrate`
  executable build, while the `kiroku-write-expected-schema` generator is gated off
  (`-f-expected-schema-tool` + emptied `executableHaskellDepends`), so `ephemeral-pg` never
  enters the nix build closure.

If the strict test fails immediately after generation, first check the PostgreSQL major version
of the generated directory: codd reads `kiroku-store-migrations/expected-schema/<server-major>/`,
so a test server on a major version different from the one the snapshot was captured on will not
find the `vNN` files. Align the environment (or regenerate on the matching major version).


## Idempotence and Recovery

Regenerating the snapshot is safe to repeat. `cabal run kiroku-write-expected-schema` starts a
fresh throwaway database, applies all migrations, and has codd atomically wipe and rewrite
`kiroku-store-migrations/expected-schema/vNN/` (codd's `writeSchema`/`persistRepsToDisk`
replaces the tree rather than merging). Because the `kiroku` user is pinned, two runs against
the same migration set produce a byte-identical tree, so re-running to recover from a partial or
confused state is always safe. Always inspect `git diff -- kiroku-store-migrations/expected-schema`
after regeneration: a legitimate change produces a focused diff matching the migrations you
touched; a broad or noisy diff means the generating database was not clean, the identity was not
pinned, or the PostgreSQL major version differs.

To recover the snapshot to its committed state at any time:

```bash
git checkout -- kiroku-store-migrations/expected-schema
```

If a regeneration partially writes files and then fails, remove only this plan's versioned tree
and regenerate from a fresh database:

```bash
rm -rf kiroku-store-migrations/expected-schema/vNN
cabal run kiroku-write-expected-schema
```

Never run destructive commands (`rm -rf`, `git clean`, `git checkout -- .`) against the
repository root or unrelated files — scope every destructive command to
`kiroku-store-migrations/expected-schema`. The negative-test perturbation (Milestone 4) must
always be restored from its `/tmp` backup and must never be committed; if you are unsure whether
it lingers, run `git status --short kiroku-store-migrations/expected-schema` and, if the tree is
dirty, `git checkout -- kiroku-store-migrations/expected-schema`.

The code edits are low-risk and reversible. The generator is a new, additive file; the cabal
flag defaults `True` so nothing changes for existing dev-shell workflows; the test edits switch
`onDiskReps` from an empty in-memory `DbRep` to `Left <dir>` and add helpers and one example,
all additive; and the nix change wraps an existing derivation in `overrideCabal`, reverting is a
matter of restoring the three-line binding.


## Interfaces and Dependencies

Libraries and modules used, and why:

- `Kiroku.Store.Migrations` (`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs`):
  `runKirokuMigrationsNoCheck` in the generator and the spike example;
  `runKirokuMigrations ... StrictCheck` for the strict drift gate. Signatures (both return
  `IO ApplyResult` in kiroku):

  ```haskell
  runKirokuMigrations        :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
  runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
  ```

- codd (the `codd` package): `CoddSettings (..)`, `VerifySchemas (StrictCheck)`,
  `ApplyResult (SchemasMatch, SchemasDiffer, SchemasNotVerified)`, and from
  `Codd.AppCommands.WriteSchema` the function `writeSchema :: (MonadUnliftIO m, NotInTxn m) =>
  CoddSettings -> WriteSchemaOpts -> m ()` with `WriteSchemaOpts (WriteToDisk (Maybe FilePath))`
  (verified present in the pinned codd at
  `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/AppCommands/WriteSchema.hs`).
  Also `Codd.Parsing.connStringParser`, and from `Codd.Types`: `ConnectionString`,
  `SchemaSelection (IncludeSchemas)`, `SqlSchema`, `SchemaAlgo`, `TxnIsolationLvl (DbDefault)`,
  `singleTryPolicy`. This plan sets `onDiskReps = Left <dir>` and keeps
  `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]` unchanged.

- ephemeral-pg (`EphemeralPg`, imported qualified as `Pg`): `Pg.Config (..)` (with the
  `user :: Text` field), `Pg.defaultConfig`, `Pg.defaultCacheConfig`, `Pg.startCached`,
  `Pg.stop`, `Pg.connectionString`, and the types `Pg.Database`, `Pg.StartError`. The pinned
  identity is expressed as:

  ```haskell
  kirokuPgConfig :: Pg.Config
  kirokuPgConfig = Pg.defaultConfig { Pg.user = "kiroku" }
  ```

  and consumed via `Pg.startCached kirokuPgConfig Pg.defaultCacheConfig`. `withCachedConfig` is
  **not** exported, so `startCached` + `Control.Exception.finally` (for teardown with `Pg.stop`)
  is the required pattern.

Function and artifact signatures that must exist at the end of each milestone:

- End of M1: `kiroku-store-migrations/app/WriteExpectedSchema.hs` defines
  `main :: IO ()`, `kirokuPgConfig :: Pg.Config`, and
  `coddSettings :: Text -> FilePath -> CoddSettings`; the cabal file has
  `flag expected-schema-tool` (default `True`, `manual: False`) and
  `executable kiroku-write-expected-schema` gated on it. `cabal build
  kiroku-write-expected-schema` succeeds.
- End of M2: the artifact `kiroku-store-migrations/expected-schema/vNN/` exists, is staged in
  git, and contains a `schemas/kiroku/` subtree plus `roles/kiroku` and a `db-settings` with
  `owner: kiroku`; no OS-username appears anywhere.
- End of M3: `kiroku-store-migrations/test/Main.hs` has
  `testCoddSettings :: Text -> FilePath -> CoddSettings` with `onDiskReps = Left`,
  `kirokuPgConfig :: Pg.Config`,
  `withKirokuPg :: (Pg.Database -> IO a) -> IO (Either Pg.StartError a)`,
  `findExpectedSchemaDir :: IO FilePath`, and a new `StrictCheck` example; the suite passes.
- End of M5: `nix/haskell-overlay.nix`'s `kiroku-store-migrations` binding is wrapped in
  `overrideCabal (_: { configureFlags = [ "-f-expected-schema-tool" ];
  executableHaskellDepends = [ ]; })`; `nix build .#kiroku-store-migrations` succeeds.

Shared-file coordination. `kiroku-store-migrations/test/Main.hs` and
`kiroku-store-migrations/kiroku-store-migrations.cabal` are edited by both EP-1 and this plan.
In the test, EP-2 owns `testCoddSettings`, the `StrictCheck` example, and the
`kirokuPgConfig`/`withKirokuPg`/`findExpectedSchemaDir` helpers; it must not edit
`migrationFileNameSpec` or EP-1's `scaffolderSpec`. In the cabal file EP-2 owns the
`flag expected-schema-tool` and the `executable kiroku-write-expected-schema` stanza; EP-1 owns
the library `exposed-modules` addition and its `directory`/`filepath` deps. The edits are in
disjoint functions/stanzas, so whichever plan lands second performs a mechanical rebase, not a
semantic merge. EP-2 does not touch `kiroku-store-migrations/app/Main.hs` (EP-1's).
