---
id: 96
slug: release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests
title: "Release the inspection surface cohort and complete the keiro-ui requests"
kind: exec-plan
created_at: 2026-09-30T22:35:20Z
intention: "intention_01m3t7a7jaeewbf71vqrzk4zd8"
master_plan: "docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T22:35:20Z
---

# Release the inspection surface cohort and complete the keiro-ui requests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is the seventh and last child (EP-7) of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md).
It hard-depends on the six implementation children, in their landing order:
[plan 90](90-add-configurable-cors-support-to-kiroku-metrics.md) (CORS, IR-11),
[plan 87](87-serve-durable-subscription-checkpoints-over-http.md) (durable checkpoints over
HTTP, IR-10), [plan 88](88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md)
(the REST browse API, IR-8), [plan 89](89-expose-a-public-dead-letter-read-api.md) (the public
dead-letter read API, IR-9),
[plan 94](94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md)
(WebSocket convergence, IR-12), and
[plan 95](95-serve-the-kiroku-inspection-surface-standalone-and-make-it-self-describing.md)
(the standalone `kiroku-inspect` executable and the discovery route). Those plans deliver source,
tests, and documentation and deliberately leave every package version, every dependency bound,
and every improvement-request status short of `completed`. This plan is where the cohort becomes
a published, pinnable version set and where the five open requests filed by the keiro runtime UI
initiative are closed with release evidence. Every commit made under this plan carries the
trailers `MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md`,
`ExecPlan: docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`,
and `Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8`.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store written in Haskell, published to Hackage as a family of
independently versioned packages. Its HTTP and WebSocket surface lives in the sister package
`kiroku-metrics`. The six implementation children of MasterPlan 13 turn that surface into
everything a browser UI needs from the store: cross-origin access, durable subscription
checkpoints, stream and event browsing, dead-letter reads, a WebSocket dialect that fits the
cross-project convention, a discovery route, and a standalone server binary. Until those changes
are on Hackage, nobody outside this repository can use them: the keiro runtime UI initiative
(`mori://shinzui/keiro-ui`) builds its `@keiro-ui/client-kiroku` package against published
versions, and a user who adopts only the event store has no way to install `kiroku-inspect`.

After this plan, five Kiroku packages are published on Hackage with PVP-correct independent
versions, matching source and documentation archives, one annotated git tag each, and one GitHub
release each. A clean Cabal project outside this repository, pinning only the published versions,
compiles a program that calls the new library reads and the new server starters, and installs the
`kiroku-inspect` binary. Improvement requests IR-8, IR-9, IR-10, IR-11, and IR-12 in
`docs/improvement-requests/` read `status: completed` with the shipped versions named, and the
Seihou upgrade blueprint tells a consuming project how to move from `kiroku-store` 0.9 to 0.10.
Seeing it work is one command from an empty directory:

```bash
cabal install kiroku-metrics:exe:kiroku-inspect --installdir ./bin && ./bin/kiroku-inspect --help
```

which downloads the published packages and prints the standalone server's usage text. No
publication, tag, push, or upload happens without the user's explicit confirmation at the two
gates this plan defines, and no downstream repository is edited.


## Progress

- [ ] Gate: plans 90, 87, 88, 89, 94, and 95 are marked Complete in the MasterPlan registry, their
      living sections are current, their IRs read `in_progress` with implementation evidence, and
      `kiroku-store/CHANGELOG.md` and `kiroku-metrics/CHANGELOG.md` each carry one `## Unreleased`
      section holding every child's bullets.
- [ ] M1: release truth established from the working tree, `git tag`, Hackage, and Mori dependents;
      per-package review table and proposed PVP bumps, bounds, and changelog sections presented.
- [ ] M1: explicit user confirmation of the proposed version set received before any release
      metadata is edited.
- [ ] M2: approved versions and bounds applied in every stanza; changelog sections dated;
      blueprint edge `0-9-to-0-10.md` written and registered; `nix fmt`, `cabal build all`,
      `cabal test all`, `just test-matrix`, `nix flake check`, `nix build` for `kiroku-store` and
      `kiroku-metrics`, `just perf-check`, and `just perf-telemetry` green.
- [ ] M2: `cabal check`, `cabal sdist`, and Hackage Haddock archives produced for every package in
      the cohort; archive names and SHA-256 hashes recorded; the example and `kiroku-inspect --help`
      run; final diff presented; second explicit confirmation received.
- [ ] M3: release commit, five annotated tags, push; source and documentation uploaded in
      dependency order; five GitHub releases; Hackage URLs, tag objects, and peeled commits recorded.
- [ ] M3: clean external consumer pinning the exact published versions compiles the new library
      reads and server starters, and `kiroku-inspect --help` prints from a Hackage install.
- [ ] M4: IR-8, IR-9, IR-10, IR-11, and IR-12 set to `completed` with release evidence; bundle log
      entries added; strict validation passes; CAP-17 checked; adopter handle set recorded.
- [ ] M5: ADR distillation across plans 87, 88, 89, 90, 94, 95 and the MasterPlan; any new or
      amended record allocated with `okf id next` and validated; Outcomes & Retrospective written;
      report for the MasterPlan's Outcomes prepared.


## Surprises & Discoveries

- Planning audit (2026-09-30): `agents/skills/release/SKILL.md` lists `kiroku-store-migrations`
  as a dependent of `kiroku-store`, but `kiroku-store-migrations/kiroku-store-migrations.cabal`
  depends only on the `pg-migrate` family, `template-haskell`, `filepath`, `containers`,
  `bytestring`, and `text`; its executable and test stanzas depend on the package itself. A
  `kiroku-store` major bump therefore does not require a migrations release, and this cohort ships
  no schema migration at all. The skill's ordering text is stale on that one point; this plan
  follows the verified dependency graph and notes the discrepancy for a later skill correction.
- Planning audit (2026-09-30): the Seihou upgrade blueprint `blueprints/kiroku-upgrade/` exists at
  version `0.2.0` with two edges, `0.7.0.1 -> 0.8.0.0` and `0.8.0.2 -> 0.9.0.0`. Each edge's `from`
  is the exact last patch of the previous line, so this plan's edge is `0.9.0.1 -> 0.10.0.0`.
- Planning audit (2026-09-30): `mori registry dependents shinzui/kiroku --packages` lists
  `shinzui/keiro` (six packages), `shinzui/kioku` (four), `shinzui/kawa` (one),
  `shinzui/keiro-benchmarks` (one), and project-level consumers `danwa`, `kanmon`, `kikan`,
  `keiro-runtime-docs`, `keiro-runtime-jitsurei`, `keiro-runtime-kenshou`, and
  `keiro-runtime-patterns`. None of them is edited by this plan; they adopt through Hackage bounds
  and the blueprint edge.


## Decision Log

- Decision: Package versions are chosen in this plan only, at Milestone 1, from the integrated
  diff and the authoritative state of Hackage and upstream tags; the six implementation children
  leave every `.cabal` `version:` and every internal bound untouched and write their changelog
  bullets under one `## Unreleased` heading per package.
  Rationale: Plans 87, 88, 89, and 90 were written as standalone plans and each proposed a
  different `kiroku-metrics` number (0.2.0.0, 0.1.1.0, "decide at release", major) and two of them
  proposed a `kiroku-store` 0.9.0.0 that has since shipped for other reasons. PVP impact depends
  on the final exported types; one plan choosing once from the merged code is the only way to get
  one consistent version set, and it is the pattern plans 80 and 85 established.
  Date: 2026-09-30

