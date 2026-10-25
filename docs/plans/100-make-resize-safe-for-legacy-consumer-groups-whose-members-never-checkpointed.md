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
---

# Make resize safe for legacy consumer groups whose members never checkpointed

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A consumer group splits one subscription across N members; each member owns the
streams whose id hashes to its index, so an event one member skips is skipped by the
whole group. Migration `0013` (kiroku-store-migrations 0.7.0.0) persisted each group's
size by deriving it from existing rows as `max(member) + 1`. A group that was configured
at size 4 but whose member 3 never ran before the upgrade therefore derives size 3; a
kiroku-store 0.10 worker configured at size 4 refuses to start; and the remedy the
migration comment, plan 81 and `docs/user/consumer-groups.md` prescribe,
`resizeConsumerGroupTx`, inserts the missing member at the group's minimum
checkpoint. Member 3's slice below that minimum was never processed by anyone, so
those events are skipped permanently and silently. On kiroku-store 0.9 the same member
would have initialized from position 0 and caught up. This is bug report BUG-5 in
`docs/bug-reports/post-migration-resize-skips-a-never-started-members-backlog.md`,
found by review REV-2.

After this plan an operator can resize an incomplete legacy group and choose where the
members that have no history start: at the group minimum (today's behaviour, right for
a genuine grow because the old members covered every stream below it) or at an
explicit position such as 0 (right for a member that never ran). The user guide, the
upgrade edge and the bug report say exactly when to use which, a test proves the
never-started member receives its backlog, and BUG-5 moves to `fixed`.


## Progress

