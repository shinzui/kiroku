---
id: 10
slug: kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook
title: "Kiroku migration robustness: proactive authoring, a portable drift gate, and an operator runbook"
kind: master-plan
created_at: 2026-07-05T19:09:05Z
intention: "intention_01kwstss55e79aafxgtcw6631j"
---

# Kiroku migration robustness: proactive authoring, a portable drift gate, and an operator runbook

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku is an event-store library written in Haskell (`shinzui/kiroku`). Its PostgreSQL
schema evolution lives in the `kiroku-store-migrations` package, which embeds a set of
timestamped SQL files (`kiroku-store-migrations/sql-migrations/*.sql`) and applies them
through **codd** (the migration runner, `mzabani/codd`). codd is forward-only and keys a
migration's applied-status by **filename** in its ledger table (`codd_schema.sql_migrations`),
with no body checksum. A PostgreSQL *schema* is a namespace inside one database; kiroku
already does schema ownership correctly — its bootstrap issues `CREATE SCHEMA IF NOT EXISTS
kiroku;`, every incremental migration hard-qualifies `kiroku.<table>`, codd is scoped to
`namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]`, and it captures no extra roles.

This initiative is the kiroku counterpart of keiro's MasterPlan 12
(`/Users/shinzui/Keikaku/bokuno/keiro/docs/masterplans/12-keiro-schema-separation-and-migration-architecture-rework.md`),
adapted to kiroku's *own* distinct gaps. A literal port of MP-12 does not apply: MP-12's
three core concerns — schema separation, runtime query qualification, and a configurable
projection schema — are either already done in kiroku (which MP-12 explicitly treats as the
*model* of good practice) or are keiro-application concerns that do not exist here. What
kiroku lacks is the robustness machinery *around* its already-clean migrations. Research
surfaced three concrete gaps:

1. **No proactive authoring tooling.** The `kiroku-store-migrate` executable only *applies*
   migrations; there is no `new` subcommand to scaffold a correctly-named migration file.
   Every migration filename has been hand-typed, which produced a recurring class of bug:
   hand-assigned *sentinel* timestamps (`…-00-00-00-…`, `…-00-00-01-…`) that do not sort in
   true authoring order and collided in codd's timestamp-keyed ledger. The recent git
   history is entirely this pain — commits renaming migrations to real commit-date
   timestamps, a `renumber` fix for a colliding timestamp, and a
   `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql` script to repair
   already-migrated databases — culminating in a **reactive** guard test
   (`migrationFileNameSpec` in `kiroku-store-migrations/test/Main.hs`) that *rejects*
   sentinels after the fact but does nothing to help authors produce correct names.

2. **No schema-drift gate.** The migration test uses `onDiskReps = Right (DbRep Null
   Map.empty Map.empty)` (an empty in-memory representation) and only ever calls
   `runKirokuMigrationsNoCheck`; nothing compares the migrated database's actual shape
   against a checked-in expectation. The README states this outright: "Kiroku does not yet
   ship a checked-in codd expected-schema snapshot … Operators should treat the migration
   table as the source of applied-version truth until strict snapshots are added." A
   migration that silently changes the schema — a dropped column, a renamed index, an
   altered constraint that the hand-written `assert*` queries do not happen to probe — is
   caught by nothing. keiro built exactly this gate for itself (its `keiro-write-expected-schema`
   executable, `expected-schema/v18/` snapshot, and a `StrictCheck` test); kiroku has none of
   it. The checked runner `runKirokuMigrations` exists but is unused and unbacked by any
   snapshot.

3. **Stale, incomplete operator documentation.** The README documents only the *apply* path
   and explicitly disclaims the (missing) drift gate; there is no authoring guide, no
   drift-gate workflow, no explanation of the `ledger-fixups/` discipline, and no
   forward-only recovery runbook. An operator or contributor has no single place that
   explains how to add a migration safely, how to regenerate and verify the snapshot, or
   what to do when a migration goes wrong in production.

**After this initiative**, kiroku's migrations are *bulletproof* along every axis a
forward-only, filename-keyed migration system can fail:

