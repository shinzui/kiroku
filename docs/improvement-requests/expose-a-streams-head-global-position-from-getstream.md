---
type: Improvement Request
title: Expose a stream's head global position from getStream
description: >-
  Let a consumer that holds a stream version learn, from the same public stream lookup it already
  makes, the global position of that stream's newest visible event, so a read-your-writes wait can
  target exactly the events of one stream instead of a whole category's visible head.
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-10-06T23:32:09Z"
timestamp: "2026-10-06T23:32:09Z"
requestId: IR-18
status: proposed
origin: mori://tan/notification-render-service
---

# Improvement Request: Expose a Stream's Head Global Position from getStream

## Status

Proposed by the notification render service
(`mori://tan/notification-render-service`), whose admin API implements the platform's
read-your-writes contract in
`mori://tan/notification-render-service/plans/16-give-the-admin-api-one-command-answer-and-a-read-your-writes-position-floor`.
That plan is complete; it works today with a category-wide proxy that this request would let it
replace with an exact per-stream target. Nothing is blocked. The request is non-urgent and
additive in intent.

## Context

A platform convention (registration-service-v2, admin-graphql-server, admin-web, and now the
notification render service) hands clients the **per-stream version** of a change: a mutation
answers `visibleAsOf = N`, every view carries `version`, and a read with `?minPosition=N` must
not answer a view older than event `N` of that entity's stream. The number is a stream version
because the same number serves optimistic concurrency (`expectedVersion` on a later command), so
clients track one integer per entity.

Keiro's read-model freshness protocol
(`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections`) waits on a
projection's durable cursor, and that cursor is kept in **global positions**. To honour a
stream-version floor the service must therefore answer one question before it waits: *what is the
global position of event `N` of stream `S`*, or at least of some event at or after it?

Kiroku's public API cannot answer it today:

- `Kiroku.Store.Read.getStream` returns `StreamInfo` with `version` (the count of appended events)
  but no global position. Its statement reads the `streams` row only
  (`getStreamSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs`).
- `readStreamForward` and `readStreamBackward` return `RecordedEvent.globalPosition = 0` for every
  event: their SQL selects `0::bigint AS global_position` with the comment "not available
  without `$all` join".
- `visibleGlobalHeadPosition` (IR-4, `kiroku-store` 0.6.0.0) answers the store-wide visible head,
  and Keiro's `categoryHeadPosition` answers a category's; neither is scoped to one stream.

The service's current workaround, recorded as a documented proxy in its pattern register
(`mori://tan/notification-render-service/docs/KEIRO-PATTERNS.md`): after `getStream` shows
`version >= N` (so event `N` is committed), capture the **category's** visible head with Keiro's
`categoryHeadPosition` and wait for the projection cursor to reach it. That head is at or past
event `N`, so the wait is correct, but it also covers every other stream's events appended before
the capture. The over-wait is harmless when the projection is caught up and only lengthens a wait
that is already lagging; it is still a looser target than the one the caller means, and it costs a
second round trip after `getStream`.

The storage fact needed is already indexed. Each event has exactly one `$all` link row in
`stream_events` with `stream_id = 0`, whose `stream_version` is the global position and whose
`original_stream_id` names the source stream. The index
`ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE stream_id = 0`
(migration `0001-kiroku-bootstrap.sql`) makes "the newest `$all` link of stream `S`" a single
index probe.

## Requested Change

Let `getStream` (or a sibling read with the same input) answer the global position of the
stream's newest visible event, with these semantics:

1. The value is the greatest `$all` `stream_version` among the visible link rows whose
   `original_stream_id` is the stream's, or absent when the stream has no visible `$all` entry
   (a stream with no events; a hard-deleted stream is already absent from `getStream`).
2. It is a position, not an event: no event data or metadata is fetched and the store's decode
   hook is not invoked.
3. Visibility matches Kiroku's global reads and IR-4's `visibleGlobalHeadPosition`: soft deletion
   and logical truncation (`truncateBefore`) do not hide events from `$all`; hard deletion removes
   them and may make the value regress or disappear.
