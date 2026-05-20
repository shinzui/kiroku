# Reading Events

Kiroku exposes four read shapes: a single stream, the global `$all` stream, a
category (a fan-in of streams sharing a name prefix), and stream metadata.
All event reads return `Vector RecordedEvent`; all use an **exclusive**
cursor. This guide covers each, plus constant-memory streaming reads.

## `RecordedEvent`

Reads return `RecordedEvent`:

| Field | Meaning |
| --- | --- |
| `eventId` | The event's stable id (UUIDv7 by default). |
| `eventType` | The application-level type discriminator. |
| `streamVersion` | Position in the stream being read. For source-stream reads this equals `originalVersion`; for a linked target it is the link's position in that target. |
| `globalPosition` | Position in the global `$all` sequence at original-append time. Stable across links; used as the subscription cursor. |
| `originalStreamId` | The stream the event was first appended to. |
| `originalVersion` | The position the event was assigned in its source stream. |
| `payload` | The JSONB body. |
| `metadata` | Optional JSONB metadata. |
| `causationId` / `correlationId` | Optional causal / workflow ids. |
| `createdAt` | Append timestamp. |

`streamVersion` and `originalVersion` differ only when reading a linked
target stream — see [Linking Events](linking.md).

## Reading A Single Stream

```haskell
readStreamForward ::
  (HasCallStack, Store :> es) =>
  StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)

readStreamBackward ::
  (HasCallStack, Store :> es) =>
  StreamName -> StreamVersion -> Int32 -> Eff es (Vector RecordedEvent)
```

The cursor is exclusive. `readStreamForward name (StreamVersion 0) limit`
returns events with `streamVersion > 0` — i.e. the whole stream from the
start. `limit` caps the batch size; pass a large value to "read everything".

```haskell
events <- readStreamForward (StreamName "orders-1") (StreamVersion 0) 1000
```

`readStreamBackward` returns events older than the cursor (`streamVersion <
startVer`). To read from the latest event backward, pass `StreamVersion 0` —
the SQL treats it as "newer than any".

Both return an **empty vector** for a nonexistent or soft-deleted stream;
neither raises an error for absence.

To page forward manually, advance the cursor to the last returned event's
`streamVersion` and call again until you get an empty batch.

## Streaming A Single Stream

For long streams, `readStreamForwardStream` returns a constant-memory
Streamly `Stream` instead of a `Vector`. It pages internally with the same
SQL and the same exclusive-cursor semantics:

```haskell
import Streamly.Data.Stream qualified as Stream

readStreamForwardStream ::
  (HasCallStack, Store :> es) =>
  StreamName -> StreamVersion -> Int32 -> Stream (Eff es) RecordedEvent

-- fold the whole stream without materializing it
total <-
  Stream.fold Fold.length $
    readStreamForwardStream (StreamName "orders-1") (StreamVersion 0) 256
```

The third argument is the page size, not a total limit. The recommended page
size is `256`. Use a smaller value for very wide events (large payloads) to
bound per-page memory; a larger value for very long streams of small events
to cut round-trips.

## Reading The Global `$all` Stream

`$all` is the global, gap-free log of every appended event in append order.

```haskell
readAllForward ::
  (HasCallStack, Store :> es) =>
  GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)

readAllBackward ::
  (HasCallStack, Store :> es) =>
  GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
```

The cursor is exclusive on `globalPosition`. `readAllForward (GlobalPosition
0) limit` reads from the first event; `readAllBackward (GlobalPosition 0)
limit` reads from the most recent event backward.

`$all` includes events from **soft-deleted** streams (the global log is
append-only and they survive even after their owning stream is hidden). It
excludes events from **hard-deleted** streams. The internal seed row at
`globalPosition = 0` is never returned. You cannot read `$all` through
`readStreamForward (StreamName "$all")` — that name is reserved and mutating
APIs reject it; use these functions instead.

## Reading A Category

A category is the substring of a stream name before the first `-`:
`StreamName "orders-1"` has `CategoryName "orders"`. `readCategory` fans in
every event whose source stream shares that prefix, in global position order.

```haskell
readCategory ::
  (HasCallStack, Store :> es) =>
  CategoryName -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)

orders <- readCategory (CategoryName "orders") (GlobalPosition 0) 1000
```

The cursor is the global position, exclusive, so paging works exactly like
`$all`. Linked events appear at their **source** position, and the category
is the source's category, not a link target's. Category reads include events
from soft-deleted streams, mirroring `$all`.

## Stream Metadata

```haskell
getStream ::
  (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamInfo)

lookupStreamId ::
  (HasCallStack, Store :> es) => StreamName -> Eff es (Maybe StreamId)
```

`getStream` returns `StreamInfo` for both live and soft-deleted streams
(soft-deleted streams have `deletedAt` populated), and `Nothing` for streams
that were hard-deleted or never created.

| `StreamInfo` field | Meaning |
| --- | --- |
| `id` | The stream's surrogate id (access via `info ^. #id` to avoid clashing with `Prelude.id`). |
| `name` | The stream name as created. |
| `version` | Current version (count of appended events). |
| `createdAt` | When the stream row was first inserted. |
| `deletedAt` | `Just` the soft-delete timestamp, or `Nothing` if live. |

`lookupStreamId` is a cheaper alternative when you only need the surrogate id
— it decodes one column instead of five. It returns `Nothing` for never-created
and hard-deleted streams, matching `getStream`'s soft-delete behavior.

## See Also

- [Appending Events](appending-events.md) — how positions are assigned.
- [Linking Events](linking.md) — why `streamVersion` can differ from
  `originalVersion`.
- [Subscriptions](subscriptions.md) — read continuously as new events arrive.
