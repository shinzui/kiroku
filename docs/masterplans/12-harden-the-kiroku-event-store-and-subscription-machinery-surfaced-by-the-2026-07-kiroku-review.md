---
id: 12
slug: harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review
title: "Harden the Kiroku event store and subscription machinery surfaced by the 2026-07 Kiroku review"
kind: master-plan
created_at: 2026-08-27T21:11:09Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: no child adds a hot-path round trip, but no plan named the ADR-5 gates or hot-path boundaries"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Added ADR-5 context, Performance gates integration point with per-child ownership and hot-path boundaries, discoveries, decision, revision note"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: recorded typed target columns, per-event decode contract, worker stall event, derived/declared adoption, startup-failure parent; cascaded to 81-85"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: undecodable-handler callback replaces automatic dead-lettering; construction-time validation, stream_name drop, checkpoint-module consolidation, landing order, ADR-8"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T16:36:22Z
      mode: "implement"
      note: "Begin EP-1 according to registry order; preserve pre-cohort control for required performance acceptance"
---

# Harden the Kiroku event store and subscription machinery surfaced by the 2026-07 Kiroku review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Write performance is a hard acceptance constraint for this initiative. Preserve successful
append throughput and latency, including when subscriptions share the application process and
database. Confirmed regressions block implementation completion and release; correctness remains
mandatory. [ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
records the durable default-path and opt-in diagnostic rules adopted on 2026-10-09.

This initiative is the Kiroku-owned successor to
`mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review`.
It was transferred on 2026-08-27 because the remaining behavior, public types, migrations,
documentation, tests, and releases are owned primarily by Kiroku. The Keiro source document and
its four child plans remain as historical transfer records and must not be used for new execution.

The July 2026 review found two write-path defects and six subscription or adapter defects. Two
write-path outcomes have since landed independently: Kiroku 0.7's ordered affected-stream guards
close the hard-delete/concurrent-append orphan window, and Kiroku 0.8 surfaces PostgreSQL `40001`
and `40P01` as retryable `TransientTransactionFailure`; Keiro 0.13 adopts that constructor as a
transient failure. This MasterPlan treats those behaviors as verified baseline rather than
replanning them.

After the remaining initiative is complete, a consumer group records the topology under which
each checkpoint was written and can be resized without gaps; a live database-driven subscription
reconnects from its real progress; invalid batch sizes and checkpoint retargeting fail before
delivery, and every startup refusal is catchable through one parent exception; an event the
store-wide decode hook cannot decode is offered to each subscriber's optional disposition callback,
with a retry-then-stop default instead of stalling every `$all` subscriber; append unique-violation mapping distinguishes duplicate caller event ids from
store corruption; the store reports a handler that has held one event too long for every
subscriber kind; and the Shibuya adapter exposes retry policy. The final child plan releases the
affected Kiroku packages and proves downstream Keiro adoption. This cohort is a deliberately
breaking release: while the store stabilizes toward 1.0, the best API wins over compatibility with
the pre-1.0 surface, and every public change is recorded so the 1.0 review can audit it.

Out of scope are dynamic consumer-group rebalancing, the proposed fresh-stream lock-order work in
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7`, `HandlerInTransaction`, prefix
subscriptions, and redesign of the `$all` append serialization point. Replay-history retention is
already complete under [ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md).


## Decomposition Strategy

The 2026-10-09 source audit at commit `e6ea664` found **0 of 6 children complete**.
At that audit all five implementation children were Not Started; EP-6 awaits their completion.
EP-1 is now In Progress: functional topology/resize milestones have landed in the
working tree, while its full performance acceptance remains open.
The accepted ADR-8 records the intended API, not evidence that it has shipped. The recent
lifecycle, category-performance, and publisher-memory fixes are baseline improvements to preserve.
This update inspected source, tests, migrations, changelogs, and history; it did not rerun the
runtime or performance suites and makes no new measured-performance claim.

Five implementation plans are separated by functional ownership, followed by one release and
downstream-adoption plan. EP-1 owns consumer-group topology and safe resize. EP-2 owns the worker
cursor plus configuration identity and batch validation. EP-3 owns the decode hook's typed per-event
failure contract across reads, catch-up, and the publisher. EP-4 owns handler-stall observability in
the store worker and the Shibuya adapter's retry configuration. EP-5 closes the two unique-violation
mapping edge cases that remained hidden inside the old write-path child plan after the main
transient taxonomy landed. EP-6 integrates and releases the cohort only after EP-1 through EP-5 are
complete.

This split keeps independent proofs independent: consumer-group resize is a database topology
problem; reconnect is a worker finite-state-machine problem; decode failure is a per-event
disposition problem that happens to surface first in the shared publisher thread; handler stall is a
worker-level observability problem the adapter merely configures; and unique-violation mapping is a
pure error-taxonomy problem. Combining EP-2 and EP-3, as the Keiro source plan did, was rejected
because they have different failure contracts and can be implemented and reverted independently.
Recreating the already-landed hard-delete and transient failure fixes was rejected because it would
obscure current source truth.

Relevant durable context is [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md), which
defines static hash partitioning but contains a resize consequence EP-1 must amend;
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md), which requires exact checkpoint
identity and separates ordinary monotonic saves from explicit reset; and
[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md), which owns
the hard-delete lock order that superseded the source plan's proposed single-row locking change.
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) governs performance evidence: the
structural and controlled-workload tiers behind `just perf-check` are authoritative, and the
historical CSV behind `just perf-telemetry` is corroborating telemetry. EP-1 through EP-4 change checkpoint, publisher, or delivery paths, so the Performance gates
integration point below assigns existing and missing measurements and the hot-path boundaries
each child must keep. EP-5 changes only error classification.
[ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md),
accepted in September, records the subscription API conventions the cohort establishes toward
1.0: construction-time validation, declared startup policies, one exception parent for runtime
refusals, and never skipping an event on a consumer's behalf. The completed checkpoint lifecycle
request `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3` is adjacent but does not bind
a checkpoint to a subscription target or define group topology. No existing ADR covers the decode
hook's failure contract or handler-stall observability; EP-3 creates one for the former, and EP-4
decides during implementation whether the latter warrants a record.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make consumer-group topology durable and resize without gaps | docs/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md | None | EP-2 | In Progress |
| 2 | Repair live reconnect and validate subscription identity and batch size | docs/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size.md | None | EP-1 | Not Started |
| 3 | Contain persistent publisher decode-hook failures | docs/plans/83-contain-persistent-publisher-decode-hook-failures.md | None | EP-2 | Not Started |
| 4 | Harden adapter acknowledgement liveness and expose retry policy | docs/plans/84-harden-adapter-acknowledgement-liveness-and-expose-retry-policy.md | EP-1, EP-2 | EP-3 | Not Started |
| 5 | Make append unique-violation classification exact | docs/plans/86-make-append-unique-violation-classification-exact.md | None | None | Not Started |
| 6 | Release the subscription hardening cohort and coordinate downstream adoption | docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |


### Source evidence for the registry (2026-10-09)


EP-1: `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` initializes only
name, member, position, and timestamp. The ordinary and dead-letter upserts in
`kiroku-store/src/Kiroku/Store/SQL.hs` still omit `consumer_group_size`.
`ConsumerGroup` remains publicly constructible; no `ConsumerGroupSize`, size-mismatch refusal,
or `resizeConsumerGroupTx` exists.

EP-2: `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` still converts
`LiveFetchError err` to `ConnectionLost err`; `Subscription/Fsm.hs` carries no observed position.
`Subscription/Types.hs` still uses `Int32` batch sizes and `Subscription/Stream.hs` checks a raw
`Natural` buffer at runtime. No target-binding columns, policy, rebind operation, or common
startup-refusal parent exists. The existing reconnect test injects errors before live delivery
has advanced, so it does not establish the missing mid-live progress guarantee.

EP-3: `kiroku-store/src/Kiroku/Store/Settings.hs` still has
`decodeHook :: Maybe (RecordedEvent -> IO RecordedEvent)` and the no-hook `pure xs` fast path.
`Test/PublisherCallbackResilience.hs` tests a one-shot throw and observability exceptions;
there is no typed persistent-failure disposition. The publisher's strict idle-position fix
addresses heap retention, not this decode contract.

EP-4: `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` has the existing handler guards
and exception-safe group acquisition, but no `kirokuProcessor`, configurable `retryPolicy`,
or `handlerStallWarnAfter`. The store has no handler-stall event. Existing acknowledgement,
retry, cancellation, and cleanup tests are reusable baseline coverage; the remaining helper,
warning, and custom-policy acceptance cases are still absent.

EP-5: `kiroku-store/src/Kiroku/Store/Error.hs:mapUniqueViolation` still tests
`events_pkey` with `Text.isInfixOf`, then stream-name uniqueness, then the generic
`WrongExpectedVersion` fallback. Neither exact link-key classification nor the explicit
stream-version invariant branch has landed.

EP-6: checked-in package versions are store `0.9.0.1`, migrations `0.6.0.0`, and adapter
`0.5.1.5`; the manifest ends at `0012.sql`. These identify the audited checkout, not the latest
Hackage state. Their changelogs describe separate fixes, not this cohort's missing APIs.
Release selection and registry/tag verification remain EP-6 work.


## Dependency Graph

EP-1, EP-2, EP-3, and EP-5 have no hard dependencies. EP-4 hard-depends on EP-1
and EP-2 for the validated types used by its final adapter configuration. EP-1 and EP-2 both
change checkpoint reads and writes, so their dependency is integration-only: whichever lands second must preserve both
topology and target-binding fields. EP-2, EP-3, and EP-4 all edit `Worker.hs`: EP-2 owns
reconnect and validation, EP-3 owns the `DecodedEvent` walk and the undecodable-event
disposition in `processEvents`, and EP-4 owns the stall cell around the handler call. Their worker
changes have integration dependencies; the recommended landing order is EP-3, then EP-2, then EP-4, so that the delivery primitive is merged serially rather than
three ways; EP-5 can land at any point; EP-1 can proceed independently but must finish before EP-4. EP-4 also consumes plan 82's `BatchSize` and
`StreamBufferSize` types and plan 81's `mkConsumerGroup` in its adapter configs, so it should
land after both as well. Its acknowledgement characterization can be prepared earlier, but
the complete child cannot land independently of those APIs.

EP-6 hard-depends on all five implementation plans because package versions, PVP impact,
migration manifests, release order, and downstream Keiro bounds can be selected truthfully only
from the integrated code. EP-6 must use the repository release skill and re-query Hackage,
upstream tags, and Mori dependents at execution time; this MasterPlan deliberately does not pin a
future version number.


## Integration Points

`kiroku.subscriptions` and the checkpoint SQL are shared by EP-1 and EP-2. EP-1 owns
`consumer_group_size`, which exists in migration `0001` but was never written; EP-1 derives its
values for existing groups in a migration. EP-2 owns target binding through two new typed
columns, `target_kind` and `target_category`, added by a separate additive migration that also
drops the historical `stream_name` column, since nothing reads it. The current migration manifest
ends at `0012.sql` in the audited checkout; neither child may reuse an existing number. Each
plan creates its migration with the standard `kiroku-store-migrate new --manifest ...` scaffolder,
lets the manifest allocate the filename, and does not merge the two.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` is shared by EP-1, EP-2, EP-3, and EP-4.
EP-1 owns checkpoint topology validation and resize; EP-2 owns `ConnectionLost` position
propagation, batch-size validation, and target validation; EP-3 owns the `DecodedEvent` walk and
decode retry inside `processEvents`; EP-4 owns the handler-stall cell written and cleared around
the handler call. Keep the changes mechanically composable.

`kiroku-store/src/Kiroku/Store/Observability.hs` is shared by EP-2, EP-3, and EP-4. EP-2 adds
`KirokuEventSubscriptionTargetBound`, EP-3 adds `KirokuEventPublisherDecodeFailed`, and EP-4 adds
`KirokuEventSubscriptionHandlerStalled`; no adapter-specific constructor enters the store's
vocabulary. Each must update every exhaustive consumer in Kiroku packages and tests.

The public `SubscriptionConfig`/`RetryPolicy` contract flows from `kiroku-store` into
`shibuya-kiroku-adapter`. `RetryPolicy` is unchanged; EP-4 threads it, the new
`handlerStallWarnAfter` field, plan 82's validated `BatchSize` and `StreamBufferSize` types, and
plan 81's `mkConsumerGroup` through both adapter configs without redefining any of them. EP-6 owns
final cross-package version/bound changes and the downstream Keiro adoption proof.

`Kiroku.Store.Settings.decodeHook` and `decodeEvents` are owned by EP-3 and have three callers:
the read interpreter in `Kiroku.Store.Effect`, worker catch-up, and the publisher. EP-3 defines
all three semantics: reads fail with `EventDecodeFailed`, and a subscription hands an undecodable
event to its optional `undecodableHandler` or, by default, retries briefly and stops with
`StopUndecodable`; the store never dead-letters on a consumer's behalf. Construction-time
validation is owned by EP-2 (`BatchSize`, `StreamBufferSize`) and EP-1 (`ConsumerGroupSize`,
`mkConsumerGroup`), following `mkHistoryRetentionInventoryLimit`; the runtime-refusal parent
`SomeSubscriptionStartupFailure` is owned by EP-2, EP-1's `ConsumerGroupSizeMismatch` routes
through it, and whichever plan lands second adds the instance. All three explicit checkpoint-set
operations, reset, resize (EP-1), and rebind (EP-2), live in `Kiroku.Store.Subscription.Checkpoint`
and return `...Report` types.

Performance gates are shared by every implementation child and by EP-6, under
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md). The review of 2026-09-09 verified
against source that no child adds a database round trip to a per-event or per-batch path, and the
following constraints keep it that way. `saveCheckpointMemberStmt` and the checkpoint half of
`insertDeadLetterAndCheckpointStmt` in `kiroku-store/src/Kiroku/Store/SQL.hs` run once per delivered
batch tail; EP-1 and EP-2 add `consumer_group_size`, `target_kind`, and `target_category` as
additional upsert columns only. Neither may add a `WHERE` predicate, a returned-row check, or a
second statement to an ordinary save, and none of the three columns is indexed on
`kiroku.subscriptions` (its only indexes are the `subscription_id` key and the composite unique
index), so the upsert stays a single HOT-eligible statement. EP-2's column addition carries constant
defaults and is metadata-only; EP-1's derivation touches one row per member; both migrations run
with workers stopped. Topology validation (EP-1) and target validation (EP-2) both read every row
for the subscription name; both run inside the existing `initializeSubscriptionCheckpointSession`
pool checkout in `kiroku-store/src/Kiroku/Store/Subscription/Checkpoint/SQL.hs` rather than as
separate `Pool.use` calls, so startup stays at one checkout per member. Whichever plan lands second
extends that session; it does not add another. The consumer-group and category fetch statements
remain outside these children's scope.
Preserve the category index and category-specific group wakeups already landed under
[ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md) and plan 91,
including the 20,000-stream caught-up-poll buffer budget in
`kiroku-store/test/Test/PerformanceStructure.hs`. Do not restore the older LATERAL queries.

