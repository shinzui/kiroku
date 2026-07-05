---
id: 68
slug: document-kiroku-migration-authoring-verification-and-forward-only-recovery
title: "Document kiroku migration authoring verification and forward-only recovery"
kind: exec-plan
created_at: 2026-07-05T19:09:18Z
intention: "intention_01kwstss55e79aafxgtcw6631j"
master_plan: "docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md"
---

# Document kiroku migration authoring verification and forward-only recovery

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `kiroku-store-migrations` package owns the PostgreSQL schema evolution for Kiroku, an
event-store library written in Haskell. Today its only documentation, the package README at
`kiroku-store-migrations/README.md`, explains a single thing: how to *apply* the embedded
migrations by running the `kiroku-store-migrate` executable with codd's `CODD_*` environment
variables. It says nothing about how to *author* a new migration safely, and it ends with a
paragraph that explicitly disclaims the existence of any schema-drift verification:

> This first implementation runs without codd expected-schema verification because Kiroku
> does not yet ship a checked-in codd expected-schema snapshot. `CODD_EXPECTED_SCHEMA_DIR`
> is still required by codd's settings parser, but this executable does not read from it.

Two sibling ExecPlans in this initiative make that world obsolete. EP-1
(`docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md`) adds a
`kiroku-store-migrate new "<description>"` subcommand that scaffolds a correctly-named,
schema-qualified migration file for you, so you never again hand-type a filename. EP-2
(`docs/plans/67-add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations.md`)
adds a checked-in expected-schema snapshot and a strict test that fails on *any*
un-snapshotted schema change, plus a `kiroku-write-expected-schema` tool to regenerate that
snapshot. After those two land, the README's disclaimer is simply false.

This ExecPlan (EP-3, the documentation stream) owns turning that false paragraph into an
authoritative, single-source guide. After this change a contributor who reads only
`kiroku-store-migrations/README.md` can: (1) **author** a new migration with the scaffolder and
understand exactly why the filename rules exist and what they must never do; (2) **verify** that
their change did not silently alter the schema, by regenerating and diffing the drift snapshot
and running the strict test; (3) understand the **`ledger-fixups/` discipline** — why renaming
a shipped migration is dangerous, and how the one existing repair script
(`kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`) is
the template for doing it safely; and (4) **recover** when a migration has already run in
production and turned out wrong, using the forward-only recovery runbook. The `CHANGELOG.md`
records the new tooling.

You can see the work is done when: a reader following the README can run
`kiroku-store-migrate new "add widget index"` and get a real-UTC-timestamped file; run
`kiroku-write-expected-schema` and `cabal test kiroku-store-migrations-test` and observe the
drift gate pass, then fail after they perturb the schema; find no stale "no snapshot yet"
sentence anywhere (`grep -rn "does not yet ship" kiroku-store-migrations/README.md` returns
nothing); and the CHANGELOG's `## Unreleased` section names the scaffolder and the drift gate.

This is a **documentation-only** plan. It edits two Markdown files
(`kiroku-store-migrations/README.md` and `kiroku-store-migrations/CHANGELOG.md`) and writes no
Haskell and ships no SQL of its own. It *references* the tooling delivered by EP-1 and EP-2 but
does not author it — that boundary is deliberate and restated throughout. Because the docs
describe EP-1's and EP-2's observable surfaces, this plan may be **drafted** any time but must
be **finalized** only after EP-1 and EP-2 land, with every documented command actually run and
its real transcript pasted in, so the docs are verified rather than aspirational.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: README "no snapshot yet" disclaimer replaced by the drift-gate / verification workflow; the false `CODD_EXPECTED_SCHEMA_DIR`-is-unused text corrected.
- [x] Milestone 2: README authoring guide added — `kiroku-store-migrate new`, the filename rules enforced by `migrationFileNameSpec` and *why*, and the `embedDir` recompile caveat.
- [x] Milestone 3: README `ledger-fixups/` discipline section and forward-only recovery runbook added.
- [x] Milestone 4: `CHANGELOG.md` `## Unreleased` entries added for the scaffolder and the drift gate.
- [x] Finalization: every documented command executed against the delivered EP-1/EP-2 tooling and its real transcript reconciled into the README; no invented output remains. Confirmed: `cabal run kiroku-store-migrate -- new "…"` prints `Created sql-migrations/2026-07-05-21-11-13-doc-verification-scratch-migration.sql` + the embed reminder (default-dir form pasted into the README); snapshot dir is `expected-schema/v18/`; the apply path is verbatim `runKirokuMigrationsNoCheck` and does not read `CODD_EXPECTED_SCHEMA_DIR`; `cabal test kiroku-store-migrations-test` → 6 examples, 0 failures including the StrictCheck drift example. The scratch migration was removed and the tree left clean.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-05: The README's closing paragraph becomes *false* the moment EP-2 lands. Its exact
  words are "This first implementation runs without codd expected-schema verification because
  Kiroku does not yet ship a checked-in codd expected-schema snapshot" and
  "`CODD_EXPECTED_SCHEMA_DIR` … this executable does not read from it"
  (`kiroku-store-migrations/README.md:35-40`). EP-2 ships the snapshot under
  `kiroku-store-migrations/expected-schema/v18/` and a strict test that enforces it, so the
  first sentence is wrong; the second sentence is *subtle* — the drift gate is enforced by the
  **test suite** (via `onDiskReps = Left <dir>` wired in code) and the `kiroku-write-expected-schema`
  tool, not necessarily by the apply executable reading the env var. The rewrite must correct
  the "no snapshot" claim without over-claiming that the apply executable now verifies at apply
  time. This is flagged for reconciliation against EP-1/EP-2's final `app/Main.hs` behavior.
