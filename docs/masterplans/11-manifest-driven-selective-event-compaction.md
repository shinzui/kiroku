---
id: 11
slug: manifest-driven-selective-event-compaction
title: "Manifest-driven selective event compaction"
kind: master-plan
created_at: 2026-08-22T14:06:28Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
---

# Manifest-driven selective event compaction

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Kiroku is an append-only PostgreSQL event store. Today its only ways to make history smaller
are whole-stream soft delete, whole-stream hard delete, and the reversible logical
`truncate_before` marker (all in `kiroku-store/src/Kiroku/Store/Lifecycle.hs`). None of them
can physically remove a reviewed subset of events from a stream that must otherwise stay live.
The improvement request
[IR-14](../improvement-requests/add-manifest-driven-selective-event-compaction.md), filed by
`mori://shinzui/mori/masterplans/27-record-event-provenance-and-manage-the-store-lifecycle`
for the hard-gated consumer
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`,
asks for exactly that: a public, transactional, manifest-driven operation that deletes a
caller-selected set of originated events and nothing else.

After this initiative a `kiroku-store` consumer can do the following. It asks the store for its
identity (a UUID installed by migration) and for the complete membership and reference inventory
of any event (home stream row, `$all` row, link rows, dead letters, causation dependents). It
builds an immutable, digest-sealed *compaction manifest* naming the store, an operation label,
explicit reference policies, the expected head version of every affected stream, and every
selected event with its event ID, originating stream, original stream version, global position,
and any link memberships it explicitly acknowledges. It previews the manifest: a read-only
operation that validates every witness against the live store and returns either a closed list
of typed refusals or a deterministic report with counts and a report digest. It applies the
manifest: one database transaction that takes the ADR-7 coordinator lock, refuses while any
history-retention lease is active, locks every affected stream row in ascending `stream_id`
order, re-validates every witness under those locks, deletes exactly the accounted-for junction
and payload rows, records the applied manifest in an append-only ledger table, and commits. The
same manifest applied again is a recognised no-op returning the stored record; a manifest whose
events are only partially present is refused. Retained events keep their event IDs, stream
versions, global positions, payloads, metadata, causation and correlation IDs, and memberships
byte for byte. Every ordered read skips the physical gap without renumbering, subscription
checkpoints continue forward, and an expected-version append succeeds from the unchanged
pre-compaction head. Operators can audit previews, refusals, and applies through typed
`KirokuEvent` values, read the ledger through a public API, and drive preview and apply through
embeddable `kiroku-cli` commands. The capability ships in versioned `kiroku-store`,
`kiroku-store-migrations`, and `kiroku-cli` releases proven from a clean external consumer.

The initiative deliberately follows event-sourcing practice rather than the letter of the request
where the two differ. Immutability stays the default: physical deletion is exceptional, explicit,
witness-validated, and itself recorded as a durable fact. Kiroku never decides that an event is
semantically redundant; the consumer proves it and presents immutable witnesses, and Kiroku fails
closed on any discrepancy. Retained history is never renumbered or rewritten; gaps are first
class, as they already are after whole-stream hard delete. Logical compaction
(`setStreamTruncateBefore`) remains the recommended tool for close-the-book snapshots; physical
compaction exists for reclaiming space held by provably redundant facts after the consumer has
archived them. Coordination with readers and writers reuses ADR-7's leases and lock order and
adds no statement, trigger, lock, or round trip to ordinary append and read paths.

Out of scope, and recorded as deliberate exclusions: a whole-stream fallback, renumbering or
re-inserting retained events, declarative scavenge policies such as maximum stream length or
age, crypto-shredding, physical filesystem reclamation (documented as PostgreSQL `VACUUM`
territory), a remote or HTTP apply surface, a subscription-checkpoint guard inside the manifest,
and any Mori-specific classifier, archive format, ledger, or production authorisation.


## Decomposition Strategy

The work was split by functional concern into seven independently verifiable deliverables,
grouped into three implementation waves. Wave one builds three foundations that share no code:
the schema additions (store identity and ledger), the event reference inventory read API, and
the pure manifest, digest, refusal, and report types. Wave two builds the operation itself in
two steps, preview first and apply second, because apply's transaction is "preview's validation
under locks plus deletion plus a ledger insert", so preview is the natural, independently
demonstrable first half. Wave three delivers the operator-facing surface (documentation,
capability record, ADR, CLI) and then the release with its clean-consumer proof.

Three principles guided the boundaries. First, minimise cross-plan coupling: every shared type
and SQL object is owned by exactly one plan and specified verbatim in Integration Points below,
so later plans consume rather than negotiate. Second, maximise independent verifiability: each
wave-one plan has its own tests that pass without the others; preview is demonstrable without
apply; apply is demonstrable without the CLI. Third, respect natural ordering without over
serialising: the three wave-one plans run in parallel, and the only hard chains are
foundations → preview → apply → operator surface → release.

Alternatives considered. A single ExecPlan was rejected: it would carry at least eight
milestones across two packages, a migration, a new pure module with property tests, a
transactional core with concurrency and failure injection, CLI work, and a release, which is far
past the ExecPlan comfort zone and would hide the interface decisions that matter most. Merging
preview and apply was rejected because preview is a useful, shippable operator tool in its own
right and because separating it makes the "validation runs before the first delete" property
structurally obvious. Merging the reference inventory into preview was rejected because the
consumer (Mori's plan 237) needs a public "upstream link/reference inventory" to *build* the
manifest before it can preview anything, and other requests (a REST browse API) want it too.

Relevant local ADRs, read and carried into the child plans:
[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md) defines
the coordinator row, the lease conflict rule, the coordinator-then-ascending-`stream_id` lock
order, and the hot-path exclusion that every destructive operation must honour; compaction joins
that model. [ADR-5](../adr/0005-three-tier-performance-regression-gates.md) defines the
structural and controlled-workload gates that prove the hot path is unchanged; the apply plan
extends the structural tier. [ADR-3](../adr/0003-dedicated-kiroku-schema.md) requires every
new object to live schema-qualified in `kiroku`. [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
explains why `RecordedEvent` carries `originalStreamId` rather than a name and why the inventory
API resolves names in batch. [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md)
is why checkpoint handling is left to consumers. [ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md)
is why the ledger is exposed through a Haskell API and not a new SQL relation in this initiative.
Across repositories, `mori://shinzui/kiroku/okf/adrs/concepts/ADR-7` is the handle the request
itself cites. The earlier ExecPlan
[65](../plans/65-logical-truncate-before-for-close-the-book-compaction.md) recorded that physical
compaction was deferred to "a possible Phase 2"; this MasterPlan is that phase.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add a store identity and an append-only event-compaction ledger | docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md | None | None | Not Started |
| 2 | Expose an event membership and reference inventory read API | docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md | None | None | Not Started |
| 3 | Define the compaction manifest, canonical digest, refusal vocabulary, and report types | docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md | None | EP-1 (`StoreIdentity` newtype) | Not Started |
| 4 | Preview a compaction manifest read-only with deterministic witnesses | docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md | EP-1, EP-2, EP-3 | None | Not Started |
| 5 | Apply a compaction manifest transactionally with ledgered idempotence | docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md | EP-4 | None | Not Started |
| 6 | Document compaction for operators and add embeddable kiroku-cli compaction commands | docs/plans/79-document-compaction-for-operators-and-add-embeddable-kiroku-cli-compaction-commands.md | EP-5 | None | Not Started |
| 7 | Release the compaction cohort and prove it from a clean external consumer | docs/plans/80-release-the-compaction-cohort-and-prove-it-from-a-clean-external-consumer.md | EP-6 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Phases: wave one is EP-1, EP-2, EP-3 (parallel); wave two is EP-4 then EP-5; wave three is
EP-6 then EP-7.