- **Authoring is proactive, not reactive.** `kiroku-store-migrate new "<description>"`
  scaffolds a migration file stamped with the real current UTC time to the second (so it
  sorts in true authoring order and never collides in codd's ledger) and a
  schema-qualified, idempotent SQL skeleton. The existing `migrationFileNameSpec` guard
  becomes a backstop for a mistake the tooling no longer invites, and a round-trip test
  proves the scaffolder's output passes that guard.

- **Drift is caught mechanically and portably.** A new `kiroku-write-expected-schema`
  executable generates a checked-in codd snapshot under
  `kiroku-store-migrations/expected-schema/v18/`; `runKirokuMigrations` is wired to
  `onDiskReps = Left <dir>`; and the test suite gains a `StrictCheck` example that fails on
  *any* un-snapshotted schema change. The snapshot is **portable from day one**: the
  ephemeral-pg superuser is pinned to a fixed, machine-independent name so the captured
  role/owner identity is deterministic and `cabal test kiroku-store-migrations-test` passes
  on any machine and in CI (not just the author's). A negative test proves the gate is
  meaningful. Critically, the new executable is **gated behind a cabal flag and disabled
  under nix**, so it never drags the non-building `ephemeral-pg` dependency into the
  `nix build` closure (a known kiroku trap — see Integration Points).

- **Operators have a complete runbook.** The README's "no snapshot yet" disclaimer is
  replaced by an authoritative migration-authoring-and-verification guide: how to scaffold
  with `new`, how to regenerate and verify the drift snapshot, the `ledger-fixups/`
  discipline for renamed migrations, and a forward-only recovery procedure. The CHANGELOG
  records the new tooling.

**How you can see it working when the initiative is complete.** Running `kiroku-store-migrate
new "add widget index"` prints the path of a new file under `sql-migrations/` whose name is a
real UTC timestamp (non-sentinel, so it passes `migrationFileNameSpec`) and whose body is a
`kiroku.`-qualified idempotent skeleton; running `cabal run kiroku-write-expected-schema`
followed by `git status` shows a snapshot under
`kiroku-store-migrations/expected-schema/v18/schemas/kiroku/` with a deterministic role/owner
and no machine-specific username anywhere (`grep -R "$(whoami)"
kiroku-store-migrations/expected-schema` finds nothing); `cabal test
kiroku-store-migrations-test` passes on a machine whose OS user is arbitrary, and perturbing
one column in the snapshot makes the strict example fail; `nix build .#kiroku-store-migrations`
still succeeds because the write executable is flag-gated off; and the README's authoring +
recovery runbook walks a contributor through all of it end to end.

**In scope:** the `kiroku-store-migrations` package only — its scaffolder (`app/Main.hs` +
a new `Kiroku.Store.Migrations.New` module), its expected-schema tooling (a new
`kiroku-write-expected-schema` executable, the checked-in snapshot, the `runKirokuMigrations`
wiring, the strict test), the `.cabal` flag and the `nix/haskell-overlay.nix` gate for the
new executable, and all package documentation (README, CHANGELOG, authoring/recovery guide).
**Out of scope:** any change to kiroku's actual schema *shape* (no new tables, columns,
indexes, or DDL semantics — the migrations' SQL bodies are not rewritten); kiroku's runtime
query modules in `kiroku-store` (already qualified and correct); apply-time hardening of the
migration runner itself (advisory-lock tuning, retry policy, statement timeouts — codd owns
the apply path and the user scoped this out; noted as possible future work in the Decision
Log); and any change to downstream consumers (keiro pins kiroku by git SHA and maintains its
own combined ledger and snapshot — see Integration Points for the cross-repo note).


## Decomposition Strategy

The initiative was split by **functional concern**, following the principle that each work
stream produces an independently verifiable behavior and that cross-plan coupling is
minimized. Three concerns emerged naturally, matching the three gaps in the Vision:

1. **Proactive migration authoring** (EP-1). A self-contained tooling concern: give
   `kiroku-store-migrate` a `new` subcommand backed by a new `Kiroku.Store.Migrations.New`
   module that stamps the real current UTC time and emits a qualified, idempotent skeleton,
   plus a round-trip test proving the output satisfies the existing `migrationFileNameSpec`
   guard. It touches the scaffolder code, the executable's argument dispatch, and the test
   file; it does **not** touch schema DDL or the drift gate. It has no dependency on the
   other streams — it can ship first or in parallel. Its direct implementation model is
   keiro's already-shipped `Keiro.Migrations.New`
   (`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/src/Keiro/Migrations/New.hs`).

2. **A portable strict drift gate** (EP-2). The single largest and most valuable stream:
   add codd's on-disk `StrictCheck` gate that kiroku never had. It owns a new
   `kiroku-write-expected-schema` executable, the generated `expected-schema/v18/` snapshot,
   the `runKirokuMigrations` (checked) wiring, a `StrictCheck` test example, the
   ephemeral-pg identity pin that makes the snapshot portable, and the cabal-flag + nix
   overlay gating that keeps the new executable out of the `nix build` closure. Its models
   are keiro's plan 79 (which first *added* keiro's strict gate) and plan 87
   (`/Users/shinzui/Keikaku/bokuno/keiro/docs/plans/87-scope-codd-expected-schema-to-the-keiro-namespace-and-remove-the-role-and-owner-leak.md`,
   which made it portable) — combined, because kiroku is greenfield here and must build the
   gate portable from the first commit rather than shipping-then-fixing a leaky one. It is
   separated from EP-1 because the drift snapshot and the scaffolder are different artifacts
   with different review and test surfaces and no functional dependency on each other.

3. **Documentation and the operator runbook** (EP-3). All user-facing docs: replace the
   README's "no snapshot yet" disclaimer with an authoring-and-verification guide, document
   the `ledger-fixups/` discipline and a forward-only recovery procedure, and update the
   CHANGELOG. It reflects the final state of EP-1 and EP-2, so it is drafted last and
   finalized after they land. Its model is keiro's EP-5
   (`/Users/shinzui/Keikaku/bokuno/keiro/docs/plans/89-document-keiro-schema-separation-and-ship-the-alpha-database-remediation-guide.md`).

**Alternatives considered.** *Merging EP-1 and EP-2* (both touch `test/Main.hs` and the
`.cabal`) was rejected: the scaffolder is a small, self-contained tooling addition, while the
drift gate is a large stream carrying the portability investigation, the nix-closure risk,
and snapshot generation — folding them together would make one plan do the large majority of
the work and starve the other, violating the balance principle, and would couple a quick,
low-risk win (the scaffolder) to a bigger, riskier change. They share two files but edit
disjoint functions (see Integration Points), which is cheap to coordinate. *Splitting EP-2's
portability pin into its own plan* (as keiro did, because keiro already had a leaky snapshot
to fix) was rejected: kiroku has **no** snapshot yet, so building it portable in one stream is
strictly cleaner than deliberately shipping a machine-dependent snapshot and then fixing it —
there is no interim state worth a separate plan. *Folding EP-3's docs into EP-1/EP-2* was
rejected: the runbook spans both streams (authoring *and* verification *and* recovery) and is
best written once, coherently, against their final shapes, rather than as fragments in two
code-focused plans.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add a kiroku migration scaffolder that stamps real UTC timestamps | docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md | None | None | Complete |
| 2 | Add a portable strict codd expected-schema drift gate for kiroku migrations | docs/plans/67-add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations.md | None | None | Complete |
| 3 | Document kiroku migration authoring, verification, and forward-only recovery | docs/plans/68-document-kiroku-migration-authoring-verification-and-forward-only-recovery.md | None | EP-1, EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are **no hard dependencies** in this initiative — a deliberate outcome of the
functional-concern split. EP-1 (scaffolder) and EP-2 (drift gate) touch overlapping files
but edit disjoint functions and have no functional dependency on each other: the scaffolder
produces new migration files but the drift gate does not need the scaffolder to exist, and
the gate verifies the *current* migration set regardless of how those files were authored.
They can therefore proceed **fully in parallel**, by two implementers or in either order.

EP-3 (docs) **soft-depends** on both EP-1 and EP-2. It has no hard dependency because
documentation can be drafted against the plans themselves, but it must be *finalized* only
after EP-1 and EP-2 land, because it documents their final, observable shapes: the exact
`kiroku-store-migrate new` CLI surface and output format (EP-1), and the exact
`kiroku-write-expected-schema` workflow, the `CODD_*` environment surface, and the
drift-gate verification steps (EP-2). If EP-3 is drafted before the others complete, its
command transcripts and file paths must be reconciled against the delivered behavior before
it is marked Complete.

Parallelism summary: EP-1 ∥ EP-2 from the start; EP-3 drafts anytime and finalizes last.
Because both code plans edit `kiroku-store-migrations/test/Main.hs` and
`kiroku-store-migrations/kiroku-store-migrations.cabal`, whichever lands second must rebase
its edits onto the first (the edits are in distinct functions/stanzas — see Integration
Points — so this is a mechanical merge, not a conflict of intent).


## Integration Points

**The migration test file `kiroku-store-migrations/test/Main.hs`.** Both EP-1 and EP-2 edit
this file. It currently contains `migrationFileNameSpec` (the sentinel-timestamp guard),
the `codd migration spike` example (which calls `runKirokuMigrationsNoCheck` and the
hand-written `assert*` placement/index/trigger queries), and `testCoddSettings` (with
`onDiskReps = Right (DbRep Null Map.empty Map.empty)` and `namespacesToCheck = IncludeSchemas
[SqlSchema "kiroku"]`). Ownership split, to keep edits in disjoint functions:
- **EP-1** adds a new `Spec` (e.g. `scaffolderSpec`) that invokes the `Kiroku.Store.Migrations.New`
  API to generate a migration into a temp dir and asserts the generated filename satisfies
  `handAssignedTimestamp` == `False` and is `isTimestampShaped`. EP-1 reuses, and must not
  weaken, the existing `migrationFileNameSpec`.
- **EP-2** changes `testCoddSettings`'s `onDiskReps` from the empty in-memory `DbRep` to
  `Left <expected-schema-dir>`, adds a new `StrictCheck` example (calling the checked
  `runKirokuMigrations`), and introduces the pinned-identity ephemeral-pg helper (a
  `withKirokuPg`-style wrapper around `Pg.startCached` with a fixed `Config.user`, replacing
  the bare `Pg.withCached` in the strict example — see below). EP-2 leaves
  `migrationFileNameSpec` and EP-1's `scaffolderSpec` untouched, and preserves the existing
  `namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]` (kiroku is already correctly
  scoped — unlike keiro, there is **no** re-scoping to do).
Whichever plan lands second rebases onto the first; because the additions are new top-level
`Spec`s / helpers and a single field change, there is no semantic overlap.

**The package cabal file `kiroku-store-migrations/kiroku-store-migrations.cabal`.** Both plans
edit it. **EP-1** adds the `Kiroku.Store.Migrations.New` module to the library's
`exposed-modules` and adds its dependencies (`time` is already present; `directory` and
`filepath` are new) to the `library` and/or `kiroku-store-migrate` executable stanzas, and
adds `directory`/`filepath` to the test stanza for the round-trip test. **EP-2** adds a new
`executable kiroku-write-expected-schema` stanza **and** — critically — a new
`flag expected-schema-tool` (default `True`, `manual: False`) that gates that executable's
`buildable`/dependencies, so nix can turn it off (see the nix integration point). EP-2 also
adds any codd `WriteSchema`/`ephemeral-pg` deps the write executable needs. The stanzas are
disjoint; a second-lander merge is mechanical.

**The `kiroku-store-migrate` executable entrypoint `kiroku-store-migrations/app/Main.hs`.**
Owned by **EP-1**. Today it unconditionally calls `runKirokuMigrationsNoCheck`. EP-1
restructures `main` to dispatch on `getArgs`: `("new" : rest)` scaffolds via
`Kiroku.Store.Migrations.New.newMigrationFile`; anything else (or an `up`/default arg) keeps
the current apply behavior verbatim. EP-2 does **not** touch this file — its write tool is a
*separate* executable (`app/WriteExpectedSchema.hs`), mirroring keiro's split of
`keiro-migrate` from `keiro-write-expected-schema`.

**The migration filename contract.** The single source of truth for what a valid migration
filename is remains `migrationFileNameSpec` in `test/Main.hs`: a `YYYY-MM-DD-HH-MM-SS-<slug>.sql`
prefix that is `isTimestampShaped`, whose seconds field is not `00`, and which is not exactly
UTC midnight. **EP-1's scaffolder is the producer** and must emit names that satisfy this
contract (stamp the real current UTC time to the second; if the sampled time happens to land
on a `00`-seconds or midnight boundary, the author is instructed to nudge it — mirror keiro's
`migrationFileName`). **EP-2's snapshot** is keyed to whatever migration set exists at
generation time; it does not parse filenames but its ledger correctness depends on the same
uniqueness the contract enforces. EP-3 documents the contract. No plan may relax the guard.

**The pinned ephemeral-pg identity (portability).** **EP-2 owns** the choice of the fixed
PostgreSQL superuser name used by `kiroku-write-expected-schema` and the strict test so the
snapshot's captured role/owner is deterministic across machines (codd *always* records the
connecting user's role and the `pg_database` owner — `namespacesToCheck` does not affect
them; see keiro plan 87 for the exact mechanism). The recommended name is the literal
`kiroku` (matching the schema name and keiro's `keiro` precedent). Because
`EphemeralPg.withCachedConfig` is **not exported**, EP-2 must use `Pg.startCached` +
`bracket`/`finally` with `Pg.defaultConfig { Pg.user = "kiroku" }`, not the bare
`Pg.withCached` used today. This identity is **per-repo and independent of keiro's**: keiro's
own combined snapshot captures kiroku's tables under keiro's pinned `keiro` identity via
keiro's own write tool, so kiroku pinning to `kiroku` creates no cross-repo conflict (the two
snapshots are generated by different executables in different repositories). EP-3 documents
the identity so operators understand why the snapshot is machine-independent.

