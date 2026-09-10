---
id: 77
slug: preview-a-compaction-manifest-read-only-with-deterministic-witnesses
title: "Preview a compaction manifest read-only with deterministic witnesses"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:36:16Z
      verdict: "changes-requested"
      note: "selectionWitnessesStmt is redundant with EP-2's eventMembershipsStmt (three index probes per selection plus a second pass); ledger decoder should use D.refine rather than error"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:45:20Z
      mode: "update"
      note: "Dropped selectionWitnessesStmt in favour of one eventMembershipsStmt pass; exported ledgerOutcomeTx; D.refine in the ledger decoder"
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
that could be found, not just the first — or a `CompactionPreview`:
`CompactionPreviewReady` carrying a deterministic `CompactionReport` with exact counts
of what would be removed, the head version of every affected stream, and a report digest an
operator can sign off on, or `CompactionPreviewAlreadyApplied` carrying the stored ledger
record when this exact manifest was already applied. Preview takes no locks, sets no session
variable, writes no row, uses exactly one pool checkout, and runs all of its reads on one
`RepeatableRead` snapshot. The same validation function is reused unchanged by the apply
plan `docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`,
executed there under the ADR-7 locks; this plan is therefore also where the "validate every
witness before the first delete" property is implemented.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Create `Kiroku.Store.Compaction.SQL` with the stream-resolution and ledger statements and re-exports of the EP-2 inventory statements.
- [ ] M1: Create `Kiroku.Store.Compaction.Internal` with `ledgerOutcomeTx`, `validateCompactionTx`, `ValidatedCompaction`, and `previewCompactionTx`.
- [ ] M1: Register `Kiroku.Store.Compaction.SQL` as an exposed module and `Kiroku.Store.Compaction.Internal` as an other-module; `cabal build kiroku-store` passes.
- [ ] M2: Add `PreviewCompaction` to `Store`, `runReadOnlyTxOnPool`, the interpreter arm with one checkout, and the two `KirokuEvent` constructors.
- [ ] M2: Add explicit no-op arms in `kiroku-otel` and `kiroku-metrics`; `cabal build all` passes.
- [ ] M2: Create public `Kiroku.Store.Compaction` exporting `previewCompaction` and `previewCompactionTx`, re-exporting Types; switch the `Kiroku.Store` re-export.
- [ ] M3: `Test.CompactionPreview` integration suite covering the happy path and every refusal constructor.
- [ ] M3: `Test.CompactionPreviewMock` dispatch test.
- [ ] M3: Structural assertions (one checkout per preview; preview SQL text contains no `FOR UPDATE`, `DELETE`, `SET LOCAL`; `EXPLAIN` plan shape for `resolveStreamsStmt` with a large array) registered under `describe "performance structure"`.
- [ ] M3: Haddock for `Kiroku.Store.Compaction` distinguishing preview from apply; `kiroku-store/CHANGELOG.md` entry.
- [ ] M3: `cabal test all`, `just perf-structure`, `nix fmt`, commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement validation once, as `validateCompactionTx`, returning a
  `ValidatedCompaction` value that carries the sealed report, the canonical selected-event IDs,
  and the exact `(event_id, stream_id)` junction pairs apply deletes (payload shape fixed by
  the MasterPlan's 2026-08-29 review); preview
  wraps it, and the apply plan calls the same function after taking its locks.
  Rationale: The request's central safety property is that the complete manifest is validated
  before the first row is deleted. A single shared function makes preview and apply agree by
  construction; any divergence would be a bug in exactly one place.
  Date: 2026-08-22

- Decision: Preview runs in a `RepeatableRead` transaction opened in `Read` mode
  (`TxSessions.Read`) through the new `runReadOnlyTxOnPool` helper, with no `SET LOCAL` and no
  row locks. (Supersedes the 2026-08-22 `ReadCommitted` decision, per the MasterPlan's
  2026-08-29 review.)
  Rationale: A read-only transaction is the strongest statement that preview cannot mutate; all
  of preview's statements are `SELECT`s, so `Read` mode costs nothing. Under `ReadCommitted`
  each statement would see a different snapshot, so a concurrent append landing between the
  head-resolution statement and the membership pass could manufacture spurious
  `CompactionStreamHeadDrift` or witness refusals; `RepeatableRead` gives one snapshot for the
  whole validation, and a read-only repeatable-read transaction can never serialization-fail.
  The locked apply transaction remains the authoritative check.
  Date: 2026-08-29

- Decision: Preview accumulates every refusal it can determine rather than stopping at the first,
  with two short-circuits: a store-identity mismatch (every other witness is meaningless against
  the wrong store) and a ledger conflict (the store is in an inconsistent state relative to the
  ledger and per-event findings would only add noise).
  Rationale: An operator reviewing a large manifest should see all missing events, all drifted
  heads, and all unexpected links in one pass instead of iterating one refusal at a time.
  Date: 2026-08-22

- Decision: When the ledger already records the manifest digest and no selected event survives,
  preview returns `Right (CompactionPreviewAlreadyApplied record)` with the stored ledger
  record; apply returns `CompactionAlreadyApplied` for the same state. The ledger lookup runs
  before any witness work. (Supersedes the 2026-08-22 "return the stored report" decision, per
  the MasterPlan's 2026-08-29 review.)
  Rationale: The request defines reapplication of a completed manifest as an observable no-op
  with the same logical report; the stored record carries that report plus the applied-at
  evidence, and the dedicated `CompactionPreview` outcome lets the CLI and Mori's workflow tell
  "ready to apply" from "already done", which `Either refusals CompactionReport` could not
  express. Checking the ledger first means re-previewing an applied 100k manifest costs one
  digest lookup and one surviving-count query instead of building and discarding 100k
  `CompactionSelectedEventMissing` values.
  Date: 2026-08-29

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

- Decision: There is no dedicated witness statement. Validation runs EP-2's
  `SQL.eventMembershipsStmt` once, unbatched, over every resolvable selection and derives the
  witness comparison, the acknowledged-link comparison, and `junctionRows` from the grouped
  rows. (Cascade from the MasterPlan's 2026-09-09 review; replaces the draft's
  `selectionWitnessesStmt`.)
  Rationale: The membership rows already carry every column the witness join fetched — the
  home row's `stream_version`, `original_stream_id`, and `original_stream_version`, the `$all`
  row's `stream_version`, and each link row with its resolved stream name — and validation had
  to run the membership statement anyway for the link comparison. One primary-key range scan
  per event replaces three probes plus a `LATERAL ... LIMIT 1` and a second membership pass,
  and the structural suite gates one statement fewer.
  Date: 2026-09-09

- Decision: The ledger step of validation is its own exported function, `ledgerOutcomeTx ::
  CompactionManifest -> Tx.Transaction LedgerOutcome`, and the ledger row decoder uses
  `D.refine` for the digest columns instead of `error`.
  Rationale: The apply plan calls the ledger step once more before it takes any stream lock, so
  a no-op reapply never blocks appends; sharing the function keeps the two call sites identical.
  `D.refine` keeps the decoder total — the check constraints make a malformed column
  unreachable, but a typed decode failure is the right shape if it ever happens.
  Date: 2026-09-09


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
`StoreError`; it is called as `runTxOnPool pool TxSessions.transaction body` and hard-codes
`ReadCommitted`/`Write`. This plan leaves `runTxOnPool` untouched (the apply plan's call sites
depend on its three-argument shape) and adds a read-only sibling, `runReadOnlyTxOnPool`, that
passes `RepeatableRead`/`Read` (see Milestone 2). Effect
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
`EventMembership` (a sum: `HomeMembership`/`GlobalMembership`/`LinkMembership`, each carrying
exactly its class's identity) and `EventReferenceInventory` live in `Kiroku.Store.Types`; this
plan consumes the raw statements, not those types.

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
PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionPreview)

-- Kiroku.Store.Compaction (public)
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionPreview)
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionPreview)