- Decision: The expected outcome, to be re-derived at Milestone 1 rather than assumed, is
  `kiroku-store` 0.9.0.1 to 0.10.0.0 (major), `kiroku-metrics` 0.1.0.10 to 0.2.0.0 (major),
  and bound-only patch releases `kiroku-otel` 0.2.0.11, `kiroku-cli` 0.2.0.9, and
  `shibuya-kiroku-adapter` 0.5.1.6; `kiroku-store-migrations` is not released.
  Rationale: The closed `Store` GADT gains four constructors, which breaks every exhaustive custom
  interpreter (the 0.7.0.0, 0.8.0.0, and 0.9.0.0 precedents treat that as major). `MetricsServerConfig`
  gains the `cors` field, which changes an exported datatype definition, and the server gains a
  providers record and new starters. The three patch packages change only to admit
  `kiroku-store ^>=0.10`, and `kiroku-metrics` also needs `kiroku-cli` to admit it, because a
  consumer that resolves the new `kiroku-metrics` together with today's `kiroku-cli` bound has no
  solution. The migrations package has no `kiroku-store` dependency and no new migration.
  Date: 2026-09-30

- Decision: Follow `agents/skills/release/SKILL.md` exactly, with the user invoking it. The skill
  is declared `disable-model-invocation: true`, so the agent implementing this plan prepares every
  input the skill needs, stops, and asks the user to run `/release`; the agent never runs the
  commit, tag, push, or upload steps on its own initiative.
  Rationale: Publication is irreversible and the skill is the repository's authority on version
  policy and ordering. A MasterPlan does not widen the authority to publish.
  Date: 2026-09-30

- Decision: The release gate includes the ADR-5 performance tiers (`just perf-check` and
  `just perf-telemetry`) and the two-major PostgreSQL matrix (`just test-matrix`), in addition to
  the skill's own `nix fmt`, `cabal build all`, `cabal test all`, and `nix flake check`.
  Rationale: Plans 88 and 89 add SQL statements (`starts_with`, a recursive CTE, a row-wise
  keyset comparison) whose plans are pinned by the structural gate in
  `kiroku-store/test/Test/PerformanceStructure.hs`; they are off the hot path, and the gates are
  the evidence that they stayed there. New SQL is exercised on both supported majors because a
  planner difference is the kind of regression a single-major run hides.
  Date: 2026-09-30

- Decision: Prove the release from a clean consumer outside the worktree that pins the exact
  published versions, compiles the new library reads and server starters, and installs
  `kiroku-inspect` from Hackage, before any request is marked `completed`.
  Rationale: Plans 69, 80, 85, and 87 all make the clean-consumer check the acceptance of a
  release; an in-tree build proves nothing about what Hackage serves, and `kiroku-inspect` is the
  first Kiroku executable a store-only adopter is expected to install rather than embed.
  Date: 2026-09-30

- Decision: Add a `0.9.0.1 -> 0.10.0.0` edge to `blueprints/kiroku-upgrade/` stating that no
  schema migration is required and describing the source impact (four `Store` constructor arms,
  the `cors` field, the new bounds), and bump the blueprint version to `0.3.0`.
  Rationale: Every released version window with judgement work has an edge, and a consumer with an
  exhaustive `Store` interpreter or a positional `MetricsServerConfig` construction has exactly the
  kind of change the blueprint exists to walk them through. Saying "no database work" explicitly is
  as valuable as describing database work, because the previous edge required a maintenance window.
  Date: 2026-09-30

- Decision: Complete IR-8 through IR-12 only after the clean-consumer proof, with `completedAt`,
  an advanced `timestamp`, a rewritten `## Status` naming the shipped versions and citing the
  implementing plan and this MasterPlan, and one dated `**Completion**` log entry per request.
  Do not edit the keiro-ui or keiro repositories; record the adopter handle set in Outcomes.
  Rationale: This is the lifecycle IR-3 through IR-6, IR-10, and IR-13 followed using Mori's closed
  vocabulary. The keiro-ui initiative tracks adoption on its own plans and cites Kiroku's
  completed requests; editing another repository's plans from here would create divergent status.
  Date: 2026-09-30

- Decision: No ADR is allocated up front. Milestone 5 performs the distillation pass over the
  six children and the MasterPlan and decides, with evidence, whether the CORS posture, the
  providers-record and self-hosting shape, or an amendment to ADR-9's published inventory deserves
  a record that the children did not already write.
  Rationale: Plan 90 names the CORS posture as its own candidate and plan 95 writes the
  self-hosting record; ADR-9 already makes the user guide the normative inventory precisely so
  the record need not be amended for each new route. Writing a record here before seeing what the
  children recorded would duplicate or contradict them.
  Date: 2026-09-30


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Terms used in this plan

**PVP** is the Haskell Package Versioning Policy. A version is `A.B.C.D`; a change that removes,
renames, or re-types an export, or changes an exported datatype's definition, bumps `B` and resets
`C` and `D` (a major bump, `0.9.0.1` to `0.10.0.0`); an addition bumps `C` (minor); a fix or
internal change bumps `D` (patch). A **bound-only patch release** is a patch release whose only
change is a wider dependency bound, made so that a consumer can resolve the package together with
a new major of its dependency. A **cohort** is a set of packages released together in dependency
order because one bump forces the others. **Hackage** is the Haskell package index; **sdist** is a
package's source archive; a **Haddock archive** is its generated API documentation uploaded beside
the source. An **annotated tag** is a git tag object with its own message and author; this
repository names one per package release, `<package>-v<version>`. A **clean consumer** is a Cabal
project created outside this repository whose only knowledge of Kiroku is the published index. An
**improvement request** (IR) is a concept document in the OKF bundle `docs/improvement-requests/`
with a `status` from Mori's closed vocabulary (`proposed`, `accepted`, `in_progress`, `completed`,
`declined`, `superseded`). A **Seihou blueprint** is a directory of upgrade instructions
(`blueprints/kiroku-upgrade/`) that an agent follows to move a consuming project across a released
version window; each window is an **edge**.

### The packages and their verified dependency graph

The repository is a Cabal multi-package project (`cabal.project` at the root; GHC 9.12.4; every
package builds with `-Wall -Werror=incomplete-patterns`). The publishable packages, their versions
and newest tags at planning time (2026-09-30), and their internal dependencies as read from the
`.cabal` files (not from the release skill's summary, which is stale on one point, see Surprises &
Discoveries):

- `kiroku-store` 0.9.0.1, tag `kiroku-store-v0.9.0.1`. The core library. No internal dependency.
- `kiroku-store-migrations` 0.6.0.0, tag `kiroku-store-migrations-v0.6.0.0`. Depends on the
  `pg-migrate` family only; it does not depend on `kiroku-store`. Not part of this cohort.
- `kiroku-otel` 0.2.0.10. `kiroku-store ^>=0.9.0.1` in its library and test-suite stanzas.
- `kiroku-cli` 0.2.0.8, tag `kiroku-cli-v0.2.0.8`. `kiroku-store ^>=0.9.0.1` in its library and
  test-suite stanzas; its `kiroku` executable depends on the library.
- `kiroku-metrics` 0.1.0.10, tag `kiroku-metrics-v0.1.0.10`. `kiroku-store ^>=0.9.0.1` in its
  library, its `kiroku-metrics-example` executable (behind the manual cabal flag `example`, off by
  default), and its test-suite; `kiroku-cli ^>=0.2.0.8` in its library and test-suite. After plan
  95 it also has an executable `kiroku-inspect` with its own `kiroku-store` bound.
- `shibuya-kiroku-adapter` 0.5.1.5, tag `shibuya-kiroku-adapter-v0.5.1.5`. `kiroku-store ^>=0.9.0.1`
  in its library, its test-suite, and its `lifecycle-live` executable.

Not released: `kiroku-test-support` (depends on `kiroku-store-migrations`, not on `kiroku-store`)
and `kiroku-jitsurei` (depends on `kiroku-store` with no version bound, so it needs no edit but is
built by `cabal build all`). The Nix build exposes the publishable packages as
`nix build .#kiroku-store`, `.#kiroku-metrics`, and so on (`flake.module.nix`), with the Haskell
set defined in `nix/haskell-overlay.nix`.