- 2026-07-05: The `ledger-fixups/` artifact already documents the load-bearing invariant this
  plan must teach. Its header comment
  (`kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql:1-28`)
  states in plain English that "codd decides whether a migration is already applied by FILENAME
  (`SELECT … FROM codd_schema.sql_migrations WHERE name = ?`)", gives the "WHEN TO RUN"
  guidance (once per long-lived DB, before the next migrate; ephemeral/test DBs never need it;
  downstream combined ledgers like keiro's are included), and states the safety properties
  (1:1 remap, idempotent, transactional). The README section can quote and point at this file
  rather than re-deriving the discipline.
- 2026-07-05: kiroku's migrations mix two qualification styles. The **bootstrap** migration
  (`sql-migrations/2026-05-16-12-17-14-kiroku-bootstrap.sql:14-15`) does `CREATE SCHEMA IF NOT
  EXISTS kiroku;` then `SET search_path TO kiroku, pg_catalog;` and uses unqualified names,
  while **incremental** migrations hard-qualify (`sql-migrations/2026-06-24-09-42-22-stream-truncate-before.sql:7`
  writes `ALTER TABLE kiroku.streams …`). The authoring guide must tell new authors to follow
  the *incremental* convention (hard-qualify `kiroku.<table>`, idempotent DDL) — which is what
  EP-1's scaffolder emits. Confirm the exact scaffolded skeleton against EP-1 before finalizing.


## Decision Log

Record every decision made while working on the plan.

- Decision: Scope this plan to **documentation only** — edit `kiroku-store-migrations/README.md`
  and `kiroku-store-migrations/CHANGELOG.md`, and nothing else. Write no Haskell and author no
  SQL; reference EP-1's scaffolder and EP-2's drift-gate tooling and the existing
  `ledger-fixups/` script by path.
  Rationale: The MasterPlan
  (`docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md`,
  Decomposition Strategy) assigns all user-facing prose to EP-3 and keeps the code in EP-1/EP-2
  so each stream has a single review surface. Keeping SQL and Haskell out of this plan prevents
  the docs and the code from drifting apart: the docs point at one source of truth for *what*
  runs.
  Date: 2026-07-05

- Decision: **Draft any time, finalize only after EP-1 and EP-2 land.** Every command transcript
  and file path this plan documents must be reconciled against the delivered behavior before the
  plan is marked Complete; run each documented command and paste its real output.
  Rationale: The MasterPlan Dependency Graph makes EP-3 a *soft* dependant of EP-1 and EP-2 — no
  hard dependency (docs can be drafted against the plans themselves), but the docs describe
  EP-1's exact CLI surface/output and EP-2's exact drift-gate workflow, `CODD_*` semantics, and
  snapshot path, so publishing before those land risks documenting names or output that later
  change. At authoring time both siblings are still skeletons, so this plan documents their
  *intended* surface from the MasterPlan Integration Points and flags every place a concrete
  name or transcript must be confirmed.
  Date: 2026-07-05

- Decision: Keep the `ledger-fixups/` discipline **documented, not automated.** The README
  explains when and why to write a one-time ledger-realignment script and points at the existing
  one as a template; it does not ask for tooling to generate such scripts.
  Rationale: Renaming a shipped migration is a rare, operationally sensitive event whose correct
  fix is inherently bespoke (the exact old→new name remap differs each time). The MasterPlan's
  whole thrust is to make renames *unnecessary* by giving authors the `new` scaffolder, so the
  ledger-fixup is a backstop for an event the tooling now prevents — not worth automating. The
  primary guidance is therefore "prefer `new` so you never have to rename," with the fixup
  discipline as the escape hatch.
  Date: 2026-07-05

- Decision: Correct the `CODD_EXPECTED_SCHEMA_DIR`-is-unused sentence **carefully**, framing the
  drift gate as a developer/CI test-time check keyed to the in-repo snapshot directory, and flag
  the apply-executable's exact env-var semantics for reconciliation against EP-1/EP-2.
  Rationale: EP-2 enforces drift via the test suite (`onDiskReps = Left <dir>`) and the write
  tool, not necessarily via the apply executable reading `CODD_EXPECTED_SCHEMA_DIR`. Over-claiming
  that the apply path now verifies at apply time would be wrong if EP-1 keeps the executable's
  apply behavior as `runKirokuMigrationsNoCheck` (which the MasterPlan Integration Points say it
  does: "anything else … keeps the current apply behavior verbatim"). Document what is certainly
  true (the snapshot now exists and is enforced by `cabal test`) and flag the executable detail.
  Date: 2026-07-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-05: EP-3 delivered as a documentation-only change to `README.md` and `CHANGELOG.md`,
  reconciled against the *delivered* EP-1/EP-2 behavior rather than the plans' intended surface.
  The README now walks a contributor end to end: apply → author (`new`, the filename rules and
  why, the `embedDir` recompile caveat) → verify (the `expected-schema/v18/` drift gate, how to
  regenerate, portability, the flag-gate/nix note, and the corrected `CODD_*` semantics) →
  rename (`ledger-fixups/` discipline) → forward-only recovery. The false "does not yet ship a
  snapshot" / "does not read from it" disclaimer is gone (`grep` returns nothing). The
  CHANGELOG's `## Unreleased` names both the scaffolder and the drift gate. Every documented
  command was executed and its real output pasted in — no aspirational transcripts remain.
- All the "confirm against EP-1/EP-2" flags from the authoring-time draft were resolved: the
  apply executable stays `runKirokuMigrationsNoCheck` and does not consult
  `CODD_EXPECTED_SCHEMA_DIR` (so the README frames the drift gate strictly as a test/CI check),
  and the snapshot segment is `v18` (PostgreSQL 18.4 on the dev machine). No `.cabal` `version:`
  bump was made — that is a separate release action.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**What Kiroku is.** Kiroku is a PostgreSQL-backed event-store library written in Haskell. An
*event store* is a database that records an append-only log of immutable events grouped into
*streams*. Kiroku lives at the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (referred to below by repository-relative
paths). This plan touches exactly one package: `kiroku-store-migrations`, which owns the
database schema and how it changes over time.

**What a PostgreSQL schema is.** A *schema* is a named namespace for tables inside a single
PostgreSQL database (not to be confused with "the shape of the tables"). A table can be
addressed *unqualified* (`streams`) or *qualified* with its schema (`kiroku.streams`). Kiroku
puts all of its objects in a dedicated schema named `kiroku`, leaving the default `public`
schema free for application objects. That schema ownership is already correct and is *not*
changed by this initiative.

**The migrations package layout.** Everything below is under `kiroku-store-migrations/`:

- `sql-migrations/` — the embedded SQL migration files, one per schema change, named
  `YYYY-MM-DD-HH-MM-SS-<slug>.sql`. At authoring time there are seven, from
  `2026-05-16-12-17-14-kiroku-bootstrap.sql` (creates the `kiroku` schema and every table) to
  `2026-06-24-09-42-22-stream-truncate-before.sql`.
- `src/Kiroku/Store/Migrations.hs` — the library. It embeds the whole `sql-migrations/`
  directory at compile time with Template Haskell (`$(embedDir "sql-migrations")` on the last
  line) and exposes `runKirokuMigrations` (the *checked* runner) and
  `runKirokuMigrationsNoCheck` (the *unchecked* runner).
- `app/Main.hs` — builds the `kiroku-store-migrate` executable. Today it calls
  `runKirokuMigrationsNoCheck` unconditionally. EP-1 restructures it to also handle
  `kiroku-store-migrate new "<description>"`.
- `test/Main.hs` — the test suite (`kiroku-store-migrations-test`). It contains
  `migrationFileNameSpec` (the filename guard described below) and a "codd migration spike"
  example that applies the migrations against an ephemeral PostgreSQL and asserts the resulting
  schema with hand-written queries.
- `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql` — a one-time repair script
  (explained below).
- `README.md` and `CHANGELOG.md` — the two files this plan edits.

**What codd is, and its two load-bearing properties.** Kiroku applies migrations through
**codd** (`mzabani/codd`), a migration runner. Two of codd's properties dominate everything in
this plan, so define them precisely:

1. **codd is forward-only.** codd applies ordered migration files and records which ran in a
   *ledger table*, `codd_schema.sql_migrations`. It has **no `down`/rollback step**. Once a
   migration has run against a database, reverting the Haskell package (checking out an older
   commit, downgrading the dependency) does **not** undo the database change. You recover only
   by restoring from a backup or by shipping *another forward* migration. This is why the
   existing README already warns "codd is forward-only" — this plan expands that one sentence
   into a real recovery runbook.

2. **codd keys applied-status by FILENAME, with no body checksum.** codd decides whether a
   migration is already applied by looking up its file *name* in the ledger
   (`SELECT … FROM codd_schema.sql_migrations WHERE name = ?`). It does **not** hash the file
   body. Two consequences follow, and both drive this plan's docs. First, filenames must sort
   in true authoring order and never collide, because codd orders and de-duplicates by name —
   this is what the filename rules enforce. Second, **renaming a migration that has already run
   somewhere makes codd think the renamed file is brand-new and re-run it**, which is exactly
   the bug the `ledger-fixups/` script exists to repair.

**The filename guard (`migrationFileNameSpec`) and the sentinel history.** The test
`migrationFileNameSpec` in `kiroku-store-migrations/test/Main.hs` is a *reactive* guard: it
rejects migration filenames whose timestamp looks *hand-assigned* rather than sampled from a
wall clock. Concretely (see its Haddock at `test/Main.hs:87-95` and the
`handAssignedTimestamp` helper at `test/Main.hs:136-144`) it fails if a filename's seconds
field is `00`, or if the time is exactly UTC midnight (`HH-MM == 00-00`), and a second example
fails if any two migrations share a timestamp prefix (they must be unique and
strictly-increasing). This guard exists because of a real, recent pain: migrations were
originally named with *sentinel* timestamps like `2026-05-16-00-00-00-kiroku-bootstrap.sql` and
`2026-06-11-00-00-01-…`, which do not sort in true authoring order and collided in codd's
timestamp-keyed ledger. The git history is entirely this cleanup — commits renaming migrations
to real commit-date timestamps (`dac1a0b`, `e1f6c02`), a `renumber` fix for a colliding
timestamp, and the `ledger-fixups/` realignment script that repaired already-migrated
databases. The guard rejects the mistake *after the fact*; EP-1's scaffolder prevents it by
stamping the real current UTC time. This plan documents both: the rule (for authors who edit by
hand or review a PR) and the tool that makes the rule automatic.

**The drift gate (delivered by EP-2).** A *drift gate* is a mechanism that fails a test when
the database schema produced by the migrations no longer matches a checked-in expectation. codd
can capture the shape of a live schema into an on-disk *expected-schema snapshot* (a directory
tree of files describing tables, columns, indexes, constraints, functions, triggers) and later
compare a freshly-migrated database against it. Today kiroku has **no** such snapshot: the test
uses an empty in-memory representation (`onDiskReps = Right (DbRep Null Map.empty Map.empty)` at
`test/Main.hs:168`) and only ever calls `runKirokuMigrationsNoCheck`, so a migration that
silently drops a column or alters a constraint the hand-written `assert*` queries do not happen
to probe is caught by nothing. EP-2 adds the snapshot under
`kiroku-store-migrations/expected-schema/v18/`, wires `runKirokuMigrations` to
`onDiskReps = Left <that dir>`, adds a `StrictCheck` test example that fails on *any*
un-snapshotted change, and ships a `kiroku-write-expected-schema` executable to (re)generate the
snapshot. The snapshot is **portable**: EP-2 pins the ephemeral-PostgreSQL superuser to a fixed
`kiroku` identity so the captured role/owner is deterministic and `cabal test
kiroku-store-migrations-test` passes on any machine (codd always records the connecting role and
the database owner, so a machine-specific OS username would otherwise leak into the snapshot and
break other machines). EP-2 also gates the new executable behind a cabal flag
(`expected-schema-tool`, default on) that is turned **off** under nix, so the non-building
`ephemeral-pg` dependency never enters the `nix build .#kiroku-store-migrations` closure. This
plan documents the *workflow* around that gate; it does not build it.

**The sibling ExecPlans (this initiative).** This plan is EP-3 of MasterPlan
`docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md`.
The other two, under `docs/plans/`, are:

- **EP-1** — `docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md`.
  Adds `kiroku-store-migrate new "<description>"`, backed by a new
  `Kiroku.Store.Migrations.New` module, which stamps the real current UTC time to the second and
  emits a `kiroku.`-qualified, idempotent SQL skeleton, plus a round-trip test proving the
  output passes `migrationFileNameSpec`. Its direct model is keiro's already-shipped
  `Keiro.Migrations.New` (`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/src/Keiro/Migrations/New.hs`),
  whose `new` subcommand prints `Created <path>` followed by a reminder to touch the embed
  comment so `embedDir` recompiles. **Soft dependency** — this plan documents that CLI surface
  and its output.

- **EP-2** — `docs/plans/67-add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations.md`.
  Adds the portable drift gate described above: the `kiroku-write-expected-schema` executable,
  the `expected-schema/v18/` snapshot, the `StrictCheck` test, the pinned `kiroku` identity, and
  the cabal-flag + nix-overlay gating. **Soft dependency** — this plan documents the regenerate/
  verify workflow, the `CODD_*` semantics, and the snapshot's portability guarantee.

**Status of the sibling plans at authoring time.** EP-1 and EP-2 are both still skeletons (their
bodies are the unfilled template). This plan therefore describes their *intended final state*
from the MasterPlan's Vision & Scope and Integration Points, and flags every place where a
concrete command, output line, or path must be confirmed against the sibling plan once it is
fleshed out and landed. The single most important flags: **EP-1's exact `new` output lines** (the
`Created …` path and any recompile-reminder wording), **EP-2's exact snapshot directory** (the
MasterPlan says `expected-schema/v18/`; confirm the `v18` segment), and **whether the apply
executable's `CODD_EXPECTED_SCHEMA_DIR` handling changes** (the MasterPlan says the apply path is
kept "verbatim" as `runKirokuMigrationsNoCheck`, so the env var likely stays unread by the
executable even though the snapshot now exists and is enforced by the test suite).

