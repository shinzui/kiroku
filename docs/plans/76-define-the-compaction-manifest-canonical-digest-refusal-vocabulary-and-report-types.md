---
id: 76
slug: define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types
title: "Define the compaction manifest, canonical digest, refusal vocabulary, and report types"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Define the compaction manifest, canonical digest, refusal vocabulary, and report types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku is an append-only PostgreSQL event store written in Haskell. The MasterPlan at
`docs/masterplans/11-manifest-driven-selective-event-compaction.md` adds a supported way to
physically delete a caller-selected subset of events ("selective compaction") without renumbering
or otherwise disturbing any retained event. Every part of that operation — the read-only preview
(`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`), the
transactional apply (`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md`),
the operator CLI, and the consuming project `mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`
— speaks one vocabulary: an immutable, digest-sealed *compaction manifest* as input, a closed
set of *refusals* as the negative outcome, and a deterministic *report* as the positive outcome.

This plan delivers that vocabulary as a pure Haskell module, `Kiroku.Store.Compaction.Types`,
with no database code at all. After it lands, a developer can open `cabal repl kiroku-store`,
build a manifest from plain values with `mkCompactionManifest`, see it rejected for any of
fifteen typed reasons, obtain its canonical SHA-256 digest, encode it to JSON, decode it back
with the digest re-verified, and run a Hedgehog property suite proving the digest is
deterministic, order-independent, and sensitive to every field. Nothing about the database
changes in this plan; the preview and apply plans build on these types without modifying them.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Confirm `crypton` availability through Mori and the cached build plan; add `crypton` to `kiroku-store` build-depends.
- [ ] M1: Ensure `StoreIdentity` exists in `kiroku-store/src/Kiroku/Store/Types.hs` (add it if `docs/plans/74-...` has not landed).
- [ ] M1: Create `kiroku-store/src/Kiroku/Store/Compaction/Types.hs` with all newtypes, records, sum types, and deriving clauses.
- [ ] M1: Implement validated constructors (`mkCompactionOperation`, `mkCompactionDigest`, `parseCompactionDigestHex`, `compactionDigestHex`, `mkCompactionLedgerLimit`).
- [ ] M1: Implement `mkCompactionManifest` with every `CompactionManifestError` branch and canonical ordering.
- [ ] M1: Register the module in `exposed-modules` and re-export it from `Kiroku.Store`; `cabal build kiroku-store` passes with `-Wall`.
- [ ] M2: Implement `canonicalCompactionManifestBytes`, `compactionManifestDigest`, `canonicalCompactionReportBytes`, `compactionReportDigest`.
- [ ] M2: Add the worked single-selection byte example as a unit test with the exact expected hex digest.
- [ ] M3: Implement hand-written `ToJSON`/`FromJSON` for `CompactionManifest`, `CompactionReport`, `CompactionRecord`, `CompactionRefusal`, and the small enums; `FromJSON CompactionManifest` requires `digest`.
- [ ] M4: Create `kiroku-store/test/Test/CompactionManifest.hs` with unit examples for each error branch and Hedgehog properties.
- [ ] M4: Register `Test.CompactionManifest` in `other-modules` and in `kiroku-store/test/Main.hs`; suite passes.
- [ ] M4: Add the `kiroku-store/CHANGELOG.md` entry under an unreleased heading.
- [ ] M4: Final `cabal build all`, `cabal test kiroku-store:kiroku-store-test`, `nix fmt`, commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Make `CompactionManifest` an abstract type constructed only through
  `mkCompactionManifest`, with read-only accessor functions.
  Rationale: The digest is computed at construction over the canonical form. If consumers could
  build the record directly, a manifest could exist whose stored digest disagrees with its
  content, and every downstream check would have to re-validate. Abstraction makes "a
  `CompactionManifest` value is valid and its digest is correct" a type-level guarantee, the
  same way `HistoryRetentionLeaseOwner` can only be built by `mkHistoryRetentionLeaseOwner`.
  Date: 2026-08-22

- Decision: Fix the canonical encoding as an explicit byte layout (length-prefixed UTF-8,
  big-endian integers, raw UUID bytes) rather than hashing the JSON rendering.
  Rationale: JSON has no canonical form without extra libraries and conventions (key order,
  whitespace, number formatting); a byte layout is reproducible from any language and is
  specified once in the MasterPlan. JSON stays a transport format carrying the digest as data.
  Date: 2026-08-22

- Decision: Use SHA-256 from `crypton` (`Crypto.Hash`), bound `>=1.0 && <1.2`.
  Rationale: `crypton` 1.1.4 is already in the repository's dependency closure through
  `pg-migrate` and `codd-extras`, so adding it to `kiroku-store` adds no new transitive package;
  Mori registers `kazu-yamamoto/crypton` as an active library. The fallback, only if Mori or the
  build plan contradicts this at implementation time, is `cryptohash-sha256`.
  Date: 2026-08-22

- Decision: Sort selections by global position, acknowledged links by (stream name, version),
  and stream-head witnesses by stream name, all in byte order of UTF-8 text, before encoding.
  Rationale: Global positions are unique per event in a store, so they give a total order that
  does not depend on UUID byte order or on how the consumer enumerated candidates; the other two
  orders are the simplest total orders over their keys. Sorting in the constructor means two
  consumers who enumerate the same set in different orders produce the same digest.
  Date: 2026-08-22