-- Kiroku.Store.Observability
KirokuEventCompactionPreviewed !CompactionDigest !Int64                 -- selected events
KirokuEventCompactionRefused !CompactionDigest !CompactionRefusal !Int  -- first refusal, total count
```

`CompactionPreview` (`CompactionPreviewReady CompactionReport` /
`CompactionPreviewAlreadyApplied CompactionRecord`) comes from
`Kiroku.Store.Compaction.Types`; this plan adds no public type of its own.

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

There is no separate witness statement. Every fact a selection's witnesses are compared
against — the home row's `stream_version`, `original_stream_id`, and `original_stream_version`,
the `$all` row's `stream_version`, and every link row with its resolved stream name — is a
column of the rows `SQL.eventMembershipsStmt` (from
`docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md`) returns for the
same event IDs, and validation has to run that statement anyway to compare acknowledged links.
Validation therefore runs it once, unbatched, over every selection whose origin stream
resolved (the raw statement accepts the whole manifest's array; only the
`lookupEventReferences` interpreter arm batches at 10000), and derives witness checks, link
checks, and `junctionRows` from the grouped rows. That is one primary-key range scan per
event instead of the three probes plus a `LATERAL ... LIMIT 1` that a dedicated witness join
would cost, and one statement fewer for the structural suite to gate.

`ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)` — selects every
ledger column `WHERE manifest_digest = $1`. Decode it into `CompactionRecord` by rebuilding the
`CompactionReport` (parse `affected_streams` JSONB with Aeson into `Vector StreamHeadWitness`,
map the policy strings back to the enums, wrap digests with `mkCompactionDigest` through
`D.refine` so a malformed column surfaces as a typed decode error rather than an `error` call
— the table's check constraints make it unreachable, but the decoder stays total) and
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
exporting `ledgerOutcomeTx`, `LedgerOutcome (..)`, `validateCompactionTx`,
`ValidatedCompaction (..)`, `previewCompactionTx`, and `buildReport`. Define:

```haskell
data ValidatedCompaction = ValidatedCompaction
    { report :: !CompactionReport                -- sealed; preview returns it verbatim
    , selectedEventIds :: !(Vector UUID)         -- ascending global position
    , junctionRows :: !(Vector (UUID, Int64))    -- every (event_id, stream_id) pair apply deletes
    }