## Dependency Graph

EP-1, EP-2, and EP-3 have no hard dependencies and can be implemented in any order or in
parallel. EP-3 has a soft dependency on EP-1 only for the `StoreIdentity` newtype in
`Kiroku.Store.Types`; whichever plan lands first adds the newtype exactly as specified in
Integration Points, and the other plan finds it already present.

EP-4 (preview) needs all three foundations: the `kiroku.store_identity` table and the
`storeIdentityTx` combinator from EP-1 to check store identity; the reference-inventory SQL
statements and `EventReferenceInventory` types from EP-2 to discover links, dead letters, and
causation dependents; and the manifest, refusal, and report types from EP-3 to accept input and
produce output. It also reads the ledger table from EP-1 to recognise an already-applied
manifest during preview.

EP-5 (apply) needs EP-4 because apply is preview's validation executed under the ADR-7 locks,
followed by deletion and a ledger insert; it reuses EP-4's validation function and statements
verbatim rather than duplicating them.

EP-6 (operator documentation and CLI) needs EP-5 because it documents and wraps the shipped
behaviour; the CLI commands call `previewCompaction`, `applyCompaction`, `compactionLedger`, and
`storeIdentity` through the `Store` effect.

EP-7 (release) needs EP-6 because a release must ship the documentation and CLI surface, and
because the clean-consumer proof compiles against the public modules that EP-6 finalises.


## Integration Points

This section is the single source of truth for every artifact more than one child plan touches.
Later plans consume these definitions verbatim; if implementation reveals that a definition must
change, update this section first, record the change in the Decision Log, and cascade to the
affected child plans.

### `StoreIdentity` and the `kiroku.store_identity` table

Owner: EP-1. Consumers: EP-3 (manifest field), EP-4 and EP-5 (identity check), EP-6 (CLI
`store identity` command and manifest JSON), EP-7 (clean-consumer witness).