- Decision: Bound manifests at `maxCompactionSelections = 100000` and operation labels at 512
  UTF-8 bytes; reject rather than truncate.
  Rationale: Mirrors ADR-7's bounded-input style for lease owners and durations. Bounded
  parameter arrays keep apply's lock hold time predictable; the consumer chunks larger jobs.
  Date: 2026-08-22

- Decision: Treat `CompactionRefusal` and `CompactionReport` as ordinary public records (not
  abstract) while keeping `reportDigest` a derived field recomputed by `compactionReportDigest`.
  Rationale: Refusals and reports are outputs that tests and operators pattern-match and
  construct; an abstract report would only add ceremony. The report digest is deterministic from
  the other fields, so a mismatch is detectable wherever the record travels.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### The repository and the package you are editing

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; every path below is
relative to it. `cabal.project` lists eight packages built with GHC 9.12.4. This plan touches only
`kiroku-store`, the core library. Its library stanza in `kiroku-store/kiroku-store.cabal` has an
explicit `exposed-modules` list (public modules) and an `other-modules` list (internal modules);
a new module must be added to one of them or it will not compile into the package. The package
uses the `GHC2024` language edition with default extensions `DeriveAnyClass`,
`DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and compiles with
`-Wall -Werror=incomplete-patterns`. Because `DuplicateRecordFields` is on, several records may
share field names (for example `stream`); code reads them through `generic-lens` labels
(`value ^. #stream`) or pattern matching, not through bare selector functions.

Public API re-exports live in `kiroku-store/src/Kiroku/Store.hs`, which re-exports whole
modules (`module Kiroku.Store.Types`, `module Kiroku.Store.HistoryRetention`, and so on). A
consumer typically writes `import Kiroku.Store`.

### Existing conventions this plan copies

`Kiroku.Store.HistoryRetention.Types` (`kiroku-store/src/Kiroku/Store/HistoryRetention/Types.hs`)
is the template for this plan's style. It defines newtypes whose constructors are exported but
whose validated values come from smart constructors returning `Either` a typed error, for
example:

```haskell
newtype HistoryRetentionLeaseOwner = HistoryRetentionLeaseOwner Text
    deriving stock (Eq, Ord, Show, Generic)

mkHistoryRetentionLeaseOwner :: Text -> Either HistoryRetentionRequestError HistoryRetentionLeaseOwner
mkHistoryRetentionLeaseOwner value
    | bytes == 0 = Left HistoryRetentionLeaseOwnerEmpty
    | bytes > 512 = Left (HistoryRetentionLeaseOwnerTooLong bytes)
    | otherwise = Right (HistoryRetentionLeaseOwner value)
  where
    bytes = ByteString.length (Text.encodeUtf8 value)
```

Records derive `stock (Eq, Show, Generic)`; sum types used as closed vocabularies derive
`stock (Eq, Show, Generic)` and sometimes `Ord`. Byte lengths are measured on UTF-8 encodings.

The core identity types you will reuse are in `kiroku-store/src/Kiroku/Store/Types.hs`:
`newtype StreamName = StreamName Text`, `newtype StreamId = StreamId Int64`,
`newtype EventId = EventId UUID`, `newtype StreamVersion = StreamVersion Int64` (per-stream
versions are 1-based), and `newtype GlobalPosition = GlobalPosition Int64` (positions in the
global `$all` log, also 1-based). `Kiroku.Store.Error` exports
`validateStreamName :: StreamName -> Either StoreError ()` (rejects the reserved name `$all`
with `ReservedStreamName` and names longer than `maxStreamNameBytes = 512` UTF-8 bytes with
`StreamNameTooLong name bytes`); this plan reuses it so manifest stream names obey the same
rule as append.

`Kiroku.Store.HistoryRetention.Types.HistoryRetentionConflict` (fields `activeLeaseCount ::
Int64`, `earliestExpiry :: UTCTime`) is the value one refusal constructor carries; it already
exists and is not changed.

### Terms used in this plan

A *compaction manifest* ("manifest") is an immutable description of exactly which events a
consumer wants physically deleted, together with enough facts about them that the store can
refuse if anything differs. A *selection* is one entry in the manifest naming one event. A
*witness* is a fact recorded in the manifest that the store will compare against reality: the
event's originating stream, its version in that stream, its global position, and the head version
of each touched stream. A *digest* is a SHA-256 hash; the *root digest* (or *manifest digest*)
is the hash of the manifest's canonical byte encoding and is what an operator approves. A
*derived membership* is one of the two rows every event automatically has in the
`kiroku.stream_events` junction table: its *home* row (`stream_id` equals
`original_stream_id`) and its *global* row (`stream_id = 0`, the `$all` log, whose
`stream_version` is the global position). A *link* is any further junction row created by
`Kiroku.Store.Link.linkToStream`, making the event also visible in another stream at that
stream's own version. An *acknowledged link* is a link the manifest explicitly lists for a
selection, meaning "delete this row too". A *dead letter* is a row in `kiroku.dead_letters`
that a subscription wrote when its handler gave up on an event; it holds a foreign key to the
event. A *causation dependent* of an event is another event whose `causation_id` is this
event's ID. A *refusal* is one typed reason the store will not (or, in preview, would not)
perform a manifest; the set of reasons is closed. A *report* is the deterministic summary of a
manifest's effect: counts, affected stream heads, and a *report digest* over those fields.

### Relevant architecture decisions