EP-3 owns `decodeEvents` and the publisher loop in
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`. With a hook configured it already
runs once per surfaced event, so the intended successful path adds no hook calls. Today's no-hook
`decodeEvents` returns the original vector without traversal. The earlier proposed uniform
per-event wrapping would add traversal/allocation and possible read-side unwrapping. The revised
batch representation below avoids that cost on the no-hook path; successful-hook overhead still
requires measurement. The queue element becomes
`DecodedBatch`: an `UnchangedBatch` retains the original vector when no hook exists, while a
`TransformedBatch` carries `Vector DecodedEvent` when a hook runs. Reads keep their no-hook
passthrough. Only the transformed batch needs a constructor per event; there is no control signal in the queue, no failure counter, and
no terminal state, and `SubscriberStatus` is unchanged. A decode retry re-applies the hook in the
worker for one event after the callback's or the default one-second delay; it performs no
database work unless a consumer callback chooses to dead-letter, which is the existing single
statement. EP-4 owns the handler-stall cell in `Worker.hs`. `processEvents` delivers one event at
a time, so an enabled watchdog has one `TVar` per worker written before and cleared after the handler call,
one monotonic clock read and two STM writes per event, plus watchdog wakeup and timer
bookkeeping. These are opt-in costs to measure; `handlerStallWarnAfter` now defaults to
`Nothing` in the store and both adapter configs, superseding the proposed `Just 60` default. The watchdog parks on STM until an item
is pending and then waits the full threshold; it never polls. When the threshold is `Nothing` no
thread, tracking cell, or timer is created, and no per-delivery clock read or tracking STM write occurs.

Gate ownership: EP-1 and EP-2 run `just perf-check` and `just perf-telemetry` and must report the
`All.reliability-audit.subscription category catch-up 100 events`, `All.category.*`, and
`All.subscription-checkpoint-inventory.*` cells before and after. EP-2 adds the `InvalidBatchSize`
refusal to the "no-op paths use no pooled connection" block of
`kiroku-store/test/Test/PerformanceStructure.hs`, and EP-1 adds the topology-mismatch refusal there
as an exactly-one-checkout path. EP-3 and EP-4 retain `cabal bench
kiroku-store:kiroku-shibuya-overhead` as supplementary before/after evidence, but it is not a
live publisher or production adapter acceptance gate. `ShibuyaOverhead.hs` pre-appends events
before subscribing, so it primarily measures catch-up, and its Shibuya layer constructs a
synthetic adapter over `subscriptionStream` with a no-op finalizer for normal acknowledgements;
it never calls the production `kirokuAdapter`.

EP-3 must add controlled coverage of no-hook and successful-hook reads, catch-up, and confirmed
live publisher fan-out, recording throughput and allocation per event. EP-4 must measure the
production acknowledgement-coupled `kirokuAdapter` and bare workers with stall tracking disabled
and with an explicit opt-in `Just 60`, including idle-worker timer/thread behavior. Define
controls and acceptance bounds before measuring, following ADR-5, and integrate the new controlled
cases into an authoritative gate. No bound is claimed as already passed. Avoid interpreting an
unchanged database round-trip count or the old synthetic benchmark as proof of unchanged CPU,
allocation, or scheduling cost. EP-1/EP-2 also record startup validation cost as group size grows:
one pool checkout does not imply one statement or constant work. Wider checkpoint rows can increase
write volume even when the upsert remains HOT-eligible.

EP-5 changes only the error path after PostgreSQL has rolled back the failed statement, so it
needs no gate beyond EP-6's. EP-6 runs `just perf-check`, the new EP-3/EP-4 controlled cases, and
`just perf-telemetry` as part of its release gate and records the transcripts in its Outcomes.
The reconnect correction should remove redundant replay; the decoder and opt-in watchdog are
the main healthy-delivery regression risks. The no-hook read passthrough and a no-hook subscription
batch fast path must avoid mandatory per-event wrapping; EP-3 may adjust its internal representation
to meet that requirement while preserving the typed failure semantics. No remaining change has measured regression evidence
yet because its implementation has not landed.

Cross-repository work in Keiro must use canonical references. The transferred source remains
`mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review`;
EP-1's downstream shard-count seam belongs to `mori://shinzui/keiro`, while Kiroku remains the
source of truth for checkpoint topology and resize semantics.