`Kiroku.Store.Types` gains `newtype StoreIdentity = StoreIdentity UUID` deriving
`Eq, Ord, Show, Generic`. Migration `0012.sql` creates
`kiroku.store_identity (singleton BOOLEAN PRIMARY KEY DEFAULT TRUE, store_id UUID NOT NULL
DEFAULT kiroku.uuidv7(), created_at TIMESTAMPTZ NOT NULL DEFAULT now(), CONSTRAINT
chk_store_identity_singleton CHECK (singleton))`
and inserts its one row. UPDATE is blocked by a trigger on `kiroku.prevent_mutation()`; DELETE
and TRUNCATE are gated by `kiroku.protect_deletion()` and `kiroku.protect_truncation()` like the
data tables. The effect surface is `GetStoreIdentity :: Store m StoreIdentity`, wrapped as
`Kiroku.Store.Read.storeIdentity`, with a transaction combinator
`Kiroku.Store.Transaction.storeIdentityTx :: Tx.Transaction StoreIdentity`. A restored clone
shares its source's identity by construction; this is documented as intended for rehearsal.

### The `kiroku.event_compactions` ledger table

Owner: EP-1 (schema). Writer: EP-5. Readers: EP-4 (already-applied detection), EP-5 (inventory
API), EP-6 (CLI `compaction ledger`).

Columns, in order: `compaction_id UUID PRIMARY KEY DEFAULT kiroku.uuidv7()`,
`manifest_digest BYTEA NOT NULL UNIQUE`, `report_digest BYTEA NOT NULL`, `store_id UUID NOT NULL`,
`operation TEXT NOT NULL`, `dead_letter_policy TEXT NOT NULL`, `causation_policy TEXT NOT NULL`,
`selected_events BIGINT NOT NULL`, `home_memberships BIGINT NOT NULL`,
`global_memberships BIGINT NOT NULL`, `link_memberships BIGINT NOT NULL`,
`dead_letters_removed BIGINT NOT NULL`, `causation_dependents BIGINT NOT NULL`,
`lowest_global_position BIGINT NOT NULL`, `highest_global_position BIGINT NOT NULL`,
`affected_streams JSONB NOT NULL`, `applied_at TIMESTAMPTZ NOT NULL DEFAULT now()`,
`applied_by TEXT NOT NULL DEFAULT session_user`. Named constraints:
`chk_event_compactions_manifest_digest_bytes` and `chk_event_compactions_report_digest_bytes`
(`octet_length(...) = 32`), `chk_event_compactions_operation_bytes`
(`octet_length(operation) BETWEEN 1 AND 512`), `chk_event_compactions_policies`
(`dead_letter_policy IN ('refuse','remove') AND causation_policy IN ('refuse','allow')`),
`chk_event_compactions_counts` (`selected_events > 0`, every other count `>= 0`,
`home_memberships = selected_events`, `global_memberships = selected_events`),
`chk_event_compactions_positions` (`0 < lowest_global_position AND lowest_global_position <=
highest_global_position`). `affected_streams` is a JSON array of objects
`{"stream": <name>, "head_version": <int>}` sorted by stream name. Index
`ix_event_compactions_applied_at ON kiroku.event_compactions (applied_at DESC, compaction_id)`.
Triggers: UPDATE blocked by `kiroku.prevent_mutation()`, DELETE and TRUNCATE gated by
`kiroku.protect_deletion()` / `kiroku.protect_truncation()`. No trigger is added to `events`,
`stream_events`, or `streams`; the existing structural assertions that count
`protect_replay_history_*` triggers on those three tables stay at `(6, 0)`.

### Event membership and reference inventory

Owner: EP-2. Consumers: EP-4 and EP-5 (validation statements), EP-6 (documentation),
Mori's plan 237 (manifest construction).

`Kiroku.Store.Types` gains:

```haskell
data EventMembershipKind = HomeMembership | GlobalMembership | LinkMembership
    deriving stock (Eq, Ord, Show, Generic)

data EventMembership = EventMembership
    { stream :: !StreamName
    , streamId :: !StreamId
    , streamVersion :: !StreamVersion   -- the global position for GlobalMembership
    , kind :: !EventMembershipKind
    }
    deriving stock (Eq, Show, Generic)

data EventReferenceInventory = EventReferenceInventory
    { memberships :: !(Vector EventMembership)  -- ascending streamId
    , deadLetterCount :: !Int64
    , causationDependentCount :: !Int64         -- other events whose causation_id is this event
    }
    deriving stock (Eq, Show, Generic)
```

`HomeMembership` is the row where `stream_id = original_stream_id`; `GlobalMembership` is the
row where `stream_id = 0`; every other row is a `LinkMembership`. The effect surface is
`LookupEventReferences :: [EventId] -> Store m (Map EventId EventReferenceInventory)` wrapped as
`Kiroku.Store.Read.lookupEventReferences`, with
`Kiroku.Store.Transaction.lookupEventReferencesTx`. Unknown IDs are absent from the map; an
empty input performs no pool checkout. The SQL statements live in
`Kiroku.Store.SQL` under a new export group `-- * Event reference inventory statements`:
`eventMembershipsStmt :: Statement (Vector UUID) (Vector (UUID, Int64, Text, Int64, Int64))`
returning `(event_id, stream_id, stream_name, stream_version, original_stream_id)`,
`deadLetterCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))`, and
`causationDependentCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))` (dependents
outside the input set).

