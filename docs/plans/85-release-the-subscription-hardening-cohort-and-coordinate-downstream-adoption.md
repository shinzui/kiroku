---
id: 85
slug: release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption
title: "Release the subscription hardening cohort and coordinate downstream adoption"
kind: exec-plan
created_at: 2026-08-27T21:14:25Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: release gate omitted ADR-5 perf-check and perf-telemetry"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Added perf-check and perf-telemetry to the release gate"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: updated forecast of public-surface changes and migrations for the release gate and clean-consumer proof"
---

# Release the subscription hardening cohort and coordinate downstream adoption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plans 81, 82, 83, 84, and 86 change Kiroku behavior and public surfaces across the store,
migrations, observability consumers, and Shibuya adapter. Source-only completion is insufficient:
downstream users need a coherent published package set, and Keiro must consume Kiroku's supported
consumer-group resize operation instead of reaching into checkpoint tables.

After this plan, every affected Kiroku package has a PVP-correct independently versioned Hackage
release, matching source/docs archives, annotated tag, and GitHub release. A clean external
consumer resolves the cohort. In `mori://shinzui/keiro`, shard-count changes use the released
transaction-composable resize API to update Kiroku checkpoints and Keiro lease rows atomically;
the old transferred plan stays retired. No publication or downstream commit occurs without the
user's explicit release-time confirmation.


## Progress

- [ ] Gate: plans 81, 82, 83, 84, and 86 are complete, their living sections are current, and required ADR/OKF validation passes.
- [ ] M1: determine changed packages and PVP impact from commits since authoritative tags; verify Hackage and upstream tags rather than trusting local registry versions.
- [ ] M1: present exact package versions, bounds, and changelogs for user confirmation before editing release metadata.
- [ ] M2: update approved versions/bounds/changelogs and pass formatting, build, test, ADR-5 performance, migration, sdist, Haddock, and flake gates.
- [ ] M3: after a second explicit publication confirmation, commit, tag, push, publish Hackage/docs and GitHub releases in dependency order; verify clean-consumer resolution.
- [ ] M4: adopt the released public resize operation in `mori://shinzui/keiro` and prove atomic shard/checkpoint resizing without private Kiroku SQL.
- [ ] Record release URLs, tag commits, clean-consumer evidence, downstream commit, and retrospective.


## Surprises & Discoveries

- Transfer audit (2026-08-27): the July source plan forecast `kiroku-store` 0.4 and adapter 0.5.
  Current source is already `kiroku-store` 0.8.0.0 and `shibuya-kiroku-adapter` 0.5.1.1. No
  forecast version from the transferred plan is usable release evidence.
- Transfer audit (2026-08-27): Kiroku packages are versioned and tagged independently. A store API
  change may require bound-only patch releases of internal dependents even when their runtime
  behavior did not change.
- Transfer audit (2026-08-27): Keiro already refuses a startup `ShardCountMismatch` but offers no
  supported resize. Its `ensureShards` transaction inserts missing lease rows before it checks
  recorded counts, so a resize operation must be separately named and atomic rather than weakening
  that startup guard.


## Decision Log

- Decision: Do not choose package versions until every implementation plan is complete and current
  Hackage versions plus upstream tags have been verified.
  Rationale: PVP impact depends on the final exported types and semantics. The local Mori corpus is
  for source discovery and may lag authoritative release state.
  Date: 2026-08-27

- Decision: Follow the repository release skill exactly, including independent package versions,
  dependency order, and user confirmation before release metadata edits and publication.
  Rationale: A master plan does not broaden authority to commit, tag, push, or upload packages.
  The skill captures Kiroku's established release invariants.
  Date: 2026-08-27

- Decision: Release Kiroku before changing Keiro and adopt only public transaction-composable APIs.
  Rationale: Downstream bounds and compilation must be based on a retrievable artifact. Composing
  Kiroku checkpoint resize with Keiro lease-table resize in one Hasql transaction avoids the split
  state that private sequential SQL would create.
  Date: 2026-08-27

- Decision: Keep Keiro release out of scope unless separately authorized.
  Rationale: The acceptance target is downstream source adoption and test evidence. Publishing
  Keiro is a separate external action with its own release process.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Kiroku's repository release instructions are in `.agents/skills/release/SKILL.md`. Publishable
packages, in dependency order, are `kiroku-store`, `kiroku-store-migrations`, `kiroku-otel`,
`kiroku-cli`, `kiroku-metrics`, and `shibuya-kiroku-adapter`. Only packages changed since their
last package-specific tag need a release, but a new `kiroku-store` major/minor line can require
dependent bound updates and corresponding patch releases. `kiroku-test-support` and example/test
components are not Hackage packages.

