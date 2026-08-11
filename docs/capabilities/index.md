---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Capability

- [Append events with optimistic concurrency](append-with-optimistic-concurrency.md) - Append events to one or many streams atomically with an expected-version precondition, all-or-nothing per call, with read-your-own-writes and typed conflict errors.
- [Causation and correlation graph queries](causation-correlation-queries.md) - Walk the causation graph forward and backward from a seed event, and gather every event sharing a correlation id, using dedicated partial indexes.
- [Link an existing event into another stream](event-linking.md) - Add an existing event to a second stream by its event id, sharing the underlying event row through a stream-event junction rather than copying the payload.
- [Explicit subscription checkpoint lifecycle](explicit-subscription-checkpoint-lifecycle.md) - Resolve absent subscription checkpoints by an explicit atomic policy and compose exact multi-name checkpoint resets with application-owned SQL in one transaction.
- [Interpreter-level event enrich and decode hooks](interpreter-event-hooks.md) - Transform every event on the write path (enrichEvent) and the read/subscription path (decodeHook) through interpreter-level hooks wired once on ConnectionSettings, with an allocation-free fast path when absent.
- [Live catch-up subscriptions](live-subscriptions.md) - Subscribe to the global log or a category, catch up from a durable checkpoint and switch to live delivery, with at-least-once, per-batch checkpointing and a Streamly bridge.
- [Logical truncate-before compaction](logical-truncate-before.md) - Set a per-stream truncate-before marker that hides events below a version from ordered per-stream reads, without deleting anything, to support snapshot-and-compact rehydration.
- [Observability event stream](observability-events.md) - Install a synchronous eventHandler that receives a typed KirokuEvent stream covering store-internal thread health and the full subscription lifecycle, hardened so a throwing handler cannot kill a store thread.
- [OpenTelemetry subscription tracing](opentelemetry-subscription-tracing.md) - Turn the subscription worker's finite-state lifecycle into OpenTelemetry spans through a ready-made KirokuEvent handler, with kiroku.* and messaging.* semantic-convention attributes.
- [OpenTelemetry W3C trace-context propagation](opentelemetry-trace-context.md) - Inject a W3C traceparent/tracestate into an event's metadata on write and extract a SpanContext back on read, keeping kiroku-store free of any OpenTelemetry dependency.
- [Operational HTTP endpoints: metrics, health, and event streaming](operational-http-endpoints.md) - Serve in-process metrics as JSON and Prometheus exposition, liveness/readiness/detailed health, a subscription-status endpoint, and a WebSocket channel for live metrics and events, without pulling a web framework into the core library.
- [Embeddable operator CLI](operator-cli.md) - Embed a kiroku operator command group into a host CLI, or run the standalone kiroku binary as a remote client that reports subscription status from a running worker's HTTP endpoint.
- [Partitioned consumer groups](partitioned-consumer-groups.md) - Split a named subscription across N members that each process a disjoint, per-stream-ordered slice in parallel, with per-member checkpoints and an optional startup conflict guard.
- [Read streams, categories, and the global log](reading-events.md) - Read events forward or backward from a single stream, a category, or the totally ordered global $all log, including a constant-memory streaming read and batch surrogate-id resolution.
- [Resilient delivery: retry, dead-letter, filtering, and backpressure recovery](resilient-delivery.md) - Drive per-event dispositions (retry with backoff, dead-letter) through an ack-coupled stream, filter deliveries by event type or predicate, and recover from backpressure and live DB errors without losing events.
- [Schema provisioning and migrations](schema-provisioning.md) - Install and version-control the Kiroku PostgreSQL schema through an embedded, manifest-ordered pg-migrate component and the kiroku-store-migrate executable before any application opens a store.
- [Shibuya queue-framework adapter](shibuya-adapter.md) - A published adapter package that presents a Kiroku subscription (or a whole consumer group) as a Shibuya pull-based Adapter, mapping ack decisions onto Kiroku's per-event retry, dead-letter, and checkpoint semantics.
- [Store acquisition with connection pooling and schema isolation](store-acquisition.md) - Open a KirokuStore over a pooled hasql connection, isolated in a dedicated PostgreSQL schema, with a dedicated LISTEN connection and pluggable observation/event handlers.
- [Stream lifecycle: soft delete, hard delete, undelete](stream-lifecycle.md) - Soft-delete a stream (reversible, hidden from reads), hard-delete it (purge payloads and dead letters), or undelete a soft-deleted stream, with hard deletes gated by a session GUC.
- [Transactional append composition](transactional-append-composition.md) - Atomically compose a single-stream append with a caller-supplied hasql transaction, so an event and the application state it drives commit or roll back together.