Release order, dependencies first, is `kiroku-store`, `kiroku-otel`, `kiroku-cli`,
`kiroku-metrics`, `shibuya-kiroku-adapter`. `kiroku-metrics` must publish after `kiroku-cli`
because it depends on it; a failed upload of any package stops the uploads of everything after it.

### What the six children change (forecast; the merged diff is authoritative)

`kiroku-store`: the `Store` effect in `kiroku-store/src/Kiroku/Store/Effect.hs` gains
`ListStreams`, `ListCategories`, and `GetEvent` (plan 88) and `ListSubscriptionDeadLetters`
(plan 89); `Kiroku.Store.Read` gains `listStreams`, `listCategories`, and `getEvent`;
`Kiroku.Store.Subscription` gains `subscriptionDeadLetters`; `Kiroku.Store.Subscription.Types`
gains `SubscriptionDeadLetter`, `SubscriptionDeadLetterCursor`, `SubscriptionDeadLetterLimit`
with `mkSubscriptionDeadLetterLimit`, `SubscriptionDeadLetterQuery`,
`defaultSubscriptionDeadLetterQuery`, and `SubscriptionDeadLetterPage`; `Kiroku.Store.SQL` gains
three browse statements and re-exports two dead-letter statements; and
`Kiroku.Store.Subscription.EventPublisher` (plan 94) gives the exported `Subscriber` record a
`subDropped :: TVar Word64` drop counter, adds `subscribePublisherWith` returning a
`PublisherSubscription`, and keeps `subscribePublisher` as a compatibility wrapper. No migration.
Because the GADT is closed, any exhaustive interpreter outside this repository stops compiling,
and because `Subscriber (..)` is exported with its fields, the new field changes an exported
datatype: either alone is the major bump.

`kiroku-metrics`: `MetricsServerConfig` gains `cors :: CorsPolicy` (plan 90); `Kiroku.Metrics.Server`
gains the `ServerProviders` record (`webSocketServer`, `subscriptionStatus`, `checkpointInventory`,
`browser`, `deadLetters`), `defaultServerProviders`, `storeServerProviders`,
`startMetricsServerWithProviders`, `withMetricsServerWithProviders`, `combinedAppWithProviders`,
and `httpAppWithProviders` (plan 87 owns the record; plans 88 and 89 add fields); new modules
`Kiroku.Metrics.Cors`, `Kiroku.Metrics.Checkpoints`, `Kiroku.Metrics.Browse`,
`Kiroku.Metrics.DeadLetters`, `Kiroku.Metrics.Capabilities`, and `Kiroku.Metrics.Standalone`;
new routes `/subscriptions/checkpoints`, `/streams…`, `/categories…`, `/events…`,
`/subscriptions/<name>/dead-letters`, and the discovery route; additive WebSocket frames and the
optional `original_stream_name` key on `event` frames (plan 94); the `kiroku-inspect` executable
(plan 95); new dependencies `effectful-core` (library, plan 88) and `optparse-applicative`
(library, because plan 95 keeps the option parser in `Kiroku.Metrics.Standalone` so it is
testable) plus `unix` on the executable only. The `cors` field alone makes this a major bump; the
changelog's `### Other Changes` names both new library dependencies.

`kiroku-otel`, `kiroku-cli`, `shibuya-kiroku-adapter`: no source change is expected. They are
released only so their bounds admit the new `kiroku-store`. If the merged diff shows that a child
touched one of them (for example an exhaustive `Store` interpreter in a test that needed new arms),
its changelog says so and the bump level is re-derived.

### Where the changelog text comes from

Each child writes its bullets under `## Unreleased` at the top of the package changelog:
`kiroku-store/CHANGELOG.md` uses headings of the form `## 0.9.0.1 — 2026-09-25` (em dash) and
`kiroku-metrics/CHANGELOG.md` uses `## 0.1.0.10 -- 2026-09-25` (two hyphens); keep each file's
own convention. Entries are grouped under `### Breaking Changes`, `### New Features`,
`### Bug Fixes`, and `### Other Changes`, only the groups that apply. This plan renames each
`## Unreleased` heading to the approved version and date without rewriting the children's text,
and writes the patch packages' `### Other Changes` entries in the phrasing of the 2026-09-25
entries ("Require `kiroku-store ^>=0.10` … The API and behavior are unchanged.").

### The release skill and its gates

`agents/skills/release/SKILL.md` (symlinked as `.claude/skills/release`) defines the procedure:
determine scope from `git log <last-tag>..HEAD -- <package-dir>`; propose per-package PVP bumps and
ask the user to confirm; edit versions, bounds in every stanza, and dated changelogs; run
`nix fmt`, `cabal build all`, `cabal test all`, and `nix flake check` (new files must be
`git add`-ed first so Nix sees them); one `chore(release): …` commit after approval; one annotated
tag per package; `git push && git push --tags`; then per package in dependency order `cabal check`,
`cabal test`, `cabal sdist`, `cabal upload --publish`, `cabal haddock --haddock-for-hackage
--haddock-hyperlink-source --haddock-quickjump`, `cabal upload --publish --documentation`; then
`gh release create` per tag. The skill's frontmatter says `disable-model-invocation: true`: the
user runs `/release`; this plan prepares its inputs and reports at each gate.

This plan adds three gates the skill does not name. `just perf-check` runs the structural tier
(`cabal test kiroku-store:kiroku-store-test --test-options='--match "performance structure"'`)
and the controlled workload gate (`cabal bench kiroku-store:kiroku-store-bench-workload-gate`),
and `just perf-telemetry` compares the historical benchmark suite against
`kiroku-store/bench/results/baseline.csv` without failing on timing movement; both are defined in
`Justfile` and governed by [ADR-5](../adr/0005-three-tier-performance-regression-gates.md), which
makes the first two tiers authoritative and the third corroborating. `just test-matrix` runs every
suite once under PostgreSQL 17 and once under 18 through the `postgresql17` and `postgresql18`
acceptance shells in `flake.module.nix`. Their thresholds and how to read a boundary-noisy run
are in `docs/PERF-REGRESSION-GATES.md`; per ADR-5 a noisy run is repeated on an idle host, never
resolved by editing thresholds.

### What becomes published at release

