---
type: Improvement Request
title: Report the global position on single-stream reads
description: >-
  readStreamForward and readStreamBackward select 0 for global_position ("not available without
  $all join"), so every event read from one stream — kiroku-inspect's /streams/{name}/events and
  every library built on stream reads — carries no position, while docs/user/reading-events.md
  says the field is the $all position. Report the real position on stream reads, or, if the join
  is too costly, document the 0 sentinel and expose the position another way.
timestamp: "2026-10-26T02:29:20Z"
requestId: IR-20
status: proposed
origin: mori://shinzui/keiro-ui
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-26T02:29:20Z"
    document_timestamp: "2026-10-26T02:29:20Z"
    scope: status-and-plan-traceability
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked both stream-read SQL statements, the public reading guide and the
      owning plan inventory. Both statements still return the zero sentinel;
      Plan 97 supplies a stream head rather than each event's global position.
      The proposed status is accurate and no dedicated implementation plan exists.
      This review does not claim implementation or release acceptance.
---

# Improvement Request: Report the Global Position on Single-Stream Reads

## Status

Proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/16-build-the-aggregates-process-managers-and-timers-screens`
(found first through keiro's workflow journal in
`mori://shinzui/keiro-ui/plans/15-build-the-workflows-screens`). An improvement, not a
dependency.

No dedicated Kiroku implementation plan exists as of 2026-10-25; status remains
`proposed`. [ExecPlan 97](../plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md)
completed [IR-18](expose-a-streams-head-global-position-from-getstream.md) by exposing
an opt-in stream-head metadata read. It deliberately preserves the zero sentinel
on per-event stream reads and does not fulfill this request. The browsing routes
implemented by [ExecPlan 88](../plans/88-expose-a-rest-read-api-for-browsing-streams-categories-and-events.md)
also retain that sentinel through the existing Store reads.

## Context

`readStreamForwardSQL` and `readStreamBackwardSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs`
select `0::bigint AS global_position`; their comment says the position is "not available without
$all join". The `$all` and category reads select the real value. `docs/user/reading-events.md`
describes `globalPosition` as "Position in the global `$all` sequence at original-append time" and
says `$all` never returns position 0, without mentioning that stream reads report 0.

Observed on 2026-10-21 against kiroku-inspect (kiroku-metrics 0.3.0.1) on the jitsurei database:
`GET /streams/order-demo-…/events` answers `globalPosition: 0` for `OrderPlaced`, while
`GET /events` and `GET /categories/order/events` answer `globalPosition: 1` for the same event id.
Every consumer that reads streams inherits the 0: keiro's workflow journal entries
(`readWorkflowJournalPage`) and its process managers' last reaction report `global_position: 0`.

## Console behaviour today

The console treats a 0 global position as "not reported" (no `$all` event has position 0) and
shows those words instead of a number in stream event tables and the process-manager reaction
card. Where the position matters — the workflow journal-entry sheet's "open in the $all log" link
and its journal-stream link — it reads the event by id from `GET /events/{id}`, which reports the
real position and stream name. Everything else works unchanged. With this change the stream
tables would show positions again and the extra lookup would go away.

## Requested Change

One of:

1. Join each stream read to the event's `$all` entry so `global_position` is the real value, with
   the cost measured against the current stream-read benchmarks; or
2. If the join is too costly for the hot path, keep 0 but (a) say so in
   `docs/user/reading-events.md` and on `RecordedEvent.globalPosition`, and (b) give
   kiroku-inspect's `/streams/{name}/events` the real positions (or an opt-in parameter for them),
   since that route serves people rather than the hot path.

## Acceptance

1. `GET /streams/{name}/events` reports the same `globalPosition` for an event as `GET /events/{id}`
   (option 1, or option 2b); or the documentation states the sentinel (option 2a).
2. A regression test reads one event through a stream read and through `$all` and compares the
   positions (or asserts the documented sentinel).
