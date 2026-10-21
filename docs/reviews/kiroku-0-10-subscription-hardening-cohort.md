---
type: Review
title: Kiroku 0.10.0.0 subscription hardening cohort
description: The 0.9.0.1 to 0.10.0.0 cohort changes no append or read SQL and its per-batch subscription cost is bounded by the retained same-process evidence, the new startup verification, decode-failure containment, reconnect repair and adapter acknowledgement paths trace correctly, but migration 0013 plus the documented resize remedy permanently skips the backlog of a legacy member that never checkpointed, the kiroku-store changelog omits several public API breaks, the consumer upgrade edge landed two days after publication, and the operator migration guide still stops at 0012.
generated:
  by: process:claude-code
  at: "2026-10-21T14:17:00Z"
reviewId: REV-2
subject: mori://shinzui/kiroku
subjectKind: project
reviewedSha: 364ffa82136fcfc83d39ead1234abffaf500844b
coverage: incremental
baseSha: 94e11392a1e84f33ecd7f135f816e4ce3ea019d2
previousReview: REV-1
reviewedAt: "2026-10-21T13:57:37Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - performance
  - design
  - test-coverage
  - documentation
  - operability
produced:
  - mori://shinzui/kiroku/plans/100-make-resize-safe-for-legacy-consumer-groups-whose-members-never-checkpointed
  - mori://shinzui/kiroku/plans/102-reconcile-the-0-10-and-0-11-release-surface-changelogs-operator-migration-guide-and-performance-ledger
  - mori://shinzui/kiroku/plans/103-close-the-subscription-worker-observability-and-decode-filter-gaps-from-rev-2
  - mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-5
context: >-
  Reviewed the 38 commits between the kiroku-store-v0.9.0.1 tag and the
  release commit that published kiroku-store 0.10.0.0, kiroku-store-migrations
  0.7.0.0, kiroku-metrics 0.2.0.0, kiroku-otel 0.2.0.11, kiroku-cli 0.2.0.9
  and shibuya-kiroku-adapter 0.6.0.0. This reviewer read the append, SQL,
  error and publisher diffs, migrations 0013 and 0014, the changelogs and the
  retained EP6 evidence directly, and ran the ADR-5 gates and every test
  suite at repository HEAD, whose append and category-read SQL is the 0.10
  SQL plus the additive 0.11 statements. The subscription worker, FSM, types,
  checkpoint, adapter, metrics and otel diffs and their tests were read by a
  delegated reviewer with no build access; its three verdict-setting
  findings were re-verified by this reviewer against the code at HEAD before
  being recorded. No remote cell was used. Performance claims rest on the
  retained EP6 cell comparison and on local same-process gates, never on
  absolute historical timings.
---

# Kiroku 0.10.0.0 subscription hardening cohort

## Verdict

Changes requested. The hardening itself is sound: consumer-group topology and
target binding are verified under a per-name advisory lock before any row is
written, typed decode failures are contained per event with a preserved
checkpoint, live reconnect resumes from the last resolved position, the
adapter acknowledges nothing before the Shibuya handler finalizes, and unique
constraints are matched by exact name against constraints that exist in the
migrations. No append, read or category SQL changed in this cohort. What
needs correcting before the next tag is one operator path that loses
deliveries, and a release surface that under-describes what shipped.

## Required before the next tag

1. **Close BUG-5.** Migration 0013 derives `consumer_group_size` as
   `max(member) + 1`. A size-4 group whose member 3 never ran derives 3,
   startup refuses size 4, and the remedy the migration comment, plan 81 and
   `docs/user/consumer-groups.md` prescribe, `resizeConsumerGroupTx`, seeds the
   missing member at the group's minimum checkpoint. That member's slice below
   the minimum was never covered by anyone, so it is skipped permanently; on
   0.9.0.1 the same member would have initialized from the beginning. The
   fix can be documentation plus a reset step, or a seed-position choice on
   resize; the report lists both. `Test/ConsumerGroupResize.hs` currently
   asserts the seeded-at-minimum row shape as correct and has no case that
   appends into the new member's slice first.
