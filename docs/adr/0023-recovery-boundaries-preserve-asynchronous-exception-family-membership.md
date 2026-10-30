---
type: Architecture Decision Record
title: Recovery boundaries preserve asynchronous exception family membership
description: "Classify cancellation by SomeAsyncException membership and rethrow the original exception across observation and publisher recovery boundaries."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-30T18:34:00Z"
docId: ADR-23
status: Accepted
date: 2026-10-30
timestamp: "2026-10-30T18:34:00Z"
originatingPlan: docs/plans/104-preserve-asynchronous-cancellation-across-observability-and-recovery.md
---

# Recovery boundaries preserve asynchronous exception family membership

## Context

Optional observability callbacks must tolerate synchronous failures without preventing
shutdown. Publisher recovery must retry ordinary failures without advancing past a
partially delivered batch. Notifier startup must release its acquired connection on
failure and preserve cancellation rather than wrapping it as an ordinary startup error.
BUG-6 found that asking `asyncExceptionFromException` for `SomeAsyncException` fails:
that decoder extracts a concrete payload, rather than testing family membership.

## Decision

At these three broad recovery boundaries, classify the caught `SomeException` with
`fromException e :: Maybe SomeAsyncException`. On a match, rethrow the original `e`.
This preserves concrete exception type and consumer-defined payloads, including values
raised directly with `throwIO`. Arbitrary values sent with `throwTo` are not necessarily
members of this exception family; delivery mechanism alone does not define cancellation.

Keep the synchronous branches unchanged: observation failures are dropped, publisher
failures emit a loop error and retry later, and initial LISTEN failures become
`NotifierListenError` with their original cause. Keep resource release in the existing
brackets. Do not add blanket masking or process signal handling.

A test-only, process-local `withListenHookForTest` wraps initial LISTEN inside the
production exception handler and connection bracket. It follows existing worker hooks,
restores the previous value on exit, and requires sequential tests. The extra IORef read
occurs only during startup, never per event or during reconnect.

## Consequences

Direct and cross-thread tests cover `AsyncCancelled`, runtime exceptions and a custom
asynchronous payload. Queue-subscriber tests force the full publisher fetch path and
check termination without loop errors or cursor advancement. Notifier tests check the
acquired connection returns to baseline after failed startup.

The later notifier listener and reconnect handlers retain their existing concrete
`AsyncCancelled` policy: cancellation from a wait exits normally; cancellation during
reacquisition is rethrown; `stopNotifier` owns final connection release after joining.
Cancellation raised by a reconnect callback either reaches the wait handler and exits
normally or escapes the recovery handler; neither path suppresses it and retries.
Other asynchronous types there can still initiate reconnect. This decision does not
establish a broader notifier policy, resolve every shutdown interleaving, or prove
consumer deployment and OpenTelemetry symptoms resolved. See
[ADR-13](0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md) for advisory
worker diagnostics and consumer acknowledgement ownership.