data ValidationOutcome
    = ValidationRefused (NonEmpty CompactionRefusal)
    | ValidationAlreadyApplied CompactionRecord
    | ValidationReady ValidatedCompaction

data LedgerOutcome
    = LedgerUnrecorded
    | LedgerAlreadyApplied CompactionRecord   -- recorded, no selected event survives
    | LedgerConflict CompactionId Int64       -- recorded, this many selected events survive

ledgerOutcomeTx :: CompactionManifest -> Tx.Transaction LedgerOutcome
validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
```

The shape is fixed by the MasterPlan's "Shared preview/apply internals": `junctionRows` is the
exact set of `(event_id, stream_id)` pairs the apply plan deletes — the home row (origin
`stream_id`), the global row (`stream_id = 0`), and one row per acknowledged link (the link
target's resolved `stream_id`) for every selection — so "delete only what was accounted for"
is structural in apply's `DELETE`. Every count apply verifies derives from this value: the
junction total is `length junctionRows`, the dead-letter total is the report's
`deadLettersRemoved`, the events total is the report's `selectedEvents`. Resolved stream IDs
and running counts are locals of `validateCompactionTx`, not fields.

`validateCompactionTx` performs these steps in order, collecting refusals in a `Seq` or reversed
list and returning `ValidationRefused` at the end unless a short-circuit fires:

1. Identity. `actual <- storeIdentityTx`; if `actual /= manifestStoreIdentity manifest`, return
   `ValidationRefused (CompactionStoreIdentityMismatch {expectedIdentity, actualIdentity} :| [])`
   immediately.

2. Leases. `conflict <- activeHistoryRetentionConflictTx`; on `Just c` add
   `CompactionHistoryRetentionActive c` (do not short-circuit: the operator wants the other
   findings too).

3. Ledger. `ledgerOutcomeTx manifest`: `Tx.statement digestBytes ledgerRecordByDigestStmt`,
   and only when that returns `Just record`, `survivingSelectedEventsStmt` over *all*
   selection IDs. `LedgerAlreadyApplied record` (zero survivors) → return
   `ValidationAlreadyApplied record` (short-circuit); `LedgerConflict compactionId n` → return
   `ValidationRefused (CompactionLedgerConflict {compactionId, survivingEvents = n} :| [])`
   (short-circuit: the store is inconsistent relative to the ledger and per-event findings
   would only add noise); `LedgerUnrecorded` falls through. Running this before any witness
   work means re-previewing an applied 100k manifest costs one digest lookup and one count
   instead of building and discarding 100k `CompactionSelectedEventMissing` values. The step
   is its own exported function because the apply plan calls it once more, before it takes
   any stream lock, so a no-op reapply never blocks appends.

4. Streams. Collect the set of touched names (every `originStream`, every acknowledged link's
   `stream`, every head witness's `stream`; by construction of `mkCompactionManifest` these are
   the same set as the witnesses). Run `resolveStreamsStmt`. For each witness: absent →
   `CompactionStreamMissing name`; present with `deleted` → `CompactionStreamSoftDeleted name`;
   present and `stream_version /= headVersion` → `CompactionStreamHeadDrift {stream,
   expectedHead, actualHead}`. Keep the resolved name→ID map as a local. Matching is per fact,
   with no cascading exclusions: a missing stream yields exactly its `CompactionStreamMissing`.
   A selection whose origin stream is missing is excluded from the membership pass (its
   origin ID cannot be resolved) and gets no additional per-event refusal — the stream refusal
   already covers it; an acknowledged link targeting a missing stream is likewise covered by
   that stream's refusal, while the same selection's other links and its origin witnesses are
   still validated normally, and no spurious `CompactionUnexpectedLink` or
   `CompactionAcknowledgedLinkMissing` is emitted for facts that do match. One discrepancy
   never suppresses or fabricates another.

5. Memberships and witnesses. Run `SQL.eventMembershipsStmt` once over every remaining
   selection's event ID (the full array; no batching) and group its rows by event ID. Per
   selection: no rows at all → `CompactionSelectedEventMissing eventId`. Otherwise the *home*
   row is the row whose `stream_id` equals the resolved origin ID and the *global* row is the
   row whose `stream_id` is 0. If the home row is absent, or its `stream_version` differs from
   `originVersion`, or its `original_stream_id` differs from the resolved origin ID, or its
   `original_stream_version` differs from `originVersion`, or the global row is absent, or its
   `stream_version` differs from `globalPosition` → `CompactionWitnessMismatch eventId
   (WitnessMismatch {actualOriginStream, actualOriginVersion, actualGlobalPosition})`, where
   `actualOriginVersion` and the origin ID come from any row's `original_*` columns,
   `actualGlobalPosition` is the global row's version or `Nothing`, and `actualOriginStream`
   is the home row's own `stream_name` when that row exists, else the name resolved from the
   origin ID through the touched-stream map or, when the ID is not a touched stream, through
   one `SQL.lookupStreamNamesStmt` call gathered for all such IDs (at most one call). Every
   other row of the event is a live link, keyed by `(stream_name, stream_version)`; compare it
   with the selection's `acknowledgedLinks` per fact: actual but not acknowledged →
   `CompactionUnexpectedLink eventId (LinkWitness stream version)`; acknowledged but not
   actual → `CompactionAcknowledgedLinkMissing eventId link`. A selection with no witness or
   link refusal is `verified`: it contributes `(eventId, originId)`, `(eventId, 0)`, and one
   `(eventId, stream_id)` pair per acknowledged link (the link row's `stream_id`) to
   `junctionRows`, and its acknowledged-link count to the link total.

6. References. Run `SQL.deadLetterCountsStmt` and `SQL.causationDependentCountsStmt` over
   `verified`. Under `RefuseDeadLetters`, each non-zero dead-letter count →
   `CompactionDeadLettersPresent eventId n`; under `RemoveDeadLetters`, sum into the
   dead-letter count. Under `RefuseCausationDependents`, each non-zero dependent count →
   `CompactionCausationDependentsPresent eventId n`; under `AllowDanglingCausation`, sum into
   the causation count. (Per the MasterPlan, the causation refusal is validation-time
   best-effort — causation IDs have no foreign key and apply takes no lock on unlisted
   streams; say so in the Haddock.)

7. Outcome. If refusals were collected, return `ValidationRefused` with them in the order
   collected (identity, lease, streams in witness order, then per-selection findings in
   canonical selection order). Otherwise assemble `junctionRows` from the resolved IDs and
   acknowledged links, build the report, and return `ValidationReady`.

`buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport` takes the
link, dead-letter, and causation counts and fills `manifestDigest`, `storeIdentity`,
`operation`, both policies, `selectedEvents = length selections`, `homeMemberships =
selectedEvents`, `globalMemberships = selectedEvents`, `linkMemberships`,
`deadLettersRemoved` (zero under the refuse policy), `causationDependents` (zero under the
refuse policy), `lowestGlobalPosition` and `highestGlobalPosition` from the first and last
canonical selection, `affectedStreams = manifestStreamHeads manifest` (already sorted by name
and verified equal to live heads), and seals it with `sealCompactionReport`.

`previewCompactionTx manifest` is then:

```haskell
previewCompactionTx manifest =
    validateCompactionTx manifest <&> \case
        ValidationRefused refusals -> Left refusals
        ValidationAlreadyApplied record -> Right (CompactionPreviewAlreadyApplied record)
        ValidationReady validated -> Right (CompactionPreviewReady (validated ^. #report))
```

Register `Kiroku.Store.Compaction.SQL` under `exposed-modules` (mirroring `Kiroku.Store.SQL`:
the structural suite must be able to import it and `EXPLAIN` its statements) and
`Kiroku.Store.Compaction.Internal` under `other-modules` in
`kiroku-store/kiroku-store.cabal`.

Result and proof: `cabal build kiroku-store` passes, and a throwaway test (or `cabal repl`
session against a store from `withTestStore`) running `runTransaction (previewCompactionTx m)`
returns `Right (CompactionPreviewReady report)` for a freshly appended stream and
`Left (CompactionStreamMissing ... :| [])` for an unknown stream. Milestone 3 makes this
permanent.

### Milestone 2 — The effect, events, adapters, and public module

Goal: consumers call `previewCompaction` through `Store`, mocks can intercept it, and operators
see a `KirokuEvent` per preview.

Work. Add `PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty
CompactionRefusal) CompactionPreview)` to `data Store` in `Kiroku.Store.Effect`, with a Haddock
comment stating it is surfaced as `Kiroku.Store.Compaction.previewCompaction`, takes no locks,
and writes nothing. Leave `runTxOnPool` exactly as it is; add beside it:

```haskell
-- | Like 'runTxOnPool' but for read-only work: one snapshot for every
-- statement, no serialization failures possible in a Read transaction.
runReadOnlyTxOnPool ::
    (IOE :> es, Error StoreError :> es) =>
    Pool ->
    Tx.Transaction a ->
    Eff es a