**The nix build closure (a kiroku-specific trap EP-2 must defuse).** `nix build
.#kiroku-store-migrations` builds the package's **library and all executables** (only the
*test suite* is skipped, via `dontCheck` at `nix/haskell-overlay.nix:118`). The new
`kiroku-write-expected-schema` executable depends on `ephemeral-pg`, whose derivation **does
not build** in this repo's pinned nixpkgs Haskell set. Adding the executable naively will
therefore break `nix build`. **EP-2 owns the fix**, following the exact pattern already used
for `kiroku-metrics` at `nix/haskell-overlay.nix:140-158`: gate the executable behind the
cabal `flag expected-schema-tool` (default `True`, so `cabal run kiroku-write-expected-schema`
works in the dev shell) and, in the overlay's `kiroku-store-migrations` derivation
(currently `nix/haskell-overlay.nix:118-120`), wrap it in `overrideCabal (_: { configureFlags
= [ "-f-expected-schema-tool" ]; executableHaskellDepends = [ ]; })`. cabal2nix lists exe
deps regardless of flags, so **both** the flag-off and the emptied `executableHaskellDepends`
are required. Additionally, nix flakes only include **git-tracked** files, so EP-2 must
`git add` the new `WriteExpectedSchema.hs`, the `Kiroku.Store.Migrations.New` module (EP-1),
and the entire generated `expected-schema/` tree before running `nix build`. See the memory
`project_nix_executable_test_dep_closure` for the full rationale.