### Manifest, digest, refusal, and report types

Owner: EP-3, in the new exposed module `Kiroku.Store.Compaction.Types`. Consumers: EP-4, EP-5,
EP-6, EP-7.

```haskell
newtype CompactionOperation = CompactionOperation Text      -- validated 1..512 UTF-8 bytes
newtype CompactionDigest = CompactionDigest ByteString      -- exactly 32 bytes (SHA-256)
newtype CompactionId = CompactionId UUID

data LinkWitness = LinkWitness { stream :: !StreamName, streamVersion :: !StreamVersion }
data StreamHeadWitness = StreamHeadWitness { stream :: !StreamName, headVersion :: !StreamVersion }

data CompactionSelection = CompactionSelection
    { eventId :: !EventId
    , originStream :: !StreamName
    , originVersion :: !StreamVersion
    , globalPosition :: !GlobalPosition
    , acknowledgedLinks :: !(Vector LinkWitness)  -- sorted by (stream, streamVersion), unique
    }

data DeadLetterPolicy = RefuseDeadLetters | RemoveDeadLetters
data CausationPolicy = RefuseCausationDependents | AllowDanglingCausation

data CompactionManifestInput = CompactionManifestInput
    { storeIdentity :: !StoreIdentity
    , operation :: !CompactionOperation
    , deadLetterPolicy :: !DeadLetterPolicy
    , causationPolicy :: !CausationPolicy
    , streamHeads :: ![StreamHeadWitness]
    , selections :: ![CompactionSelection]
    , expectedDigest :: !(Maybe CompactionDigest)
    }

-- Abstract: constructed only by mkCompactionManifest; fields readable through accessors.
data CompactionManifest

mkCompactionManifest :: CompactionManifestInput -> Either CompactionManifestError CompactionManifest
compactionManifestDigest :: CompactionManifest -> CompactionDigest
canonicalCompactionManifestBytes :: CompactionManifest -> ByteString
maxCompactionSelections :: Int   -- 100000

-- Accessors on the abstract manifest (the only way to read it back):
manifestStoreIdentity :: CompactionManifest -> StoreIdentity
manifestOperation :: CompactionManifest -> CompactionOperation
manifestDeadLetterPolicy :: CompactionManifest -> DeadLetterPolicy
manifestCausationPolicy :: CompactionManifest -> CausationPolicy
manifestStreamHeads :: CompactionManifest -> Vector StreamHeadWitness   -- ascending by stream
manifestSelections :: CompactionManifest -> Vector CompactionSelection  -- ascending by globalPosition
manifestStreamNames :: CompactionManifest -> Vector Text                -- the heads' names, ascending
manifestDigest :: CompactionManifest -> CompactionDigest                -- synonym of compactionManifestDigest

-- Validated newtype constructors and renderings:
mkCompactionOperation :: Text -> Either CompactionManifestError CompactionOperation
mkCompactionDigest :: ByteString -> Maybe CompactionDigest             -- exactly 32 bytes
compactionDigestBytes :: CompactionDigest -> ByteString
compactionDigestHex :: CompactionDigest -> Text                        -- 64 lowercase hex chars
parseCompactionDigestHex :: Text -> Maybe CompactionDigest
mkCompactionLedgerLimit :: Int32 -> Either CompactionLedgerError CompactionLedgerLimit  -- 1..1000
sealCompactionReport :: CompactionReport -> CompactionReport           -- fills reportDigest

data CompactionManifestError
    = CompactionManifestEmpty
    | CompactionManifestTooLarge !Int
    | CompactionManifestDuplicateEvent !EventId
    | CompactionManifestReservedStream !StreamName
    | CompactionManifestInvalidStreamName !StreamName !Int
    | CompactionManifestNonPositiveVersion !EventId
    | CompactionManifestNonPositivePosition !EventId
    | CompactionManifestDuplicateLink !EventId !LinkWitness
    | CompactionManifestLinkIntoOrigin !EventId
    | CompactionManifestMissingStreamHead !StreamName
    | CompactionManifestUnusedStreamHead !StreamName
    | CompactionManifestDuplicateStreamHead !StreamName
    | CompactionManifestOperationEmpty
    | CompactionManifestOperationTooLong !Int
    | CompactionManifestDigestMismatch { expected :: !CompactionDigest, computed :: !CompactionDigest }

data CompactionRefusal
    = CompactionStoreIdentityMismatch { expected :: !StoreIdentity, actual :: !StoreIdentity }
    | CompactionHistoryRetentionActive !HistoryRetentionConflict
    | CompactionStreamMissing !StreamName
    | CompactionStreamSoftDeleted !StreamName
    | CompactionStreamHeadDrift { stream :: !StreamName, expected :: !StreamVersion, actual :: !StreamVersion }
    | CompactionSelectedEventMissing !EventId
    | CompactionWitnessMismatch !EventId !WitnessMismatch
    | CompactionUnexpectedLink !EventId !LinkWitness
    | CompactionAcknowledgedLinkMissing !EventId !LinkWitness
    | CompactionDeadLettersPresent !EventId !Int64
    | CompactionCausationDependentsPresent !EventId !Int64
    | CompactionLedgerConflict { compactionId :: !CompactionId, survivingEvents :: !Int64 }

data WitnessMismatch = WitnessMismatch
    { actualOriginStream :: !StreamName
    , actualOriginVersion :: !StreamVersion
    , actualGlobalPosition :: !(Maybe GlobalPosition)  -- Nothing when the $all row is gone
    }

data CompactionReport = CompactionReport
    { manifestDigest :: !CompactionDigest
    , storeIdentity :: !StoreIdentity
    , operation :: !CompactionOperation
    , deadLetterPolicy :: !DeadLetterPolicy
    , causationPolicy :: !CausationPolicy
    , selectedEvents :: !Int64
    , homeMemberships :: !Int64
    , globalMemberships :: !Int64
    , linkMemberships :: !Int64
    , deadLettersRemoved :: !Int64
    , causationDependents :: !Int64
    , lowestGlobalPosition :: !GlobalPosition
    , highestGlobalPosition :: !GlobalPosition
    , affectedStreams :: !(Vector StreamHeadWitness)   -- sorted by stream name
    , reportDigest :: !CompactionDigest
    }

compactionReportDigest :: CompactionReport -> CompactionDigest   -- over every field except reportDigest

data CompactionRecord = CompactionRecord
    { compactionId :: !CompactionId
    , report :: !CompactionReport
    , appliedAt :: !UTCTime
    , appliedBy :: !Text
    }

data CompactionApplyResult
    = CompactionAppliedNow !CompactionRecord
    | CompactionAlreadyApplied !CompactionRecord

newtype CompactionLedgerLimit = CompactionLedgerLimit Int32   -- validated 1..1000
data CompactionLedgerQuery = CompactionLedgerQuery { limit :: !CompactionLedgerLimit }
```

