# Kiroku Guides

These are **task-oriented, end-to-end guides**: each one walks a complete
real-world scenario from start to finish, composing the Kiroku primitives into a
working pattern with runnable code, design trade-offs, and failure handling.

They complement the [user guides](../user/README.md), which are *reference*
documentation organized per topic (one API surface per page). Reach for a guide
when you want to *accomplish something* ("build a projection", "coordinate a
multi-step workflow"); reach for the user docs when you want the precise
semantics of one function or type.

## Available Guides

- [Consuming The Event Log](consuming-the-event-log.md) — the comprehensive
  subscriptions guide: choosing an approach, the catch-up→live lifecycle,
  filtering by event type, at-least-once and idempotency, retry/dead-letter,
  backpressure, the effectful and Streamly APIs, driving subscriptions from the
  Shibuya adapter, scaling with consumer groups, and observability.
- [Building A Projection](building-a-projection.md) — derive a queryable read
  model from the event log: subscribe to the relevant events, apply each one with
  an idempotent write, track progress with the subscription checkpoint, and
  rebuild, scale, and handle failure. Covers external-table projections, the
  atomicity question, in-store projections with links, and consumer-group
  scaling.
- [Process Managers And Sagas](process-managers-and-sagas.md) — drive a
  multi-step workflow across aggregates by reacting to events and *issuing
  commands*. Covers the process-manager-as-aggregate pattern, idempotent
  reactions under at-least-once delivery, causation/correlation tracking,
  atomic coupled appends, saga compensation, timeouts, and routing/scaling.

## Where To Start

If you are new to Kiroku, start with the user docs'
[Getting Started](../user/getting-started.md), then
[Appending Events](../user/appending-events.md) and
[Reading Events](../user/reading-events.md). Come back here once you are
appending and reading and want to build something on top of the log — a read
model or a workflow.

## See Also

- [User Guides](../user/README.md) — per-topic reference documentation.
- [DESIGN.md](../DESIGN.md) / [IMPLEMENTATION.md](../IMPLEMENTATION.md) —
  internal design notes.
- [PRODUCTION-DEPLOYMENT.md](../PRODUCTION-DEPLOYMENT.md) /
  [PRODUCTION-TUNING.md](../PRODUCTION-TUNING.md) — operating Kiroku in
  production.
