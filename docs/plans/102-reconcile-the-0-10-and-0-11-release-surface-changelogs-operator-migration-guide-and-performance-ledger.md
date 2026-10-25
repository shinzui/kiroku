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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T20:15:37Z
      verdict: "changes-requested"
      note: "Gate legacy recovery on Plan 100; reconcile all migration counts; correct EP97 trial/size mapping; refresh existing CORS erratum and correction dates."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T20:21:55Z
      mode: "update"
      note: "Apply review fixes for migration counts, EP97 evidence, existing CORS erratum and dates; depend only on Plan 100 documentation correction."
---

# Reconcile the 0.10 and 0.11 release surface: changelogs, operator migration guide and performance ledger

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The October 2026 release reviews (REV-2 and REV-3 under `docs/reviews/`) found that
the code shipped in kiroku-store 0.10.0.0 and 0.11.0.0 is sound but that the words
around it lag: the kiroku-store changelog omits several public API breaks, the
kiroku-metrics changelog originally overstated what its CORS default did, the operator guide for
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
- [ ] Milestone 2: `docs/user/schema-migrations.md` covers migrations 0013 through 0015 with the operator actions each requires and consistent manifest-derived counts, links to the upgrade edges and the consumer-group guide's incomplete-legacy warning, and no dependency on a new recovery API.
- [ ] Milestone 3: `docs/perf-experiment-log.md` has rows for the MP13 rerun comparison and the EP97 paired metadata gate, its header admits protected-path experiments beyond appends, and `blueprints/kiroku-upgrade/README.md` states when an edge is written.


## Surprises & Discoveries

On 2026-10-25 the user confirmed that the consumer-group feature has never been
used in production. Plan 100 now defers dedicated legacy recovery implementation
and retains only documentation correction and bug triage. The current guide still
contains the unsafe resize-only recommendation, so the link must wait for that
small correction, not for a new API.

Plan 101 has completed: the metrics changelog already contains an Unreleased entry
and a CORS erratum dated 2026-10-25, and ADR-16 describes the new default. Plan 99
has also appended ledger rows dated 2026-10-25. Preserve those changes.

The EP97 size-to-trial mapping in REV-3 is incorrect. The retained paired-run README
assigns one 100-event and one 100,000-event result to each trial. Use that primary
evidence rather than copying the review's summary.


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
- Decision: The migration guide links to Plan 100's corrected incomplete-legacy
  warning, without requiring a seeded-resize API or a recovery test suite.
  Rationale: The user confirmed no production use and removed that implementation
  scope. A warning must still not endorse the existing unsafe resize-only remedy.
  Date: 2026-10-25
- Decision: Date errata when the correction is actually added and preserve Plan
  101's existing CORS correction. Compare ledger numbers directly with retained
  experiment evidence, including trial and stream-size labels.
  Rationale: Publication history and measurement attribution are the purpose of
  this reconciliation; neither should be reconstructed from stale planning prose.
  Date: 2026-10-25


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a multi-package Haskell repository: `kiroku-store` (the event store),
`kiroku-store-migrations` (the schema migrations and their runner), `kiroku-metrics`
(the HTTP and WebSocket inspection surface), `kiroku-cli`, `kiroku-otel` and
`shibuya-kiroku-adapter`. Each package has its own `CHANGELOG.md` with one `## <version>
— <date>` entry per release and subsections "Breaking Changes", "New Features", "Bug
Fixes" and "Other Changes". The metrics changelog already has an Unreleased section
from Plan 101; preserve any additional unreleased entries present at implementation.

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

For kiroku-metrics 0.3.0.0 (git `7394055`): the original entry claimed "WebSocket
origin refusal before upgrade" without saying it required enabled CORS. Disabled-policy
upgrades were open in that release. Plan 101 has already corrected that sentence,
added `### Erratum — 2026-10-25`, and documented the new default refusal under
Unreleased (target 0.4.0.0). Preserve the distinction between historical behavior
and the next release. The remaining omissions are the added `effectful-core` library
dependency and the default change that store-backed starters automatically wire
browse, dead-letter and checkpoint routes.