Every type derives `Eq, Show, Generic`; the newtypes also derive `Ord`. `CompactionManifest`,
`CompactionReport`, and `CompactionRecord` have hand-written `ToJSON`/`FromJSON` instances with
snake_case keys (`format`, `store_identity`, `operation`, `dead_letter_policy`,
`causation_policy`, `stream_heads[].stream`/`head_version`, `selections[].event_id`/
`origin_stream`/`origin_version`/`global_position`/`acknowledged_links[].stream`/
`stream_version`, `digest`); `FromJSON CompactionManifest` requires `format` equal to
`kiroku-compaction-manifest/1` and a `digest` key, and routes through `mkCompactionManifest` so
a corrupted document is rejected at decode time. Policies serialise as `refuse`/`remove` and
`refuse`/`allow`, the same words the ledger stores. Digests render as lowercase hex in JSON.

The canonical manifest encoding is fixed here so every implementation (and any other language)
computes the same root digest. It is the SHA-256 of the concatenation of: the ASCII bytes
`kiroku-compaction-manifest/1\n`; the 16 raw bytes of the store UUID; the operation label as a
4-byte big-endian length prefix followed by its UTF-8 bytes; one byte each for
`deadLetterPolicy` (`0x00` refuse, `0x01` remove) and `causationPolicy` (`0x00` refuse, `0x01`
allow); a 4-byte big-endian count of stream-head witnesses followed by each witness as
length-prefixed UTF-8 stream name then 8-byte big-endian head version, in ascending byte order
of stream name; a 4-byte big-endian count of selections followed by each selection, in
ascending global position, as 16 raw UUID bytes, length-prefixed origin stream name, 8-byte
big-endian origin version, 8-byte big-endian global position, a 4-byte count of acknowledged
links, and each link as length-prefixed stream name then 8-byte big-endian stream version in
ascending (name, version) order. The report digest uses the prefix
`kiroku-compaction-report/1\n` followed by the manifest digest bytes, the store UUID,
the length-prefixed operation, the two policy bytes, the eleven 8-byte big-endian counters and
positions in declaration order, and the affected streams encoded like stream-head witnesses.

SHA-256 comes from the `crypton` package (`Crypto.Hash.SHA256`), which is already in the
repository's dependency closure through `pg-migrate`; EP-3 confirms this with
`mori registry show` before adding the build dependency.

### Effect constructors, wrappers, and transaction combinators

Owners: EP-1 (`GetStoreIdentity`), EP-2 (`LookupEventReferences`), EP-4
(`PreviewCompaction`), EP-5 (`ApplyCompaction`, `GetCompactionLedger`). All constructors are
added to `data Store` in `kiroku-store/src/Kiroku/Store/Effect.hs` and interpreted in
`runStorePool`.

