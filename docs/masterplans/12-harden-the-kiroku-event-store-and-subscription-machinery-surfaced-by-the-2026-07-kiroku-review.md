---
id: 12
slug: harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review
title: "Harden the Kiroku event store and subscription machinery surfaced by the 2026-07 Kiroku review"
kind: master-plan
created_at: 2026-08-27T21:11:09Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
---

# Harden the Kiroku event store and subscription machinery surfaced by the 2026-07 Kiroku review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

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
delivery; a permanently throwing publisher decode hook cannot leave every `$all` subscriber
apparently live but stalled; append unique-violation mapping distinguishes duplicate caller event
ids from store corruption; and the Shibuya adapter exposes retry policy and makes an unfinalized
acknowledgement observable. The final child plan releases the affected Kiroku packages and proves
downstream Keiro adoption.

Out of scope are dynamic consumer-group rebalancing, the proposed fresh-stream lock-order work in
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-7`, `HandlerInTransaction`, prefix
subscriptions, and redesign of the `$all` append serialization point. Replay-history retention is
already complete under [ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md).


## Decomposition Strategy

Five implementation plans are separated by functional ownership, followed by one release and
downstream-adoption plan. EP-1 owns consumer-group topology and safe resize. EP-2 owns the worker
cursor plus configuration identity and batch validation. EP-3 owns the shared publisher's
decode-hook failure boundary. EP-4 owns the Shibuya adapter's acknowledgement liveness and retry
configuration. EP-5 closes the two unique-violation mapping edge cases that remained hidden inside
the old write-path child plan after the main transient taxonomy landed. EP-6 integrates and
releases the cohort only after EP-1 through EP-5 are complete.

This split keeps independent proofs independent: consumer-group resize is a database topology
problem; reconnect is a worker finite-state-machine problem; publisher callback containment is a
shared-thread liveness problem; adapter finalization is an inter-package acknowledgement problem;
and unique-violation mapping is a pure error-taxonomy problem. Combining EP-2 and EP-3, as the
Keiro source plan did, was rejected because they have different failure contracts and can be
implemented and reverted independently. Recreating the already-landed hard-delete and transient
failure fixes was rejected because it would obscure current source truth.

Relevant durable context is [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md), which
defines static hash partitioning but contains a resize consequence EP-1 must amend;
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md), which requires exact checkpoint
identity and separates ordinary monotonic saves from explicit reset; and
[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md), which owns the
hard-delete lock order that superseded the source plan's proposed single-row locking change. The
completed checkpoint lifecycle request
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3` is adjacent but does not bind a
checkpoint to a subscription target or define group topology. No existing ADR covers persistent
decode-hook failure or adapter pending-ack observability; each child must decide during
implementation whether its result warrants a new record.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Make consumer-group topology durable and resize without gaps | docs/plans/81-make-consumer-group-topology-durable-and-resize-without-gaps.md | None | EP-2 | Not Started |
| 2 | Repair live reconnect and validate subscription identity and batch size | docs/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size.md | None | EP-1 | Not Started |
| 3 | Contain persistent publisher decode-hook failures | docs/plans/83-contain-persistent-publisher-decode-hook-failures.md | None | EP-2 | Not Started |
| 4 | Harden adapter acknowledgement liveness and expose retry policy | docs/plans/84-harden-adapter-acknowledgement-liveness-and-expose-retry-policy.md | None | EP-2, EP-3 | Not Started |
| 5 | Make append unique-violation classification exact | docs/plans/86-make-append-unique-violation-classification-exact.md | None | None | Not Started |
| 6 | Release the subscription hardening cohort and coordinate downstream adoption | docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |


## Dependency Graph

EP-1 through EP-5 have no hard dependencies and can proceed in parallel. EP-1 and EP-2 both
change checkpoint reads and writes, so their dependency is integration-only: whichever lands
second must preserve both topology and target-binding fields. EP-2 and EP-3 both touch
subscription observability but own different threads and failure types. EP-4 consumes the store's
subscription and observability surfaces; it may develop in parallel using the current surface,
then reconcile any new EP-3 event constructor before completion.