`docs/adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md` (ADR-7)
establishes that destructive operations coordinate through a singleton coordinator row, refuse
while any history-retention lease is active, and lock affected streams in ascending `stream_id`
order. This plan contributes the `CompactionHistoryRetentionActive` refusal constructor that the
preview and apply plans use to report ADR-7's lease conflict, and it copies ADR-7's
bounded-input style. `docs/adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md`
(ADR-1) explains why `RecordedEvent` carries `originalStreamId` rather than a name; manifests
therefore carry stream *names* (the stable, human-reviewable identity) and the preview plan
resolves them to IDs. `docs/adr/0005-three-tier-performance-regression-gates.md` (ADR-5) is
not affected by this plan (no database statements), but its structural gate is why the later
plans keep compaction SQL out of ordinary paths. No other ADR is relevant.

The consumer whose needs shaped the manifest is
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`; it
must be able to produce a manifest deterministically from its own review artefacts, so the
JSON codec and the canonical encoding are both part of the public contract.

### The authoritative type specification

The MasterPlan's Integration Points section fixes the types. They are reproduced here so this
plan stands alone; if you find a discrepancy, the MasterPlan wins and you must update it and this
plan together.

```haskell
newtype StoreIdentity = StoreIdentity UUID            -- in Kiroku.Store.Types (owned by docs/plans/74-...)

newtype CompactionOperation = CompactionOperation Text  -- validated 1..512 UTF-8 bytes
newtype CompactionDigest = CompactionDigest ByteString  -- exactly 32 bytes (SHA-256)
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

data CompactionManifest   -- abstract

mkCompactionManifest :: CompactionManifestInput -> Either CompactionManifestError CompactionManifest
compactionManifestDigest :: CompactionManifest -> CompactionDigest
canonicalCompactionManifestBytes :: CompactionManifest -> ByteString
maxCompactionSelections :: Int   -- 100000

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
    , actualGlobalPosition :: !(Maybe GlobalPosition)
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

compactionReportDigest :: CompactionReport -> CompactionDigest

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

Every record derives `stock (Eq, Show, Generic)`; every newtype additionally derives `Ord`;
`DeadLetterPolicy`, `CausationPolicy`, and `CompactionApplyResult` derive `stock (Eq, Show,
Generic)`, the two policies also `Ord` and `Enum, Bounded`.

### The canonical byte encoding

The manifest digest is SHA-256 over the following concatenation. "Length-prefixed UTF-8" means a
4-byte big-endian unsigned byte count followed by the UTF-8 bytes. All integers are big-endian
two's-complement of the declared width.

1. The ASCII bytes `kiroku-compaction-manifest/1` followed by a newline (`0x0a`).
2. The 16 raw bytes of the store identity UUID (`Data.UUID.toByteString`, which is
   network order).
3. The operation label, length-prefixed UTF-8.
4. One byte for the dead-letter policy: `0x00` for `RefuseDeadLetters`, `0x01` for
   `RemoveDeadLetters`.
5. One byte for the causation policy: `0x00` for `RefuseCausationDependents`, `0x01` for
   `AllowDanglingCausation`.
6. A 4-byte count of stream-head witnesses, then each witness in ascending byte order of the
   UTF-8 stream name: the name length-prefixed, then the 8-byte head version.
7. A 4-byte count of selections, then each selection in ascending global position: the 16 raw
   event UUID bytes, the origin stream name length-prefixed, the 8-byte origin version, the
   8-byte global position, a 4-byte count of acknowledged links, and each link in ascending
   (name bytes, version) order as the name length-prefixed then the 8-byte stream version.

The report digest uses the same primitives: the ASCII bytes `kiroku-compaction-report/1` and a
newline; the 32 manifest digest bytes; the 16 store UUID bytes; the operation length-prefixed;
the two policy bytes; then, as 8-byte big-endian integers in this order, `selectedEvents`,
`homeMemberships`, `globalMemberships`, `linkMemberships`, `deadLettersRemoved`,
`causationDependents`, `lowestGlobalPosition`, `highestGlobalPosition`; then the affected
streams encoded exactly like item 6 above (4-byte count, then each as length-prefixed name and
8-byte head version, ascending by name).

Worked example. Take a manifest for store identity
`00000000-0000-7000-8000-000000000001`, operation label `compact`, both policies refusing, one
stream-head witness `orders-1` at head version 7, and one selection: event
`00000000-0000-7000-8000-0000000000aa` originating in `orders-1` at version 3, global position
42, no acknowledged links. Its canonical bytes, shown as hex with one field per line, are:

```text
6b69726f6b752d636f6d70616374696f6e2d6d616e69666573742f310a   "kiroku-compaction-manifest/1\n"
00000000000070008000000000000001                             store identity UUID (16 bytes)
00000007 636f6d70616374                                      len=7, "compact"
00                                                           RefuseDeadLetters
00                                                           RefuseCausationDependents
00000001                                                     1 stream-head witness
00000008 6f72646572732d31                                    len=8, "orders-1"
0000000000000007                                             head version 7
00000001                                                     1 selection
000000000000700080000000000000aa                             event UUID (16 bytes)
00000008 6f72646572732d31                                    len=8, "orders-1"
0000000000000003                                             origin version 3
000000000000002a                                             global position 42
00000000                                                     0 acknowledged links
```

Milestone 2 turns this example into a unit test: it builds the manifest, asserts
`canonicalCompactionManifestBytes` equals exactly these 115 bytes, and pins the SHA-256 of those
bytes as a hex string. Compute the expected hex once at implementation time with a trusted tool
(for example `printf` of the bytes piped to `shasum -a 256`) and record it in the test and in
the Surprises & Discoveries section, so any later change to the layout is caught.


