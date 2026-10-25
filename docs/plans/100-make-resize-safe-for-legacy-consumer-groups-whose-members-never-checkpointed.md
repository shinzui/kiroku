---
id: 100
slug: make-resize-safe-for-legacy-consumer-groups-whose-members-never-checkpointed
title: "Make resize safe for legacy consumer groups whose members never checkpointed"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T18:36:53Z
      verdict: "changes-requested"
      note: "Resolve seeded-resize retry semantics, version-gate upgrade guidance, and test distinct existing/new member positions; correct export instructions."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T18:39:37Z
      mode: "update"
      note: "Address review: document seeded-resize retries, add version-compatible atomic recovery, strengthen seed assertions, and correct exports."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T20:21:55Z
      mode: "update"
      note: "User confirmed no production use; defer seeded recovery API and tests, retain only documentation correction and BUG-5 triage."
---

# Make resize safe for legacy consumer groups whose members never checkpointed

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
Its original title and identifier are retained for existing references. The active
scope is documentation and bug triage; the proposed legacy recovery API is deferred.


## Purpose / Big Picture

On 2026-10-25 the user confirmed that this feature has never been used in production
and asked to avoid spending time on recovery functionality for an unused feature.
There is no production migration requirement to justify the proposed seeded-resize
API. This plan now corrects misleading guidance and records that scope decision.

The source-level defect remains: migration 0013 derives a consumer group's size from
its highest recorded member. If a configured member never ran, the derived size can
be too small. Ordinary resize then creates that member at the existing group's
minimum checkpoint, above events that nobody processed for that member. BUG-5 records
this mechanism; it is not a report of an observed production incident.

After this plan, the consumer guide and historical upgrade edge will distinguish an
ordinary resize from recovery of an incomplete legacy group and will no longer imply
that ordinary resize alone safely restores the latter's backlog. BUG-5 will retain
its evidence and explicitly record deferred implementation because of no production
use. No seeded-resize API, SQL change, migration repair, downstream integration,
recovery test matrix, release bump or performance experiment is required.


## Progress

- [ ] Milestone 1: `docs/user/consumer-groups.md` and `blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md` distinguish ordinary resizing from incomplete legacy recovery, remove the unsafe resize-only recommendation, and provide a stable warning section for Plan 102 to link.
- [ ] Milestone 2: BUG-5 and its bundle log record the user's no-production-use statement, deferred recovery implementation and a concrete reopening condition; invalid per-member-reset and released-migration-edit advice is corrected, and bundle validation passes.

The earlier implementation milestones are superseded, not completed. This revision
changes the plan only; the documentation and bug-triage deliverables remain pending.


## Surprises & Discoveries

The initial plan treated an inferred historical upgrade scenario as a production
recovery requirement. The user's 2026-10-25 statement removes that requirement.
Published package versions alone do not establish that the feature was deployed.

The previous review also established that `resetSubscriptionCheckpointsTx` resets
all persisted members for a subscription name, not selected individual members.
The existing BUG-5 workaround incorrectly claims otherwise. The proposed seeded API
had additional retry semantics and was unavailable to consumers on the historical
0.10 upgrade edge. These are reasons to avoid retaining it as incidental work after
the production recovery requirement was removed.


## Decision Log

- Decision: Keep released migration `kiroku-store-migrations/migrations/0013.sql`
  unchanged, including its comment.
  Rationale: Its bytes are checksummed. Correct advice in current documentation;
  absence of production use does not justify changing released payload identities.
  Date: 2026-10-21; retained on 2026-10-25.
- Decision: The earlier proposals for `NewMemberSeed`,
  `resizeConsumerGroupWithSeedTx`, distinct existing/new member positions, explicit
  seed retry tests and a tested atomic recovery recipe are superseded.
  Rationale: They were designed for legacy recovery, and the user confirmed on
  2026-10-25 that the feature has never been used in production. Do not implement or
  release these proposals without a newly established need.
  Date: 2026-10-25
- Decision: Retain only documentation correction and explicit bug triage.
  Rationale: Removing an unsafe recommendation is useful without adding a recovery
  product. BUG-5 remains a source-inspected issue, not a fixed defect or a production
  incident. Keep its existing `status: reported` and record deferral in prose rather
  than inventing a profile status or claiming runtime confirmation.
  Date: 2026-10-25
- Decision: Reopen implementation only when an actual retained incomplete legacy
  group needs recovery, or a concrete future consumer requirement establishes the
  need for a new seed API.
  Rationale: Scope and evidence should follow a real use case. No-production-use
  does not establish that every development or external database is disposable.
  Date: 2026-10-25


## Outcomes & Retrospective

The plan was narrowed on 2026-10-25 before implementation. The proposed public API,
SQL changes and recovery test work are removed from active scope. The two small
remaining documentation deliverables have not yet been implemented or accepted.


## Context and Orientation

A consumer group divides a subscription's streams among a configured number of
members. Each member has a checkpoint, the last processed global event position.
Migration `kiroku-store-migrations/migrations/0013.sql` records each existing group's
size as its highest stored member index plus one. A size-four group with rows only
for members zero through two therefore acquires stored size three. Startup refuses
a configured size of four with `ConsumerGroupSizeMismatch`.

