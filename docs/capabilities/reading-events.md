---
title: "Read streams, categories, and the global log"
type: Capability
description: "Read events forward or backward from a single stream, a category, or the totally ordered global $all log, including a constant-memory streaming read and batch surrogate-id resolution."
generated:
  by: anthropic/claude-sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/kiroku
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - kiroku-store
interface:
  - Kiroku.Store.Read
  - Kiroku.Store.Types
requires:
  - CAP-2
evidence:
  - kind: test
    resource: kiroku-store/test/Test/ReadStream.hs
    proves: Forward/backward single-stream reads, exclusive-cursor pagination, and soft-deleted-stream read visibility.
  - kind: test
    resource: kiroku-store/test/Test/Category.hs
    proves: Category reads over the streams.category generated column.
  - kind: test
    resource: kiroku-store/test/Test/StreamNameLookup.hs
    proves: lookupStreamNames resolves batches of surrogate stream ids to names in a single round trip.
  - kind: guide
    resource: docs/user/reading-events.md
    proves: The read API surface and the cursor conventions.
---

# Read streams, categories, and the global log

Read events by stream (`readStreamForward` / `readStreamBackward`), by category
(`readCategory`), or across the totally ordered global log (`readAllForward` / `readAllBackward`).
`readStreamForwardStream` is a Streamly companion that paginates internally for constant-memory
folds over long streams. `getStream`, `lookupStreamId`, `lookupStreamNames`, and
`eventExistsInStream` cover metadata and surrogate-id resolution. Reads run against an acquired
store — see [store acquisition](store-acquisition.md).

## Usage

```haskell
events <- readStreamForward (StreamName "order-42") (StreamVersion 1) 100
```

## Limits

- Backward reads paginate with an **exclusive upper bound** (since `0.3.0.0`): a nonzero cursor
  returns events *older* than it, while cursor `0` maps to `maxBound` (= "from the latest").
  Any pre-`0.3.0.0` caller passing a nonzero backward cursor gets different results.
- `RecordedEvent` deliberately carries no source stream name on fan-in reads (`$all`, categories,
  causation/correlation) — only the surrogate `originalStreamId`. Recover names with
  `lookupStreamNames`; carrying the name on every row cost ~13% on `$all` pages.
- `GlobalPosition` is an opaque, strictly-increasing cursor: never construct one by arithmetic and
  never assume density (`pos + 1` may not exist), even though the current implementation happens
  to assign contiguous positions.
- Per-stream ordered reads hide events below a stream's truncate-before marker (CAP-9); the
  global `$all` log, categories, and subscriptions are unaffected.
