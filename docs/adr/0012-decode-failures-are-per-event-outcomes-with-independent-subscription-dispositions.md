---
type: Architecture Decision Record
title: Decode failures are per-event outcomes with independent subscription dispositions
description: "Represent expected decode failures explicitly, advance the shared publisher, and preserve failed-event checkpoints by default."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-10T00:16:23Z"
docId: ADR-12
status: Accepted
date: 2026-10-09
timestamp: "2026-10-10T00:23:58Z"
originatingPlan: docs/plans/83-contain-persistent-publisher-decode-hook-failures.md
---

# ADR-0012: Decode failures are per-event outcomes with independent subscription dispositions

## Context

A persistent exception from an interpreter decode hook repeatedly interrupted a publisher
batch before cursor advancement. All-stream subscribers could appear live while never receiving
later events. The publisher is shared, while skipping or dead-lettering is a consumer decision.
[ADR-11](0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
requires cheap default paths and focused verification; this change adds no append SQL or schema.

## Decision

`decodeHook` returns `IO (Either DecodeFailure RecordedEvent)`. Expected failures carry an event
id and reason through `Left`; thrown exceptions retain their programming-error behavior and are
not converted into expected failures. A successful hook should preserve event identity and position.

The publisher retains raw failed events in a shared `DecodedBatch`, reports each typed failure
once through `KirokuEventPublisherDecodeFailed`, broadcasts the batch, and advances to the raw
batch tail. Each subscriber applies its own disposition. Catch-up and category/group live reads
use the same batch representation and delivery resolver.

`undecodableHandler = Nothing` retries the hook on the original event once per second using
`retryMaxAttempts` total attempts. Exhaustion stops that subscriber with `StopUndecodable` and
`SubscriptionUndecodable`, without an automatic dead letter or checkpoint past the failed event.
After fixing the hook, restart the same subscription; earlier events in an unsaved batch may replay.
This terminal exception is distinct from hook programming exceptions.

An explicit callback receives the raw event and failure and uses existing `SubscriptionResult`
semantics: Continue skips, Stop checkpoints that event and ends cleanly, Retry re-applies the hook,
and DeadLetter atomically records and checkpoints. Explicit callback retry exhaustion retains the
existing `DeadLetterMaxAttempts` behavior. `DeadLetterDecodeFailure` stores a stable reason object
with `kind`, `event_id` and `detail`. Filtered-out raw events bypass the callback. Both callbacks
share the persistent effect environment when subscribed through the effect interpreter.

Reads return `EventDecodeFailed` on the first typed failure and never expose a partial vector.
Earlier hook side effects are not rolled back. Read decoding maps directly to successful values,
avoiding an intermediate vector of wrappers. With no hook, reads return the original vector;
subscription decoding adds one `UnchangedBatch` wrapper without traversal or per-event wrappers.
Successful live decoding runs once per publisher batch, shared across subscribers; retries are
subscriber-local. Hook-enabled batches allocate per-event outcomes, whose integrated performance
cost remains an EP6 measurement concern rather than an assumed zero cost.

## Consequences

The hook and subscription configuration are source-breaking APIs. Exhaustive store-error, stop-
reason and operational-event observers must handle the new constructors. Metrics distinguish typed
failures from publisher loop errors and worker crashes. The metrics fields,
Prometheus metric and stop vocabulary grow additively under
[ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md);
the WebSocket tail uses its existing error frame on a typed decode failure. Existing defaults preserve at-least-once
recovery and do not silently discard poison events. Explicit skips and dead letters remain choices
made by the consumer. Permanently throwing hooks still need correction; typed failures are the
supported recoverable data-failure contract.
