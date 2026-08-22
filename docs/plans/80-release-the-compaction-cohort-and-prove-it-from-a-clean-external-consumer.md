---
id: 80
slug: release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer
title: "Release the compaction cohort and prove it from a clean external consumer"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Release the compaction cohort and prove it from a clean external consumer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Everything the compaction initiative built is, until this plan completes, only visible inside
this repository's working tree. The consuming project
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`
consumes `kiroku-store` from Hackage by version bound and is explicitly blocked "until this
request is implemented, released, and inspected from the released source". After this plan, a
team anywhere can add `kiroku-store ^>=0.9`, `kiroku-store-migrations ^>=0.4.1`, and
`kiroku-cli ^>=0.3` to a Cabal project, download them from Hackage, migrate a database to
`0012`, read the store identity, build and preview a compaction manifest, and apply it — and
this plan proves that is true by doing exactly that from an isolated throwaway project that
cannot see this repository. The improvement request IR-14 moves to `completed` only when that
proof is recorded.

To see it working: the witness program in Milestone 5 prints one line naming the released
versions, the store identity, and a manifest digest, after resolving every package from Hackage
into a fresh Cabal store.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `nix fmt` clean, `cabal build all`, `cabal test all`, `just perf-check`, `just test-matrix`, `nix flake check`, `just adr-validate`, `just capabilities-validate` all green on the release candidate commit.
- [ ] M1: `cabal check` clean for each of the six publishable packages, run before any tag exists.
- [ ] M2: Versions chosen and justified; `.cabal` versions and every internal bound updated in library, executable, and test stanzas.
- [ ] M2: Changelog sections dated for each released package; `docs/capabilities/selective-event-compaction.md` `since` confirmed.
- [ ] M2: Blueprint edge `blueprints/kiroku-upgrade/migrations/0-8-to-0-9.md` written and registered in `blueprint.dhall`.
- [ ] M3: Single `chore(release)` commit with per-package justification and the three trailers; six annotated tags; pushed.
- [ ] M4: Pre-upload sdist SHA-256 recorded for each package; packages uploaded in dependency order with documentation; GitHub releases created.
- [ ] M5: Hackage `preferred.json`, tag peel, tarball hash and listing recorded.
- [ ] M5: Clean isolated consumer resolved the exact released versions, built, migrated ephemeral PostgreSQL to `0012`, previewed a manifest, and printed the witness line; transcript recorded here.
- [ ] M5: IR-14 status `implemented` after upload, then `completed` with `completedAt` after the consumer proof; improvement-request `log.md` entry added.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `kiroku-store` 0.8.0.0 → 0.9.0.0 (major).
  Rationale: `KirokuEvent` gains four constructors and `Store` gains five; `kiroku-otel` and
  `kiroku-metrics` match `KirokuEvent` exhaustively under `-Werror=incomplete-patterns`, so
  the change breaks downstream builds (the same situation that made 0.7.0.0 a major release in
  `docs/plans/73-protect-replay-history-with-retention-leases-and-stream-guards.md`). Three new
  exposed modules and new `Kiroku.Store.Types` constructors are additive, but PVP takes the
  strictest component.
  Date: 2026-08-22

- Decision: `kiroku-store-migrations` 0.4.0.0 → 0.4.1.0 (minor).
  Rationale: Migration `0012` is additive, forward-only, needs no operator ledger step, and
  changes no exported Haskell declaration. The precedent is 0.3.0.0 → 0.3.1.0 for migration
  `0009` in `docs/plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md`. This
  package has no dependency on `kiroku-store` (the release skill's overview says otherwise and is
  wrong; the Cabal file is authoritative), so its bump is driven solely by the migration.
  Date: 2026-08-22

- Decision: `kiroku-cli` 0.2.0.6 → 0.3.0.0 (major).
  Rationale: `KirokuCommand` is exported with `(..)` and gains two constructors; any downstream
  exhaustive match breaks. `kiroku-metrics` imports only `SubscriptionStatusRow` and
  `subscriptionStatusRows`, so it compiles unchanged but must widen its bound to `^>=0.3`.
  Date: 2026-08-22

- Decision: `kiroku-otel`, `kiroku-metrics`, and `shibuya-kiroku-adapter` take patch bumps with
  `kiroku-store ^>=0.9` (and `kiroku-cli ^>=0.3` for `kiroku-metrics`).
  Rationale: Their only source change is the no-op `KirokuEvent` arms added by the preview and
  apply plans, invisible to their own consumers; the precedent is release commit `7726d23`,
  where bound widening alone was a patch.
  Date: 2026-08-22

- Decision: Run `cabal check` for every package before creating any tag.
  Rationale: `docs/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory.md`
  records a pushed `kiroku-metrics-v0.1.0.2` tag stranded by a `cabal check` failure discovered
  afterwards; public tags are never moved, so the check must come first.
  Date: 2026-08-22

- Decision: Add a `kiroku-upgrade` blueprint edge `0.8.0.0 → 0.9.0.0`.
  Rationale: Consumers need judgement work Kiroku cannot perform for them: new `KirokuEvent`
  arms, new `KirokuCommand` arms for hosts that match the command tree, migration-count fixtures
  growing from eleven to twelve, and the schema comment changing to `through 0012`. The
  blueprint's version space is `kiroku-store`, and the previous edge is `0.7.0.1 → 0.8.0.0`.
  Date: 2026-08-22

- Decision: The clean-consumer proof exercises preview (not apply) against ephemeral PostgreSQL
  migrated with the released migration plan.
  Rationale: Preview reaches every released surface — identity, manifest construction, digest,
  the `0012` tables, and the `Store` effect — without needing `DELETE` grants or a destructive
  step in a throwaway program; apply is proven exhaustively by the repository suite. The proof
  must build from Hackage in an isolated Cabal store so it cannot accidentally resolve the working
  tree.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a Cabal multi-package project at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (`cabal.project`, GHC 9.12.4). Six
packages are published to Hackage and versioned independently: `kiroku-store` (the event-store
library, currently 0.8.0.0), `kiroku-store-migrations` (the schema as an embedded, numbered
`pg-migrate` plan, 0.4.0.0), `kiroku-otel` (0.2.0.7), `kiroku-cli` (0.2.0.6), `kiroku-metrics`
(0.1.0.8), and `shibuya-kiroku-adapter` (0.5.1.1). `kiroku-test-support` and `kiroku-jitsurei`
are internal and never released. Each package's version is the `version:` line of
`<package>/<package>.cabal`; each has a `CHANGELOG.md` whose newest section is first, headed
`## A.B.C.D — YYYY-MM-DD`, with subsections such as `### Breaking Changes`, `### New Features`,
`### Fixes`, and `### Other Changes`, written as explanatory paragraphs rather than one-liners.
Release tags are annotated and named `<package>-v<version>` (for example `kiroku-store-v0.8.0.0`;
list them with `git tag --list 'kiroku-store-v*'`).

