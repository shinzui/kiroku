---
id: 74
slug: add-a-store-identity-and-an-append-only-event-compaction-ledger
title: "Add a store identity and an append-only event-compaction ledger"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Add a store identity and an append-only event-compaction ledger

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is child EP-1 of the MasterPlan
`docs/masterplans/11-manifest-driven-selective-event-compaction.md`. Every commit made while
working on it carries three git trailers: `MasterPlan:`, `ExecPlan:`, and `Intention:` (see
Concrete Steps for the exact text).


## Purpose / Big Picture

Kiroku is a PostgreSQL event store written in Haskell. Its schema is owned by the
`kiroku-store-migrations` package and its runtime API by the `kiroku-store` package. Today a
Kiroku database has no identity of its own: nothing in the `kiroku` schema says "this is store
X", so a tool that was handed instructions produced against one database cannot tell whether it
is now pointed at the same database, a restored clone of it, or an unrelated store. Kiroku also
has no durable record of destructive maintenance: a whole-stream hard delete emits a
process-local `KirokuEvent` and nothing else, so after a restart nobody can prove what was
removed.

After this plan, two things exist that did not before. First, every migrated Kiroku database
carries a single, immutable *store identity* — a UUID generated once by migration and readable
through the public API as `storeIdentity` (an `Eff` action) or `storeIdentityTx` (a value that
runs inside a caller's own transaction). A restored clone of a database carries the same
identity as its source by construction, which is exactly what a consumer wants when it
rehearses a maintenance manifest against a clone before applying it to production. Second, the
schema contains an empty, append-only *event-compaction ledger* table,
`kiroku.event_compactions`, whose full column and constraint contract is fixed here so that the
later plan that writes to it (`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`)
needs no second migration. Both tables are protected the way Kiroku's data tables are: an
`UPDATE` always fails, and a `DELETE` or `TRUNCATE` fails unless the session has set the
hard-delete guard (a PostgreSQL session setting, explained below).

You can see it working by running the new migration against an ephemeral database and calling
`storeIdentity` twice: both calls return the same UUID, a second connection returns the same
UUID, and a database created with `CREATE DATABASE ... TEMPLATE` from the first one returns the
same UUID too. Attempting `UPDATE kiroku.store_identity SET store_id = gen_random_uuid()` fails
with `Immutable table: store_identity cannot be updated`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Scaffold `kiroku-store-migrations/migrations/0012.sql` with the scaffolder and verify the manifest gained the line.
- [ ] M1: Write the migration body: `kiroku.store_identity`, `kiroku.event_compactions`, named constraints, index, protection triggers, comments, and the closing schema comment.
- [ ] M1: Update the hard-coded fixtures in `kiroku-store-migrations/test/Main.hs` (file list, example titles, pending ids, outcome counts, schema-comment literal).
- [ ] M1: Add `describe "compaction schema"` with exact-column and named-constraint assertions and the unchanged `(6, 0)` hot-table trigger shape.
- [ ] M1: Run the migrations suite on the default PostgreSQL and on the 17/18 matrix.
- [ ] M2: Add `StoreIdentity` to `Kiroku.Store.Types`, `storeIdentityStmt` to `Kiroku.Store.SQL`, `GetStoreIdentity` to the `Store` effect and interpreter.
- [ ] M2: Add `Kiroku.Store.Read.storeIdentity` and `Kiroku.Store.Transaction.storeIdentityTx` with Haddock.
- [ ] M2: Write `kiroku-store/test/Test/StoreIdentity.hs` and `Test/StoreIdentityMock.hs`; register both in the cabal file and `test/Main.hs`.
- [ ] M2: Run the store suite and `just perf-structure`.
- [ ] M3: Allocate the ADR handle with `okf id next`, write the store-identity ADR, update `docs/adr/index.md` and `docs/adr/log.md`, run `just adr-validate`.
- [ ] M3: Add unreleased changelog sections to `kiroku-store/CHANGELOG.md` and `kiroku-store-migrations/CHANGELOG.md`; update `docs/user/schema-migrations.md`.
- [ ] M3: Run `cabal build all`, `cabal test all`, `nix fmt`, `nix flake check`; commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship the empty `kiroku.event_compactions` ledger table in the same migration as
  the store identity, with its complete column and constraint contract, even though no code in
  this plan writes to it.
  Rationale: A migration payload can never be edited once released (pg-migrate verifies its
  SHA-256 forever), and each migration should be released once. Putting both tables in `0012`
  means the compaction feature needs exactly one schema release and the later apply plan
  (`docs/plans/78-...`) is purely a `kiroku-store` change. The contract is fixed in the
  MasterPlan's Integration Points so this plan and the apply plan cannot drift.
  Date: 2026-08-22

- Decision: Model the store identity as a singleton-row table
  (`kiroku.store_identity`) with a `BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton)` column,
  mirroring `kiroku.history_retention_coordinator` from migration `0010`.
  Rationale: The singleton pattern is already established and tested in this schema; it
  yields an ordinary row that is trivial to read with one statement, impossible to duplicate,
  and easy to assert in catalog tests.
  Date: 2026-08-22

- Decision: A restored clone (`pg_dump`/`pg_restore`, or `CREATE DATABASE ... TEMPLATE`) shares
  its source's identity. No "rotate identity" operation is provided.
  Rationale: The consumer that motivated this work rehearses the exact production manifest on a
  clone before applying it to production; a shared identity is what makes that rehearsal
  meaningful. Rotation would need its own authorization story and is not requested.
  Date: 2026-08-22

- Decision: Protect both new tables with the existing `kiroku.prevent_mutation()` (UPDATE),
  `kiroku.protect_deletion()` (DELETE), and `kiroku.protect_truncation()` (TRUNCATE) trigger
  functions, and add nothing to `events`, `stream_events`, or `streams`.
  Rationale: The ledger is an audit record and the identity is a fact; neither may change
  silently. Reusing the established functions keeps the GUC contract uniform. The hot-path
  structural gate (`retentionTriggerShapeStmt` expecting `(6, 0)`) must stay green, and it
  does because this migration touches only the two new relations.
  Date: 2026-08-22

- Decision: Do not bump any package version in this plan; add "Unreleased" changelog sections
  only.
  Rationale: Versioning, tagging, and publishing belong to the release plan
  (`docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md`),
  which selects the bump for the whole cohort once.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### The repository in one paragraph

The repository root is the Cabal multi-package project described by `cabal.project`. The
packages that matter here are `kiroku-store` (the event-store library, source under
`kiroku-store/src/Kiroku/Store/`, tests under `kiroku-store/test/`), `kiroku-store-migrations`
(the schema owner: SQL files under `kiroku-store-migrations/migrations/`, a test suite at
`kiroku-store-migrations/test/Main.hs`, an executable `kiroku-store-migrate`), and
`kiroku-test-support` (one module, `Kiroku.Test.Postgres`, that starts a throwaway PostgreSQL
server with the `ephemeral-pg` library and applies the migrations to it). The build uses GHC
9.12.4 through `cabal`; a `justfile` at the root wraps the common commands (`just test`,
`just perf-structure`, `just test-matrix`, `just adr-validate`). Nothing in the test suites
needs a `DATABASE_URL`; they bring their own server.

### How migrations work today

Kiroku's migrations are applied by the `pg-migrate` library. A migration is identified by the
pair (component `kiroku`, file basename without `.sql`) and by the SHA-256 of its bytes.
Ordering is the line order of `kiroku-store-migrations/migrations/manifest`, which currently
lists eleven files ending in `0009.sql`, `0010.sql`, `0011.sql`. Files since `0009` are bare
zero-padded numbers without a slug. You never hand-edit the manifest; the scaffolder creates
the next file and appends its line atomically:

```bash
cabal run kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "add store identity and event-compaction ledger"
```

This prints `Created kiroku-store-migrations/migrations/0012.sql` and leaves a file containing
only the comment line `-- add store identity and event-compaction ledger` followed by a blank
line. A released migration payload is never edited again; a mistake is fixed by a new forward
migration. Two older ExecPlans (66 and 67) describe a timestamped scaffolder and a codd
"expected schema" gate; both are superseded and the directories they mention
(`sql-migrations/`, `expected-schema/`) are empty leftovers. Ignore them.

Conventions every migration after `0001` must follow, all visible in
`kiroku-store-migrations/migrations/0010.sql`: schema-qualify every object name as
`kiroku.<name>` (only `0001` sets `search_path`); use `kiroku.uuidv7()` — never bare
`uuidv7()` — for UUID defaults, because `0010` made that qualified name exist on both
PostgreSQL 17 and 18; put triggers only on `DELETE`, `TRUNCATE`, and (for immutability) `UPDATE`,
never on `INSERT`; give every constraint an explicit `chk_...` name so tests can assert the
names; add `COMMENT ON TABLE` / `COMMENT ON COLUMN` for every published object; and end with
`COMMENT ON SCHEMA kiroku IS 'Managed by pg-migrate component kiroku through 0012';`, which the
test suite pins.

The trigger functions you will reuse already exist in the `kiroku` schema since `0001`:
`kiroku.prevent_mutation()` raises `Immutable table: <name> cannot be updated`;
`kiroku.protect_deletion()` and `kiroku.protect_truncation()` raise unless the session has run
`SET LOCAL kiroku.enable_hard_deletes = 'on'`. That session setting is what this repository
calls "the hard-delete GUC" (GUC is PostgreSQL's name for a configuration variable). It is an
accidental-mutation guard, not a security boundary; PostgreSQL privileges remain the boundary.

### The migrations test suite and its hard-coded fixtures

`kiroku-store-migrations/test/Main.hs` is a plain `hspec` suite (target
`kiroku-store-migrations:kiroku-store-migrations-test`). It hard-codes the migration inventory
in several places that you must update for a twelfth file:

The list `nativeMigrationFiles` (near line 420) enumerates the eleven basenames; append
`"0012.sql"`. Two example titles say "eleven" — `"tracks the eleven native files in manifest
order"` and `"applies all eleven, verifies strictly, and reports AlreadyApplied on rerun"` —
rename both to "twelve". In the Codd-history import fixture (near line 391) the `pendingIds`
list `["0008-schema-management-comment", "0009", "0010", "0011"]` gains `"0012"`, and the
assertion `replicate 7 AlreadyApplied <> replicate 4 AppliedNow` becomes `replicate 5
AppliedNow`. The block `describe "upgrades of already-bootstrapped databases"` (near line 284)
uses `planThrough (length nativeMigrationFiles - 2)` and `replicate 2 AppliedNow`; it models a
database bootstrapped two releases ago and applying the pending tail in a session with no
`search_path`. Keep the shape: with twelve files the tail is still the last two (`0011`,
`0012`), which is the right thing to test, so the arithmetic needs no change — but read the
block and confirm the trailing `replicate 2 AppliedNow` still describes the tail. Finally
`schemaFactsStatement` (near line 553) contains the literal
`'Managed by pg-migrate component kiroku through 0011'`; change it to `0012`.

The model for a focused schema block is `describe "history retention schema"` (near line 253):
one example compares the exact ordered `(relname, attname, format_type, attnotnull)` rows for
the new tables from `pg_attribute`, and one example counts *named* constraints (not all
constraints — PostgreSQL 18 exposes column `NOT NULL` as `pg_constraint` rows, so counting
everything is version-dependent), checks index predicates with `pg_indexes.indexdef`, and
counts triggers. You will add `describe "compaction schema"` in the same style.

The suite must pass on both supported PostgreSQL majors. `cabal test all` uses whichever
`postgres` is on `PATH` (18 in the default dev shell); `just test-matrix` runs the suites under
`nix develop .#postgresql17` and `.#postgresql18`, asserting the server major each time. Run the
matrix before declaring the migration done.

### The `Store` effect and its interpreter

`kiroku-store/src/Kiroku/Store/Effect.hs` defines `data Store :: Effect where ...`, a GADT of
operations (`AppendToStream`, `ReadStreamForward`, `GetStream`, `LookupStreamNames`,
`HardDeleteStream`, the five `...HistoryRetentionLease...` constructors, `RunTransaction`, and
so on). "Effect" here is the `effectful` library's notion: an operation type that a program
`send`s and an interpreter handles. The production interpreter is `runStorePool`, a big
`interpret_ $ \case ...` over every constructor. Read-only constructors use the helper
`usePool (store ^. #pool) $ Session.statement params SQL.someStmt`, which maps pool errors to
`StoreError`. Transaction-shaped constructors use `runTxOnPool`.

Public wrappers live in small modules: `kiroku-store/src/Kiroku/Store/Read.hs` exports
`readStreamForward`, `visibleGlobalHeadPosition`, `lookupStreamNames`, each a one-liner like
`visibleGlobalHeadPosition = send GetVisibleGlobalHeadPosition` with rich Haddock.
`kiroku-store/src/Kiroku/Store/Transaction.hs` hosts `Tx.Transaction`-flavored combinators that
callers compose inside their own `hasql-transaction` bodies (`appendToStreamTx` and friends).
SQL statements are `Hasql.Statement` values in `kiroku-store/src/Kiroku/Store/SQL.hs`, built
with `preparable "<sql>" encoder decoder` and grouped by section in the export list. The
umbrella module `kiroku-store/src/Kiroku/Store.hs` re-exports `Kiroku.Store.Read`,
`Kiroku.Store.Transaction`, and `Kiroku.Store.Types` wholesale, so adding exports to those
modules makes them public automatically.

Core types are in `kiroku-store/src/Kiroku/Store/Types.hs`: `newtype StreamId = StreamId Int64`,
`newtype EventId = EventId UUID`, `newtype GlobalPosition = GlobalPosition Int64`, each
`deriving stock (Eq, Ord, Show, Generic)`. The package enables `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`, `DeriveAnyClass` by default (see the `common common`
stanza of `kiroku-store/kiroku-store.cabal`) and compiles with `-Werror=incomplete-patterns`.

### Tests in `kiroku-store`

There is one test suite, `kiroku-store:kiroku-store-test`, whose modules are listed explicitly
under `other-modules` in `kiroku-store/kiroku-store.cabal` and wired in
`kiroku-store/test/Main.hs` (`main = withSharedMigratedPostgres $ hspec $ do ...`). New test
modules must be added to both. The fixture is `Test.Helpers.withTestStore :: (KirokuStore -> IO
()) -> IO ()`, which creates a fresh migrated database from a template and opens a store; the
variant `withTestStoreSettings` lets you tweak `ConnectionSettings` first. Existing helpers
include `truncateRejected :: KirokuStore -> Text -> IO Bool` (returns `True` when `TRUNCATE`
of the named table is rejected without the GUC) and `tableExists`.

Mock interpreters follow one pattern (see `kiroku-store/test/Test/VisibleGlobalHeadPositionMock.hs`):
an `interpret_ $ \case` that handles exactly the constructors under test, counts calls in an
`IORef`, and ends with `_ -> error "unexpected Store operation ..."`. The test asserts both the
returned value and that exactly one dispatch occurred.

The structural performance gate (`just perf-structure`) runs every example under the
`describe "performance structure"` block in `kiroku-store/test/Main.hs`. One of its examples,
in `kiroku-store/test/Test/PerformanceStructure.hs`, asserts that the three hot tables carry
exactly six `protect_replay_history_*` triggers and none on INSERT/UPDATE (`shape shouldBe
(6, 0)`). This migration must not change that.

### ADRs

Architecture Decision Records live in `docs/adr/` as an OKF bundle governed by
`docs/adr/profile.dhall`. Each record is one Markdown file with frontmatter fields `type`,
`title`, `description`, `generated` (`by`, `at`), `docId` (`ADR-N`), `status`, `date`,
`timestamp`, and optionally `originatingPlan`; `docs/adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md`
is the template to copy. `docs/adr/index.md` lists every record; `docs/adr/log.md` is appended
with `okf log add`. Handles are allocated with `okf id next`, never by counting files. Strict
validation is `just adr-validate`.

The relevant records for this plan, both read during planning:

[ADR-3](../adr/0003-dedicated-kiroku-schema.md) — every Kiroku object lives in the dedicated
`kiroku` schema and `ConnectionSettings.schema` is authoritative for resolution. Consequence
here: both new tables, their triggers, and their comments are created fully qualified.

[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md) —
destructive work is serialized through the `history_retention_coordinator` singleton, refuses
while any lease is active, locks affected streams in ascending `stream_id`, and adds nothing to
ordinary append/read paths; its migration `0010` is the style guide for this one (singleton
row pattern, `kiroku.uuidv7()`, statement-level DELETE/TRUNCATE triggers, named constraints).
This plan adds no lease or coordinator behaviour; it only follows the same schema discipline.

No ADR yet records a store identity; this plan creates one (Milestone 3).

### Why a consumer needs this

The request that motivates the initiative is
`docs/improvement-requests/add-manifest-driven-selective-event-compaction.md` (IR-14), filed for
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`.
That consumer builds a manifest naming the store it was produced against and requires Kiroku to
refuse the manifest on store-identity mismatch. The ledger serves the request's requirement that
reapplying an already completed manifest is an observable no-op and that operators can audit
applies without reading private tables.


## Plan of Work

### Milestone 1 — Migration `0012` installs the identity and the ledger

Scope: the schema change and its tests. At the end, a freshly migrated database contains
`kiroku.store_identity` with one row and `kiroku.event_compactions` with zero rows, both
protected; the migrations suite asserts their exact contract; and the PostgreSQL 17/18 matrix
passes.

Run the scaffolder from the repository root (command in Context and Orientation). Open the new
`kiroku-store-migrations/migrations/0012.sql` and replace its body with the following. Keep the
description comment as the first line.

```sql
-- add store identity and event-compaction ledger

-- A schema-installed, immutable identity for this store. Generated once, on the
-- PostgreSQL side, the first time this migration runs. A restored clone shares
-- its source's identity by construction; that is intended, so a maintenance
-- manifest rehearsed on a clone still names the production store.
CREATE TABLE kiroku.store_identity (
    singleton  BOOLEAN     PRIMARY KEY DEFAULT TRUE,
    store_id   UUID        NOT NULL DEFAULT kiroku.uuidv7(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_store_identity_singleton CHECK (singleton)
);

INSERT INTO kiroku.store_identity (singleton)
VALUES (TRUE)
ON CONFLICT DO NOTHING;

-- Durable, append-only record of every applied selective compaction. Rows are
-- written only by kiroku-store's compaction apply transaction; the table ships
-- empty and its full contract is fixed here so the feature needs one schema
-- release. manifest_digest and report_digest are raw SHA-256 bytes.
CREATE TABLE kiroku.event_compactions (
    compaction_id            UUID        PRIMARY KEY DEFAULT kiroku.uuidv7(),
    manifest_digest          BYTEA       NOT NULL UNIQUE,
    report_digest            BYTEA       NOT NULL,
    store_id                 UUID        NOT NULL,
    operation                TEXT        NOT NULL,
    dead_letter_policy       TEXT        NOT NULL,
    causation_policy         TEXT        NOT NULL,
    selected_events          BIGINT      NOT NULL,
    home_memberships         BIGINT      NOT NULL,
    global_memberships       BIGINT      NOT NULL,
    link_memberships         BIGINT      NOT NULL,
    dead_letters_removed     BIGINT      NOT NULL,
    causation_dependents     BIGINT      NOT NULL,
    lowest_global_position   BIGINT      NOT NULL,
    highest_global_position  BIGINT      NOT NULL,
    affected_streams         JSONB       NOT NULL,
    applied_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by               TEXT        NOT NULL DEFAULT session_user,
    CONSTRAINT chk_event_compactions_manifest_digest_bytes
        CHECK (octet_length(manifest_digest) = 32),
    CONSTRAINT chk_event_compactions_report_digest_bytes
        CHECK (octet_length(report_digest) = 32),
    CONSTRAINT chk_event_compactions_operation_bytes
        CHECK (octet_length(operation) BETWEEN 1 AND 512),
    CONSTRAINT chk_event_compactions_policies
        CHECK (dead_letter_policy IN ('refuse', 'remove')
           AND causation_policy IN ('refuse', 'allow')),
    CONSTRAINT chk_event_compactions_counts
        CHECK (selected_events > 0
           AND home_memberships = selected_events
           AND global_memberships = selected_events
           AND link_memberships >= 0
           AND dead_letters_removed >= 0
           AND causation_dependents >= 0),
    CONSTRAINT chk_event_compactions_positions
        CHECK (0 < lowest_global_position
           AND lowest_global_position <= highest_global_position)
);

CREATE INDEX ix_event_compactions_applied_at
    ON kiroku.event_compactions (applied_at DESC, compaction_id);

-- Immutability and gated destruction, reusing the functions 0001 installed.
-- Nothing here touches events, stream_events, or streams.
CREATE TRIGGER no_update_store_identity
    BEFORE UPDATE ON kiroku.store_identity
    FOR EACH ROW EXECUTE FUNCTION kiroku.prevent_mutation();

CREATE TRIGGER no_delete_store_identity
    BEFORE DELETE ON kiroku.store_identity
    FOR EACH ROW EXECUTE FUNCTION kiroku.protect_deletion();

CREATE TRIGGER no_truncate_store_identity
    BEFORE TRUNCATE ON kiroku.store_identity
    FOR EACH STATEMENT EXECUTE FUNCTION kiroku.protect_truncation();

CREATE TRIGGER no_update_event_compactions
    BEFORE UPDATE ON kiroku.event_compactions
    FOR EACH ROW EXECUTE FUNCTION kiroku.prevent_mutation();

CREATE TRIGGER no_delete_event_compactions
    BEFORE DELETE ON kiroku.event_compactions
    FOR EACH ROW EXECUTE FUNCTION kiroku.protect_deletion();

CREATE TRIGGER no_truncate_event_compactions
    BEFORE TRUNCATE ON kiroku.event_compactions
    FOR EACH STATEMENT EXECUTE FUNCTION kiroku.protect_truncation();

COMMENT ON TABLE kiroku.store_identity IS
  'Single immutable row identifying this store; a restored clone shares its source identity.';
COMMENT ON COLUMN kiroku.store_identity.store_id IS
  'UUIDv7 generated once by migration 0012; never updated.';

COMMENT ON TABLE kiroku.event_compactions IS
  'Append-only ledger of applied selective compactions keyed by manifest digest; rows are audit evidence and are never updated.';
COMMENT ON COLUMN kiroku.event_compactions.manifest_digest IS
  'Raw SHA-256 of the canonical manifest encoding; unique so an exact manifest can be applied once.';
COMMENT ON COLUMN kiroku.event_compactions.report_digest IS
  'Raw SHA-256 of the canonical report encoding recorded at apply time.';
COMMENT ON COLUMN kiroku.event_compactions.affected_streams IS
  'JSON array of {"stream", "head_version"} objects sorted by stream name, recording the verified head of every affected stream.';
COMMENT ON COLUMN kiroku.event_compactions.applied_by IS
  'PostgreSQL session_user that applied the manifest; recorded by default, not supplied by the caller.';

COMMENT ON SCHEMA kiroku IS
  'Managed by pg-migrate component kiroku through 0012';
```

Next update `kiroku-store-migrations/test/Main.hs` as described in Context and Orientation, then
add the new block after `describe "history retention schema"`:

```haskell
    describe "compaction schema" $ do
        it "publishes the exact store identity and ledger columns" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                columns <- useSession connection (Session.statement () compactionColumnsStatement)
                columns
                    `shouldBe` [ ("event_compactions", "compaction_id", "uuid", True)
                               , ("event_compactions", "manifest_digest", "bytea", True)
                               , ("event_compactions", "report_digest", "bytea", True)
                               , ("event_compactions", "store_id", "uuid", True)
                               , ("event_compactions", "operation", "text", True)
                               , ("event_compactions", "dead_letter_policy", "text", True)
                               , ("event_compactions", "causation_policy", "text", True)
                               , ("event_compactions", "selected_events", "bigint", True)
                               , ("event_compactions", "home_memberships", "bigint", True)
                               , ("event_compactions", "global_memberships", "bigint", True)
                               , ("event_compactions", "link_memberships", "bigint", True)
                               , ("event_compactions", "dead_letters_removed", "bigint", True)
                               , ("event_compactions", "causation_dependents", "bigint", True)
                               , ("event_compactions", "lowest_global_position", "bigint", True)
                               , ("event_compactions", "highest_global_position", "bigint", True)
                               , ("event_compactions", "affected_streams", "jsonb", True)
                               , ("event_compactions", "applied_at", "timestamp with time zone", True)
                               , ("event_compactions", "applied_by", "text", True)
                               , ("store_identity", "singleton", "boolean", True)
                               , ("store_identity", "store_id", "uuid", True)
                               , ("store_identity", "created_at", "timestamp with time zone", True)
                               ]
            either (expectationFailure . show) pure result

        it "installs one identity row, named constraints, the ledger index, six protection triggers, and leaves hot tables unchanged" $ do
            plan <- requirePlan
            result <- withMigratedDatabase plan $ \connection -> do
                facts <- useSession connection (Session.statement () compactionFactsStatement)
                facts `shouldBe` (1, 0, 10, True, 6, 6)
            either (expectationFailure . show) pure result
```

`compactionColumnsStatement` is a copy of `historyRetentionColumnsStatement` with the relation
list `('event_compactions', 'store_identity')`; the `ORDER BY relation.relname,
attribute.attnum` clause is why `event_compactions` rows come first. `compactionFactsStatement`
returns a six-tuple: the count of `store_identity` rows where `singleton`; the count of
`event_compactions` rows (expected `0`); the count of `pg_constraint` rows in schema `kiroku`
whose `conname` is one of `store_identity_pkey`, `chk_store_identity_singleton`,
`event_compactions_pkey`, `event_compactions_manifest_digest_key`,
`chk_event_compactions_manifest_digest_bytes`, `chk_event_compactions_report_digest_bytes`,
`chk_event_compactions_operation_bytes`, `chk_event_compactions_policies`,
`chk_event_compactions_counts`, `chk_event_compactions_positions` — ten names, hence the
expected `10` (PostgreSQL auto-names the primary keys `<table>_pkey` and the `UNIQUE` column
constraint `event_compactions_manifest_digest_key`); whether `ix_event_compactions_applied_at` exists with `indexdef LIKE '%applied_at DESC%'`; the
count of non-internal triggers on the two new tables whose names start with `no_` (expected
`6`); and the same `protect_replay_history_*` trigger count on `events`, `stream_events`,
`streams` that `historyRetentionFactsStatement` computes (expected `6`, proving nothing was
added to the hot tables). Write it with one `SELECT` of six scalar subqueries, exactly like
`historyRetentionFactsStatement`, and decode with `Decoders.singleRow` of a six-tuple.

Run the suite, then the matrix. Acceptance: every example passes on PostgreSQL 17 and 18, and
the output shows twelve `AppliedNow` outcomes on a fresh database.

### Milestone 2 — The public `storeIdentity` API

Scope: the Haskell surface for reading the identity. At the end, `storeIdentity` and
`storeIdentityTx` are exported from the umbrella module, dispatch through one `Store` call,
and are covered by integration and mock tests.

In `kiroku-store/src/Kiroku/Store/Types.hs`, add `StoreIdentity (..)` to the export list and
the declaration, placed after `GlobalPosition`:

```haskell
{- | The immutable identity of one Kiroku store, installed once by migration
@0012@ in @kiroku.store_identity@. A database restored from a backup or created
with @CREATE DATABASE ... TEMPLATE@ carries the same identity as its source;
this is intended so maintenance manifests rehearsed on a clone still name the
production store. Read it with 'Kiroku.Store.Read.storeIdentity' or
'Kiroku.Store.Transaction.storeIdentityTx'.
-}
newtype StoreIdentity = StoreIdentity UUID
    deriving stock (Eq, Ord, Show, Generic)
```

In `kiroku-store/src/Kiroku/Store/SQL.hs`, add an export group `-- * Store identity` with
`storeIdentityStmt` and the definition:

```haskell
-- | Read the single store identity row installed by migration 0012.
storeIdentityStmt :: Statement () StoreIdentity
storeIdentityStmt =
    preparable
        "SELECT store_id FROM store_identity WHERE singleton"
        E.noParams
        (D.singleRow (StoreIdentity <$> D.column (D.nonNullable D.uuid)))
```

Statements in this module use unqualified table names because the connection's `search_path`
is set from `ConnectionSettings.schema` (ADR-3); follow the neighbouring statements.

In `kiroku-store/src/Kiroku/Store/Effect.hs`, add the constructor next to
`GetVisibleGlobalHeadPosition`:

```haskell
    {- | Read the immutable identity installed by migration @0012@.
    Surfaced as 'Kiroku.Store.Read.storeIdentity'.
    -}
    GetStoreIdentity :: Store m StoreIdentity
```

and the interpreter arm in `runStorePool`:

```haskell
    GetStoreIdentity ->
        usePool (store ^. #pool) $
            Session.statement () SQL.storeIdentityStmt
```

In `kiroku-store/src/Kiroku/Store/Read.hs`, export and define:

```haskell
{- | The store's immutable identity (see 'Kiroku.Store.Types.StoreIdentity').
Stable for the life of the database and shared by restored clones. One pool
checkout, one statement.
-}
storeIdentity :: (HasCallStack, Store :> es) => Eff es StoreIdentity
storeIdentity = send GetStoreIdentity
```

In `kiroku-store/src/Kiroku/Store/Transaction.hs`, add a section `-- * Tx-flavored reads`
exporting `storeIdentityTx`:

```haskell
{- | Read the store identity inside the caller's transaction, so a manifest
check and the work that depends on it share one snapshot.
-}
storeIdentityTx :: Tx.Transaction StoreIdentity
storeIdentityTx = Tx.statement () SQL.storeIdentityStmt
```

(`Kiroku.Store.Transaction` does not yet import `Kiroku.Store.SQL`; add
`import Kiroku.Store.SQL qualified as SQL`.)

Create `kiroku-store/test/Test/StoreIdentity.hs`:

```haskell
module Test.StoreIdentity (spec) where

spec :: Spec
spec = describe "store identity" $ do
    it "is stable across calls and equal between the effect and the transaction combinator" $
        withTestStore $ \store -> do
            Right first <- runStoreIO store storeIdentity
            Right second <- runStoreIO store storeIdentity
            Right viaTx <- runStoreIO store (runTransaction storeIdentityTx)
            second `shouldBe` first
            viaTx `shouldBe` first

    it "rejects UPDATE, DELETE, and TRUNCATE of the identity and ledger without the guard" $
        withTestStore $ \store -> do
            updateRejected store "store_identity" `shouldReturn` True
            deleteRejected store "store_identity" `shouldReturn` True
            truncateRejected store "store_identity" `shouldReturn` True
            deleteRejected store "event_compactions" `shouldReturn` True
            truncateRejected store "event_compactions" `shouldReturn` True

    it "is shared by a database created from this one as a template" $ ...
```

Write `updateRejected` and `deleteRejected` locally in the same style as
`Test.Helpers.truncateRejected` (run the raw statement through `Pool.use`, return `True` on a
server error). For the template case, use `withMigratedTestDatabase` from
`Kiroku.Test.Postgres` to obtain a connection string, open a store, read the identity, then
from a second raw `Hasql.Connection` run `CREATE DATABASE <fresh> TEMPLATE <current>` (this
requires no other sessions on the template; the test database is yours alone, so close the
first store before issuing it, or open the template store only after the copy), open a store
against the copy, read its identity, and assert equality; drop the copy in a `finally`.
If template creation proves fragile under the shared ephemeral server, the acceptable fallback
is `pg_dump --schema-only --data-only`-free: read `store_id` from the first database and insert
it with an explicit value into a second fresh database's `store_identity` row before the
migration seeds it — but prefer the template approach and record which one you used in
Surprises & Discoveries.

Create `kiroku-store/test/Test/StoreIdentityMock.hs` by copying
`Test/VisibleGlobalHeadPositionMock.hs`, handling `GetStoreIdentity` and asserting one
dispatch returns the configured `StoreIdentity`. Register `Test.StoreIdentity` and
`Test.StoreIdentityMock` in `kiroku-store/kiroku-store.cabal` under `other-modules` of the test
suite (keep alphabetical order) and in `kiroku-store/test/Main.hs` next to the other mock and
lifecycle specs.

Acceptance: `cabal test kiroku-store:kiroku-store-test` passes with the three new examples and
the mock example; `just perf-structure` still reports the `(6, 0)` trigger shape.

### Milestone 3 — ADR, changelogs, and documentation

Scope: durable context and the release-facing notes. At the end, the store-identity decision is
an accepted ADR, both changelogs carry an "Unreleased" section, and the schema guide counts
twelve migrations.

Allocate the handle:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

At planning time the next handle was `ADR-8`; use whatever the command prints. Create
`docs/adr/000N-store-identity-is-a-schema-installed-clone-shared-singleton.md` (with `N`
matching the handle) by copying the frontmatter shape of
`docs/adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md`: `type:
Architecture Decision Record`, the title, a one-sentence `description`, `generated.by` as the
producing agent (for example `anthropic/claude-fable-5`) and `generated.at` as the current UTC
timestamp, `docId: ADR-N`, `status: Accepted`, `date: 2026-08-22` (or the day you write it),
`timestamp`, and `originatingPlan: docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md`.
The body has the sections Context, Decision, Consequences (Positive, Negative), Alternatives
Considered. Record: the identity is a singleton row generated by migration; clones share it;
there is no rotation; the ledger table is append-only and keyed by manifest digest; both
tables reuse the `0001` protection functions; nothing is added to hot tables. Alternatives to
list: a per-connection caller-supplied label (rejected: not durable, not verifiable); deriving
identity from the database OID or `pg_control` system identifier (rejected: changes on restore,
which defeats clone rehearsal); a separate identity per schema migration (rejected: no
requirement).

Add the record to `docs/adr/index.md` in the same list style, then:

```bash
okf log add docs/adr --kind Addition -m "ADR-N establishes the schema-installed, clone-shared store identity and the append-only event-compaction ledger contract."
just adr-validate
```

In `kiroku-store/CHANGELOG.md`, add at the top:

```markdown
## Unreleased

### New Features

* `Kiroku.Store.Types.StoreIdentity`, `Kiroku.Store.Read.storeIdentity`, and
  `Kiroku.Store.Transaction.storeIdentityTx` read the immutable store identity
  installed by `kiroku-store-migrations` migration `0012`. Requires that
  migration; a store migrated only through `0011` fails the read with a missing
  relation error.
```

In `kiroku-store-migrations/CHANGELOG.md`, add:

```markdown
## Unreleased

### New Features

* Migration `0012` installs `kiroku.store_identity` (one immutable UUID row,
  shared by restored clones) and the empty append-only
  `kiroku.event_compactions` ledger with its complete constraint contract. Both
  reuse the `0001` mutation, deletion, and truncation guards. No trigger,
  statement, or column is added to `events`, `stream_events`, or `streams`. The
  plan now has twelve migrations and the schema comment reads
  `Managed by pg-migrate component kiroku through 0012`; consumers whose tests
  pin the count or the comment must update them.
```

Update `docs/user/schema-migrations.md`: "eleven ordered native migrations" becomes "twelve",
and "`0008` through `0011` are native-only forward migrations" becomes "`0008` through
`0012`"; search the file for every `0011` and update the ones that describe the current tail.
Add a short paragraph under the authoring section noting that `0012` installed the store
identity and the compaction ledger.

Acceptance: `just adr-validate` passes; `cabal build all`, `cabal test all`, `nix fmt`, and
`nix flake check` pass; the working tree is committed with the trailers.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Scaffold and verify the manifest:

```bash
cabal run kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "add store identity and event-compaction ledger"
cabal run kiroku-store-migrate -- check --manifest kiroku-store-migrations/migrations/manifest
tail -3 kiroku-store-migrations/migrations/manifest
```

Expected:

```text
Created kiroku-store-migrations/migrations/0012.sql
0010.sql
0011.sql
0012.sql
```

Edit the SQL body and the test fixtures, then run the migrations suite. Because the SQL is
embedded at compile time and a SQL-only edit may not trigger a rebuild, force one:

```bash
touch kiroku-store-migrations/src/Kiroku/Store/Migrations/Internal/Definition.hs
cabal test kiroku-store-migrations:kiroku-store-migrations-test --test-show-details=direct
```

Expected tail:

```text
  compaction schema
    publishes the exact store identity and ledger columns
    installs one identity row, named constraints, the ledger index, six protection triggers, and leaves hot tables unchanged
...
Finished in N seconds
M examples, 0 failures
```

Run the matrix (this enters two nix dev shells and takes several minutes):

```bash
just test-matrix
```

Expected: each run prints `== postgres (PostgreSQL) 17.x ==` or `18.x` followed by every suite
passing, including the line `PostgreSQL 17 UUIDv7 generator: kiroku.uuidv7() via 0001's
fallback` on the 17 run.

Implement Milestone 2, then:

```bash
cabal build kiroku-store
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "store identity"'
just perf-structure
```

Expected: the `store identity` examples and the `store identity mock` example pass; the
performance-structure examples pass including `installs no retention trigger for INSERT or
UPDATE`.

Implement Milestone 3, then:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr --kind Addition -m "<message>"
just adr-validate
nix fmt
cabal build all
cabal test all
git add -A
nix flake check
```

Commit at each milestone boundary with a message of this shape:

```text
feat(migrations): install store identity and event-compaction ledger

Add migration 0012 creating kiroku.store_identity and the append-only
kiroku.event_compactions ledger with named constraints, protection
triggers, and comments. Extend the migrations suite with exact column,
constraint, index, and trigger assertions and update the fixtures for
twelve migrations.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

After Milestone 1, a fresh database migrated with the full plan satisfies the following, which
you can check by hand with `psql` against a local database after `just reset-database`:

```sql
SELECT count(*) FROM kiroku.store_identity;            -- 1
SELECT count(*) FROM kiroku.event_compactions;         -- 0
UPDATE kiroku.store_identity SET created_at = now();   -- ERROR: Immutable table: store_identity cannot be updated
DELETE FROM kiroku.event_compactions;                  -- ERROR: Hard deletes require: SET LOCAL kiroku.enable_hard_deletes = 'on'
SELECT obj_description(to_regnamespace('kiroku'), 'pg_namespace');
-- Managed by pg-migrate component kiroku through 0012
```

After Milestone 2, a program using the public API observes one UUID from `storeIdentity`, the
same UUID from `storeIdentityTx`, and the same UUID after the database is copied with `CREATE
DATABASE ... TEMPLATE`. The mock test proves `storeIdentity` performs exactly one `Store`
dispatch, so a mocked store needs to handle only `GetStoreIdentity`.

After Milestone 3, `just adr-validate` reports the bundle valid with the new record, and the
two changelogs describe the change under "Unreleased".

The structural gate must be unchanged throughout: `just perf-structure` keeps reporting the
`(6, 0)` trigger shape on the hot tables, and `Test.NotifyGuard` keeps its exact payload
expectations (this migration fires no notification).


## Idempotence and Recovery

The scaffolder refuses to overwrite an existing `0012.sql` and appends to the manifest
atomically, so rerunning it after a failure either succeeds once or fails loudly; never edit
the manifest by hand. The migration body is applied to ephemeral test databases only, which are
created from a template per example and dropped afterwards; rerunning the suites is always safe.

Before the migration is released (which this plan does not do), its payload may be edited
freely. After release, it must never change: a defect is corrected by a new forward migration,
as `0011` corrected `0010`. If you discover after committing that a constraint or column is
wrong, amend the migration in a follow-up commit on the same unreleased payload and re-run the
matrix.

The ADR handle is allocated by `okf id next`; if you abandon a draft, delete the file before
re-running the command so the handle is not skipped. `okf log add` appends; if you run it twice
by mistake, remove the duplicate line by hand.


## Interfaces and Dependencies

Libraries: `hasql` (statements and decoders), `hasql-transaction` (`Tx.Transaction`),
`effectful-core` (the `Store` effect), `uuid` (already a dependency of `kiroku-store`).
`kiroku-store-migrations` gains no new dependency. No new package dependency is needed for this
plan.

At the end of Milestone 1 these SQL objects exist in every migrated database:
`kiroku.store_identity` and `kiroku.event_compactions` exactly as written above,
`ix_event_compactions_applied_at`, the six `no_*` triggers, and the schema comment through
`0012`.

At the end of Milestone 2 these declarations exist and are re-exported by `Kiroku.Store`:

```haskell
-- Kiroku.Store.Types
newtype StoreIdentity = StoreIdentity UUID
    deriving stock (Eq, Ord, Show, Generic)

-- Kiroku.Store.SQL
storeIdentityStmt :: Statement () StoreIdentity

-- Kiroku.Store.Effect (constructor of data Store)
GetStoreIdentity :: Store m StoreIdentity

-- Kiroku.Store.Read
storeIdentity :: (HasCallStack, Store :> es) => Eff es StoreIdentity

-- Kiroku.Store.Transaction
storeIdentityTx :: Tx.Transaction StoreIdentity
```

The ledger table is consumed by `docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`
(read) and `docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`
(insert and inventory); `StoreIdentity` is consumed by
`docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`
as a manifest field. If that plan lands first, it adds the newtype exactly as shown here and
this plan finds it present.
