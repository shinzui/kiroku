---
id: 102
slug: reconcile-the-0-10-and-0-11-release-surface-changelogs-operator-migration-guide-and-performance-ledger
title: "Reconcile the 0.10 and 0.11 release surface: changelogs, operator migration guide and performance ledger"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
---

# Reconcile the 0.10 and 0.11 release surface: changelogs, operator migration guide and performance ledger

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The October 2026 release reviews (REV-2 and REV-3 under `docs/reviews/`) found that
the code shipped in kiroku-store 0.10.0.0 and 0.11.0.0 is sound but that the words
around it lag: the kiroku-store changelog omits several public API breaks, the
kiroku-metrics changelog overstates what its CORS default does, the operator guide for
schema migrations still ends at migration 0012 although 0013, 0014 and 0015 each need
an operator action, the performance ledger that every optimization plan must consult
has no record of the MP13 or EP97 experiments, and the consumer upgrade edge for
0.10.0.0 was published two days after the packages were on Hackage.

After this plan a consumer reading the repository changelogs sees every break the
reviews found, with errata that say when they were added; an operator reading
`docs/user/schema-migrations.md` learns that 0013 and 0014 need stopped workers and
that 0015 blocks appends for the index build; a contributor checking the ledger before
proposing an append optimization finds the October experiments; and the upgrade
blueprint's README states that an edge lands in the release commit, before any tag.


## Progress

- [ ] Milestone 1: `kiroku-store/CHANGELOG.md` and `kiroku-metrics/CHANGELOG.md` carry dated errata under the 0.10.0.0, 0.11.0.0 and 0.3.0.0 entries listing every omission REV-2 and REV-3 recorded, and the files still render as one entry per version.
- [ ] Milestone 2: `docs/user/schema-migrations.md` covers migrations 0013 through 0015 with the operator actions each requires and links to the upgrade edges and to the consumer-group guide's incomplete-legacy procedure.
- [ ] Milestone 3: `docs/perf-experiment-log.md` has rows for the MP13 rerun comparison and the EP97 paired metadata gate, its header admits protected-path experiments beyond appends, and `blueprints/kiroku-upgrade/README.md` states when an edge is written.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Published changelog entries are corrected with an "Erratum (date)" line
  under the affected version rather than rewritten.
  Rationale: The Hackage copy of each version is immutable; a reader comparing the two
  must be able to see what was added later and when.
  Date: 2026-10-21
- Decision: The ledger's header sentence is widened from "every append-performance
  experiment" to protected-path experiments (appends, category reads, metadata reads,
  browse) so the EP97 read-path gate belongs in it.
  Rationale: `docs/PERF-METHODOLOGY.md` step 2 sends contributors to the ledger to find
  what was already measured; a read-path experiment that is absent from it will be
  repeated.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a multi-package Haskell repository: `kiroku-store` (the event store),
`kiroku-store-migrations` (the schema migrations and their runner), `kiroku-metrics`
(the HTTP and WebSocket inspection surface), `kiroku-cli`, `kiroku-otel` and
`shibuya-kiroku-adapter`. Each package has its own `CHANGELOG.md` with one `## <version>
— <date>` entry per release and subsections "Breaking Changes", "New Features", "Bug
Fixes" and "Other Changes"; there is no unreleased section today.

The omissions to record, each verified against the code by the reviews:

For kiroku-store 0.10.0.0 (git `364ffa8`): `SubscriptionConfigM` gained the field
`targetBindingPolicy` and its `batchSize` changed from `Int32` to `BatchSize`;
`StoreError.EventDecodeFailed` and `DeadLetterReason.DeadLetterDecodeFailure` are new
constructors that break exhaustive matches but were listed only under new features;
`KirokuEvent.KirokuEventSubscriptionTargetBound` is a new observer constructor the entry
does not name; `InvalidConsumerGroup` and `InvalidStreamBufferSize` lost their
`Exception` instances so `subscribe`, `subscriptionAckStream` and
`kirokuConsumerGroupProcessors` no longer throw them; the exposed modules
`Kiroku.Store.Subscription.Fsm` (`ConnectionLost` carries a `GlobalPosition`;
`BatchFetched` and `DeliverBatch` carry `DecodedBatch`),
`Kiroku.Store.Subscription.EventPublisher` (`subscribePublisher` returns a
`TBQueue DecodedBatch`), `Kiroku.Store.Subscription.Worker` (`LiveFromPublisherQueue`)
and `Kiroku.Store.SQL` (`saveCheckpointMemberStmt` is a six-tuple statement;
`DeadLetterParams` gained `dlTargetKind`, `dlTargetCategory`, `dlGroupSize`) changed
signatures; and the `subscriptionStream` / `subscriptionAckStream` buffer parameter type
change was only implied.