**The README's disclaimer (owned by EP-3, produced by EP-2).** `kiroku-store-migrations/README.md`
currently ends with a paragraph stating no snapshot ships and that
`CODD_EXPECTED_SCHEMA_DIR` is unused. EP-2's delivery makes that false. EP-2 may leave a
minimal note, but **EP-3 owns** replacing that paragraph with the real drift-gate workflow
(how to regenerate, how the strict test enforces it, what `CODD_*` vars now mean for the
checked path) and adding the authoring guide and recovery runbook.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. These are the initial expected milestones and will be reconciled against
each child plan's own Progress section as they are authored and refined.

- [x] EP-1: `Kiroku.Store.Migrations.New` module added, stamping real UTC timestamps and a qualified idempotent skeleton
- [x] EP-1: `kiroku-store-migrate new "<description>"` subcommand wired into `app/Main.hs`; apply path preserved
- [x] EP-1: Round-trip test proves scaffolder output passes `migrationFileNameSpec`; suite green
- [x] EP-2: `kiroku-write-expected-schema` executable added, gated behind cabal `flag expected-schema-tool`
- [x] EP-2: ephemeral-pg superuser pinned to a fixed `kiroku` identity; portable snapshot generated under `expected-schema/v18/`
- [x] EP-2: `runKirokuMigrations` wired to `onDiskReps = Left <dir>`; `StrictCheck` test example added; negative test proves the gate is meaningful
- [x] EP-2: `nix/haskell-overlay.nix` gates the write executable off (`-f-expected-schema-tool` + emptied `executableHaskellDepends`); `nix build .#kiroku-store-migrations` green
- [ ] EP-3: README "no snapshot yet" disclaimer replaced with the authoring + drift-gate verification guide
- [ ] EP-3: `ledger-fixups/` discipline and forward-only recovery runbook documented; CHANGELOG updated


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-05: A literal port of keiro's MasterPlan 12 does not fit kiroku. MP-12's own text
  repeatedly names kiroku as the *model* of correct schema ownership ("kiroku itself models
  the target pattern and needs no changes — it `CREATE SCHEMA`s and owns its schema … scopes
  codd to its own namespace … captures no roles"). MP-12's three concerns (schema
  separation, runtime qualification, projection-schema config) are already done in kiroku or
  are keiro-application concerns. The kiroku-equivalent is therefore the migration-robustness
  *machinery* MP-12 assumes as a baseline — a scaffolder, a portable drift gate, and docs —
  not MP-12's schema rework. This reframing is the basis of the whole decomposition.