### Write-performance acceptance contract (2026-10-09)

EP-1 owns the shared mixed-workload harness, checkpoint-write control, and structural write-path
assertions. EP-2 extends it for target metadata and reconnect. EP-3 adds decode/no-hook and live
fan-out cases. EP-4 owns the real adapter arm in the adapter package and opt-in watchdog cases.
The first of these children implemented establishes the common harness so the others need not wait
for EP-1; preserve one shared workload specification. EP-6 runs the integrated matrix against the
original pre-cohort control as well as recording per-child results. Record exact control/candidate
commits, schemas, commands, fixtures, and raw results in the responsible child's Outcomes.

The control is the implementation immediately before MP-12 production changes, initially the
`e6ea664` audit baseline, not the pre-category-index implementation and not merely the preceding
child. Keep its matching schema and all already-shipped correctness fixes. New migrations may make
the control and candidate schema differ; isolate the databases and record that difference.
Prefer same-process controls where both real implementations can coexist; otherwise alternate
matched control/candidate executables on the same quiet host and PostgreSQL instance, never run
them concurrently against a shared resource and call that an A/B comparison. Fix compiler, RTS,
CPU allocation, pool limits, database durability settings, payloads, event counts, and instrumentation.

Measure successful single-stream and multi-stream appends, both fresh and existing streams, with
small and batched payloads. Include append-only, idle subscriptions, actively consuming native
`$all` and category/group subscriptions, and the production acknowledgement-coupled Shibuya adapter.
Cover shared-process CPU/GC and shared-pool contention; a separate subscriber process alone misses
the former. Use no hook/default-disabled diagnostics for the default matrix, then separate
successful-hook and opt-in watchdog arms. Use one and several workers and checkpoint batch sizes
1 and 100 to expose checkpoint write amplification. Freeze representative payload sizes,
concurrency, and scenario combinations before measuring; avoid a huge arbitrary Cartesian product.