**The files this plan edits.**

- `kiroku-store-migrations/README.md` — currently documents only the apply path via `CODD_*`
  env vars and ends with the "no snapshot yet" disclaimer (lines 35-40). This plan replaces that
  disclaimer with the drift-gate workflow and adds an authoring guide, the `ledger-fixups/`
  discipline, and a forward-only recovery runbook.
- `kiroku-store-migrations/CHANGELOG.md` — its `## Unreleased` section (line 3) is empty. This
  plan adds entries for the scaffolder (EP-1) and the drift gate (EP-2).


## Plan of Work

The work is four milestones, all inside the two documentation files. Milestones 1–3 rewrite and
extend `kiroku-store-migrations/README.md`; Milestone 4 updates
`kiroku-store-migrations/CHANGELOG.md`. Each milestone is independently verifiable by reading
the file and running the greps in *Concrete Steps*. Because the README is a single continuous
document, do the milestones in order so the final section ordering is coherent: apply → author →
verify → repair/recover, then the CHANGELOG.

Recommended final README section order after all milestones (so a reader meets steady-state use
first, then day-to-day authoring, then the rare repair/recovery cases):

1. Intro + "Applying migrations" (mostly the existing apply text, lightly updated).
2. "Authoring a new migration" (Milestone 2).
3. "Verifying the schema: the drift gate" (Milestone 1 — replaces the disclaimer).
4. "Renaming a migration: the `ledger-fixups/` discipline" (Milestone 3).
5. "Forward-only recovery" (Milestone 3 — expands the existing one-paragraph warning).