```haskell
GetStoreIdentity :: Store m StoreIdentity
LookupEventReferences :: [EventId] -> Store m (Map EventId EventReferenceInventory)
PreviewCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionReport)
ApplyCompaction :: CompactionManifest -> Store m (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
GetCompactionLedger :: CompactionLedgerQuery -> Store m (Vector CompactionRecord)
```

The public module `Kiroku.Store.Compaction` (created by EP-4, extended by EP-5) re-exports
`Kiroku.Store.Compaction.Types` and exposes `previewCompaction`, `applyCompaction`,
`compactionLedger` (effect wrappers) and `previewCompactionTx`, `applyCompactionTx`,
`compactionLedgerTx` (transaction combinators). `Kiroku.Store` re-exports the module. Internal
modules are `Kiroku.Store.Compaction.Internal` and `Kiroku.Store.Compaction.SQL`
(`other-modules`).

### Lock order and transaction shape for apply

Owner: EP-5, constrained by ADR-7. EP-4 owns the single validation function
`validateCompactionTx :: CompactionManifest -> Tx.Transaction ValidationOutcome` with
`ValidationOutcome = ValidationRefused (NonEmpty CompactionRefusal) | ValidationAlreadyApplied
CompactionRecord | ValidationReady ValidatedCompaction`; it performs the identity check, the
lease probe, non-locking stream resolution with head-drift checks, the witness join, membership
comparison, reference policies, and the ledger lookup by manifest digest (including the
surviving-event count that distinguishes "already applied" from "ledger conflict"). Preview
calls it alone; apply calls it unchanged after taking its locks. `applyCompactionTx` runs inside
one `ReadCommitted`/`Write` transaction and performs, in this order: `SET LOCAL
kiroku.enable_hard_deletes = 'on'`; `lockHistoryRetentionCoordinatorTx`;
`activeHistoryRetentionConflictTx` (refuse on `Just` before any stream lock is taken);
`SELECT ... FROM kiroku.streams WHERE stream_name = ANY($1) ORDER BY stream_id FOR UPDATE` over
every origin, link-target, and witness stream; `validateCompactionTx` (whose reads now observe
the locked rows and whose ledger lookup runs under the coordinator lock); `DELETE FROM
kiroku.stream_events WHERE event_id = ANY($1) RETURNING stream_id, original_stream_id`;
`DELETE FROM kiroku.dead_letters WHERE event_id = ANY($1)` only under `RemoveDeadLetters`;
`DELETE FROM kiroku.events WHERE event_id = ANY($1)`; `INSERT INTO kiroku.event_compactions ...
RETURNING compaction_id, applied_at, applied_by`. Any refusal returns `Left` before the first
`DELETE`, and `ValidationAlreadyApplied` returns `Right (CompactionAlreadyApplied record)`
without deleting anything. Returned counts that differ from the
validated expectation condemn the transaction and surface as
`UnexpectedServerError "KRCMP" ...`; this cannot happen under the held locks and exists as a
defensive invariant. The transaction never touches the `$all` streams row and never updates a
`streams` row, so no `NOTIFY` fires.

### Observability events

Owner: EP-4 (`Previewed`, `Refused`) and EP-5 (`Applied`, `AlreadyApplied`), added to
`KirokuEvent` in `kiroku-store/src/Kiroku/Store/Observability.hs`:

```haskell
KirokuEventCompactionPreviewed !CompactionDigest !Int64                 -- selected events
KirokuEventCompactionRefused !CompactionDigest !CompactionRefusal !Int  -- first refusal, total count
KirokuEventCompactionApplied !CompactionId !CompactionDigest !Int64 !Int64  -- events, memberships
KirokuEventCompactionAlreadyApplied !CompactionId !CompactionDigest
```

`kiroku-otel/src/Kiroku/Otel/Subscription.hs` and `kiroku-metrics/src/Kiroku/Metrics/Collector.hs`
match `KirokuEvent` exhaustively and must gain explicit no-op arms (EP-4 for the first two,
EP-5 for the last two). This is what makes the `kiroku-store` release a major bump.

### Structural gates

Owner: EP-5, extending `kiroku-store/test/Test/PerformanceStructure.hs` and
`kiroku-store-migrations/test/Main.hs`. The ordinary-statement list gains the assertion that no
ordinary statement mentions `event_compactions` or `store_identity`; the trigger-shape
assertion stays `(6, 0)`; a new assertion proves the ledger and identity tables carry only
DELETE/TRUNCATE/UPDATE protection triggers and nothing on INSERT; the migrations suite gains a
`describe "compaction schema"` block asserting exact columns and named constraints.

### Documentation and catalog surfaces

Owner: EP-6. `docs/user/compaction.md` (new), `docs/user/lifecycle.md` (cross-reference),
`docs/user/operator-cli.md`, `docs/user/observability.md`, `docs/user/schema-migrations.md`,
`docs/PRODUCTION-DEPLOYMENT.md`, `docs/capabilities/selective-event-compaction.md` (handle
allocated with `okf id next`), and the ADRs: EP-1 records the store-identity decision, EP-5
records the compaction contract decision; EP-6 validates both bundles.