- [ ] Milestone 1: a failing test in `kiroku-store/test/Test/ConsumerGroupResize.hs` reproduces BUG-5 against the current code (events in a never-started member's slice below the group minimum are not delivered after the documented resize), and the bug report moves to `confirmed`.
- [ ] Milestone 2: `resizeConsumerGroupWithSeedTx` exists in `Kiroku.Store.Subscription.Checkpoint` and is available through `Kiroku.Store`'s existing module re-export; tests verify distinct existing/new member positions, nonzero seeds, repeat behavior and backlog delivery, while `resizeConsumerGroupTx` retains its current semantics.
- [ ] Milestone 3: `docs/user/consumer-groups.md`, the `0.9.0.1 -> 0.10.0.0` upgrade edge and the kiroku-store changelog describe the version-appropriate incomplete-legacy procedure, retry behavior and the stale-row direction; the existing-API fallback is tested; BUG-5 is `fixed` with a resolution; ADR-8 carries the seed rule.


## Surprises & Discoveries

- Review against the current implementation found that an explicit seed below the
  old minimum makes a repeated resize rewind existing members again, even with no
  intervening worker activity. For existing positions 100, 120 and 110, adding a
  member at zero yields 100, 100, 100, 0; repeating yields 0, 0, 0, 0. This follows
  from recomputing the minimum on each invocation and needs a documented contract
  and regression coverage, not the default resize's idempotence claim.
- `Kiroku.Store.Subscription` does not export checkpoint lifecycle operations.
  `Kiroku.Store` already re-exports the entire checkpoint module. The new exports
  therefore belong only in the checkpoint module's explicit export list.
- The historical upgrade edge selects `kiroku-store ^>=0.10.0.0`, which does not
  provide the proposed API. Its primary recovery procedure must use the already
  available resize and whole-group reset operations in one transaction.


## Decision Log

- Decision: Migration `0013.sql` is not edited, not even its comment.
  Rationale: The migration runner checks each applied migration's checksum; changing
  the file would require a ledger fixup on every deployed database (see BUG-1 and
  `kiroku-store-migrations/ledger-fixups/`). The corrected guidance lives in the user
  guide, the upgrade edge and the new API's documentation instead.
  Date: 2026-10-21
- Decision: The fix is an additive sibling, `resizeConsumerGroupWithSeedTx`, and
  `resizeConsumerGroupTx` keeps its current semantics.
  Rationale: Seeding at the minimum is correct for a genuine grow and is what plan 81
  shipped and tested; changing it would redeliver whole histories for every consumer
  that grows a group. An additive export is a minor-version change under the PVP, so
  the fix can ship as kiroku-store 0.11.1.0 without forcing a cohort.
  Date: 2026-10-21
- Decision: The changelog entry is drafted under a `## Unreleased` heading in
  `kiroku-store/CHANGELOG.md`; release preparation renames it to the version it ships in.
  Rationale: The repository has no standing unreleased section, and the version is
  chosen at release time, which plan 102 and the release procedure own.
  Date: 2026-10-21

- Decision: Explicit seeding applies only to rows absent at the start of that
  invocation; every invocation rewinds surviving rows to the current minimum.
  Rationale: This preserves the proposed SQL and the existing resize contract.
  A seeded resize is not generally idempotent: a repeat after a lower seed can
  cause additional replay. Document and test this rather than introducing new
  persisted recovery metadata. An uncertain commit must be inspected before retry.
  Date: 2026-10-25
- Decision: Keep checkpoint lifecycle exports in `Kiroku.Store.Subscription.Checkpoint`,
  available through `Kiroku.Store`'s existing module re-export, without adding them
  to `Kiroku.Store.Subscription`.
  Rationale: This follows the current public API organization and avoids an
  unrelated new export path.
  Date: 2026-10-25
- Decision: The historical 0.10 upgrade edge uses atomic resize followed by a
  whole-group reset to zero as its compatible recovery procedure. The new API is
  an alternative only for a release that actually exports it.
  Rationale: The edge's existing version bounds exclude the planned additive
  release. Reset accepts subscription names, not individual member keys, so the
  compatible fallback deliberately replays the whole group. Release preparation
  records the first shipping version; until then the new API is labelled unreleased.
  Date: 2026-10-25


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL event store in Haskell. Subscriptions deliver events from the
global log (`$all`) or a category; a consumer group is a subscription split across N
members by `hashtextextended(stream_id::text, 0) % N`. Each member's checkpoint is a
row in `kiroku.subscriptions` keyed by `(subscription_name, consumer_group_member)`
with the columns `last_seen` (the last delivered global position),
`consumer_group_size`, `target_kind` and `target_category`.

The checkpoint-set operations live in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs`:
`resetSubscriptionCheckpointsTx` (sets named subscriptions to one position),
`resizeConsumerGroupTx` (lines 99 to 115) and `rebindSubscriptionTargetTx`. They are
`hasql-transaction` `Tx.Transaction` values so a caller can compose them with its own
SQL in one transaction; callers run them through `runTransaction` from
`Kiroku.Store.Transaction`. `resizeConsumerGroupTx` locks the name
(`lockCheckpointNameStmt`), locks and reads every row (`lockCheckpointRowsStmt`),
computes `position` as the minimum `last_seen` across the rows (0 when there are none),
and runs `resizeCheckpointMembersStmt` from
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` (lines 254 to 276), whose
SQL deletes members at or above the new size, inserts every member in
`generate_series(0, size - 1)` with `last_seen = $3`, and on conflict updates
`consumer_group_size` and `last_seen = EXCLUDED.last_seen`. Every member, new or
existing, therefore ends at the minimum. It returns `ConsumerGroupResizeReport`
(`previousSizes`, `previousMemberCount`, `newSize`, `resumePosition`).

`resetSubscriptionCheckpointsTx` takes a non-empty collection of subscription names
and one `GlobalPosition`; it resets every persisted member for those names and does
not select individual members. This makes resize followed by reset in the same
transaction a compatible whole-group replay procedure. The public export list in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs` owns these operations;
`kiroku-store/src/Kiroku/Store.hs` re-exports that whole module, whereas
`kiroku-store/src/Kiroku/Store/Subscription.hs` does not.

Startup verification is in the same SQL module: `initializeWorkerCheckpointSession`
takes a per-name advisory lock, reads the rows and refuses with
`ConsumerGroupSizeMismatch name configured [stored sizes]` under
`SomeSubscriptionStartupFailure` when the stored size disagrees. The worker
(`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`) surfaces the refusal from
`wait` and emits `KirokuEventSubscriptionGroupSizeMismatch`.

On kiroku-store 0.9.0.1 a member without a row went through
`initializeSubscriptionCheckpointStmt` (git `94e1139`,
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` lines 66 to 76), whose
`from_beginning` policy resolved to position 0.

Tests for resize are in `kiroku-store/test/Test/ConsumerGroupResize.hs`; the case
"refuses an underestimated derived topology until resized" (line 63) builds rows that
mimic a 0013-derived underestimate and asserts the seeded-at-minimum row shape, and
"delivers every seeded event after equalizing size 2 to size 3" (line 132) shows how to
seed streams for specific members and assert delivery. The migration suite
`kiroku-store-migrations/test/Main.hs` has a 0013 derivation case at line 335. Both
suites run against an ephemeral PostgreSQL started by `kiroku-test-support`.

