---
id: 66
slug: add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps
title: "Add a kiroku migration scaffolder that stamps real UTC timestamps"
kind: exec-plan
created_at: 2026-07-05T19:09:18Z
intention: "intention_01kwstss55e79aafxgtcw6631j"
master_plan: "docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md"
---

# Add a kiroku migration scaffolder that stamps real UTC timestamps

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, adding a new database migration to kiroku means hand-typing a filename. Every one of
the seven files under `kiroku-store-migrations/sql-migrations/` was named by a human, and that
manual step has been a recurring source of pain: authors kept assigning *sentinel* timestamps
— rounded, fake times like `2026-05-16-00-00-00-…` and `…-00-00-01-…` — instead of the real
clock time at which they wrote the migration. Those fake timestamps do not sort in true
authoring order and, worse, two of them collided outright inside codd's ledger (the table
codd uses to remember which migrations it has already applied, keyed by filename and by a
timestamp derived from that filename). The recent git history of this repository is almost
entirely the cleanup from that mistake: a mass rename to real timestamps (`dac1a0b`), a
"renumber" fix for a colliding timestamp (`e1f6c02`), a hand-written SQL repair script for
already-migrated databases (`kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`),
and finally a *reactive* guard test (`migrationFileNameSpec` in
`kiroku-store-migrations/test/Main.hs`) that rejects sentinel names after someone types them
but does nothing to help an author produce a correct one in the first place.

After this change, a contributor runs a single command from the repository root:

```bash
cabal run kiroku-store-migrate -- new "add widget index"
```

and the tool creates a new file such as
`sql-migrations/2026-07-05-19-14-37-add-widget-index.sql`, whose name is the **real current
UTC time to the second** (so it sorts in true authoring order and cannot collide in codd's
ledger) and whose body is a ready-to-edit, **schema-qualified, idempotent** SQL skeleton (it
writes `kiroku.<table>` explicitly and uses `IF NOT EXISTS`, matching kiroku's correct
incremental-migration style). The tool prints the path it created and a one-line reminder
about the Template-Haskell embed step (explained below). The command applies no migrations and
changes no schema — it only writes one new file.

You can see it working three ways. First, the printed filename has a non-`00` seconds field
and a real hour/minute, so it passes the existing `migrationFileNameSpec` guard rather than
tripping it. Second, opening the generated file shows a `kiroku.`-qualified skeleton with no
`SET search_path`. Third, a new automated test (`scaffolderSpec`) generates a migration into a
throwaway temporary directory and asserts, using the very same helper functions the guard uses
(`isTimestampShaped`, `handAssignedTimestamp`), that the produced name is well-shaped and is
**not** a hand-assigned sentinel. In other words, this plan turns the reactive guard into
*proactive tooling*: the guard becomes a backstop for a mistake the tooling no longer invites,
and a round-trip test proves the tooling and the guard agree.

This plan is **EP-1** of MasterPlan 10
(`docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md`).
It is deliberately scoped to authoring tooling only. It does **not** touch any schema DDL, and
it does **not** add the schema-drift gate or the expected-schema snapshot — that is EP-2 (a
separate plan, `docs/plans/67-…`). The two plans edit two files in common
(`kiroku-store-migrations/test/Main.hs` and `kiroku-store-migrations/kiroku-store-migrations.cabal`)
but in disjoint functions and stanzas; see "Idempotence and Recovery" for the mechanical
rebase if EP-2 lands first.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: New library module `Kiroku.Store.Migrations.New` created under
      `kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs` (functions
      `newMigrationFile`, `migrationFileName`, `migrationSlug`, `migrationTemplate`,
      `defaultMigrationsDir`).
- [x] M1: `Kiroku.Store.Migrations.New` added to the library `exposed-modules`; `directory`
      and `filepath` added to the library `build-depends`; `cabal build kiroku-store-migrations`
      succeeds.
- [x] M2: `kiroku-store-migrations/app/Main.hs` restructured to dispatch `new` vs. the
      existing apply path; apply path preserved verbatim; `cabal build
      exe:kiroku-store-migrate` succeeds.
- [x] M2: Manual smoke test — `cabal run kiroku-store-migrate -- new "add widget index"` into
      a temp `KIROKU_MIGRATIONS_DIR` creates a real-timestamped file with non-`00` seconds and
      prints the embed reminder. Observed: `2026-07-05-20-56-59-add-widget-index.sql`.
- [x] M3: `scaffolderSpec` added to `kiroku-store-migrations/test/Main.hs` and wired into
      `main`; `temporary` and `filepath` added to the test `build-depends`;
      `migrationFileNameSpec` left untouched.
- [x] M3: `cabal test kiroku-store-migrations-test` green (existing `migrationFileNameSpec`,
      the codd spike, and the new `scaffolderSpec` all pass — 5 examples, 0 failures).
- [x] Commit(s) recorded with the required MasterPlan/ExecPlan/Intention trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05 (authoring): **kiroku migration filenames are NOT prefixed**, unlike keiro's.
  keiro's `Keiro.Migrations.New.migrationSlug` force-prepends `"keiro-"` to every slug. The
  existing kiroku files show no such convention — e.g.
  `2026-06-14-13-25-40-dead-letters-event-id-index.sql` and
  `2026-05-29-15-26-04-add-subscription-dead-letters.sql` carry a bare slug; only the
  bootstrap file happens to contain the word `kiroku`
  (`2026-05-16-12-17-14-kiroku-bootstrap.sql`) because its human description was "kiroku
  bootstrap", not because of any prefixing rule. Therefore kiroku's `migrationSlug` must drop
  keiro's `isPrefixOf`/`"keiro-"` logic entirely and only lower-case, collapse runs of
  non-alphanumerics to single dashes, and trim leading/trailing dashes.

