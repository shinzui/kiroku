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
- [ ] Milestone 2: `resizeConsumerGroupWithSeedTx` exists in `Kiroku.Store.Subscription.Checkpoint`, is re-exported through `Kiroku.Store.Subscription` and `Kiroku.Store`, seeds new members at the chosen position while rewinding existing members to the minimum, keeps `resizeConsumerGroupTx` byte-for-byte equivalent to its current behaviour, and the milestone 1 test passes when it uses `SeedAtPosition 0`.
- [ ] Milestone 3: `docs/user/consumer-groups.md`, the `0.9.0.1 -> 0.10.0.0` upgrade edge and the kiroku-store changelog describe the incomplete-legacy procedure and the stale-row direction; BUG-5 is `fixed` with a resolution; ADR-4 or ADR-8 carries the seed rule.


## Surprises & Discoveries

(None yet.)


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
`resumePosition` keeps meaning the position existing members were rewound to; add a
Haddock sentence saying so and that new members start at the seed. Export the new
type and function through `Kiroku.Store.Subscription` and `Kiroku.Store` the same way
`resizeConsumerGroupTx` is exported today (search for its name in
`kiroku-store/src/Kiroku/Store/Subscription.hs` and `kiroku-store/src/Kiroku/Store.hs`
and mirror each line). Change the milestone 1 test to call the new function with
`SeedAtPosition (GlobalPosition 0)` and keep a sibling case that documents the minimum
seed's behaviour for a genuine grow, so both semantics stay pinned.

Milestone 3 fixes the words. In `docs/user/consumer-groups.md` replace the migration
paragraph with one that distinguishes the two situations: a genuine grow uses
`resizeConsumerGroupTx` and redelivers from the minimum; an incomplete legacy group,
one whose derived size is smaller than the configured size because members never ran,
uses `resizeConsumerGroupWithSeedTx` with `SeedAtPosition 0` (or the subscription's
original start position) so the never-started members replay their slices, and the
operator must expect those members to process their whole history. Add the reverse
case too: a group shrunk under 0.9's stop-and-restart procedure keeps stale higher rows,
0013 derives the old larger size, and the forced resize rewinds live members to the
stale rows' positions, which is redelivery rather than loss. Make the same two points
in the upgrade edge `0.9.0.1-to-0.10.0.0.md`, and draft the `## Unreleased` changelog
entry in `kiroku-store/CHANGELOG.md`. Update BUG-5 to `status: fixed`,
`fixedVersion: "unreleased"`, with a `resolution` naming the new function and the test,
and add the log entry. Finally amend ADR-8 (or ADR-4 if it reads more naturally there)
with one dated paragraph: a resize may seed a member at the group minimum only when
that member's slice below the minimum was covered by existing members; a member with no
row is seeded by explicit operator choice. Bump the ADR timestamp, add the log entry
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

Milestone 2 is accepted when: the new test passes with `SeedAtPosition 0`; the existing
resize cases ("delivers every seeded event after equalizing size 2 to size 3",
"is idempotent when repeated at the same size and retains surviving member identities",
"starts a missing group at zero and removes obsolete members on shrink", "rolls back the
complete resize with the caller transaction") still pass unchanged, proving
`resizeConsumerGroupTx` kept its semantics; and `cabal test all` passes. The user-visible
proof is the test transcript showing member 3's seeded positions delivered after the
seeded resize and absent after the minimum resize.

Milestone 3 is accepted when the three documents describe both procedures, the
changelog entry exists, BUG-5 is `fixed` with a resolution and both bundle validations
pass, and the ADR amendment validates strictly. The upgrade edge is prose read by an
agent, so also run the blueprint's own validation if one exists (`just` lists recipes;
`seihou` validation ran in the release records under `bench/mp13-release/publication-2026-10-11/blueprint-validation.log`
and shows the command used).

Proposed, not required: a keiro improvement request asking its composed resize to
expose the seed, filed in `mori://shinzui/keiro` once this ships.


## Idempotence and Recovery

The SQL change is to a statement text, not a migration; no deployed database changes.
The new statement is exercised only by the new function and by the existing function
with equal parameters, so a mistake shows up in the existing resize tests before it can
reach an operator. Tests use fresh ephemeral databases and can be rerun freely. Bug
report and ADR edits are additive; if `okf validate` complains, fix frontmatter rather
than removing content. Every step can be repeated.


## Interfaces and Dependencies

`Kiroku.Store.Subscription.Checkpoint` gains `NewMemberSeed(..)` and
`resizeConsumerGroupWithSeedTx`; `Kiroku.Store.Subscription` and `Kiroku.Store` re-export
them. `Kiroku.Store.Subscription.Checkpoint.SQL.resizeCheckpointMembersStmt` becomes a
six-parameter `Statement (Text, Int32, Int64, Text, Maybe Text, Int64) ()` (name, size,
rewind position, target kind, target category, new-member position); it is internal.
`Kiroku.Store.Types.GlobalPosition` and `Kiroku.Store.Subscription.Types.ConsumerGroupSize`
are the value types. `hasql`, `hasql-transaction` and `hasql-pool` are unchanged. The
bug-reports and ADR bundles are OKF bundles validated by `okf` against the profiles
pinned in `docs/bug-reports/profile.dhall` and `docs/adr/profile.dhall`.