**What this plan releases.** The preceding plans of the MasterPlan delivered, in the working
tree: migration `kiroku-store-migrations/migrations/0012.sql` installing the
`kiroku.store_identity` singleton and the append-only `kiroku.event_compactions` ledger
(`docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md`); the
`lookupEventReferences` read API
(`docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md`); the pure
module `Kiroku.Store.Compaction.Types` with the manifest, digest, refusal, and report types
(`docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`);
`previewCompaction`
(`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`);
`applyCompaction` and `compactionLedger` with the compaction ADR
(`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`);
and the operator guide, capability record, and `kiroku-cli` commands
(`docs/plans/79-document-compaction-for-operators-and-add-embeddable-kiroku-cli-compaction-commands.md`).
All of those must be complete and committed before this plan starts; verify with
`git log --oneline -30` and by reading each plan's Outcomes section.

**The release skill.** `agents/skills/release/SKILL.md` is the repository's release procedure.
Its rules: Package Versioning Policy (PVP) versions are `A.B.C.D`; a *major* bump (change `B`,
reset `C` and `D`) is required for any breaking API change, which includes adding a constructor
to an exported type that downstream code matches exhaustively; a *minor* bump (change `C`, reset
`D`) is for backwards-compatible additions; a *patch* bump (change `D`) is for fixes, docs,
internal changes, and bound widening. Dependents constrain internal packages with caret bounds
`^>=A.B`, and those bounds appear in library, executable, and test-suite stanzas alike. The
publish order is `kiroku-store → kiroku-store-migrations → kiroku-otel → kiroku-cli →
kiroku-metrics → shibuya-kiroku-adapter`. Per package, from its own directory, the steps are
`cabal check`, the explicit test target, `cabal sdist`, `cabal upload --publish <tarball>`,
`cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`, and
`cabal upload --publish --documentation <docs tarball>`; then `gh release create <tag> --title
... --notes ...` with that version's changelog text. The skill says `kiroku-store-migrations`
depends on `kiroku-store`; it does not (its `.cabal` has no such dependency in any stanza), so
treat its bump as independent. Two recorded gotchas: `cabal test kiroku-store-migrations`
resolves to the library target in this multi-package project and is rejected — always use
`<package>:<suite>` (for example `kiroku-store-migrations:kiroku-store-migrations-test`); and
`cabal check` must run before tagging, because a pushed tag is never moved.
`kiroku-store-migrations/README.md` additionally requires `just test-matrix` (PostgreSQL 17 and
18 through `nix develop .#postgresql17` / `.#postgresql18`) before releasing that package,
because `cabal test all` runs only against whichever server is on `PATH`.

**The consumer blueprint.** `blueprints/kiroku-upgrade/` is a Seihou blueprint that tells a
consuming project how to move across a released version window that needs judgement. Its
`blueprint.dhall` lists `migrations = [ S.BlueprintMigration::{ from = "0.7.0.1", to =
"0.8.0.0", prompt = ./migrations/0-7-to-0-8.md as Text } ]`; the version space is
`kiroku-store` even when the work is migration-related. The edge document
`migrations/0-7-to-0-8.md` is the model: a heading `# kiroku-store X → Y`, a summary of which
packages the edge covers, a "Precondition" section saying when the edge is not applicable, then
one "Part" per kind of consumer work with "What changed" and "What to do" subsections.