- 2026-07-05: kiroku is *further behind* than keiro on the drift gate, not just missing the
  portability fix. keiro plan 87 records that kiroku "does not use an on-disk strict gate …
  sets `onDiskReps = Right (DbRep Null Map.empty Map.empty)` and runs
  `runKirokuMigrationsNoCheck`, so it never compares against captured roles or db-settings
  and therefore never hits the leak." So EP-2 must both *add* the gate (keiro's plan 79 work)
  **and** make it portable (keiro's plan 87 work) in a single stream — and can build it
  portable from the first commit, with no leaky interim snapshot.
- 2026-07-05: The nix-closure trap is live and directly threatens EP-2. `nix build
  .#kiroku-store-migrations` builds executables (`nix/haskell-overlay.nix:118` only
  `dontCheck`s the test suite), and the overlay already carries the mitigation pattern for
  `kiroku-metrics` (lines 140–158: cabal `flag example` off + emptied
  `executableHaskellDepends`) because `ephemeral-pg` has no buildable derivation in the
  pinned Haskell set. EP-2's new `kiroku-write-expected-schema` executable pulls in
  `ephemeral-pg`, so it must adopt the identical cabal-flag + overrideCabal gating. Recorded
  as a hard constraint in Integration Points. Source: memory
  `project_nix_executable_test_dep_closure`, confirmed against current `nix/haskell-overlay.nix`.
- 2026-07-05 (EP-1/EP-2 landed): The observable surfaces EP-3 must document are now
  **confirmed against delivered behavior**, resolving the "confirm against EP-1/EP-2" flags in
  plan 68: (a) `kiroku-store-migrate new "<desc>"` prints `Created <path>` followed by
  `Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or
  run \`cabal clean\`).` and writes into `KIROKU_MIGRATIONS_DIR` (default `sql-migrations/`);
  (b) the snapshot directory segment is **`v18`** (this machine runs PostgreSQL 18.4);
  (c) the generator is `cabal run kiroku-write-expected-schema` (writes to
  `kiroku-store-migrations/expected-schema` by default); (d) the apply executable's behavior is
  kept verbatim as `runKirokuMigrationsNoCheck` (the drift gate is a **test-time** check via
  `onDiskReps = Left <dir>`, not an apply-time check, and the apply path does not consult
  `CODD_EXPECTED_SCHEMA_DIR`); (e) the strict example is named
  "matches the checked-in expected schema (StrictCheck)".
- 2026-07-05 (EP-1 implementation): the scaffolder template originally specified in plan 66
  contained the literal token `search_path` in an instructional comment, which its own
  round-trip test forbids in the generated body. Reworded to "Do NOT pin the schema search
  path…" — no behavior change. Recorded in plan 66's Surprises. No cross-plan impact.
- 2026-07-05: The recent git history (commits `6bf77ba`, `dac1a0b`, `e1f6c02`, plus the
  `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql` artifact and the
  `migrationFileNameSpec` guard) is entirely the *symptom* of the missing scaffolder (gap 1).
  Hand-typed sentinel timestamps collided in codd's ledger and forced a rename + a ledger
  realignment. EP-1 removes the cause; the existing guard becomes a backstop.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Interpret "an equivalent to keiro's MP-12 to make migrations more robust /
  bulletproof" as targeting kiroku's *own* migration-robustness gaps (proactive authoring,
  a portable drift gate, an operator runbook), **not** as a literal port of MP-12's schema
  separation / runtime qualification / projection-schema concerns.
  Rationale: MP-12 explicitly treats kiroku as the model of correct schema ownership; those
  concerns are already satisfied or non-existent in kiroku. Confirmed with the user during
  planning (scope selection: "Gaps I found"). The user's follow-up "make migrations
  bulletproof" raises the thoroughness bar within this scope rather than re-expanding it.
  Date: 2026-07-05

