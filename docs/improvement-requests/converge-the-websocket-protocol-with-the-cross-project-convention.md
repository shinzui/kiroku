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
timestamp: "2026-10-11T02:24:04Z"
requestId: IR-12
status: in_progress
origin: mori://shinzui/keiro-ui
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-11T01:56:12Z"
    scope: authoring-metadata
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked the required title, description, request identity, lifecycle, origin and
      timestamp metadata against the bundle profile. This is an authoring-metadata
      review only; source claims, implementation acceptance and release evidence were
      not reviewed here.
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

Accepted by kiroku on 2026-09-30. Implementation is under way under
[ExecPlan 94, Converge the kiroku-metrics WebSocket protocol with the cross-project convention](../plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention.md)
(`mori://shinzui/kiroku/plans/94-converge-the-kiroku-metrics-websocket-protocol-with-the-cross-project-convention`),
EP-5 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md)
(`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`).
The audit behind that plan corrected one candidate gap and found two others: both WebSocket
paths already run a 30-second server ping thread, so idle pings are met; the metrics channel
pushes without a subscribe frame (to be closed additively with an `unsubscribe_metrics` frame
and a documented deviation); `error` frames carry no stable code (to gain an optional
snake_case `code`); and the in-band overflow `error` frame the guide documents is never emitted
under the tail's `DropOldest` policy, which the plan fixes with a publisher drop counter in
`kiroku-store`. The plan also adds `original_stream_name` to `event` frames so a client can
name the source stream without a lookup, sharing one event object with the REST browse items.
The request moves to `in_progress` when the plan's first milestone starts and to `completed`
once the cohort release is published.

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

## Implementation Evidence (unreleased)

ExecPlan 94 implements explicit metrics stop/resume, four sanitized error codes,
resolved source names on live/replay/category event objects, and drop-oldest loss
notices before affected survivors. The public publisher counter increments only
on actual drops; the old triple-returning API remains available. Name resolution
uses at most one lookup per batch and a bounded per-tail 4096-name FIFO cache.

`kiroku-metrics/test/Test/WebSocketConvergenceSpec.hs` has 21 examples covering
frozen frames, real protocol lifecycle/read failures, cache bounds, scoped worker
cancellation/failure and the production overflow delivery loop. Its gated writer
proves notice-before-survivor order and recovery from the pre-notice cursor.
`kiroku-store/test/Test/PublisherDropCounter.hs` covers actual policy counters,
newest-batch retention and idempotent legacy deregistration. The original
`Test.WebSocketSpec` remains unchanged; the metrics suite reports 98 passing examples.

The ten-element [guide mapping](../user/metrics.md#conformance-with-the-cross-project-websocket-convention)
records typed frames, lifecycle, ping/pong, replay cursor, initial snapshot,
incremental frames, idle pings, in-band loss/error reporting, goodbye and bounded
queues. Both paths already had 30-second server pings. Event-stream acknowledgement,
metrics push-on-connect and complete periodic snapshots remain documented dialect
deviations. Earlier drop-oldest notices were unreachable; the counter now makes
that promised signal observable and correctly ordered.

`kiroku-metrics:kiroku-websocket-tail` compares frozen encoding and warm/cold
bounded resolution alongside local appends; retained logs belong to plan 94.
Local correctness is separate from cumulative performance and publication.
Status remains `in_progress` until plan 96 releases the cohort and records acceptance.

All 654 examples across six suites, the ten-step example and both Nix package builds pass. [Retained local evidence](../../kiroku-metrics/bench/results/mp13-ep5-websocket-convergence/README.md) includes adverse samples, setup/fixture failures, a bounded original-publisher comparison and the final faithful tail-control comparison. No cumulative performance or publication verdict is inferred.
