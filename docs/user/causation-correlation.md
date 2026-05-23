# Causation And Correlation

Two optional fields on every event record *why* it happened:

- `causationId` — the id of the single event that **directly caused** this one.
  Following these links forms a causation tree: a handler reacting to event `A`
  appends event `B` with `causationId = Just (A's event id)`.
- `correlationId` — an id **shared** by every event in the same workflow,
  request, or saga. Unlike causation it is flat: every related event carries the
  same value no matter how deep the causal chain runs.

You set them on append (see [Appending Events](appending-events.md)) and read
them back on every `RecordedEvent` (see [Reading Events](reading-events.md)).
This guide covers the three queries that *walk* those links —
`findCausationDescendants`, `findCausationAncestors`, and `findByCorrelation` —
all in `Kiroku.Store.Causation` and re-exported from `Kiroku.Store`.

## The Causal Model

An event `B` is *caused by* event `A` when `B`'s `causationId` equals `A`'s
`eventId`. Causation is therefore a directed tree of single parents; correlation
is a flat label spanning the whole workflow. A typical chain:

```text
OrderPlaced            causationId = Nothing            correlationId = w
  └─ PaymentRequested  causationId = OrderPlaced.id     correlationId = w
       └─ PaymentTaken causationId = PaymentRequested.id correlationId = w
            └─ OrderConfirmed causationId = PaymentTaken.id correlationId = w
```

`findCausation*` walk the parent links (the tree); `findByCorrelation` returns
everything tagged `w` (the flat set), in one query, regardless of shape.

Set the fields when you append the reacting event — the value you pass for
`causationId` is the **raw `UUID`** of the triggering event:

```haskell
import Control.Lens ((^.))

-- inside a handler reacting to `trigger :: RecordedEvent`
let EventId triggerUuid = trigger ^. #eventId
appendToStream stream expected
  [ EventData
      { eventId = Nothing
      , eventType = EventType "PaymentRequested"
      , payload = ...
      , metadata = Nothing
      , causationId = Just triggerUuid
      , correlationId = trigger ^. #correlationId  -- inherit the workflow id
      }
  ]
```

## Walking Causation Forward (Descendants)

```haskell
findCausationDescendants ::
  (HasCallStack, Store :> es) =>
  EventId -> Eff es (Vector RecordedEvent)
```

Returns the **seed event plus every event whose `causationId` chain leads back
to it**, in ascending `globalPosition` order. The seed is the first (depth-0)
row when it exists; if no event has that id the result is empty.

```haskell
import Control.Lens ((^.))
import Kiroku.Store

-- everything that ultimately flowed from one OrderPlaced event
descendants <- findCausationDescendants (placedEvent ^. #eventId)
```

Use it to answer "what did this event set in motion?" — auditing a command's
full downstream effect, or reconstructing a process-manager's chain from its
trigger.

## Walking Causation Backward (Ancestors)

```haskell
findCausationAncestors ::
  (HasCallStack, Store :> es) =>
  EventId -> Eff es (Vector RecordedEvent)
```

Returns the **seed plus every ancestor reachable by following `causationId`
upward**, in depth order: the seed first, its immediate cause second, and so on
up the chain. Empty when no event has the seed id.

```haskell
-- "why did this confirmation happen?" — the chain that produced it
ancestors <- findCausationAncestors (confirmedEvent ^. #eventId)
```

This is the inverse direction of `findCausationDescendants`. Note the ordering
contract differs: descendants come back in `globalPosition` order, ancestors in
depth order (nearest cause first).

## Querying A Correlation

```haskell
findByCorrelation ::
  (HasCallStack, Store :> es) =>
  UUID -> Eff es (Vector RecordedEvent)
```

Returns **every event whose `correlationId` equals the input**, in ascending
`globalPosition` order; empty if none match. The argument is a raw `UUID` — the
same value you stored in `correlationId`, *not* an `EventId`:

```haskell
import Data.Maybe (fromMaybe)

-- the full timeline of one workflow, across every stream it touched
case someEvent ^. #correlationId of
  Just wf -> findByCorrelation wf
  Nothing -> pure mempty
```

Reach for this to assemble a saga's complete timeline, or to gather every event
belonging to one originating request, without knowing the causal shape in
advance.

## Recovering Source Stream Names

All three are **fan-in reads**: like `$all` and `readCategory`, each returned
`RecordedEvent` carries only its surrogate `originalStreamId`, not a stream
name. To display the originating stream, collect the distinct ids and resolve
them in one round trip with `lookupStreamNames` — see
[Reading Events › Resolving Source Stream Names](reading-events.md#resolving-source-stream-names).

## Cost, Indexes, And Hooks

- The causation walks are recursive queries over the partial index
  `ix_events_causation_id`; `findCausationDescendants` costs `O(depth · log n)`
  in the chain length, not the total event count. `findByCorrelation` is a
  single index scan over `ix_events_correlation_id`. Neither needs a schema
  change — both indexes ship in the base schema (see
  [Database Schema](schema.md)).
- These reads honor the interpreter's `decodeHook` on parity with
  `readStreamForward` / `readAllForward` / `readCategory`, so any decode
  customization wired through `StoreSettings` applies here too (see
  [OpenTelemetry](opentelemetry.md)).
- The id columns are nullable: events appended without a `causationId` /
  `correlationId` simply never appear as a match. Set the fields on append if
  you intend to query by them later.

## See Also

- [Appending Events](appending-events.md) — setting `causationId` and
  `correlationId` on append.
- [Reading Events](reading-events.md) — the `RecordedEvent` fields and
  `lookupStreamNames`.
- [Database Schema](schema.md) — the `ix_events_causation_id` and
  `ix_events_correlation_id` indexes behind these queries.