Milestone 1 is described first because its *primary act* — deleting the false disclaimer — is
the centerpiece of the plan, even though the resulting section lands third in reading order.


### Milestone 1 — Replace the "no snapshot yet" disclaimer with the drift-gate workflow

**Scope and outcome.** After this milestone, the README's closing disclaimer paragraph
(`kiroku-store-migrations/README.md:35-40`) is gone, replaced by a "Verifying the schema: the
drift gate" section that describes the checked-in `expected-schema/` snapshot, how to regenerate
it, how the strict test enforces it, that the snapshot is portable, that the write tool is
flag-gated so it does not affect `nix build`, and what the `CODD_*` variables now mean for the
checked versus unchecked path. The false sentence "Kiroku does not yet ship a checked-in codd
expected-schema snapshot" no longer appears anywhere.

**What to write.** A new section, roughly:

> ## Verifying the schema: the drift gate
>
> The migration test suite strict-checks the migrated database against a checked-in
> *expected-schema snapshot* under `expected-schema/v18/`. The snapshot is a codd-generated
> directory tree describing every table, column, index, constraint, function, and trigger the
> migrations should produce in the `kiroku` schema. `cabal test kiroku-store-migrations-test`
> applies the embedded migrations to a throwaway PostgreSQL and fails if the live schema differs
> from the snapshot in any way — a dropped column, a renamed index, an altered constraint — even
> one no hand-written assertion happens to probe.
>
> **When you change the schema shape** (add or alter a table, index, constraint, function, or
> trigger via a new migration), regenerate the snapshot and commit the diff:
>
> ```bash
> cd kiroku-store-migrations
> cabal run kiroku-write-expected-schema
> git status                 # shows changes under expected-schema/v18/
> git add expected-schema
> ```
>
> Then run `cabal test kiroku-store-migrations-test` and confirm it passes. Review the
> `git diff` of the snapshot the same way you review code: it should reflect exactly the change
> your migration makes and nothing else. An unexpected diff line is a real schema change you did
> not intend.
>
> **The snapshot is portable.** It is captured under a fixed, machine-independent database
> identity, so the strict test passes on any machine and in CI, not just the author's. You will
> not see your local OS username anywhere in `expected-schema/`.
>
> **The write tool is flag-gated.** `kiroku-write-expected-schema` is built behind a cabal flag
> that is disabled under nix, so it never drags its `ephemeral-pg` dependency into the
> `nix build .#kiroku-store-migrations` closure. `cabal run kiroku-write-expected-schema` works
> in the dev shell; `nix build` does not compile the tool.

