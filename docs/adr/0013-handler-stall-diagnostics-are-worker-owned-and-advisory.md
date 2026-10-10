---
type: Architecture Decision Record
title: Handler stall diagnostics are worker-owned and advisory
description: "Keep acknowledgement ownership with consumers and use opt-in scoped worker diagnostics for pending ordinary handlers."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-10T00:38:59Z"
docId: ADR-13
status: Accepted
date: 2026-10-09
timestamp: "2026-10-10T00:38:59Z"
originatingPlan: docs/plans/84-harden-adapter-acknowledgement-liveness-and-expose-retry-policy.md
---

# ADR-0013: Handler stall diagnostics are worker-owned and advisory

## Context

Kiroku's acknowledgement bridge holds the subscription handler call until a consumer
finalizes an item. A raw consumer can leave that call pending indefinitely. A native
handler can also block. The standard supervised runner in
`mori://shinzui/shibuya/packages/shibuya-core` already finalizes synchronous handler
exceptions as zero-delay retries; those exceptions do not establish an abandoned-ack
bug. [ADR-11](0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
requires disabled diagnostic defaults and proportional performance verification.

## Decision

The store owns diagnostics around the ordinary delivery handler, including catch-up,
all-stream live, category and consumer-group paths. `handlerStallWarnAfter = Nothing`
selects the original handler once during worker construction. It adds no tracking cell,
thread, timer, diagnostic clock read, per-event branch or tracking write. Decode-error
callbacks are outside this boundary.

A positive interval enables one cell and one scoped watchdog per worker. Each handler
call writes its event identity and monotonic start time, then clears tracking in `finally`.
The watchdog parks on STM while idle, reuses an active interval timer across quick calls,
and checks the current invocation's age. At most one timer is outstanding per watchdog;
a completed call may leave its existing timer to wake once before the watchdog parks.
Repeated warnings are separated by at least the configured interval. Worker exit cancels
and joins the watchdog. Nonpositive intervals fail before checkpoint initialization as
`InvalidHandlerStallWarnAfter` under `SomeSubscriptionStartupFailure` on the handle's `wait`.
This optional raw duration is a narrow exception to construction-time validation in
[ADR-8](0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md),
preserving the planned `Maybe NominalDiffTime` API rather than adding another wrapper type.

`KirokuEventSubscriptionHandlerStalled` reports name, position, event id, monotonic elapsed
duration and group context through the guarded store event callback. It is an observation
of a pending invocation, not a state transition. The warning never finalizes, retries,
dead-letters or checkpoints it. Automatic finalization could race a slow successful
handler and cause unwanted redelivery, so consumer ownership and first-wins finalization
remain intact.

The adapter forwards the same optional interval and the existing `RetryPolicy` to every
worker. The policy counts total deliveries; an `AckRetry` delay independently determines
pacing. `kirokuProcessor` composes `mkProcessor` with the existing one-second synchronous
exception guard, preserving its `Unordered`, `Serial` defaults. The group factory retains
its guarded `PartitionedInOrder`, `Serial` defaults. Asynchronous cancellation propagates.

## Consequences

Full config record literals and exhaustive operational-event matches require source
updates. Metrics add a warning counter, `subscription_handler_stalls` in lifecycle JSON,
and `kiroku_subscription_handler_stalls_total` in Prometheus, without advancing observed
subscription positions. These additive fields follow
[ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md).
The OpenTelemetry observer leaves span state unchanged on warnings.

Enabled diagnostics add a clock read and two tracking writes per ordinary call, plus
watchdog scheduling. They remain an explicit opt-in cost; the default-path invariants and
focused correctness tests do not establish cumulative performance neutrality. EP6 owns
that comparison, including real adapter acknowledgements where applicable. Raw consumers
must finalize every item, and handlers must resolve their own stalls.