For kiroku-store 0.11.0.0 (git `7394055`): `SubscriptionDeadLetter` and
`SubscriptionDeadLetterQuery` export the record selectors `eventId`, `globalPosition`,
`after` and `limit` under `DuplicateRecordFields` through `Kiroku.Store`, so code that
used those names bare on `RecordedEvent` or `HistoryRetentionInventoryQuery` gets an
ambiguous-occurrence error; the repository's own `Worker.hs` needed
`hiding (eventId, globalPosition)`.

For kiroku-metrics 0.3.0.0 (git `7394055`): the entry says the CORS policy provides
"WebSocket origin refusal before upgrade", but with the default `corsDisabled` no origin
is checked and upgrades stay open (plan 101 changes that behaviour for the next
version); the library also gained an `effectful-core` dependency that the entry does
not list; and the store-backed starters began wiring the browse, dead-letter and
checkpoint routes automatically, which is a default change rather than only a feature.

The operator guide `docs/user/schema-migrations.md` has sections "Running the
executable", "Existing Codd databases", "Authoring and recovery", "Upgrading from
kiroku-store-migrations 0.3.2.x" and "Migration 0012 needs a maintenance window"; line
12 says `0008` through `0012` are the native migrations, while
`kiroku-store-migrations/README.md` line 7 already says `0015`. The facts to add: 0013
rewrites `consumer_group_size` from existing rows and 0014 adds the target-binding
columns and drops `stream_name`, both to be applied with every subscription worker
stopped, with the incomplete-legacy resize procedure that plan 100 documents in
`docs/user/consumer-groups.md`; 0015 creates `ix_streams_browse_name` with a plain
transactional `CREATE INDEX`, which holds a `SHARE` lock on `kiroku.streams` for the
build so every append waits, with duration proportional to the number of streams, so
large stores rehearse it on a restored clone and schedule a write pause (the migration
file comment, the migrations changelog and the `0.10.0.0 -> 0.11.0.0` edge in
`blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md` already say this).

The ledger `docs/perf-experiment-log.md` is append-only, one Markdown table whose
header defines the columns Date, Plan, Hypothesis, Variant, Bench Numbers, Outcome and
Lesson; its last rows are dated 2026-09-25. The evidence to record: the MP13 rerun at
`bench/mp13-release/validation-2026-10-11-rerun/README.md` (candidate `109d58f` against
released control `364ffa8`, five interleaved pairs per case with inspection disabled and
active, 30 s measured appends per trial, 660,159 appends; throughput -1.544% with a
95% interval of -4.090% to +1.069% disabled and -0.370% with -3.371% to +2.724%
active; WAL per measured append +2.85% and +3.37%; every metric inconclusive under the
zero-slowdown policy; practically accepted by the user on 2026-10-11), and the EP97
paired metadata gate at `docs/bench/stream-head/2026-10-11-ep97-paired/README.md`
(two trials, 40 rounds of 1,000 calls, 99% block-bootstrap intervals; production
against frozen `getStream` 1.005 and 1.004 at 100 events with upper bounds 1.019 and
1.014, 1.003 and 0.995 at 100,000; controls within 0.95 to 1.05; the 20% extra-work
control detected at 1.204; PASS under the 1.10 limit; the earlier 1.17 short sequential
estimate was a comparison-design flaw). The plans are `docs/plans/96-...md` and
`docs/plans/97-...md`.

The upgrade blueprint lives in `blueprints/kiroku-upgrade/` (`blueprint.dhall`,
`README.md`, `migrations/`), mirrored by `seihou-registry.dhall`. The `0.9.0.1 ->
0.10.0.0` edge was committed on 2026-10-12 (git `76ffe79`) after the 2026-10-10
publication, whereas the `0.8.0.2 -> 0.9.0.0` and `0.10.0.0 -> 0.11.0.0` edges were in
their release commits.

Relevant ADRs: [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) and
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
govern what performance evidence means and how it is reported;
[ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md) is the
source of truth for the CORS erratum's wording (plan 101 amends it);
[ADR-17](../adr/0017-stream-browsing-uses-byte-order-and-one-shared-name-index.md)
records the 0015 index. No ADR changes are expected from this plan; no
cross-repository ADR applies.


## Plan of Work