## Plan of Work

### Milestone 1 — Types, validated constructors, and the manifest smart constructor

Goal: the module compiles and `mkCompactionManifest` enforces every rule. At the end of this
milestone a developer can build, reject, and inspect manifests in `cabal repl`, but cannot yet
compute digests (the digest field is filled by Milestone 2; in Milestone 1 use a placeholder
that Milestone 2 replaces, or implement Milestones 1 and 2 in one commit — the plan treats them
as separate proof points only).

Work. First confirm the hashing dependency. Run `mori registry search crypton` and
`mori registry show kazu-yamamoto/crypton --full`; confirm the cached build plan already contains
it with the Python one-liner in Concrete Steps. Add `, crypton >=1.0 && <1.2` to the library
`build-depends` in `kiroku-store/kiroku-store.cabal` (the list is alphabetical; place it after
`containers`). If Mori shows `crypton` as unavailable or the plan lacks it, use
`cryptohash-sha256 >=0.11 && <0.12` and its `Crypto.Hash.SHA256.hash :: ByteString -> ByteString`
instead; record the choice in the Decision Log.

Check whether `newtype StoreIdentity` already exists in `kiroku-store/src/Kiroku/Store/Types.hs`
(`grep -n StoreIdentity kiroku-store/src/Kiroku/Store/Types.hs`). If it does not (the plan
`docs/plans/74-add-a-store-identity-and-an-append-only-event-compaction-ledger.md` owns it but
may land later), add it in the identity-newtypes section, exactly:

```haskell
-- | Identity of one Kiroku store installation, installed by migration @0012@.
newtype StoreIdentity = StoreIdentity UUID
    deriving stock (Eq, Ord, Show, Generic)
```

and export `StoreIdentity (..)` from the module's export list. Do not add anything else from
plan 74.

Create `kiroku-store/src/Kiroku/Store/Compaction/Types.hs`. Its export list names every type from
the specification with constructors (`CompactionSelection (..)`, `CompactionRefusal (..)`, and
so on) except `CompactionManifest`, which is exported without constructors; plus the
constructors and accessors listed under Interfaces and Dependencies. Define the types verbatim
from the specification. Define the abstract manifest as:

```haskell
data CompactionManifest = CompactionManifest
    { manifestStoreIdentity' :: !StoreIdentity
    , manifestOperation' :: !CompactionOperation
    , manifestDeadLetterPolicy' :: !DeadLetterPolicy
    , manifestCausationPolicy' :: !CausationPolicy
    , manifestStreamHeads' :: !(Vector StreamHeadWitness)
    , manifestSelections' :: !(Vector CompactionSelection)
    , manifestDigest' :: !CompactionDigest
    }
    deriving stock (Eq, Show, Generic)
```

and expose accessors `manifestStoreIdentity`, `manifestOperation`, `manifestDeadLetterPolicy`,
`manifestCausationPolicy`, `manifestStreamHeads`, `manifestSelections`, `manifestDigest` (the
last one is a synonym of `compactionManifestDigest`, kept so the accessor family reads
uniformly), plus the derived `manifestStreamNames :: CompactionManifest -> Vector Text`, the
ascending stream names of every head witness, which by construction is exactly the set of
streams the manifest touches (origins, acknowledged link targets, and witnesses coincide). The
apply plan passes it to its `FOR UPDATE` lock statement.

Implement the small validated constructors:

```haskell
mkCompactionOperation :: Text -> Either CompactionManifestError CompactionOperation
-- empty -> CompactionManifestOperationEmpty; > 512 UTF-8 bytes -> CompactionManifestOperationTooLong bytes

compactionOperationText :: CompactionOperation -> Text

mkCompactionDigest :: ByteString -> Maybe CompactionDigest          -- Just only for exactly 32 bytes
compactionDigestBytes :: CompactionDigest -> ByteString
compactionDigestHex :: CompactionDigest -> Text                     -- 64 lowercase hex characters
parseCompactionDigestHex :: Text -> Maybe CompactionDigest          -- accepts upper or lower case

mkCompactionLedgerLimit :: Int32 -> Either CompactionLedgerError CompactionLedgerLimit
compactionLedgerLimitValue :: CompactionLedgerLimit -> Int32
data CompactionLedgerError = CompactionLedgerLimitOutOfRange !Int32
```

Hex rendering needs no extra dependency: use `Data.ByteString.Builder.byteStringHex` or a hand
rolled `Text.pack . concatMap (printf "%02x")`; parsing can fold over pairs of characters with
`Data.Char.digitToInt` after checking `isHexDigit`.

Implement `mkCompactionManifest`. It validates in this order and returns the first failure:

1. `selections` empty → `CompactionManifestEmpty`.
2. `length selections > maxCompactionSelections` → `CompactionManifestTooLarge n`.
3. Operation: already validated by `mkCompactionOperation`, nothing to do (the field is the
   validated newtype).