**Correcting the `CODD_*` text.** The old disclaimer claimed `CODD_EXPECTED_SCHEMA_DIR` "is
still required by codd's settings parser, but this executable does not read from it." Replace it
with an accurate note that distinguishes the two paths:

> The **drift gate is a developer/CI check**, enforced by `cabal test
> kiroku-store-migrations-test` against the in-repo `expected-schema/v18/` snapshot. It is wired
> in the test (and in the checked runner `runKirokuMigrations`) directly to the snapshot
> directory, not through `CODD_EXPECTED_SCHEMA_DIR`. The **apply path** — the
> `kiroku-store-migrate` executable you run in production — applies the embedded migrations and
> records them in codd's ledger; treat the ledger table `codd_schema.sql_migrations` as the
> source of applied-version truth. [Reconcile against EP-1/EP-2: state precisely whether the
> apply executable now performs any check and whether it reads `CODD_EXPECTED_SCHEMA_DIR`; the
> MasterPlan says the apply path is kept verbatim as an unchecked run, so the env var likely
> stays a codd-settings-parser formality that the executable does not consult.]

Leave the bracketed reconciliation note in the *plan* (not the README); when finalizing, run the
executable and the test, observe the real behavior, and write the confirmed sentence into the
README with no bracket.

**Commands to run (verification).** From `kiroku-store-migrations`:

```bash
grep -n "does not yet ship\|until strict snapshots are added\|does not read from it" README.md
grep -n "expected-schema\|drift gate\|kiroku-write-expected-schema" README.md
```

**Acceptance.** The first grep returns nothing (the disclaimer is gone). The second grep shows
the new drift-gate section. `cabal run kiroku-write-expected-schema` and `cabal test
kiroku-store-migrations-test` (run during finalization) behave exactly as the README describes.


### Milestone 2 — Add the authoring guide: `new`, the filename rules, and the embed caveat

**Scope and outcome.** After this milestone, the README has an "Authoring a new migration"
section that tells a contributor to scaffold with `kiroku-store-migrate new "<description>"`,
explains the filename rules the scaffolder satisfies and *why* codd needs them, and warns about
the Template-Haskell embed recompile caveat.

**What to write.** A new section, roughly:

> ## Authoring a new migration
>
> Do not hand-name migration files. Scaffold them:
>
> ```bash
> cd kiroku-store-migrations
> cabal run kiroku-store-migrate -- new "add widget index"
> ```
>
> This stamps the **real current UTC time to the second** into the filename and writes a
> `kiroku.`-qualified, idempotent SQL skeleton under `sql-migrations/`, printing the path it
> created. Fill in the body with your DDL, keeping it idempotent (`IF NOT EXISTS`, `ADD COLUMN
> IF NOT EXISTS`, etc.) and hard-qualifying every object as `kiroku.<name>`, following the style
> of the existing incremental migrations (for example
> `sql-migrations/2026-06-24-09-42-22-stream-truncate-before.sql`, which does `ALTER TABLE
> kiroku.streams ADD COLUMN IF NOT EXISTS …`).
>
> ### Why the filename must be a real UTC timestamp
>
> codd orders migrations by filename and decides whether a migration has already been applied by
> looking its *name* up in the ledger table `codd_schema.sql_migrations` — it does **not** hash
> the file body. So filenames must sort in true authoring order and must be unique. The
> `YYYY-MM-DD-HH-MM-SS-<slug>.sql` format sorts lexicographically == chronologically because
> every field is fixed-width and zero-padded.
>
> The test `migrationFileNameSpec` in `test/Main.hs` enforces this and rejects names that look
> *hand-assigned* rather than sampled from a clock:
>
> - the seconds field must not be `00`,
> - the time must not be exactly UTC midnight (`HH-MM` not `00-00`),
> - all migration timestamps must be unique and strictly increasing.
>
> These rules exist because migrations were once named with rounded *sentinel* timestamps
> (`…-00-00-00-…`, `…-00-00-01-…`) that did not sort in authoring order and collided in codd's
> timestamp-keyed ledger — a bug that forced a mass rename and a ledger-repair script (see
> "Renaming a migration" below). The scaffolder samples the wall clock, so it never produces a
> sentinel. In the astronomically unlikely event the sampled time lands on a `00`-seconds or
> midnight boundary, nudge the seconds by one; the guard's failure message tells you exactly
> which file offended.
>
> ### Recompile caveat: the migrations are embedded at compile time
>
> `src/Kiroku/Store/Migrations.hs` embeds the whole `sql-migrations/` directory into the library
> at **compile time** with Template Haskell (`$(embedDir "sql-migrations")` on its last line).
> Adding or editing a `.sql` file does **not** by itself cause a recompile, so a stale build can
> run the *old* set of migrations. After scaffolding or editing a migration, force the module to
> rebuild — touch the embed line's module, run `cabal clean`, or edit the file's module comment —
> before running the tests or the executable, so `embedDir` re-captures the directory.