The operator guide `docs/user/schema-migrations.md` has sections "Running the
executable", "Existing Codd databases", "Authoring and recovery", "Upgrading from
kiroku-store-migrations 0.3.2.x" and "Migration 0012 needs a maintenance window"; line
12 says `0008` through `0012` are the native-only migrations. The introduction also
says twelve total entries, and "Existing Codd databases" repeats that range, five
`AppliedNow` outcomes and twelve total entries. The authoritative
`kiroku-store-migrations/migrations/manifest` contains fifteen entries: seven imported
historical entries and eight pending native-only entries, `0008` through `0015`.
The import walkthrough must therefore expect seven `AlreadyApplied` and eight
`AppliedNow` outcomes, with a final verify covering all fifteen. The facts to add: 0013
rewrites `consumer_group_size` from existing rows and 0014 adds the target-binding
columns and drops `stream_name`, both to be applied with every subscription worker
stopped. Plan 100's reduced documentation milestone adds an "Incomplete legacy
groups" warning to `docs/user/consumer-groups.md`: ordinary resize alone can skip
an unstarted member's backlog. The user reports no production use; dedicated recovery
implementation is deferred. This guide must not prescribe the removed seed API or
claim a validated recovery procedure. Migration 0015 creates `ix_streams_browse_name`
with a plain
transactional `CREATE INDEX`, which holds a `SHARE` lock on `kiroku.streams` for the
build so every append waits, with duration proportional to the number of streams, so
large stores rehearse it on a restored clone and schedule a write pause (the migration
file comment, the migrations changelog and the `0.10.0.0 -> 0.11.0.0` edge in
`blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md` already say this).

The ledger `docs/perf-experiment-log.md` is append-only, one Markdown table whose
header defines the columns Date, Plan, Hypothesis, Variant, Bench Numbers, Outcome and
Lesson. Plan 99 has appended rows through 2026-10-25; retain them and append the
missing October 11 experiments at the end without sorting or rewriting prior rows.
The evidence to record: the MP13 rerun at
`bench/mp13-release/validation-2026-10-11-rerun/README.md` (candidate `109d58f` against
released control `364ffa8`, five interleaved pairs per case with inspection disabled and
active, 30 s measured appends per trial, 660,159 appends; throughput -1.544% with a
95% interval of -4.090% to +1.069% disabled and -0.370% with -3.371% to +2.724%
active; WAL per measured append +2.85% and +3.37%; every metric inconclusive under the
zero-slowdown policy; practically accepted by the user on 2026-10-11), and the EP97
paired metadata gate at `docs/bench/stream-head/2026-10-11-ep97-paired/README.md`
(two trials, 40 rounds of 1,000 calls, 99% block-bootstrap intervals). Production
latency divided by frozen `getStream` latency was 1.00503 at 100 events in trial 1
(interval 0.99112–1.01932) and 1.00335 in trial 2 (0.98868–1.01924). At 100,000 events
it was 1.00436 in trial 1 (0.99375–1.01356) and 0.99520 in trial 2
(0.98101–1.00728). All identical-code intervals were within 0.95–1.05; the 20%
extra-work controls measured 1.20386 and 1.20079. Both trials passed the unchanged
1.10 upper-bound limit. The earlier 1.17 short sequential estimate remains retained
as inconclusive; the comparison design did not establish uncertainty for that ratio.
Block bootstrap here means resampling contiguous groups of observations to retain
short-range timing dependence when estimating the interval. MP13 is MasterPlan 13's
inspection release comparison; EP97 is ExecPlan 97's metadata comparison. The ledger
plan links are `docs/plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md`
and `docs/plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md`.

The upgrade blueprint lives in `blueprints/kiroku-upgrade/` (`blueprint.dhall`,
`README.md`, `migrations/`), mirrored by `seihou-registry.dhall`. The `0.9.0.1 ->
0.10.0.0` edge was committed on 2026-10-12 (git `76ffe79`) after the 2026-10-10
publication, whereas the `0.8.0.2 -> 0.9.0.0` and `0.10.0.0 -> 0.11.0.0` edges were in
their release commits.

