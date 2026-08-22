---
id: 78
slug: apply-a-compaction-manifest-transactionally-with-ledgered-idempotence
title: "Apply a compaction manifest transactionally with ledgered idempotence"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Apply a compaction manifest transactionally with ledgered idempotence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is child EP-5 of the MasterPlan
[docs/masterplans/11-manifest-driven-selective-event-compaction.md](../masterplans/11-manifest-driven-selective-event-compaction.md).
It has one hard dependency: the preview plan
[docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md](77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md)
must be Complete, because apply reuses preview's validation function and statements verbatim.
Transitively that means the foundations —
[docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md](74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md)
(migration `0012`, `StoreIdentity`),
[docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md](75-expose-an-event-membership-and-reference-inventory-read-api.md)
(reference inventory statements), and
[docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md](76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md)
(manifest, refusal, and report types) — are already in the working tree.


## Purpose / Big Picture

After this plan, a `kiroku-store` consumer can hand the store a reviewed, digest-sealed
*compaction manifest* (an immutable list of selected events, each identified by event ID,
originating stream, original stream version, global position, and any explicitly acknowledged
link memberships, plus the expected head version of every affected stream) and call
`applyCompaction`. In one PostgreSQL transaction the store takes the replay-history coordinator
lock defined by ADR-7, refuses if any history-retention lease is active, locks every affected
stream row in ascending `stream_id` order, re-validates every witness in the manifest against
that locked state, and only then deletes exactly the accounted-for junction rows (the event's
home-stream row, its `$all` row, and any acknowledged link rows), optionally its dead letters,
and its payload row. It records the applied manifest in the append-only
`kiroku.event_compactions` ledger and commits. Nothing else changes: every retained event keeps
its event ID, stream version, global position, payload, metadata, causation and correlation IDs,
and memberships; every affected stream keeps its high-water `stream_version`; no `NOTIFY` fires.

The user-visible behaviours this enables are concrete. After an apply, `readStreamForward`,
`readStreamBackward`, `readAllForward`, and `readCategory` return the retained events with
unchanged numbers and simply skip the gaps. A subscription whose checkpoint sits below a gap
keeps moving forward and delivers only retained events. `appendToStream name (ExactVersion
preCompactionHead) [...]` succeeds and lands at `preCompactionHead + 1`. Applying the same
manifest a second time is an observable no-op that returns the stored ledger record with the
identical report digest. Applying a manifest while any history-retention lease is active, or
when any witness no longer matches, or when a selected event has a link, dead letter, or
causation dependent the manifest did not account for, refuses with a typed, closed
`CompactionRefusal` and changes no row. Operators can read the ledger through
`compactionLedger` and observe `KirokuEventCompactionApplied`,
`KirokuEventCompactionAlreadyApplied`, and `KirokuEventCompactionRefused` through the store's
event handler.

You can see it working by running the new `Test.CompactionApply` suite, which appends events,
links some into other streams, builds manifests, applies them, and asserts every retained row is
byte-identical while the selected rows are gone; and by running `just perf-check`, which proves
the ordinary append and read paths gained no statement, trigger, lock, or round trip.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `lockCompactionStreamsStmt`,
  `deleteCompactionJunctionsStmt`, `deleteCompactionDeadLettersStmt`,
  `deleteCompactionEventsStmt`, `insertCompactionRecordStmt`, and
  `compactionLedgerStmt` to `kiroku-store/src/Kiroku/Store/Compaction/SQL.hs`
- [ ] M1: Implement `applyCompactionTx` and `compactionLedgerTx` in
  `kiroku-store/src/Kiroku/Store/Compaction/Internal.hs` in the exact lock order
- [ ] M1: Export `applyCompactionTx` and `compactionLedgerTx` from `Kiroku.Store.Compaction`
  with Haddock; build clean with `cabal build kiroku-store`
- [ ] M1: `Test.CompactionApply` transaction-level examples (happy path, refusals leave rows
  unchanged, condemned wrapper transaction leaves rows and ledger unchanged) pass
- [ ] M2: Add `ApplyCompaction` and `GetCompactionLedger` to `data Store`, interpret them in
  `runStorePool`, emit the three events after the transaction
- [ ] M2: Add `KirokuEventCompactionApplied` and `KirokuEventCompactionAlreadyApplied` to
  `KirokuEvent`; add no-op arms in `kiroku-otel` and `kiroku-metrics`
- [ ] M2: Public wrappers `applyCompaction` and `compactionLedger`; `Test.CompactionApplyMock`;
  event-handler examples pass
- [ ] M3: Concurrency and lifecycle examples: head-drift refusal, append blocked then succeeds,
  lease refusal, already-applied no-op, ledger conflict, dead-letter and causation policies,
  multi-stream manifest, gap-tolerant reads, subscription continuation, expected-version append
- [ ] M3: Hedgehog property `compactingARandomSubsetPreservesTheRest` passes
- [ ] M4: `Test.PerformanceStructure` extended (ordinary SQL exclusion, `(6, 0)` unchanged,
  `compactionTriggerShapeStmt`, ledger query plans, one checkout per apply); `Test.NotifyGuard`
  extended; `just perf-check` passes with unchanged workload ratio recorded here
- [ ] M4: Compaction-contract ADR created with an `okf id next` handle, index and log updated,
  `just adr-validate` passes
- [ ] M4: CHANGELOG entries (unreleased) for `kiroku-store`, `kiroku-otel`, `kiroku-metrics`
- [ ] M4: `cabal test all` and `just test-matrix` green; Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Apply re-runs the complete preview validation (`validateCompactionTx` from
  `docs/plans/77-...`) after taking the coordinator and stream locks, rather than trusting a
  preview result passed in by the caller.
  Rationale: A preview holds no locks, so anything it observed may have changed. Re-validating
  under `FOR UPDATE` locks on every affected stream and under the coordinator lock is the only
  way to make "validate the complete manifest before deleting its first row" a transactional
  fact rather than a hope. The cost is one extra read pass inside a rare destructive operation.
  Date: 2026-08-22

- Decision: The ledger lookup by manifest digest happens under the coordinator lock and before
  the stream locks.
  Rationale: Two concurrent applies of the same manifest must serialize somewhere. The
  coordinator row is already the single serialization point for every destructive operation
  (ADR-7), so taking it first lets the second apply observe the first apply's committed ledger
  row and return `CompactionAlreadyApplied` instead of racing into validation.
  Date: 2026-08-22

- Decision: A mismatch between the validated expectation and the rows a `DELETE ... RETURNING`
  actually removed condemns the transaction and surfaces as
  `UnexpectedServerError "KRCMP" <message>`; no new `StoreError` constructor is added.
  Rationale: Under the held locks and the `no_update_*` immutability triggers this cannot
  happen; it exists as a defensive invariant so a future bug fails loudly with nothing
  committed. Reusing `UnexpectedServerError` keeps `StoreError` additive-free for this plan and
  leaves the constructor set stable for consumers.
  Date: 2026-08-22

- Decision: Dead letters are deleted only under `RemoveDeadLetters`, and always before the
  `events` delete.
  Rationale: `kiroku.dead_letters.event_id` is a foreign key to `kiroku.events.event_id`, so a
  payload delete with surviving dead letters fails the constraint. Under `RefuseDeadLetters`
  validation already refused, so the delete statement is skipped entirely rather than run as an
  empty no-op, which keeps the statement list of a refuse-policy apply minimal.
  Date: 2026-08-22

- Decision: Use `TxSessions.transaction` (the retrying entry point) with
  `ReadCommitted` / `Write`, mirroring hard delete.
  Rationale: The body is pure SQL. On a `40001`/`40P01` retry PostgreSQL has rolled back
  everything, the coordinator lock is re-taken, the ledger is re-read, and the manifest is
  re-validated, so a retried body is exactly as safe as a first attempt. `ReadCommitted` is
  sufficient because every row the decision depends on is explicitly locked.
  Date: 2026-08-22