For latency, drive fixed offered loads below saturation and near the control's sustainable limit;
retain request arrival times so queueing delay is included. Separately measure maximum sustainable
throughput. Measure only after workers reach live mode for live cases. Assert equal delivered work,
correct acknowledgements, durable checkpoint progress, and bounded backlog throughout the window
and after draining. A faster append result obtained by doing less subscriber work, allowing backlog
to grow without bound, dropping events, or deferring checkpoint writes is a failed run.

Run PostgreSQL 18 with durable writes enabled. The user narrowed the performance
validation scope to PostgreSQL 18 on 2026-10-09; PostgreSQL 17 performance trials
are not required. Warm both arms, alternate at least five
paired steady-state trials, and use windows of at least 60 seconds, extending runs when necessary
for stable tail-latency estimates. Report committed events/second, append p50/p95/p99 latency,
checkpoint saves/second and latency, WAL bytes per committed event and per checkpoint save,
process allocation/GC and residency, and pool/lock waits. Collect expensive diagnostic profiles
separately from primary timing runs with identical instrumentation in control and candidate. Record
checkpoint write amplification and HOT-update behavior; HOT eligibility alone is not evidence of
unchanged write cost.

There is no intentional write-regression allowance. Before viewing candidate results, measure
control-versus-control variability and predeclare equivalence margins and sample-size rules that
can resolve a 1% throughput/p50 change and a 3% p95/p99 change or better. These are maximum
measurement-uncertainty targets, not permitted slowdowns. Use paired uncertainty intervals; a wide
interval crossing the target is inconclusive, not a pass. Any reproducible adverse change, including
one below those targets, requires investigation and blocks acceptance until corrected. Assess each
scenario separately; never average a regression away with reconnect improvements or faster reads.
Do not widen margins, reduce durability, change checkpoint frequency, or refresh baselines to pass.

Wire the authoritative mixed-write comparisons into `just perf-check` (including the production
adapter gate without creating a store-to-adapter library dependency cycle). Record exact runnable
commands once the harness exists; until then the associated child gate is unchecked. Existing
append pipeline/category gates remain necessary but are insufficient: both sides of an existing
algorithm comparison could slow down together. EP-6 must present the original-control comparison
and separately quantify opt-in diagnostic cost. A confirmed regression requires redesign and
remeasurement, not automatic release or silent acceptance of a tradeoff.


## Improvement-Request Alignment

The current Kiroku improvement-request bundle does not represent this initiative end to end, and
completed requests must not be retroactively broadened to imply that it does.

- `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` exposes durable checkpoint
  inventory but explicitly treats `stream_name` and `consumer_group_size` as non-authoritative
  legacy fields and excludes consumer-group rebalancing. It is evidence for the current gap, not
  coverage of EP-1 or EP-2.
- `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3` provides atomic missing-checkpoint
  policies and exact transaction-composable reset. It is a prerequisite for EP-1/EP-2 but
  explicitly does not infer consumer-group topology or target identity.