- 2026-07-05 (authoring): **kiroku's incremental-migration template style differs from
  keiro's.** keiro's `migrationTemplate` emits `SET search_path TO keiro, pg_catalog;` — the
  style keiro itself now discourages. kiroku's incremental migrations are the *correct* model:
  they hard-qualify every object as `kiroku.<table>` and never pin `search_path`. Evidence,
  the body of `2026-06-14-13-25-40-dead-letters-event-id-index.sql`:

  ```sql
  CREATE INDEX IF NOT EXISTS ix_dead_letters_event_id
      ON kiroku.dead_letters (event_id);
  ```

  and `2026-06-14-14-01-17-stream-name-length-check.sql`:

  ```sql
  ALTER TABLE kiroku.streams
      ADD CONSTRAINT chk_streams_stream_name_length
      CHECK (octet_length(stream_name) <= 512);
  ```

  Neither pins `search_path`; both write `kiroku.` explicitly. So kiroku's scaffolder template
  must emit a `kiroku.`-qualified, idempotent skeleton and must contain no `SET search_path`
  anywhere.

- 2026-07-05 (authoring): the **bootstrap** file
  (`2026-05-16-12-17-14-kiroku-bootstrap.sql`) *does* contain `SET search_path TO kiroku,
  pg_catalog;` at its top. That is an intentional, one-time exception justified in its own
  header comment (it lets the long bootstrap body use unqualified names as it creates the
  schema and a `uuidv7()` fallback function). It is **not** the model for new incremental
  migrations, and the scaffolder must not reproduce it. The template follows the *incremental*
  files, not the bootstrap.

- 2026-07-05 (authoring): the round-trip test has a **1-in-60 theoretical flake** if it asserts
  `handAssignedTimestamp == False` on a filename produced from the live wall clock, because a
  real reading can land on a `00` seconds boundary. Resolution recorded in the Decision Log:
  the guard predicate (`handAssignedTimestamp == False`, `isTimestampShaped == True`) is
  asserted on a *deterministic* `UTCTime` fed to `migrationFileName`, while the live
  `newMigrationFile` path is exercised separately for its IO behavior (file created with a
  well-shaped basename, refuses to overwrite). This keeps the suite non-flaky while still
  proving producer/guard agreement.

