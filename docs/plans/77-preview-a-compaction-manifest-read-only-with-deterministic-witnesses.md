---
id: 77
slug: preview-a-compaction-manifest-read-only-with-deterministic-witnesses
title: "Preview a compaction manifest read-only with deterministic witnesses"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Preview a compaction manifest read-only with deterministic witnesses

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku is an append-only PostgreSQL event store written in Haskell. The MasterPlan
`docs/masterplans/11-manifest-driven-selective-event-compaction.md` adds a supported way to
physically delete a caller-selected subset of events, described by an immutable, digest-sealed
*compaction manifest*. Before anything is deleted, an operator needs a dry run: "if I applied
this manifest to this store right now, what exactly would happen, and would it be refused?"

This plan delivers that dry run. After it lands, a consumer holding a `CompactionManifest` (from
`Kiroku.Store.Compaction.Types`, delivered by
`docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`)
calls `previewCompaction manifest` through the `Store` effect and receives either a non-empty
list of typed refusals — every discrepancy between the manifest's witnesses and the live store
that could be found, not just the first — or a deterministic `CompactionReport` with exact counts
of what would be removed, the head version of every affected stream, and a report digest an
operator can sign off on. Preview takes no locks, sets no session variable, writes no row, and
uses exactly one pool checkout. The same validation function is reused unchanged by the apply
plan `docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`,
executed there under the ADR-7 locks; this plan is therefore also where the "validate every
witness before the first delete" property is implemented.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Create `Kiroku.Store.Compaction.SQL` with the stream-resolution, witness, ledger-lookup statements and re-exports of the EP-2 inventory statements.
- [ ] M1: Create `Kiroku.Store.Compaction.Internal` with `validateCompactionTx`, `ValidatedCompaction`, and `previewCompactionTx`.
- [ ] M1: Register both as `other-modules`; `cabal build kiroku-store` passes.
- [ ] M2: Add `PreviewCompaction` to `Store`, the interpreter arm with one checkout, and the two `KirokuEvent` constructors.
- [ ] M2: Add explicit no-op arms in `kiroku-otel` and `kiroku-metrics`; `cabal build all` passes.
- [ ] M2: Create public `Kiroku.Store.Compaction` exporting `previewCompaction` and `previewCompactionTx`, re-exporting Types; switch the `Kiroku.Store` re-export.
- [ ] M3: `Test.CompactionPreview` integration suite covering the happy path and every refusal constructor.
- [ ] M3: `Test.CompactionPreviewMock` dispatch test.
- [ ] M3: Structural assertions (one checkout per preview; preview SQL text contains no `FOR UPDATE`, `DELETE`, `SET LOCAL`) registered under `describe "performance structure"`.
- [ ] M3: Haddock for `Kiroku.Store.Compaction` distinguishing preview from apply; `kiroku-store/CHANGELOG.md` entry.
- [ ] M3: `cabal test all`, `just perf-structure`, `nix fmt`, commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement validation once, as `validateCompactionTx`, returning a
  `ValidatedCompaction` value that carries the resolved stream IDs and computed counts; preview
  wraps it, and the apply plan calls the same function after taking its locks.
  Rationale: The request's central safety property is that the complete manifest is validated
  before the first row is deleted. A single shared function makes preview and apply agree by
  construction; any divergence would be a bug in exactly one place.
  Date: 2026-08-22

- Decision: Preview runs in a `ReadCommitted` transaction opened in `Read` mode
  (`TxSessions.Read`), with no `SET LOCAL` and no row locks.
  Rationale: A read-only transaction is the strongest statement that preview cannot mutate; all
  of preview's statements are `SELECT`s, so `Read` mode costs nothing. Preview observes a single
  statement-level snapshot per statement (ReadCommitted), which is adequate for a dry run; the
  locked apply transaction is the authoritative check.
  Date: 2026-08-22

- Decision: Preview accumulates every refusal it can determine rather than stopping at the first,
  with two short-circuits: a store-identity mismatch (every other witness is meaningless against
  the wrong store) and a ledger conflict (the store is in an inconsistent state relative to the
  ledger and per-event findings would only add noise).
  Rationale: An operator reviewing a large manifest should see all missing events, all drifted
  heads, and all unexpected links in one pass instead of iterating one refusal at a time.
  Date: 2026-08-22

- Decision: When the ledger already records the manifest digest and no selected event survives,
  preview returns `Right` the stored report (whose `reportDigest` equals the report preview would
  have computed at apply time); apply returns `CompactionAlreadyApplied` for the same state.
  Rationale: The request defines reapplication of a completed manifest as an observable no-op
  with the same logical report. Returning the stored report from preview gives the operator the
  same evidence before and after, and keeps preview's type simple.
  Date: 2026-08-22