EP-6 hard-depends on all five implementation plans because package versions, PVP impact,
migration manifests, release order, and downstream Keiro bounds can be selected truthfully only
from the integrated code. EP-6 must use the repository release skill and re-query Hackage,
upstream tags, and Mori dependents at execution time; this MasterPlan deliberately does not pin a
future version number.


## Integration Points

`kiroku.subscriptions` and the checkpoint SQL are shared by EP-1 and EP-2. EP-1 owns
`consumer_group_size`; EP-2 owns target binding through `stream_name`. Both fields already exist
in migration `0001` but were never written. The current migration manifest has advanced beyond
the source plan's claimed `0009`, so neither child may reuse that number. If a backfill or default
change is required, create it with the standard `kiroku-store-migrate new --manifest ...`
scaffolder and let the manifest allocate the current filename.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` is shared by EP-1 and EP-2. EP-1 owns
checkpoint topology validation and resize; EP-2 owns `ConnectionLost` position propagation,
batch-size validation, and target validation. Keep the changes mechanically composable.

`kiroku-store/src/Kiroku/Store/Observability.hs` is shared by EP-3 and potentially EP-4. EP-3 owns
publisher decode-hook failure vocabulary. EP-4 owns adapter pending-ack vocabulary. If both add
constructors, each must update every exhaustive consumer in Kiroku packages and tests.

The public `SubscriptionConfig`/`RetryPolicy` contract flows from `kiroku-store` into
`shibuya-kiroku-adapter`. EP-4 threads the existing policy without redefining it. EP-6 owns final
cross-package version/bound changes and the downstream Keiro adoption proof.

Cross-repository work in Keiro must use canonical references. The transferred source remains
`mori://shinzui/keiro/masterplans/20-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review`;
EP-1's downstream shard-count seam belongs to `mori://shinzui/keiro`, while Kiroku remains the
source of truth for checkpoint topology and resize semantics.


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

No current improvement request covers reconnect progress, invalid batch size, target binding,
persistent publisher callback failure, adapter pending-ack observability/retry configuration, or
the exact append unique-violation mapping. These are corrections to behavior Kiroku already
provides, so this MasterPlan is their authoritative coordination record. Each implementation child
must decide during execution whether a focused Kiroku bug report or a new improvement request is
needed for durable OKF tracking; it must not edit completed IR-2, IR-3, or IR-5 to manufacture
coverage after the fact.


## Progress

- [x] (2026-08-27) Baseline: hard delete serializes against affected streams under ADR-7; the July orphan window is closed by released Kiroku 0.7 evidence.
- [x] (2026-08-27) Baseline: `40001`/`40P01` surface as retryable `TransientTransactionFailure` in Kiroku 0.8 and Keiro classifies the constructor as transient.
- [ ] EP-1: persist and validate consumer-group topology, refuse unsafe restarts, and expose an idempotent gap-free resize operation.
- [ ] EP-1: amend ADR-2 and the consumer-group guide; expose the transaction surface needed for downstream adoption.
- [ ] EP-2: reconnect database-driven live subscriptions from `posRef` and reject `batchSize < 1` before a worker starts.
- [ ] EP-2: bind every checkpoint to its subscription target, migrate legacy rows explicitly, and document deliberate retarget operations.
- [ ] EP-3: prove persistent decode-hook behavior and replace apparent-live retry spin with one explicit, observable terminal contract.
- [ ] EP-4: expose retry policy on single and consumer-group adapter configs; provide a guarded processor path and pending-ack observability.
- [ ] EP-5: distinguish `stream_events_pkey` duplicates and `ux_stream_events_stream_version` corruption with deterministic mapping tests.
- [ ] EP-6: run the integrated test matrix, release the affected package cohort with current authoritative versions, and prove downstream Keiro shard-count adoption without private Kiroku SQL.


## Surprises & Discoveries

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


## Decision Log

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


## Outcomes & Retrospective

The coordination transfer is complete: Kiroku now contains the authoritative MasterPlan and six
self-contained child plans under Intention `intention_01m12ed0r5e61aqa9h1rfgvk4a`; the Keiro
source documents identify these successors and are retired from execution. Implementation remains
open for EP-1 through EP-6. At completion, review every child Decision Log and update ADR-2,
ADR-4, or new ADRs where the implemented contracts require durable memory.