- `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5` publishes the stable SQL
  checkpoint relation while deliberately excluding topology fields; it does not provide resize
  or rebind behavior.
- `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7` asks for fresh-stream append lock
  ordering and is unrelated to the released hard-delete guard or the remaining subscription work.

The 2026-10-09 bundle audit found no dedicated current bug report or improvement request
whose acceptance is fully delivered by EP-1 through EP-5. Their authority remains the transferred
July review and these children. The newer records require these distinctions:

[IR-16](../improvement-requests/retry-publisher-pool-errors-before-the-safety-poll.md) explicitly
cites plan 82 for the separate category replay observed in its network-partition experiment.
EP-2 addresses that replay symptom, but IR-16 requests prompt bounded retry after publisher pool
errors. EP-2 changes a worker cursor and EP-3 changes decode disposition; neither changes the
publisher's pool-error retry cadence, so neither completes IR-16.

[IR-15](../improvement-requests/hold-the-consumer-group-member-guard-for-the-workers-lifetime.md)
and [IR-17](../improvement-requests/expose-the-lifetime-member-guard-in-the-shibuya-adapter.md)
are accepted and owned by plans 93 and 92 respectively. Lifetime member exclusivity is distinct
from EP-1's stored topology, and the adapter guard field is distinct from EP-4's retry/stall
fields. Those plans remain outside this registry. Reconcile edits to worker startup, startup
exceptions, and adapter records with their owners; do not duplicate their implementation.

[BUG-2](../bug-reports/partitioned-category-read-scans-every-stream-in-the-category.md),
[BUG-3](../bug-reports/publisher-position-thunk-retains-append-results-without-all-subscribers.md),
and [BUG-4](../bug-reports/partial-consumer-group-acquisition-strands-members.md) are marked fixed.
The changelogs identify category indexing in store 0.9.0.0, idle publisher retention in store
0.9.0.1, and acquisition cleanup in adapter 0.5.1.3. BUG-2's `fixedVersion` still says
`unreleased`; use its implementation, plan 91, and changelog evidence for this audit rather than
propagating that stale field. These fixes are baseline constraints, not completed MP-12 children.
IR-6's replay-retention work is also completed baseline. IR-2, IR-3, and IR-5 remain narrower
completed prerequisites; IR-7 remains an excluded append-lock-order request.

Each implementation child should add focused OKF tracking only where it provides durable
traceability; do not broaden completed records or close IR-15, IR-16, or IR-17 through this plan.


## Progress

- [x] (2026-10-09) Adopted the user's write-performance priority as a hard gate, made stall warnings opt-in, and recorded ADR-11.
- [ ] Establish the mixed append/subscription control and per-scenario write/GC/WAL measurements before production changes; keep each child and the integrated release gated on them.
- [x] (2026-10-09) Audited all six children against source, tests, migrations, changelogs, and local history at `e6ea664`; no child implementation is complete.
- [x] (2026-10-09) Recorded adjacent lifecycle/category/heap fixes as baseline, mapped IR-15/IR-16/IR-17 to their actual scope, and corrected the synthetic benchmark's coverage claims.
- [x] (2026-08-27) Baseline: hard delete serializes against affected streams under ADR-7; the July orphan window is closed by released Kiroku 0.7 evidence.
- [x] (2026-08-27) Baseline: `40001`/`40P01` surface as retryable `TransientTransactionFailure` in Kiroku 0.8 and Keiro classifies the constructor as transient.
- [x] (2026-09-09) Performance review: verified against source that no child adds a hot-path round trip; ADR-5 gate ownership and hot-path boundaries recorded in Integration Points and cascaded to plans 81 through 85.
- [x] (2026-09-09) Design review: five API concerns resolved as recorded decisions and cascaded to plans 81 through 85.
- [x] (2026-09-09) Design review, second pass: undecodable events dispose through a consumer callback rather than automatic dead-lettering; construction-time validation, the `stream_name` drop, checkpoint-module consolidation, landing order, and ADR-8 recorded.
- [ ] EP-1: derive stored topology by migration, persist and validate it, refuse unsafe restarts, validate group configuration at construction, and expose an idempotent gap-free resize operation in the checkpoint module.
- [ ] EP-1: amend ADR-2 and the consumer-group guide; expose the transaction surface needed for downstream adoption.
- [ ] EP-2: reconnect database-driven live subscriptions from `posRef` and reject `batchSize < 1` before a worker starts.
- [ ] EP-2: bind every checkpoint to its target in typed columns under a declared binding policy, drop `stream_name`, validate batch and buffer sizes at construction, introduce the startup-refusal parent exception, and document deliberate retarget operations.
- [ ] EP-3: prove the current apparent-live stall, then make decode failure a typed per-event outcome that each subscriber disposes of through an optional callback, stopping by default, and that fails reads with a typed error.
- [ ] EP-4: expose retry policy on single and consumer-group adapter configs; provide a guarded processor path and a worker-level handler-stall event the adapter configures.
- [ ] EP-5: distinguish `stream_events_pkey` duplicates and `ux_stream_events_stream_version` corruption with deterministic mapping tests.
- [ ] EP-6: run the integrated test matrix and the ADR-5 performance gates, release the affected package cohort with current authoritative versions, and prove downstream Keiro shard-count adoption without private Kiroku SQL.


## Surprises & Discoveries

- Scope correction (2026-10-09): the user explicitly removed PostgreSQL 17
  testing from the remaining work. Authoritative performance acceptance uses
  PostgreSQL 18 on alpha. Previously completed PostgreSQL 17 functional tests
  remain evidence; beta diagnostics are not acceptance measurements.

- EP-1 controlled benchmark preparation: matched Linux payloads build under
  `bench/mp12-cell`, reusing `mori://shinzui/keiro-runtime-kenshou` at revision
  `68f986cd7548e7da64e6eeb0444d8f5524cf5e82`. Alpha (PostgreSQL 18) is the selected measurement cell. The workload and fail-closed checker are reusable
  by later children; cell calibration and complete ADR-11 coverage remain open.