4. For every selection: `validateStreamName originStream` → `Left (ReservedStreamName _)`
   becomes `CompactionManifestReservedStream name`, `Left (StreamNameTooLong _ bytes)` becomes
   `CompactionManifestInvalidStreamName name bytes`; `originVersion < 1` →
   `CompactionManifestNonPositiveVersion eventId`; `globalPosition < 1` →
   `CompactionManifestNonPositivePosition eventId`. For every acknowledged link: the same
   stream-name checks; `streamVersion < 1` → `CompactionManifestNonPositiveVersion eventId`;
   link stream equal to the origin stream → `CompactionManifestLinkIntoOrigin eventId`;
   duplicate `(stream, streamVersion)` within one selection →
   `CompactionManifestDuplicateLink eventId link`.
5. Duplicate `eventId` across selections → `CompactionManifestDuplicateEvent eventId`
   (detect with a `Set`). Duplicate global position across selections is also a
   `CompactionManifestDuplicateEvent` of the later event, because two events cannot share a
   position; document this in the Haddock.
6. Stream heads: the same stream-name checks on each witness (`CompactionManifestReservedStream`
   / `CompactionManifestInvalidStreamName`); a name appearing twice →
   `CompactionManifestDuplicateStreamHead name`; the set of witness names must equal the set of
   all origin streams and all acknowledged-link streams: a touched stream with no witness →
   `CompactionManifestMissingStreamHead name`; a witness for an untouched stream →
   `CompactionManifestUnusedStreamHead name`. Head versions may be 0 (a stream with a head of
   0 cannot contain a selected event, so preview will refuse it, but the manifest itself is well
   formed).
7. Canonicalise: sort selections by `globalPosition`, each selection's links by
   `(stream, streamVersion)` comparing stream names as UTF-8 byte strings
   (`Data.Text.Encoding.encodeUtf8`, then `compare`), and stream heads by name bytes. Convert
   the lists to `Vector`s.
8. Compute the digest (Milestone 2). If `expectedDigest` is `Just d` and `d` differs from the
   computed digest → `CompactionManifestDigestMismatch { expected = d, computed }`.

Why byte order rather than `Text`'s `Ord`: `Data.Text` compares by code point, which happens to
coincide with UTF-8 byte order for valid text, but stating "UTF-8 byte order" makes the
specification portable to other languages without that knowledge; implement it as byte
comparison to be safe.

Register the module under `exposed-modules` in `kiroku-store/kiroku-store.cabal` (alphabetically
between `Kiroku.Store.Causation` and `Kiroku.Store.Connection`: `Kiroku.Store.Compaction.Types`).
Add `module Kiroku.Store.Compaction.Types` to the export list and imports of
`kiroku-store/src/Kiroku/Store.hs`. Note in a comment that
`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md` will
create `Kiroku.Store.Compaction`, which re-exports this module, and will switch the umbrella
re-export to that module.

Result and proof: `cabal build kiroku-store` succeeds with no warnings, and in
`cabal repl kiroku-store` the session in Validation and Acceptance behaves as shown.

### Milestone 2 — Canonical encoding and digests

Goal: `canonicalCompactionManifestBytes`, `compactionManifestDigest`,
`canonicalCompactionReportBytes`, and `compactionReportDigest` exist and match the specified
byte layout exactly.

Work. Implement the encoders with `Data.ByteString.Builder`:

```haskell
import Data.ByteString.Builder (Builder, byteString, int64BE, word32BE, word8, toLazyByteString)

lengthPrefixed :: Text -> Builder
lengthPrefixed text =
    let bytes = Text.encodeUtf8 text
     in word32BE (fromIntegral (ByteString.length bytes)) <> byteString bytes

uuidBytes :: UUID -> Builder
uuidBytes = lazyByteString . UUID.toByteString   -- 16 bytes, network order

canonicalCompactionManifestBytes :: CompactionManifest -> ByteString
canonicalCompactionManifestBytes manifest =
    toStrict . toLazyByteString $
        byteString "kiroku-compaction-manifest/1\n"
            <> uuidBytes storeUuid
            <> lengthPrefixed (compactionOperationText operation)
            <> word8 (policyByte deadLetterPolicy)
            <> word8 (policyByte causationPolicy)
            <> counted streamHeads headWitness
            <> counted selections selection
  where
    counted vector encode = word32BE (fromIntegral (Vector.length vector)) <> foldMap encode vector
    headWitness StreamHeadWitness{stream = StreamName name, headVersion = StreamVersion v} =
        lengthPrefixed name <> int64BE v
    selection CompactionSelection{..} =
        uuidBytes eid <> lengthPrefixed originName <> int64BE originV <> int64BE pos
            <> counted acknowledgedLinks link
    link LinkWitness{stream = StreamName name, streamVersion = StreamVersion v} =
        lengthPrefixed name <> int64BE v
```

(The sketch elides the pattern bindings; write them out with explicit field patterns because
`DuplicateRecordFields` makes bare selectors ambiguous.) `policyByte` maps the refuse
constructors to `0` and the permissive ones to `1`. Since the vectors were sorted by
`mkCompactionManifest`, the encoder does not sort again.

`compactionManifestDigest` hashes those bytes:

```haskell
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)

sha256 :: ByteString -> CompactionDigest
sha256 bytes = CompactionDigest (convert (hash bytes :: Digest SHA256))
```

(`Data.ByteArray` is from the `memory` package, which `crypton` re-exports transitively; add
`memory >=0.18 && <0.19` to build-depends if the import does not resolve.) Wire the digest into
`mkCompactionManifest` step 8.

