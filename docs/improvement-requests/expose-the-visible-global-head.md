---
type: Improvement Request
title: Expose the visible global head
description: >-
  Let consumers read the greatest global position that is still visible in $all through a cheap
  public Store operation, without decoding an event or mistaking the monotonic append frontier for
  a reachable subscription position after hard deletion.
generated:
  by: openai/gpt-5
  at: "2026-08-12T16:20:30Z"
timestamp: "2026-08-12T16:20:30Z"
requestId: IR-4
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-12T16:20:30Z"
    document_timestamp: "2026-08-12T16:20:30Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against kiroku-store source at dedb99f and Keiro Plan 238. Kiroku currently exposes
      payload-bearing readAllBackward and the authoritative subscription-inventory storePosition,
      but no payload-free Store operation for the greatest surviving $all junction position.
      Hard deletion removes those junctions without reducing the authoritative append frontier.
verified:
  by: process:codex
  at: "2026-08-12T16:20:30Z"
---

# Improvement Request: Expose the Visible Global Head

## Status

Proposed as the owning-library follow-up to
`mori://shinzui/keiro/plans/238-target-strong-consistency-waits-at-the-visible-store-head`.
Keiro can correct its release-blocking wait-target defect with a temporary private query, so this
request does not gate that plan. Once a released Kiroku API is available, Keiro should adopt it and
remove its Kiroku-schema query rather than retain two implementations of the same storage fact.

## Context

Kiroku has two intentionally different global positions:

- The *authoritative append frontier* is the monotonic position allocated by the `$all` stream.
  `SubscriptionCheckpointInventory.storePosition` reports this value. Hard deletion never reduces
  it, so it remains useful for allocation, auditing, and bounded replay ceilings.
- The *visible global head* is the greatest global position whose event is still present in
  `$all`, or `GlobalPosition 0` when no event remains. It can regress when hard deletion removes
  the visible tail.

The current public `readAllBackward (GlobalPosition 0) 1` call can discover the visible head, but
it fetches the newest event's full row and invokes the configured decode hook. Consumers that only
need a position therefore pay payload I/O and decoding cost, and an unrelated decode failure can
prevent them from observing a storage position.

The public checkpoint inventory answers a different question. Its `storePosition` deliberately
reports the authoritative append frontier from the `$all` stream row in the same snapshot as the
checkpoint rows. Reinterpreting or changing that field to mean “visible head” would break its
contract and erase information. The proposed API must keep both facts distinct.

Keiro exposed the error caused by conflating them. A caught-up projection checkpoint rests at the
latest event its subscription consumed. If workflow garbage collection or another caller
hard-deletes newer tail events, the append frontier stays above every remaining event and no idle
subscription can checkpoint that absent position. A wait targeted at the append frontier then
times out even though the projection has no visible work. This is a Keiro bug, but the visible head
it needs is a Kiroku-owned storage fact.

The separate request
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` proposes an authoritative current
global position and bounded replay windows. That monotonic replay ceiling remains correct even
when positions inside the window have been hard-deleted. IR-4 requests the distinct visible
frontier needed for reachability and actionable backlog calculations.

## Requested Change

Add an additive, read-only `kiroku-store` operation with these semantics:

1. Return the greatest currently visible global position in `$all`, or `GlobalPosition 0` when no
   event is visible.
2. Execute as a scalar position query. Do not fetch event data or metadata and do not invoke the
   store's decode hook.
3. Expose the operation through the mockable `Store` effect and a public read module such as
   `Kiroku.Store.Read`; consumers must not import a package-internal Hasql statement.
4. Define visibility to match Kiroku's global reads. Soft deletion and logical truncation do not
   hide events from `$all`; hard deletion removes them and may make the visible head regress.
5. Keep `SubscriptionCheckpointInventory.storePosition` and any authoritative
   `currentGlobalPosition` API unchanged. Documentation must name the difference and warn against
   using the append frontier as a generally reachable subscription checkpoint target.
6. Document each result as one statement-time observation, not a frozen snapshot. A concurrent
   append or hard deletion may change the answer immediately after the call returns.

One possible public shape is:

```haskell
visibleGlobalHeadPosition ::
    (HasCallStack, Store :> es) =>
    Eff es GlobalPosition
```

The final name belongs to Kiroku. It should contain enough “visible” and “head” terminology that a
caller cannot reasonably confuse it with the monotonic append frontier.

## Boundaries

This request does not change global-position allocation, hard-deletion behavior, checkpoint
advancement, subscription delivery, or the checkpoint inventory. In particular, it does not ask a
subscription to checkpoint deleted positions or manufacture progress when an empty fetch occurs.

It does not ask Kiroku to implement query freshness, projection waits, projection lag, workflow
garbage collection, or operator rendering. Keiro owns those policies and decides when a visible
head is the correct operand.

This request is limited to the global `$all` head. A constant-cost category-visible-head operation
may be useful to filtered consumers, but it has different indexing and ownership questions and is
not required to resolve the defect that originated this request.

The operation does not promise that a captured event will remain visible. If a concurrent hard
delete removes the captured tail before a consumer reaches it, the consumer must apply its own
timeout or retry policy. The API reports visibility at capture time; it does not provide a
long-lived database snapshot.

## Acceptance

1. An empty migrated store returns `GlobalPosition 0` without reading or decoding an event.
2. After appending events at positions 1 through 3, the operation returns position 3.
3. Hard-deleting a non-tail stream leaves the result unchanged; hard-deleting the stream that owns
   position 3 makes the result fall back to the greatest surviving position, or zero if none
   survives. The authoritative append frontier remains 3 in both cases.
4. Soft deletion and logical truncation leave the visible global head unchanged, matching
   `readAllForward` and `readAllBackward` visibility.
5. A deliberately failing decode hook does not affect the operation, proving that no event payload
   passes through the read or decode path.
6. Both concrete pool interpreters and a mock `Store` interpreter expose the operation with the
   same result semantics.
7. Haddocks and the reading-events or subscription guide contrast the visible head with
   `SubscriptionCheckpointInventory.storePosition` and include the hard-deleted-tail example.
8. A downstream consumer can replace private SQL with the public operation and preserve tests for
   empty, caught-up, genuinely behind, hard-deleted-tail, and timeout behavior.
