# Linking Events

Kiroku can link an existing event into another stream with `linkToStream`.
Linking is useful when an event belongs naturally to one source stream, but
another consumer wants to read a curated stream of related events.

The key property is that linking does not copy or rewrite the event. The
original `events` row is shared, and Kiroku adds one new `stream_events` row for
the target stream. See [Database Schema](schema.md) for the table-level model.

## When To Use Links

Use links when you want a read stream that is derived from existing events:

- projection streams, such as `account-activity-123`, built from events emitted
  by `orders-*`, `payments-*`, and `refunds-*`;
- process-manager inboxes, where a coordinator wants a single stream of events
  relevant to one workflow instance;
- audit or review queues, where selected events from many source streams should
  be read in a stable order;
- closed accounting periods, where a stream such as `closed-books-2026-04`
  records exactly which already-appended ledger events were included in a close;
- alternate grouping streams, where the source aggregate stream remains the
  write owner, but another aggregate or view needs a durable event list.

Do not use links to create a new fact. If something new happened, append a new
event to the owning stream. Use links only to give an existing event another
stream position.

## Basic Usage

Import `Kiroku.Store`; `linkToStream` is re-exported from the public API.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Kiroku.Store

linkOrderIntoAccount ::
  (Store :> es) =>
  Eff es LinkResult
linkOrderIntoAccount = do
  events <- readStreamForward (StreamName "orders-123") (StreamVersion 0) 100
  let orderCreatedId = V.head events ^. #eventId
  linkToStream (StreamName "account-activity-456") [orderCreatedId]
```

The target stream is created automatically if it does not exist. If it already
exists, Kiroku appends the links to the end of that target stream.

`LinkResult` contains:

| Field | Meaning |
| --- | --- |
| `streamId` | The target stream id. |
| `streamVersion` | The target stream version after linking; for a batch, this is the position of the last linked event. |

There is no `globalPosition` in `LinkResult` because linking does not advance
the global `$all` stream.

## Reading Linked Streams

Read a linked stream with the same stream read APIs used for ordinary streams:

```haskell
linkedEvents <-
  readStreamForward
    (StreamName "account-activity-456")
    (StreamVersion 0)
    100
```

For events read from a linked stream:

- `eventId`, `eventType`, `payload`, `metadata`, `causationId`,
  `correlationId`, and `createdAt` come from the original event;
- `streamVersion` is the event's position in the linked target stream;
- `originalStreamId` and `originalVersion` identify where the event was first
  appended.

For direct source-stream reads, `streamVersion` and `originalVersion` are the
same. For linked-stream reads, they can differ.

## Ordering

`linkToStream target [a, b, c]` links events into `target` in the list order.
If the target was at version `10`, the linked events receive target stream
versions `11`, `12`, and `13`.

The linked events keep their original `$all` positions. Reading `$all` after a
link does not show a duplicate event, and the global counter is unchanged.

This makes links a good fit for durable projections: the projection stream has
its own ordering, while global ordering remains the ordering of original
appends.

## Close The Books Pattern

Links can model the closed set for an accounting close. When a month, quarter,
or other period is closed, the application chooses the finalized ledger events
that belong to that period and links them into a period-specific stream:

```haskell
linkToStream
  (StreamName "closed-books-2026-04")
  finalizedLedgerEventIds
```

The resulting stream is a durable audit list: reading `closed-books-2026-04`
later shows the exact events that were included in the close, in the order they
were linked. The source ledger streams remain the owners of the original
events, and `$all` is not duplicated or advanced by the links.

Use ordinary appended events to record and enforce the period state itself. For
example:

```text
accounting-period-2026-04
  1. BooksCloseStarted
  2. BooksClosed { closedStream = "closed-books-2026-04" }
```

After `BooksClosed`, application logic can reject new ordinary postings for the
closed period, or require explicit adjustment events in a later period. Linking
does not enforce those business rules by itself; it gives the close a stable
read stream containing the exact events that were closed.

## Failure Cases

`linkToStream` is atomic. If a batch cannot be linked, no partial target stream
is left behind and the target version is not advanced.

Important failure cases:

| Case | Result |
| --- | --- |
| The target stream is `$all`. | Fails with `ReservedStreamName`; `$all` is reserved for global reads. |
| The target stream exists but is soft-deleted. | Fails with `StreamNotFound`. |
| Any source event id does not exist, or was hard-deleted. | Fails; the whole batch rolls back. |
| The same event is linked into the same target stream twice. | Fails with a database uniqueness error mapped through `StoreError`. |
| The event's source stream is soft-deleted. | The event can still be linked, because the event row and its source junction rows still exist. |

Avoid calling `linkToStream` with an empty event list. It is treated as a
programming mistake rather than a meaningful operation.

## Links And Deletes

Soft deleting a source stream does not remove its events. Existing links keep
working, and the events remain visible in `$all`.

Hard deleting a stream removes junction rows owned by that stream and deletes
event payloads only when they have no surviving stream entries. If an event is
still linked to another stream that is not part of the deletion, Kiroku
preserves the event row so the surviving linked stream remains readable.

## Practical Guidance

Keep the source stream as the owner of writes. Append the event once to the
stream that owns the fact, then link it into as many read-oriented streams as
needed.

Use link stream names that describe the read model, not the source event type:
`account-activity-456`, `customer-timeline-789`, or `invoice-review-2026-05`
are clearer than `linked-orders`.

Treat duplicate-link failures as idempotency signals only if your application
can prove the target stream and event id are the same intended link. Otherwise,
surface the error; the primary key prevents one event from appearing twice in
the same stream.
