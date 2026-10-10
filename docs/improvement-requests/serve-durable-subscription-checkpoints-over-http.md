---
type: Improvement Request
title: Serve durable subscription checkpoints over HTTP
description: >-
  Serve the durable, cross-process subscription checkpoint inventory over HTTP in kiroku-metrics
  alongside the existing in-process registry, with the live-versus-durable distinction explicit in
  the response shape, so a UI can show every subscription's persisted position no matter which
  worker it asks.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-10-10T17:39:38Z"
requestId: IR-10
status: in_progress
origin: mori://shinzui/keiro-ui
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-10T17:32:47Z"
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

# Improvement Request: Serve Durable Subscription Checkpoints over HTTP

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). The
library-level capability this endpoint wraps already shipped:
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` is completed, and
`subscriptionCheckpointInventory` has been public in `kiroku-store` since 0.4.0.0. This request
asks only for the missing HTTP surface. Implementation is kiroku's own downstream work under
kiroku's plans.

Implementation is in progress under the plan accepted by kiroku on 2026-09-10:
[ExecPlan 87, Serve durable subscription checkpoints over HTTP](../plans/87-serve-durable-subscription-checkpoints-over-http.md)
(`mori://shinzui/kiroku/plans/87-serve-durable-subscription-checkpoints-over-http`), which
finalizes the route as `GET /subscription-checkpoints` and keeps the live `GET /subscriptions`
route unchanged.

Since 2026-09-30 that plan is EP-2 of
[MasterPlan 13, Expose the Kiroku inspection surface for the keiro runtime UI and a standalone Kiroku UI](../masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md)
(`mori://shinzui/kiroku/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui`),
which coordinates IR-8 through IR-12 as one cohort; plan 87 also introduces the server
composition record every other route in the cohort extends. The release moved out of plan 87:
the request remains `in_progress` until the cohort release, performed by
[ExecPlan 96](../plans/96-release-the-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md),
is published; only then does it move to `completed`.

## Context

`GET /subscriptions` in `kiroku-metrics` reads the in-process live registry
(`subscriptionStates`) of whichever worker the request happens to hit. That view is honest about
what it is — live worker FSM cursors — but it cannot answer the durable question a UI dashboard
needs: what is every subscription's persisted checkpoint, including subscriptions whose workers
are stopped, and subscriptions running in other processes? A stopped worker vanishes from the
registry while its durable row remains; a multi-process deployment shows a different registry
per process; and when no status provider is wired, the route 404s.

The durable answer already exists at two lower layers, both delivered under completed requests:
`subscriptionCheckpointInventory` (IR-2; durable, cross-process, one round trip, includes the
captured `storePosition`) and the frozen SQL relation `kiroku.subscription_checkpoints_v1`
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-5`, recorded in
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`). Neither is reachable over HTTP, so a browser
UI — which speaks neither Haskell nor SQL — cannot see durable subscription state at all.

Wire-format details follow the cross-project inspection conventions
(`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level URI
pending): snake_case new fields, structured error envelope, and the vocabulary rule that
distances derived from the captured store position are position distances, not "lag".

## Requested Change

1. A new endpoint in `kiroku-metrics` — for example `GET /subscriptions/checkpoints` (the exact
   route is kiroku's to finalize) — serving `subscriptionCheckpointInventory`: the captured
   `store_position` plus one entry per durable checkpoint row with the subscription name,
   consumer-group member, exact persisted position, and last-update timestamp, in the
   operation's deterministic (name, member) order.
2. The live-versus-durable distinction stays explicit: the durable endpoint's response shape
   must be visibly distinct from the live registry's (distinct route and documented semantics —
   values are exact persisted checkpoints; stopped subscriptions remain present; a live worker's
   cursor may be ahead), so a UI can render both truthfully side by side. Whether kiroku
   additionally offers a combined view is kiroku's choice; the durable-only endpoint is the
   request.
3. Unlike the live registry, this endpoint must not depend on a wired status provider: any
   process with store access can serve it, and it answers identically no matter which process is
   asked.

## Boundaries

This request is read-only serving of the existing inventory. It does not ask for checkpoint
reset, rewind, deletion, lifecycle control, consumer-group rebalancing, or any new library
capability — IR-2's Boundaries hold here unchanged. It does not ask kiroku to compute lag,
freshness verdicts, or projection semantics; consumers derive what they need from
`store_position` and the checkpoint positions.

## Acceptance

1. With one subscription checkpointed and its worker stopped, `GET /subscriptions/checkpoints`
   (or the finalized route) returns HTTP 200 with the subscription's row — while
   `GET /subscriptions` no longer lists it — demonstrating the durable/live distinction.
2. The response includes the captured `store_position` from the same snapshot as the rows, and
   rows appear in ascending (subscription name, member) order.
3. Two processes sharing one store return the same durable inventory for the same store state,
   regardless of which registered which workers.
4. The endpoint works on a process with no subscription status provider wired (where
   `GET /subscriptions` returns its 404), returning the durable inventory normally.
5. An empty store returns `store_position` 0 and an empty row list, per IR-2's semantics.
6. Existing endpoints and frames are unchanged.

## Requested Deliverables

The `kiroku-metrics` route with tests and `docs/user/metrics.md` documentation including a
request/response transcript and an explicit live-versus-durable explanation; changelog entries
and PVP-appropriate version bumps, at kiroku's discretion.


## Implementation Evidence

The unreleased source serves `GET /subscription-checkpoints` through
`Kiroku.Metrics.Checkpoints` and the shared `ServerProviders` composition in
`Kiroku.Metrics.Server`. Its object carries `store_position` and ordered `checkpoints`
rows with `subscription`, `member`, `checkpoint_position`, and `updated_at`.
Store-backed legacy starters wire durable reads while preserving the live configured-404.
The new route leaves `/subscriptions/checkpoints` available for that live subscription name.

`kiroku-metrics/test/Test/CheckpointsSpec.hs` pins the codec, retained stopped-worker rows,
quiescent cross-handle equality, no-live-provider behavior, method handling, sanitized errors,
CORS, prefix mounts, readiness and resource cleanup. The guide is
[Durable subscription checkpoints over HTTP](../user/metrics.md#durable-subscription-checkpoints-over-http);
`kiroku-metrics/example/Main.hs` verifies an empty checkpoint array with real HTTP.
Release and cumulative append-under-observer performance acceptance remain with plan 96.
