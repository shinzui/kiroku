---
type: Improvement Request
title: Converge the WebSocket protocol with the cross-project convention
description: >-
  Align the kiroku-metrics WebSocket surface with the cross-project inspection protocol
  convention through strictly additive changes — published frames stay frozen — and document the
  conformance mapping, so the composed UI can drive all runtime WebSocket surfaces with one
  client core.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-08-19T00:00:00Z"
requestId: IR-12
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Converge the WebSocket Protocol with the Cross-Project Convention

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). The
convention this request references is recorded in
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` and elaborated in the initiative's conventions
document (`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`,
artifact-level URI pending, area 5). Implementation is kiroku's own downstream work under
kiroku's plans.

## Context

The keiro runtime stack has two shipped WebSocket inspection dialects — kiroku-metrics
(`/ws/metrics`, `/ws/events`) and shibuya-metrics (`/ws`) — and more are coming (pgmq-hs and
keiro surfaces are being requested by the same initiative). To avoid one bespoke browser client
per dialect, the initiative defined a structural convention that is deliberately a superset of
both shipped dialects: typed JSON frames with a required `type` tag; explicit subscribe and
unsubscribe frames; an initial `snapshot` after subscribe, then incremental frames; `ping`/`pong`
with servers pinging idle connections; in-band `error` frames including bounded-queue overflow
signaling; `goodbye` before server-initiated close; and replay cursors (`from_position`) where
the domain has them.

kiroku's `/ws/events` already fits this shape almost entirely — it is the origin of several of
the convention's rules (replay cursors, DropOldest bounded queues with in-band overflow
`error`, `event_stream_started`, `goodbye`). The convention's frozen-dialect rule
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`) applies in both directions: kiroku's
published frames — including the camelCase field names inside event payload objects — stay
exactly as shipped, and any convergence is strictly additive.

## Requested Change

1. kiroku audits its two WebSocket paths against the convention (the ten-point frame shape in
   conventions area 5) and identifies each gap. Known candidates from the initiative's audit,
   for kiroku to confirm or correct: `/ws/metrics` pushes periodic snapshots on connect without
   an explicit subscribe/unsubscribe lifecycle, and idle-connection server pings may not run on
   both paths.
2. Where a gap can be closed additively — for example, accepting an optional subscribe frame on
   `/ws/metrics` while preserving today's push-on-connect behavior for existing clients, or
   adding server-side idle pings — kiroku closes it as it sees fit.
3. Where a gap cannot be closed additively, kiroku documents the deviation instead of breaking
   the published protocol; the convention's frozen-dialect rule makes documented deviation the
   correct outcome, not a compromise.
4. `docs/user/metrics.md` (or a sibling document) gains a short conformance mapping: for each
   convention element, the kiroku frame(s) that realize it or the recorded deviation. This
   mapping is what the composed UI's client core is built against.

## Boundaries

No breaking changes are requested or acceptable: no renaming, removal, or re-typing of any
published frame or field, no change to `wsEventQueueCap`/overflow semantics, no protocol
version negotiation. This request does not cover new data endpoints (those are
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8`,
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-9`, and
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-10`) or CORS on the upgrade path
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-11`).

## Acceptance

1. A client written against the shipped protocol (the frame inventory in
   `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs` as of commit `c2d0328`) connects and
   operates unchanged against the converged server — demonstrated by the existing tests
   continuing to pass without modification.
2. Every convergence change is additive: a new frame type, a new optional field, or new
   documented behavior — never a change to an existing frame's shape or meaning.
3. The conformance mapping exists in kiroku's documentation and covers every element of the
   convention (typed frames, subscribe/unsubscribe, snapshot-then-delta, ping/pong, bounded
   queues with in-band overflow signaling, `goodbye`, replay cursors), each marked as met,
   additively closed, or a documented deviation.
4. Any newly added frames use snake_case fields and are documented with example JSON.

## Requested Deliverables

The gap audit outcome (however kiroku records it), the additive protocol changes with tests,
and the conformance mapping in user documentation; changelog entries and PVP-appropriate
version bumps, at kiroku's discretion.