**The clean external consumer.** There is no script for this; it is a documented manual
procedure whose evidence is recorded in the plan and in the improvement request. The pattern,
established in `docs/plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md` and
repeated in plan 73, is: record the SHA-256 of each sdist before upload; after Hackage's index
refreshes, confirm `https://hackage.haskell.org/package/<package>/preferred.json` reports the
new version, confirm the annotated tag resolves to the release commit with `git ls-remote
--tags`, download the Hackage tarball and compare its hash to the pre-upload sdist, list the
tarball to show the expected new files, and build a throwaway Cabal project in an isolated
`CABAL_DIR` (its own config, index, cache, and store, so nothing can resolve from this
repository or from the shared `~/.cabal` store) that pins the exact released versions and runs a
program exercising the new surface. Plan 72's recorded evidence is the target shape: the tag
object and the commit it peels to, identical SHA-256 for sdist and Hackage archive, the tarball
contents, and the witness line the program printed.

**Improvement request lifecycle.** `docs/improvement-requests/add-manifest-driven-selective-event-compaction.md`
is IR-14 with frontmatter `status: proposed`. Completed requests (for example
`expose-the-visible-global-head.md`) carry `status: completed` and `completedAt: "<UTC
timestamp>"`, and also advance `timestamp`. The convention from plan 72 is: `implemented` once
the packages are uploaded, `completed` only once authoritative Hackage artifacts and the
clean-consumer evidence agree. The bundle's `log.md` receives a dated entry for each transition.
`docs/capabilities/selective-event-compaction.md` carries `since: "0.9.0.0"` written by plan 79;
confirm it matches the released version and run `just capabilities-validate` after any edit.

**Relevant ADRs.** [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes the
structural assertions (`just perf-structure`) and the controlled workload gate (`just
perf-workload-gate`) the authoritative performance evidence; both must pass on the release
commit, and the workload ratio is recorded here (plan 73 observed boundary noise and repeated
the gate per ADR-5 rather than changing it). [ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md)
is the coordination model compaction joins; the release notes must say that apply refuses under
an active lease and uses the coordinator-then-ascending-`stream_id` lock order. The compaction
ADR created by plan 78 (find it with `grep -l "compaction" docs/adr/*.md`) is the durable
decision the changelogs and blueprint edge must restate accurately. The consuming project
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`
stays blocked until Milestone 5's evidence exists; it will inspect the released source through
Mori's registry, so the Hackage source archive — not the working tree — is what it will read.


## Plan of Work

### Milestone 1 — Pre-release verification on the candidate commit

Goal: prove that the commit to be released builds, tests, formats, validates, and passes every
authoritative gate on both supported PostgreSQL majors, and that every package passes `cabal
check`, before any version or tag exists.

Work. From the repository root run, in order, `nix fmt` (must change nothing; check `git status
--short`), `cabal build all`, `cabal test all`, `just perf-check` (structural tier then the
controlled workload gate; record the two ratios it prints, which must be at most `0.90x`, and if
a run is boundary-noisy repeat it on an idle host per ADR-5 rather than editing thresholds),
`just test-matrix` (fourteen suite runs across PostgreSQL 17 and 18; the migrations suite prints
which `uuidv7()` route it exercised on each), `nix flake check`, `just adr-validate`, and `just
capabilities-validate`. Then, for each of the six packages, `cd <package> && cabal check`. Any
failure stops the plan; fix it in an ordinary commit under the owning ExecPlan's trailer and
start Milestone 1 again.

Result and proof: a transcript in Progress naming the commit hash, the example counts, the
matrix outcome, and the workload ratios.

### Milestone 2 — Versions, bounds, changelogs, capability, and blueprint edge

Goal: every released artifact carries its new version, every dependent admits it, and consumers
have a written upgrade path.

Work. Edit `version:` in `kiroku-store/kiroku-store.cabal` to `0.9.0.0`,
`kiroku-store-migrations/kiroku-store-migrations.cabal` to `0.4.1.0`,
`kiroku-cli/kiroku-cli.cabal` to `0.3.0.0`, `kiroku-otel/kiroku-otel.cabal` to `0.2.0.8`,
`kiroku-metrics/kiroku-metrics.cabal` to `0.1.0.9`, and
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` to `0.5.1.2`. Confirm each current value
first with `grep -n '^version' */*.cabal`; if any package has moved since this plan was written,
apply the same PVP reasoning from the current number. Then change every `kiroku-store ^>=0.8`
to `^>=0.9` in `kiroku-otel`, `kiroku-cli`, `kiroku-metrics`, and `shibuya-kiroku-adapter`
(library and test stanzas — `grep -rn 'kiroku-store *\^>=' */*.cabal` lists all of them), and
every `kiroku-cli ^>=0.2` to `^>=0.3` in `kiroku-metrics` (library and test stanzas).
`kiroku-test-support` and `kiroku-jitsurei` also depend on `kiroku-store`; update their bounds
too so the project solves, even though they are not released.

Write the changelog sections, dated with the release day. `kiroku-store/CHANGELOG.md` gets `##
0.9.0.0 — <date>` with "Breaking Changes" (four `KirokuEvent` constructors:
`KirokuEventCompactionPreviewed`, `KirokuEventCompactionRefused`,
`KirokuEventCompactionApplied`, `KirokuEventCompactionAlreadyApplied`; five `Store`
constructors) and "New Features" (the `Kiroku.Store.Compaction` and
`Kiroku.Store.Compaction.Types` modules; `storeIdentity`/`storeIdentityTx`;
`lookupEventReferences`/`lookupEventReferencesTx`; the manifest contract in prose: digest-sealed,
witness-validated, refuses rather than widens, never renumbers, one transaction per manifest,
refuses under an active history-retention lease, ledgered idempotence; a pointer to
`docs/user/compaction.md`). The preceding plans left their text under an `## Unreleased`
heading; fold that text into the dated section rather than rewriting it.
`kiroku-store-migrations/CHANGELOG.md` gets `## 0.4.1.0 — <date>` with "New Features"
describing migration `0012` (both tables, their triggers, the schema comment through `0012`,
the fact that existing databases gain one pending migration and that consumer fixtures asserting
eleven migrations must become twelve). `kiroku-cli/CHANGELOG.md` gets `## 0.3.0.0 — <date>` with
"Breaking Changes" (`KirokuCommand` gains `KirokuCompaction` and `KirokuStore`) and "New
Features" (the four commands, `KirokuCommandOutcome`, `executeKirokuCommandWithStore`, the exit
codes, the standalone refusal). The three patch packages get `## <version> — <date>` with
"Other Changes": the no-op event arms and the widened bounds.