- Decision: A selection whose home row is below its stream's `truncate_before` marker is
  eligible; a selection in a soft-deleted stream is refused with `CompactionStreamSoftDeleted`.
  Rationale: Logically truncated rows physically exist and are exactly what a consumer may want
  to reclaim; a soft-deleted stream is invisible to the consumer's reads, so its events cannot
  have been reviewed as live history (this is the MasterPlan's "unsupported topology" reading).
  Date: 2026-08-22

- Decision: The active-lease check is reported by preview as a refusal
  (`CompactionHistoryRetentionActive`) even though preview itself would be allowed to run.
  Rationale: The purpose of preview is to predict apply; an operator must learn before
  attempting apply that a lease would block it and when the earliest lease expires.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### Repository and packages

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; all paths are
relative to it. `cabal.project` builds eight packages with GHC 9.12.4. This plan edits
`kiroku-store` (the core library), and makes one-line additions to `kiroku-otel` and
`kiroku-metrics` because they pattern-match the store's event type exhaustively. Every package
compiles with `-Wall -Werror=incomplete-patterns`, `GHC2024`, and the default extensions
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`. Records are
read with `generic-lens` labels (`value ^. #field`) or explicit pattern matching; bare selector
functions are ambiguous under `DuplicateRecordFields`.

### The schema preview reads

All Kiroku objects live in the `kiroku` PostgreSQL schema
(`docs/adr/0003-dedicated-kiroku-schema.md`). Statements in `kiroku-store` use unqualified table
names because the connection's `search_path` is set to the configured schema. The tables that
matter here, as created by `kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql` and
later migrations:

`streams (stream_id BIGSERIAL PK, stream_name TEXT UNIQUE, category TEXT generated,
stream_version BIGINT, created_at, deleted_at TIMESTAMPTZ NULL, truncate_before BIGINT DEFAULT 0)`.
The row with `stream_id = 0` and `stream_name = '$all'` is the global log; its `stream_version`
is the global append frontier. A stream's `stream_version` is its *head*: the version the next
append will exceed. `deleted_at IS NOT NULL` means soft-deleted.

`events (event_id UUID PK, event_type, causation_id UUID NULL, correlation_id UUID NULL, data
JSONB, metadata JSONB NULL, created_at)` holds each payload once.

`stream_events (event_id, stream_id, stream_version, original_stream_id,
original_stream_version; PK (event_id, stream_id))` is the junction table. Each event has a
*home* row (`stream_id = original_stream_id`, `stream_version = original_stream_version`), a
*global* row (`stream_id = 0`, `stream_version` = the global position), and zero or more *link*
rows created by `Kiroku.Store.Link.linkToStream` (any other `stream_id`; `original_*` still
name the origin). The partial index `ix_stream_events_all_by_origin (original_stream_id,
stream_version) WHERE stream_id = 0` and the unique index `ux_stream_events_stream_version
(stream_id, stream_version)` exist.

`dead_letters (dead_letter_id, subscription_name, consumer_group_member, global_position,
event_id UUID REFERENCES events(event_id), reason, ...)` with index `ix_dead_letters_event_id`.

`history_retention_leases` and `history_retention_coordinator` (migration `0010`) implement
ADR-7's leases; `Kiroku.Store.HistoryRetention.Internal.activeHistoryRetentionConflictTx ::
Tx.Transaction (Maybe HistoryRetentionConflict)` reports active leases and is reused here.

`store_identity (singleton, store_id UUID, created_at)` and `event_compactions` (the
append-only ledger of applied manifests; columns `compaction_id, manifest_digest BYTEA UNIQUE,
report_digest BYTEA, store_id, operation, dead_letter_policy, causation_policy,
selected_events, home_memberships, global_memberships, link_memberships,
dead_letters_removed, causation_dependents, lowest_global_position,
highest_global_position, affected_streams JSONB, applied_at, applied_by`) are created by
migration `0012` from
`docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md`. That plan
also provides `Kiroku.Store.Transaction.storeIdentityTx :: Tx.Transaction StoreIdentity`. In
this plan the ledger is only read; nothing writes it until the apply plan.

### Existing code this plan builds on

`Kiroku.Store.Effect` (`kiroku-store/src/Kiroku/Store/Effect.hs`) defines the dynamically
dispatched `data Store :: Effect where` GADT and the PostgreSQL interpreter `runStorePool`,
written as `interpret_ $ \case` over every constructor. The helper

```haskell
runTxOnPool ::
    (IOE :> es, Error StoreError :> es) =>
    Pool ->
    (TxSessions.IsolationLevel -> TxSessions.Mode -> Tx.Transaction a -> Session.Session a) ->
    Tx.Transaction a ->
    Eff es a
```

runs a `hasql-transaction` body on one pooled connection (one checkout) and maps pool errors to
`StoreError`; it is currently called as `runTxOnPool pool TxSessions.transaction body` and
hard-codes `ReadCommitted`/`Write`. This plan generalises it slightly (see Milestone 2). Effect
wrappers are thin: `previewCompaction manifest = send (PreviewCompaction manifest)`, following
`Kiroku.Store.HistoryRetention.acquireHistoryRetentionLease`.

`Kiroku.Store.HistoryRetention` / `.Types` / `.Internal` / `.SQL` are the module template:
public module re-exporting its Types module and exposing both effect wrappers and
`Tx.Transaction` combinators; `Internal` holds the transaction logic; `SQL` holds `preparable`
statements with `contrazipN` encoders (from `contravariant-extras`) and `Hasql.Decoders`
rows. `Internal` and `SQL` are `other-modules` in `kiroku-store/kiroku-store.cabal`; the public
modules are `exposed-modules`.

`Kiroku.Store.Observability` defines `data KirokuEvent` (additive, emitted through
`emitOrDrop :: Maybe (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()` using the store's
`eventHandler`) and is matched exhaustively in
`kiroku-otel/src/Kiroku/Otel/Subscription.hs` (function `onEvent`, whose final arms are
`KirokuEventHardDeleteIssued{} -> pure ()` through
`KirokuEventHardDeleteHistoryRetentionConflict{} -> pure ()`) and in
`kiroku-metrics/src/Kiroku/Metrics/Collector.hs` (function `applyEvent`, same tail). Adding a
constructor without adding arms there fails the build.

`Kiroku.Store.SQL` already exports the event-reference inventory statements from
`docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md`:
`eventMembershipsStmt :: Statement (Vector UUID) (Vector (UUID, Int64, Text, Int64, Int64))`
returning `(event_id, stream_id, stream_name, stream_version, original_stream_id)` for every
junction row of the given events; `deadLetterCountsStmt :: Statement (Vector UUID) (Vector
(UUID, Int64))`; and `causationDependentCountsStmt :: Statement (Vector UUID) (Vector (UUID,
Int64))` counting events outside the input set whose `causation_id` is in it. Their types
`EventMembership`, `EventMembershipKind`, and `EventReferenceInventory` live in
`Kiroku.Store.Types`.

Test infrastructure: `kiroku-store/test/Test/Helpers.hs` provides `withTestStore :: (KirokuStore
-> IO ()) -> IO ()` (a fresh migrated database per call from an ephemeral PostgreSQL started once
per suite by `withSharedMigratedPostgres` in `kiroku-store/test/Main.hs`),
`withTestStoreSettings` (to install an `observationHandler`), `makeEvent :: Text -> Value ->
EventData`, `countEvents :: KirokuStore -> IO Int64`, and `insertDeadLetterForEvent ::
KirokuStore -> Text -> RecordedEvent -> IO ()`. Tests run store operations with `runStoreIO
store :: Eff '[Store, Error StoreError, IOE] a -> IO (Either StoreError a)` and raw SQL with
`Hasql.Pool.use (store ^. #pool) (Session.statement params stmt)`. Mock tests follow
`kiroku-store/test/Test/HistoryRetentionMock.hs`: an `interpret_` handler that records calls in
an `IORef [Text]` and ends with `_ -> error "unexpected Store operation ..."`. Structural
assertions live in `kiroku-store/test/Test/PerformanceStructure.hs` and must be registered under
the `describe "performance structure"` block in `Main.hs` to run under `just perf-structure`; the
checkout-counting helper there is:

```haskell
withObservedStore :: IORef Int -> (KirokuStore -> IO ()) -> IO ()
withObservedStore checkouts =
    withTestStoreSettings $ \settings ->
        settings { observationHandler = Just $ \case
                     ConnectionObservation _ InUseConnectionStatus -> modifyIORef' checkouts (+ 1)
                     _ -> pure () }
```

### Terms

A *manifest* is the immutable `CompactionManifest` from `Kiroku.Store.Compaction.Types`; a
*selection* names one event with its *witnesses* (origin stream name, origin version, global
position) and optional *acknowledged links*; *stream-head witnesses* record the expected
`streams.stream_version` of every touched stream; *policies* say whether dead letters and
causation dependents refuse or are tolerated. A *refusal* is a `CompactionRefusal` value; a
*report* is a `CompactionReport`. *Derived memberships* are the home and global junction rows.
A *causation dependent* is an event outside the selection whose `causation_id` names a selected
event. The *ledger* is `kiroku.event_compactions`.

### Relevant architecture decisions

`docs/adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md` (ADR-7):
destructive work coordinates through `history_retention_coordinator`, refuses while any lease is
active, locks affected streams in ascending `stream_id` order, and adds nothing to ordinary
append and read paths. Preview does not take the coordinator or stream locks (it mutates
nothing) but it does report active leases so the operator learns that apply would refuse.
`docs/adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md` (ADR-1): events carry
`original_stream_id`, not names; manifests carry names for human review, and the first thing
preview does is resolve every name to an ID in one statement.
`docs/adr/0005-three-tier-performance-regression-gates.md` (ADR-5): the deterministic structural
tier must keep proving that ordinary statements are untouched; this plan adds preview-specific
structural assertions and changes no ordinary statement. The consuming project is
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`, whose
workflow is "build manifest → preview on a restored clone → preview on production → apply".

### The interface this plan implements

```haskell
-- Kiroku.Store.Effect
PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionReport)

-- Kiroku.Store.Compaction (public)
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionReport)
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionReport)