**Reconcile against EP-1.** The exact invocation and output are EP-1's. Confirm at finalization:
whether the subcommand is `cabal run kiroku-store-migrate -- new "<desc>"` or invoked on the
installed binary as `kiroku-store-migrate new "<desc>"`; the exact stdout (keiro's model prints
`Created <path>` plus a recompile reminder — see
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/app/Main.hs`); the exact skeleton body the
scaffolder writes; the slug normalization (keiro lowercases, collapses non-alphanumerics to
single dashes, and ensures a package prefix); and any environment override for the target
directory (keiro uses `KEIRO_MIGRATIONS_DIR`; kiroku's equivalent, if any, must be named from
EP-1). Replace the illustrative transcript with the real one.

**Commands to run (verification).** From `kiroku-store-migrations`:

```bash
grep -n "Authoring a new migration\|migrationFileNameSpec\|embedDir\|sentinel" README.md
cabal run kiroku-store-migrate -- new "doc verification scratch migration"
```

**Acceptance.** The grep shows the authoring section. Running `new` prints a path whose filename
is a real (non-`00`-seconds, non-midnight) UTC timestamp, and `cabal test
kiroku-store-migrations-test` still passes with that scratch file present (delete the scratch
file afterward — see *Idempotence and Recovery*). The documented transcript matches the real
output.


### Milestone 3 — Document the `ledger-fixups/` discipline and forward-only recovery

**Scope and outcome.** After this milestone, the README has two more sections: one explaining
the `ledger-fixups/` discipline for the rare case of renaming a shipped migration, and one
expanding the existing single-paragraph forward-only warning into a real recovery runbook.

**What to write — the ledger-fixups discipline.** A new section, roughly:

> ## Renaming a migration: the `ledger-fixups/` discipline
>
> **Prefer never to rename a migration.** Because you scaffold with `new`, filenames are correct
> from birth and there is nothing to rename. This section is the escape hatch for the rare case
> where a migration that has *already run* on a long-lived database must be renamed anyway (for
> example, to repair a historical sentinel name).
>
> codd identifies an applied migration by its **filename**, with no body checksum. Renaming a
> shipped file therefore makes codd believe the renamed file is a brand-new, un-applied
> migration and re-run it — which for a non-idempotent migration corrupts the database, and even
> for an idempotent one leaves a bogus duplicate ledger row. To rename safely you must, in the
> same change, ship a one-time **ledger-fixup**: a transactional, idempotent SQL script that
> `UPDATE`s the `name` (and `migration_timestamp`) columns of `codd_schema.sql_migrations` from
> the old identity to the new one, so codd sees the renamed migrations as already applied and
> skips them.
>
> The repository already contains the template:
> `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`. It was written when the
> migrations were renamed from sentinel timestamps to real authoring times. Model any new fixup
> on it:
>
> - **Transactional** — wrap the whole script in `BEGIN; … COMMIT;` so it is all-or-nothing.
> - **Idempotent** — remap each row 1:1 onto brand-new values, so a second run matches no rows
>   and neither `UNIQUE(name)` nor `UNIQUE(migration_timestamp)` can be violated.
> - **Bookkeeping only** — it changes codd's ledger, never your schema.
>
> **When to run a ledger-fixup:** once per long-lived database (staging, production, persistent
> local), **before** the next `kiroku-store-migrate` run that carries the renamed files. This
> includes downstream databases that ran kiroku's migrations bundled with a consumer's own
> ledger — for example keiro, which maintains a *combined* kiroku↔keiro ledger; the fixup's new
> timestamps are chosen not to collide with keiro's rows. **Ephemeral and template-per-suite
> test databases never need it** — they apply every migration from scratch under the new names.
>
> Apply a fixup inside a transaction with `psql`:
>
> ```bash
> psql "host=/tmp port=5432 dbname=kiroku user=kiroku_admin" \
>   --single-transaction \
>   --file=kiroku-store-migrations/ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql
> ```
>
> Note: this codd builds its ledger as `codd_schema.sql_migrations`. If a future codd version
> uses the `codd` schema instead, replace the schema qualifier throughout (`codd.sql_migrations`)
> — the existing fixup's header says the same.

**What to write — forward-only recovery.** Expand the existing paragraph (currently
`README.md:31-33`, "codd is forward-only. … restoring from backup or by shipping another forward
migration") into a section, roughly:

> ## Forward-only recovery
>
> codd has no `down`/rollback step. Once a migration has run against a database, reverting the
> Haskell package (checking out an older commit, downgrading `kiroku-store-migrations`) does
> **not** undo the database change — the schema stays changed and codd's ledger still records the
> migration as applied. There are exactly two ways to recover from a bad migration that has
> already run in production:
>
> 1. **Restore from backup.** If you took a backup before migrating (always do, for a persistent
>    database), restore it. This is the only way to *remove* a change codd already applied.
>
>    ```bash
>    pg_restore --clean --if-exists --dbname=kiroku kiroku-pre-migrate.dump
>    ```
>
> 2. **Ship another forward migration.** Author a new migration (with `new`) that corrects the
>    problem — dropping the errant column, restoring the constraint — and apply it the normal
>    way. This is the right choice when data written since the bad migration must be preserved.
>
> **How to diagnose.** Inspect codd's ledger to see exactly what ran and when:
>
> ```sql
> SELECT name, migration_timestamp
> FROM codd_schema.sql_migrations
> ORDER BY migration_timestamp;
> ```
>
> To detect *drift* — a database whose schema no longer matches the migrations — run the strict
> gate against a fresh throwaway database (`cabal test kiroku-store-migrations-test`) and, for a
> live database, compare its shape to the checked-in `expected-schema/v18/` snapshot. A failing
> strict test or a snapshot mismatch tells you the schema changed out from under the migration
> history.

**Reconcile against EP-2.** Confirm the snapshot path segment (`v18`) and the exact strict-test
command at finalization.

**Commands to run (verification).** From `kiroku-store-migrations`:

```bash
grep -n "ledger-fixups\|forward-only\|codd_schema.sql_migrations\|pg_restore" README.md
```

**Acceptance.** The grep shows both new sections. A reader can, from the README alone, (a) see
why renaming a shipped migration is dangerous and how the existing fixup script repairs it, and
(b) diagnose and recover from a bad migration without leaving the page.


### Milestone 4 — Update the CHANGELOG

**Scope and outcome.** After this milestone, `kiroku-store-migrations/CHANGELOG.md`'s
`## Unreleased` section (currently empty, line 3) records the two new capabilities delivered by
EP-1 and EP-2, in the file's existing Keep-a-Changelog style (the file already uses
`### New Features` subheadings under each version).

**What to write.** Under `## Unreleased`, add:

```markdown
## Unreleased

### New Features

* `kiroku-store-migrate new "<description>"` scaffolds a new migration file stamped with the
  real current UTC time to the second and a schema-qualified, idempotent SQL skeleton, so
  filenames always sort in codd's authoring order and never collide. Backed by the new
  `Kiroku.Store.Migrations.New` module.
* A portable, checked-in codd expected-schema snapshot under `expected-schema/v18/` plus a
  strict drift-gate example in `kiroku-store-migrations-test`: `cabal test
  kiroku-store-migrations-test` now fails on any un-snapshotted schema change. Regenerate the
  snapshot with the new `kiroku-write-expected-schema` executable after a schema-shape change.
  The snapshot is captured under a fixed database identity so the test passes on any machine, and
  the write tool is cabal-flag-gated off under nix so it never enters the `nix build` closure.
```

**Reconcile against EP-1/EP-2.** Confirm the module name (`Kiroku.Store.Migrations.New`), the
executable name (`kiroku-write-expected-schema`), and the snapshot path (`expected-schema/v18/`)
against the delivered plans. Do **not** edit the `version:` field of the `.cabal` file — cutting
a release and bumping the version is a separate release action; this plan only records the
`## Unreleased` entries.

**Commands to run (verification).** From `kiroku-store-migrations`:

```bash
sed -n '/## Unreleased/,/## 0.1.1.0/p' CHANGELOG.md
```

**Acceptance.** The `## Unreleased` section names both the scaffolder and the drift gate.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations`
unless stated otherwise. This plan edits Markdown only; there is nothing to compile. The
verification commands that invoke `cabal` require the EP-1/EP-2 tooling to be present, so run
them at **finalization** (after the siblings land) and paste the real transcripts back into this
section and into the README.

1. **Survey the current state** so you can compare afterward:

   ```bash
   grep -n "does not yet ship\|CODD_EXPECTED_SCHEMA_DIR\|forward-only" README.md
   sed -n '1,6p' CHANGELOG.md
   ```

   Expected before editing: the README's closing disclaimer (lines 35-40) is present and the
   CHANGELOG's `## Unreleased` section (line 3) is empty.

2. **Milestone 1** — edit `README.md`: delete the disclaimer paragraph and add the
   "Verifying the schema: the drift gate" section and the corrected `CODD_*` note. Re-run:

   ```bash
   grep -n "does not yet ship" README.md      # expect: no output
   grep -n "drift gate" README.md             # expect: the new section
   ```

3. **Milestone 2** — add the "Authoring a new migration" section. Verify:

   ```bash
   grep -n "kiroku-store-migrate -- new\|migrationFileNameSpec\|embedDir" README.md
   ```

4. **Milestone 3** — add the "Renaming a migration" and "Forward-only recovery" sections.
   Verify:

   ```bash
   grep -n "ledger-fixups\|Forward-only recovery" README.md
   ```

5. **Milestone 4** — edit `CHANGELOG.md`'s `## Unreleased` section. Verify:

   ```bash
   sed -n '/## Unreleased/,/## 0.1.1.0/p' CHANGELOG.md
   ```

6. **Finalization (after EP-1 and EP-2 land)** — actually run each documented command and paste
   the real output. Force a rebuild of the embed module first so the tools see the current
   migration set:

   ```bash
   cabal run kiroku-store-migrate -- new "doc verification scratch migration"
   # expect (reconcile exact wording against EP-1): a "Created …/sql-migrations/<real-utc>-…-doc-verification-scratch-migration.sql" line
   cabal run kiroku-write-expected-schema
   git status                                 # expect: changes under expected-schema/v18/ if the scratch file changed the shape
   cabal test kiroku-store-migrations-test    # expect: all examples pass, including the StrictCheck drift example
   ```

   Then delete the scratch migration and regenerate the snapshot so the tree is clean again:

   ```bash
   git checkout -- sql-migrations expected-schema   # or: rm sql-migrations/<the-scratch-file>.sql && cabal run kiroku-write-expected-schema
   cabal test kiroku-store-migrations-test          # expect: still green
   ```

7. **Prove the gate is meaningful** (optional but recommended): perturb the snapshot and confirm
   the strict test fails, then restore it:

   ```bash
   # edit one line under expected-schema/v18/ (e.g. change a column type), then:
   cabal test kiroku-store-migrations-test    # expect: FAIL in the StrictCheck example
   git checkout -- expected-schema            # restore
   cabal test kiroku-store-migrations-test    # expect: green again
   ```

8. **Commit.** Use Conventional Commits and the required trailers:

   ```text
   docs(kiroku-store-migrations): document migration authoring, the drift gate, and forward-only recovery

   Replace the README's "no snapshot yet" disclaimer with an authoring + verification
   guide (kiroku-store-migrate new, the filename rules and why, the embedDir caveat, the
   expected-schema drift gate and how to regenerate it), document the ledger-fixups
   discipline and a forward-only recovery runbook, and record the scaffolder and drift
   gate in the CHANGELOG.

   MasterPlan: docs/masterplans/10-kiroku-migration-robustness-proactive-authoring-a-portable-drift-gate-and-an-operator-runbook.md
   ExecPlan: docs/plans/68-document-kiroku-migration-authoring-verification-and-forward-only-recovery.md
   Intention: intention_01kwstss55e79aafxgtcw6631j
   ```

   Commit directly to the current branch (do not create a feature branch unless asked).


## Validation and Acceptance

Validation for a documentation plan is (a) a set of greps proving no stale claim remains and the
new sections exist, and (b) actually **running every documented command** against the delivered
EP-1/EP-2 tooling and confirming its real output matches the README. All commands run from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store-migrations`.

**The stale-claim check.**

```bash
grep -n "does not yet ship\|until strict snapshots are added\|does not read from it" README.md
```

Expected: nothing. Any hit is a surviving fragment of the false disclaimer and must be removed.

**The new-sections check.**

```bash
grep -n "Authoring a new migration" README.md
grep -n "Verifying the schema" README.md
grep -n "ledger-fixups" README.md
grep -n "Forward-only recovery" README.md
```

Expected: each returns a hit — the four sections this plan adds all exist.

**The CHANGELOG check.**

```bash
sed -n '/## Unreleased/,/## 0.1.1.0/p' CHANGELOG.md
```

Expected: the `## Unreleased` section names both the `kiroku-store-migrate new` scaffolder and
the `expected-schema/` drift gate.