- Decision: The ledger's `affected_streams` JSON column stores the verified head witnesses
  (`[{"stream": ..., "head_version": ...}]`, sorted by stream name), not the stream IDs.
  Rationale: A ledger row must remain meaningful after a stream is later hard-deleted and its
  surrogate ID is gone; names are the identity consumers reason about, and the head version is
  the witness an auditor wants to compare against the manifest.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Kiroku is a PostgreSQL event store written in Haskell. This repository is a multi-package Cabal
project (`cabal.project` at the root, GHC 9.12.4). The package this plan changes most is
`kiroku-store`; it also touches `kiroku-otel` and `kiroku-metrics` because they pattern-match
exhaustively on the store's event type. Every test suite brings its own PostgreSQL through
`ephemeral-pg`; nothing needs a `DATABASE_URL`.

### How events are stored

All Kiroku objects live in the `kiroku` schema (ADR-3). An *event* is one row in
`kiroku.events` (`event_id UUID PRIMARY KEY`, `event_type`, `causation_id`, `correlation_id`,
`data JSONB`, `metadata JSONB`, `created_at`). A *stream* is one row in `kiroku.streams`
(`stream_id BIGSERIAL`, `stream_name`, `stream_version BIGINT` — the high-water mark used by
optimistic-concurrency appends, `deleted_at`, `truncate_before`). The reserved stream `$all`
is the row with `stream_id = 0`; its `stream_version` is the global append frontier. Stream
membership is the junction table `kiroku.stream_events (event_id, stream_id, stream_version,
original_stream_id, original_stream_version)` with primary key `(event_id, stream_id)`. Every
originated event has exactly two *derived memberships*: its *home row* (where
`stream_id = original_stream_id` and `stream_version = original_stream_version`) and its
*global row* (where `stream_id = 0` and `stream_version` is the global position). Any other row
for that event is a *link* created by `Kiroku.Store.Link.linkToStream`; a link row carries the
origin in `original_stream_id` / `original_stream_version` even when it is a link of a link.
A *dead letter* is a row in `kiroku.dead_letters` written by a subscription worker; its
`event_id` column is a foreign key to `kiroku.events`. A *causation dependent* of event E is any
other event whose `causation_id` equals E's `event_id`; this is a soft reference with no foreign
key.