[ADR-9](../adr/0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
(`mori://shinzui/kiroku/okf/adrs/concepts/ADR-9`) says a wire shape becomes a published contract
once it ships in a Hackage release of a sister package and is documented in `docs/user/metrics.md`;
the guide is the normative inventory and the record fixes the change rule, so the inventory grows
without amending the record. This release is the moment every route, frame, key, and error code
the children added becomes frozen. The consequence for this plan: a documentation gap found at the
gate is a release blocker, not a follow-up, because an undocumented shipped shape is neither
published nor free to change. [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md)
is the SQL-side precedent ADR-9 extends; no relation changes in this cohort.

Cross-repository decisions, by the canonical handles the keiro-ui bundle publishes:
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1` (inspection endpoints live in the project that
owns the concept, which is why the requests are closed here and adoption is tracked there) and
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-5` (no backend-for-frontend: the browser consumes
these endpoints directly through one typed client package per surface, so the published version
set is the whole contract between Kiroku and the UI). `mori path` may report these handles as not
found because registry observation lags fresh commits; the canonical URIs are retained regardless.

### The improvement requests this plan closes

`docs/improvement-requests/` is an OKF bundle governed by `mori/improvement-requests-profile.dhall`
(okf-profiles v0.5.0 `coordination.improvementRequests`), with `index.md` (catalog) and `log.md`
(dated journal). The five requests, by file:

- IR-8, `expose-a-rest-read-api-for-browsing-streams-categories-and-events.md` (plan 88).
- IR-9, `expose-a-public-dead-letter-read-api.md` (plan 89).
- IR-10, `serve-durable-subscription-checkpoints-over-http.md` (plan 87).
- IR-11, `add-configurable-cors-support-to-kiroku-metrics.md` (plan 90).
- IR-12, `converge-the-websocket-protocol-with-the-cross-project-convention.md` (plan 94).

Each carries `origin: mori://shinzui/keiro-ui` and, when this plan starts, `status: in_progress`
with an "Implementation Evidence" section written by its child. A completed request looks like
IR-13 (`record-http-and-websocket-wire-format-stability-in-an-adr.md`): `status: completed`,
`completedAt: "<UTC>"`, `timestamp` advanced to the same instant, and a `## Status` paragraph that
opens with "Completed on <date> …" and names what shipped. Every status change needs a dated
entry in `log.md` (the `**Completion**` entries of 2026-08-13 and 2026-09-10 are the models) and
must pass the strict validator. The validator prints one
`missing profile-recommended field: reviews` line per machine-authored request; those are
advisory and pre-existing (recorded in this repository's agent memory), and success is judged by
the absence of any other error line and a zero exit status.

`docs/capabilities/operational-http-endpoints.md` is capability CAP-17 in the profile-governed
`capabilities` bundle (`just capabilities-validate`). Its `since: "0.1.0.0"` names the version in
which the capability first shipped and does not move; the children extend its body, `interface`,
and `evidence`. This plan only confirms those edits describe what was released and adds nothing
unless a discrepancy is found.

### The upgrade blueprint

`blueprints/kiroku-upgrade/blueprint.dhall` declares a Seihou blueprint (`version = Some "0.2.0"`)
with a `migrations` list of `S.BlueprintMigration::{ from, to, prompt }` records, one per edge,
each `prompt` read from `./migrations/<from>-to-<to>.md as Text`. The existing edges are
`0.7.0.1 -> 0.8.0.0` and `0.8.0.2 -> 0.9.0.0`; the newer file, `migrations/0-8-to-0-9.md`, is the
model for structure: a heading `# kiroku-store <from> → <to>`, a summary of which packages
changed, a `## Precondition` saying when the edge is not applicable, and lettered parts with
"What changed", "What to do", and "Proving it". Consumers reach the blueprint through their own
tooling; this plan only adds the file and the list entry.


## Plan of Work

### Gate — confirm the cohort is complete

Before anything else, open the MasterPlan's Exec-Plan Registry and confirm that plans 90, 87, 88,
89, 94, and 95 are Complete; open each plan's Progress and Outcomes sections and confirm they are
current; open each of IR-8 through IR-12 and confirm `status: in_progress` with implementation
evidence; and confirm that `kiroku-store/CHANGELOG.md` and `kiroku-metrics/CHANGELOG.md` each
begin with exactly one `## Unreleased` section. Run `git status --short --branch` and expect a
clean tree on `master`. If any check fails, stop and record the gap in Surprises & Discoveries;
this plan does not implement a child's missing work.

### Milestone 1 — establish release truth and obtain approval

Scope: know exactly what changed, what the authoritative published state is, and what the PVP-correct
next versions are, then obtain the user's confirmation of the version set. Nothing is edited.

For each of the five cohort packages and for `kiroku-store-migrations`, record the current
`version:` from its `.cabal`, its newest tag from `git tag --list '<package>-v*' | sort -V | tail -1`,
the commits since that tag under its directory from `git log --oneline <tag>..HEAD -- <dir>`, and
the public API diff (the export lists of the modules the children touched; for `kiroku-store`
the `Store` constructors and the read and subscription wrappers, for `kiroku-metrics` the
`Config`, `Server`, and new modules). Query Hackage for each package's current version rather than
trusting the local tags alone; the dev shell has no `curl`, so run the check from a host shell or
with `nix run nixpkgs#curl -- -fsSL https://hackage.haskell.org/package/<package>/preferred.json`.
Run `mori registry dependents shinzui/kiroku --packages` and record the registered consumers.

Derive the bump per package from the diff, expecting the outcome in the Decision Log, and write
the review table into Progress with one row per package: current version, last tag, commit
count, proposed version, bound edits it forces, and a one-sentence justification. Include the
patch packages even though their diffs are empty, with the justification "bound-only: admit
`kiroku-store ^>=0.10`". State explicitly that `kiroku-store-migrations` is not released and why.
Show the exact changelog headings that will replace `## Unreleased` and the exact patch-package
entries that will be added.

Then stop. Present the table and ask the user to confirm the version set (this is the release
skill's first confirmation). Do not edit a `.cabal` file until the answer is yes. If the user
changes a number, record the change and its reason in the Decision Log.

Acceptance for M1: Progress holds the review table with Hackage-verified current versions, and a
confirmation from the user is recorded with its date.

### Milestone 2 — prepare and verify the approved cohort

Scope: apply the approved release metadata, write the blueprint edge, and pass every gate, without
committing. At the end, the working tree contains the complete release change, every check is
green, the archives exist with recorded hashes, and the user has seen the final diff.

Versions. Set `version:` in `kiroku-store/kiroku-store.cabal`, `kiroku-otel/kiroku-otel.cabal`,
`kiroku-cli/kiroku-cli.cabal`, `kiroku-metrics/kiroku-metrics.cabal`, and
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` to the approved numbers.

Bounds. Change every `kiroku-store ^>=0.9.0.1` to `kiroku-store ^>=0.10` in `kiroku-otel`
(library, test-suite), `kiroku-cli` (library, test-suite), `kiroku-metrics` (library,
`kiroku-metrics-example`, `kiroku-inspect`, test-suite), and `shibuya-kiroku-adapter` (library,
test-suite, `lifecycle-live`); `grep -rn 'kiroku-store *\^>=' */*.cabal` must afterwards show
only `^>=0.10`. Change `kiroku-cli ^>=0.2.0.8` to the approved `kiroku-cli` version in
`kiroku-metrics` (library, test-suite). `kiroku-jitsurei` has no bound and needs no edit;
`kiroku-test-support` does not depend on `kiroku-store`.

Changelogs. In `kiroku-store/CHANGELOG.md` rename `## Unreleased` to `## 0.10.0.0 — <YYYY-MM-DD>`
(the release day, em dash as the file uses) and leave the children's bullets in place; confirm a
`### Breaking Changes` bullet names the four `Store` constructors and that `### New Features`
names the browse reads and the dead-letter read. In `kiroku-metrics/CHANGELOG.md` rename
`## Unreleased` to `## 0.2.0.0 -- <YYYY-MM-DD>` (two hyphens as the file uses); confirm
`### Breaking Changes` names the `cors` field and any signature the children changed, and add
under `### Other Changes` the bounds now required (`kiroku-store ^>=0.10`, `kiroku-cli ^>=<version>`).
In `kiroku-otel/CHANGELOG.md`, `kiroku-cli/CHANGELOG.md`, and
`shibuya-kiroku-adapter/CHANGELOG.md` add a dated section with one `### Other Changes` bullet:
"Require `kiroku-store ^>=0.10`, whose exported `Store` effect gains the browse and dead-letter
read constructors. No source change was required and no <package> API or runtime behavior
changed." If the diff shows a source change in one of them, describe it truthfully instead.

Blueprint edge. Create `blueprints/kiroku-upgrade/migrations/0-9-to-0-10.md` with the heading
`# kiroku-store 0.9.0.1 → 0.10.0.0`, a summary that this window releases `kiroku-store` 0.10.0.0
and `kiroku-metrics` 0.2.0.0 with bound-only patches of `kiroku-otel`, `kiroku-cli`, and
`shibuya-kiroku-adapter`, and states in its first paragraph that **no schema migration ships in
this window**: the migration plan is still twelve entries, `kiroku-store-migrations` stays at
0.6.0.0, and there is no database half. A `## Precondition` says the edge is not applicable only
when the project neither interprets the `Store` effect exhaustively, nor constructs
`MetricsServerConfig` positionally, nor calls a `kiroku-metrics` starter whose signature the
merged diff changed, nor names Kiroku packages in its bounds. Part A, `Store` gains four
constructors: `ListStreams`, `ListCategories`, `GetEvent`, `ListSubscriptionDeadLetters`; an
exhaustive `interpret_` (a mock in tests, or a real interpreter) fails to compile under
`-Werror=incomplete-patterns` and needs one arm each (delegate in a real interpreter, `error` in a
mock); programs that only call `runStoreIO` need nothing. Part B, `kiroku-metrics`:
`MetricsServerConfig` gains `cors`, so `defaultConfig{...}` callers need nothing and positional
constructions add `cors = corsDisabled`; list any starter whose signature changed per the merged
diff and its replacement; mention that `startMetricsServerWithStore` now also serves the durable
checkpoint, browse, and dead-letter routes and that the discovery route reports which are wired.
Part C, bounds: `kiroku-store ^>=0.10`, `kiroku-metrics ^>=0.2`, `kiroku-cli ^>=<version>`, and
the `kiroku-inspect` executable as the new way to run the surface without a host program. "Proving
it" is `cabal build` (the compile failures are the whole signal here) plus the project's own
suites. Register the edge in `blueprint.dhall` by appending
`, S.BlueprintMigration::{ from = "0.9.0.1", to = "0.10.0.0", prompt = ./migrations/0-9-to-0-10.md as Text }`
to `migrations` and setting `version = Some "0.3.0"`. If `dhall` is on PATH, check with
`dhall --file blueprints/kiroku-upgrade/blueprint.dhall > /dev/null`; otherwise the formatter hook
under `nix flake check` covers the file (confirm by reading `.pre-commit-config.yaml` or
`nix/pre-commit.nix`).

Gates. Stage the new blueprint file (`git add blueprints/`) so Nix sees it, then run, from the
repository root inside the dev shell: `nix fmt` (must change nothing), `cabal build all`,
`cabal test all`, `just test-matrix`, `nix flake check`, `nix build .#kiroku-store`,
`nix build .#kiroku-metrics` (then `./result/bin/kiroku-inspect --help` must print usage),
`just perf-check`, and `just perf-telemetry`. Record in Progress the commit hash the tree is based
on, the example counts, both majors' outcomes, the workload-gate ratios, and the telemetry cells
for the read paths plan 88 and 89 added (the cells named `All.category.*` and
`All.subscription-checkpoint-inventory.*` are the closest existing families; a new cell the
children added is reported by name). Run `cabal run -fexample kiroku-metrics-example` and
`cabal run kiroku-inspect -- --help` and paste their tails. Run `just adr-validate`,
`just capabilities-validate`, and the strict improvement-request validation.

Archives. For each cohort package in release order, from its directory: `cabal check`,
`cabal test <package>`, `cabal sdist`, `shasum -a 256` of the produced tarball, and
`cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`. Open each
sdist listing (`tar tzf`) and confirm it contains the changelog, the license, every exposed module,
and for `kiroku-metrics` the `kiroku-inspect` main module; confirm the example executable's
`kiroku-test-support` dependency is bounded and the example flag is off (the 0.1.0.2 lesson). Do
not upload.

Then stop again. Present `git diff --stat`, the gate transcripts, the archive names and hashes,
and the release order, and ask the user to run `/release` (or to confirm that the release commit,
tags, push, and uploads may proceed). This is the skill's second confirmation and the last point
at which a change costs nothing.

Acceptance for M2: `git status --short` shows exactly the five `.cabal` files, the five
changelogs, the blueprint file and manifest, and nothing else; every gate is green; ten archives
exist with recorded hashes; the user's confirmation is recorded.

### Milestone 3 — publish and independently verify

Scope: make the cohort public and prove it from outside. Nothing here runs before the Milestone 2
confirmation.

Publication follows the skill. One Conventional Commit,
`chore(release): kiroku-store 0.10.0.0, kiroku-otel 0.2.0.11, kiroku-cli 0.2.0.9, kiroku-metrics 0.2.0.0, shibuya-kiroku-adapter 0.5.1.6`
(with the approved numbers), whose body gives one sentence per package justifying its bump, one
line naming the gates that passed with their counts and ratios, and the three trailers. Then one
annotated tag per package, `git push && git push --tags`, and per package in release order:
`cabal check`, `cabal test`, `cabal sdist`, `cabal upload --publish <sdist>`, the Haddock build,
`cabal upload --publish --documentation <docs-tarball>`, and the Hackage URL. If an upload fails,
stop before the next package and record the partial cohort. Finally `gh release create` per tag
with the title `<package> v<version>` and that version's changelog section as notes. Record in
Progress every Hackage URL, every tag's object hash and peeled commit
(`git for-each-ref refs/tags/*-v* --format '%(refname:short) %(objecttype) %(objectname) %(*objectname)'`),
and every GitHub release URL.

Clean consumer. After Hackage's index refreshes (`cabal update` from the scratch project;
allow several minutes), create `"$SCRATCH/inspection-consumer"` outside the worktree (the
session scratchpad directory is the intended place) containing a `cabal.project` with
`packages: .`, an `inspection-consumer.cabal` with one executable whose `build-depends` pins
`kiroku-store ==0.10.0.0`, `kiroku-metrics ==0.2.0.0`, `kiroku-cli ==0.2.0.9`, `effectful-core`,
`uuid`, `text`, and `base`, and a `Main.hs` that imports `Kiroku.Metrics` and `Kiroku.Store` and
type-checks calls to `storeServerProviders`, `withMetricsServerWithProviders`, `allowedOrigin`,
`corsAllowOrigins`, `listStreams`, `getEvent`, `subscriptionDeadLetters`, and
`subscriptionCheckpointInventory` (the program never opens a database; the store-dependent parts
are functions it defines but does not call). The Concrete Steps section shows the file. Before
writing it, re-read the released export lists in `kiroku-metrics/src/Kiroku/Metrics/Server.hs`,
`kiroku-metrics/src/Kiroku/Metrics/Cors.hs`, `kiroku-store/src/Kiroku/Store/Read.hs`, and
`kiroku-store/src/Kiroku/Store/Subscription.hs`; the names above are what the children specify
at planning time, and the consumer must use the names that shipped. `cabal build` must download
the pinned versions from Hackage and succeed. Then, in the same scratch directory,
`cabal install kiroku-metrics:exe:kiroku-inspect --installdir ./bin --overwrite-policy=always`
and `./bin/kiroku-inspect --help` must print the standalone server's usage. Record the solver's
download lines, the build result, and the help text in Progress.

Acceptance for M3: five packages on Hackage at the approved versions with documentation, five
tags peeling to the release commit, five GitHub releases, and a consumer transcript showing a
successful build and a printed `--help`.

### Milestone 4 — complete the requests and coordinate downstream

Scope: turn the release into recorded completion of the five keiro-ui requests, and leave a
downstream adopter everything they need without touching their repositories.

For each of IR-8, IR-9, IR-10, IR-11, and IR-12: set `status: completed`, add
`completedAt: "<UTC instant>"`, set `timestamp` to the same instant, and rewrite the `## Status`
section's opening paragraph to begin "Completed on <date>." and to name the shipped versions
(`kiroku-store` 0.10.0.0 and/or `kiroku-metrics` 0.2.0.0 as applicable), the implementing plan by
repository-relative link and canonical handle (`mori://shinzui/kiroku/plans/<N>-<slug>`), and this
MasterPlan (`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`).
Keep the children's "Implementation Evidence" sections and the request bodies otherwise unchanged;
`index.md` descriptions do not change. Add one dated section to `docs/improvement-requests/log.md`
with one `**Completion**` bullet per request, each naming the versions, the Hackage evidence, and
the clean-consumer check in the style of the IR-6 entry. Run the strict validator and
`mori validate`.

Open `docs/capabilities/operational-http-endpoints.md` and confirm its `interface` lists the new
modules, its `evidence` names the children's spec files, and its body describes the released
routes; leave `since` and `stability` unchanged unless the user asks otherwise. If a child left it
inconsistent with what shipped, fix the text, add a dated `**Update**` entry to
`docs/capabilities/log.md`, and run `just capabilities-validate`.

Do not edit `mori://shinzui/keiro-ui` or `mori://shinzui/keiro`. Instead, write into this plan's
Outcomes the adopter's handle set: the completed requests as
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8` through `IR-12`, the version set,
the Hackage URLs, the blueprint edge, and the discovery route a client should call first. Note
that `mori registry` observation of these completions may lag until the registry is refreshed,
and that the keiro-ui initiative tracks adoption under its own MasterPlan
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`). Registered consumers
that pin `kiroku-store` bounds (from Milestone 1's dependents list) move on their own schedule
through the blueprint edge; if the user asks for a downstream bump, that is separate work under a
separate authorization.

Commit as `docs(improvement-requests): complete IR-8 through IR-12 with the inspection surface release`
with the three trailers.

Acceptance for M4: the five request files read `status: completed` with matching `completedAt`
and `timestamp`, the log has the entries, the strict validator exits zero with no error other than
the advisory `reviews` lines, and Outcomes holds the adopter handle set.

### Milestone 5 — ADR distillation and Outcomes

Scope: promote what is durable and close the plan.

Reread the Decision Log and Surprises & Discoveries of plans 87, 88, 89, 90, 94, and 95 and the
MasterPlan's Decision Log and Surprises & Discoveries, and list what each child recorded in
`docs/adr/` at its own completion (`ls docs/adr/` and `docs/adr/log.md`). Decide three questions
with evidence. First, did plan 90 record the CORS posture (default-off, explicit origins, wildcard
unrepresentable, WAI-layer enforcement covering WebSocket upgrades)? If not, and the posture now
governs six routes and a standalone binary, allocate a record. Second, did plan 95 record the
providers-record and self-hosting shape (one record of optional store-backed providers, one
general starter, the bare `Application` exported for composition, the standalone executable, the
discovery route)? If it did, confirm it cites the final names; if not, allocate one. Third, does
ADR-9's section 1 need amending? Its rule is that `docs/user/metrics.md` is the normative
inventory and the record fixes only membership and change, so the expected answer is no; amend it
only if a child changed a rule (for example the error-envelope boundary or the casing rule) rather
than the inventory. For any record: `okf id next docs/adr --profile docs/adr/profile.dhall ADR`
(ADR-11 was next at planning time; use whatever it prints), imitate ADR-9's frontmatter
(`type`, `title`, one-sentence `description`, `generated.by` as your model actor string,
`generated.at`, `docId`, `status: Accepted`, `date`, `timestamp`), add the `okf log add docs/adr`
entry, and run `just adr-validate`. Record the decision, including a "no record needed" decision,
in this plan's Decision Log.

Write Outcomes & Retrospective: what shipped (versions, URLs, tags), what was proven (gates,
matrix, consumer), what closed (IR-8 through IR-12), what was left (any declined or deferred
item), and the lessons. End with a short "For the MasterPlan" paragraph listing what MasterPlan
13's Outcomes should record and which ADRs now exist; updating the MasterPlan itself is the
MasterPlan implement mode's job, not this plan's.

Commit as `docs(plans): close plan 96 with release outcomes and ADR distillation` with the three
trailers.

Acceptance for M5: every ADR decision is recorded with evidence, `just adr-validate` passes,
Outcomes is written, and every Progress item is checked.


## Concrete Steps

Run every command from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside the Nix dev
shell (`nix develop`, or the direnv-loaded shell) unless a step says otherwise. Replace
`<version>` placeholders with the approved numbers; never run a publishing command with a
placeholder.

Gate and Milestone 1, read-only:

```bash
git status --short --branch
grep -n '^version' kiroku-store/kiroku-store.cabal kiroku-otel/kiroku-otel.cabal kiroku-cli/kiroku-cli.cabal kiroku-metrics/kiroku-metrics.cabal shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal kiroku-store-migrations/kiroku-store-migrations.cabal
for p in kiroku-store kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter kiroku-store-migrations; do
  t=$(git tag --list "$p-v*" | sort -V | tail -1)
  echo "== $p last tag $t: $(git log --oneline "$t"..HEAD -- "$p" | wc -l | tr -d ' ') commits"
done
grep -rn 'kiroku-store *\^>=\|kiroku-cli *\^>=' */*.cabal
head -30 kiroku-store/CHANGELOG.md
head -40 kiroku-metrics/CHANGELOG.md
mori registry dependents shinzui/kiroku --packages
```

Expected shape (numbers vary):

```text
## master
kiroku-store/kiroku-store.cabal:3:version:         0.9.0.1
...
== kiroku-store last tag kiroku-store-v0.9.0.1: 9 commits
== kiroku-otel last tag kiroku-otel-v0.2.0.10: 0 commits
== kiroku-cli last tag kiroku-cli-v0.2.0.8: 0 commits
== kiroku-metrics last tag kiroku-metrics-v0.1.0.10: 31 commits
== shibuya-kiroku-adapter last tag shibuya-kiroku-adapter-v0.5.1.5: 0 commits
== kiroku-store-migrations last tag kiroku-store-migrations-v0.6.0.0: 0 commits
```

Hackage check, from a host shell that has `curl` (the dev shell does not):

```bash
for p in kiroku-store kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter; do
  echo "$p: $(curl -fsSL "https://hackage.haskell.org/package/$p/preferred.json")"
done
```

Expected: each `normal-version` list's newest entry equals the local newest tag's version, and
none lists a proposed new version. Then present the review table and wait for confirmation.

Milestone 2 edits and gates:

```bash
# edit the five .cabal versions and every kiroku-store / kiroku-cli bound
# edit the five CHANGELOG.md files
# write blueprints/kiroku-upgrade/migrations/0-9-to-0-10.md; edit blueprints/kiroku-upgrade/blueprint.dhall
grep -rn 'kiroku-store *\^>=' */*.cabal          # every line must read ^>=0.10
git add blueprints/
nix fmt && git status --short
cabal build all
cabal test all --test-show-details=direct
just test-matrix
nix flake check
nix build .#kiroku-store
nix build .#kiroku-metrics && ./result/bin/kiroku-inspect --help
just perf-check
just perf-telemetry
cabal run -fexample kiroku-metrics-example
cabal run kiroku-inspect -- --help
just adr-validate
just capabilities-validate
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
git diff --check
```

Expected: `nix fmt` leaves `git status --short` showing only the intended files; every suite
passes on both majors (`just test-matrix` prints `== postgres (PostgreSQL) 17.x ==` and
`== postgres (PostgreSQL) 18.x ==` followed by each suite's `0 failures`); `just perf-check`
ends with the structural suite green and the workload gate's ratios within the thresholds in
`docs/PERF-REGRESSION-GATES.md`; `just perf-telemetry` prints the comparison table without
failing; the example prints its full numbered transcript ending in `all checks passed`;
`kiroku-inspect --help` prints usage naming the database URL, port, and CORS options; the
validators exit zero (the improvement-request run prints only `reviews` advisories).

Archives, per package in release order:

```bash
for p in kiroku-store kiroku-otel kiroku-cli kiroku-metrics shibuya-kiroku-adapter; do
  ( cd "$p" \
    && cabal check \
    && cabal sdist \
    && shasum -a 256 dist-newstyle/sdist/"$p"-*.tar.gz \
    && tar tzf dist-newstyle/sdist/"$p"-*.tar.gz | sed -n '1,40p' \
    && cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump \
    && ls dist-newstyle/"$p"-*-docs.tar.gz )
done
```

Expected per package: `No errors or warnings could be found in the package.` (or only the known
`-Werror` warning `cabal check` emits for the `ghc-options` line, which previous releases carried),
one sdist hash line, a listing that includes `CHANGELOG.md`, `LICENSE`, and the package's modules,
and one `<package>-<version>-docs.tar.gz`. Record the hashes in Progress, then present and wait
for the second confirmation.

Milestone 3, only after confirmation, following the release skill:

```bash
git add kiroku-store/kiroku-store.cabal kiroku-store/CHANGELOG.md \
        kiroku-otel/kiroku-otel.cabal kiroku-otel/CHANGELOG.md \
        kiroku-cli/kiroku-cli.cabal kiroku-cli/CHANGELOG.md \
        kiroku-metrics/kiroku-metrics.cabal kiroku-metrics/CHANGELOG.md \
        shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal shibuya-kiroku-adapter/CHANGELOG.md \
        blueprints/kiroku-upgrade/
git commit -F - <<'EOF'
chore(release): kiroku-store 0.10.0.0, kiroku-otel 0.2.0.11, kiroku-cli 0.2.0.9, kiroku-metrics 0.2.0.0, shibuya-kiroku-adapter 0.5.1.6

kiroku-store 0.10.0.0: major because the closed Store effect gains ListStreams,
ListCategories, GetEvent, and ListSubscriptionDeadLetters, which exhaustive
interpreters must handle; adds listStreams, listCategories, getEvent, and
subscriptionDeadLetters. No schema migration.
kiroku-metrics 0.2.0.0: major because MetricsServerConfig gains the cors field;
adds CORS, the ServerProviders record and general starters, the durable
checkpoint, browse, dead-letter, and discovery routes, additive WebSocket
frames, and the kiroku-inspect executable.
kiroku-otel 0.2.0.11, kiroku-cli 0.2.0.9, shibuya-kiroku-adapter 0.5.1.6:
patch, bound-only, to admit kiroku-store ^>=0.10.

Verified: nix fmt clean, cabal build all, cabal test all (<N> examples),
just test-matrix on PostgreSQL 17 and 18, nix flake check, nix build of
kiroku-store and kiroku-metrics, just perf-check (<ratios>), just perf-telemetry,
cabal check on all five packages.

MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
ExecPlan: docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8
EOF
git tag -a kiroku-store-v0.10.0.0 -m "kiroku-store 0.10.0.0"
git tag -a kiroku-otel-v0.2.0.11 -m "kiroku-otel 0.2.0.11"
git tag -a kiroku-cli-v0.2.0.9 -m "kiroku-cli 0.2.0.9"
git tag -a kiroku-metrics-v0.2.0.0 -m "kiroku-metrics 0.2.0.0"
git tag -a shibuya-kiroku-adapter-v0.5.1.6 -m "shibuya-kiroku-adapter 0.5.1.6"
git push && git push --tags
git for-each-ref 'refs/tags/*-v*' --format '%(refname:short) %(objecttype) %(objectname) %(*objectname)' | tail -5
```

Uploads, per package in release order, from the package directory (stop at the first failure):

```bash
cd kiroku-store
cabal check
cabal test kiroku-store:kiroku-store-test
cabal sdist
cabal upload --publish dist-newstyle/sdist/kiroku-store-0.10.0.0.tar.gz
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
cabal upload --publish --documentation dist-newstyle/kiroku-store-0.10.0.0-docs.tar.gz
cd ..
# repeat for kiroku-otel, kiroku-cli, kiroku-metrics, shibuya-kiroku-adapter
```

Expected tail per upload: `Package successfully published.` and, for documentation,
`Documentation successfully published.`; the URL `https://hackage.haskell.org/package/<package>-<version>`
then serves the page. GitHub releases:

```bash
for t in kiroku-store-v0.10.0.0 kiroku-otel-v0.2.0.11 kiroku-cli-v0.2.0.9 kiroku-metrics-v0.2.0.0 shibuya-kiroku-adapter-v0.5.1.6; do
  gh release create "$t" --title "${t%-v*} v${t##*-v}" --notes-file "$SCRATCH/notes-$t.md"
done
```

where each notes file holds the heading, the Hackage URL, and that version's changelog section
as the skill specifies. Expected: five `https://github.com/shinzui/kiroku/releases/tag/<tag>`
URLs.

Clean consumer, in the session scratchpad (outside the worktree):

```bash
mkdir -p "$SCRATCH/inspection-consumer" && cd "$SCRATCH/inspection-consumer"
cat > cabal.project <<'EOF'
packages: .
EOF
cat > inspection-consumer.cabal <<'EOF'
cabal-version: 3.0
name:          inspection-consumer
version:       0.1.0.0
build-type:    Simple

executable inspection-consumer
  main-is:          Main.hs
  default-language: GHC2024
  default-extensions: DataKinds, OverloadedRecordDot, OverloadedStrings
  build-depends:
    , base
    , effectful-core
    , kiroku-cli     ==0.2.0.9
    , kiroku-metrics ==0.2.0.0
    , kiroku-store   ==0.10.0.0
    , text
    , uuid
EOF
cat > Main.hs <<'EOF'
module Main (main) where

import Data.UUID (nil)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Kiroku.Metrics
import Kiroku.Store

-- Compiles against the published cohort; never opens a database.
main :: IO ()
main = do
    origin <- either (fail . show) pure (allowedOrigin "https://ops.example.com")
    let cfg = defaultConfig{cors = corsAllowOrigins [origin]}
    putStrLn ("inspection-consumer: kiroku-metrics 0.2.0.0 resolves; port " <> show cfg.port)

browse :: Eff '[Store, Error StoreError, IOE] ()
browse = do
    _ <- listStreams (Just "orders-") Nothing 10
    _ <- listCategories Nothing 10
    _ <- getEvent (EventId nil)
    _ <- subscriptionCheckpointInventory
    _ <- subscriptionDeadLetters (defaultSubscriptionDeadLetterQuery (SubscriptionName "orders"))
    pure ()

serve :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ()
serve cfg m store = do
    providers <- storeServerProviders cfg m store
    withMetricsServerWithProviders cfg m [postgresPing store] providers $ \srv ->
        putStrLn ("serving on " <> show srv.serverPort)

_unused :: ()
_unused = const () (browse, serve)
EOF
cabal update
cabal build
cabal run inspection-consumer
cabal install kiroku-metrics:exe:kiroku-inspect --installdir ./bin --overwrite-policy=always
./bin/kiroku-inspect --help
```

Expected: the solver lines `Downloading kiroku-store-0.10.0.0`, `Downloading kiroku-cli-0.2.0.9`,
and `Downloading kiroku-metrics-0.2.0.0` (with their transitive closure), a successful build,
the line `inspection-consumer: kiroku-metrics 0.2.0.0 resolves; port 9091`, an installed binary,
and the usage text of `kiroku-inspect`. If a name in `Main.hs` does not match the released export
list, fix the consumer to the shipped name and record the discrepancy in Surprises & Discoveries;
do not "fix" it by republishing.

Milestone 4 edits and validation:

```bash
# edit the five IR files: status, completedAt, timestamp, ## Status paragraph
# edit docs/improvement-requests/log.md: one dated section, five Completion bullets
okf validate docs/improvement-requests --strict --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
mori validate
just capabilities-validate
git diff --check
git add docs/improvement-requests docs/capabilities
git commit -m "docs(improvement-requests): complete IR-8 through IR-12 with the inspection surface release" -m "MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md" -m "ExecPlan: docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md" -m "Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8"
```

Expected validator tail: only lines of the form
`profile: <slug>: missing profile-recommended field: reviews`, then exit status `0`.

Milestone 5:

```bash
ls docs/adr/ && tail -20 docs/adr/log.md
okf id next docs/adr --profile docs/adr/profile.dhall ADR      # only if a record is needed
# write the record, then:
okf log add docs/adr --kind Addition -m "<one sentence naming the record>"
just adr-validate
git add docs/adr docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
git commit -m "docs(plans): close plan 96 with release outcomes and ADR distillation" -m "MasterPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md" -m "ExecPlan: docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md" -m "Intention: intention_01m3t7a7jaeewbf71vqrzk4zd8"
```


## Validation and Acceptance

The plan is complete when all of the following are observable:

1. Milestone 1's review table in Progress shows Hackage-verified current versions, the proposed
   version set, and a recorded user confirmation; `kiroku-store-migrations` is listed as not
   released with the verified reason.
2. On the release commit, `grep -rn 'kiroku-store *\^>=' */*.cabal` shows only `^>=0.10`,
   `kiroku-metrics` bounds `kiroku-cli` at the released patch, every changelog has a dated section
   for its new version with the children's bullets intact, and
   `blueprints/kiroku-upgrade/blueprint.dhall` lists the `0.9.0.1 -> 0.10.0.0` edge at version
   `0.3.0`.
3. `nix fmt` is a no-op; `cabal build all`, `cabal test all`, `just test-matrix`,
   `nix flake check`, `nix build .#kiroku-store`, `nix build .#kiroku-metrics`, `just perf-check`,
   `just perf-telemetry`, `just adr-validate`, `just capabilities-validate`, and the strict
   improvement-request validation all pass on that commit, with counts and ratios recorded.
4. `cabal check` passes for all five packages; ten archives exist with recorded SHA-256 hashes;
   `./result/bin/kiroku-inspect --help` from the Nix build and `cabal run kiroku-inspect -- --help`
   both print usage.
5. Hackage serves `kiroku-store-0.10.0.0`, `kiroku-otel-0.2.0.11`, `kiroku-cli-0.2.0.9`,
   `kiroku-metrics-0.2.0.0`, and `shibuya-kiroku-adapter-0.5.1.6` (or the approved numbers) with
   documentation; five annotated tags peel to the release commit; five GitHub releases exist.
6. A clean consumer outside the worktree pinning those exact versions builds, runs, and prints
   its line; `cabal install kiroku-metrics:exe:kiroku-inspect` from Hackage produces a binary whose
   `--help` prints.
7. IR-8, IR-9, IR-10, IR-11, and IR-12 read `status: completed` with `completedAt` equal to
   `timestamp`, their `## Status` sections name the shipped versions and cite plan and MasterPlan,
   `log.md` has five `**Completion**` bullets, and the strict validator exits zero.
8. Milestone 5's three ADR questions are answered in the Decision Log with evidence, any new or
   amended record validates, Outcomes & Retrospective is written, and every Progress item is
   checked with a date.


## Idempotence and Recovery

Everything before the release commit is repeatable: reading state, editing versions and
changelogs, writing the blueprint edge, and running gates and archive builds change nothing
outside the working tree, and `git checkout -- <file>` undoes any edit. Archive generation can be
re-run; hashes are recorded per attempt, and only the hash of the archive actually uploaded is
release evidence.

Publishing is not idempotent, and the repository's rule comes from plan 69's incident: the tag
`kiroku-metrics-v0.1.0.2` was pushed before `cabal check` found a missing upper bound on the
example's `kiroku-test-support` dependency; Hackage never received 0.1.0.2; the tag was
preserved and the fix shipped as 0.1.0.3. Therefore: never reuse a version for different
contents, never move or delete a pushed tag, and never publish source that differs from what the
tag names. Before retrying any part of Milestone 3, inspect `git status`, `git log -1`,
`git tag --list '*-v*' | sort -V | tail -5`, `git ls-remote --tags origin | tail -5`, and each
package's Hackage page, decide which steps succeeded, and continue from the first step that did
not. If a package's upload fails after its tag is pushed, fix the package in a new commit, bump
it one more patch, tag and publish that, and record the orphaned tag in Surprises & Discoveries.
If an upload fails partway through the cohort, dependents of the failed package are not uploaded
until it succeeds; a published subset is recorded honestly.

If the user declines at either gate, the six children remain complete and valid on `master`, the
changelogs keep their `## Unreleased` sections, no `.cabal` version changes, and the five requests
stay `in_progress` with their evidence; this plan records the decision and stops.

Request completion and ADR edits are validated by strict profile checks; a failure names the
offending field (typically a `timestamp` that did not advance or a missing dated log entry) and
the fix is local. Keep `status: in_progress` until the clean-consumer proof exists; never set
`completed` on the strength of a local build or an unrefreshed index.


## Interfaces and Dependencies

Versions are intentionally unspecified until Milestone 1 confirms them; the expected set is in
the Decision Log. Release order is:

```text
kiroku-store
kiroku-otel
kiroku-cli
kiroku-metrics
shibuya-kiroku-adapter
```

`kiroku-store-migrations` is outside the cohort because it has no `kiroku-store` dependency and
no new migration; `kiroku-test-support` and `kiroku-jitsurei` are never published.

The public surface the clean consumer must find in the released packages (names as the children
specify them at planning time; confirm against the shipped export lists):

```haskell
-- kiroku-store 0.10.0.0, via Kiroku.Store
listStreams :: (HasCallStack, Store :> es) => Maybe Text -> Maybe StreamName -> Int32 -> Eff es (Vector StreamInfo)
listCategories :: (HasCallStack, Store :> es) => Maybe CategoryName -> Int32 -> Eff es (Vector CategoryName)
getEvent :: (HasCallStack, Store :> es) => EventId -> Eff es (Maybe RecordedEvent)
subscriptionDeadLetters :: (HasCallStack, Store :> es) => SubscriptionDeadLetterQuery -> Eff es SubscriptionDeadLetterPage
defaultSubscriptionDeadLetterQuery :: SubscriptionName -> SubscriptionDeadLetterQuery
subscriptionCheckpointInventory :: (HasCallStack, Store :> es) => Eff es SubscriptionCheckpointInventory

-- kiroku-metrics 0.2.0.0, via Kiroku.Metrics
data MetricsServerConfig = MetricsServerConfig { ..., cors :: !CorsPolicy }
allowedOrigin :: Text -> Either OriginError AllowedOrigin
corsAllowOrigins :: [AllowedOrigin] -> CorsPolicy
data ServerProviders = ServerProviders
    { webSocketServer :: !WS.ServerApp
    , subscriptionStatus :: !(Maybe SubscriptionStatusProvider)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)
    , browser :: !(Maybe StoreBrowser)
    , deadLetters :: !(Maybe DeadLetterProvider)
    }
storeServerProviders :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ServerProviders
withMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> (MetricsServer -> IO a) -> IO a
-- executable kiroku-inspect (component kiroku-metrics:exe:kiroku-inspect)
```

Tools used and why: `cabal` (build, test, check, sdist, haddock, upload, install), `nix` (fmt,
flake check, package builds), `just` (the gate recipes in `Justfile`), `git` and `gh` (commit,
tags, push, GitHub releases), `okf` and `mori` (bundle validation, handle allocation, dependents),
`shasum` and `tar` (archive evidence), `curl` from a host shell (Hackage state), and optionally
`dhall` (blueprint syntax). Locate dependency sources through `mori registry show <project> --full`
when behaviour is uncertain; do not inspect `/nix/store`. The only runtime service is PostgreSQL,
supplied by the dev shells for the suites and the matrix.

Dependency direction is unchanged by this plan: `kiroku-metrics` depends on `kiroku-cli` and
`kiroku-store`; `kiroku-otel`, `kiroku-cli`, and `shibuya-kiroku-adapter` depend on
`kiroku-store`; nothing in the repository depends on `kiroku-metrics`. Downstream projects
(`mori://shinzui/keiro`, `mori://shinzui/kioku`, `mori://shinzui/kawa`, and the others
Milestone 1 lists) consume the cohort through Hackage bounds and the blueprint edge, on their own
schedule.