4. It is one statement-time observation beside `version`, taken in the same statement or
   transaction as the `streams` row, so a caller that reads `version >= N` and the head position
   together knows the head is at or past event `N`. It is not a snapshot: a concurrent append may
   raise both immediately afterwards.
5. It is exposed through the mockable `Store` effect and `Kiroku.Store.Read`; consumers need not
   import `Kiroku.Store.SQL` or Hasql.

Two shapes satisfy this; the final one belongs to Kiroku:

```haskell
-- (a) a field beside version, filled by one extra indexed join in getStreamSQL
data StreamInfo = StreamInfo
    { id :: !StreamId
    , name :: !StreamName
    , version :: !StreamVersion
    , headGlobalPosition :: !(Maybe GlobalPosition)
    , …
    }

-- (b) a sibling read, when changing StreamInfo is undesirable
streamHeadGlobalPosition ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe GlobalPosition)
```

Shape (a) gives the consumer both facts in one call, which is what the read-your-writes check
needs; it adds a field to an exported record, which is source-breaking for code that constructs
`StreamInfo` positionally (mock interpreters). Shape (b) is purely additive at the type level but
is a second round trip, and a caller must then reason about the two observations not being
simultaneous. Either removes the category proxy; (a) removes the extra round trip as well.

An exact lookup, "the global position of event `N` of stream `S`"
(`StreamName -> StreamVersion -> Eff es (Maybe GlobalPosition)`), would answer the question
literally. It is not requested here: for a wait target the head is as good as the exact event (the
cursor reaching the head implies it reached event `N`), the head needs no second probe to tell
"no stream" from "version beyond the stream", and the head is the fact the existing index serves
best. Populating `RecordedEvent.globalPosition` on stream reads is also not requested: it would
put the `$all` join on every stream read, including every command hydration.

## Boundaries

This request does not change global-position allocation, `$all` linking, hard or soft deletion,
truncation, checkpoint advancement, or subscription delivery. It does not ask Kiroku to implement
query freshness, waits, or any read-your-writes policy; Keiro and its consumers decide what to
wait for. It does not touch `SubscriptionCheckpointInventory.storePosition`,
`visibleGlobalHeadPosition`, or Keiro's `categoryHeadPosition`, whose contracts stay as they are.

It does not promise that the captured position stays visible. If a concurrent hard delete removes
the stream's newest events after the call returns, the consumer applies its own timeout, exactly as
with IR-4's store-wide head.

## Acceptance

1. A stream with no events reports no head position; after appending events at stream versions 1
   through 3 (global positions, say, 810, 811 and 815 with other streams interleaved), the head
   position is 815 and `version` is 3, from one call.
2. Appending to another stream leaves the first stream's head position unchanged while the
   store-wide visible head moves.
3. Soft-deleting the stream or setting `truncateBefore` leaves the head position unchanged;
   hard-deleting the stream makes `getStream` answer `Nothing`, as today.
4. A deliberately failing decode hook does not affect the call: no event payload passes through
   the read or decode path.
5. The production statement's EXPLAIN uses `ix_stream_events_all_by_origin` for the head probe
   with no `Sort` node and no scan of `stream_events` beyond the probe, using the existing schema
   and natural planner settings.
6. The direct and resource-backed runners and a mock `Store` interpreter expose the value with the
   same semantics; the mock change is the only source-breaking consequence if shape (a) is chosen,
   and the changelog names it.
7. Haddocks contrast the stream head with `version` (a count, not a position), with
   `visibleGlobalHeadPosition` (store-wide), and with the append frontier, and give the
   read-your-writes example: "check `version >= N`, then wait for the projection cursor to reach
   `headGlobalPosition`".

## Follow-up

When released, the notification render service replaces its category-head proxy
(`Server/Seam.hs` `categoryHead` and the `otherwise` branch of `Handler.hs` `floored`) with the
stream's own head position, with no change to its HTTP contract, and updates the two rows of its
pattern register that describe the proxy. A later request to Keiro may add a freshness mode that
takes a stream name and version directly and resolves it through this read, so consumers of the
platform convention need no handler-level translation at all.
