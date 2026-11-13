---
type: Architecture Decision Record
title: Shibuya processing spans link to the appending span by default
description: "The Shibuya Kiroku adapter defaults to LinkOnly trace correlation, so each processed event starts its own trace linked to the span that appended it, with ParentAndLink available per adapter or consumer group."
generated:
  by: anthropic/claude-opus-5-5
  at: "2026-11-13T18:10:00Z"
docId: ADR-24
status: Accepted
date: 2026-11-13
timestamp: "2026-11-13T18:10:00Z"
originatingPlan: mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default
---

# ADR-0024: Shibuya processing spans link to the appending span by default

- **Related:** Shibuya's correlation contract, ADR 0014 in `mori://shinzui/shibuya`
  (`docs/adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md`; the
  artifact-level URI is pending);
  `mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`;
  [OpenTelemetry trace context](../capabilities/opentelemetry-trace-context.md);
  [OpenTelemetry subscription tracing](../capabilities/opentelemetry-subscription-tracing.md);
  [ADR-2](0002-static-hash-partitioned-consumer-groups.md).

## Context

`kiroku-otel`'s `injectTraceContext` writes the appending span's W3C `traceparent` into an
event's metadata, and `shibuya-kiroku-adapter` copies it into the Shibuya envelope. From
`shibuya-core` 0.13 an adapter declares how Shibuya's per-event Consumer span relates to that
creation context: `ParentAndLink` makes the processing span the appending span's child and also
links to it; `LinkOnly` starts a new trace whose root links to it. Without a usable
`traceparent` neither policy adds a link. Batch spans are always roots with bounded links.

Until 0.8.0.0 the adapter had only the parent-child shape. For an event store that shape is
usually wrong. A subscription started from the beginning, or catching up after downtime,
processes events whose appending trace ended long ago, so every replay extends that old trace.
Several subscriptions, and every consumer-group member that owns a stream, read the same event,
so one writer's trace gathers the work of all its readers. Tail-sampling collectors decide per
trace within a time window and drop spans that arrive late.

`kiroku-otel`'s native subscription spans (`kiroku.subscription.deliver`, the episode spans, and
so on) are independent roots created on an empty context from event-handler callbacks. They are
neither children of the appending span nor ambient parents of the adapter's processing span, so
nothing in Kiroku relies on processing joining the writer's trace.

## Decision

`shibuya-kiroku-adapter` defaults to `LinkOnly`. `KirokuAdapterConfig` and
`KirokuConsumerGroupConfig` each carry a strict `telemetry :: AdapterTelemetry` field defaulting
to `kirokuDefaultTelemetry` (`defaultAdapterTelemetry {traceCorrelation = LinkOnly}`), which the
adapter copies unchanged into Shibuya's `Adapter`; the consumer-group helper gives the group's
value to every member. Users who want the writer and the handler in one trace set
`telemetry = defaultAdapterTelemetry` (`ParentAndLink`). `kiroku-otel` is unchanged: its spans and
the adapter's processing spans remain separate traces, correlated by the shared `kiroku.*`
attributes, and each processing span reaches its writer through the link.

## Consequences

Each processed event is a short trace of its own whose root names the writer in a link, so
replays, catch-up and fan-out no longer stretch or crowd the writer's trace, and sampling
decides for each event's processing independently of the writer. Trace backends show the
writer by following the link rather than in the same timeline. Upgrading from 0.7 changes the
default trace shape; the changelog gives the one-line restoration. `telemetry` joins the field
names already shared by both configuration records and Shibuya's `Adapter`, so, as for
`batchSize`, a record update needs a type annotation or generic-lens. The adapter's PostgreSQL
tests prove both policies, two subscriptions to one event, consumer-group members and events
without `traceparent`.