- EP-1's local PostgreSQL 18 control/control write calibration exceeded the
  required precision and is inconclusive. The user directed authoritative
  measurement onto `mori://shinzui/keiro-runtime-kenshou` infrastructure. Its
  controlled Linux cells, durable resets, health evidence, and sealed artifacts
  should be reused across this cohort; its ADR-6 considers local macOS Kiroku
  performance results exploratory. EP-1 remains In Progress pending that gate.

- EP-1 implementation (2026-10-09): migration `0013.sql` derives legacy topology;
  EP-2 must allocate its target-binding migration after that filename. Worker
  startup now uses `initializeWorkerCheckpointSession`: extend this transaction
  for target validation, retaining the one-checkout boundary and the advisory
  name lock that prevents concurrent incompatible initializers. The original
  low-level initializer remains size-1 provisioning; whole groups use resize.
- EP-1 implementation: `ConsumerGroup` accessors are ordinary functions, not
  exported record fields, because record updates could otherwise bypass the
  hidden constructor. Adapter `groupSize` now takes `ConsumerGroupSize`; EP-4
  preserves this surface while adopting validated batch/buffer sizes. Plan 82
  adds the startup-parent `Exception` instance for `ConsumerGroupSizeMismatch`.

- Refresh audit (2026-10-09): accepted ADR-8 has not yet been implemented; configuration remains
  raw integers, runtime errors remain separate, and resize/rebind/decode-disposition APIs are absent.
- Refresh audit (2026-10-09): the existing overhead benchmark preloads events and builds a synthetic
  non-acknowledgement-coupled adapter. Earlier claims that it proves the live publisher and real
  adapter bridge were incorrect. EP-3/EP-4 now require direct controlled coverage.
- Refresh audit (2026-10-09): preserving round-trip counts does not prove performance neutrality.
  EP-3 originally proposed replacing the no-hook vector passthrough with per-event wrapping; EP-4 originally proposed default per-event
  tracking and a watchdog; the later write-performance requirement makes that diagnostic opt-in. The later ADR-11 revision also adds a no-hook batch fast path. Both changes still require
  measured allocation and throughput evidence.
- Transfer audit (2026-08-27): the source plan's proposed Kiroku 0.4/adaptor 0.5 release train is
  obsolete. Current source is `kiroku-store` 0.8.0.0 and `shibuya-kiroku-adapter` 0.5.1.1; release
  versions must be chosen from final PVP impact and authoritative registry/tag state.
- Transfer audit (2026-08-27): migration `0009` is already the published checkpoint relation and
  the manifest has advanced further. EP-2 must allocate a new migration through the repository
  scaffolder rather than copy the source plan's number.
- Transfer audit (2026-08-27): ADR-7 closed the hard-delete orphan race with coordinator plus
  ordered affected-stream locking, a stronger shape than the source plan's target-row-only
  `findStreamIdForUpdateStmt` proposal.
- Transfer audit (2026-08-27): the transient taxonomy landed as
  `TransientTransactionFailure`, not the source plan's proposed `TransientConflict`, and all
  current mapping paths are tested. The old child plan's two unique-violation edge cases remain
  absent and are preserved in EP-5.
- Transfer audit (2026-08-27): Shibuya Core 0.9 retains the always-finalize runner guarantee: a
  synchronous handler exception becomes `AckRetry (RetryDelay 0)` and finalization is separately
  retried. EP-4 must test current behavior before choosing its final guard/watchdog surface.