Open `docs/capabilities/selective-event-compaction.md` and confirm `since: "0.9.0.0"` and
`status: shipped`; change nothing else unless the version differs.

Create `blueprints/kiroku-upgrade/migrations/0-8-to-0-9.md`, modelled on `0-7-to-0-8.md`, with
heading `# kiroku-store 0.8.0.0 → 0.9.0.0`, a summary covering the four released packages that
changed shape (`kiroku-store` 0.9.0.0, `kiroku-store-migrations` 0.4.1.0, `kiroku-cli` 0.3.0.0,
and the patch releases), a "Precondition" (not applicable only when the project neither matches
`KirokuEvent` or `KirokuCommand` exhaustively nor runs Kiroku migrations against a persistent
database nor asserts migration counts), and parts: Part A `KirokuEvent` gains four constructors
(what changed, what to do: add explicit arms, typically no-ops, and decide whether to surface the
compaction events in the project's own metrics); Part B `KirokuCommand` gains two constructors
(hosts that `case` on the tree add arms or delegate to `executeKirokuCommandWithStore`; hosts
that only embed `kirokuSubparser` need nothing); Part C migration `0012` (the plan grows from
eleven to twelve, the pending-id fixtures and `drop N` offsets move, the schema comment becomes
`Managed by pg-migrate component kiroku through 0012`, `migrate up` on an existing database
applies one migration, and the project's role needs no new grant unless it will run compaction);
Part D grants for compaction (optional; point to `docs/PRODUCTION-DEPLOYMENT.md`). Register it
in `blueprint.dhall` by appending `, S.BlueprintMigration::{ from = "0.8.0.0", to = "0.9.0.0",
prompt = ./migrations/0-8-to-0-9.md as Text }` to the `migrations` list and bump the blueprint's
`version` to `Some "0.2.0"`. Check the Dhall parses with `dhall --file
blueprints/kiroku-upgrade/blueprint.dhall > /dev/null` (the `dhall` binary is in the dev shell;
if it is absent, `nix flake check` covers the file through the formatter hook — confirm by
looking at `.pre-commit-config.yaml`).

Re-run `cabal build all` and `cabal test all` after the edits (bounds changes can change the
solver's plan). Result and proof: `git diff --stat` shows exactly the six `.cabal` files, the
two unreleased packages' `.cabal` files, six changelogs, the blueprint files, and possibly the
capability file; the project builds and tests.

### Milestone 3 — Release commit, tags, and push

Goal: one reviewable commit records the release, and six annotated tags name it.

Work. Stage everything from Milestone 2 and commit with a message whose body justifies each bump
in one sentence per package, then the three trailers. Example:

```text
chore(release): kiroku-store 0.9.0.0, kiroku-store-migrations 0.4.1.0, kiroku-cli 0.3.0.0, kiroku-otel 0.2.0.8, kiroku-metrics 0.1.0.9, shibuya-kiroku-adapter 0.5.1.2

kiroku-store 0.9.0.0: major because KirokuEvent and Store gain constructors that
downstream adapters match exhaustively; adds Kiroku.Store.Compaction,
Kiroku.Store.Compaction.Types, storeIdentity, and lookupEventReferences.
kiroku-store-migrations 0.4.1.0: minor for the additive forward migration 0012
(store_identity singleton and event_compactions ledger); no operator ledger step.
kiroku-cli 0.3.0.0: major because KirokuCommand gains KirokuCompaction and
KirokuStore; adds compaction preview/apply/ledger and store identity commands.
kiroku-otel 0.2.0.8, kiroku-metrics 0.1.0.9, shibuya-kiroku-adapter 0.5.1.2:
patch for the no-op event arms and kiroku-store ^>=0.9 (kiroku-cli ^>=0.3) bounds.

Verified: nix fmt clean, cabal build all, cabal test all (<N> examples),
just perf-check (<ratio-4>/<ratio-8>), just test-matrix on PostgreSQL 17 and 18,
nix flake check, cabal check on all six packages.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```

Then create the tags and push:

```bash
git tag -a kiroku-store-v0.9.0.0 -m "kiroku-store 0.9.0.0"
git tag -a kiroku-store-migrations-v0.4.1.0 -m "kiroku-store-migrations 0.4.1.0"
git tag -a kiroku-otel-v0.2.0.8 -m "kiroku-otel 0.2.0.8"
git tag -a kiroku-cli-v0.3.0.0 -m "kiroku-cli 0.3.0.0"
git tag -a kiroku-metrics-v0.1.0.9 -m "kiroku-metrics 0.1.0.9"
git tag -a shibuya-kiroku-adapter-v0.5.1.2 -m "shibuya-kiroku-adapter 0.5.1.2"
git push && git push --tags
```

Before tagging, confirm no version is already published: `curl -fsSL
https://hackage.haskell.org/package/kiroku-store/preferred.json` must not list `0.9.0.0`, and
likewise for the other five. Result and proof: `git for-each-ref refs/tags/*-v* --format '%(refname:short) %(objecttype) %(*objectname)'`
shows six `tag` objects peeling to the release commit.

### Milestone 4 — Publish in dependency order

Goal: all six packages and their documentation are on Hackage and GitHub, with pre-upload
hashes recorded.

Work, for each package in the order `kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`,
`kiroku-cli`, `kiroku-metrics`, `shibuya-kiroku-adapter`, from that package's directory:

```bash
cd kiroku-store
cabal check
cabal test kiroku-store:kiroku-store-test
cabal sdist
shasum -a 256 dist-newstyle/sdist/kiroku-store-0.9.0.0.tar.gz   # record in Progress
cabal upload --publish dist-newstyle/sdist/kiroku-store-0.9.0.0.tar.gz
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
cabal upload --publish --documentation dist-newstyle/kiroku-store-0.9.0.0-docs.tar.gz
cd ..
```

The explicit test targets are `kiroku-store-migrations:kiroku-store-migrations-test`,
`kiroku-otel:kiroku-otel-test`, `kiroku-cli:kiroku-cli-test`,
`kiroku-metrics:kiroku-metrics-test`, and `shibuya-kiroku-adapter:shibuya-kiroku-adapter-test`
(confirm names with `grep -n '^test-suite' */*.cabal`). For `kiroku-store-migrations`, also
confirm `tar tzf dist-newstyle/sdist/kiroku-store-migrations-0.4.1.0.tar.gz | grep
migrations/0012.sql` prints the file before uploading — the sdist is governed by the
`extra-source-files: migrations/*.sql` glob, so the new file is included automatically, but the
listing is the evidence. If any upload fails, stop; do not upload its dependents; record the
state in Progress. Then create the GitHub releases:

```bash
gh release create kiroku-store-v0.9.0.0 --title "kiroku-store 0.9.0.0" --notes-file /path/to/notes.md
```

with one invocation per tag and notes extracted from that package's changelog section (a
scratch file per package is fine; do not commit it). Result and proof: six Hackage URLs of the
form `https://hackage.haskell.org/package/<package>-<version>` and six non-draft GitHub
releases, recorded in Progress with the sdist hashes.

### Milestone 5 — Clean external consumer, evidence, and request closure

Goal: an isolated project that cannot see this repository downloads the released packages,
builds, migrates a fresh database to `0012`, reads the store identity, constructs a manifest,
previews it, and prints a witness line; the authoritative artifacts agree with the pre-upload
hashes; IR-14 is closed with that evidence.

Work. Wait for the Hackage index to refresh (minutes), then gather the authoritative facts:

```bash
for p in kiroku-store kiroku-store-migrations kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter; do
  echo "$p: $(curl -fsSL https://hackage.haskell.org/package/$p/preferred.json)"
done
git ls-remote --tags https://github.com/shinzui/kiroku.git 'refs/tags/kiroku-store-v0.9.0.0*'
```

The second command prints two lines: the annotated tag object and the `^{}` peeled commit,
which must equal the release commit. Then, in a scratch directory outside the repository
(`/private/tmp/claude-501/.../scratchpad/kiroku-clean-consumer` or any empty directory),
create an isolated Cabal environment and project:

```bash
export CABAL_DIR="$PWD/cabal-isolated"
mkdir -p "$CABAL_DIR" kiroku-compaction-consumer && cd kiroku-compaction-consumer
cabal update
cabal get kiroku-store-0.9.0.0 --destdir=../downloaded
cabal get kiroku-store-migrations-0.4.1.0 --destdir=../downloaded
tar tzf "$CABAL_DIR/packages/hackage.haskell.org/kiroku-store-migrations/0.4.1.0/kiroku-store-migrations-0.4.1.0.tar.gz" | grep 'migrations/0012.sql'
shasum -a 256 "$CABAL_DIR/packages/hackage.haskell.org/kiroku-store/0.9.0.0/kiroku-store-0.9.0.0.tar.gz"
shasum -a 256 "$CABAL_DIR/packages/hackage.haskell.org/kiroku-store-migrations/0.4.1.0/kiroku-store-migrations-0.4.1.0.tar.gz"
```

Both hashes must equal the pre-upload sdist hashes recorded in Milestone 4. (If `cabal get`
does not populate the package cache at that path on the installed Cabal version, download the
tarballs with `curl -fsSLO https://hackage.haskell.org/package/kiroku-store-0.9.0.0/kiroku-store-0.9.0.0.tar.gz`
and hash those.) Write the project files:

`cabal.project`:

```text
packages: .

constraints:
  kiroku-store == 0.9.0.0,
  kiroku-store-migrations == 0.4.1.0
```

`kiroku-compaction-consumer.cabal`:

```text
cabal-version: 3.0
name:          kiroku-compaction-consumer
version:       0.1.0.0
build-type:    Simple

executable kiroku-compaction-consumer
  main-is:          Main.hs
  default-language: GHC2024
  default-extensions: OverloadedStrings
  ghc-options:      -Wall
  build-depends:
    , base
    , aeson
    , ephemeral-pg          >=0.2
    , hasql
    , kiroku-store          ==0.9.0.0
    , kiroku-store-migrations ==0.4.1.0
    , pg-migrate            ^>=1.1.0.0
    , text
```

`Main.hs` — adjust the exact accessor and constructor names to the released Haddock at
`https://hackage.haskell.org/package/kiroku-store-0.9.0.0/docs/Kiroku-Store-Compaction-Types.html`;
the shape is:

```haskell
module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Kiroku.Store
import Kiroku.Store.Compaction
import Kiroku.Store.Migrations (kirokuMigrationPlan)

main :: IO ()
main = Pg.withCached $ \db -> do
    let connStr = Pg.connectionString db
    plan <- either (fail . show) pure kirokuMigrationPlan
    _ <- runMigrationPlan defaultRunOptions (Conn.connectionString connStr) plan
    withStore (defaultConnectionSettings connStr) $ \store -> do
        Right appended <- runStoreIO store $ do
            _ <- appendToStream (StreamName "consumer-proof") NoStream [sample "One", sample "Two"]
            readStreamForward (StreamName "consumer-proof") (StreamVersion 0) 10
        Right identity <- runStoreIO store storeIdentity
        let middle = appended `atIndex` 0
            Right operation = mkCompactionOperation "clean-consumer/proof"
            input =
                CompactionManifestInput
                    { storeIdentity = identity
                    , operation = operation
                    , deadLetterPolicy = RefuseDeadLetters
                    , causationPolicy = RefuseCausationDependents
                    , streamHeads = [StreamHeadWitness (StreamName "consumer-proof") (StreamVersion 2)]
                    , selections =
                        [ CompactionSelection
                            { eventId = middle.eventId
                            , originStream = StreamName "consumer-proof"
                            , originVersion = middle.streamVersion
                            , globalPosition = middle.globalPosition
                            , acknowledgedLinks = mempty
                            }
                        ]
                    , expectedDigest = Nothing
                    }
        manifest <- either (fail . show) pure (mkCompactionManifest input)
        Right outcome <- runStoreIO store (previewCompaction manifest)
        case outcome of
            Left refusals -> fail ("unexpected refusal: " <> show refusals)
            Right report ->
                TIO.putStrLn $
                    "clean consumer verified: kiroku-store 0.9.0.0, kiroku-store-migrations 0.4.1.0, store "
                        <> T.pack (show identity)
                        <> ", manifest "
                        <> compactionDigestHex (manifestDigest manifest)
                        <> ", selected "
                        <> T.pack (show report.selectedEvents)
  where
    sample name = EventData { eventId = Nothing, eventType = EventType name, payload = "{}", metadata = Nothing, causationId = Nothing, correlationId = Nothing }
    atIndex v i = v `seq` (v Data.Vector.! i)
```

(Use `Data.Vector` indexing with an explicit import, set the `payload` to an Aeson `Value` such
as `Data.Aeson.object []`, and name fields exactly as the released `EventData` and
`RecordedEvent` declare them — the repository's `kiroku-store/src/Kiroku/Store/Types.hs` is a
reliable guide, but the released Haddock is authoritative.) Run:

```bash
cabal build
cabal run kiroku-compaction-consumer
```

Expected:

```text
clean consumer verified: kiroku-store 0.9.0.0, kiroku-store-migrations 0.4.1.0, store StoreIdentity 0199…, manifest 5b1e…(64 hex)…, selected 1
```

`cabal build` must show the solver downloading and building `kiroku-store-0.9.0.0` and
`kiroku-store-migrations-0.4.1.0` from `hackage.haskell.org` (the build log names the source);
if it reports using a local package or an in-place package from this repository, the isolation
failed — delete `CABAL_DIR` and the scratch directory and start Milestone 5 again. Record in
Progress: the `preferred.json` outputs, the tag object and peeled commit, both hash comparisons,
the `tar tzf` line, and the witness line.

Close the request. Edit `docs/improvement-requests/add-manifest-driven-selective-event-compaction.md`:
after the uploads, set `status: implemented` and advance `timestamp`; after the consumer proof,
set `status: completed`, add `completedAt: "<UTC now>"`, and append a short "Delivery" section
to the body naming the released versions, the Hackage URLs, the tag object and commit, the
matching hashes, and the witness line (plan 72's request file shows the wording). Add a dated
entry to `docs/improvement-requests/log.md` with `okf log add docs/improvement-requests ...`
(match the existing entries' shape). In the same "Delivery" section, record the downstream
hand-off the MasterPlan's Integration Points ("Downstream standalone operator surface") calls
for: the standalone, database-connected `stream compact ...` command belongs to
`mori://shinzui/keiro/packages/keiro-ops` and is to be filed as a keiro improvement request now
that `kiroku-store` 0.9 and `kiroku-cli` 0.3 are on Hackage, reusing `Kiroku.Cli.Compaction`'s
renderers. Commit with the trailers. Do not edit the MasterPlan's registry here; the master-plan
skill updates it when this plan is marked complete, but note in Progress that it is due.

Result and proof: IR-14 reads `status: completed` with evidence that an outsider can reproduce;
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`'s
stated precondition ("implemented, released, and inspected from the released source") is now
satisfiable from Hackage alone.


## Concrete Steps

All commands run from the repository root unless a `cd` is shown.

Milestone 1:

```bash
nix fmt && git status --short
cabal build all
cabal test all
just perf-check
just test-matrix
nix flake check
just adr-validate
just capabilities-validate
for p in kiroku-store kiroku-store-migrations kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter; do (cd "$p" && cabal check) || echo "FAILED: $p"; done
```

Expected shape of the workload gate output (ratios are illustrative; each must be `<= 0.90`):

```text
append-multi-stream
  sequential-control-4:   OK
  production-pipeline-4:  OK  0.84x
  sequential-control-8:   OK
  production-pipeline-8:  OK  0.86x
```

Milestone 2:

```bash
grep -n '^version' */*.cabal
grep -rn 'kiroku-store *\^>=\|kiroku-cli *\^>=' */*.cabal
$EDITOR kiroku-store/kiroku-store.cabal kiroku-store-migrations/kiroku-store-migrations.cabal \
  kiroku-cli/kiroku-cli.cabal kiroku-otel/kiroku-otel.cabal kiroku-metrics/kiroku-metrics.cabal \
  shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal kiroku-test-support/kiroku-test-support.cabal \
  kiroku-jitsurei/kiroku-jitsurei.cabal
$EDITOR kiroku-store/CHANGELOG.md kiroku-store-migrations/CHANGELOG.md kiroku-cli/CHANGELOG.md \
  kiroku-otel/CHANGELOG.md kiroku-metrics/CHANGELOG.md shibuya-kiroku-adapter/CHANGELOG.md
$EDITOR blueprints/kiroku-upgrade/migrations/0-8-to-0-9.md blueprints/kiroku-upgrade/blueprint.dhall
cabal build all && cabal test all
for p in kiroku-store kiroku-store-migrations kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter; do
  echo "$p: $(curl -fsSL https://hackage.haskell.org/package/$p/preferred.json)"
done
```

Milestone 3: the commit and tag commands shown in Plan of Work.

Milestone 4: the per-package publish block shown in Plan of Work, six times, in order, followed
by six `gh release create` invocations.

Milestone 5: the verification, isolated-consumer, and request-closure commands shown in Plan of
Work, then:

```bash
git add docs/improvement-requests docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md
git commit -m "docs(ir): mark IR-14 completed with the released compaction cohort evidence" \
  -m "MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md" \
  -m "ExecPlan: docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md" \
  -m "Intention: intention_01m0mwdmnfex3tv9fg0t57htfv"
git push
```


## Validation and Acceptance

The release is accepted when all of the following are observable from outside this repository.

`curl -fsSL https://hackage.haskell.org/package/kiroku-store/preferred.json` lists `0.9.0.0`
as a normal version, and the same holds for `kiroku-store-migrations` `0.4.1.0`, `kiroku-cli`
`0.3.0.0`, `kiroku-otel` `0.2.0.8`, `kiroku-metrics` `0.1.0.9`, and `shibuya-kiroku-adapter`
`0.5.1.2`. `https://hackage.haskell.org/package/kiroku-store-0.9.0.0/docs/Kiroku-Store-Compaction.html`
renders the Haddock for `previewCompaction` and `applyCompaction`. `git ls-remote --tags
https://github.com/shinzui/kiroku.git 'refs/tags/kiroku-store-v0.9.0.0*'` prints a tag object
and a peeled commit equal to the release commit recorded in this plan. `gh release view
kiroku-store-v0.9.0.0` shows a non-draft release whose notes match the changelog. The SHA-256 of
each Hackage tarball equals the pre-upload sdist hash recorded in Progress, and `tar tzf` of the
migrations tarball lists `migrations/0012.sql` with a manifest whose last line is `0012.sql`.
An isolated consumer with its own `CABAL_DIR`, pinned to the exact versions, builds from the
downloaded packages and prints a line beginning `clean consumer verified: kiroku-store 0.9.0.0`
that includes a 64-character lowercase-hex manifest digest and `selected 1`.
`docs/improvement-requests/add-manifest-driven-selective-event-compaction.md` has `status:
completed` and a `completedAt` timestamp, and `okf validate docs/improvement-requests` exits 0.
`docs/capabilities/selective-event-compaction.md` says `since: "0.9.0.0"` and `just
capabilities-validate` exits 0.


## Idempotence and Recovery

Milestones 1 and 2 are freely repeatable: verification is read-only and the edits converge on
the same file contents. Milestone 3 is repeatable until the push; if a mistake is found before
pushing, amend the commit and re-create the local tags with `git tag -d` then `git tag -a`.
After `git push --tags`, tags are public and are never moved or deleted; a mistake discovered
afterwards is fixed by a new commit and a higher version (for example 0.9.0.1 or 0.9.1.0),
never by force-pushing a tag. Milestone 4 is irreversible per package: Hackage does not allow
replacing a published version's source. Before each upload, rerun `cabal check` and confirm the
version is absent from `preferred.json`; if an upload succeeds but later verification fails, do
not overwrite Hackage — publish a higher version following the release skill's recovery
procedure, deprecate the bad version on Hackage if it is unusable, and record the reason in
Surprises & Discoveries. If an upload fails midway through the order, its dependents must not be
uploaded until it succeeds, because their caret bounds would not solve. Milestone 5 is
repeatable: delete the scratch directory and `CABAL_DIR` and start again; the request file edits
converge. IR-14 stays `implemented` rather than `completed` until the hashes, the tag peel, and
the witness line all agree.


## Interfaces and Dependencies

Tools: `cabal` (3.12 or later, from the dev shell), `nix` (for `nix fmt`, `nix flake check`,
`nix develop .#postgresql17` / `.#postgresql18` through `just test-matrix`), `just`, `gh`
(authenticated for `shinzui/kiroku`), `curl`, `shasum`, `tar`, `okf`, `mori`, and optionally
`dhall`. Hackage upload credentials must be configured for `cabal upload` (the release skill
assumes they are).

Versions released by this plan (adjust only if the working tree's current versions differ from
those recorded in Context and Orientation):

```text
kiroku-store             0.8.0.0 -> 0.9.0.0   (major: KirokuEvent and Store constructors)
kiroku-store-migrations  0.4.0.0 -> 0.4.1.0   (minor: additive migration 0012)
kiroku-cli               0.2.0.6 -> 0.3.0.0   (major: KirokuCommand constructors)
kiroku-otel              0.2.0.7 -> 0.2.0.8   (patch: event arms, bounds)
kiroku-metrics           0.1.0.8 -> 0.1.0.9   (patch: event arms, bounds)
shibuya-kiroku-adapter   0.5.1.1 -> 0.5.1.2   (patch: event arms, bounds)
```

Bounds after the release: every released dependent declares `kiroku-store ^>=0.9`;
`kiroku-metrics` declares `kiroku-cli ^>=0.3`; `kiroku-test-support` and `kiroku-jitsurei`
declare `kiroku-store ^>=0.9`.

Public surfaces the clean consumer exercises and which must therefore be exported from the
released `kiroku-store` 0.9.0.0: `Kiroku.Store` (re-exporting `withStore`,
`defaultConnectionSettings`, `runStoreIO`, `appendToStream`, `readStreamForward`,
`storeIdentity`, `Kiroku.Store.Compaction`, and `Kiroku.Store.Types`);
`Kiroku.Store.Compaction` (`previewCompaction`, `mkCompactionManifest`,
`mkCompactionOperation`, `manifestDigest`, `compactionDigestHex`, the
`CompactionManifestInput`, `CompactionSelection`, `StreamHeadWitness`, `DeadLetterPolicy`,
`CausationPolicy`, and `CompactionReport` types); and from `kiroku-store-migrations` 0.4.1.0,
`Kiroku.Store.Migrations.kirokuMigrationPlan` whose plan ends in `0012`.

Artifacts this plan edits: the eight `.cabal` files, six `CHANGELOG.md` files,
`blueprints/kiroku-upgrade/blueprint.dhall`, `blueprints/kiroku-upgrade/migrations/0-8-to-0-9.md`,
`docs/improvement-requests/add-manifest-driven-selective-event-compaction.md`,
`docs/improvement-requests/log.md`, possibly `docs/capabilities/selective-event-compaction.md`,
and this plan.