Plans 81 and 82 change checkpoint public APIs and each adds a migration. Plan 83 changes the type
of `decodeHook` in `StoreSettings`, makes `RetryPolicy` a record, and adds a `StoreError`
constructor, a dead-letter reason, and an observability constructor. Plan 84 adds a store
subscription config field and observability constructor and changes both adapter config records.
Plan 82 also adds an exception-hierarchy parent for startup failures. Plan 86 is an internal bug
fix. Their final diffs, not these forecasts,
determine PVP. Relevant durable records are [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md),
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md), and any ADR created by plan 83
or 84.

Use Mori to discover reverse dependencies with `mori registry dependents shinzui/kiroku
--packages --json`, but verify released versions against Hackage and package tags. The release
skill requires all package tests, `nix fmt`, `cabal build all`, `cabal test all`, and
`nix flake check` before publication, then `cabal check`, source archive, and Hackage Haddock
archive per package. This plan additionally requires the
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) gates `just perf-check` and
`just perf-telemetry`, because plans 81 through 84 change the checkpoint upsert, the publisher
loop, and the adapter bridge; the MasterPlan's Performance gates integration point names the
telemetry cells to report.

The downstream repository is `mori://shinzui/keiro`. Its project-relative
`keiro/src/Keiro/Subscription/Shard.hs` defines `ensureShards` and
`ShardCountMismatch`; `keiro/src/Keiro/Subscription/Shard/Schema.hs` owns the
`keiro_subscription_shards` transaction statements. `ensureShards` currently proves startup
topology matches but cannot resize it. The transferred source master plan is
`mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review`
and remains a historical transfer record.


## Plan of Work

### Milestone 1 — establish release truth and obtain approval

Confirm all five implementation child plans are complete. Inspect each publishable package's
current Cabal version, newest `<package>-v*` tag, commits since that tag, changelog, and public API
diff. Query Hackage and upstream tags at execution time. Use Mori reverse dependencies to identify
registered consumers, then inspect in-repository dependency bounds.

Produce a review table with package, current authoritative version, last tag, change set, proposed
PVP bump, dependent bound edits, and justification. Show every proposed Cabal/changelog edit.
Stop and request user confirmation as required by the release skill. Do not edit versions merely
because this plan has reached the gate.

### Milestone 2 — prepare and verify the approved cohort

Apply only the approved independent bumps. Update every internal dependency bound in library, test,
executable, and benchmark stanzas; add dated changelog sections. Plans 81 and 82 each add a
migration; prove both fresh installation and upgrade from the newest released manifest snapshot,
including that plan 82's column addition rewrites no rows.

Run repository-wide formatting/build/test/flake gates, then `just perf-check` and
`just perf-telemetry`; record the telemetry cells named in the MasterPlan's Performance gates
integration point against their baseline rows. Run `cabal check`, `cabal sdist`, and
Hackage Haddock generation for each proposed package without uploading. Inspect each source
archive for its public modules, migration manifest/payload, changelog, license, and generated
documentation. Stage newly created files before `nix flake check` so Nix sees them, but do not
commit.

Present the final diff, test matrix, archive names/hashes, and package order. Request explicit
confirmation before commit, tags, push, or upload.

### Milestone 3 — publish and independently verify

After confirmation, create one Conventional Commit release commit, one annotated package tag per
released package, and push commit plus tags. Upload source and documentation archives in dependency
order; stop immediately if any dependency upload fails. Create one GitHub release per tag.

Refresh package metadata and build a clean temporary consumer outside the worktree using exact
published versions. Import the new store resize and rebind operations, the typed decode hook, the
startup-failure parent, the handler-stall event, and the adapter config fields, run a minimal
compile, and record Hackage URLs, hashes, annotated tag objects/peeled commits, GitHub release URLs,
and consumer transcript in Outcomes.

### Milestone 4 — adopt safe resize in Keiro

Only after Hackage verification, update `mori://shinzui/keiro` dependency bounds to the released
cohort. In its project-relative `keiro/src/Keiro/Subscription/Shard/Schema.hs`, add transactional
helpers that lock the complete subscription lease-row set and refuse resize while any owner is
active. Add `resizeShardCount` in `keiro/src/Keiro/Subscription/Shard.hs`. In one
`Hasql.Transaction.Transaction` it must:

1. validate the new count is positive and lock existing Keiro shard rows;
2. refuse with typed `ShardResizeActiveLeases` unless every owner is clear;
3. call Kiroku's released `resizeConsumerGroupTx` for the same subscription;
4. replace Keiro rows with buckets `0 .. newSize - 1` and the new recorded count;
5. return both Kiroku's resume position/report and Keiro's old/new topology.