`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs` defines ordinary
`resizeConsumerGroupTx`: stop all workers, lock the checkpoint set, and equalize
members at the existing minimum position. Its SQL is in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs`. For a genuine resize,
the old group covered the streams below that minimum. That assumption fails for an
incomplete legacy group whose missing member never processed its assigned streams.

The same checkpoint module exposes `resetSubscriptionCheckpointsTx`. It accepts
subscription names, updates every persisted member for those names, and creates no
missing rows. Do not describe it as a per-member reset. Existing resize behavior and
tests in `kiroku-store/test/Test/ConsumerGroupResize.hs` are unchanged by this plan.

The current migration paragraph in `docs/user/consumer-groups.md`, under "Resizing
The Group", directs an incomplete group to ordinary resize. The historical edge
`blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md` places its incomplete
legacy warning next to ordinary topology-change advice without clearly separating
the cases. BUG-5 is
`docs/bug-reports/post-migration-resize-skips-a-never-started-members-backlog.md`;
it records source inspection rather than an executed reproduction. Its workaround
and suggested-fix sections also contain per-member-reset and migration-edit advice
that must be corrected. Its profile is `docs/bug-reports/profile.dhall` and its update
log is `docs/bug-reports/log.md`.

[ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) explains the disjoint
member assignments; [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)
requires explicit, transaction-composable checkpoint mutations; and
[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
defines typed startup refusals and groups the lifecycle operations. These contracts
remain unchanged. No new seed rule or architecture decision is introduced, so this
scope revision requires no ADR amendment. No cross-repository dependency is needed.


## Plan of Work

Milestone 1 makes a small correction to the two existing guides. Keep ordinary
resize instructions for intentional topology changes. Add an "Incomplete legacy
groups" subsection under "Resizing The Group" in `docs/user/consumer-groups.md` that
explains why resize alone can skip a never-started member's backlog and links to
BUG-5. State that this scenario has no production use reported by the project owner
as of 2026-10-25 and that dedicated recovery implementation is deferred. Keep the
warning applicable to any retained data; absence of production use is not permission
to discard it. Disposable development fixtures can use their already established
rebuild workflow. If history must be retained, stop the workers and establish a
recovery requirement before performing checkpoint changes; do not present the
removed seeded API or an untested recovery recipe as available functionality.

Add the same distinction to the historical upgrade edge, linking to the guide's
`#incomplete-legacy-groups` anchor. Preserve its cohort bounds, stopped-worker
requirement and existing restrictions on changing persistent databases. Plan 102
can then link to this warning without waiting for a new API or recovery test suite.

Milestone 2 triages BUG-5. Preserve the reproduction, affected versions, source
inspection evidence and `status: reported`. Add a dated disposition explaining the
user's statement, the deferred implementation and the reopening condition from the
Decision Log. Replace the incorrect per-member-reset workaround with the verified
API limitation: reset affects all persisted members and creates none; any eventual
recovery must account for missing rows and possible whole-group replay. Do not claim
that a recovery procedure has been validated or that the defect is fixed. Revise the
suggested fixes as deferred alternatives, removing advice to edit released migration
bytes and any promise that reset selects individual members. Add a dated update to
`docs/bug-reports/log.md` in its existing format and run bundle validation. No
`fixedVersion`, new API changelog entry or version bump is warranted.


## Concrete Steps

All commands run from the repository root. Inspect the edited advice together:

```bash
rg -n 'Incomplete legacy|incomplete|resize|reset|production|defer'   docs/user/consumer-groups.md   blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md   docs/bug-reports/post-migration-resize-skips-a-never-started-members-backlog.md
```

Review the matches for the distinction between ordinary resizing and incomplete
legacy recovery, and for accurate reset scope. Validate the two maintained surfaces:

```bash
okf validate docs/bug-reports --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
seihou validate-blueprint blueprints/kiroku-upgrade
git diff --check
```

Expected: each command exits zero; concept counts may grow with unrelated work.
Check relative Markdown links and the new guide anchor manually. No compilation,
database test or benchmark is required for these prose-only changes. `nix fmt`
configures Nix, Haskell and Cabal formatters, not a Markdown validation pass.


## Validation and Acceptance

Milestone 1 is accepted when a reader can distinguish an ordinary topology change
from an incomplete legacy group and cannot interpret resize alone as a lossless
repair of the latter. The guide anchor and edge link must resolve, and blueprint
validation must pass. Neither guide may promise a new seed API, a tested recovery
recipe or permission to discard retained data.

Milestone 2 is accepted when BUG-5 preserves its evidence, remains `reported`, records
no production use and deferred implementation with the reopening condition, and no
longer suggests an unavailable per-member reset or an edit to released migration
bytes. Its bundle log and validation must agree. Completion of this documentation
plan does not mean the underlying defect is fixed or runtime-confirmed.


## Idempotence and Recovery

This plan edits prose and the bug bundle log only. Preserve historical evidence and
append one dated disposition rather than duplicating it on each pass. No database
is opened or modified. Released migration bytes remain unchanged. If implementation
is reopened, reassess the actual data and required replay behavior before restoring
any earlier API proposal; the superseded design is not automatic authorization.


## Interfaces and Dependencies

No public API, runtime SQL, schema, package bound or downstream interface changes.
The implementation touches the consumer guide, the historical upgrade edge, BUG-5
and its log. Plan 102's migration guide depends only on milestone 1's accurate warning
and anchor; it does not depend on legacy recovery implementation. No new changelog
entry is required by Plan 100, and ordinary release-surface errata remain Plan 102's
responsibility.

Revision note (2026-10-25, earlier review): The original proposal was refined to
specify seeded-resize retries, a version-compatible fallback and distinct-position
tests. Those implementation requirements are superseded by the following decision.

Revision note (2026-10-25, user scope decision): The user confirmed no production use.
Replaced seeded recovery implementation and its tests with two documentation/triage
milestones, retained the defect evidence, and made actual recovery demand the
condition for reopening the API work.
