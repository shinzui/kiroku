---
type: Improvement Request
title: Report the delivery phase of each event to the Shibuya adapter
description: >-
  Let the Shibuya adapter know whether a subscription event was delivered during catch-up or
  while live, and put that on the event's processing span, so an operator can tell replayed
  work from live work on a single span and a later trace-correlation rule can treat the two
  differently.
generated:
  by: anthropic/claude-fable-5-2
  at: "2026-11-12T03:52:01Z"
timestamp: "2026-11-12T03:52:01Z"
requestId: IR-21
status: proposed
origin: mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: "2026-11-12T03:52:01Z"
    document_timestamp: "2026-11-12T03:52:01Z"
    scope: authoring-metadata
    outcome: comments
    provider: anthropic
    model: claude-fable-5-2
    context: >-
      Self-check by the authoring model of the required title, description, request identity,
      lifecycle, origin and timestamp metadata against the bundle profile. This is an
      authoring-metadata review only; the request has not been independently reviewed, and
      its source claims were read from kiroku-otel and the adapter but not tested.
---

# Report the delivery phase of each event to the Shibuya adapter

## Status

Proposed on 2026-11-12. No implementation plan exists. This request is not blocking: the
originating Shibuya MasterPlan
(`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`) and
its Kiroku child plan
(`mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default`)
complete without it.

## Why this is a request

A Kiroku subscription worker is in one of two delivering phases: catching up from its
checkpoint, or live. `kiroku-otel` already reports the phase on its own spans:
`Kiroku.Otel.Subscription` emits one `kiroku.subscription.deliver` span per delivered batch with
the attribute `kiroku.subscription.state` set to `"catchup"` or `"live"`.

The `shibuya-kiroku-adapter` cannot report it. The adapter receives a plain
`Stream IO RecordedEvent` from `subscriptionStream` and builds each envelope from the event and
from constants derived from its configuration (`kirokuEnvelopeAttrs`: subscription name and
consumer-group member). Nothing in what it receives says which phase delivered an event, so
Shibuya's per-event processing span carries `kiroku.subscription.name`, `kiroku.event.type` and
`kiroku.event.global_position` but not the phase.

Two consequences follow.

First, the two instrumentations are harder to read together than they could be. The native
subscription spans and Shibuya's processing spans are separate traces: every native span is
created with an empty context (`createSpan tracer Context.empty` in
`kiroku-otel/src/Kiroku/Otel/Subscription.hs`), so they are correlated only by matching
`kiroku.*` attribute values. An operator looking at one slow or failed processing span cannot
tell from that span whether it was replayed history or live traffic; they must find the
neighbouring native spans by subscription name and time.

Second, the phase is the natural input for trace correlation. `shibuya-core` 0.13 lets an
adapter choose whether a processing span is a child of the span that appended the event or a
separate trace linked to it. The Kiroku adapter will default to link-only, because replayed
events are processed long after the appending trace ended. That reasoning applies to catch-up,
not to live delivery, where joining the appender's trace is reasonable. The policy is one value
per adapter today because the adapter has no per-event signal to decide on. The phase is that
signal. Shibuya's policy lives in an extensible `AdapterTelemetry` record precisely so that a
per-message rule can be added later without a breaking change; this request supplies the Kiroku
half.

## Requested change

1. Make the delivery phase of each event available to the code that builds Shibuya envelopes,
   without changing what existing `subscriptionStream` callers receive and without adding work
   to the write path or to subscriptions that do not ask for it. Whether this is a parallel
   stream variant, a tagged element type, or a phase accessor consulted at delivery is for the
   implementation to decide.
2. In `shibuya-kiroku-adapter`, add the phase to `Envelope.attributes` under the existing key
   `kiroku.subscription.state` with the same values `kiroku-otel` uses (`"catchup"`, `"live"`),
   so one query matches both instrumentations.
3. Expose the phase to adapter users in a form a future per-message correlation rule can read.
   Choosing or implementing such a rule is out of scope here; it belongs to Shibuya.

Not requested: linking Shibuya's processing span to the native `deliver` span. That span opens
and ends immediately as a marker, so a link to it would add little beyond the shared attributes
and would require carrying a span context alongside every delivered event.

## Acceptance

With tracing enabled and a subscription started behind a backlog, events processed before the
worker reports caught-up carry `kiroku.subscription.state = "catchup"` on their Shibuya
processing spans, and events appended afterwards carry `"live"`. The values agree with the
`kiroku.subscription.state` on the native `deliver` span that covered the same event. The same
holds for every member of a consumer group. Existing `subscriptionStream` callers compile and
behave unchanged, and Kiroku's performance gates
([ADR 0005](../adr/0005-three-tier-performance-regression-gates.md)) show no regression in
append or delivery throughput.
