---
type: Improvement Request
title: Expose bounded fan-in replay windows
description: >-
  Let callers capture Kiroku's global head and page $all or one category through that inclusive
  bound, so offline replays terminate against an immutable logical window even while new events
  continue to arrive.
generated:
  by: openai/gpt-5
  at: "2026-08-08T00:13:03Z"
timestamp: "2026-08-08T00:13:03Z"
requestId: IR-1
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-08T00:13:03Z"
    document_timestamp: "2026-08-08T00:13:03Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against kiroku-store 0.3.1.0 and current master: public fan-in reads return one
      unbounded Vector page; only the single-stream forward read has a Streamly wrapper; and the
      cheap currentGlobalPositionStmt used by the internal publisher is not exposed through the
      Store effect. Keiro can build fixed-head replay from the existing calls, so this request is
      useful hardening and reuse rather than a blocker.
verified:
  by: process:codex
  at: "2026-08-08T00:13:03Z"
---

# Improvement Request: Expose Bounded Fan-In Replay Windows

## Status

Proposed as a non-blocking dependency-side companion to
`mori://shinzui/keiro/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds`,
particularly its deterministic replay work. Keiro can initially implement the same semantics over
Kiroku's existing public reads. Adopting a Kiroku API should be gated on released availability and
should remove, rather than duplicate, Keiro's compatibility loop.

## Context

The released `kiroku-store-0.3.1.0` public API provides these fan-in reads:

```haskell
readAllForward :: GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
readAllBackward :: GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
readCategory :: CategoryName -> GlobalPosition -> Int32 -> Eff es (Vector RecordedEvent)
```

The forward cursors are exclusive and results are ordered by ascending global position. A caller
can therefore approximate a fixed replay window by reading one event backward from position zero
to discover a head `H`, repeatedly reading forward from its last position, discarding anything
after `H`, and treating the first empty or beyond-`H` page as completion.

That is enough for Keiro to proceed, but the logical contract is not represented in the API. Each
offline projector must reproduce the same termination, empty-store, page-boundary, and concurrent
append reasoning. The existing `readStreamForwardStream` centralizes paging for one named stream,
but `$all` and category fan-in have no equivalent. More importantly, an unbounded short page does
not itself prove that a captured target was reached when writers may append concurrently.

Kiroku already has a cheap internal `currentGlobalPositionStmt` that reads the `$all` stream row
without decoding a full event. `EventPublisher` uses it at startup and while no subscriber needs
event rows. The missing capability is a public, mockable Store operation for that frontier plus
forward pages whose SQL-level range includes an explicit upper bound.

## Requested Change

Add an additive `kiroku-store` read contract with these semantics:

1. Expose the current global position through `Kiroku.Store.Read` and the `Store` effect. An empty
   store returns `GlobalPosition 0`; callers do not need to decode the latest event merely to
   capture a replay target.
2. Add bounded forward page primitives for `$all` and a single `CategoryName`. Each takes an
   exclusive lower cursor, an inclusive upper cursor, and a positive page size, and returns events
   in strictly ascending global-position order with `lower < position <= upper`.
3. Make completion relative to the upper bound observable. A page shorter than the requested size
   (including an empty page) proves there are no more currently visible matching events through
   the bound. This lets a category with no event at exactly `upper` still prove it scanned through
   the captured frontier.
4. Prefer SQL predicates that enforce the upper bound rather than fetching an unbounded page and
   filtering in Haskell. Events appended after capture must neither appear in the result nor keep
   a correctly written replay alive.
5. Provide constant-memory Streamly wrappers if they can retain the same completion contract
   clearly. The bounded page operations are the required primitive; a stream of events alone must
   not obscure how a caller proves an empty or sparse category reached its target.
6. Preserve existing visibility semantics for hard-deleted and soft-deleted streams. A bounded
   window freezes its upper position, not the database's lifecycle state, and must not claim
   snapshot-isolation or historical completeness that Kiroku does not provide.

One possible additive shape is:

```haskell
currentGlobalPosition ::
    (HasCallStack, Store :> es) =>
    Eff es GlobalPosition

readAllForwardThrough ::
    (HasCallStack, Store :> es) =>
    GlobalPosition ->  -- exclusive lower cursor
    GlobalPosition ->  -- inclusive captured head
    Int32 ->
    Eff es (Vector RecordedEvent)

readCategoryForwardThrough ::
    (HasCallStack, Store :> es) =>
    CategoryName ->
    GlobalPosition ->  -- exclusive lower cursor
    GlobalPosition ->  -- inclusive captured head
    Int32 ->
    Eff es (Vector RecordedEvent)
```

The final names and whether completion is represented by short-page semantics or an explicit page
record belong to Kiroku. If an explicit record is chosen, it should carry the next exclusive cursor
and whether the upper frontier has been exhausted so consumers do not infer those facts from vector
length inconsistently.

## Boundaries

This request does not ask Kiroku to understand projection catalogs, persist projection progress,
merge several categories, or coordinate target-table writes. Keiro owns those concerns. In
particular, Keiro may perform a k-way merge of independently bounded category pages when a rebuild
group consumes several categories and must retain total global order.

This request also does not require one long database transaction or exported snapshot across an
entire replay. The captured `GlobalPosition` is a logical inclusive ceiling. Existing Kiroku hard
deletion semantics remain visible and must be documented as a separate limitation.

## Acceptance

1. On an empty store, head capture returns zero and bounded `$all` and category reads complete with
   no events.
2. With events at global positions 1 through 10 and a captured head of 7, every page size from 1
   through 10 yields exactly positions 1 through 7, without duplicates, gaps, or position 8.
3. Events appended concurrently after head capture never appear and do not prevent completion.
4. A sparse category whose last matching event is below the captured head can still prove it has
   exhausted that head. A category with no matching events has the same proof.
5. Exclusive-lower and inclusive-upper behavior is pinned at page boundaries, including
   `lower == upper`, an upper bound beyond the current head, and invalid reversed bounds.
6. `$all` and category results remain globally ordered and retain the same soft-delete,
   hard-delete, link, metadata-enrichment, and decode-hook behavior as their existing unbounded
   counterparts.
7. A mock `Store` interpreter can implement and assert the new operations without depending on
   Hasql internals.
8. Haddocks and the reading-events guide include a copyable captured-head replay example and state
   that the bound does not prevent later hard deletion from changing visible history.