Documentation that prescribes the lossy remedy: `docs/user/consumer-groups.md`,
section "Resizing The Group" (line 146) and its migration paragraph (line 189);
`blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md` lines 53 to 66; the
comment at the top of `kiroku-store-migrations/migrations/0013.sql` (which must not be
edited, see Decision Log). The CLI package `kiroku-cli` has no resize command, so it
needs no change. The keiro framework (`mori://shinzui/keiro`) composes Kiroku's resize
with its own shard lease rows; exposing the new seed through keiro's composed resize is
a follow-up for that repository and is noted, not done, here.

Relevant ADRs: [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md) fixes
the static hash partitioning that makes a member's slice exclusive;
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) establishes that
checkpoint lifecycle mutations are explicit, atomic operator actions;
[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
decision 2 says values a migration can derive are derived in the migration rather than
adopted at runtime, decision 4 says the store never skips an event on a consumer's
behalf, and decision 5 keeps reset, resize and rebind together. The seed rule this plan
adds belongs with decisions 4 and 5. No cross-repository ADR applies.


## Plan of Work

Milestone 1 reproduces the loss. Add a case to `ConsumerGroupResize.hs` that, with the
helpers already in that file, appends events whose stream ids hash to member 3 of 4 at
positions below 100 and to members 0 to 2 as well; writes rows for members 0, 1 and 2
only, with `consumer_group_size = 3` and `last_seen` 100, 120 and 110, exactly as 0013
would have derived them; asserts that starting a size-4 member refuses with
`ConsumerGroupSizeMismatch`; runs `resizeConsumerGroupTx` at size 4 through
`runTransaction`; starts all four members with a collecting handler; and asserts that
every seeded event in member 3's slice is delivered. On the current code the assertion
fails because member 3 starts at 100. Keep the case, mark it with the bug id in its
description, and when it fails for the expected reason update BUG-5 to
`status: confirmed` with a one-line `okf log add` entry and a bundle validation.

Milestone 2 adds the seed. In `Checkpoint.hs` define
`data NewMemberSeed = SeedAtGroupMinimum | SeedAtPosition GlobalPosition` and
`resizeConsumerGroupWithSeedTx :: SubscriptionName -> ConsumerGroupSize -> NewMemberSeed -> Tx.Transaction ConsumerGroupResizeReport`;
redefine `resizeConsumerGroupTx name size = resizeConsumerGroupWithSeedTx name size SeedAtGroupMinimum`.
In `Checkpoint/SQL.hs` give `resizeCheckpointMembersStmt` a sixth parameter, the new
members' position, so the `INSERT ... SELECT` uses it for `last_seen` while the
`ON CONFLICT DO UPDATE` sets `last_seen = $3` (the rewind position) explicitly instead
of `EXCLUDED.last_seen`; with both parameters equal to the minimum the statement is the
one that ships today, which the existing resize tests will confirm. The report's
`resumePosition` remains the pre-operation group minimum (zero for an absent group),
which is assigned to surviving existing members; inserted members use the chosen
seed. Rewrite the report Haddock so its claims about all members starting at the
same position, absent groups starting at zero and repeats preserving progress apply
only to the default minimum-seeded operation. An absent group given an explicit
seed inserts all its members at that seed, while `resumePosition` is still zero.
Document that a seed is a checkpoint: delivery resumes strictly after that position.
The new function requires all workers stopped, preserves transaction composition
and rollback, and explicitly documents the repeat behavior below.

Add `NewMemberSeed(..)` and `resizeConsumerGroupWithSeedTx` to the export list in
`kiroku-store/src/Kiroku/Store/Subscription/Checkpoint.hs`.
`kiroku-store/src/Kiroku/Store.hs` already imports and re-exports the entire module,
so it requires no new export line. Leave
`kiroku-store/src/Kiroku/Store/Subscription.hs` unchanged. The tests' existing
`import Kiroku.Store` exercises the umbrella export. Change the milestone 1 test to call the new function with
`SeedAtPosition (GlobalPosition 0)` and keep a sibling case that documents the minimum
seed's behaviour for a genuine grow, so both semantics stay pinned.

Before starting workers, assert that the seeded resize transforms rows
`[(0,3,100),(1,3,120),(2,3,110)]` into
`[(0,4,100),(1,4,100),(2,4,100),(3,4,0)]` and reports `resumePosition = GlobalPosition 100`.
Use an independent fixture with `SeedAtPosition (GlobalPosition 25)` to require
the same existing-member positions and member 3 at 25. These assertions must fail
if the implementation assigns the explicit seed to every member or ignores its
value. In a separate repeat case, run the zero-seeded resize twice with workers
still stopped: the second result must contain four positions of zero and report
`resumePosition = GlobalPosition 0`, retaining member identities. Keep the backlog
delivery test independent of this repeat so a second resize cannot hide incorrect
first-call behavior.

Milestone 3 fixes the words. In `docs/user/consumer-groups.md` replace the migration
paragraph with one that distinguishes the two situations: a genuine grow uses
`resizeConsumerGroupTx` and redelivers from the minimum; an incomplete legacy group,
one whose derived size is smaller than the configured size because members never ran,
uses `resizeConsumerGroupWithSeedTx` with `SeedAtPosition 0` (or the subscription's
original start position) so the never-started members replay their slices, and the
operator must expect those members to process their whole history. Add the reverse
case too: a group shrunk under 0.9's stop-and-restart procedure keeps stale higher rows,
0013 derives the old larger size, and the forced resize rewinds live members to the
stale rows' positions, which is redelivery rather than loss. Qualify the guide's
existing claim that repeating resize preserves positions: it applies to the
minimum-seeded operation without intervening progress, not an explicit lower seed.
Include the retry and uncertain-commit guidance from Idempotence and Recovery.

In `blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md`, preserve the existing
cohort bounds and use the existing-API fallback below as the primary procedure for
an incomplete legacy group. Include it in the user guide too. Stop every worker,
run resize then reset the whole group to zero in one transaction, commit, and only
then restart; all members may replay their full history. This also repairs a group
whose missing members were already created by the old minimum-seeded remedy.
Where a framework owns lease rows, retain the edge's requirement to use its composed
resize and include the reset in the same caller transaction; do not bypass the lease
update. Mention the seeded API only as an unreleased alternative until release
preparation identifies its first shipping version, then name that version explicitly.
Never instruct a consumer staying on the 0.10 cohort to call the new function.

The fallback transaction body uses only existing public APIs:

```haskell
import Data.List.NonEmpty (NonEmpty (..))
import Hasql.Transaction qualified as Tx
import Kiroku.Store

repairLegacyGroupTx ::
    SubscriptionName -> ConsumerGroupSize -> Tx.Transaction SubscriptionCheckpointResetReport
repairLegacyGroupTx name size = do
    _ <- resizeConsumerGroupTx name size
    resetSubscriptionCheckpointsTx (name :| []) (GlobalPosition 0)
```

Run that body through `runTransaction` (or the existing test helper's pool-backed
transaction runner). Add a focused test using the legacy fixture that asserts all
four rows are at zero after the transaction and member 3 receives its backlog.
Condemning the composed transaction must leave the original three rows unchanged.
This validates the fallback without claiming that only missing members were reset.

Draft the `## Unreleased` changelog entry in `kiroku-store/CHANGELOG.md`, describing
the new seed choice and the repeat caveat. Update BUG-5 to `status: fixed`,
`fixedVersion: "unreleased"`, with a `resolution` naming the new function and the test,
correct its workaround to describe the whole-group fallback (reset cannot select
individual members), and add the log entry. Finally amend ADR-8
with one dated paragraph: a resize may seed a member at the group minimum only when
that member's slice below the minimum was covered by existing members; a member with no
row is seeded by explicit operator choice, and repeating an explicit lower-seeded
resize can rewind the remaining members further. Bump the ADR timestamp, add the log entry
and run strict validation.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build kiroku-store:kiroku-store-test
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "resize"'
```

Before milestone 2 the new case fails like this (illustrative):

```text
  delivers a never-started member's backlog after resize (BUG-5) [✘]
    expected: delivered positions for member 3 to include [12,37,58,91]
     but got: []
```

After milestone 2 the whole resize group passes. Then run the full suite once:

```bash
cabal test all
```

Bug report and ADR bundle maintenance:

```bash
okf log add docs/bug-reports   # follow the prompt, or edit log.md by hand in the same format
okf validate docs/bug-reports --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected: `OK: 5 concepts (okf_version 0.2)` and `OK: 20 concepts (okf_version 0.2)`.

Formatting before committing:

```bash
nix fmt
```


## Validation and Acceptance

Milestone 1 is accepted when the new test fails on the unchanged code for the stated
reason and passes nowhere else, and BUG-5 validates as `confirmed`.

Milestone 2 is accepted when: the new test passes with `SeedAtPosition 0` after one
resize; pre-start row assertions distinguish existing members at 100 from the new
member at zero, and an independent nonzero-seed case places only the new member at
25; the repeat case confirms the documented second-call rewind and report; the existing
resize cases ("delivers every seeded event after equalizing size 2 to size 3",
"is idempotent when repeated at the same size and retains surviving member identities",
"starts a missing group at zero and removes obsolete members on shrink", "rolls back the
complete resize with the caller transaction") still pass unchanged, proving
`resizeConsumerGroupTx` kept its semantics; and `cabal test all` passes. The user-visible
proof is the test transcript showing member 3's seeded positions delivered after the
seeded resize and absent after the minimum resize.

Milestone 3 is accepted when the three documents describe both procedures and the
explicit-seed retry caveat; the 0.10 edge's primary fallback uses only existing APIs,
keeps its cohort bounds and passes the focused delivery and rollback tests; the new
API is explicitly labelled unreleased or tied to its verified first shipping release; the
changelog entry exists, BUG-5 is `fixed` with a resolution and both bundle validations
pass, and the ADR amendment validates strictly. The upgrade edge is prose read by an
agent, so also run the blueprint's own validation if one exists (`just` lists recipes;
`seihou` validation ran in the release records under `bench/mp13-release/publication-2026-10-11/blueprint-validation.log`
and shows the command used).

Proposed, not required: a keiro improvement request asking its composed resize to
expose the seed, filed in `mori://shinzui/keiro` once this ships.


## Idempotence and Recovery

The SQL change is to a runtime statement, not a migration; no schema or migration
ledger change is required. Existing resize tests cover the default equal-parameter
path; the new distinct-position tests are required to cover explicit seeding.
Tests use fresh ephemeral databases and can be rerun freely. Bug report and ADR
edits are additive; if `okf validate` complains, fix frontmatter rather than removing
content.

Minimum-seeded resize remains idempotent when repeated at the same size without
intervening progress. Explicit seeding is not generally idempotent: the initial
100, 100, 100, 0 result has a new minimum of zero, so another call rewinds all four
members to zero. This additional replay is deliberate, must be documented, and is
not prevented by keeping workers stopped. The seed applies only to missing rows;
calling the new API after the old remedy already created every row cannot recover
the skipped backlog. Use the whole-group reset fallback in that situation.

If a transaction is known to have rolled back, retry it with workers still stopped.
If its commit outcome is unknown, keep workers stopped and inspect persisted member
indices, sizes and `last_seen` positions before deciding whether repair is still
needed; do not promise a blind retry preserves positions. A confirmed successful
seeded resize needs no repeat. If the operator cannot establish the state or wants
a deterministic full replay, the atomic resize-and-reset fallback sets every member
to zero and may be repeated while workers remain stopped. Account for any composed
application-owned state before retrying the complete transaction.


## Interfaces and Dependencies

`Kiroku.Store.Subscription.Checkpoint` gains `NewMemberSeed(..)` and
`resizeConsumerGroupWithSeedTx`; `Kiroku.Store` makes them available through its
existing checkpoint-module re-export. `Kiroku.Store.Subscription` gains no exports.
`ConsumerGroupResizeReport` keeps its fields and constructor; its documentation
distinguishes the existing-member rewind from the insertion seed and limits its
idempotence claim to the default operation.
`Kiroku.Store.Subscription.Checkpoint.SQL.resizeCheckpointMembersStmt` becomes a
six-parameter `Statement (Text, Int32, Int64, Text, Maybe Text, Int64) ()` (name, size,
rewind position, target kind, target category, new-member position); it is internal.
`Kiroku.Store.Types.GlobalPosition` and `Kiroku.Store.Subscription.Types.ConsumerGroupSize`
are the value types. `hasql`, `hasql-transaction` and `hasql-pool` are unchanged. The
bug-reports and ADR bundles are OKF bundles validated by `okf` against the profiles
pinned in `docs/bug-reports/profile.dhall` and `docs/adr/profile.dhall`.

Revision note (2026-10-25): Applied review findings by defining the additional replay
on seeded-resize retries, specifying a compatible atomic fallback for the historical
upgrade edge, requiring distinct-position and nonzero-seed assertions, and following
the existing checkpoint export structure. Implementation milestones remain pending.