### Downstream standalone operator surface (keiro-ops)

Owner: none in this MasterPlan; recorded so the embeddable-only decision has its follow-up
written down. No kiroku plan or request proposes a `kiroku-admin` or `kiroku-ops` binary, and
[ExecPlan 52](../plans/52-remote-subscription-status-http-endpoint-and-kiroku-cli-remote-client.md)
deliberately removed the standalone `kiroku` binary's `--database-url` mode on 2026-06-01. The
standalone, database-connected operator console for Kiroku-backed deployments already exists one
repository over: `mori://shinzui/keiro/packages/keiro-ops` ("Embeddable operational command tree
and command-line interface for Keiro deployments"). Its `Keiro.Ops.Stream` domain wraps Kiroku's
lifecycle operations today — `soft-delete`, `hard-delete` behind stream-name confirmation and
`--force`, and `truncate-before set|clear` with preview — and it resolves its connection from
`--database-url` / `KEIRO_OPS_DATABASE_URL`; Mori's consumer plan
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`
mounts keiro-ops rather than building its own confirmation surface. The intended shape is
therefore: EP-6 ships the embeddable `compaction preview|apply|ledger` commands and their
renderers in `kiroku-cli`; after EP-7 releases `kiroku-store` 0.9, a keiro improvement request
adds a `stream compact …` command to keiro-ops that reuses those renderers (the same way
`kiroku-metrics` reuses `SubscriptionStatusRow`) behind keiro-ops' existing destructive-command
rails. That request belongs to keiro and is not a deliverable of this MasterPlan; EP-7's
summary should mention it so the hand-off is not lost.

### Cross-plan decisions that deserve ADRs

Store identity as a schema-installed, clone-shared singleton (EP-1). Physical compaction is
manifest-driven, witness-validated, explicitly accounts for every reference class, never
renumbers, and is recorded in an append-only ledger keyed by manifest digest (EP-5). The
deliberate exclusions listed in Vision & Scope are recorded in that same ADR.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Migration `0012` installs `kiroku.store_identity` and `kiroku.event_compactions` with protection triggers and passes the migrations suite on PostgreSQL 17 and 18
- [ ] EP-1: `storeIdentity` / `storeIdentityTx` exposed, tested, mock-dispatched; store-identity ADR recorded
- [ ] EP-2: Inventory SQL statements with plan-shape assertions
- [ ] EP-2: `lookupEventReferences` / `lookupEventReferencesTx` exposed, tested against home, `$all`, link, dead-letter, and causation cases
- [ ] EP-3: Types, smart constructor, canonical encoding, digests, and JSON codec implemented
- [ ] EP-3: Hedgehog properties for determinism, order independence, corruption detection, and JSON round trip pass
- [ ] EP-4: `previewCompactionTx` validates every witness class and returns all refusals
- [ ] EP-4: `previewCompaction` effect, events, adapter arms, mock, and integration tests complete
- [ ] EP-5: `applyCompactionTx` deletes exactly the accounted rows under ADR-7 locks and writes the ledger
- [ ] EP-5: Idempotent reapply, partial-store refusal, lease refusal, head-drift race, rollback injection, and gap-tolerant reads/appends proven
- [ ] EP-5: Structural gates extended and `just perf-check` unchanged; compaction ADR recorded
- [ ] EP-6: Operator guide, capability record, Haddock, and production guidance published and validated
- [ ] EP-6: `kiroku compaction preview|apply|ledger` and `kiroku store identity` embeddable commands with non-zero refusal exit codes
- [ ] EP-7: Versions, changelogs, blueprint edge, tags, Hackage uploads, GitHub releases
- [ ] EP-7: Clean external consumer proves the released API; IR-14 marked completed


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- The migrations package no longer has a codd expected-schema drift gate or a timestamped
  scaffolder; ExecPlans 66 and 67 describe a superseded world. Authoring is now
  `cabal run kiroku-store-migrate -- new --manifest kiroku-store-migrations/migrations/manifest
  --description "..."`, which emits the next bare number (`0012.sql`), and the schema gate is the
  catalog assertions in `kiroku-store-migrations/test/Main.hs`. EP-1 is written against the
  current tooling.
- The standalone `kiroku` binary has had no database connectivity since `kiroku-cli` 0.2.0.0; it
  is a pure remote client of `kiroku-metrics`. Compaction commands are therefore embeddable-only
  (`renderKirokuCommandWithStore` hosts) and the standalone binary refuses them with guidance;
  no mutating HTTP endpoint is added to the read-only `kiroku-metrics` package.
- `dead_letters.event_id` is a foreign key to `events.event_id`, and there is no public API to
  remove dead letters. A selected event with dead letters can therefore only be compacted if the
  manifest explicitly opts in through `RemoveDeadLetters`; this is why the policy is part of the
  digest-sealed manifest rather than a call-site flag.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into seven ExecPlans in three waves (foundations; preview then apply;
  operator surface then release) rather than one plan or a preview-plus-apply single plan.
  Rationale: Each plan yields an independently testable behaviour; the three foundations share
  no code and can be built in parallel; separating preview from apply makes the "validate
  everything before the first delete" property structural and gives operators a shippable
  dry-run tool; documentation, CLI, and release are operator-facing work that must not block the
  core.
  Date: 2026-08-22

- Decision: Record every applied manifest in an append-only `kiroku.event_compactions` ledger
  keyed by the manifest digest, and use it (not the absence of rows) to recognise an
  already-applied manifest.
  Rationale: IR-14 requires that reapplying a completed manifest is an observable no-op with the
  same logical report while a partially matching store is an error. Absence of rows cannot
  distinguish "applied" from "never existed"; a durable record can. Event-sourcing practice also
  treats a deletion as a fact worth retaining: the ledger is the in-store audit trail the request
  asks for, and it survives process restarts where `KirokuEvent` values do not.
  Date: 2026-08-22

- Decision: Install a store identity (`kiroku.store_identity`) by migration and make the
  manifest name it; a restored clone shares the identity.
  Rationale: The request requires refusal on store-identity mismatch, and Kiroku has no
  identity today. A migration-installed UUID is the smallest durable, schema-owned identity.
  Sharing it with a restored clone is desirable because the consumer's workflow rehearses the
  exact production manifest on a clone before applying it to production.
  Date: 2026-08-22

- Decision: Links are removed only when the manifest explicitly acknowledges them per selection;
  dead letters and causation dependents are governed by manifest-level policies whose defaults
  refuse; every other reference class refuses.
  Rationale: The request forbids silently widening a manifest but permits references the
  manifest "explicitly and safely" accounts for. Putting acknowledgements and policies inside
  the digest-sealed manifest means a reviewer sees every destructive consequence before
  approving the digest, and Kiroku never chooses. Causation IDs are soft references (an
  `EventData.causationId` may already point outside the store), so dangling causation is a
  policy the consumer may accept rather than an invariant Kiroku enforces.
  Date: 2026-08-22

- Decision: Stream-head witnesses are mandatory for every stream a manifest touches and apply
  refuses on drift; compaction never changes `streams.stream_version`.
  Rationale: The request names head drift as a refusal. Because compaction leaves the high-water
  version untouched, witnesses stay valid across a sequence of chunked manifests as long as no
  append intervenes, and an intervening append is exactly the condition a reviewer should
  re-examine.
  Date: 2026-08-22

- Decision: Bound a manifest to `maxCompactionSelections = 100000` selections; larger jobs are
  chunked by the consumer into several manifests, each one transaction.
  Rationale: One transaction per manifest is required; bounded inputs keep lock hold time and
  parameter size predictable and match the bounded-input style of ADR-7's leases. Mori's
  475,058 candidates become at most five manifests.
  Date: 2026-08-22

- Decision: Refusals are returned as `Either (NonEmpty CompactionRefusal) ...` values, not
  thrown as `StoreError`; only connection, transaction, and invariant failures use `StoreError`.
  Rationale: A refusal is an expected, reviewable outcome that operators must inspect in full,
  not an exceptional condition. Preview returns every refusal it can find so one review cycle
  surfaces all problems.
  Date: 2026-08-22

- Decision: Exclude a whole-stream fallback, renumbering, declarative scavenge policies,
  crypto-shredding, filesystem reclamation, a remote apply surface, and a manifest-level
  subscription-checkpoint guard.
  Rationale: The first five are either forbidden by the request or separate capabilities; a
  remote apply would turn the read-only `kiroku-metrics` package into a mutating surface; a
  checkpoint guard encodes consumer policy (ADR-4 leaves checkpoint semantics to consumers) and
  consumers can compose their own check with `applyCompactionTx` in one transaction.
  Date: 2026-08-22

- Decision: Do not add a standalone database-connected `kiroku-admin`/`kiroku-ops` binary; treat
  `mori://shinzui/keiro/packages/keiro-ops` as the downstream standalone host for compaction
  commands once the API is released (see Integration Points, "Downstream standalone operator
  surface").
  Rationale: ExecPlan 52 removed the standalone binary's database mode because the binary runs no
  subscriptions and the in-process case belongs to the embeddable library; keiro-ops already
  provides `--database-url` resolution, stream-name confirmation, `--force`, and preview for
  Kiroku's existing destructive lifecycle commands, and Mori's consumer plan mounts it. Adding a
  second standalone console in kiroku would duplicate those rails and split the operator
  surface.
  Date: 2026-08-22

- Decision: Soft-deleted streams refuse (`CompactionStreamSoftDeleted`); a `truncate_before`
  marker does not affect eligibility.
  Rationale: A soft-deleted stream is an ambiguous topology for a consumer that read it as
  live; refusing is the conservative reading of "unsupported topology". Logically truncated
  events still physically exist and are exactly the rows a consumer may wish to reclaim.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
