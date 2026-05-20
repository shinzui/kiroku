# Appending Events

Appending is how new facts enter the store. Kiroku appends are atomic per
call, enforce optimistic concurrency at the stream level, and assign each
event a gap-free global position. This guide covers `appendToStream`,
the `ExpectedVersion` preconditions, idempotent retries, multi-stream
appends, and transactional appends.

## `appendToStream`

```haskell
appendToStream ::
  (HasCallStack, Store :> es) =>
  StreamName ->
  ExpectedVersion ->
  [EventData] ->
  Eff es AppendResult
```

A call appends a batch of events to one stream under an `ExpectedVersion`
precondition. The batch is all-or-nothing: if the precondition fails, no
event in the batch is written.

`EventData` is what you supply:

| Field | Meaning |
| --- | --- |
| `eventId :: Maybe EventId` | `Nothing` lets the store generate a UUIDv7. `Just` supplies your own id, primarily for idempotent retries (see below). |
| `eventType :: EventType` | Application-level discriminator, e.g. `EventType "OrderPlaced"`. Indexed but not interpreted. |
| `payload :: Value` | The event's JSONB body. |
| `metadata :: Maybe Value` | Optional JSONB metadata — tenant ids, trace context, request annotations. |
| `causationId :: Maybe UUID` | The id of the event that directly caused this one. |
| `correlationId :: Maybe UUID` | The id shared by events in the same workflow or saga. |

`AppendResult` reports the state **after** the batch:

| Field | Meaning |
| --- | --- |
| `streamId` | The id of the stream that was appended to (created if missing). |
| `streamVersion` | The stream's version after the append — the position of the *last* event in the batch. |
| `globalPosition` | The global `$all` position assigned to the *last* event in the batch. |

Do not append an empty list. The underlying query returns no rows, which the
interpreter maps to a precondition error rather than your intent — reject the
call yourself before invoking the API.

## Optimistic Concurrency: `ExpectedVersion`

Every append carries an `ExpectedVersion` that the stream must satisfy at
commit time. This is how Kiroku enforces consistency without locks held
across reads.

| Constructor | Precondition | On violation |
| --- | --- | --- |
| `NoStream` | The stream must not exist yet. Creates it and appends. Use for aggregate creation. | `StreamAlreadyExists` (including soft-deleted streams). |
| `StreamExists` | The stream must already exist and not be soft-deleted; its version does not matter. | `StreamNotFound`. |
| `ExactVersion v` | The stream's current version must equal `v`. Use after reading the stream, to append only if no one else advanced it. | `WrongExpectedVersion` carrying the actual version. |
| `AnyVersion` | Upsert: create if missing, append otherwise; no version check. Maps to a single `INSERT ... ON CONFLICT DO UPDATE`. | — (only fails if the existing stream is soft-deleted). |

The canonical aggregate write loop reads the stream, decides, and writes back
with `ExactVersion`:

```haskell
import Control.Lens ((^.))
import Data.Vector qualified as V

placeOrder :: (Store :> es) => StreamName -> EventData -> Eff es AppendResult
placeOrder stream newEvent = do
  current <- readStreamForward stream (StreamVersion 0) 100000
  let expected =
        if V.null current
          then NoStream
          else ExactVersion (V.last current ^. #streamVersion)
  appendToStream stream expected [newEvent]
```

If a concurrent writer advanced the stream between the read and the append,
the `ExactVersion` append fails with `WrongExpectedVersion`. Re-read and
retry, or surface the conflict to the caller.

## Errors

`appendToStream` reports failures as `StoreError` (via the `Error StoreError`
effect; with `runStoreIO` they arrive as `Left`):

| Error | Cause |
| --- | --- |
| `WrongExpectedVersion name expected actual` | `ExactVersion` mismatch. The third field is the actual version. |
| `StreamNotFound name` | `StreamExists` against a missing or soft-deleted stream. |
| `StreamAlreadyExists name` | `NoStream` against an existing stream (including soft-deleted). |
| `ReservedStreamName name` | The target is `$all`, which is the global read stream and cannot be appended as an application stream. |
| `DuplicateEvent (Maybe EventId)` | A caller-supplied `eventId` collides with an existing event. |

Other constructors (`PoolAcquisitionTimeout`, `ConnectionLost`,
`UnexpectedServerError`, `ConnectionError`) cover infrastructure failures.
Match the specific constructors first when deciding retry vs. escalate.

## Idempotent Retries

Network failures leave appends ambiguous: the commit may or may not have
landed. Supply your own `eventId` so a retry is safe:

```haskell
import Data.UUID (UUID)

idempotentAppend ::
  (Store :> es) => StreamName -> UUID -> EventData -> Eff es AppendResult
idempotentAppend stream eid ev =
  appendToStream stream AnyVersion [ev { eventId = Just (EventId eid) }]
```

On retry, one of two things happens:

- The previous attempt did **not** commit — the retry succeeds normally.
- The previous attempt **did** commit — the retry surfaces as
  `DuplicateEvent`, which you can treat as success.

Note the interaction with `ExactVersion`: a retry that observed
`WrongExpectedVersion` is genuinely ambiguous (either a concurrent writer
raced you, or your previous attempt succeeded). The correct recovery in both
cases is to re-read the stream and decide.

## Multi-Stream Appends

`appendMultiStream` writes to several streams in a single transaction —
either all per-stream appends succeed or all roll back.

```haskell
appendMultiStream ::
  (HasCallStack, Store :> es) =>
  [(StreamName, ExpectedVersion, [EventData])] ->
  Eff es [AppendResult]
```

The interpreter pre-locks the named streams in deterministic `stream_id`
order, so two concurrent multi-stream calls touching overlapping streams in
different user-supplied orders cannot deadlock. If any operation targets
`$all`, the whole call is rejected with `ReservedStreamName` before the
transaction opens. The returned list mirrors the input order; each
`AppendResult` carries the corresponding stream's final state. As with
`appendToStream`, do not pass an empty list.

## Transactional Appends

`appendToStream` runs as one statement on a pooled connection — no
Haskell-layer `BEGIN`/`COMMIT`. Reach for the transaction combinators only
when you must atomically combine an append with **additional SQL writes that
the store does not perform** — most commonly inserting a projection row in
the same transaction as the event.

```haskell
import Kiroku.Store.Transaction (runTransactionAppending)
import Hasql.Transaction qualified as Tx

appendWithProjection ::
  (IOE :> es, Store :> es) =>
  StreamName -> [EventData] -> Eff es (Either StoreError ())
appendWithProjection stream events =
  runTransactionAppending stream AnyVersion events $ \ar ->
    -- runs in the SAME transaction as the append
    Tx.statement (...) insertProjectionRow
```

`runTransactionAppending` opens an explicit `BEGIN`/`COMMIT`, retries the
whole body on PostgreSQL serialization conflicts by default, and threads your
continuation into the same transaction. It returns
`Either StoreError a` so append-precondition conflicts surface without an
exception. Use `runTransactionAppendingNoRetry` to execute the body exactly
once.

Direct callers of the lower-level `appendToStreamTx` bypass the `enrichEvent`
hook (see [OpenTelemetry](opentelemetry.md)); call `enrichEventsIO` first if
you rely on it. For most applications, plain `appendToStream` is the right
default — reach for transactions only when a cross-table atomic write demands
it.

## See Also

- [Reading Events](reading-events.md) — how appended events read back.
- [Stream Lifecycle](lifecycle.md) — how deletes affect appends.
- [Database Schema](schema.md) — the ordering model behind global positions.