- Decision: Decompose into three child plans — scaffolder (EP-1), portable drift gate (EP-2),
  docs/runbook (EP-3) — with **no hard dependencies**; EP-1 ∥ EP-2, EP-3 finalizes last.
  Rationale: Functional-concern separation, balanced scope, independent verifiability. The
  scaffolder and the gate are different artifacts with different test/review surfaces and no
  functional coupling, so they parallelize; docs reflect both final states, so they trail.
  See Decomposition Strategy for the merges/splits rejected.
  Date: 2026-07-05

- Decision: Build EP-2's drift gate **portable from the first commit** (pin the ephemeral-pg
  superuser to a fixed `kiroku` identity) rather than shipping a machine-dependent snapshot
  and fixing it in a later plan (as keiro did across plans 79 and 87).
  Rationale: kiroku has no snapshot today, so there is no interim leaky state worth a
  separate plan; building it portable in one stream is strictly cleaner. codd always captures
  the connecting role and DB owner, so portability requires a deterministic pinned identity,
  not zero role files (keiro plan 87's confirmed mechanism).
  Date: 2026-07-05

- Decision: Gate EP-2's new `kiroku-write-expected-schema` executable behind a cabal flag
  (`expected-schema-tool`, default `True`) and disable it in `nix/haskell-overlay.nix`.
  Rationale: `nix build` compiles executables and `ephemeral-pg` has no buildable derivation
  in the pinned Haskell set, so an ungated exe breaks `nix build .#kiroku-store-migrations`.
  The `kiroku-metrics` example (overlay lines 140–158) is the proven in-repo pattern. This is
  the single most important kiroku-specific bulletproofing detail and has no keiro analogue.
  Date: 2026-07-05

- Decision (scoped out): Apply-time hardening of the migration runner — advisory-lock
  tuning, retry policy beyond `singleTryPolicy`, statement timeouts — is **not** in this
  initiative.
  Rationale: The user scoped it out at planning ("Gaps I found", not "Also add apply-time
  safety"), and codd owns the apply path (it already wraps migrations in its ledger + lock).
  Recorded here so it is captured, not silently dropped; a future MasterPlan can take it up if
  operational evidence warrants.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