Implement `canonicalCompactionReportBytes :: CompactionReport -> ByteString` and
`compactionReportDigest` per the report layout (prefix, manifest digest bytes, store UUID,
operation, two policy bytes, eight `int64BE` values in declaration order, then the affected
streams as a counted list of head witnesses). `compactionReportDigest` ignores the record's own
`reportDigest` field. Provide `sealCompactionReport :: CompactionReport -> CompactionReport`
that sets `reportDigest` from the other fields; the preview plan calls it once after filling the
counts.

Result and proof: the worked-example unit test in `Test.CompactionManifest` passes with the
pinned hex, and `compactionManifestDigest` equals `manifestDigest`.

### Milestone 3 — JSON codec

Goal: manifests, reports, records, and refusals travel as JSON with stable snake_case keys, and
decoding a manifest re-validates it and its digest.

Work. Write hand-written `ToJSON` and `FromJSON` instances (no generic deriving, so key names
are explicit and stable) in `Kiroku.Store.Compaction.Types`. Key layouts:

```json
{
  "format": "kiroku-compaction-manifest/1",
  "store_identity": "00000000-0000-7000-8000-000000000001",
  "operation": "compact",
  "dead_letter_policy": "refuse",
  "causation_policy": "refuse",
  "stream_heads": [ { "stream": "orders-1", "head_version": 7 } ],
  "selections": [
    {
      "event_id": "00000000-0000-7000-8000-0000000000aa",
      "origin_stream": "orders-1",
      "origin_version": 3,
      "global_position": 42,
      "acknowledged_links": [ { "stream": "audit-2026", "stream_version": 9 } ]
    }
  ],
  "digest": "<64 lowercase hex characters>"
}
```

`ToJSON CompactionManifest` emits the canonical (sorted) order and the hex digest. `FromJSON
CompactionManifest` parses the fields into a `CompactionManifestInput` with `expectedDigest =
Just parsedDigest` (the `digest` key is required; a missing key fails with the message
`compaction manifest requires a digest`), then calls `mkCompactionManifest`, turning a `Left`
into a parse failure whose message is the `show` of the `CompactionManifestError`. `format` is
required and must equal the string above. Policy strings are `refuse`/`remove` for dead letters
and `refuse`/`allow` for causation (the same words the ledger table stores).

`CompactionReport` keys: `manifest_digest`, `store_identity`, `operation`, `dead_letter_policy`,
`causation_policy`, `selected_events`, `home_memberships`, `global_memberships`,
`link_memberships`, `dead_letters_removed`, `causation_dependents`, `lowest_global_position`,
`highest_global_position`, `affected_streams` (array of `{stream, head_version}`),
`report_digest`. `FromJSON CompactionReport` recomputes the report digest and fails with
`compaction report digest mismatch` if it differs from `report_digest`.

`CompactionRecord` keys: `compaction_id`, `report` (nested object), `applied_at` (ISO-8601 as
Aeson renders `UTCTime`), `applied_by`.

`CompactionRefusal` is tagged: `{"refusal": "<constructor-name-in-snake_case>", ...fields}`,
for example `{"refusal": "stream_head_drift", "stream": "orders-1", "expected": 7, "actual": 9}`
and `{"refusal": "history_retention_active", "active_lease_count": 2, "earliest_expiry":
"..."}`. Provide `FromJSON` too, so the CLI can round-trip refusal lists.

Result and proof: the JSON round-trip properties in Milestone 4 pass, and the example manifest
above decodes to a value whose digest equals the `digest` key.

### Milestone 4 — Property and unit tests, registration, changelog

Goal: the behaviour is proven and the module is part of the public surface with a changelog
entry.

Work. Create `kiroku-store/test/Test/CompactionManifest.hs` exporting `spec :: Spec`. It needs no
database, so it does not use `withTestStore`. Use `hspec-hedgehog` (`hedgehog`, and
`modifyMaxSuccess` to raise the count to 200 for the cheap pure properties) exactly as
`kiroku-store/test/Test/Properties.hs` does. Generators: stream names from a small alphabet of
valid names (for example `Gen.element ["orders-1", "orders-2", "audit-2026", "ψ-stream"]` — include
a non-ASCII name so UTF-8 byte ordering is exercised), UUIDs from `Gen.word64` pairs via
`Data.UUID.fromWords64`, positive versions and positions from `Gen.int64 (Range.linear 1
1_000_000)`, selections with unique event IDs and unique global positions (generate a set then
assign), links into streams other than the origin, and stream heads derived from the touched set
(so generated inputs are valid by construction). A `genValidInput :: Gen CompactionManifestInput`
and a `shuffle` helper (`Gen.shuffle`) drive the properties.

Properties to implement: the digest of a valid input is the same across two calls
(determinism); shuffling `selections`, each selection's `acknowledgedLinks`, and `streamHeads`
before construction yields the same digest (order independence); for a valid manifest, any
single mutation — change the operation label, flip either policy, change one head version, change
one selection's origin version, global position, event ID, or origin stream (adjusting heads to
stay valid), add or remove one acknowledged link — changes the digest (sensitivity); `decode .
encode` on a valid manifest returns `Right` a manifest whose digest and canonical bytes equal the
original (JSON round trip); flipping one hex character of the `digest` key in the encoded JSON
makes decoding fail with a message containing `CompactionManifestDigestMismatch` (corruption
detection); `decode . encode` on a report and on a record round-trips (`Eq`).

