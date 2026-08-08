---
okf_version: "0.2"
---

# Kiroku capabilities

What the Kiroku repository (`mori://shinzui/kiroku`) — an experimental PostgreSQL event store in
Haskell — provides to a consumer **today**, one concept per capability, each backed by evidence a
reader can open. Kiroku stores immutable events in PostgreSQL, tracks stream membership, and
maintains a totally ordered `$all` log; on top of that it offers subscriptions, projections
support, consumer groups, tracing, and operational endpoints across five consumable packages.

Every capability is `status: shipped` and `stability: experimental`. The uniform stability is
correct, not a gap: Kiroku is pre-1.0 (lifecycle Experimental) with a single compatibility
promise — everything here is usable *and* subject to breaking change before 1.0. Availability
(`status`) and compatibility (`stability`) are tracked separately; `since` is the release each
capability arrived in, per package.

## What is deliberately excluded

- **`kiroku-jitsurei`** (worked examples) and **`kiroku-test-support`** (shared test fixtures) are
  internal packages, not adoption targets. `kiroku-jitsurei`'s consumer-group demo appears only as
  *evidence* for [CAP-13](partitioned-consumer-groups.md).
- **Composition claims.** End-to-end behaviors that are only true when Kiroku and a sibling project
  cooperate are not Kiroku capabilities. The Shibuya adapter ([CAP-19](shibuya-adapter.md)) is
  included because this repository ships and proves the adapter *package*; guarantees that depend on
  `shibuya-core` belong to the consuming repository.
- **The effectful `Store` effect's mockability** is described in the relevant records' interfaces
  rather than as a standalone capability, because no dedicated mock-interpreter test was found to
  evidence it independently.

## Capabilities

| ID | Capability | Package | Since |
|----|------------|---------|-------|
| [CAP-1](schema-provisioning.md) | Schema provisioning and migrations | kiroku-store-migrations | 0.1.0.0 |
| [CAP-2](store-acquisition.md) | Store acquisition with pooling and schema isolation | kiroku-store | 0.1.0.0 |
| [CAP-3](append-with-optimistic-concurrency.md) | Append events with optimistic concurrency | kiroku-store | 0.1.0.0 |
| [CAP-4](reading-events.md) | Read streams, categories, and the global log | kiroku-store | 0.1.0.0 |
| [CAP-5](causation-correlation-queries.md) | Causation and correlation graph queries | kiroku-store | 0.1.0.0 |
| [CAP-6](transactional-append-composition.md) | Transactional append composition | kiroku-store | 0.1.0.0 |
| [CAP-7](interpreter-event-hooks.md) | Interpreter-level event enrich/decode hooks | kiroku-store | 0.1.0.0 |
| [CAP-8](stream-lifecycle.md) | Stream lifecycle: soft/hard delete, undelete | kiroku-store | 0.1.0.0 |
| [CAP-9](logical-truncate-before.md) | Logical truncate-before compaction | kiroku-store | 0.3.0.0 |
| [CAP-10](event-linking.md) | Link an existing event into another stream (provisional) | kiroku-store | 0.1.0.0 |
| [CAP-11](live-subscriptions.md) | Live catch-up subscriptions | kiroku-store | 0.1.0.0 |
| [CAP-12](resilient-delivery.md) | Resilient delivery: retry, dead-letter, filtering, backpressure recovery | kiroku-store | 0.2.0.0 |
| [CAP-13](partitioned-consumer-groups.md) | Partitioned consumer groups | kiroku-store | 0.1.0.0 |
| [CAP-14](observability-events.md) | Observability event stream | kiroku-store | 0.1.0.0 |
| [CAP-15](opentelemetry-trace-context.md) | OpenTelemetry W3C trace-context propagation | kiroku-otel | 0.1.0.0 |
| [CAP-16](opentelemetry-subscription-tracing.md) | OpenTelemetry subscription tracing | kiroku-otel | 0.2.0.0 |
| [CAP-17](operational-http-endpoints.md) | Operational HTTP endpoints: metrics, health, streaming | kiroku-metrics | 0.1.0.0 |
| [CAP-18](operator-cli.md) | Embeddable operator CLI | kiroku-cli | 0.1.0.0 |
| [CAP-19](shibuya-adapter.md) | Shibuya queue-framework adapter | shibuya-kiroku-adapter | 0.1.0.0 |