Relevant ADRs: [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) and
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
govern what performance evidence means and how it is reported.
[ADR-16](../adr/0016-browser-inspection-access-is-explicit-and-default-off.md)
records the current CORS policy and its 2026-10-25 amendment. Use the release commit
and existing erratum for historical 0.3.0.0 behavior, rather than projecting the
amended default backwards.
[ADR-17](../adr/0017-stream-browsing-uses-byte-order-and-one-shared-name-index.md)
records the 0015 index. No ADR changes are expected from this plan; no
cross-repository ADR applies.


## Plan of Work

Milestone 1 completes the errata. Under `## 0.10.0.0 — 2026-10-10` and
`## 0.11.0.0 — 2026-10-11` in `kiroku-store/CHANGELOG.md`, add an Erratum subsection
dated with the actual correction date, listing the omissions in Context under the
appropriate release. Do not use the plan's creation date as the erratum date. In
`kiroku-metrics/CHANGELOG.md`, preserve the already-corrected CORS sentence and
`### Erratum — 2026-10-25` under 0.3.0.0, together with the Unreleased breaking note.
If implementing on October 25, extend that erratum with the missing dependency and
automatically enabled route details; on a later date, add a separately dated erratum
for those additions. Do not duplicate the completed CORS correction or restore its
original wording. Preserve every unrelated released and Unreleased entry.

Milestone 2 reconciles the whole operator guide with the manifest. Update both the
introductory inventory and the "Existing Codd databases" walkthrough: fifteen total
entries, native-only range `0008` through `0015`, seven `AlreadyApplied` and eight
`AppliedNow` outcomes after import. Check every occurrence of the old range and
counts; changing only line 12 is insufficient. These totals describe the current
fifteen-entry manifest; if it grows before implementation, derive the counts again.

Add "Migrations 0013 and 0014 need stopped workers" after the 0012 section, explaining
the derived group size, target binding and incomplete-group startup refusal. Before
linking to `consumer-groups.md#incomplete-legacy-groups`, verify that Plan 100's
milestone 1 has replaced the unsafe resize-only advice and that the anchor exists.
Coordinate that small documentation correction if needed; never substitute the
currently misleading paragraph merely because the file exists. Explain the warning
briefly in this guide too. No recovery API or recovery test is a prerequisite.
Link the `0.9.0.1 -> 0.10.0.0` edge at
`blueprints/kiroku-upgrade/migrations/0.9.0.1-to-0.10.0.0.md`.

Add "Migration 0015 blocks appends during its index build" with the write-blocking
lock, stream-count duration driver, clone rehearsal and write-pause advice, and link
the `0.10.0.0 -> 0.11.0.0` edge at
`blueprints/kiroku-upgrade/migrations/0-10-to-0-11.md`. Keep the guide's voice: it
addresses an operator running `kiroku-store-migrate up`.