-- Kiroku.Store.Observability
KirokuEventCompactionPreviewed !CompactionDigest !Int64                 -- selected events
KirokuEventCompactionRefused !CompactionDigest !CompactionRefusal !Int  -- first refusal, total count
```

The refusal vocabulary (from `Kiroku.Store.Compaction.Types`) that preview must be able to
produce: `CompactionStoreIdentityMismatch`, `CompactionHistoryRetentionActive`,
`CompactionStreamMissing`, `CompactionStreamSoftDeleted`, `CompactionStreamHeadDrift`,
`CompactionSelectedEventMissing`, `CompactionWitnessMismatch`, `CompactionUnexpectedLink`,
`CompactionAcknowledgedLinkMissing`, `CompactionDeadLettersPresent`,
`CompactionCausationDependentsPresent`, `CompactionLedgerConflict`.


## Plan of Work

### Milestone 1 — Validation and preview as transaction combinators

Goal: `previewCompactionTx` exists and can be run through the existing
`Kiroku.Store.Transaction.runTransaction` escape hatch; no effect constructor yet.

Work, part one: statements. Create `kiroku-store/src/Kiroku/Store/Compaction/SQL.hs` (with
`{-# LANGUAGE MultilineStrings #-}` like `HistoryRetention/SQL.hs`) exporting:

`resolveStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Bool))` — for each
requested name that exists, `(stream_name, stream_id, stream_version, deleted_at IS NOT NULL)`.
Names absent from the result do not exist.

```sql
SELECT s.stream_name, s.stream_id, s.stream_version, s.deleted_at IS NOT NULL
FROM unnest($1::text[]) AS requested(stream_name)
JOIN streams s USING (stream_name)
```

`selectionWitnessesStmt :: Statement (Vector UUID, Vector Int64, Vector Int64, Vector Int64)
(Vector (UUID, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64))` — the four input arrays
are, position by position, event ID, expected origin `stream_id`, expected origin version, and
expected global position. For every input row it returns the event ID plus, from the live
store, the home row's `stream_version` where `stream_id = expected origin` (NULL if absent),
the `original_stream_id` and `original_stream_version` from any junction row of the event (NULL
if the event has no rows at all), and the global row's `stream_version` (NULL if absent):

```sql
WITH requested AS (
  SELECT event_id, origin_stream_id, origin_version, global_position
  FROM unnest($1::uuid[], $2::bigint[], $3::bigint[], $4::bigint[])
       AS r(event_id, origin_stream_id, origin_version, global_position)
)
SELECT r.event_id,
       home.stream_version,
       anyrow.original_stream_id,
       anyrow.original_stream_version,
       global.stream_version
FROM requested r
LEFT JOIN stream_events home
       ON home.event_id = r.event_id AND home.stream_id = r.origin_stream_id
LEFT JOIN stream_events global
       ON global.event_id = r.event_id AND global.stream_id = 0
LEFT JOIN LATERAL (
  SELECT se.original_stream_id, se.original_stream_version
  FROM stream_events se
  WHERE se.event_id = r.event_id
  LIMIT 1
) anyrow ON true
```

Every join is served by the `stream_events` primary key `(event_id, stream_id)`. The encoder is
`contrazip4` over four `E.foldableArray` parameters; the decoder uses `D.rowVector` with
`D.column (D.nullable D.int8)` for the four nullable columns.

`ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)` — selects every
ledger column `WHERE manifest_digest = $1`. Decode it into `CompactionRecord` by rebuilding the
`CompactionReport` (parse `affected_streams` JSONB with Aeson into `Vector StreamHeadWitness`,
map the policy strings back to the enums, wrap digests with `mkCompactionDigest` and fail with
`error` on a malformed 32-byte column — the table's check constraints make that impossible) and
`sealCompactionReport` is **not** applied: the stored `report_digest` is used verbatim and a
test asserts it equals the recomputed value. Name the row decoder `compactionRecordRow ::
D.Row CompactionRecord` and export it from the SQL module: the apply plan
(`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`)
reuses this statement and the decoder for its ledger listing and insert statements.

`survivingSelectedEventsStmt :: Statement (Vector UUID) Int64` — `SELECT count(*) FROM events
WHERE event_id = ANY($1::uuid[])`, used for the ledger-conflict decision.

Re-export `SQL.eventMembershipsStmt`, `SQL.deadLetterCountsStmt`, and
`SQL.causationDependentCountsStmt` from `Kiroku.Store.SQL` rather than copying them.

Work, part two: validation. Create `kiroku-store/src/Kiroku/Store/Compaction/Internal.hs`
exporting `validateCompactionTx`, `ValidatedCompaction (..)`, `previewCompactionTx`, and
`buildReport`. Define:

```haskell
data ValidatedCompaction = ValidatedCompaction
    { manifest :: !CompactionManifest
    , streamIds :: !(Map StreamName StreamId)          -- every touched stream, resolved
    , selectedEventIds :: !(Vector UUID)               -- canonical order
    , acknowledgedLinkCount :: !Int64
    , deadLetterCount :: !Int64                        -- rows that RemoveDeadLetters would delete
    , causationDependentCount :: !Int64
    , report :: !CompactionReport                      -- sealed
    }

data ValidationOutcome
    = ValidationRefused (NonEmpty CompactionRefusal)
    | ValidationAlreadyApplied CompactionRecord
    | ValidationReady ValidatedCompaction

validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
```

`validateCompactionTx` performs these steps in order, collecting refusals in a `Seq` or reversed
list and returning `ValidationRefused` at the end unless a short-circuit fires:

1. Identity. `actual <- storeIdentityTx`; if `actual /= manifestStoreIdentity manifest`, return
   `ValidationRefused (CompactionStoreIdentityMismatch {expected, actual} :| [])` immediately.

2. Leases. `conflict <- activeHistoryRetentionConflictTx`; on `Just c` add
   `CompactionHistoryRetentionActive c` (do not short-circuit: the operator wants the other
   findings too).

3. Streams. Collect the set of touched names (every `originStream`, every acknowledged link's
   `stream`, every head witness's `stream`; by construction of `mkCompactionManifest` these are
   the same set as the witnesses). Run `resolveStreamsStmt`. For each witness: absent →
   `CompactionStreamMissing name`; present with `deleted` → `CompactionStreamSoftDeleted name`;
   present and `stream_version /= headVersion` → `CompactionStreamHeadDrift {stream, expected,
   actual}`. Build `streamIds` from the present rows. Streams that are missing cannot be used
   in step 4; for selections whose origin stream is missing, emit no per-event refusal (the
   stream refusal already covers them) and exclude them from the witness statement. Do the same
   for acknowledged links targeting a missing stream.

4. Witnesses. For the remaining selections run `selectionWitnessesStmt` with the resolved origin
   IDs. Per row: if all four live columns are NULL → `CompactionSelectedEventMissing eventId`;
   else if the home version is NULL, or differs from `originVersion`, or `original_stream_id`
   differs from the resolved origin ID, or `original_stream_version` differs, or the global
   position is NULL or differs from `globalPosition` → `CompactionWitnessMismatch eventId
   (WitnessMismatch {actualOriginStream, actualOriginVersion, actualGlobalPosition})`, where
   `actualOriginStream` is looked up from `original_stream_id` through an inverse of
   `streamIds` or, if the ID is not among the touched streams, through one extra
   `SQL.lookupStreamNamesStmt` call gathered for all such IDs (at most one call). Keep the set
   of event IDs that passed as `verified`.

5. Memberships. Run `SQL.eventMembershipsStmt` over `verified`. Group rows by event. For each
   event, the actual link set is every row whose `stream_id` is neither 0 nor the origin ID,
   keyed by `(stream_name, stream_version)`. Compare with the selection's `acknowledgedLinks`:
   actual but not acknowledged → `CompactionUnexpectedLink eventId (LinkWitness stream
   version)`; acknowledged but not actual → `CompactionAcknowledgedLinkMissing eventId link`.
   Sum acknowledged links over events that passed into `acknowledgedLinkCount`.

6. References. Run `SQL.deadLetterCountsStmt` and `SQL.causationDependentCountsStmt` over
   `verified`. Under `RefuseDeadLetters`, each non-zero dead-letter count →
   `CompactionDeadLettersPresent eventId n`; under `RemoveDeadLetters`, sum into
   `deadLetterCount`. Under `RefuseCausationDependents`, each non-zero dependent count →
   `CompactionCausationDependentsPresent eventId n`; under `AllowDanglingCausation`, sum into
   `causationDependentCount`.

7. Ledger. `record <- Tx.statement digestBytes ledgerRecordByDigestStmt`. If `Just record`:
   count surviving selected events with `survivingSelectedEventsStmt` over *all* selection IDs;
   zero → return `ValidationAlreadyApplied record` (short-circuit, discarding the per-event
   refusals, which in this state are all `CompactionSelectedEventMissing`); non-zero → return
   `ValidationRefused (CompactionLedgerConflict {compactionId, survivingEvents} :| [])`.
   If `Nothing` and refusals were collected, return `ValidationRefused` with them in the order
   collected (identity, lease, streams in witness order, then per-selection findings in
   canonical selection order). Otherwise build the report and return `ValidationReady`.

`buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport` fills
`manifestDigest`, `storeIdentity`, `operation`, both policies, `selectedEvents = length
selections`, `homeMemberships = selectedEvents`, `globalMemberships = selectedEvents`,
`linkMemberships = acknowledgedLinkCount`, `deadLettersRemoved = deadLetterCount` (zero under
the refuse policy), `causationDependents = causationDependentCount` (zero under the refuse
policy), `lowestGlobalPosition` and `highestGlobalPosition` from the first and last canonical
selection, `affectedStreams = manifestStreamHeads manifest` (already sorted by name and verified
equal to live heads), and seals it with `sealCompactionReport`.

`previewCompactionTx manifest` is then:

```haskell
previewCompactionTx manifest =
    validateCompactionTx manifest <&> \case
        ValidationRefused refusals -> Left refusals
        ValidationAlreadyApplied record -> Right (record ^. #report)
        ValidationReady validated -> Right (validated ^. #report)
```

Register `Kiroku.Store.Compaction.Internal` and `Kiroku.Store.Compaction.SQL` under
`other-modules` in `kiroku-store/kiroku-store.cabal`.

Result and proof: `cabal build kiroku-store` passes, and a throwaway test (or `cabal repl`
session against a store from `withTestStore`) running `runTransaction (previewCompactionTx m)`
returns `Right` a report for a freshly appended stream and
`Left (CompactionStreamMissing ... :| [])` for an unknown stream. Milestone 3 makes this
permanent.

### Milestone 2 — The effect, events, adapters, and public module

Goal: consumers call `previewCompaction` through `Store`, mocks can intercept it, and operators
see a `KirokuEvent` per preview.

Work. Add `PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty
CompactionRefusal) CompactionReport)` to `data Store` in `Kiroku.Store.Effect`, with a Haddock
comment stating it is surfaced as `Kiroku.Store.Compaction.previewCompaction`, takes no locks,
and writes nothing. Generalise `runTxOnPool` by adding a `TxSessions.Mode` parameter (update
its existing call sites to pass `TxSessions.Write`; the hard-delete arm and the lease arms keep
their behaviour). Add the interpreter arm:

```haskell
PreviewCompaction manifest -> do
    result <-
        runTxOnPool (store ^. #pool) TxSessions.transaction TxSessions.Read
            (Internal.previewCompactionTx manifest)
    let digest = compactionManifestDigest manifest
    liftIO $ case result of
        Right report ->
            emitOrDrop (store ^. #eventHandler)
                (KirokuEventCompactionPreviewed digest (report ^. #selectedEvents))
        Left refusals ->
            emitOrDrop (store ^. #eventHandler)
                (KirokuEventCompactionRefused digest (NonEmpty.head refusals) (NonEmpty.length refusals))
    pure result
```

Events are emitted after the transaction finishes, matching the retention arms. Add the two
constructors to `KirokuEvent` in `Kiroku.Store.Observability` with Haddock (the refusal carried
is the first one; the `Int` is the total count; no payload data is included), extend the module
header's bullet list, and add `KirokuEventCompactionPreviewed{} -> pure ()` and
`KirokuEventCompactionRefused{} -> pure ()` arms at the tail of `onEvent` in
`kiroku-otel/src/Kiroku/Otel/Subscription.hs` and of `applyEvent` in
`kiroku-metrics/src/Kiroku/Metrics/Collector.hs` with a one-line comment that compaction
events are deliberately not folded into subscription tracing or the fixed metrics schema.

Create `kiroku-store/src/Kiroku/Store/Compaction.hs`:

```haskell
module Kiroku.Store.Compaction (
    module Kiroku.Store.Compaction.Types,
    previewCompaction,
    previewCompactionTx,
) where
```

with a module Haddock that explains, in plain language, the difference between preview (read
only, no locks, reports every refusal it can find, may be run on a clone or on production at any
time) and apply (one locked transaction, delivered by the apply plan), and that the same
validation runs in both. `previewCompaction manifest = send (PreviewCompaction manifest)`;
`previewCompactionTx = Internal.previewCompactionTx`. Add the module to `exposed-modules` and
replace the `module Kiroku.Store.Compaction.Types` re-export in `kiroku-store/src/Kiroku/Store.hs`
with `module Kiroku.Store.Compaction`.

Result and proof: `cabal build all` succeeds (the adapters compile), and the mock test in
Milestone 3 dispatches exactly once.

### Milestone 3 — Tests, structural gates, documentation, changelog

Goal: every refusal constructor and the happy path are proven against PostgreSQL; preview is
provably read-only and single-checkout.

Work. Create `kiroku-store/test/Test/CompactionPreview.hs` with `describe "compaction preview"`
and `around withTestStore`. Write local helpers: `seed :: KirokuStore -> StreamName -> Int -> IO
[RecordedEvent]` appending `n` events via `appendToStream` and reading them back with
`readStreamForward`, so tests have each event's ID, version, and global position
(`readAllForward` gives global positions; per-stream reads report `globalPosition 0`, so read
`$all` and filter by `originalStreamId`, or use the `AppendResult` plus per-event positions from
`readAllForward`); `liveIdentity :: KirokuStore -> IO StoreIdentity` via `storeIdentity`;
`manifestFor :: StoreIdentity -> [(StreamName, StreamVersion)] -> [CompactionSelection] ->
CompactionManifestInput`; `selectionOf :: RecordedEvent -> StreamName -> CompactionSelection`.
Examples (each asserts the exact `Left`/`Right` value or exact report fields):

- happy path: seed `orders-1` with 5 events, select versions 2 and 3, head witness 5; the report
  has `selectedEvents 2`, `homeMemberships 2`, `globalMemberships 2`, `linkMemberships 0`,
  `deadLettersRemoved 0`, `causationDependents 0`, lowest/highest global positions equal to the
  two events' positions, `affectedStreams = [orders-1 @ 5]`, and `reportDigest ==
  compactionReportDigest report`; a second preview returns an equal report; `countEvents` is
  unchanged;
- selecting the event at the stream head (version 5) succeeds;
- an event below a `setStreamTruncateBefore` marker still previews successfully;
- acknowledged link: link event 2 into `audit-1` with `linkToStream`, select it with
  `acknowledgedLinks = [audit-1 @ 1]` and head witnesses for both streams → report with
  `linkMemberships 1`; the same selection without the acknowledgement → `Left` containing
  `CompactionUnexpectedLink eid (LinkWitness "audit-1" 1)`; acknowledging a link that does not
  exist → `CompactionAcknowledgedLinkMissing`;
- link of a link: link the event into `audit-1`, then from `audit-1` into `audit-2`
  (`linkToStream (StreamName "audit-2") [eid]` again — links always reference the origin) and
  acknowledge both;
- two manifests for the same stream with disjoint selections both preview successfully with the
  same head witness;
- soft-deleted stream → `CompactionStreamSoftDeleted`; unknown stream →
  `CompactionStreamMissing`; head witness off by one → `CompactionStreamHeadDrift` with the
  live head as `actual`;
- wrong origin version → `CompactionWitnessMismatch` with the actual values; wrong global
  position → likewise; random event ID → `CompactionSelectedEventMissing`;
- dead letters: `insertDeadLetterForEvent store "sub" event` then preview under
  `RefuseDeadLetters` → `CompactionDeadLettersPresent eid 1`; under `RemoveDeadLetters` → report
  `deadLettersRemoved 1`;
- causation: append a second event with `causationId = Just (eventUuid first)` then select the
  first; `RefuseCausationDependents` → `CompactionCausationDependentsPresent eid 1`;
  `AllowDanglingCausation` → report `causationDependents 1`; selecting both events → 0 under
  either policy (the dependent is inside the selection);
- lease active: `acquireHistoryRetentionLease` (owner/reason/duration via the `mk*` helpers,
  60 seconds) then preview → `Left` containing `CompactionHistoryRetentionActive c` with
  `activeLeaseCount 1`, alongside no other refusal for an otherwise valid manifest; after
  `releaseHistoryRetentionLease`, the same preview succeeds;
- store identity mismatch: build the manifest with `StoreIdentity` of a fresh UUID →
  `Left (CompactionStoreIdentityMismatch {expected = thatUuid, actual = live} :| [])` and no
  other refusal even when the manifest is otherwise wrong (short-circuit);
- multiple findings: a manifest with one missing stream, one drifted head, and one wrong
  version returns all three refusals in the documented order;
- ledger conflict and already-applied: insert a ledger row directly with raw SQL (no GUC is
  needed for `INSERT`):

```sql
INSERT INTO event_compactions
  (manifest_digest, report_digest, store_id, operation, dead_letter_policy, causation_policy,
   selected_events, home_memberships, global_memberships, link_memberships,
   dead_letters_removed, causation_dependents, lowest_global_position, highest_global_position,
   affected_streams)
VALUES ($1, $2, $3, 'test', 'refuse', 'refuse', 2, 2, 2, 0, 0, 0, $4, $5,
        '[{"stream":"orders-1","head_version":5}]'::jsonb)
```

  with `$1` the manifest digest bytes, `$2` the digest of the report the happy-path preview
  produced, `$3` the live store UUID, `$4`/`$5` the positions. While the two selected events
  still exist, preview returns `Left (CompactionLedgerConflict {compactionId, survivingEvents =
  2} :| [])`. Then remove the two events with raw SQL (`SET LOCAL kiroku.enable_hard_deletes =
  'on'` inside one transaction, `DELETE FROM stream_events WHERE event_id = ANY($1)`, `DELETE
  FROM events WHERE event_id = ANY($1)`) and preview again: `Right report` whose
  `manifestDigest`, counts, and `reportDigest` equal the inserted row, proving the stored report
  is returned.
- observability: install an `eventHandler` collecting `KirokuEvent`s via
  `withTestStoreSettings`; one successful preview yields exactly one
  `KirokuEventCompactionPreviewed digest 2`; one refused preview yields exactly one
  `KirokuEventCompactionRefused digest firstRefusal n` with `n` equal to the list length.

Create `kiroku-store/test/Test/CompactionPreviewMock.hs`: an `interpret_` mock handling only
`PreviewCompaction manifest` (assert it equals the sample manifest, record `"preview"`, return
`Right sampleReport`), proving `previewCompaction` dispatches exactly once; build the sample
manifest with `mkCompactionManifest` and a fixed UUID identity.

Add to `kiroku-store/test/Test/PerformanceStructure.hs`, inside `noOpAppendSpec` (so it runs
under `just perf-structure`): "previews a manifest with one pool checkout" — using
`withObservedStore`, seed a stream, build a valid manifest, run `previewCompaction`, and assert
the checkout delta is exactly 1; and "keeps preview SQL free of locks and writes" — for each of
`CompactionSQL.resolveStreamsStmt`, `selectionWitnessesStmt`, `ledgerRecordByDigestStmt`,
`survivingSelectedEventsStmt`, `SQL.eventMembershipsStmt`, `SQL.deadLetterCountsStmt`,
`SQL.causationDependentCountsStmt`, assert `T.toUpper (Statement.toSql stmt)` contains none of
`"FOR UPDATE"`, `"FOR SHARE"`, `"DELETE"`, `"INSERT"`, `"UPDATE "`, `"SET LOCAL"`. Since
`Kiroku.Store.Compaction.SQL` is an `other-module`, the test cannot import it; instead export a
`previewStatementTexts :: [Text]` helper from `Kiroku.Store.Compaction` (documented as a
testing aid, like `Kiroku.Store.Effect`'s internal building blocks) that returns the SQL text
of every statement preview issues. Also extend the existing "keeps every ordinary statement free
of retention coordination" example to additionally assert that no ordinary statement mentions
`event_compactions` or `store_identity`.

Register `Test.CompactionPreview` and `Test.CompactionPreviewMock` in `other-modules` and in
`kiroku-store/test/Main.hs` (next to `HistoryRetention.spec` / `HistoryRetentionMock.spec`).

Write the Haddock on `previewCompaction` and `previewCompactionTx` (read-only; one checkout;
reports all refusals; lease conflicts are reported, not waited for; `Tx` variant runs inside the
caller's transaction and takes no locks, so a caller wanting a stable view should take the
ADR-7 guards itself). Add a `### New Features` bullet to the `## Unreleased` section of
`kiroku-store/CHANGELOG.md` describing `previewCompaction`, the two events, and the adapter
no-op arms (a breaking change for exhaustive matchers — note it under `### Breaking Changes` as
well).

Result and proof: the commands in Concrete Steps pass; `just perf-structure` lists the two new
examples as passing.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Verify the hard dependencies landed (all three must print a match):

```bash
grep -n "storeIdentityTx" kiroku-store/src/Kiroku/Store/Transaction.hs
grep -n "eventMembershipsStmt\|deadLetterCountsStmt\|causationDependentCountsStmt" kiroku-store/src/Kiroku/Store/SQL.hs
grep -n "mkCompactionManifest" kiroku-store/src/Kiroku/Store/Compaction/Types.hs
grep -n "0012.sql" kiroku-store-migrations/migrations/manifest
```

Build and test per milestone:

```bash
cabal build kiroku-store                       # after M1
cabal build all                                # after M2 (adapters must compile)
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "compaction preview"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "compaction preview mock"'
just perf-structure
cabal test all
nix fmt
```

Expected focused-run tail:

```text
compaction preview
  returns a deterministic report for two selections in one stream [✔]
  previews the event at the stream head [✔]
  ...
  returns the stored report once the ledger records the manifest [✔]
  emits one Previewed event per successful preview [✔]
Finished in 6.8 seconds
NN examples, 0 failures
```

Commit after each milestone with the three trailers. Example:

```text
feat(store): preview a compaction manifest read-only

Add validateCompactionTx, shared by preview and the later apply, and the
PreviewCompaction effect returning every refusal found or a sealed
CompactionReport. Preview runs in a Read-mode transaction on one pool
checkout, takes no locks, and emits Previewed/Refused events afterwards.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

Behavioural acceptance, observable in a test or a `cabal repl` session against a
`withTestStore` database:

1. After appending five events to `orders-1` and building a manifest selecting versions 2 and
   3 with head witness 5, `runStoreIO store (previewCompaction m)` returns `Right report` with
   `selectedEvents = 2`, `linkMemberships = 0`, `affectedStreams = [orders-1 @ 5]`, and
   `countEvents store` is unchanged before and after.
2. Changing the head witness to 6 returns `Left (CompactionStreamHeadDrift {stream = "orders-1",
   expected = 6, actual = 5} :| [])`.
3. With an active history-retention lease, the otherwise valid manifest returns `Left` whose
   only element is `CompactionHistoryRetentionActive` with `activeLeaseCount = 1`.
4. Linking event 2 into `audit-1` and previewing without acknowledging it returns `Left`
   containing `CompactionUnexpectedLink`; acknowledging it yields `Right` with
   `linkMemberships = 1`.
5. Building the manifest with a random `StoreIdentity` returns exactly one refusal,
   `CompactionStoreIdentityMismatch`.
6. `just perf-structure` passes with the two new examples; `cabal test all` passes; the
   pool-checkout delta for one preview is exactly 1.


## Idempotence and Recovery

Preview is read-only by construction; every test can be re-run against a fresh ephemeral
database. If an integration example fails because the ledger or identity table is missing,
migration `0012` from `docs/plans/74-...` has not been applied: that plan is a hard
dependency and must be completed first. If the adapters fail to compile after adding the
events, add the missing `pure ()` arms in `kiroku-otel` and `kiroku-metrics` — nothing else in
those packages changes. If `runTxOnPool`'s new `Mode` parameter breaks existing call sites,
pass `TxSessions.Write` at each of them; behaviour is unchanged.


## Interfaces and Dependencies

Hard dependencies (must be Complete): `docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md`
(migration `0012`, `StoreIdentity`, `storeIdentityTx`),
`docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md` (the three
inventory statements and `EventMembership` types), and
`docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md`
(all compaction types, `sealCompactionReport`, `compactionReportDigest`).

Libraries: `hasql`, `hasql-transaction`, `hasql-pool`, `contravariant-extras`, `vector`,
`containers`, `aeson`, `effectful-core`, `uuid`; all already in `kiroku-store`'s
build-depends.

Signatures that must exist at the end of this plan:

```haskell
-- Kiroku.Store.Compaction.SQL (other-module)
resolveStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Bool))
selectionWitnessesStmt :: Statement (Vector UUID, Vector Int64, Vector Int64, Vector Int64)
                                    (Vector (UUID, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64))
ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)
survivingSelectedEventsStmt :: Statement (Vector UUID) Int64