runReadOnlyTxOnPool pool tx = do
    result <-
        liftIO $
            Pool.use pool $
                TxSessions.transaction TxSessions.RepeatableRead TxSessions.Read tx
    case result of
        Left usageErr -> throwError (mapTransactionUsageError usageErr)
        Right a -> pure a
```

Add the interpreter arm:

```haskell
PreviewCompaction manifest -> do
    result <-
        runReadOnlyTxOnPool (store ^. #pool)
            (Internal.previewCompactionTx manifest)
    let digest = compactionManifestDigest manifest
    liftIO $ case result of
        Right (CompactionPreviewReady report) ->
            emitOrDrop (store ^. #eventHandler)
                (KirokuEventCompactionPreviewed digest (report ^. #selectedEvents))
        Right (CompactionPreviewAlreadyApplied record) ->
            emitOrDrop (store ^. #eventHandler)
                (KirokuEventCompactionPreviewed digest (record ^. #report . #selectedEvents))
        Left refusals ->
            emitOrDrop (store ^. #eventHandler)
                (KirokuEventCompactionRefused digest (NonEmpty.head refusals) (NonEmpty.length refusals))
    pure result
```

Both preview outcomes emit `KirokuEventCompactionPreviewed` — the already-applied recognition
is still a preview; the `KirokuEventCompactionAlreadyApplied` constructor belongs to the apply
plan and is emitted only by apply.

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
Examples (each asserts the exact `Left`/`Right` value or exact report fields; below,
"`Right` a report" abbreviates `Right (CompactionPreviewReady report)` — only the
already-applied example produces `CompactionPreviewAlreadyApplied`):

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
  FROM events WHERE event_id = ANY($1)`) and preview again:
  `Right (CompactionPreviewAlreadyApplied record)` whose record's report `manifestDigest`,
  counts, and `reportDigest` equal the inserted row, proving the stored record is returned and
  is distinguishable from a ready preview.
- observability: install an `eventHandler` collecting `KirokuEvent`s via
  `withTestStoreSettings`; one successful preview yields exactly one
  `KirokuEventCompactionPreviewed digest 2`; the already-applied preview also yields exactly
  one `KirokuEventCompactionPreviewed`; one refused preview yields exactly one
  `KirokuEventCompactionRefused digest firstRefusal n` with `n` equal to the list length.

Create `kiroku-store/test/Test/CompactionPreviewMock.hs`: an `interpret_` mock handling only
`PreviewCompaction manifest` (assert it equals the sample manifest, record `"preview"`, return
`Right (CompactionPreviewReady sampleReport)`), proving `previewCompaction` dispatches exactly
once; build the sample manifest with `mkCompactionManifest` and a fixed UUID identity.

Add to `kiroku-store/test/Test/PerformanceStructure.hs`, inside `noOpAppendSpec` (so it runs
under `just perf-structure`): "previews a manifest with one pool checkout" — using
`withObservedStore`, seed a stream, build a valid manifest, run `previewCompaction`, and assert
the checkout delta is exactly 1; and "keeps preview SQL free of locks and writes" — for each of
`CompactionSQL.resolveStreamsStmt`, `ledgerRecordByDigestStmt`,
`survivingSelectedEventsStmt`, `SQL.eventMembershipsStmt`, `SQL.deadLetterCountsStmt`,
`SQL.causationDependentCountsStmt`, assert `T.toUpper (Statement.toSql stmt)` contains none of
`"FOR UPDATE"`, `"FOR SHARE"`, `"DELETE"`, `"INSERT"`, `"UPDATE "`, `"SET LOCAL"`.
`Kiroku.Store.Compaction.SQL` is an exposed module precisely so this test imports the
statements directly (no re-exported SQL-text helper exists or is needed). Under
`queryPlanSpec`, add an `EXPLAIN` plan-shape assertion for `resolveStreamsStmt` following the
existing `explainProductionStatement` examples, substituting a realistically large
`text[]` literal (hundreds of names at minimum — the planner's choice for a one-element array
proves nothing about the 100000-row case) and asserting the resolution is served by
`ix_streams_stream_name`. The membership statement validation reuses is gated by
`docs/plans/75-...`'s large-array `stream_events_pkey` assertion; do not duplicate it. (The
ordinary-statement `event_compactions`/`store_identity` text assertion is owned by
`docs/plans/74-...`, not this plan.)

Register `Test.CompactionPreview` and `Test.CompactionPreviewMock` in `other-modules` and in
`kiroku-store/test/Main.hs` (next to `HistoryRetention.spec` / `HistoryRetentionMock.spec`).

Write the Haddock on `previewCompaction` and `previewCompactionTx` (read-only; one checkout on
one `RepeatableRead` snapshot; reports all refusals; lease conflicts are reported, not waited
for; the causation-dependent refusal is validation-time best-effort — causation IDs carry no
foreign key and apply locks no unlisted stream, so a dependent appended elsewhere after
validation is not detected; `Tx` variant runs inside the
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
   3 with head witness 5, `runStoreIO store (previewCompaction m)` returns
   `Right (CompactionPreviewReady report)` with
   `selectedEvents = 2`, `linkMemberships = 0`, `affectedStreams = [orders-1 @ 5]`, and
   `countEvents store` is unchanged before and after.
2. Changing the head witness to 6 returns `Left (CompactionStreamHeadDrift {stream = "orders-1",
   expectedHead = 6, actualHead = 5} :| [])`.
3. With an active history-retention lease, the otherwise valid manifest returns `Left` whose
   only element is `CompactionHistoryRetentionActive` with `activeLeaseCount = 1`.
4. Linking event 2 into `audit-1` and previewing without acknowledging it returns `Left`
   containing `CompactionUnexpectedLink`; acknowledging it yields `Right` with
   `linkMemberships = 1`.
5. Building the manifest with a random `StoreIdentity` returns exactly one refusal,
   `CompactionStoreIdentityMismatch`.
6. `just perf-structure` passes with the new examples (checkout count, lock-free SQL text, and
   the large-array plan shape); `cabal test all` passes; the
   pool-checkout delta for one preview is exactly 1.


## Idempotence and Recovery

Preview is read-only by construction; every test can be re-run against a fresh ephemeral
database. If an integration example fails because the ledger or identity table is missing,
migration `0012` from `docs/plans/74-...` has not been applied: that plan is a hard
dependency and must be completed first. If the adapters fail to compile after adding the
events, add the missing `pure ()` arms in `kiroku-otel` and `kiroku-metrics` — nothing else in
those packages changes. `runTxOnPool` is deliberately untouched; if a diff shows its signature
changing, revert it and route preview through `runReadOnlyTxOnPool` instead.


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
-- Kiroku.Store.Compaction.SQL (exposed)
resolveStreamsStmt :: Statement (Vector Text) (Vector (Text, Int64, Int64, Bool))
ledgerRecordByDigestStmt :: Statement ByteString (Maybe CompactionRecord)
survivingSelectedEventsStmt :: Statement (Vector UUID) Int64
compactionRecordRow :: D.Row CompactionRecord

-- Kiroku.Store.Compaction.Internal (other-module)
data ValidatedCompaction = ValidatedCompaction { report, selectedEventIds, junctionRows }
data ValidationOutcome = ValidationRefused (NonEmpty CompactionRefusal) | ValidationAlreadyApplied CompactionRecord | ValidationReady ValidatedCompaction
data LedgerOutcome = LedgerUnrecorded | LedgerAlreadyApplied CompactionRecord | LedgerConflict CompactionId Int64
ledgerOutcomeTx :: CompactionManifest -> Tx.Transaction LedgerOutcome
validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome
buildReport :: CompactionManifest -> Int64 -> Int64 -> Int64 -> CompactionReport
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionPreview)

-- Kiroku.Store.Effect
PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionPreview)
runReadOnlyTxOnPool :: (IOE :> es, Error StoreError :> es) => Pool -> Tx.Transaction a -> Eff es a
-- runTxOnPool keeps its existing three-argument shape, unchanged.

-- Kiroku.Store.Compaction (exposed)
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionPreview)
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionPreview)

-- Kiroku.Store.Observability
KirokuEventCompactionPreviewed :: CompactionDigest -> Int64 -> KirokuEvent
KirokuEventCompactionRefused :: CompactionDigest -> CompactionRefusal -> Int -> KirokuEvent
```

Consumers: `docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`
imports `ledgerOutcomeTx`, `validateCompactionTx`, `ValidationOutcome`, `ValidatedCompaction`,
and the SQL module; `docs/plans/79-...` wraps `previewCompaction` in the CLI; the external consumer is
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`.


## Revision Notes

- 2026-09-09 (claude-fable-5-1, update cascaded from the MasterPlan review): Removed
  `selectionWitnessesStmt`; witness checks, link checks, and `junctionRows` now come from one
  unbatched `eventMembershipsStmt` pass (validation steps 5 and 6 merged). Factored the ledger
  step out as the exported `ledgerOutcomeTx` so the apply plan can probe the ledger before
  locking streams. The ledger row decoder uses `D.refine` instead of `error`. Structural
  assertions and Interfaces updated to match; the plan-shape gate for the membership statement
  stays with EP-2.