- Performance review (2026-09-09): the transferred child plans cited no performance gate even
  though [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
  authoritative and the historical suite already measures category catch-up (fetch, delivery, and
  the checkpoint upsert) and checkpoint-inventory reads over `kiroku.subscriptions`. The gap was a
  coordination omission, not a hot-path change; ownership is now recorded in Integration Points.
- Performance review (2026-09-09): for database-driven live workers the FSM's `Live` cursor never
  advances, because the live loop runs to completion inside the worker's `nextInput`; a
  `ConnectionLost` today re-catches-up from the position at live entry and replays every batch
  processed since. EP-2's reconnect-from-`posRef` change removes that redundant fetch and handler
  work, so it is a performance improvement rather than a risk.
- Performance review (2026-09-09): publisher retries after a decode-hook failure are paced by
  notifier ticks (one per committed append, debounced) or the 30-second safety poll, so the loop
  never spins. EP-3's five-attempt budget is attempt-based, however, and under sustained append
  load five attempts can elapse within milliseconds; EP-3 must record whether that is acceptable
  or add a minimum spacing before the terminal transition. Resolved later the same day: the
  per-event decode contract has no budget and no terminal transition.
- Design review (2026-09-09): `decodeEvents` has three callers (the read interpreter in
  `Kiroku.Store.Effect`, worker catch-up, and the publisher), so the decode contract could not be
  changed at the publisher alone; EP-3 now defines read-path semantics as well.
- Design review (2026-09-09): no package or user guide reads `kiroku.subscriptions.stream_name`,
  and the published relation does not expose it, so EP-2 drops the column instead of deferring a
  cleanup with no owner. The adapter also carries its own `batchSize` and `bufferSize` fields, so
  EP-4 must adopt the validated types rather than merely forward them.


## Decision Log

- Decision: Preserve write performance as a hard acceptance constraint, use mixed workloads against
  the original control, make `handlerStallWarnAfter` default to `Nothing`, and preserve no-hook
  fast paths. No intentional default write slowdown is budgeted.
  Rationale: The user explicitly prioritizes performance, especially writes; unchanged append SQL
  cannot exclude shared CPU/GC/pool/WAL contention. Optional diagnostics must not charge every user.
  The September proposal for default-enabled stall warnings is superseded. Recorded in ADR-11.
  Date: 2026-10-09

- Decision: Retain all six children as Not Started after the source audit, and treat later
  lifecycle, category-index, and publisher-memory fixes as baseline to preserve.
  Rationale: Related names and newer releases do not establish the missing acceptance contracts.
  Date: 2026-10-09

- Decision: Reflect EP-4's existing validated-type requirements as hard dependencies on EP-1/EP-2,
  and require direct controlled measurements for EP-3/EP-4 instead of relying on the synthetic
  overhead benchmark. Keep the newer request owners outside this registry.
  Rationale: This corrects coordination and validation coverage without changing the accepted API
  design or expanding the cohort. ADR-5 and ADR-8 already govern these constraints; no new ADR is
  needed for this status refresh.
  Date: 2026-10-09
- Decision: Transfer execution ownership from Keiro MasterPlan 20 to this Kiroku MasterPlan and
  retire the Keiro parent and children as historical transfer records.
  Rationale: Kiroku owns the remaining implementation, migrations, public contracts, tests,
  documentation, and release. Leaving active duplicate plans in two repositories invites
  divergent decisions and stale status.
  Date: 2026-08-27

- Decision: Treat the released hard-delete and transient-transaction fixes as baseline, not child
  plans, while preserving the still-missing unique-violation work as EP-5.
  Rationale: Plans must describe current source truth. Replanning completed behavior adds no
  independently deliverable result, but dropping the source plan's secondary mapping findings
  would lose real scope.
  Date: 2026-08-27

- Decision: Keep resize as an explicit stop-and-equalize operation rather than dynamic
  rebalancing.
  Rationale: ADR-2 deliberately chose static hash partitioning. Safe resize requires topology
  validation and explicit rewind to the old members' minimum checkpoint; dynamic handoff is a
  separate architecture.
  Date: 2026-08-27

- Decision: Split persistent publisher decode-hook failure from worker reconnect and checkpoint
  validation.
  Rationale: The publisher is one shared thread with a store-wide blast radius, while reconnect
  and identity validation are per-worker state-machine behavior. Their tests, rollback paths, and
  durable contracts are independent.
  Date: 2026-08-27

- Decision: Defer all future package version and dependency-bound choices to EP-6.
  Rationale: The source plan's versions are already obsolete. Dependency bounds must be chosen
  from final API impact and verified against Hackage plus upstream tags, not copied from a July
  forecast.
  Date: 2026-08-27

- Decision: Record the improvement-request coverage gap without rewriting completed requests.
  Rationale: IR-2, IR-3, and IR-5 delivered narrower accepted contracts whose explicit exclusions
  remain true. The remaining findings are mostly defects in promised behavior; child plans should
  create focused OKF records only where they add durable traceability.
  Date: 2026-08-27

- Decision: Adopt the ADR-5 gates as a per-child completion requirement and an EP-6 release gate,
  with the hot-path boundaries fixed in Integration Points: a single-statement checkpoint upsert,
  startup validation inside the existing initialization checkout, a status-TVar publisher failure
  signal, and a single-cell adapter watchdog.
  Rationale: The initiative edits the per-batch checkpoint statement, the shared publisher loop,
  and the adapter acknowledgement bridge. Each change is cheap by construction, but only the
  authoritative gates and the existing overhead benchmark can prove the implementation kept it
  so; a plan that names no gate leaves that decision to whoever implements it last.
  Date: 2026-09-09
  Amended later on 2026-09-09: the publisher no longer needs a failure signal, and the
  single-cell watchdog lives in the worker; the gates and the other boundaries are unchanged.

- Decision: Store target identity in typed `target_kind`/`target_category` columns with CHECK
  constraints and leave `stream_name` untouched; represent pre-existing rows as `unbound`.
  Rationale: A private token grammar in a misnamed column costs clarity forever to save one
  migration. Typed columns make the encoder total, let PostgreSQL reject inconsistent rows, and
  add without rewriting rows.
  Date: 2026-09-09

- Decision: Replace EP-3's attempt budget and terminal publisher state with a typed per-event
  decode contract: `decodeHook` returns `Either DecodeFailure RecordedEvent`, undecodable events
  retry under the subscriber's `RetryPolicy` and dead-letter with `DeadLetterDecodeFailure`, and
  reads fail with `EventDecodeFailed`.
  Rationale: An exception is the wrong failure channel for a per-event transformation. Reusing
  the worker's existing retry and dead-letter machinery gives bounded, per-subscriber, replayable
  outcomes with no magic number and no store-wide failure mode.
  Date: 2026-09-09
  Amended later on 2026-09-09: automatic dead-lettering is withdrawn. The store never skips an
  event on a consumer's behalf; see the undecodable-handler decision below.

- Decision: Implement handler-stall observability in the store worker as `handlerStallWarnAfter`
  plus `KirokuEventSubscriptionHandlerStalled`; the adapter forwards the setting and adds no
  constructor of its own.
  Rationale: A pending acknowledgement is a handler holding one event too long, which any
  subscriber can do. One worker-level cell serves every caller and keeps adapter-specific names
  out of the store's vocabulary.
  Date: 2026-09-09

- Decision: Remove runtime adopt-once paths: EP-1 derives group size in a migration from existing
  member rows, and EP-2 makes target adoption a declared `TargetBindingPolicy` with an emitted
  event.
  Rationale: Implicit one-way transitions on first start are the class of silent behavior this
  initiative removes elsewhere. Where a value can be derived it belongs in the schema step; where
  it cannot, the caller declares the policy, following the `MissingCheckpointPolicy` precedent.
  Date: 2026-09-09

- Decision: Introduce `SomeSubscriptionStartupFailure` as an exception-hierarchy parent for every
  subscription startup refusal, owned by EP-2 and adopted by EP-1's new failure.
  Rationale: The cohort grows the startup surface from four failures to seven. The GHC hierarchy
  pattern lets callers catch once without breaking any existing concrete handler.
  Date: 2026-09-09
  Amended later on 2026-09-09: construction-time validation removes the three configuration
  errors, so the parent covers four runtime refusals.

- Decision: An undecodable event is handed to an optional per-subscription `undecodableHandler`
  that returns an ordinary `SubscriptionResult`; without one, the worker retries briefly and stops
  the subscription with `StopUndecodable`. The store never dead-letters on a consumer's behalf.
  Rationale: Every dead-letter in Kiroku is the consumer's decision. An automatic one advances
  the checkpoint past an event the consumer never saw and, under a systemic hook failure, turns
  one configuration error into a flood of skipped events. The disposition vocabulary already
  expresses every choice a consumer could want, and the default is the safe one.
  Date: 2026-09-09

- Decision: Validate configuration at construction with smart constructors returning typed
  errors (`BatchSize`, `StreamBufferSize`, `ConsumerGroupSize`, `mkConsumerGroup`), following the
  retention-limit precedent; configuration errors are values, and only refusals that depend on
  stored state remain exceptions.
  Rationale: A value that cannot be invalid needs no runtime check, and separating the two kinds
  of failure gives the 1.0 surface one clear rule. Recorded in
  [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md).
  Date: 2026-09-09

- Decision: Drop `kiroku.subscriptions.stream_name` in EP-2's migration.
  Rationale: Nothing reads it, the published relation does not expose it, and `DROP COLUMN` is
  metadata-only; a cleanup deferred to "a later migration" with no owner would not happen.
  Date: 2026-09-09

- Decision: All explicit checkpoint-set operations (reset, resize, rebind) live in
  `Kiroku.Store.Subscription.Checkpoint` and return `...Report` types.
  Rationale: ADR-4 defines them as one family; one module and one naming scheme make that visible
  to a 1.0 reader and to Keiro, which composes them.
  Date: 2026-09-09

- Decision: Recommended landing order through `Worker.hs` is EP-3, then EP-2, then EP-4; EP-1 and
  EP-5 are free.
  Rationale: Three edits to the delivery primitive are small individually but a three-way merge of
  it is not; serial landing keeps each diff reviewable. Hard dependencies are unchanged.
  Date: 2026-09-09

- Decision: Record the cohort's API conventions now as
  [ADR-8](../adr/0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
  rather than leaving them to a child plan.
  Rationale: The conventions are cross-plan and will govern the 1.0 review; the decode hook's
  own contract still becomes EP-3's ADR at implementation.
  Date: 2026-09-09

- Decision: Regrouping `SubscriptionConfig` into policy sub-records is a deliberate exclusion,
  deferred to the 1.0 API review.
  Rationale: The record now carries seven policy-like fields and would read better grouped, but
  regrouping touches every caller for no behavioral gain and belongs to a review of the whole
  configuration surface, not to a hardening cohort.
  Date: 2026-09-09


## Outcomes & Retrospective

Implementation update (2026-10-09): EP-1's functional milestones are implemented;
PostgreSQL 18.6 store, adapter, observability-package and migration checks pass.
The child stays In Progress because its controlled write-performance gate and
remaining evidence are mandatory. No child is yet marked Complete, and no
cohort package has been released.


The coordination transfer is complete: Kiroku now contains the authoritative MasterPlan and six
self-contained child plans under Intention `intention_01m12ed0r5e61aqa9h1rfgvk4a`; the Keiro
source documents identify these successors and are retired from execution. At the 2026-10-09 audit, none of the six children meets its implementation acceptance.
EP-1, EP-2, EP-3, and EP-5 can begin; the suggested shared-worker sequence is EP-3 then EP-2,
with EP-1 completed before EP-4's validated adapter surface. EP-5 is a small independent error-path
fix. EP-6 remains gated on all five. The source audit confirms useful adjacent fixes but does not
substitute for the outstanding runtime and performance acceptance runs. At completion, review every child Decision Log and update ADR-2,
ADR-4, or new ADRs where the implemented contracts require durable memory.


## Revision Notes

Revision note (2026-09-09): Performance review under ADR-5. Added ADR-5 to the durable context, a
Performance gates integration point with per-child gate ownership and hot-path boundaries, three
review discoveries, one decision, and a Progress entry. Cascaded gate commands and boundaries to
plans 81, 82, 83, 84, and 85; plan 86 needed no change because it touches only the error path. No
ADR was changed because assigning existing gates is coordination, not a new durable decision.

Revision note (2026-09-09): Design review. Recorded five API decisions (typed target columns, a
per-event decode contract, a worker-level handler-stall event, migration-derived or declared
adoption instead of adopt-once magic, and a startup-failure exception parent) and cascaded them
into plans 81 through 85: EP-3 is substantially redesigned, EP-4 moves its watchdog into the
store, EP-1 and EP-2 each gain a migration, and EP-6's forecast of public-surface changes is
updated. Child titles and file names are retained for reference stability. ADR creation stays
with the implementing children (EP-3 creates the decode-contract ADR; EP-2 amends ADR-4).

Revision note (2026-09-09): Design review, second pass, approved by the user. Withdrew automatic
dead-lettering in favor of a per-subscription `undecodableHandler` with a retry-then-stop
default; adopted construction-time validation for batch, buffer, and consumer-group values;
dropped `stream_name` in EP-2's migration; consolidated reset, resize, and rebind in the
checkpoint module with `...Report` naming; recorded a landing order through `Worker.hs`; widened
EP-6's Keiro scope; accepted ADR-8 for the resulting API conventions; and recorded the
`SubscriptionConfig` regrouping as a deliberate exclusion. Cascaded to plans 81 through 85.

Revision note (2026-10-09): Refreshed against `e6ea664`, all six children, implementation and test
sources, migrations through `0012`, package changelogs, relevant ADRs, and current local OKF
records. Kept unimplemented children open, recorded shipped baseline fixes, corrected the stale
automatic-dead-letter summary and benchmark coverage claims, documented performance risks and
required direct measurements, mapped adjacent requests to their owners, and cascaded the evidence
and validation changes into plans 81–86. No production code, package versions, or ADR decisions
changed, and no runtime/performance test result is claimed by this documentation-only refresh.

Revision note (2026-10-09, write-performance requirement): Added a blocking mixed-write acceptance
contract and per-child gate ownership, preserved the original control for cumulative comparisons,
changed the planned watchdog default to opt-in, required no-hook fast paths, and recorded ADR-11.
This follows the user's explicit sensitivity to performance, especially event writes. No benchmark
result is claimed and no production code has changed.

Revision note (2026-10-09, implementation): Began EP-1 in registry order, recorded
its functional progress and migration allocation, and documented the worker
initializer and validated adapter group-size integration for later children.
EP-1 remains In Progress until all required acceptance evidence is complete.