**The command-parity check (the crux — run at finalization, after EP-1/EP-2 land).** Every
command the README shows must be executed and observed to behave as documented. This is what
makes the docs *verified* rather than aspirational:

- `cabal run kiroku-store-migrate -- new "<desc>"` produces a file whose name is a real UTC
  timestamp that passes `migrationFileNameSpec` (non-`00`-seconds, non-midnight, unique). Paste
  the real `Created …` line into the README, replacing the illustrative one.
- `cabal run kiroku-write-expected-schema` regenerates `expected-schema/v18/` and `git status`
  shows the change; confirm the path segment (`v18`) matches EP-2's delivery.
- `cabal test kiroku-store-migrations-test` passes with the snapshot in place, and **fails** when
  one snapshot line is perturbed — proving the gate is meaningful.
- The `codd_schema.sql_migrations` diagnostic query and the `ledger-fixups/` `psql` invocation
  are syntactically valid against the shipped script
  (`ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`).

**The ultimate acceptance signal.** A reviewer who reads **only** `kiroku-store-migrations/README.md`
— with no other repo knowledge — can (1) author a new migration, (2) verify it did not drift the
schema, and (3) recover from a bad migration. If any of those three requires knowledge not on the
page, the page is incomplete and the milestone is not done.


## Idempotence and Recovery

Every step in this plan edits text, so every step is idempotent. Re-running an edit that has
already been made is a no-op (the target string is already changed); re-running a grep is always
safe; re-running `sed -n` prints the same slice. If a sibling plan's final names or output change
after this plan is finalized, re-open the affected milestone, re-run the greps, and update the
README — the checks in *Validation and Acceptance* surface the drift.

The finalization commands (Concrete Steps 6–7) touch the working tree and a throwaway database,
so they need a cleanup path. Two things to keep clean:

- **The scratch migration** created by `cabal run kiroku-store-migrate -- new …` is a real file
  under `sql-migrations/`. Delete it (`git checkout -- sql-migrations` or `rm` the specific file)
  and regenerate the snapshot before committing, so the doc-verification run leaves no artifact.
- **The perturbed snapshot** used to prove the gate is meaningful is restored with
  `git checkout -- expected-schema`, after which `cabal test kiroku-store-migrations-test` is
  green again.

No step in this documentation plan touches a persistent database. The `pg_restore`,
`ledger-fixups` `psql`, and `pg_dump` commands appear only *inside the README as documentation
for operators*; this plan does not run them against any real database. The *procedures the README
documents* are themselves designed to be safe: the ledger-fixup is transactional (all-or-nothing)
and idempotent (a second run matches no rows), exactly like the shipped
`ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`; and the forward-only recovery
runbook mandates a backup before migrating and gives a `pg_restore` rollback path.


## Interfaces and Dependencies

This plan produces documentation, so its "interfaces" are the files it must leave in a
consistent state and the sibling-plan surfaces it must reference correctly.

**Files that must exist / be updated at the end.**

- `kiroku-store-migrations/README.md` — apply path (lightly updated), plus the four new
  sections: authoring, drift-gate verification, the `ledger-fixups/` discipline, and
  forward-only recovery. The "no snapshot yet" disclaimer is gone.
- `kiroku-store-migrations/CHANGELOG.md` — `## Unreleased` names the scaffolder and the drift
  gate. The `.cabal` `version:` is **not** edited here.

**The tooling surfaces this plan references (owned by the siblings).** This plan names these
identifiers and commands; their final spelling must be confirmed against the delivered code:

- From **EP-1** (`docs/plans/66-add-a-kiroku-migration-scaffolder-that-stamps-real-utc-timestamps.md`):
  the `kiroku-store-migrate new "<description>"` subcommand; the `Kiroku.Store.Migrations.New`
  module; the exact stdout of `new` (a `Created <path>` line and any recompile reminder); the
  scaffolded skeleton body (`kiroku.`-qualified, idempotent); the slug normalization; and any
  migrations-directory environment override. The plan documents the *unchanged* filename contract
  enforced by `migrationFileNameSpec` in `kiroku-store-migrations/test/Main.hs` — no plan may
  relax that guard.
- From **EP-2** (`docs/plans/67-add-a-portable-strict-codd-expected-schema-drift-gate-for-kiroku-migrations.md`):
  the `kiroku-write-expected-schema` executable; the `expected-schema/v18/` snapshot directory
  (confirm the `v18` segment); the `StrictCheck` example in `kiroku-store-migrations-test`; the
  checked runner `runKirokuMigrations` wired to `onDiskReps = Left <dir>` in
  `src/Kiroku/Store/Migrations.hs`; the pinned `kiroku` database identity that makes the snapshot
  portable; and the cabal `flag expected-schema-tool` + nix-overlay gating that keeps the write
  tool out of the `nix build` closure. The plan documents the *workflow* around these; it does
  not build them.
- From the **existing repository** (already checked in): the `ledger-fixups/2026-07-05-realign-kiroku-migration-timestamps.sql`
  script (the template for the rename discipline) and codd's ledger table
  `codd_schema.sql_migrations` (the applied-version source of truth and the diagnostic surface).

**Dependency and sequencing (from the MasterPlan Dependency Graph).** This plan **soft-depends**
on EP-1 and EP-2: no hard dependency (it can be drafted against the plans themselves), but it must
be **finalized only after EP-1 and EP-2 land**, with every command transcript and file path
reconciled against the delivered behavior before it is marked Complete. At authoring time both
siblings are skeletons, so this plan documents their intended surface from the MasterPlan
Integration Points and flags each concrete name, output line, and path as "confirm against EP-1/
EP-2 final output." The finalization pass (Concrete Steps 6–7, and the command-parity check in
*Validation and Acceptance*) is the gate that turns those flags into confirmed prose.