Milestone 3 records the experiments and the edge rule. Append two rows to the ledger
table, dated 2026-10-11, with the plan paths, a one-sentence hypothesis each (MP13: the
inspection index, HTTP polling and name enrichment add no measurable append cost; EP97:
the originated-head probe leaves `getStream` unchanged), the variant, the measurements
above checked against each retained README with their trial/size labels intact,
outcome `kept`, and a lesson each (MP13: a five-pair opaque probe bounds
but cannot certify zero regression; EP97: short sequential windows cannot establish a
ratio's uncertainty, paired block-bootstrap trials can). Link each row to its retained
evidence README as well as its full plan path. State MP13's statistical result as
inconclusive and its release decision as practical user acceptance; `kept` must not
imply a zero-regression pass. State EP97's pass against its 1.10 limit rather than
claiming universal unchanged latency. Widen the ledger title to "Performance
Experiment Log" and its introductory sentence per the Decision Log, keeping the
table's column count intact. In
`blueprints/kiroku-upgrade/README.md` add a short paragraph under its existing
guidance on edges: an edge for a released window is written in the release commit,
before the tags are created, because consumers who upgrade on release day need it;
cite the 0.10.0.0 case as the reason the rule exists.


## Concrete Steps

All commands run from the repository root. These are documentation changes; no
compiler, database or new performance experiment is needed. `nix fmt` currently
configures only Nix, Haskell and Cabal formatters, so it does not validate these
Markdown edits. Use the focused structural checks below plus the content review
specified in Validation and Acceptance.

```bash
git diff --check
awk -F'|' '/^\| 2026-/{ if (NF != 9) { print "bad column count on row: " $0; bad=1 } } END { exit bad }' docs/perf-experiment-log.md && echo "ledger rows OK"
```

Expected: a clean whitespace check and `ledger rows OK`. Confirm migration totals
against the checked-in manifest and inspect any remaining stale counts:

```bash
cat -n kiroku-store-migrations/migrations/manifest
rg -n '0012|twelve|fifteen|five|eight|AlreadyApplied|AppliedNow' docs/user/schema-migrations.md
```

Expected: fifteen manifest entries; the inventory and import walkthrough agree with
seven historical and eight pending entries. References to 0012 in its own maintenance
section remain valid. Inspect the guide's new relative links and warning anchor.

Check the changelogs still parse as one entry per version:

```bash
rg -c '^## ' kiroku-store/CHANGELOG.md kiroku-metrics/CHANGELOG.md
```

Record these counts before editing and compare afterwards; errata are `###`
subsections and must not create duplicate version headings. Account separately for
an Unreleased heading added by concurrent work. Also inspect `rg '^## ' <file>` for
each changelog, since an unchanged total alone does not prove version uniqueness.

Heading check for the guide:

```bash
rg -n '^## ' docs/user/schema-migrations.md
```

Expected to list the two new sections after "Migration 0012 needs a maintenance window".


## Validation and Acceptance

Milestone 1 is accepted when every omission listed in Context appears under the right
version's erratum with the actual correction date, Plan 101's existing correction is
preserved, and version headings remain unique with unchanged counts apart from
concurrent Unreleased additions. Milestone 2 is accepted when a
reader of `schema-migrations.md` alone can state, for each of 0013, 0014 and 0015, what
to stop or pause and why; every inventory/import count matches the manifest; the
upgrade-edge links and corrected incomplete-legacy warning anchor resolve; and the
warning no longer endorses resize-only recovery. Milestone 3 is accepted when the
two ledger rows pass the column check, each trial/size/interval matches its primary
evidence, MP13's inconclusive result remains distinct from practical acceptance,
EP97's pass names its limit, the title and introductory sentence cover read-path
experiments, and the blueprint README carries the edge rule. A second pair of
eyes should read the errata against the review records
`docs/reviews/kiroku-0-10-subscription-hardening-cohort.md` and
`docs/reviews/kiroku-0-11-inspection-cohort.md`, which list the sources.

Proposed, not required: a `just` recipe that fails a release when the blueprint's
newest edge `to` version is older than the version being tagged.


## Idempotence and Recovery

These edits add errata and reconcile existing explanatory prose. Preserve earlier
correction dates and avoid duplicate errata on a second pass. If a ledger row is wrong,
append a correcting row that cites it rather than editing it. Errata are dated so a
second pass can add another dated line without ambiguity.


## Interfaces and Dependencies

No code interfaces change. The files touched are `kiroku-store/CHANGELOG.md`,
`kiroku-metrics/CHANGELOG.md`, `docs/user/schema-migrations.md`,
`docs/perf-experiment-log.md` and `blueprints/kiroku-upgrade/README.md`. Plan 100 is
`docs/plans/100-make-resize-safe-for-legacy-consumer-groups-whose-members-never-checkpointed.md`;
its reduced milestone 1 owns the consumer-guide warning and historical edge
clarification. Require those words before accepting the link, but do not wait for a
new seed API or recovery tests. Plan 100 no longer owns a new API changelog entry.
Plan 101's CORS change and erratum are already present; retain heading order
"Unreleased, then released versions newest first". Plan 99's existing ledger rows
are independent and must be preserved.

Revision note (2026-10-25): Applied review findings by reconciling all migration
counts and import expectations, correcting EP97 trial/size attribution from primary
evidence, preserving the existing CORS correction and dating new errata accurately.
Reflected the user's no-production-use decision by depending only on Plan 100's
small documentation correction. Replaced ineffective Markdown formatting evidence
with content, link and structural checks. Implementation milestones remain pending.