2. **Reconcile the kiroku-store 0.10.0.0 changelog with the diff.** Breaks
   not listed: `SubscriptionConfigM` gained `targetBindingPolicy` and its
   `batchSize` changed from `Int32` to `BatchSize`; `StoreError.EventDecodeFailed`
   and `DeadLetterReason.DeadLetterDecodeFailure` break exhaustive matches but
   appear only under new features; `KirokuEventSubscriptionTargetBound` is a new
   observer constructor the entry does not name; `InvalidConsumerGroup` and
   `InvalidStreamBufferSize` lost their `Exception` instances; the exposed
   `Fsm`, `EventPublisher`, `Worker` and `SQL` modules changed signatures
   (`ConnectionLost` carries a position, batches are `DecodedBatch`,
   `saveCheckpointMemberStmt` is a six-tuple statement, `DeadLetterParams`
   gained three fields). The published entry cannot change on Hackage; the
   repository changelog and the next release notes can carry the correction.
3. **Bring the operator documentation up to the cohort.**
   `docs/user/schema-migrations.md` still says `0008` through `0012` are the
   native migrations and has a maintenance-window section only for 0012;
   0013 and 0014 are covered only in passing by `consumer-groups.md` and
   `subscriptions.md`. The `0.9.0.1 -> 0.10.0.0` upgrade edge was published on
   2026-10-12, two days after the cohort was on Hackage, so consumers who
   upgraded on release day had no edge to run.

## Hot-path performance

| Path | What changed | Evidence | Assessment |
| --- | --- | --- | --- |
| Append (`appendToStream`, `appendMultiStream`, links, hard delete) | Nothing. The append CTEs, link and delete statements are byte-identical between 94e1139 and 364ffa8; `Effect.hs` changed only `decodeReadEvents` | `git diff` of `SQL.hs` and `Effect.hs` for the range | Unchanged |
| Public reads | `decodeReadEvents` returns the raw vector when no hook is configured and maps the hook per event otherwise | Source | No-hook path cheaper than before (no wrapper); hook path unchanged in statement count |
| Per-batch checkpoint save (`saveCheckpointMember*`) | Same single upsert now binds four or five parameters and sets `consumer_group_size`, `target_kind`, `target_category` on every save | `SQL.hs` `saveCheckpointMemberSQLWith`; `insertDeadLetterAndCheckpointSQL` likewise | One round trip as before; a few more bytes per row version on a small table |
| Per-batch worker path | Each fetched batch is wrapped as `UnchangedBatch` (no hook) or per-event `Decoded`; `walk` adds one indirection and writes `posRef` twice per delivered event; the publisher traverses a transformed batch only to emit failures | Delegated trace of `Worker.hs`, `Fsm.hs`, `EventPublisher.hs` | Allocation-level cost, no statements added |
| Handler stall watchdog | Off by default; enabled it costs one monotonic read, two TVar writes and a shared `registerDelay` per delivery | `Worker.hs` `withHandlerStallDiagnostics` | Zero when disabled, as the changelog states |
| Startup | Checkpoint load became one `ReadCommitted Write` transaction with an advisory lock | `Checkpoint/SQL.hs` | Once per worker start |

The retained evidence for this cohort is the EP6 cell comparison at candidate
5805117 against control e6ea664 on a dedicated PostgreSQL 18.6 cell: 25 valid
trials and eleven matched default-path pairs; latest adapter throughput +0.39%
(95% interval -2.88% to +3.77%), p99 +0.06% (-4.17% to +4.47%); hook-path
throughput +1.60% (+0.89% to +2.31%). The original zero-slowdown policy was
not met, cross-session pooling was rejected for a fingerprint mismatch, and
the user accepted the bounded evidence practically on 2026-10-10. This review
treats that as what it is: the measured adapter and hook paths moved by less
than the interval width, no reproducible append slowdown was found, and no
statistical equivalence is claimed. The per-batch additions above are
consistent with that bound. The two historical telemetry timeouts EP6
retained are not evidence either way.

At repository HEAD, whose append and category-read SQL is the 0.10 SQL plus
0.11's additive statements, `just perf-structure` (41 examples) and
`just perf-workload-gate` (16 cases, pipeline 0.86x and 0.87x against 0.90,
category reads 0.01x to 0.39x against their ceilings) pass. The
`append-category-column` cell passed vacuously because its control arm is
invalid; that cell measures 0.9's migration 0012 and is REV-1's finding.

## Correctness

- **Startup verification.** The initializer takes
  `pg_advisory_xact_lock` on a per-name key inside one transaction, reads
  every row, and returns `Left SomeSubscriptionStartupFailure` without
  mutation on a size or binding mismatch; concurrent first starts are
  serialized, and `ConsumerGroupResize.hs` and `SubscriptionTarget.hs`
  exercise the concurrent case. The worker converts the value to an exception
  that `wait` surfaces, so the refusal is typed but not exceptionless end to
  end.