Retain `ensureShards` as a strict startup guard. Add tests for active-lease refusal, idempotent
same-size resize, deliberately skewed Kiroku checkpoints, atomic rollback after injected failure,
and post-resize delivery with no missing event ids. The test must import the released public
module and contain no SQL against `kiroku.subscriptions`. Update Keiro's shard documentation and
transferred-plan status. Commit only if separately authorized by the user; do not release Keiro in
this plan.


## Concrete Steps

Run release preparation from the Kiroku repository root:

```bash
mori registry dependents shinzui/kiroku --packages --json
git tag --list '*-v*' --sort=-version:refname
nix fmt
cabal build all
cabal test all --test-show-details=direct
nix flake check
just perf-check
just perf-telemetry
```

For every package approved for release, from its package directory:

```bash
cabal check
cabal sdist
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
```

The release skill supplies the exact commit, tag, upload, and GitHub commands once the versions
are known. Do not substitute placeholder versions into executable commands. Expected pre-release
evidence has this shape:

```text
package                         PVP decision   source archive   docs archive   tests
kiroku-store                    <approved>     present          present        PASS
shibuya-kiroku-adapter          <approved>     present          present        PASS
<affected dependents>           <approved>     present          present        PASS
```

After publication, run from a fresh temporary consumer and record exact version constraints:

```bash
cabal update
cabal build all
```

Then run from `mori://shinzui/keiro`:

```bash
cabal build keiro:keiro-test
cabal test keiro:keiro-test \
  --test-show-details=direct \
  --test-options='--match "shard count resize"'
cabal test keiro:keiro-test --test-show-details=direct
```


## Validation and Acceptance

All Kiroku child-plan acceptance tests, ADR/OKF gates, ADR-5 performance gates, package tests,
migration paths, source archives, Haddocks, and flake checks must pass before publication. Hackage
source/docs versions, annotated tags, GitHub releases, and peeled commits must agree. A clean
consumer must resolve only published artifacts and compile the new APIs.

Keiro acceptance requires an active lease to refuse before either table changes; a stopped
skewed-size group must atomically equalize Kiroku checkpoints and replace Keiro shard rows; a
forced transaction failure must leave both old topologies intact; repeating the operation must be
idempotent; and new workers must deliver every seeded event id at least once. No downstream
module, test, or documentation may use private Kiroku checkpoint SQL.


## Idempotence and Recovery

Readiness checks, builds, tests, archive generation, and clean-consumer verification are
repeatable. Version/changelog edits remain uncommitted until approved and can be corrected with a
new patch. Never overwrite a published Hackage version or move an existing tag.

If an upload fails, stop before publishing any dependent and resume with the same immutable
archive after diagnosing it. If a package was published but a later dependent fails, record the
partial cohort honestly and publish the dependent only after its gate passes. The Keiro resize
transaction is atomic and repeatable; at-least-once rewind may duplicate deliveries but cannot
lose events. External publication and commits are not implied by executing earlier milestones.


## Interfaces and Dependencies

Versions are intentionally unspecified until milestone 1. Release order is:

```text
kiroku-store
kiroku-store-migrations
kiroku-otel
kiroku-cli
kiroku-metrics
shibuya-kiroku-adapter
```

Only changed packages and dependents needing new bounds are published. Kiroku source discovery
uses `mori://shinzui/kiroku` and downstream discovery uses `mori://shinzui/keiro`; Hackage and
upstream tags remain authoritative for release selection.

Keiro's public adoption surface has this semantic shape:

```haskell
resizeShardCount ::
    (Store :> es) =>
    SubscriptionName ->
    Int ->
    Eff es ShardResizeResult
```

`ShardResizeResult` includes Kiroku's `ConsumerGroupResizeResult` plus old/new Keiro counts.
`ShardResizeActiveLeases` identifies the subscription and active buckets without exposing private
Kiroku schema. The implementation composes the released
`Kiroku.Store.Subscription.ConsumerGroup.resizeConsumerGroupTx` with Keiro's Hasql transaction;
no new external dependency is expected beyond the approved Kiroku bound.


Revision note (2026-09-09): Performance review under ADR-5. Added `just perf-check` and
`just perf-telemetry` to the release gate in Progress, Context, milestone 2, the concrete steps,
and acceptance, with the telemetry cells owned by the MasterPlan's Performance gates integration
point.

Revision note (2026-09-09): Design review. Updated the forecast of public-surface changes from
plans 82, 83, and 84 (typed decode hook, `RetryPolicy` record, startup-failure parent, worker
stall event, two migrations) so the release gate and the clean-consumer proof cover them.