Ordered reads are cursor-based (`stream_version > $cursor`, `ORDER BY stream_version`) in
`kiroku-store/src/Kiroku/Store/SQL.hs` (`readStreamForwardSQL`, `readAllForwardSQL`,
`readCategoryForwardSQL`), so a missing row is simply skipped. Appends compare against
`streams.stream_version`, which compaction never changes. Subscriptions treat an empty fetch as
"caught up" (`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, `FetchEmpty -> Live`), so
a gap at the tail does not stall them.

### The destructive-operation template: hard delete

The only existing physical deletion is whole-stream hard delete. Its interpreter arm in
`kiroku-store/src/Kiroku/Store/Effect.hs` is the template this plan follows and must be read
before writing any code:

```haskell
    HardDeleteStream (StreamName name) -> do
        rejectInvalidApplicationStream name
        let txn = do
                Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
                HistoryRetention.lockHistoryRetentionCoordinatorTx
                mSid <- Tx.statement name SQL.findStreamIdStmt
                case mSid of
                    Nothing -> pure (Right Nothing)
                    Just sid -> do
                        conflict <- HistoryRetention.activeHistoryRetentionConflictTx
                        case conflict of
                            Just active -> pure (Left active)
                            Nothing -> do
                                HistoryRetention.lockAffectedStreamsForHardDeleteTx sid
                                originated <- Tx.statement sid SQL.deleteAllRowsForOriginStmt
                                Tx.statement originated SQL.deleteJunctionsByEventIdsStmt
                                linkedIn <- Tx.statement sid SQL.deleteStreamOwnJunctionsStmt
                                let affected = originated <> linkedIn
                                Tx.statement affected SQL.deleteDeadLettersForOrphanedEventsStmt
                                Tx.statement affected SQL.deleteOrphanedEventsStmt
                                Tx.statement sid SQL.deleteStreamRowStmt
                                pure (Right (Just (StreamId sid)))
        result <-
            usePool (store ^. #pool) $
                TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
        case result of
            Right (Just sid) ->
                liftIO $ emitOrDrop (store ^. #eventHandler) (KirokuEventHardDeleteIssued (StreamName name) sid)
            Right Nothing -> pure ()
            Left conflict -> do
                liftIO $
                    emitOrDrop
                        (store ^. #eventHandler)
                        (KirokuEventHardDeleteHistoryRetentionConflict (StreamName name) conflict)
                throwError (HistoryRetentionActive (StreamName name) conflict)
        pure (either (const Nothing) (\value -> value) result)
```

Four things in that arm matter here. First, `SET LOCAL kiroku.enable_hard_deletes = 'on'` is
required because migration `0001` installed `BEFORE DELETE` row triggers (`no_delete_events`,
`no_delete_stream_events`, `no_delete_streams`, function `kiroku.protect_deletion()`) and
`BEFORE TRUNCATE` statement triggers that raise unless that session-local GUC is `on`; the
`kiroku.dead_letters`, `kiroku.store_identity`, and `kiroku.event_compactions` tables are gated
the same way. Second, `lockHistoryRetentionCoordinatorTx` (in
`kiroku-store/src/Kiroku/Store/HistoryRetention/Internal.hs`) runs
`SELECT singleton FROM kiroku.history_retention_coordinator WHERE singleton FOR UPDATE`. It must
be taken before any `DELETE` because migration `0010` installed statement-level `BEFORE DELETE`
and `BEFORE TRUNCATE` triggers (`protect_replay_history_delete` / `_truncate`, function
`kiroku.protect_replay_history_from_destruction()`) on `events`, `stream_events`, and
`streams` that lock that same coordinator row and raise SQLSTATE `KR001` if any lease in
`kiroku.history_retention_leases` is active (`released_at IS NULL AND expires_at >
clock_timestamp()`). Taking the coordinator first gives one deterministic lock order and lets
Kiroku return a typed refusal instead of a server error. Third,
`activeHistoryRetentionConflictTx` returns `Maybe HistoryRetentionConflict` (active count and
earliest expiry). Fourth, `lockAffectedStreamsForHardDeleteTx` locks the target stream and every
stream that holds a junction for one of its events, `ORDER BY stream_id ... FOR UPDATE`, before
the first delete; ADR-7 fixes that order as "coordinator, then affected streams ascending by
`stream_id`". Also note that hard delete deletes dead letters before orphaned payloads because of
the `dead_letters.event_id` foreign key; see the Haddock on `deleteDeadLettersForOrphanedEventsStmt`
in `kiroku-store/src/Kiroku/Store/SQL.hs`.

`runTxOnPool` in the same module runs a `Tx.Transaction` through
`Hasql.Transaction.Sessions.transaction`, which automatically retries the whole body on
PostgreSQL's class-40 codes (`40001` serialization failure, `40P01` deadlock). Because the body
is pure SQL and PostgreSQL rolls back the failed attempt completely, a retry is indistinguishable
from a first attempt. `Hasql.Transaction.condemn` marks the current transaction for rollback at
the end of the body; the tests use it for failure injection ("the transaction fails before
commit").

### What the foundations already provide

From `docs/plans/74-...`: migration `kiroku-store-migrations/migrations/0012.sql` created
`kiroku.store_identity` (one row, `store_id UUID`) and the empty ledger
`kiroku.event_compactions` with the columns, named constraints, the index
`ix_event_compactions_applied_at (applied_at DESC, compaction_id)`, a `UNIQUE` constraint on
`manifest_digest`, and UPDATE/DELETE/TRUNCATE protection triggers; `Kiroku.Store.Types` has
`newtype StoreIdentity = StoreIdentity UUID`; `Kiroku.Store.Transaction.storeIdentityTx` reads
the identity. The ledger columns, in order, are `compaction_id`, `manifest_digest`,
`report_digest`, `store_id`, `operation`, `dead_letter_policy` (`'refuse'` | `'remove'`),
`causation_policy` (`'refuse'` | `'allow'`), `selected_events`, `home_memberships`,
`global_memberships`, `link_memberships`, `dead_letters_removed`, `causation_dependents`,
`lowest_global_position`, `highest_global_position`, `affected_streams JSONB`, `applied_at`
(default `now()`), `applied_by` (default `session_user`). Check constraints require the two
digests to be 32 bytes, `selected_events > 0`, `home_memberships = selected_events`,
`global_memberships = selected_events`, and `0 < lowest_global_position <= highest_global_position`.

From `docs/plans/75-...`: `Kiroku.Store.SQL` exports `eventMembershipsStmt`,
`deadLetterCountsStmt`, and `causationDependentCountsStmt`, and `Kiroku.Store.Types` has
`EventMembership`, `EventMembershipKind (HomeMembership | GlobalMembership | LinkMembership)`,
and `EventReferenceInventory`.

From `docs/plans/76-...`: the exposed module `Kiroku.Store.Compaction.Types` defines the
abstract `CompactionManifest` (built only by `mkCompactionManifest`, read through accessors
`manifestStoreIdentity`, `manifestOperation`, `manifestDeadLetterPolicy`,
`manifestCausationPolicy`, `manifestStreamHeads`, `manifestSelections`, `manifestDigest`),
`CompactionSelection { eventId, originStream, originVersion, globalPosition, acknowledgedLinks
:: Vector LinkWitness }`, `LinkWitness { stream, streamVersion }`, `StreamHeadWitness { stream,
headVersion }`, `DeadLetterPolicy (RefuseDeadLetters | RemoveDeadLetters)`, `CausationPolicy
(RefuseCausationDependents | AllowDanglingCausation)`, the closed `CompactionRefusal` sum
(`CompactionStoreIdentityMismatch`, `CompactionHistoryRetentionActive`,
`CompactionStreamMissing`, `CompactionStreamSoftDeleted`, `CompactionStreamHeadDrift`,
`CompactionSelectedEventMissing`, `CompactionWitnessMismatch`, `CompactionUnexpectedLink`,
`CompactionAcknowledgedLinkMissing`, `CompactionDeadLettersPresent`,
`CompactionCausationDependentsPresent`, `CompactionLedgerConflict { compactionId,
survivingEvents }`), `CompactionReport` (all counters, `affectedStreams`, `reportDigest`),
`compactionReportDigest`, `CompactionRecord { compactionId, report, appliedAt, appliedBy }`,
`CompactionApplyResult (CompactionAppliedNow CompactionRecord | CompactionAlreadyApplied
CompactionRecord)`, `CompactionId`, `CompactionDigest` (32 bytes, with
`compactionDigestBytes`/`compactionDigestHex`), `CompactionLedgerQuery { limit ::
CompactionLedgerLimit }`, and `mkCompactionLedgerLimit` (1 through 1000). `maxCompactionSelections`
is 100000.

From `docs/plans/77-...`: the public module `Kiroku.Store.Compaction` exports
`previewCompaction`, `previewCompactionTx`, and re-exports the types; the internal module
`Kiroku.Store.Compaction.Internal` exports a reusable

```haskell
data ValidatedCompaction = ValidatedCompaction
    { manifest :: !CompactionManifest
    , streamIds :: !(Map StreamName StreamId)          -- every touched stream, resolved
    , selectedEventIds :: !(Vector UUID)               -- canonical (global position) order
    , acknowledgedLinkCount :: !Int64
    , deadLetterCount :: !Int64                        -- rows that RemoveDeadLetters would delete
    , causationDependentCount :: !Int64
    , report :: !CompactionReport                      -- sealed with its reportDigest
    }

data ValidationOutcome
    = ValidationRefused (NonEmpty CompactionRefusal)
    | ValidationAlreadyApplied CompactionRecord
    | ValidationReady ValidatedCompaction

validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport
```

`validateCompactionTx` performs, in order: the store-identity check (short-circuits on
mismatch), the active-lease probe (`activeHistoryRetentionConflictTx`, recorded as a refusal
without short-circuiting), stream resolution through the non-locking `resolveStreamsStmt`
(missing, soft-deleted, and head-drift refusals), the witness join, the membership comparison
against acknowledged links, the dead-letter and causation policies, and finally the ledger
lookup by manifest digest: a ledger row with zero surviving selected events yields
`ValidationAlreadyApplied record`, a ledger row with survivors yields
`ValidationRefused (CompactionLedgerConflict ... :| [])`, and no ledger row yields either the
accumulated refusals or `ValidationReady` with the sealed report built by `buildReport`. Apply
calls this function unchanged after it has taken its locks; every read inside it then observes
the locked state, and the ledger lookup happens under the coordinator lock because apply takes
the coordinator first. Do not duplicate the validation and do not add a second entry point; the
contract is "the validation step is one function that apply calls after locking".

### Observability and the exhaustive consumers

`kiroku-store/src/Kiroku/Store/Observability.hs` defines `data KirokuEvent` with deliberately
additive constructors and `emitOrDrop :: Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()`.
The preview plan added `KirokuEventCompactionPreviewed !CompactionDigest !Int64` and
`KirokuEventCompactionRefused !CompactionDigest !CompactionRefusal !Int`. Two downstream
packages match `KirokuEvent` exhaustively under `-Werror=incomplete-patterns`:
`kiroku-otel/src/Kiroku/Otel/Subscription.hs` (`onEvent`, the block ending with
`KirokuEventHardDeleteHistoryRetentionConflict{} -> pure ()`) and
`kiroku-metrics/src/Kiroku/Metrics/Collector.hs` (`applyEvent`, the block around line 220).
Every constructor this plan adds needs an explicit no-op arm in both, or `cabal build all`
fails.

### Tests and gates

The single `kiroku-store` test suite is `kiroku-store:kiroku-store-test` (hspec; modules are
listed explicitly under `other-modules` in `kiroku-store/kiroku-store.cabal`, and each spec is
registered in `kiroku-store/test/Main.hs`). `kiroku-store/test/Test/Helpers.hs` provides
`withTestStore :: (KirokuStore -> IO ()) -> IO ()` (fresh migrated database per example),
`withTestStoreSettings`, `makeEvent :: Text -> Value -> EventData`, `countEvents`,
`countDeadLettersForEvents`, `insertDeadLetterForEvent`, `truncateRejected`, and
`waitForPublisher`. `kiroku-store/test/Test/HistoryRetention.hs` holds the two-connection race
pattern: one transaction holds a lock while running `SELECT pg_sleep(0.4) IS NULL /* <unique
marker> */`, the test polls `pg_stat_activity` for that exact query text to know the lock is
held (`waitForCoordinatorPhase`), starts the competing operation with `Async.async`, sleeps 50
ms, and uses `Async.poll` — `Nothing` means still blocked, `Just _` means it wrongly slipped
through — then `waitWithin` (a two-second `Async.race`) collects both results.
`kiroku-store/test/Test/StreamHistoryGuard.hs` wraps the same idea as `assertBlockedByGuard`.
Mock interpreters (for example `kiroku-store/test/Test/HistoryRetentionMock.hs`) are
`interpret_` handlers that record call names into an `IORef [Text]`, assert the argument, return a
sample value, and end with `_ -> error "unexpected Store operation ..."`.

The performance gates are ADR-5's three tiers. Tier one is the `describe "performance
structure"` block in `kiroku-store/test/Main.hs` (`just perf-structure` matches that string),
which runs `Test.PerformanceStructure.spec` (an `ordinarySql` list asserted to never mention
`history_retention`; `retentionTriggerShapeStmt` asserting `(6, 0)` — six
`protect_replay_history_*` triggers on `events`/`stream_events`/`streams`, none firing on
INSERT or UPDATE; pool-checkout counting through `observationHandler`; and `EXPLAIN (FORMAT
JSON, COSTS OFF)` plan assertions via `expectIndex`/`expectNoNodeType` over a seeded
`queryPlanFixture`), `Test.NotifyGuard.spec` (exact `LISTEN` payload list: lifecycle operations
must emit nothing), and `Test.StreamNameLookup.noOpSpec`. Tier two is
`just perf-workload-gate` (`kiroku-store/bench/RegressionGate.hs`, `bcompareWithin 0 0.90`
of the production multi-stream append against a sequential control). `just perf-check` runs
both. The migrations suite `kiroku-store-migrations:kiroku-store-migrations-test` asserts the
catalog contract of every table, including the compaction schema block that
`docs/plans/74-...` added.

### ADRs that govern this plan

- [ADR-7 — Replay-history retention uses leases and ordered stream guards](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md).
  Long rebuilds hold durable leases; every destructive operation serializes through the
  `history_retention_coordinator` singleton row, conservatively refuses while any lease is
  active (typed conflict from supported operations, SQLSTATE `KR001` from raw SQL), and locks
  affected streams in ascending `stream_id` after the coordinator. One-stream repairs hold
  `FOR SHARE` on their `streams` row. Ordinary append and read paths must gain no statement,
  trigger, lock, or round trip. Compaction is a destructive operation and joins this model
  exactly. The request cites this record as `mori://shinzui/kiroku/okf/adrs/concepts/ADR-7`.
- [ADR-5 — Separate performance regression evidence into structural, controlled workload, and historical telemetry tiers](../adr/0005-three-tier-performance-regression-gates.md).
  Deterministic structural checks and the same-process controlled workload ratio are the
  authoritative gates; the historical CSV is telemetry. This plan extends tier one and must leave
  tier two unchanged.
- [ADR-4 — Subscription checkpoint initialization is explicit and reset is a separate transaction operation](../adr/0004-explicit-subscription-checkpoint-lifecycle.md).
  Checkpoint semantics belong to consumers and are exposed as transaction-composable
  operations. This is why compaction does not guard on checkpoints: a consumer composes its own
  check with `applyCompactionTx` in one transaction.
- [ADR-3 — Install Kiroku objects in a dedicated `kiroku` schema](../adr/0003-dedicated-kiroku-schema.md).
  Every statement in this plan names `kiroku.`-qualified objects only through the connection's
  schema setting, exactly as existing statements in `Kiroku.Store.SQL` do (they rely on the
  store's configured `search_path`; follow the surrounding statements' convention).

The consuming project is `mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`;
it builds manifests from the reference inventory, previews, rehearses on a restored clone, and
applies under its own authorization. Nothing in this plan knows about Mori.


## Plan of Work

### Milestone 1 — The apply transaction

At the end of this milestone `Kiroku.Store.Compaction` exports `applyCompactionTx` and
`compactionLedgerTx`, and a transaction-level test proves that applying a manifest through
`runTransaction` removes exactly the accounted rows, writes one ledger row, and that a condemned
wrapper transaction leaves everything unchanged.

Add the new statements to `kiroku-store/src/Kiroku/Store/Compaction/SQL.hs` (an
`other-modules` entry; the preview plan created it). Follow the file's existing style:
`preparable` statements, `contrazipN` encoders from `contravariant-extras`, `D.rowVector` /
`D.rowMaybe` / `D.singleRow` decoders, and a small `column = D.column . D.nonNullable` helper.

The stream lock statement:

```haskell
lockCompactionStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Maybe UTCTime))
lockCompactionStreamsStmt =
    preparable
        """
        SELECT stream_name, stream_id, stream_version, deleted_at
        FROM streams
        WHERE stream_name = ANY($1::text[])
        ORDER BY stream_id
        FOR UPDATE
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        (D.rowVector ((,,,) <$> column D.text <*> column D.int8 <*> column D.int8 <*> D.column (D.nullable D.timestamptz)))
```

It is given every stream name the manifest mentions: each selection's origin stream, each
acknowledged link's target stream, and each stream-head witness (the manifest smart constructor
already guarantees these sets coincide). `ORDER BY stream_id` is what makes the lock order
deterministic and deadlock-free against hard delete and multi-stream append, both of which also
lock ascending by `stream_id` (`lockAffectedStreamsForHardDeleteStmt` and
`lockStreamsForMultiStmt` in the existing SQL modules). `FOR UPDATE` is chosen rather than `FOR
SHARE` because every append updates the locked `streams` row (it bumps `stream_version`), so an
exclusive row lock makes a concurrent append wait until apply commits or rolls back, and because
`FOR UPDATE` also conflicts with the `FOR SHARE` guard taken by
`lockStreamHistoryForReplayTx`, which means an in-flight one-stream repair blocks compaction of
its stream, exactly as ADR-7 requires. The lock statement's returned rows are not interpreted
by apply beyond being discarded: the three stream checks (a name that returns no row is
`CompactionStreamMissing`; a row with `deleted_at IS NOT NULL` is `CompactionStreamSoftDeleted`;
a `stream_version` that differs from the manifest's head witness is `CompactionStreamHeadDrift`)
are performed by the preview plan's `validateCompactionTx`, which apply calls next. Its plain
`resolveStreamsStmt` SELECT runs inside the same transaction after the `FOR UPDATE` lock, so it
observes exactly the locked rows; a concurrent append cannot change `stream_version` between
the lock and the check because it is waiting on that row. This is why no second entry point is
needed: locking and validating are two statements against one stable snapshot.

The ledger statements:

The lookup by digest and the surviving-event count already exist from the preview plan
(`ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)` and
`survivingSelectedEventsStmt :: Statement (Vector UUID) Int64` in
`Kiroku.Store.Compaction.SQL`); reuse them through `validateCompactionTx` rather than adding a
second pair. This plan adds only the ledger listing and insert statements, whose row shape must
decode into the same `CompactionRecord` the preview plan's digest lookup produces:

```haskell
compactionLedgerStmt :: Statement Int32 (Vector CompactionRecord)
-- SELECT compaction_id, manifest_digest, report_digest, store_id, operation,
--        dead_letter_policy, causation_policy, selected_events, home_memberships,
--        global_memberships, link_memberships, dead_letters_removed, causation_dependents,
--        lowest_global_position, highest_global_position, affected_streams,
--        applied_at, applied_by
-- FROM event_compactions ORDER BY applied_at DESC, compaction_id LIMIT $1

insertCompactionRecordStmt :: Statement CompactionRecordInsert (UUID, UTCTime, Text)
-- INSERT INTO event_compactions (manifest_digest, report_digest, store_id, operation,
--   dead_letter_policy, causation_policy, selected_events, home_memberships,
--   global_memberships, link_memberships, dead_letters_removed, causation_dependents,
--   lowest_global_position, highest_global_position, affected_streams)
-- VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::jsonb)
-- RETURNING compaction_id, applied_at, applied_by
```

Both ledger-reading statements share one row decoder (`compactionRecordRow`, defined once in
the SQL module by the preview plan for `ledgerRecordByDigestStmt` and reused here) that rebuilds
the `CompactionReport` from the stored columns and checks that the stored `report_digest` equals
`compactionReportDigest` of the rebuilt report; if it does not, the row is corrupt and the
decoder fails through `error` with a message naming the `compaction_id`, the same way
`makeLease` in `HistoryRetention/SQL.hs` treats an impossible state. `affected_streams` is
decoded with `D.jsonb` into `Value` and parsed into `Vector StreamHeadWitness`.

The deletion statements:

```haskell
deleteCompactionJunctionsStmt :: Statement (Vector UUID) (Vector (Int64, Int64))
-- DELETE FROM stream_events WHERE event_id = ANY($1::uuid[])
-- RETURNING stream_id, original_stream_id

deleteCompactionDeadLettersStmt :: Statement (Vector UUID) Int64
-- WITH removed AS (DELETE FROM dead_letters WHERE event_id = ANY($1::uuid[]) RETURNING 1)
-- SELECT count(*) FROM removed

deleteCompactionEventsStmt :: Statement (Vector UUID) Int64
-- WITH removed AS (DELETE FROM events WHERE event_id = ANY($1::uuid[]) RETURNING 1)
-- SELECT count(*) FROM removed
```

Note the data-modifying CTE pattern is safe here because each statement is self-contained; the
existing Haddock on `deleteOrphanedEventsStmt` explains why one must not chain a `NOT EXISTS`
on `stream_events` inside the same statement as the junction delete — this plan never does that,
it runs the deletes as separate statements in sequence.

Then implement the transaction in `kiroku-store/src/Kiroku/Store/Compaction/Internal.hs`:

```haskell
applyCompactionTx ::
    CompactionManifest ->
    Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
applyCompactionTx manifest = do
    Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
    HistoryRetention.lockHistoryRetentionCoordinatorTx
    conflict <- HistoryRetention.activeHistoryRetentionConflictTx
    case conflict of
        Just active -> pure (Left (CompactionHistoryRetentionActive active :| []))
        Nothing -> do
            _ <- Tx.statement (manifestStreamNames manifest) SQL.lockCompactionStreamsStmt
            validateCompactionTx manifest >>= \case
                ValidationRefused refusals -> pure (Left refusals)
                ValidationAlreadyApplied record -> pure (Right (CompactionAlreadyApplied record))
                ValidationReady validated -> Right . CompactionAppliedNow <$> deleteAndRecord validated
```

The early lease probe is deliberate even though `validateCompactionTx` probes again: an active
lease must refuse before apply takes any stream lock, so that a long rebuild never has its
protected streams locked by a destructive operation that is going to refuse anyway. Because
`validateCompactionTx` performs the ledger lookup (`ledgerRecordByDigestStmt` and
`survivingSelectedEventsStmt` from the preview plan) after the coordinator lock is held, a
second apply of the same manifest racing with the first waits on the coordinator, then observes
the committed ledger row and zero survivors, and returns `CompactionAlreadyApplied` with the
stored record. A ledger row with survivors is `CompactionLedgerConflict`. The case where no
ledger row exists and every selected event is absent is not special-cased: validation reports
`CompactionSelectedEventMissing` for each, which is the correct answer for a manifest that never
applied here.

`deleteAndRecord` runs `deleteCompactionJunctionsStmt` and folds the returned
`(stream_id, original_stream_id)` pairs into three counters — `stream_id = 0` is global,
`stream_id = original_stream_id` is home, anything else is a link — and compares each to the
validated expectation (`selectedEvents`, `selectedEvents`, and the acknowledged-link total). On
any mismatch it calls `Tx.condemn` and then raises; the cleanest way to raise a `StoreError`
from inside a `Tx.Transaction` is to return a sentinel and let the interpreter throw, so make the
internal result type `Either CompactionInvariantViolation (Either (NonEmpty CompactionRefusal)
CompactionApplyResult)` inside the module and have the public `applyCompactionTx` convert the
violation with `Tx.condemn >> error`-free handling: use `Tx.sql` to `RAISE` a server error with
SQLSTATE `KRCMP` (`DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = 'KRCMP', MESSAGE = '...'; END
$$;`) so that `mapTransactionUsageError` surfaces it as `UnexpectedServerError "KRCMP" message`
and the transaction is rolled back by PostgreSQL itself. Document in the Haddock that this path
is unreachable under the held locks and immutability triggers and exists only as a defensive
invariant. Then, only if `manifestDeadLetterPolicy manifest == RemoveDeadLetters`, run
`deleteCompactionDeadLettersStmt` and check the count equals the validated dead-letter total.
Then run `deleteCompactionEventsStmt` and check the count equals `selectedEvents`. Then build the
`CompactionReport` exactly as preview builds it (reuse the preview plan's report-building
function so preview and apply produce the identical `reportDigest` for the same store state),
insert the ledger row with `insertCompactionRecordStmt`, and return the `CompactionRecord`.

`compactionLedgerTx :: CompactionLedgerQuery -> Tx.Transaction (Vector CompactionRecord)`
runs `compactionLedgerStmt` with the validated limit and rebuilds records.

Export both from `kiroku-store/src/Kiroku/Store/Compaction.hs` with Haddock that states: the
lock order (coordinator, then affected streams ascending by `stream_id`, then validation, then
deletes); that the operation refuses while any history-retention lease is active; that
`streams.stream_version` is never changed so expected-version appends continue from the
pre-compaction head; that no `NOTIFY` fires; that reapplying a recorded manifest is a no-op
returning `CompactionAlreadyApplied`; that the ledger row is the durable audit record and
process-local events are a convenience; and that when composing with a lease operation in one
transaction the lease work comes first (ADR-7's coordinator-before-stream-row order is
preserved because apply takes the coordinator itself).

Create `kiroku-store/test/Test/CompactionApply.hs`, register it in `other-modules` and in
`kiroku-store/test/Main.hs`, and write the first three examples: the happy path through
`runStoreIO store (runTransaction (applyCompactionTx manifest))`; a refusal (an unacknowledged
link) through the same path leaving `countEvents`, the junction count, and the ledger count
unchanged; and the condemned wrapper `runTransaction (applyCompactionTx manifest <* Tx.condemn)`
leaving all three unchanged. The helper `buildManifest :: KirokuStore -> CompactionOperation ->
[ (StreamName, [EventId]) ] -> IO CompactionManifest` should read `storeIdentity`, `getStream`
for heads, and `lookupEventReferences` for positions and links, then call
`mkCompactionManifest`; keep it in this test module so every later example uses it.

### Milestone 2 — The effect surface and events

At the end of this milestone `applyCompaction` and `compactionLedger` work through the `Store`
effect, emit events, and are mock-dispatchable; `cabal build all` passes including `kiroku-otel`
and `kiroku-metrics`.

In `kiroku-store/src/Kiroku/Store/Effect.hs` add two constructors to `data Store` next to
`PreviewCompaction`:

```haskell
    ApplyCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
    GetCompactionLedger :: CompactionLedgerQuery -> Store m (Vector CompactionRecord)
```

and interpret them in `runStorePool`:

```haskell
    ApplyCompaction manifest -> do
        result <- runTxOnPool (store ^. #pool) TxSessions.transaction (Compaction.applyCompactionTx manifest)
        let digest = manifestDigest manifest
        liftIO $ case result of
            Right (CompactionAppliedNow record) ->
                emitOrDrop (store ^. #eventHandler)
                    (KirokuEventCompactionApplied (record ^. #compactionId) digest
                        (record ^. #report . #selectedEvents)
                        (membershipsOf (record ^. #report)))
            Right (CompactionAlreadyApplied record) ->
                emitOrDrop (store ^. #eventHandler)
                    (KirokuEventCompactionAlreadyApplied (record ^. #compactionId) digest)
            Left refusals ->
                emitOrDrop (store ^. #eventHandler)
                    (KirokuEventCompactionRefused digest (NonEmpty.head refusals) (NonEmpty.length refusals))
        pure result
    GetCompactionLedger query ->
        runTxOnPool (store ^. #pool) TxSessions.transaction (Compaction.compactionLedgerTx query)
```

where `membershipsOf report = homeMemberships + globalMemberships + linkMemberships`. Events are
emitted only after the transaction has finished, matching the lease interpreter arms; a
transaction error propagates as `StoreError` and emits nothing.

In `kiroku-store/src/Kiroku/Store/Observability.hs` add, with Haddock, after
`KirokuEventCompactionRefused`:

```haskell
    | -- | An apply transaction committed: ledger id, manifest digest, selected events, memberships removed.
      KirokuEventCompactionApplied !CompactionId !CompactionDigest !Int64 !Int64
    | -- | An apply found the manifest already recorded and changed nothing.
      KirokuEventCompactionAlreadyApplied !CompactionId !CompactionDigest
```

Add no-op arms `KirokuEventCompactionApplied{} -> pure ()` and
`KirokuEventCompactionAlreadyApplied{} -> pure ()` in `kiroku-otel/src/Kiroku/Otel/Subscription.hs`
(`onEvent`, beside `KirokuEventHardDeleteHistoryRetentionConflict{} -> pure ()`) and in
`kiroku-metrics/src/Kiroku/Metrics/Collector.hs` (`applyEvent`, with a comment that compaction
evidence lives in the ledger and is deliberately not a fixed metric). Re-export the two
constructors wherever `Kiroku.Store` re-exports `KirokuEvent (..)` (it already re-exports the
whole type, so nothing changes there).

Add the public wrappers to `Kiroku.Store.Compaction`:

```haskell
applyCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
applyCompaction manifest = send (ApplyCompaction manifest)

compactionLedger :: (Store :> es) => CompactionLedgerQuery -> Eff es (Vector CompactionRecord)
compactionLedger query = send (GetCompactionLedger query)
```

Create `kiroku-store/test/Test/CompactionApplyMock.hs` in the style of
`Test.HistoryRetentionMock`: one example that calls `applyCompaction` and `compactionLedger`
through an `interpret_` mock that records `["apply", "ledger"]`, asserts the manifest and query
it received, and returns a sample `CompactionAppliedNow` record and a singleton ledger vector.
Add event-handler examples to `Test.CompactionApply` using `withTestStoreSettings` to install an
`eventHandler` that appends to an `IORef [KirokuEvent]`: a successful apply emits exactly one
`KirokuEventCompactionApplied` with the record's id and the manifest digest; the same manifest
again emits exactly one `KirokuEventCompactionAlreadyApplied`; a refused apply emits exactly one
`KirokuEventCompactionRefused` whose count equals the refusal list length.

### Milestone 3 — Behavioural, concurrency, and property coverage

At the end of this milestone every acceptance case in the improvement request's item 5 has an
example in `Test.CompactionApply`, plus the post-compaction read, subscription, and append
behaviours, plus one hedgehog property.

Write these examples; each starts with `withTestStore $ \store ->` (or `around withTestStore`)
and ends with assertions that name exact counts.

*Ordinary derived memberships.* Append six events to `order-1`; select versions 2 and 4.
Capture `readAllForward (GlobalPosition 0) 1000` before; apply; capture after. Assert the
after-vector equals the before-vector with the two selected `RecordedEvent`s filtered out
(`RecordedEvent` derives `Eq`, so this is a byte-equivalence check on payload, metadata, ids,
versions, positions, causation, correlation, and `createdAt`). Assert `countEvents` dropped by
two, a raw `SELECT count(*) FROM stream_events WHERE event_id = ANY(...)` returns zero, and
`getStream "order-1"` still reports version 6. Assert the report has `selectedEvents = 2`,
`homeMemberships = 2`, `globalMemberships = 2`, `linkMemberships = 0`, `affectedStreams =
[StreamHeadWitness "order-1" 6]`.

*Retained linked events untouched.* Link `order-1` versions 1 and 3 into `audit-1`; select
version 2 only; apply; assert `readStreamForward "audit-1"` still returns both links with their
original versions and origins.

*Unexpected link refuses.* Link version 2 into `audit-1`; select version 2 with no acknowledged
links; apply returns `Left` containing `CompactionUnexpectedLink eventId (LinkWitness "audit-1"
v)`; every count is unchanged and the ledger is empty.

*Acknowledged link removed.* Same setup but acknowledge `LinkWitness "audit-1" v`; apply
succeeds with `linkMemberships = 1`; `audit-1`'s other links and its `stream_version` are
unchanged; `affectedStreams` lists both streams.

*Link of a link.* Link into `audit-1`, link that junction's event again into `audit-2`;
acknowledging both succeeds, acknowledging one refuses with the other as `CompactionUnexpectedLink`.

*Several affected streams.* Three origin streams in one manifest; assert each stream's reads
and heads; assert the ledger row's `affected_streams` JSON is sorted by name.

*Head drift.* Build the manifest; append one more event to the origin stream; apply returns
`Left (CompactionStreamHeadDrift { stream, expected = 6, actual = 7 } :| [])` and nothing
changes.

*Append blocked during apply, then succeeds.* Use the race pattern: in one `Async`, run
`runTransaction (applyCompactionTx manifest <* Tx.statement () holdCompactionStmt)` where
`holdCompactionStmt` is `SELECT pg_sleep(0.4) IS NULL /* compaction-apply-race */`; poll
`pg_stat_activity` for that exact query text; then start `appendToStream origin (ExactVersion
6) [...]` in a second `Async`; after 50 ms `Async.poll` must be `Nothing`; after both finish the
apply is `Right (CompactionAppliedNow _)` and the append is `Right` with `streamVersion = 7`.
Use a marker distinct from the ones in `Test.HistoryRetention` (`history-retention-coordinator-race`)
and `Test.StreamHistoryGuard` (no marker).

*Guard blocks apply.* With `assertBlockedByGuard`-style code, hold
`lockStreamHistoryForReplayTx origin` in one transaction and prove `applyCompaction` blocks until
it ends, then succeeds.

*Active lease refuses.* `acquireHistoryRetentionLease` with a 60-second duration; apply returns
`Left (CompactionHistoryRetentionActive conflict :| [])` with `activeLeaseCount = 1`; counts
unchanged; release the lease; apply succeeds.

*Manifest for another store.* Open a second `withTestStore` (a different database, hence a
different identity); build the manifest against store A and apply it to store B; assert
`CompactionStoreIdentityMismatch` and no change in B.

*Missing event.* Build a manifest, hard-delete... no — hard delete would remove the stream;
instead build the manifest with a fabricated `EventId` (fresh `UUID.V7`) at a plausible position;
apply returns `CompactionSelectedEventMissing` for it.

*Repeated apply is a no-op.* Apply once (`CompactionAppliedNow r1`); apply again
(`CompactionAlreadyApplied r2`); assert `r2 ^. #compactionId == r1 ^. #compactionId`,
`r2 ^. #report == r1 ^. #report` (hence identical `reportDigest`), ledger has exactly one row,
`countEvents` unchanged between the two applies.

*Ledger conflict.* Insert a ledger row by raw SQL for the manifest's digest while the events
still exist (`INSERT INTO kiroku.event_compactions (...) VALUES (...)` with all constraints
satisfied — no GUC needed for INSERT); apply returns `CompactionLedgerConflict { survivingEvents
= n }` and deletes nothing.

*Failure before commit.* Already covered in M1; keep it and additionally assert the ledger row
count is zero afterwards and a subsequent real apply succeeds.

*Dead letters.* Append, `insertDeadLetterForEvent` for the selected event; `RefuseDeadLetters`
manifest refuses with `CompactionDeadLettersPresent eventId 1` and
`countDeadLettersForEvents` is unchanged; `RemoveDeadLetters` manifest succeeds with
`deadLettersRemoved = 1`, the dead-letter count is zero, and the payload delete succeeded (the
foreign key held because dead letters were removed first).

*Causation.* Append event A, then event B with `causationId = Just a`; select A.
`RefuseCausationDependents` refuses with `CompactionCausationDependentsPresent a 1`;
`AllowDanglingCausation` succeeds with `causationDependents = 1`, B is retained with its
`causationId` still `Just a`, and `findCausationDescendants (EventId a)` still returns B.

*Reads skip gaps.* After compacting versions 2 and 4 of six: `readStreamForward` from 0 returns
versions `[1,3,5,6]`; `readStreamBackward` from the head returns `[6,5,3,1]`; `readAllForward`
positions are the original positions of the retained events; `readCategory "order"` likewise;
`readStreamForward origin (StreamVersion 2) 10` (cursor exactly at a removed version) returns
`[3,5,6]`; `visibleGlobalHeadPosition` equals the highest retained position when the last
event was selected and is unchanged otherwise.

*Subscription continues.* Start a `$all` subscription with a checkpoint saved at position 1
(use the existing subscription helpers in `Test.Helpers` and the worker API used by
`Test.SubscriptionCheckpointWorker`); compact positions 2 and 4; append one more event; assert
the handler received exactly the retained events in order and then the new one, and the saved
checkpoint advanced past the gap.

*Expected-version append.* After compaction, `appendToStream origin (ExactVersion 6) [e]`
returns `streamVersion = 7`; `appendToStream origin (ExactVersion 4) [e]` returns
`WrongExpectedVersion` exactly as before compaction.

*Truncate marker irrelevant.* `setStreamTruncateBefore origin 5`; compacting version 2 (below
the marker) succeeds; the marker is unchanged in `getStream`.

*Property.* In `Test.CompactionApply` (or `Test.Properties` if its generators fit), a
hedgehog property: generate 2–4 streams with 3–8 events each, a random set of links between
them, and a random non-empty subset of originated events as the selection with every actual link
of a selected event acknowledged; apply; assert `readAllForward` equals the pre-state minus the
selection, each stream's forward read equals its pre-state minus selected home rows minus
acknowledged link rows, every `streams.stream_version` is unchanged, and `countEvents`
decreased by exactly the selection size. Use `withTestStoreReturn` from `Test.Properties` for
an `IO a` fixture.

### Milestone 4 — Gates, ADR, changelogs

At the end of this milestone the structural gates prove the hot path is untouched, the
compaction-contract ADR is recorded and validated, changelogs carry unreleased entries, and the
full suite passes on both PostgreSQL majors.

In `kiroku-store/test/Test/PerformanceStructure.hs`: extend the `ordinarySql` example so each
statement is also asserted free of `event_compactions`, `store_identity`, and `FOR UPDATE` text
beyond what it had (the simplest form: `forM_ ordinarySql $ \sql -> do ... shouldNotSatisfy
isInfixOf "event_compactions"; ... "store_identity"`); keep `retentionTriggerShapeStmt`'s
expected `(6, 0)`; add `compactionTriggerShapeStmt` selecting from `pg_trigger` for
`relname IN ('store_identity', 'event_compactions')` and asserting `(count, insertOrUpdateFiring)`
equals `(6, 2)` — per table one UPDATE trigger (`prevent_mutation`), one DELETE trigger
(`protect_deletion`), one TRUNCATE trigger (`protect_truncation`); the two UPDATE triggers are
the only ones with `tgtype & 16`, and none has `tgtype & 4` (INSERT). Spell out in the example
title that INSERT is unguarded by design so the ledger insert costs nothing extra. Seed the
`queryPlanFixture` with a few hundred ledger rows (raw `INSERT` with valid digests, then
`ANALYZE event_compactions`) and add `expectIndex` examples: `ledgerRecordByDigestStmt`
uses the unique index on `manifest_digest`, and `compactionLedgerStmt` uses
`ix_event_compactions_applied_at` with no `Sort` node. Add a checkout-count example (pattern
from `noOpAppendSpec`): one `applyCompaction` performs exactly one pool checkout.

In `kiroku-store/test/Test/NotifyGuard.hs` extend the existing example so that after the
current append/soft-delete/undelete/append sequence it also applies a manifest that compacts
one event, and the asserted payload list is unchanged (still exactly the two append payloads;
no `$all,` payload).

Run the gates and record the workload ratio in Progress:

```bash
just perf-check
```

If the controlled workload ratio fails, repeat per ADR-5's protocol (unchanged code, idle host,
three repeats) and record each run here; ExecPlan 73 recorded boundary-noisy samples of
`0.88x–0.92x` with no append-path change.

Create the ADR. Allocate the handle and do not guess it:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
```

Create `docs/adr/000N-physical-event-compaction-is-manifest-driven-witness-validated-and-ledgered.md`
(N is the returned number) with the frontmatter shape of `docs/adr/0007-...` (`type`, `title`,
`description`, `generated.by`/`generated.at`, `docId: ADR-N`, `status: Accepted`, `date`,
`timestamp`, `originatingPlan: docs/plans/78-...`). Its Decision section states: physical
compaction removes only events named in a digest-sealed manifest whose witnesses (event id,
origin, original version, global position, acknowledged links, stream heads, store identity)
are re-validated under the ADR-7 coordinator and ascending-`stream_id` `FOR UPDATE` locks; every
reference class is explicitly accounted for or refuses (links by per-selection acknowledgement,
dead letters and causation dependents by manifest-level policies defaulting to refuse); retained
rows are never renumbered or rewritten and `streams.stream_version` is never changed; every
apply is recorded in the append-only `kiroku.event_compactions` ledger keyed by manifest digest
and reapply is a ledgered no-op; ordinary append and read paths gain nothing. Alternatives
Considered must list, each with the reason it was rejected: whole-stream rewrite or
copy-transform into a new stream (renumbers, breaks checkpoints, links, and causation);
EventStoreDB-style declarative scavenge metadata such as maximum count or age (a policy Kiroku
would be deciding; a possible future capability, not this one); tombstone-then-scavenge in two
operations (two durable states to reason about, no gain over one validated transaction);
inferring idempotence from row absence (cannot distinguish "applied" from "never existed");
refusing every linked event (forces consumers to hard-delete link streams first); Kiroku
enforcing a subscription-checkpoint guard (consumer policy per ADR-4, composable by the consumer
in one transaction). Consequences list the ledger's growth (one row per manifest), the `FOR
UPDATE` wait that appends experience during an apply, and the manifest size bound. Then update
`docs/adr/index.md` (add the bullet in the existing format) and append a log entry:

```bash
okf log add docs/adr --profile docs/adr/profile.dhall \
  --kind Addition \
  --message "ADR-N records the manifest-driven, witness-validated, ledgered physical compaction contract and its deliberate exclusions."
just adr-validate
```

If `okf log add` has a different flag shape in the installed version, run `okf log add --help`
and follow it; the requirement is an entry in `docs/adr/log.md` under today's date that
`--log-enforce` accepts.

Add unreleased CHANGELOG sections (do not change any `version:` field; the release plan
`docs/plans/80-...` owns versions and dates): in `kiroku-store/CHANGELOG.md` under a
`## Unreleased` heading, a `### New Features` entry describing `applyCompaction`,
`applyCompactionTx`, `compactionLedger`, `compactionLedgerTx`, the two new `KirokuEvent`
constructors, and the lock/lease/idempotence contract, plus a `### Breaking Changes` note that
exhaustive `KirokuEvent` matches must handle the new constructors; in `kiroku-otel/CHANGELOG.md`
and `kiroku-metrics/CHANGELOG.md`, `### Other Changes` entries stating the no-op arms.

Finally run the whole repository on both PostgreSQL majors and fill in Outcomes & Retrospective.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless stated.

Confirm the dependencies are in place before starting:

```bash
grep -n "previewCompactionTx\|validateCompaction" kiroku-store/src/Kiroku/Store/Compaction/Internal.hs
grep -n "event_compactions" kiroku-store-migrations/migrations/0012.sql | head -3
grep -n "eventMembershipsStmt" kiroku-store/src/Kiroku/Store/SQL.hs | head -2
```

Each `grep` must print at least one line; if any prints nothing, stop and implement the
missing sibling plan first.

Milestone 1:

```bash
# edit kiroku-store/src/Kiroku/Store/Compaction/SQL.hs, Internal.hs, Compaction.hs
cabal build kiroku-store
# create kiroku-store/test/Test/CompactionApply.hs; add to other-modules and test/Main.hs
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "compaction apply"'
```

Expected tail of the test output after M1:

```text
compaction apply
  removes exactly the accounted rows and records one ledger row [✔]
  refuses an unacknowledged link and changes nothing [✔]
  leaves rows and ledger unchanged when the surrounding transaction is condemned [✔]

Finished in 1.9 seconds
3 examples, 0 failures
```

Commit:

```text
feat(compaction): apply a manifest transactionally under ADR-7 locks with a ledger record

Add applyCompactionTx and compactionLedgerTx. Apply takes the coordinator,
refuses on active leases or a ledger conflict, locks affected streams by
ascending stream_id FOR UPDATE, re-validates every witness, deletes exactly
the accounted junction, dead-letter, and payload rows, and records the
manifest in kiroku.event_compactions.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```

Milestone 2:

```bash
# edit Effect.hs, Observability.hs, Compaction.hs; kiroku-otel and kiroku-metrics arms
cabal build all
# create Test/CompactionApplyMock.hs; add event-handler examples
cabal test kiroku-store:kiroku-store-test --test-options='--match "compaction apply"'
cabal test kiroku-store:kiroku-store-test --test-options='--match "compaction apply mock"'
```

`cabal build all` must finish without `-Wincomplete-patterns` errors in `kiroku-otel` or
`kiroku-metrics`; if it reports one, the missing arm is in the file and function it names.

Milestone 3:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "compaction apply"'
cabal test kiroku-store:kiroku-store-test --test-options='--match "compactingARandomSubset"'
```

Every example listed in Milestone 3 appears with `[✔]`. The race examples take roughly half a
second each because of the `pg_sleep(0.4)` barrier; a `[✘]` reading "append completed while
apply held the stream lock" means the lock statement is missing `FOR UPDATE` or is running after
the deletes.

Milestone 4:

```bash
just perf-structure
just perf-workload-gate
okf id next docs/adr --profile docs/adr/profile.dhall ADR
# write the ADR, update docs/adr/index.md, add the log entry
just adr-validate
cabal test all
just test-matrix
```

Expected `just perf-structure` tail:

```text
performance structure
  ...
  installs no retention trigger for INSERT or UPDATE [✔]
  guards the compaction tables on UPDATE, DELETE, and TRUNCATE only [✔]
  serves the ledger digest lookup from its unique index [✔]
  serves the ledger inventory from ix_event_compactions_applied_at without a sort [✔]
  applies a manifest with exactly one pool checkout [✔]
```

`just perf-workload-gate` prints two `bcompareWithin` lines; both ratios must be at most
`0.90x` as before this plan (record the exact numbers in Progress). `just adr-validate` prints
no errors. `just test-matrix` prints `== PostgreSQL 17.x ==` and `== PostgreSQL 18.x ==` with
all suites passing under each.

Final commit:

```text
feat(compaction): expose apply and ledger through the Store effect with gates and ADR

Add ApplyCompaction and GetCompactionLedger, compaction events with no-op
arms in kiroku-otel and kiroku-metrics, the acceptance, race, failure-
injection, and property suites, structural gate coverage for the ledger
and identity tables, and ADR-N recording the compaction contract.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

The behaviour to observe, with a fresh store and the test helpers:

1. Append six events to `order-1`, build a manifest selecting versions 2 and 4 (from
   `lookupEventReferences` and `getStream`), and call `applyCompaction`. The result is
   `Right (CompactionAppliedNow record)` with `record ^. #report . #selectedEvents == 2`,
   `homeMemberships == 2`, `globalMemberships == 2`, `linkMemberships == 0`,
   `deadLettersRemoved == 0`, `causationDependents == 0`, `affectedStreams == [StreamHeadWitness
   "order-1" 6]`. `readStreamForward "order-1" 0 10` returns versions `[1,3,5,6]` with every
   field of those four events equal to what it was before. `getStream "order-1"` reports version
   6. `countEvents` is four. `compactionLedger (CompactionLedgerQuery limit10)` returns exactly
   that record.
2. Calling `applyCompaction` again with the same manifest returns `Right (CompactionAlreadyApplied
   record')` where `record' == record`, and nothing changed.
3. `appendToStream "order-1" (ExactVersion 6) [e]` returns `streamVersion == 7`; the new event
   is visible at version 7 and at a new global position.
4. With a history-retention lease active, `applyCompaction` returns
   `Left (CompactionHistoryRetentionActive _ :| [])`, the store's event handler receives one
   `KirokuEventCompactionRefused`, and no row changed.
5. With a manifest whose selected event has a link the manifest did not acknowledge, the result
   is `Left` containing `CompactionUnexpectedLink`, and no row changed.
6. Inside `runTransaction (applyCompactionTx manifest <* Tx.condemn)`, the store is unchanged
   afterwards and the ledger is empty.
7. `just perf-check` passes with the trigger shape `(6, 0)` unchanged and the workload ratio
   within the existing bound; `Test.NotifyGuard` still sees exactly the two append payloads.
8. `just adr-validate` passes with the new ADR present in `docs/adr/index.md` and `log.md`.

Exact commands and the expected pass counts are in Concrete Steps. The migrations suite is not
changed by this plan (the schema landed in `docs/plans/74-...`), but it must still pass:
`cabal test kiroku-store-migrations:kiroku-store-migrations-test`.


## Idempotence and Recovery

Every code step is re-runnable; the test databases are created from a template per example and
dropped afterwards, so a failed run leaves nothing behind.

Apply itself is idempotent by construction: the ledger row keyed by `manifest_digest` makes a
second apply a no-op, and a crashed or condemned apply commits nothing because the ledger insert
is the last statement of the same transaction as the deletes. A `40001`/`40P01` retry by
`TxSessions.transaction` re-runs the whole body from the coordinator lock; this is safe because
no statement before the deletes has side effects and the deletes are preceded by a fresh
validation. If an operator sees a refusal, the correct recovery is to fix the manifest (for
example acknowledge the link or choose `RemoveDeadLetters`) and preview again; never issue a raw
`DELETE` to "make the manifest fit" — the protection triggers will refuse without the GUC and
the KR001 trigger will refuse under a lease, and doing so would defeat the witness model.

If the ADR handle allocation or `okf log add` fails, nothing else in the plan depends on it;
rerun the `okf` commands after fixing the descriptor. If `just perf-workload-gate` fails on a
noisy host, follow ADR-5's repeat protocol and record each sample in Progress before concluding
anything; this plan adds no statement to the append path, so a persistent failure indicates a
host problem, not a regression.

Do not edit `kiroku-store-migrations/migrations/0012.sql`; it was released-shape once
`docs/plans/74-...` completed and `pg-migrate` verifies its checksum. If the ledger needs a
column this plan did not anticipate, add a new forward migration through the scaffolder and
update the MasterPlan's Integration Points and Decision Log first.


## Interfaces and Dependencies

Libraries: `hasql` (`Statement`, encoders/decoders), `hasql-transaction` (`Tx.Transaction`,
`Tx.statement`, `Tx.sql`, `Tx.condemn`), `hasql-transaction` sessions
(`TxSessions.transaction`, `ReadCommitted`, `Write`), `contravariant-extras` (`contrazipN`),
`effectful-core`, `vector`, `containers`, `aeson` (for `affected_streams` JSON), `uuid`,
`time`, `hedgehog` and `hspec-hedgehog` (tests), `async` (race tests). No new package
dependency is introduced by this plan; the digest dependency was added by `docs/plans/76-...`.

Signatures that must exist at the end of Milestone 1, in `Kiroku.Store.Compaction.SQL`
(other-module):

```haskell
lockCompactionStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Maybe UTCTime))
compactionLedgerStmt :: Statement Int32 (Vector CompactionRecord)
-- reused from the preview plan (docs/plans/77-...), not redefined here:
-- ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)
-- survivingSelectedEventsStmt :: Statement (Vector UUID) Int64
insertCompactionRecordStmt :: Statement CompactionRecordInsert (UUID, UTCTime, Text)
deleteCompactionJunctionsStmt :: Statement (Vector UUID) (Vector (Int64, Int64))
deleteCompactionDeadLettersStmt :: Statement (Vector UUID) Int64
deleteCompactionEventsStmt :: Statement (Vector UUID) Int64
```

and in `Kiroku.Store.Compaction.Internal` (other-module) re-exported by the public
`Kiroku.Store.Compaction`:

```haskell
applyCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
compactionLedgerTx :: CompactionLedgerQuery -> Tx.Transaction (Vector CompactionRecord)
```

At the end of Milestone 2, in `Kiroku.Store.Effect`:

```haskell
ApplyCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
GetCompactionLedger :: CompactionLedgerQuery -> Store m (Vector CompactionRecord)
```

in `Kiroku.Store.Compaction`:

```haskell
applyCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
compactionLedger :: (Store :> es) => CompactionLedgerQuery -> Eff es (Vector CompactionRecord)
```

and in `Kiroku.Store.Observability`:

```haskell
KirokuEventCompactionApplied :: CompactionId -> CompactionDigest -> Int64 -> Int64 -> KirokuEvent
KirokuEventCompactionAlreadyApplied :: CompactionId -> CompactionDigest -> KirokuEvent
```

Consumed from sibling plans (must already exist): `Kiroku.Store.Types.StoreIdentity`,
`Kiroku.Store.Transaction.storeIdentityTx` (`docs/plans/74-...`);
`Kiroku.Store.SQL.eventMembershipsStmt`, `deadLetterCountsStmt`,
`causationDependentCountsStmt`, `Kiroku.Store.Read.lookupEventReferences`
(`docs/plans/75-...`); everything in `Kiroku.Store.Compaction.Types` (`docs/plans/76-...`);
`Kiroku.Store.Compaction.Internal.validateCompactionTx`, the report-building function, and the
`PreviewCompaction` interpreter arm with `KirokuEventCompactionPreviewed` /
`KirokuEventCompactionRefused` (`docs/plans/77-...`). Consumed by later plans:
`docs/plans/79-...` wraps `applyCompaction` and `compactionLedger` in `kiroku-cli` and
documents them; `docs/plans/80-...` releases them and compiles `applyCompactionTx` from a clean
external consumer.