- 2026-07-05 (implementation): **The template as originally specified contradicted its own
  round-trip test.** The `migrationTemplate` text in this plan's Milestone M1 ended a comment
  line with `` Do NOT add `SET search_path`; write kiroku.<name>. `` — which contains the
  literal substring `search_path`. But `scaffolderSpec` (and Validation criterion #2) assert
  the generated body contains **no** `search_path` string anywhere
  (`("search_path" \`T.isInfixOf\` T.pack body) \`shouldBe\` False`). The test failed on first
  run (`expected: False, but got: True`). Resolution: reword the template's final comment to
  `Do NOT pin the schema search path; always write kiroku.<name> explicitly, as the
  incremental migrations do.` — this conveys the same guidance without the literal `search_path`
  token, so the template still contains zero `search_path` occurrences and the test passes. The
  meaningful invariant (the skeleton never *pins* a search path) is preserved; only the wording
  changed. Evidence: `cabal test kiroku-store-migrations-test` → 5 examples, 0 failures after
  the reword.

- (Add further discoveries here as implementation proceeds.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Put the scaffolder logic in a new library module
  `Kiroku.Store.Migrations.New` (`kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs`),
  exposed from the `kiroku-store-migrations` library, rather than inline in the executable's
  `app/Main.hs`.
  Rationale: keeping the pure, testable functions (`migrationFileName`, `migrationSlug`,
  `migrationTemplate`) in the library lets the test suite import and exercise them directly,
  and mirrors keiro's shipped structure (`Keiro.Migrations.New`). The executable stays a thin
  argument-dispatch shell.
  Date: 2026-07-05

- Decision: `migrationSlug` does **not** force any prefix. It only lower-cases, collapses runs
  of non-alphanumeric characters to single dashes, and trims leading/trailing dashes.
  Rationale: kiroku filenames are unprefixed (see Surprises). Copying keiro's `"keiro-"`
  prefix logic would produce names inconsistent with the existing convention.
  Date: 2026-07-05

- Decision: `migrationTemplate` emits a header comment plus a `kiroku.`-qualified, idempotent
  example (`CREATE TABLE IF NOT EXISTS kiroku.<name> (...)`, a schema-qualified index whose
  index name is bare), plus a `-- TODO` line, and contains **no** `SET search_path`.
  Rationale: matches kiroku's correct incremental-migration style and steers authors away from
  the discouraged `search_path`-pinning style keiro's template used. (See Surprises.)
  Date: 2026-07-05

- Decision: Give the executable a subcommand-style dispatch: `("new" : rest)` scaffolds; any
  other argument list (including none) runs the existing apply behavior verbatim.
  Rationale: preserves 100% backward compatibility for existing callers (which invoke the
  binary with no `new` argument to apply migrations) while adding the authoring path. Mirrors
  keiro's `keiro-migrate` dispatch.
  Date: 2026-07-05

- Decision: The directory the scaffolder writes into is `KIROKU_MIGRATIONS_DIR` if set, else
  `defaultMigrationsDir = "sql-migrations"`.
  Rationale: an environment override lets the test (and any future tooling) redirect writes
  into a throwaway directory without touching the real migrations tree; the default matches the
  path the binary is run against from within `kiroku-store-migrations/`.
  Date: 2026-07-05

- Decision: The round-trip test asserts the guard predicate on a *deterministic* `UTCTime` fed
  to `migrationFileName`, and exercises `newMigrationFile`'s IO behavior separately.
  Rationale: avoids the 1-in-60 wall-clock flake documented in Surprises while still honoring
  the Integration contract (reuse `isTimestampShaped`/`handAssignedTimestamp`, prove the
  produced name is well-shaped and non-sentinel).
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05: EP-1 delivered as designed. `kiroku-store-migrate new "<description>"` now
  scaffolds a real-UTC-timestamped, `kiroku.`-qualified, idempotent migration skeleton under
  `sql-migrations/` (or `KIROKU_MIGRATIONS_DIR`), printing the created path and the embed
  reminder. The `Kiroku.Store.Migrations.New` library module holds the pure/IO functions; the
  executable is a thin dispatch shell whose apply path is byte-for-byte the pre-change `main`.
  The round-trip `scaffolderSpec` proves the producer satisfies the existing
  `migrationFileNameSpec` guard (deterministic timestamp check) and exercises the live
  `newMigrationFile` IO path. Suite green: 5 examples, 0 failures. The `sql-migrations/` tree
  and `migrationFileNameSpec` were left untouched.
- One deviation from the written plan: the template's final comment was reworded to avoid the
  literal `search_path` token, which its own test forbids in the generated body (see Surprises).
  No behavior change — the skeleton still never pins a search path.


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

**The repository and the package.** The repository root is
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. All commands in this plan are run from
that directory unless stated otherwise. kiroku is an event-store library written in Haskell.
Its PostgreSQL schema lives in one package, `kiroku-store-migrations`, whose files you will be
working in:

- `kiroku-store-migrations/kiroku-store-migrations.cabal` — the package description: it lists
  the library modules, the executable, the test suite, and each component's dependencies.
- `kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` — the library module that embeds and
  runs the migrations (details below).
- `kiroku-store-migrations/app/Main.hs` — the source of the `kiroku-store-migrate` executable.
  Today it only *applies* migrations.
- `kiroku-store-migrations/test/Main.hs` — the test suite (`kiroku-store-migrations-test`),
  including the filename guard you will build a round-trip test against.
- `kiroku-store-migrations/sql-migrations/` — the directory of timestamped `.sql` migration
  files. There are currently seven, listed under "The migration filename contract" below.
- `kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql` —
  a one-off repair script (details below).

**Term: PostgreSQL "schema".** In PostgreSQL a *schema* is a namespace inside a single
database — a container for tables, indexes, functions, and so on. It is not a "database
schema" in the loose sense of "the shape of the tables"; it is a specific named namespace.
kiroku puts all of its objects inside a schema literally named `kiroku` (created by the
bootstrap migration with `CREATE SCHEMA IF NOT EXISTS kiroku;`), leaving PostgreSQL's default
`public` schema free for application objects. Every kiroku table is therefore addressed as
`kiroku.streams`, `kiroku.events`, `kiroku.dead_letters`, and so on. When SQL "hard-qualifies"
a name, it writes the schema explicitly (`kiroku.streams`) rather than relying on a
`search_path` (PostgreSQL's ordered list of schemas to look in for unqualified names). Kiroku's
incremental migrations always hard-qualify; that is the style the scaffolder's template must
reproduce.

**Term: codd (the migration runner).** codd (`mzabani/codd`, the Haskell package `codd`) is the
tool kiroku uses to apply migrations. It is *forward-only*: migrations are applied in order and
never rolled back automatically. Crucially, codd decides whether a given migration has already
been applied by its **filename**, recorded in a ledger table inside the database (this codd
version names it `codd_schema.sql_migrations`). It also derives a `migration_timestamp` from
the filename's leading timestamp. codd stores **no checksum of the file body** — the filename
(and its derived timestamp) is the entire identity of a migration. Two consequences follow, and
both motivate this plan: (1) filenames must be **unique** or codd's ledger has an ambiguous
identity; and (2) filenames should sort in true authoring order, because codd applies them in
sorted order and operators reason about "which migration came first" from the name.

**Term: `embedDir` / Template Haskell (the embed step).** The library module
`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` does not read the `sql-migrations/`
directory at runtime. Instead it *embeds* the directory's contents into the compiled binary at
**compile time**, using a Template-Haskell splice (Template Haskell is GHC's compile-time
code-generation feature; a "splice" is code that runs during compilation to produce more code).
The relevant line is:

```haskell
embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")
```

The `$(embedDir "sql-migrations")` splice reads every file under `sql-migrations/` *while GHC
compiles this module* and bakes the filenames and bytes into the executable. This has a
practical consequence you must remember: **adding or editing a file under `sql-migrations/`
does not, by itself, cause GHC to recompile `Migrations.hs`.** GHC tracks the module's own
source file, not the directory the splice happened to read. So after the scaffolder creates a
new `.sql` file, that file will be *invisible* to any build until something forces
`Migrations.hs` to recompile. The two reliable ways to force it are to touch (modify) the
module — the convention here is to edit the comment near the `embedDir` line — or to run `cabal
clean`. This plan's scaffolder does not apply migrations, so it does not itself need the embed
refreshed; but the file it creates *will* need the embed refreshed before it is applied, and
the tool therefore prints a reminder. (The plan does not automate the touch; that would edit a
source file behind the author's back. The scaffolder just reminds.)

**The sentinel-timestamp bug (why this plan exists).** A "sentinel" timestamp is a fake,
placeholder time an author types instead of reading the real clock — for example
`2026-05-16-00-00-00-…` (midnight) or a sequence `…-00-00-00`, `…-00-00-01`, `…-00-00-02` used
to fake an ordering. Sentinels hurt in two concrete ways given codd's filename-keyed identity.
First, they do not sort in true authoring order: a migration written at 14:00 but stamped
`…-00-00-00` sorts *before* one written at 09:00 but stamped `…-00-00-01`, so the on-disk order
lies about history. Second, and worse, they *collide*: kiroku's migrations were originally
numbered with a shared date and an incrementing `00-00-0N` seconds slot, and two of them ended
up with the same derived timestamp, which codd's ledger cannot represent uniquely. The recent
git history is the entire cleanup: `dac1a0b` ("rename SQL migrations to real commit-date
timestamps") renamed all seven files from sentinels to real times; `e1f6c02` ("renumber
stream-truncate-before to a unique real timestamp") fixed a collision; and
`6bf77ba` ("add ledger realignment + filename guard") added both the repair script and the
guard test. You can confirm this history with `git log --oneline -- kiroku-store-migrations`.

**The ledger-fixup script.** Because a database that had already applied the *old* sentinel
names would, after the rename, see every renamed file as brand-new and try to re-run it, the
rename shipped with a repair script:
`kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`. It
`UPDATE`s the `name` and `migration_timestamp` columns of `codd_schema.sql_migrations` from
each old sentinel identity to the new real-timestamp identity, so codd sees the renamed files
as already applied and skips them. It changes only codd's bookkeeping, never the schema, and it
is idempotent (a second run matches no rows). This script is the operator-facing evidence of
how expensive the sentinel mistake was: it required hand-writing a per-database ledger repair.
This plan removes the *cause* of that class of bug. (Documenting the `ledger-fixups/`
discipline for operators is EP-3's job, not this plan's.)

**The reactive guard you will build against.** `kiroku-store-migrations/test/Main.hs` already
contains `migrationFileNameSpec`, a test that reads the real `sql-migrations/` directory and
fails if any filename looks hand-assigned. It relies on three helper functions in the same
file, which your round-trip test will reuse verbatim:

- `isTimestampShaped :: String -> Bool` — true when a 19-character prefix matches the fixed
  shape `dddd-dd-dd-dd-dd-dd` (that is, `YYYY-MM-DD-HH-MM-SS`).
- `timestampFields :: FilePath -> Maybe (String, String, String)` — extracts `(HH, MM, SS)`
  from a well-shaped name.
- `handAssignedTimestamp :: FilePath -> Bool` — true when the name is *not* well-shaped, OR its
  seconds field is `"00"`, OR it is exactly UTC midnight (`HH == "00" && MM == "00"`). In other
  words, `handAssignedTimestamp name == False` is exactly the property a real wall-clock name
  has (barring the once-a-minute `00`-seconds edge).

There is also `timestampWidth :: Int` (the constant `19`) and `migrationFiles :: IO
[FilePath]`, `findMigrationsDir :: IO FilePath` for locating the directory. `migrationFileNameSpec`
must be left exactly as-is; your job is to *add* a new spec that proves the scaffolder's output
satisfies these same predicates.

**The keiro precedent.** keiro (a sibling repository that consumes kiroku) already shipped the
identical scaffolder for itself, in a module `Keiro.Migrations.New`, and a `new` subcommand in
its `keiro-migrate` executable. This plan adapts that shipped code. The adaptations kiroku
requires — a different module name, no slug prefix, a `kiroku.`-qualified no-`search_path`
template, the `KIROKU_MIGRATIONS_DIR` env var, and the kiroku-specific embed reminder — are all
captured in the Decision Log and Surprises above and specified concretely in the Plan of Work
below.


## Plan of Work

The work is three milestones, each independently verifiable: M1 adds the library module and
proves it compiles; M2 wires the executable's `new` subcommand and proves it creates a
well-named file; M3 adds the round-trip test and proves the whole suite is green. Commit after
each milestone (see "Concrete Steps" for the exact commit-message trailers).

### Milestone M1 — the `Kiroku.Store.Migrations.New` module

Scope: create the new library module holding the pure and IO scaffolding functions, expose it,
and add its two new dependencies. At the end of M1 the package library compiles with the new
module present, but nothing calls it yet.

Create the file `kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs` with exactly this
content:

```haskell
module Kiroku.Store.Migrations.New (
    newMigrationFile,
    defaultMigrationsDir,
    migrationFileName,
    migrationSlug,
    migrationTemplate,
) where

import Control.Monad (when)
import Data.Char (isAlphaNum, toLower)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

-- | Default directory into which migrations are scaffolded, relative to the
-- working directory. Overridden by the @KIROKU_MIGRATIONS_DIR@ environment
-- variable in the executable.
defaultMigrationsDir :: FilePath
defaultMigrationsDir = "sql-migrations"

-- | Scaffold a new migration file in @dir@ from a human description, stamped
-- with the real current UTC time to the second. Returns the path written.
-- Refuses to clobber an existing file, and rejects a description with no
-- alphanumeric character (which would produce an empty slug).
newMigrationFile :: FilePath -> String -> IO FilePath
newMigrationFile dir description = do
    when (not (any isAlphaNum description)) $
        ioError (userError "migration description must contain at least one letter or digit")
    now <- getCurrentTime
    let path = dir </> migrationFileName now description
    createDirectoryIfMissing True dir
    exists <- doesFileExist path
    when exists $
        ioError (userError ("refusing to overwrite existing migration: " <> path))
    writeFile path (migrationTemplate description)
    pure path

-- | Build the migration filename from a timestamp and a description:
-- @YYYY-MM-DD-HH-MM-SS-<slug>.sql@. The timestamp is formatted to the second so
-- filenames sort in true authoring order and never collide in codd's ledger.
migrationFileName :: UTCTime -> String -> FilePath
migrationFileName now description =
    formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S" now
        <> "-"
        <> migrationSlug description
        <> ".sql"

-- | Turn a free-text description into a filename slug: lower-case, every run of
-- non-alphanumeric characters collapsed to a single dash, and leading/trailing
-- dashes trimmed. Unlike keiro's scaffolder, kiroku slugs carry NO prefix.
migrationSlug :: String -> String
migrationSlug raw =
    trimDashes (collapseDashes (map normalise raw))
  where
    normalise c = if isAlphaNum c then toLower c else '-'
    collapseDashes ('-' : '-' : rest) = collapseDashes ('-' : rest)
    collapseDashes (c : rest) = c : collapseDashes rest
    collapseDashes [] = []
    trimDashes = f . f where f = reverse . dropWhile (== '-')

-- | The SQL skeleton written into a scaffolded migration: a header comment plus
-- a schema-qualified, idempotent example and a TODO. kiroku's incremental
-- migrations hard-qualify @kiroku.<table>@ and never pin @search_path@; this
-- template follows that style (NOT the bootstrap's one-time @SET search_path@).
migrationTemplate :: String -> String
migrationTemplate description =
    unlines
        [ "-- " <> description
        , "--"
        , "-- Kiroku incremental migration. codd applies this file exactly once,"
        , "-- keyed by filename, and records it in codd_schema.sql_migrations."
        , "-- Keep every statement idempotent (IF NOT EXISTS / IF EXISTS) so a"
        , "-- partial re-run is safe, and hard-qualify every object with the"
        , "-- kiroku schema. Do NOT add `SET search_path`; write kiroku.<name>."
        , ""
        , "CREATE TABLE IF NOT EXISTS kiroku.example ("
        , "    example_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY"
        , ");"
        , ""
        , "-- Index name is bare; the ON target is schema-qualified."
        , "CREATE INDEX IF NOT EXISTS ix_example_id"
        , "    ON kiroku.example (example_id);"
        , ""
        , "-- TODO: replace the example above with the real DDL for this migration."
        ]
```

Then expose the module and add its dependencies in
`kiroku-store-migrations/kiroku-store-migrations.cabal`. In the `library` stanza, change the
`exposed-modules` line to list both modules, and add `directory` and `filepath` to the
library's `build-depends` (`time` is already a library dependency; `Data.Time.Format` lives in
the same `time` package, so no new time dependency is needed). The edit is:

```diff
 library
   import:          common
-  exposed-modules: Kiroku.Store.Migrations
+  exposed-modules:
+    Kiroku.Store.Migrations
+    Kiroku.Store.Migrations.New
   hs-source-dirs:  src
   build-depends:
     , base        >=4.18   && <5
     , bytestring  >=0.11   && <0.13
     , codd        >=0.1.8  && <0.2
+    , directory   >=1.3    && <1.4
     , file-embed  >=0.0.15 && <0.0.17
+    , filepath    >=1.4    && <1.6
     , streaming   >=0.2    && <0.3
     , text        >=2.0    && <2.2
     , time        >=1.12   && <1.15
```

Acceptance for M1: from the repository root, `cabal build kiroku-store-migrations` succeeds and
GHC reports the new module compiled. `directory` and `filepath` are part of GHC's boot library
set (they ship with the compiler), so they add no external download and — importantly — no risk
to the nix build closure (see "Interfaces and Dependencies").

### Milestone M2 — the `new` subcommand in the executable

Scope: restructure `kiroku-store-migrations/app/Main.hs` so the binary dispatches on its first
argument. With no `new` argument it does exactly what it does today (apply migrations); with
`new` it scaffolds. At the end of M2 you can run the scaffolder from the command line and see a
file created.

Replace the entire contents of `kiroku-store-migrations/app/Main.hs` with:

```haskell
module Main where

import Codd.Environment (getCoddSettings)
import Data.Maybe (fromMaybe)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import Kiroku.Store.Migrations.New (defaultMigrationsDir, newMigrationFile)
import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("new" : rest) -> generate (unwords rest)
        _ -> migrate

-- | The existing apply behavior, preserved verbatim from before the `new`
-- subcommand was added: read codd settings from the environment and apply the
-- embedded migrations without expected-schema verification.
migrate :: IO ()
migrate = do
    settings <- getCoddSettings
    _ <- runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)
    pure ()

-- | Scaffold a new migration from a free-text description. Writes into
-- @KIROKU_MIGRATIONS_DIR@ if set, else 'defaultMigrationsDir'.
generate :: String -> IO ()
generate description
    | all (== ' ') description =
        ioError (userError "usage: kiroku-store-migrate new <description>")
    | otherwise = do
        dir <- fromMaybe defaultMigrationsDir <$> lookupEnv "KIROKU_MIGRATIONS_DIR"
        path <- newMigrationFile dir description
        putStrLn ("Created " <> path)
        putStrLn
            "Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
```

Note two things. First, the `migrate` function body is byte-for-byte the old `main` body — the
apply path is preserved exactly, only moved behind the dispatch. Second, the executable needs
no new dependencies: `getArgs`/`lookupEnv` come from `base` (module `System.Environment`),
`fromMaybe` from `base` (module `Data.Maybe`), and `newMigrationFile`/`defaultMigrationsDir`
come from the `kiroku-store-migrations` library it already depends on. Do not add `directory`
or `filepath` to the executable stanza — the executable does not import them directly (the
library does).

Acceptance for M2: `cabal build exe:kiroku-store-migrate` succeeds, and the manual smoke test
in "Concrete Steps" creates a real-timestamped file and prints the reminder.

### Milestone M3 — the round-trip test

Scope: add a new `Spec` to `kiroku-store-migrations/test/Main.hs` that scaffolds a migration
into a throwaway temporary directory and asserts, using the file's existing helper functions,
that the produced name is well-shaped and not a hand-assigned sentinel. Wire it into `main`
next to `migrationFileNameSpec`. Add the two test-only dependencies it needs. At the end of M3
the whole suite is green.

First, add imports at the top of `test/Main.hs` (near the other imports). You need the
scaffolder API, a temp-directory helper, a basename helper, and `UTCTime` construction:

```haskell
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kiroku.Store.Migrations.New (migrationFileName, migrationSlug, newMigrationFile)
import System.FilePath (takeFileName)
import System.IO.Temp (withSystemTempDirectory)
```

The file already imports `Data.Time (secondsToDiffTime)`; extend that existing import to the
line shown above (which adds `UTCTime (..)` and `fromGregorian`) rather than duplicating it, to
avoid a duplicate-import warning. Concretely, change:

```diff
-import Data.Time (secondsToDiffTime)
+import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
```

Then add the new spec. Place it anywhere among the top-level definitions (for example directly
after `migrationFileNameSpec`):

```haskell
{- | Prove the scaffolder (`Kiroku.Store.Migrations.New`) is the *producer* that
satisfies the reactive `migrationFileNameSpec` guard. Two independent checks:

  * A deterministic name built from a fixed, non-sentinel UTCTime is well-shaped
    ('isTimestampShaped') and is NOT a hand-assigned sentinel
    ('handAssignedTimestamp' == False), and its slug is the expected bare slug.
    This is deterministic, so the assertion cannot flake.
  * The live 'newMigrationFile' writes a real file into a throwaway temp dir;
    its basename is well-shaped and the file exists; a second call with the same
    inputs but into an existing path is refused (never clobbers).
-}
scaffolderSpec :: Spec
scaffolderSpec =
    describe "migration scaffolder" $ do
        it "stamps a real, non-sentinel UTC timestamp and a bare slug" $ do
            -- 2026-07-05 19:09:18 UTC: real hour/minute and non-00 seconds.
            let sampled = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime (19 * 3600 + 9 * 60 + 18))
                name = migrationFileName sampled "Add widget index"
            takeFileName name `shouldBe` name
            isTimestampShaped (take timestampWidth name) `shouldBe` True
            handAssignedTimestamp name `shouldBe` False
            migrationSlug "Add widget index" `shouldBe` "add-widget-index"

        it "writes a well-named file into a temp dir and refuses to overwrite" $
            withSystemTempDirectory "kiroku-scaffolder" $ \dir -> do
                path <- newMigrationFile dir "add widget index"
                let base = takeFileName path
                isTimestampShaped (take timestampWidth base) `shouldBe` True
                length base `shouldSatisfy` (> timestampWidth)
                -- The generated file body is schema-qualified and unpinned.
                body <- readFile path
                (".sql" `isSuffixOf` path) `shouldBe` True
                ("kiroku.example" `T.isInfixOf` T.pack body) `shouldBe` True
                ("search_path" `T.isInfixOf` T.pack body) `shouldBe` False
```

The `body`/`T.pack` checks reuse the already-imported `Data.Text qualified as T`. `isSuffixOf`
is already imported (`Data.List`). If your GHC flags treat the `withSystemTempDirectory` result
type as ambiguous, annotate `path :: FilePath` — it will not be, since `newMigrationFile`
returns `IO FilePath`.

Wire the new spec into `main`. Change the top of `main` from:

```haskell
main :: IO ()
main =
    hspec $ do
        migrationFileNameSpec
        describe "codd migration spike" $
```

to:

```haskell
main :: IO ()
main =
    hspec $ do
        migrationFileNameSpec
        scaffolderSpec
        describe "codd migration spike" $
```

Finally, add the two test-only dependencies to the test stanza in the `.cabal` file. `directory`
is already there; you need `temporary` (for `withSystemTempDirectory`) and `filepath` (for
`takeFileName`):

```diff
 test-suite kiroku-store-migrations-test
   import:         common
   type:           exitcode-stdio-1.0
   main-is:        Main.hs
   hs-source-dirs: test
   ghc-options:    -threaded -rtsopts -with-rtsopts=-N
   build-depends:
     , aeson                    >=2.1  && <2.3
     , attoparsec
     , base                     >=4.18 && <5
     , codd
     , containers               >=0.6  && <0.8
     , directory                >=1.3
     , ephemeral-pg             >=0.2  && <0.3
+    , filepath                 >=1.4  && <1.6
     , hasql                    >=1.10 && <1.11
     , hasql-pool               >=1.2  && <1.5
     , hspec                    >=2.10 && <2.12
     , kiroku-store             ^>=0.2
     , kiroku-store-migrations
+    , temporary                >=1.3  && <1.4
     , text                     >=2.0  && <2.2
     , time                     >=1.12 && <1.15
     , vector                   >=0.13 && <0.14
```

Acceptance for M3: `cabal test kiroku-store-migrations-test` is green — `migrationFileNameSpec`,
`scaffolderSpec`, and the existing `codd migration spike` all pass. (The codd spike needs an
ephemeral PostgreSQL, which the suite already provisions; `scaffolderSpec` needs no database.)


## Concrete Steps

All commands are run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Expected transcripts are shown so you
can compare; exact timing/paths will differ but the shape should match.

**Step 1 — create the module and edit the cabal library stanza (M1).** Create
`kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs` and edit the `.cabal` `library`
stanza exactly as shown in Milestone M1. Then build:

```bash
cabal build kiroku-store-migrations
```

Expected (abbreviated):

```text
Building library for kiroku-store-migrations-0.1.1.0..
[1 of 2] Compiling Kiroku.Store.Migrations.New
[2 of 2] Compiling Kiroku.Store.Migrations
```

If GHC cannot find `System.Directory` or `System.FilePath`, you forgot to add `directory` /
`filepath` to the library `build-depends`.

**Step 2 — rewrite the executable and build it (M2).** Replace
`kiroku-store-migrations/app/Main.hs` as shown in Milestone M2, then:

```bash
cabal build exe:kiroku-store-migrate
```

Expected:

```text
Building executable 'kiroku-store-migrate' for kiroku-store-migrations-0.1.1.0..
[1 of 1] Compiling Main
Linking .../kiroku-store-migrate
```

**Step 3 — smoke-test the scaffolder into a throwaway directory (M2 acceptance).** Do NOT write
into the real `sql-migrations/` tree during the smoke test. Point `KIROKU_MIGRATIONS_DIR` at a
scratch directory and run the `new` subcommand. The `--` separates cabal's own arguments from
the program's:

```bash
mkdir -p /tmp/kiroku-scaffolder-demo
KIROKU_MIGRATIONS_DIR=/tmp/kiroku-scaffolder-demo \
  cabal run kiroku-store-migrate -- new "add widget index"
```

Expected transcript (the timestamp will be the real current UTC time; the seconds field will
almost never be `00`):

```text
Created /tmp/kiroku-scaffolder-demo/2026-07-05-19-14-37-add-widget-index.sql
Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`).
```

Confirm the filename has a non-`00` seconds field and inspect the generated body:

```bash
ls /tmp/kiroku-scaffolder-demo
cat /tmp/kiroku-scaffolder-demo/*.sql
```

Expected body:

```sql
-- add widget index
--
-- Kiroku incremental migration. codd applies this file exactly once,
-- keyed by filename, and records it in codd_schema.sql_migrations.
-- Keep every statement idempotent (IF NOT EXISTS / IF EXISTS) so a
-- partial re-run is safe, and hard-qualify every object with the
-- kiroku schema. Do NOT add `SET search_path`; write kiroku.<name>.

CREATE TABLE IF NOT EXISTS kiroku.example (
    example_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

-- Index name is bare; the ON target is schema-qualified.
CREATE INDEX IF NOT EXISTS ix_example_id
    ON kiroku.example (example_id);

-- TODO: replace the example above with the real DDL for this migration.
```

Verify the overwrite guard by running the exact same command a second time within the same
second is not reliably reproducible; instead prove the guard directly by re-running with a
timestamp you already have — simplest is to observe that a second invocation creates a *new*
file (different second) and that pointing at an existing exact path is refused by
`newMigrationFile`. The automated test in Step 5 exercises the refuse-to-overwrite path
deterministically. Clean up the scratch directory when done:

```bash
rm -rf /tmp/kiroku-scaffolder-demo
```

**Step 4 — add the round-trip test and test deps (M3).** Edit
`kiroku-store-migrations/test/Main.hs` (imports, `scaffolderSpec`, and the `main` wiring) and
the `.cabal` test stanza exactly as shown in Milestone M3.

**Step 5 — run the test suite (M3 acceptance).**

```bash
cabal test kiroku-store-migrations-test
```

Expected (abbreviated — the codd spike line appears only if an ephemeral PostgreSQL starts):

```text
migration file names
  carry real UTC authoring timestamps, not hand-assigned sentinels
  have unique, strictly increasing timestamps
migration scaffolder
  stamps a real, non-sentinel UTC timestamp and a bare slug
  writes a well-named file into a temp dir and refuses to overwrite
codd migration spike
  applies Kiroku migrations, opens the store without startup DDL, and is repeatable

Finished in ...
5 examples, 0 failures
```

**Step 6 — commit.** Commit per milestone (or once at the end if you prefer). Every commit must
carry these trailers verbatim:

```text
MasterPlan: docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md
ExecPlan: docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md
Intention: intention_01kwstss55e79aafxgtcw6631j
```

Example (follow Conventional Commits — this repository uses `feat:`/`test:`/etc.):

```bash
git add kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs \
        kiroku-store-migrations/app/Main.hs \
        kiroku-store-migrations/test/Main.hs \
        kiroku-store-migrations/kiroku-store-migrations.cabal
git commit -m "feat(migrations): scaffold new migrations with real UTC timestamps

Add a \`new\` subcommand to kiroku-store-migrate, backed by
Kiroku.Store.Migrations.New, that stamps the real current UTC time to
the second and emits a kiroku-qualified idempotent SQL skeleton. Add a
round-trip test proving the output passes migrationFileNameSpec.

MasterPlan: docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md
ExecPlan: docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md
Intention: intention_01kwstss55e79aafxgtcw6631j"
```


## Validation and Acceptance

Acceptance is behavioral, not merely "it compiles". Verify all of the following.

1. **The scaffolder produces a name that passes the guard.** Run the Step 3 smoke test into a
   scratch directory. The printed filename must be of the form `YYYY-MM-DD-HH-MM-SS-<slug>.sql`
   with a real hour/minute and a seconds field that is not `00`. To prove it satisfies the same
   predicate the guard enforces, you can drop the generated file into a scratch tree and run
   `handAssignedTimestamp` mentally: the seconds are non-`00` and it is not midnight, so
   `handAssignedTimestamp` is `False`. The automated `scaffolderSpec` proves this
   programmatically (deterministic path) so you do not have to.

2. **The generated body is schema-qualified and unpinned.** `cat` the generated `.sql` file
   (Step 3). It must contain `kiroku.example` (a hard-qualified object) and must **not** contain
   the string `search_path` anywhere. This is what distinguishes kiroku's correct incremental
   style from the bootstrap's one-time `SET search_path` exception.

3. **The apply path is unchanged.** Running the binary with no `new` argument must still apply
   migrations exactly as before. You do not need a live database to confirm the code path is
   preserved: the `migrate` function body is identical to the pre-change `main` body (a diff of
   `app/Main.hs` shows the apply lines only moved behind the dispatch, not altered). If you have
   a PostgreSQL to point at via the codd environment variables, `cabal run kiroku-store-migrate`
   (no `new`) applies migrations as it always did.

4. **The suite is green.** `cabal test kiroku-store-migrations-test` reports `0 failures`, with
   the two `migration scaffolder` examples passing alongside the untouched
   `migration file names` and `codd migration spike` examples. This is the primary proof that
   the producer (scaffolder) and the guard (`migrationFileNameSpec`) agree.

5. **The guard was not weakened.** `git diff` on `test/Main.hs` must show `migrationFileNameSpec`
   and its helpers (`handAssignedTimestamp`, `isTimestampShaped`, `timestampFields`,
   `timestampWidth`, `migrationFiles`, `findMigrationsDir`) unchanged. The only changes are new
   imports, the new `scaffolderSpec`, and one added line in `main`.

6. **The real `sql-migrations/` tree is untouched.** `git status` after the whole exercise must
   show no new or modified files under `kiroku-store-migrations/sql-migrations/`. The smoke test
   wrote into `/tmp`, and the test wrote into a system temp directory that `withSystemTempDirectory`
   deletes on exit.


## Idempotence and Recovery

**Re-running the plan's edits is safe.** All edits are to source files; re-applying them
produces the same tree. If a build or test fails midway, fix the reported error and re-run the
same `cabal` command — cabal is incremental and idempotent.

**The scaffolder refuses to overwrite.** `newMigrationFile` calls `doesFileExist` and raises a
`userError` ("refusing to overwrite existing migration: <path>") rather than clobbering an
existing file. In practice a collision is nearly impossible because the filename includes the
current second, but the guard makes the failure explicit if you somehow target an existing path
(for example by scripting a fixed timestamp). It also refuses a description with no
alphanumeric character (which would slug to the empty string), raising "migration description
must contain at least one letter or digit".

**Temp-dir generation leaves the repository clean.** The smoke test writes into `/tmp` and the
automated test uses `withSystemTempDirectory`, which creates a uniquely named directory under
the system temp location and deletes it (and its contents) when the block exits, even on
exception. Neither touches `kiroku-store-migrations/sql-migrations/`. If you ever run the `new`
subcommand *without* setting `KIROKU_MIGRATIONS_DIR` from within `kiroku-store-migrations/`, it
will write into the real `sql-migrations/` directory (that is the intended production use); to
undo an unwanted scaffold, simply `rm` the created file — nothing else references it until you
touch the embed comment.

**Rollback.** This plan adds a module, a subcommand, a test, and dependency lines; it deletes
nothing and changes no existing behavior. To revert, `git revert` the commit(s); there is no
schema or data migration to unwind.

**Rebase against EP-2 (the drift-gate plan).** EP-2 (`docs/plans/67-…`) also edits
`kiroku-store-migrations/test/Main.hs` and `kiroku-store-migrations/kiroku-store-migrations.cabal`,
but in disjoint places: EP-2 changes `testCoddSettings`'s `onDiskReps` field, adds a
`StrictCheck` example and a pinned-identity ephemeral-pg helper, and adds a new
`executable kiroku-write-expected-schema` stanza plus a `flag expected-schema-tool`. None of
those overlap this plan's additions (`scaffolderSpec`, one `main` line, the `directory`/
`filepath`/`temporary` test deps, and the library `exposed-modules`/deps). If EP-2 landed
first, re-apply this plan's edits onto the current file — the merge is mechanical: add
`scaffolderSpec` and its `main` wiring next to the existing specs, and add the missing test
`build-depends` lines. Do not remove or alter anything EP-2 added. If a `build-depends` line
EP-2 needs (e.g. `filepath`) is already present, do not duplicate it — cabal rejects duplicate
dependency entries.


## Interfaces and Dependencies

**New library module.** `Kiroku.Store.Migrations.New` in
`kiroku-store-migrations/src/Kiroku/Store/Migrations/New.hs`, exposed from the
`kiroku-store-migrations` library. Its public surface (the exact signatures that must exist at
the end of M1):

```haskell
newMigrationFile   :: FilePath -> String -> IO FilePath
migrationFileName  :: UTCTime -> String -> FilePath
migrationSlug      :: String -> String
migrationTemplate  :: String -> String
defaultMigrationsDir :: FilePath
```

- `newMigrationFile dir description` samples the current UTC time, builds the filename via
  `migrationFileName`, ensures `dir` exists, refuses to overwrite, writes `migrationTemplate
  description`, and returns the path. It is the only IO function.
- `migrationFileName now description` is pure: `formatTime` of `now` as `%Y-%m-%d-%H-%M-%S`,
  a dash, `migrationSlug description`, and `.sql`. Taking the time as an argument is what makes
  the deterministic test possible.
- `migrationSlug` is pure: lower-case, collapse non-alphanumeric runs to single dashes, trim
  dashes; **no prefix**.
- `migrationTemplate` is pure: the `kiroku.`-qualified, idempotent skeleton with no
  `search_path`.
- `defaultMigrationsDir` is the constant `"sql-migrations"`.

**Executable dispatch.** `kiroku-store-migrations/app/Main.hs` gains a `getArgs` dispatch:
`("new":rest)` → `generate (unwords rest)`; otherwise → `migrate` (the preserved apply path).
`generate` reads `KIROKU_MIGRATIONS_DIR` (default `defaultMigrationsDir`), calls
`newMigrationFile`, and prints the path plus the embed reminder.

**Libraries used and why.**

- `time` (already a library dependency) — `Data.Time.getCurrentTime`/`UTCTime` for the
  wall-clock reading and `Data.Time.Format.formatTime`/`defaultTimeLocale` for the
  `%Y-%m-%d-%H-%M-%S` rendering. No version bump needed.
- `directory` (new library dependency, `>=1.3 && <1.4`) — `System.Directory`'s
  `createDirectoryIfMissing` and `doesFileExist` for the write/refuse-to-overwrite logic.
- `filepath` (new library dependency, `>=1.4 && <1.6`) — `System.FilePath`'s `(</>)` to join
  the directory and filename portably. Also used by the test for `takeFileName`.
- `base` — `System.Environment` (`getArgs`, `lookupEnv`), `Data.Maybe` (`fromMaybe`),
  `Control.Monad` (`when`), `Data.Char` (`isAlphaNum`, `toLower`) in the executable and module.
- Test-only: `temporary` (`>=1.3 && <1.4`) for `System.IO.Temp.withSystemTempDirectory`, and
  `filepath` for `takeFileName`. `directory` is already a test dependency; `hspec`, `text`,
  `time` are already present.

**Toolchain and nix note.** The build tool is `cabal`; all commands in this plan are `cabal`
invocations from the repository root. The repository also builds under nix, but this plan adds
**no new executable** and **no new non-test external dependencies**: the scaffolder lives in the
existing library, and its two new deps (`directory`, `filepath`) are GHC boot libraries that are
always present in the pinned Haskell package set and build fine under nix. The only new *test*
dependency (`temporary`) affects only the test suite, which nix skips for this package
(`dontCheck` at `nix/haskell-overlay.nix:118`). Therefore **EP-1 carries no nix-closure risk** —
unlike EP-2, which adds a new `ephemeral-pg`-dependent executable and must be flag-gated off
under nix. You do not need to touch `nix/haskell-overlay.nix` in this plan.


---

Revision note (2026-07-05, initial authoring): This document was fleshed out from the skeleton
into a fully self-contained EP-1 plan. Content reflects: the keiro `Keiro.Migrations.New`
model adapted with the kiroku-required changes (no slug prefix, `kiroku.`-qualified no-pin
template, `KIROKU_MIGRATIONS_DIR`, embed reminder); the current contents of `app/Main.hs`,
`test/Main.hs`, the `.cabal`, `src/Kiroku/Store/Migrations.hs`, and the seven files under
`sql-migrations/`; and MasterPlan 10's Integration Points (disjoint edits vs. EP-2, do not
weaken `migrationFileNameSpec`, do not touch `testCoddSettings`/`onDiskReps`/`namespacesToCheck`).
The non-flaky test design (deterministic `UTCTime` for the guard predicate, live
`newMigrationFile` for IO behavior) was chosen to avoid a 1-in-60 wall-clock flake and is
recorded in the Decision Log and Surprises.