Unit examples, one per error branch, each asserting the exact `Left` value: empty selections;
`maxCompactionSelections + 1` selections (build with `replicate` over distinct positions — cheap
enough, but keep it to one example); duplicate event ID; `$all` as an origin, as a link target,
and as a head witness; a 513-byte stream name; version 0; position 0; duplicate link; link into
origin; missing head; unused head; duplicate head; empty operation; 513-byte operation; expected
digest mismatch. Plus the worked-example bytes test from Milestone 2, and hex rendering/parsing
tests (`parseCompactionDigestHex` round-trips and rejects 63 characters or a non-hex character).

Register the module: add `Test.CompactionManifest` to `other-modules` of the
`kiroku-store-test` suite in `kiroku-store/kiroku-store.cabal` (alphabetical, after
`Test.Causation`) and add `CompactionManifest.spec` to the spec list in
`kiroku-store/test/Main.hs` (for example after `Causation.spec`; it is not database-backed, so
it must not go inside the trailing `around withTestStore` block).

Add to `kiroku-store/CHANGELOG.md`, under a new `## Unreleased` heading at the top if one does
not exist (the release plan `docs/plans/80-...` renames it), a `### New Features` bullet
describing `Kiroku.Store.Compaction.Types`: the manifest, its validation, the canonical
digest, the closed refusal and report types, and the JSON codec, noting that preview and apply
follow in later releases of the same cohort.

Result and proof: `cabal test kiroku-store:kiroku-store-test --test-options='--match
"compaction manifest"'` reports all examples and properties passing; `cabal build all` is
warning-free; `nix fmt` changes nothing.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

Confirm the hashing dependency:

```bash
mori registry search crypton
mori registry show kazu-yamamoto/crypton --full | head -30
python3 - <<'EOF'
import json
plan = json.load(open('dist-newstyle/cache/plan.json'))
print(sorted({(u['pkg-name'], u['pkg-version']) for u in plan['install-plan']
              if u['pkg-name'] in ('crypton', 'memory')}))
EOF
```

Expected: Mori lists `kazu-yamamoto/crypton` as an active library and the plan prints
`[('crypton', '1.1.4'), ('memory', '0.18.0')]` (versions may be newer). If
`dist-newstyle/cache/plan.json` does not exist, run `cabal build all --dry-run` first.

Check for the soft dependency:

```bash
grep -n "StoreIdentity" kiroku-store/src/Kiroku/Store/Types.hs || echo "add StoreIdentity (see Milestone 1)"
```

Build after each milestone:

```bash
cabal build kiroku-store
cabal build all
```

Run only this plan's tests, then the whole store suite:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "compaction manifest"'
cabal test kiroku-store:kiroku-store-test
```

Expected tail of the focused run:

```text
compaction manifest
  mkCompactionManifest
    rejects an empty selection list [✔]
    ...
  canonical encoding
    encodes the worked example byte for byte [✔]
    pins the worked example digest [✔]
  properties
    digest is deterministic [✔]
      ✓ digest is deterministic passed 200 tests.
    digest is independent of input order [✔]
    ...
Finished in 1.2 seconds
NN examples, 0 failures
```

Format and commit:

```bash
nix fmt
git add kiroku-store/kiroku-store.cabal kiroku-store/src/Kiroku/Store.hs \
  kiroku-store/src/Kiroku/Store/Types.hs kiroku-store/src/Kiroku/Store/Compaction/Types.hs \
  kiroku-store/test/Test/CompactionManifest.hs kiroku-store/test/Main.hs kiroku-store/CHANGELOG.md \
  docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md
git commit
```

Every commit message carries the three trailers. Example:

```text
feat(store): add the compaction manifest, digest, refusal, and report types

Introduce Kiroku.Store.Compaction.Types: a digest-sealed abstract
CompactionManifest built only by mkCompactionManifest, the canonical
SHA-256 byte encoding, the closed CompactionRefusal vocabulary, the
deterministic CompactionReport with its own digest, and a snake_case
JSON codec that re-validates the digest on decode.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/76-define-the-compaction-manifest-canonical-digest-refusal-vocabulary-and-report-types.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

Acceptance is behavioural. In `cabal repl kiroku-store` after Milestone 2:

```haskell
import Kiroku.Store
import Data.Maybe (fromJust)
import Data.UUID qualified as UUID
let sid = StoreIdentity (fromJust (UUID.fromString "00000000-0000-7000-8000-000000000001"))
let Right op = mkCompactionOperation "compact"
let sel = CompactionSelection (EventId (fromJust (UUID.fromString "00000000-0000-7000-8000-0000000000aa"))) (StreamName "orders-1") (StreamVersion 3) (GlobalPosition 42) mempty
let input = CompactionManifestInput sid op RefuseDeadLetters RefuseCausationDependents [StreamHeadWitness (StreamName "orders-1") (StreamVersion 7)] [sel] Nothing
let Right m = mkCompactionManifest input
compactionDigestHex (compactionManifestDigest m)
-- "<the pinned 64-hex digest of the worked example>"
mkCompactionManifest input { selections = [] }
-- Left CompactionManifestEmpty
mkCompactionManifest input { streamHeads = [] }
-- Left (CompactionManifestMissingStreamHead (StreamName "orders-1"))
mkCompactionManifest input { selections = [sel, sel] }
-- Left (CompactionManifestDuplicateEvent (EventId 00000000-0000-7000-8000-0000000000aa))
```

Encoding then decoding with Aeson returns an equal manifest; editing the `digest` key fails:

```haskell
import Data.Aeson qualified as Aeson
Aeson.eitherDecode (Aeson.encode m) == Right m
-- True
```