Milestone 1 writes the errata. Under the `## 0.10.0.0 — 2026-10-10` entry of
`kiroku-store/CHANGELOG.md` add a subsection `### Erratum (2026-10-21)` listing, in the
entry's own style, each omission above as the break it is; do the same under
`## 0.11.0.0 — 2026-10-11` for the duplicate selectors, and under `## 0.3.0.0 —
2026-10-11` in `kiroku-metrics/CHANGELOG.md` for the CORS wording, the dependency and
the auto-wired routes, cross-referencing plan 101's forthcoming entry for the behaviour
change. Keep every existing line unchanged. If plan 100 or 101 has already added an
`## Unreleased` heading, leave it in place above the released entries.

Milestone 2 extends the operator guide. Change line 12 to `0008` through `0015`, add a
section "Migrations 0013 and 0014 need stopped workers" after the 0012 section that
states the two actions, the refusal an incomplete legacy group will see, and a link to
the consumer-group guide's procedure for it, and a section "Migration 0015 blocks
appends during its index build" with the lock, the duration driver, the rehearsal and
window advice, and a link to the `0.10.0.0 -> 0.11.0.0` edge. Keep the guide's voice:
it addresses an operator running `kiroku-store-migrate up`.

Milestone 3 records the experiments and the edge rule. Append two rows to the ledger
table, dated 2026-10-11, with the plan paths, a one-sentence hypothesis each (MP13: the
inspection index, HTTP polling and name enrichment add no measurable append cost; EP97:
the originated-head probe leaves `getStream` unchanged), the variant, the numbers quoted
above verbatim, outcome `kept`, and a lesson each (MP13: a five-pair opaque probe bounds
but cannot certify zero regression; EP97: short sequential windows cannot establish a
ratio's uncertainty, paired block-bootstrap trials can). Widen the header sentence per
the Decision Log and keep the table's column count intact. In
`blueprints/kiroku-upgrade/README.md` add a short paragraph under its existing
guidance on edges: an edge for a released window is written in the release commit,
before the tags are created, because consumers who upgrade on release day need it;
cite the 0.10.0.0 case as the reason the rule exists.


## Concrete Steps

All commands run from the repository root. There is no compiler involved; validation
is formatting and a column check for the ledger table.

```bash
nix fmt
awk -F'|' '/^\| 2026-/{ if (NF != 9) { print "bad column count on row: " $0; bad=1 } } END { exit bad }' docs/perf-experiment-log.md && echo "ledger rows OK"
```

Expected: `nix fmt` makes no further changes on a second run, and `ledger rows OK`.

Check the changelogs still parse as one entry per version:

```bash
grep -c '^## ' kiroku-store/CHANGELOG.md kiroku-metrics/CHANGELOG.md
```

The counts must equal their values before the edit (plus one if an `## Unreleased`
heading was added by another plan), because errata are `###` subsections.

Render check for the guide:

```bash
grep -n '^## ' docs/user/schema-migrations.md
```

Expected to list the two new sections after "Migration 0012 needs a maintenance window".


## Validation and Acceptance

Milestone 1 is accepted when every omission listed in Context appears under the right
version's erratum and `grep -c '^## '` is unchanged. Milestone 2 is accepted when a
reader of `schema-migrations.md` alone can state, for each of 0013, 0014 and 0015, what
to stop or pause and why, and the links resolve to existing files. Milestone 3 is
accepted when the two ledger rows pass the column check, the header sentence covers
read-path experiments, and the blueprint README carries the edge rule. A second pair of
eyes should read the errata against the review records
`docs/reviews/kiroku-0-10-subscription-hardening-cohort.md` and
`docs/reviews/kiroku-0-11-inspection-cohort.md`, which list the sources.

Proposed, not required: a `just` recipe that fails a release when the blueprint's
newest edge `to` version is older than the version being tagged.


## Idempotence and Recovery

All edits are additive prose. Rerunning `nix fmt` is safe. If a ledger row is wrong,
append a correcting row that cites it rather than editing it. Errata are dated so a
second pass can add another dated line without ambiguity.


## Interfaces and Dependencies

No code interfaces change. The files touched are `kiroku-store/CHANGELOG.md`,
`kiroku-metrics/CHANGELOG.md`, `docs/user/schema-migrations.md`,
`docs/perf-experiment-log.md` and `blueprints/kiroku-upgrade/README.md`. Plans 100 and
101 touch the same changelogs with `## Unreleased` entries; apply this plan after or
alongside them and keep the heading order "Unreleased, then released versions newest
first". Plan 99 appends its own ledger row; rows are independent.