- **Migrations.** A 0.9 worker left running against the migrated schema
  keeps working (every 0.9 statement names its columns and none reads
  `stream_name`); its new rows carry size 1 and `unbound`, which the next 0.10
  start refuses. The `stream_name` drop is irreversible but the column was
  never written by 0.9. The derived size is wrong in both directions: too
  small when high members never ran (BUG-5), too large when stale rows from a
  shrunk group remain, which only causes redelivery.
- **Decode failures.** The publisher advances to the raw batch tail and emits
  `KirokuEventPublisherDecodeFailed` per undecodable event; the worker retries
  the hook up to `retryMaxAttempts`, throws `SubscriptionUndecodable` with the
  checkpoint preserved before the event, or honours the callback's
  disposition. No double delivery was found. One asymmetry is recorded under
  design.
- **Reconnect.** `ConnectionLost` carries the last resolved position and the
  FSM resumes from the maximum of cursor and observed position; `posRef` is
  written only after an event resolves or at batch tail. No miss or duplicate
  within a process; the reconnect loop retries forever with a 30 s cap, as
  before.
- **Adapter.** No acknowledgement-path code changed; the watchdog wraps the
  bridge handler and the five-delivery limit dead-letters at the fifth
  attempt, with tests at limits 5 and 2. shibuya-core's `processOne` does
  substitute an immediate retry on handler exception, as plan 84 claimed.
- **Unique constraints.** `events_pkey`, `stream_events_pkey`,
  `ix_streams_stream_name` and `ux_stream_events_stream_version` all exist
  with those names in the migrations; an unknown unique violation on append
  still maps to the expected-version fallback, elsewhere to
  `UnexpectedServerError "23505"`.

## Design and operability notes

These do not block a tag but should be decided deliberately.

- The event-type filter is applied to the decoded event when the hook
  succeeds and to the raw event when it fails, so with a type-rewriting hook
  and a filter on the rewritten type an undecodable event is silently
  skipped, checkpoint advanced, with no callback and no observer event
  (`Worker.hs` `walk`). The retry path filters on the decoded event. A test
  pins the raw-excluded case as intended.
- An `undecodableHandler` returning `Stop` durably checkpoints past the event
  while the default path stops before it; documented in ADR-12 and the user
  guide, but a callback that stops "to investigate" never sees the event
  again.
- Resize, rebind and reset take the name lock, but a running member's next
  save upserts size and binding unconditionally, so a topology change made
  while any member runs is partially undone. The docs say to stop workers;
  nothing enforces it.
- `initializeSubscriptionCheckpoint` still provisions size-1 `unbound` rows,
  so calling it for a member of a bound group breaks that member's next
  start.
- `InvalidHandlerStallWarnAfter` is thrown before the worker body, so no
  `Stopped` event is emitted for it; `SubscriptionTargetMismatch` has no
  dedicated observer event, unlike the size mismatch.
- kiroku-metrics 0.2.0.0 ends a live WebSocket tail on one typed decode
  failure and withholds the rest of that batch; 0.11 documents this as the
  contract (`live_decode_failed`), the 0.2.0.0 changelog did not.

## Test coverage

The migration suite covers 0013 for member sets (0,1), (0) and (0) and
asserts 0014 rewrites no heap; `HandlerStall.hs`, `PublisherCallbackResilience.hs`,
`SubscriptionTarget.hs`, `ConsumerGroupResize.hs`, `UniqueViolationMapping.hs`
and the adapter's delivery-limit cases cover the shipped behaviour. Missing:
the BUG-5 delivery case, any 0013 case with a gap below the configured size,
and a case for the filter asymmetry with a type-rewriting hook. At HEAD every
suite passes: 487 store, 117 metrics, 45 adapter, 24 otel, 22 CLI and 17
migration examples.

## Evidence and limits

- Local, at HEAD e2cdc892 on a quiet 36-core host (load 1.5 to 2.3):
  `just perf-structure`, `just bench-baseline-check` (30 names match),
  `just perf-workload-gate`, `cabal test all`.
- Retained: `kiroku-store/bench/results/ep6-release/practical-acceptance.md`
  and the EP6 diagnosis and tail-repeat directories it links.
- Not done: no execution of the BUG-5 scenario (it is filed as `reported`),
  no separate build at the 0.10 tag, no remote cell, no reading of
  hasql-transaction's retry internals.
