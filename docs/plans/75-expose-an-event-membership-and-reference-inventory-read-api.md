---
id: 75
slug: expose-an-event-membership-and-reference-inventory-read-api
title: "Expose an event membership and reference inventory read API"
kind: exec-plan
created_at: 2026-08-22T14:06:35Z
intention: "intention_01m0mwdmnfex3tv9fg0t57htfv"
master_plan: "docs/masterplans/11-manifest-driven-selective-event-compaction.md"
---

# Expose an event membership and reference inventory read API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This plan is child EP-2 of the MasterPlan
`docs/masterplans/11-manifest-driven-selective-event-compaction.md`. Every commit made while
working on it carries three git trailers: `MasterPlan:`, `ExecPlan:`, and `Intention:` (see
Concrete Steps for the exact text).


## Purpose / Big Picture

Kiroku stores each event once in the `events` table and records *where that event is visible*
as rows in the `stream_events` junction table. Every event has at least two such rows: one in
its home stream (the stream it was appended to) and one in the global `$all` log (stream id
`0`, whose per-stream version is the event's global position). Linking an event into another
stream adds a third kind of row. Other tables can also point at an event: a subscription that
gave up on an event records a *dead letter* row referencing it, and any later event may carry
the event's id as its *causation id* (a soft pointer saying "this event was caused by that
one"). Today a consumer can ask "does event X exist in stream S?" one pair at a time
(`eventExistsInStream`), but nothing answers "everything that refers to event X" — which is
exactly what a tool needs before it can safely remove events.

After this plan, `lookupEventReferences :: [EventId] -> Eff es (Map EventId
EventReferenceInventory)` (and a transaction-composable `lookupEventReferencesTx`) returns, for
each requested event that exists, its complete list of memberships — each tagged as home,
global, or link, with the stream's name, surrogate id, and the version the event holds in that
stream — plus the number of dead-letter rows referencing it and the number of *other* events
whose causation id points to it. Unknown ids are simply absent from the map, and an empty
request performs no database work at all.

You can see it working by appending an event to stream `order-1`, linking it into
`audit-2026`, inserting a dead letter for it, appending a second event whose causation id is
the first, and calling `lookupEventReferences [firstId]`: the result holds three memberships
(home `order-1` at version 1, global `$all` at the event's global position, link `audit-2026`
at version 1), `deadLetterCount = 1`, and `causationDependentCount = 1`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `EventMembershipKind`, `EventMembership`, `EventReferenceInventory` to `Kiroku.Store.Types` with Haddock.
- [ ] M1: Add `eventMembershipsStmt`, `deadLetterCountsStmt`, `causationDependentCountsStmt` to `Kiroku.Store.SQL` under a new export group.
- [ ] M1: Add `LookupEventReferences` to the `Store` effect and its interpreter arm (empty input short-circuits; three statements on one checkout).
- [ ] M1: Add `Kiroku.Store.Read.lookupEventReferences` and `Kiroku.Store.Transaction.lookupEventReferencesTx`, sharing one pure assembly function.
- [ ] M2: Write `kiroku-store/test/Test/EventReferences.hs` covering every membership and reference case plus the no-checkout property.
- [ ] M2: Write `kiroku-store/test/Test/EventReferencesMock.hs`; register both modules in the cabal file and `test/Main.hs`.
- [ ] M2: Add the `eventMembershipsStmt` query-plan example to `Test.PerformanceStructure` under the `performance structure` describe.
- [ ] M2: Run the store suite and `just perf-structure`.
- [ ] M3: Add the unreleased changelog entry, run `cabal build all`, `cabal test all`, `nix fmt`, `nix flake check`; commit with trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Expose the inventory as a public read API rather than keeping the statements
  private to the compaction preview that will reuse them.
  Rationale: The consumer that motivated the initiative
  (`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`)
  must enumerate an event's links and references *before* it can construct a manifest, and it
  must not query Kiroku's private tables to do so. A public inventory is also the natural
  building block for the browse-style read requests already filed against Kiroku.
  Date: 2026-08-22

- Decision: Classify memberships in Haskell from `(stream_id, original_stream_id)` rather than
  in SQL: `stream_id = 0` is global, `stream_id = original_stream_id` is home, anything else is
  a link.
  Rationale: The classification is a two-comparison function of columns the statement already
  returns; keeping SQL flat makes the statement's plan trivially indexable and the rule
  testable as a pure function.
  Date: 2026-08-22

- Decision: Count causation dependents *outside* the requested set only, and count dead
  letters across all subscriptions.
  Rationale: The inventory exists to answer "what would dangle if these events vanished". A
  dependent that is itself in the requested set would vanish too, so it is not a surviving
  reference; a dead letter is a foreign-key reference regardless of which subscription wrote
  it.
  Date: 2026-08-22

- Decision: Report memberships in soft-deleted streams with the stream's name, exactly like
  live streams, and do not filter them.
  Rationale: Physical rows exist whether or not the stream is soft-deleted; a caller deciding
  whether an event may be removed needs the physical truth. Stream state is available through
  `getStream` when needed.
  Date: 2026-08-22

- Decision: Three statements on one pool checkout (memberships, dead-letter counts, causation
  counts) rather than one combined statement.
  Rationale: Each statement has an obvious single-index plan; combining them would force a
  join or a set of lateral subqueries whose plan is harder to keep stable, and the operation is
  an operator/maintenance read, not a hot path. The transaction combinator runs the same three
  statements inside the caller's transaction.
  Date: 2026-08-22


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

### Repository shape

The repository root is a Cabal multi-package project (`cabal.project`, GHC 9.12.4). This plan
touches only `kiroku-store`: library source under `kiroku-store/src/Kiroku/Store/`, the single
test suite `kiroku-store:kiroku-store-test` under `kiroku-store/test/`, module list in
`kiroku-store/kiroku-store.cabal`. The root `justfile` wraps common commands. Tests start their
own PostgreSQL through the `ephemeral-pg` library via `kiroku-test-support`; no `DATABASE_URL`
is needed.

### The schema facts this plan depends on

Defined by `kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`:

`streams (stream_id BIGSERIAL PRIMARY KEY, stream_name TEXT UNIQUE, stream_version BIGINT,
deleted_at TIMESTAMPTZ, truncate_before BIGINT, ...)`. The row with `stream_id = 0` is the
reserved global stream named `$all`. `deleted_at IS NOT NULL` means soft-deleted.

`events (event_id UUID PRIMARY KEY, event_type TEXT, causation_id UUID, correlation_id UUID,
data JSONB, metadata JSONB, created_at TIMESTAMPTZ)`. `causation_id` is nullable and carries no
foreign key; it is indexed by the partial index `ix_events_causation_id` (`WHERE causation_id
IS NOT NULL`).

`stream_events (event_id UUID REFERENCES events, stream_id BIGINT REFERENCES streams,
stream_version BIGINT, original_stream_id BIGINT, original_stream_version BIGINT,
PRIMARY KEY (event_id, stream_id))`. For a home row `stream_id = original_stream_id` and
`stream_version = original_stream_version`. For the global row `stream_id = 0` and
`stream_version` is the global position. For a link row (created by
`Kiroku.Store.Link.linkToStream`) `stream_id` is the target stream and `original_*` still name
the origin, because the link SQL copies them from any existing non-global row of the event — so
a link of a link also records the true origin. The primary key `stream_events_pkey` on
`(event_id, stream_id)` is the index that serves "all rows for these event ids".

`dead_letters (dead_letter_id BIGSERIAL, subscription_name TEXT, consumer_group_member INT,
global_position BIGINT, event_id UUID NOT NULL REFERENCES kiroku.events(event_id), reason JSONB,
...)` from migration `0002`, with index `ix_dead_letters_event_id` on `event_id` from `0004`.

All statements in `kiroku-store/src/Kiroku/Store/SQL.hs` use unqualified table names; the
connection's `search_path` is set from `ConnectionSettings.schema` (see ADR-3 below).

### The `Store` effect, wrappers, and the batch-lookup precedent

`kiroku-store/src/Kiroku/Store/Effect.hs` defines `data Store :: Effect where ...` (the
`effectful` library's dynamic effect: a GADT of operations that programs `send` and an
interpreter handles) and the production interpreter `runStorePool`, a large
`interpret_ $ \case` over every constructor. The closest precedent for this plan is
`LookupStreamNames :: [StreamId] -> Store m (Map StreamId StreamName)`, whose interpreter arms
are:

```haskell
    LookupStreamNames [] ->
        pure Map.empty
    LookupStreamNames sids ->
        fmap
            (Map.fromList . map (\(s, nm) -> (StreamId s, StreamName nm)) . V.toList)
            ( usePool (store ^. #pool) $
                Session.statement [s | StreamId s <- sids] SQL.lookupStreamNamesStmt
            )
```

The empty-input arm is deliberate: it returns without touching the pool, and a structural test
(`Test.StreamNameLookup.noOpSpec`) counts pool checkouts through the `observationHandler`
setting to prove it. Copy both the arm shape and the test shape.

`usePool :: Pool -> Session.Session a -> Eff es a` runs a `hasql` session on one pooled
connection and maps failures to `StoreError`; several `Session.statement` calls sequenced in
one `Session` share that connection. Public wrappers are one-liners in
`kiroku-store/src/Kiroku/Store/Read.hs` (for example `lookupStreamNames sids = send
(LookupStreamNames sids)`) with Haddock that explains the contract. Transaction combinators
live in `kiroku-store/src/Kiroku/Store/Transaction.hs` and are plain `Tx.Transaction` values
built from `Tx.statement`. `kiroku-store/src/Kiroku/Store.hs` re-exports `Kiroku.Store.Read`,
`Kiroku.Store.Transaction`, and `Kiroku.Store.Types` wholesale, so new exports there are public
automatically.

Types live in `kiroku-store/src/Kiroku/Store/Types.hs` with an explicit export list;
`newtype StreamId = StreamId Int64`, `newtype StreamName = StreamName Text`, `newtype EventId =
EventId UUID`, `newtype StreamVersion = StreamVersion Int64`, `newtype GlobalPosition =
GlobalPosition Int64`. The package enables `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`, `DeriveAnyClass` and compiles with `-Wall -Werror=incomplete-patterns`;
records are accessed with `generic-lens` labels such as `event ^. #eventId`.

### Tests

`kiroku-store/test/Main.hs` is `main = withSharedMigratedPostgres $ hspec $ do ...` and lists
every spec; `kiroku-store/kiroku-store.cabal` lists every test module under `other-modules`.
The fixture `Test.Helpers.withTestStore :: (KirokuStore -> IO ()) -> IO ()` gives each example a
fresh migrated database; `withTestStoreSettings` accepts a `ConnectionSettings ->
ConnectionSettings` tweak. Useful helpers already exported by `Test.Helpers`: `makeEvent ::
Text -> Value -> EventData`, `insertDeadLetterForEvent :: KirokuStore -> Text -> RecordedEvent
-> IO ()` (inserts one dead-letter row for subscription name and event),
`countDeadLettersForEvents`. Store calls in tests go through `runStoreIO store :: Eff '[Store,
Error StoreError, IOE] a -> IO (Either StoreError a)`; tests typically pattern-match `Right x <-
runStoreIO store ...`.

The checkout-counting pattern, from `kiroku-store/test/Test/PerformanceStructure.hs`:

```haskell
withObservedStore :: IORef Int -> (KirokuStore -> IO ()) -> IO ()
withObservedStore checkouts =
    withTestStoreSettings $ \settings ->
        settings
            { observationHandler = Just $ \case
                ConnectionObservation _ InUseConnectionStatus -> modifyIORef' checkouts (+ 1)
                _ -> pure ()
            }
```

Mock interpreters follow `kiroku-store/test/Test/VisibleGlobalHeadPositionMock.hs`: an
`interpret_ $ \case` handling only the constructor under test, counting dispatches in an
`IORef`, ending with `_ -> error "unexpected Store operation in ... mock"`.

The structural performance gate is the `describe "performance structure"` block in
`kiroku-store/test/Main.hs`, which `just perf-structure` selects by name. Inside
`Test.PerformanceStructure`, `queryPlanSpec` runs `EXPLAIN (FORMAT JSON, COSTS OFF)` on
production statements through `explainProductionStatement store stmt [(placeholder,
literal)]` and asserts index usage with `expectIndex "<index name>" plan` and absence of node
types with `expectNoNodeType "Sort" plan`. The fixture `withQueryPlanStore` seeds 200 streams
of 100 events, dead letters, and leases, then `ANALYZE`s. A new example there proves the
membership statement uses `stream_events_pkey`.

### ADRs

[ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md) — `RecordedEvent`
carries `originalStreamId` rather than a stream name, because adding the name to the read hot
path cost roughly thirteen percent; names are resolved on demand in batch through
`lookupStreamNames`. Consequence for this plan: the inventory is also a batch API over ids, and
it resolves stream names with one join rather than asking callers to do a second lookup,
because this is an operator read rather than the hot path.

[ADR-3](../adr/0003-dedicated-kiroku-schema.md) — all objects live in the `kiroku` schema and
statements use unqualified names resolved through the connection's `search_path`. Follow the
neighbouring statements in `SQL.hs`.

[ADR-7](../adr/0007-replay-history-retention-uses-leases-and-ordered-stream-guards.md) is
relevant only in that it forbids adding work to ordinary append and read paths; this plan adds
new statements and touches no existing one. No other ADR applies, and this plan creates none:
the read API is additive and records no architectural decision beyond those in the MasterPlan.

### Why it is public

`mori://shinzui/mori/plans/237-compact-legacy-repository-history-without-discarding-facts`
requires, for every event it proposes to compact, that "the upstream link/reference inventory
reports no non-derived link or another surviving reference that would be destroyed", and it
must obtain that inventory without querying Kiroku-owned tables. The compaction preview plan
(`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md`)
reuses the same three statements to validate manifests.


## Plan of Work

### Milestone 1 — Types, statements, effect, and wrappers

Scope: the complete library surface. At the end, `lookupEventReferences` and
`lookupEventReferencesTx` compile, are re-exported by `Kiroku.Store`, and return correct
inventories when exercised by hand in `cabal repl`.

In `kiroku-store/src/Kiroku/Store/Types.hs`, add `EventMembershipKind (..)`,
`EventMembership (..)`, and `EventReferenceInventory (..)` to the export list, import
`Data.Vector (Vector)`, and add after `EventFilter`:

```haskell
{- | How an event is visible in one stream. Every event has exactly one
'HomeMembership' (the stream it was appended to) and one 'GlobalMembership'
(the @$all@ log at its global position); each 'Kiroku.Store.Link.linkToStream'
adds one 'LinkMembership'.
-}
data EventMembershipKind
    = HomeMembership
    | GlobalMembership
    | LinkMembership
    deriving stock (Eq, Ord, Show, Generic)

{- | One junction row of an event: the stream, its surrogate id, the version
the event holds in that stream (the global position for 'GlobalMembership'),
and the membership kind.
-}
data EventMembership = EventMembership
    { stream :: !StreamName
    , streamId :: !StreamId
    , streamVersion :: !StreamVersion
    , kind :: !EventMembershipKind
    }
    deriving stock (Eq, Show, Generic)

{- | Everything in the store that refers to one event: its memberships in
ascending 'streamId' order, the number of @dead_letters@ rows that reference it
(across all subscriptions), and the number of /other/ events whose
@causation_id@ is this event. Produced by
'Kiroku.Store.Read.lookupEventReferences'.
-}
data EventReferenceInventory = EventReferenceInventory
    { memberships :: !(Vector EventMembership)
    , deadLetterCount :: !Int64
    , causationDependentCount :: !Int64
    }
    deriving stock (Eq, Show, Generic)
```

In `kiroku-store/src/Kiroku/Store/SQL.hs`, add an export group
`-- * Event reference inventory statements` listing the three statements, and define them near
`lookupStreamNamesStmt`:

```haskell
{- | Every junction row for the given event ids, with the stream name resolved.
Served by @stream_events_pkey@ on @(event_id, stream_id)@; the join to
@streams@ is a primary-key lookup per row. Rows are returned in ascending
@(event_id, stream_id)@ order so callers can group without sorting.
-}
eventMembershipsStmt :: Statement (Vector UUID) (Vector (UUID, Int64, Text, Int64, Int64))
eventMembershipsStmt =
    preparable
        """
        SELECT se.event_id, se.stream_id, s.stream_name,
               se.stream_version, se.original_stream_id
        FROM stream_events se
        JOIN streams s ON s.stream_id = se.stream_id
        WHERE se.event_id = ANY($1::uuid[])
        ORDER BY se.event_id, se.stream_id
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        ( D.rowVector
            ( (,,,,)
                <$> D.column (D.nonNullable D.uuid)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.text)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
            )
        )

{- | Dead-letter rows per referenced event, across all subscriptions and
members. Served by @ix_dead_letters_event_id@. Events with no dead letters are
absent from the result.
-}
deadLetterCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))
deadLetterCountsStmt =
    preparable
        """
        SELECT dl.event_id, count(*)
        FROM dead_letters dl
        WHERE dl.event_id = ANY($1::uuid[])
        GROUP BY dl.event_id
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        (D.rowVector ((,) <$> D.column (D.nonNullable D.uuid) <*> D.column (D.nonNullable D.int8)))

{- | Per referenced event, the number of other events whose @causation_id@ is
that event, excluding events that are themselves in the input set. Served by
the partial index @ix_events_causation_id@. Events with no dependents are
absent from the result.
-}
causationDependentCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))
causationDependentCountsStmt =
    preparable
        """
        SELECT e.causation_id, count(*)
        FROM events e
        WHERE e.causation_id = ANY($1::uuid[])
          AND NOT (e.event_id = ANY($1::uuid[]))
        GROUP BY e.causation_id
        """
        (E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        (D.rowVector ((,) <$> D.column (D.nonNullable D.uuid) <*> D.column (D.nonNullable D.int8)))
```

Now the assembly. Because both the effect interpreter and the transaction combinator must
produce identical maps from the same three result vectors, write one pure function and call
it from both. Put it in `kiroku-store/src/Kiroku/Store/Effect.hs` (it already exports internal
building blocks such as `prepareEvents`) and export it under the `$internal` section as
`assembleEventReferences`:

```haskell
{- | Fold the three inventory statements' rows into one map. Memberships keep
statement order (ascending stream id); kinds are classified as global
(@stream_id = 0@), home (@stream_id = original_stream_id@), or link.
-}
assembleEventReferences ::
    Vector (UUID, Int64, Text, Int64, Int64) ->
    Vector (UUID, Int64) ->
    Vector (UUID, Int64) ->
    Map EventId EventReferenceInventory
assembleEventReferences memberships deadLetters dependents =
    Map.mapWithKey attach grouped
  where
    grouped =
        Map.fromListWith (flip (<>))
            [ (EventId eid, V.singleton (membership sid name version origin))
            | (eid, sid, name, version, origin) <- V.toList memberships
            ]
    membership sid name version origin =
        EventMembership
            { stream = StreamName name
            , streamId = StreamId sid
            , streamVersion = StreamVersion version
            , kind
                | sid == 0 = GlobalMembership
                | sid == origin = HomeMembership
                | otherwise = LinkMembership
            }
    deadLetterMap = Map.fromList [(EventId eid, n) | (eid, n) <- V.toList deadLetters]
    dependentMap = Map.fromList [(EventId eid, n) | (eid, n) <- V.toList dependents]
    attach eid ms =
        EventReferenceInventory
            { memberships = ms
            , deadLetterCount = Map.findWithDefault 0 eid deadLetterMap
            , causationDependentCount = Map.findWithDefault 0 eid dependentMap
            }
```

Note that an event with no `stream_events` rows cannot exist in a consistent store (hard
delete removes payloads whose junctions are all gone), so building the map from memberships
and attaching counts is exact. Add the `Store` constructor next to `LookupStreamNames`:

```haskell
    {- | Complete membership and reference inventory for a batch of event ids:
    every junction row classified as home, global, or link; dead-letter rows;
    and causation dependents outside the batch. Unknown ids are absent. An empty
    input performs no database work.

    Surfaced as 'Kiroku.Store.Read.lookupEventReferences'.
    -}
    LookupEventReferences :: [EventId] -> Store m (Map EventId EventReferenceInventory)
```

and the interpreter arms:

```haskell
    LookupEventReferences [] ->
        pure Map.empty
    LookupEventReferences eventIds -> do
        let uuids = V.fromList [uid | EventId uid <- eventIds]
        usePool (store ^. #pool) $
            assembleEventReferences
                <$> Session.statement uuids SQL.eventMembershipsStmt
                <*> Session.statement uuids SQL.deadLetterCountsStmt
                <*> Session.statement uuids SQL.causationDependentCountsStmt
```

In `kiroku-store/src/Kiroku/Store/Read.hs`, export and define:

```haskell
{- | Everything that refers to each of the given events. For every id that
exists, the result holds its 'EventReferenceInventory': memberships in
ascending stream-id order (home stream, @$all@ at the global position, and one
entry per link target), the count of @dead_letters@ rows referencing it, and
the count of other events whose @causationId@ is it (events in the request are
not counted as each other's dependents). Ids that name no event are absent.

Soft-deleted streams are reported like live ones: the rows physically exist.
Use 'getStream' when stream state matters.

Passing @[]@ returns an empty map without a database round trip. Non-empty
input runs three statements on one pooled connection. This is an operator and
maintenance read, not a hot path; it is the inventory a caller consults before
asking Kiroku to remove events (see "Kiroku.Store.Compaction" once available).
-}
lookupEventReferences ::
    (HasCallStack, Store :> es) =>
    [EventId] ->
    Eff es (Map EventId EventReferenceInventory)
lookupEventReferences eventIds = send (LookupEventReferences eventIds)
```

In `kiroku-store/src/Kiroku/Store/Transaction.hs`, export `lookupEventReferencesTx` under a
`-- * Tx-flavored reads` section (the same section `docs/plans/74-...` adds
`storeIdentityTx` to; create it if it does not exist yet) and define:

```haskell
{- | 'Kiroku.Store.Read.lookupEventReferences' inside the caller's transaction,
so the inventory and any decision taken on it share one snapshot. Empty input
runs no statement.
-}
lookupEventReferencesTx :: [EventId] -> Tx.Transaction (Map EventId EventReferenceInventory)
lookupEventReferencesTx [] = pure Map.empty
lookupEventReferencesTx eventIds = do
    let uuids = V.fromList [uid | EventId uid <- eventIds]
    assembleEventReferences
        <$> Tx.statement uuids SQL.eventMembershipsStmt
        <*> Tx.statement uuids SQL.deadLetterCountsStmt
        <*> Tx.statement uuids SQL.causationDependentCountsStmt
```

Add the needed imports (`Data.Map.Strict`, `Data.Vector`, `Kiroku.Store.SQL qualified as SQL`,
and `assembleEventReferences` from `Kiroku.Store.Effect`). Acceptance for this milestone is
`cabal build kiroku-store` succeeding with no warnings and a `cabal repl kiroku-store` session
showing the exports.

### Milestone 2 — Tests and the structural example

Scope: behavioural coverage and the plan-shape assertion. At the end, every membership and
reference case in Purpose is proven by an example, the no-checkout property is proven, the
mock proves one dispatch, and the structural gate includes the membership statement.

Create `kiroku-store/test/Test/EventReferences.hs` with `spec = describe "event references" $
around withTestStore $ do ...` and these examples. Use `appendToStream (StreamName "order-1")
NoStream [makeEvent "Placed" (Aeson.object [])]` to create events, then read the
`RecordedEvent`s back with `readStreamForward` to learn ids and global positions.

"reports home and global memberships for a plain event": one event; the inventory has exactly
two memberships — `EventMembership (StreamName "order-1") sid (StreamVersion 1)
HomeMembership` and `EventMembership (StreamName "$all") (StreamId 0) (StreamVersion g)
GlobalMembership` where `g` equals the event's `globalPosition` — sorted so the `$all` entry
(stream id 0) comes first; counts are zero.

"reports one link membership per target": link the event into `audit-2026` and `audit-all`
with `linkToStream`; the inventory has four memberships, the two link entries carry
`LinkMembership`, the target stream names, and version 1 in each target.

"records the true origin for a link of a link": link event from `order-1` into `hub`, then link
from `hub` into `mirror` by passing the same event id; `mirror`'s membership is `LinkMembership`
(not home), and the home membership still names `order-1`.

"counts dead letters across subscriptions": call `insertDeadLetterForEvent store "proj-a"
event` and `insertDeadLetterForEvent store "proj-b" event`; `deadLetterCount` is 2.

"counts causation dependents outside the request": append a second event with
`(makeEvent "Shipped" ...) { causationId = Just firstUuid }` and a third with the same
causation id; `lookupEventReferences [first]` reports `causationDependentCount = 2`;
`lookupEventReferences [first, second]` reports `1` for `first` (the second is in the request)
and `0` for `second`.

"omits unknown ids": request `[known, EventId someFreshUuid]`; the map has exactly one key.

"reports memberships in a soft-deleted stream": link the event into `archive-1`, soft-delete
`archive-1`; the link membership is still present with the name `archive-1`.

"short-circuits empty input without a pool checkout": copy the `withObservedStore` pattern;
`lookupEventReferences []` changes the checkout counter by 0 and `lookupEventReferences [id]`
changes it by exactly 1 (three statements, one checkout).

"agrees between the effect and the transaction combinator": `runTransaction
(lookupEventReferencesTx ids)` returns the same map as the effect.

Create `kiroku-store/test/Test/EventReferencesMock.hs` modelled on
`Test/VisibleGlobalHeadPositionMock.hs`: the mock handles `LookupEventReferences ids`, asserts
`ids` equals the expected list, returns a hand-built map, and the example checks the map and
one dispatch.

In `kiroku-store/test/Test/PerformanceStructure.hs`, inside `queryPlanSpec`, add:

```haskell
            it "event membership inventory uses stream_events_pkey" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.eventMembershipsStmt
                        [("$1::uuid[]", "ARRAY['00000000-0000-0000-0000-000000000001']::uuid[]")]
                expectIndex "stream_events_pkey" plan
```

Register `Test.EventReferences` and `Test.EventReferencesMock` in `kiroku-store/kiroku-store.cabal`
(`other-modules`, alphabetical) and in `kiroku-store/test/Main.hs` (import and spec call next
to the other read/mock specs).

Acceptance: `cabal test kiroku-store:kiroku-store-test` passes with the ten new examples and
`just perf-structure` passes including the new plan example.

### Milestone 3 — Changelog and final verification

Add to `kiroku-store/CHANGELOG.md` under `## Unreleased` / `### New Features` (create the
section if `docs/plans/74-...` has not already):

```markdown
* `Kiroku.Store.Read.lookupEventReferences` and
  `Kiroku.Store.Transaction.lookupEventReferencesTx` return, per event id, every
  junction membership classified as home, global, or link (with stream name,
  id, and version), the dead-letter count, and the count of causation
  dependents outside the request. New types `EventMembershipKind`,
  `EventMembership`, and `EventReferenceInventory` live in `Kiroku.Store.Types`.
  Empty input performs no database work.
```

Run the full verification and commit.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

```bash
cabal build kiroku-store
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "event references"'
just perf-structure
cabal test kiroku-store:kiroku-store-test
nix fmt
cabal build all
cabal test all
git add -A
nix flake check
```

Expected from the focused run:

```text
event references
  reports home and global memberships for a plain event
  reports one link membership per target
  records the true origin for a link of a link
  counts dead letters across subscriptions
  counts causation dependents outside the request
  omits unknown ids
  reports memberships in a soft-deleted stream
  short-circuits empty input without a pool checkout
  agrees between the effect and the transaction combinator
event references mock
  returns the configured inventory through one Store effect call

Finished in N seconds
10 examples, 0 failures
```

Expected from `just perf-structure`: the existing examples plus `event membership inventory
uses stream_events_pkey`, all passing.

Commit message shape:

```text
feat(store): expose event membership and reference inventory

Add lookupEventReferences and lookupEventReferencesTx returning classified
memberships, dead-letter counts, and causation dependents per event id.
Three indexed statements share one checkout; empty input is a no-op.

MasterPlan: docs/masterplans/11-manifest-driven-selective-event-compaction.md
ExecPlan: docs/plans/75-expose-an-event-membership-and-reference-inventory-read-api.md
Intention: intention_01m0mwdmnfex3tv9fg0t57htfv
```


## Validation and Acceptance

Behaviour a reviewer can verify in `cabal repl kiroku-store:kiroku-store-test` or a scratch
program against `just reset-database`: after appending event E to `order-1` (it receives global
position P), linking E into `audit-2026`, inserting one dead letter for E, and appending event F
with `causationId = Just E`, `lookupEventReferences [E]` returns a map with one key whose
inventory is exactly

```haskell
EventReferenceInventory
    { memberships =
        [ EventMembership "$all" (StreamId 0) (StreamVersion P) GlobalMembership
        , EventMembership "order-1" (StreamId 1) (StreamVersion 1) HomeMembership
        , EventMembership "audit-2026" (StreamId 2) (StreamVersion 1) LinkMembership
        ]
    , deadLetterCount = 1
    , causationDependentCount = 1
    }
```

(stream ids depend on creation order; the ordering by ascending stream id is what is fixed).
`lookupEventReferences []` returns `Map.empty` with zero pool checkouts. The test transcript in
Concrete Steps is the executable form of this acceptance, and `just perf-structure` proves the
membership statement is served by `stream_events_pkey`.


## Idempotence and Recovery

Every step is additive and safe to repeat: re-running the suites creates fresh ephemeral
databases; rebuilding after an edit is cheap. If the plan-shape example fails because the
planner chooses a sequential scan on the tiny `EXPLAIN` input, confirm `withQueryPlanStore` has
`ANALYZE`d `stream_events` (it does) and that the literal you substituted is a valid
`uuid[]`; do not weaken the assertion. If a membership case surprises you (for example a link
of a link not recording the origin), record the evidence in Surprises & Discoveries before
changing the classification rule, because the rule is shared with the compaction plans.


## Interfaces and Dependencies

Libraries: `hasql`, `hasql-transaction`, `effectful-core`, `containers`, `vector`, `uuid` —
all already dependencies of `kiroku-store`. No new dependency.

Declarations that exist at the end of Milestone 1 and are re-exported by `Kiroku.Store`:

```haskell
-- Kiroku.Store.Types
data EventMembershipKind = HomeMembership | GlobalMembership | LinkMembership
data EventMembership = EventMembership
    { stream :: !StreamName, streamId :: !StreamId, streamVersion :: !StreamVersion, kind :: !EventMembershipKind }
data EventReferenceInventory = EventReferenceInventory
    { memberships :: !(Vector EventMembership), deadLetterCount :: !Int64, causationDependentCount :: !Int64 }

-- Kiroku.Store.SQL
eventMembershipsStmt :: Statement (Vector UUID) (Vector (UUID, Int64, Text, Int64, Int64))
deadLetterCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))
causationDependentCountsStmt :: Statement (Vector UUID) (Vector (UUID, Int64))

-- Kiroku.Store.Effect
LookupEventReferences :: [EventId] -> Store m (Map EventId EventReferenceInventory)
assembleEventReferences ::
    Vector (UUID, Int64, Text, Int64, Int64) -> Vector (UUID, Int64) -> Vector (UUID, Int64)
    -> Map EventId EventReferenceInventory

-- Kiroku.Store.Read
lookupEventReferences :: (HasCallStack, Store :> es) => [EventId] -> Eff es (Map EventId EventReferenceInventory)

-- Kiroku.Store.Transaction
lookupEventReferencesTx :: [EventId] -> Tx.Transaction (Map EventId EventReferenceInventory)
```

The three statements and `assembleEventReferences` are consumed unchanged by
`docs/plans/77-preview-a-compaction-manifest-read-only-with-deterministic-witnesses.md` and
`docs/plans/78-apply-a-compaction-manifest-transactionally-with-ledgered-idempotence.md` to
discover unacknowledged links, dead letters, and causation dependents of selected events.