The test suite is the authoritative acceptance: every `CompactionManifestError` constructor has
an example that produces it, every property passes at 200 cases, the worked-example bytes and
digest are pinned, and `cabal test all` still passes in full (no other suite is affected because
no database behaviour changed).


## Idempotence and Recovery

Every step is a pure source edit; re-running builds and tests is always safe. If the pinned
worked-example digest disagrees with the implementation, do not change the pin to match — first
compare `canonicalCompactionManifestBytes` against the hex table in Context and Orientation
field by field, since the pin is derived from that table with an independent tool. If
`crypton` fails to resolve, switch to the documented fallback and record it in the Decision Log;
no other code depends on which hashing package is used. If plan 74 lands after this plan and
also adds `StoreIdentity`, Git will report a conflict on `Types.hs`; keep a single definition
matching the text in Milestone 1.


## Interfaces and Dependencies

Libraries: `crypton` (`Crypto.Hash` for `SHA256`), `memory` (`Data.ByteArray.convert`),
`bytestring` (`Data.ByteString.Builder`), `text`, `uuid` (`Data.UUID.toByteString`,
`fromByteString`, `toText`, `fromText`), `vector`, `containers` (`Data.Set` for duplicate
detection), `aeson`; test side `hspec`, `hspec-hedgehog`, `hedgehog`. All but `crypton`
(and possibly `memory`) are already in `kiroku-store`'s build-depends.

Module `Kiroku.Store.Compaction.Types` (exposed) must export, at the end of Milestone 4:

```haskell
-- types (constructors exported unless noted)
CompactionOperation, mkCompactionOperation, compactionOperationText,
CompactionDigest, mkCompactionDigest, compactionDigestBytes, compactionDigestHex, parseCompactionDigestHex,
CompactionId (..),
LinkWitness (..), StreamHeadWitness (..),
CompactionSelection (..),
DeadLetterPolicy (..), CausationPolicy (..),
CompactionManifestInput (..),
CompactionManifest,                      -- abstract
mkCompactionManifest,
manifestStoreIdentity, manifestOperation, manifestDeadLetterPolicy, manifestCausationPolicy,
manifestStreamHeads, manifestSelections, manifestStreamNames, manifestDigest,
compactionManifestDigest, canonicalCompactionManifestBytes, maxCompactionSelections,
CompactionManifestError (..),
CompactionRefusal (..), WitnessMismatch (..),
CompactionReport (..), compactionReportDigest, canonicalCompactionReportBytes, sealCompactionReport,
CompactionRecord (..), CompactionApplyResult (..),
CompactionLedgerLimit, mkCompactionLedgerLimit, compactionLedgerLimitValue,
CompactionLedgerQuery (..), CompactionLedgerError (..)
```

with signatures:

```haskell
mkCompactionOperation :: Text -> Either CompactionManifestError CompactionOperation
compactionOperationText :: CompactionOperation -> Text
mkCompactionDigest :: ByteString -> Maybe CompactionDigest
compactionDigestBytes :: CompactionDigest -> ByteString
compactionDigestHex :: CompactionDigest -> Text
parseCompactionDigestHex :: Text -> Maybe CompactionDigest
mkCompactionManifest :: CompactionManifestInput -> Either CompactionManifestError CompactionManifest
manifestStoreIdentity :: CompactionManifest -> StoreIdentity
manifestOperation :: CompactionManifest -> CompactionOperation
manifestDeadLetterPolicy :: CompactionManifest -> DeadLetterPolicy
manifestCausationPolicy :: CompactionManifest -> CausationPolicy
manifestStreamHeads :: CompactionManifest -> Vector StreamHeadWitness
manifestSelections :: CompactionManifest -> Vector CompactionSelection
manifestStreamNames :: CompactionManifest -> Vector Text   -- ascending; the heads' stream names
manifestDigest :: CompactionManifest -> CompactionDigest
compactionManifestDigest :: CompactionManifest -> CompactionDigest
canonicalCompactionManifestBytes :: CompactionManifest -> ByteString
maxCompactionSelections :: Int
compactionReportDigest :: CompactionReport -> CompactionDigest
canonicalCompactionReportBytes :: CompactionReport -> ByteString
sealCompactionReport :: CompactionReport -> CompactionReport
mkCompactionLedgerLimit :: Int32 -> Either CompactionLedgerError CompactionLedgerLimit
compactionLedgerLimitValue :: CompactionLedgerLimit -> Int32
```

Instances: `ToJSON`/`FromJSON` for `CompactionManifest`, `CompactionReport`,
`CompactionRecord`, `CompactionRefusal`, `WitnessMismatch`, `LinkWitness`,
`StreamHeadWitness`, `CompactionSelection`, `DeadLetterPolicy`, `CausationPolicy`,
`CompactionDigest` (hex string), `CompactionId` (UUID string), `StoreIdentity` (UUID string;
define the instance here, orphan-free, only if `Kiroku.Store.Types` does not already provide
one — coordinate with `docs/plans/74-...`, which is told to leave JSON instances to this plan).

`Kiroku.Store` re-exports `module Kiroku.Store.Compaction.Types` until
`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`
replaces that line with `module Kiroku.Store.Compaction`.

Consumers of this module: `docs/plans/77-...` (preview), `docs/plans/78-...` (apply and
ledger), `docs/plans/79-...` (CLI JSON manifests), `docs/plans/80-...` (clean-consumer
witness program), and the external consumer
`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`.