-- Kiroku.Store.Compaction.Internal (other-module)
data ValidatedCompaction = ValidatedCompaction { manifest, streamIds, selectedEventIds, acknowledgedLinkCount, deadLetterCount, causationDependentCount, report }
data ValidationOutcome = ValidationRefused (NonEmpty CompactionRefusal) | ValidationAlreadyApplied CompactionRecord | ValidationReady ValidatedCompaction
validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionReport)

-- Kiroku.Store.Effect
PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionReport)
runTxOnPool :: (IOE :> es, Error StoreError :> es) => Pool
            -> (TxSessions.IsolationLevel -> TxSessions.Mode -> Tx.Transaction a -> Session.Session a)
            -> TxSessions.Mode -> Tx.Transaction a -> Eff es a

-- Kiroku.Store.Compaction (exposed)
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionReport)
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionReport)
previewStatementTexts :: [Text]

-- Kiroku.Store.Observability
KirokuEventCompactionPreviewed :: CompactionDigest -> Int64 -> KirokuEvent
KirokuEventCompactionRefused :: CompactionDigest -> CompactionRefusal -> Int -> KirokuEvent
```

Consumers: `docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`
imports `validateCompactionTx`, `ValidationOutcome`, `ValidatedCompaction`, and the SQL
module; `docs/plans/79-...` wraps `previewCompaction` in the CLI; the external consumer is
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`.
