# Kiroku User Guides

These guides cover Kiroku from an application author's point of view: how to
open a store, write and read events, run subscriptions, and operate the
system in production. For internal design notes see `docs/DESIGN.md` and
`docs/IMPLEMENTATION.md`; for deployment and tuning see
`docs/PRODUCTION-DEPLOYMENT.md` and `docs/PRODUCTION-TUNING.md`.

## Getting Started

- [Getting Started](getting-started.md) — open a store, configure the
  connection, and run your first append and read.

## Writing And Reading

- [Appending Events](appending-events.md) — `appendToStream`,
  `ExpectedVersion`, optimistic concurrency, idempotent retries,
  multi-stream appends, and transactional appends.
- [Reading Events](reading-events.md) — stream reads, the global `$all`
  stream, category reads, streaming reads, and stream metadata.
- [Linking Events](linking.md) — share an existing event into another
  stream without copying it.

## Subscriptions

- [Subscriptions](subscriptions.md) — the in-process subscription system:
  delivery semantics, overflow policy, the effectful API, and the Streamly
  bridge.
- [Consumer Groups](consumer-groups.md) — scale a single subscription
  horizontally with hash-partitioned members while preserving per-stream
  ordering.
- [Shibuya Adapter](shibuya-adapter.md) — drive Kiroku subscriptions from
  the Shibuya queue-processing framework.

## Observability

- [OpenTelemetry](opentelemetry.md) — propagate W3C trace context through
  event metadata with `kiroku-otel` and the append/read hooks.
- [Observability](observability.md) — operational events, the connection
  pool observation handler, and wiring both to logs and metrics.

## Schema And Lifecycle

- [Database Schema](schema.md) — the tables, indexes, triggers, and the
  ordering model.
- [Schema Migrations](schema-migrations.md) — apply and upgrade the schema
  with the `kiroku-store-migrations` package.
- [Stream Lifecycle](lifecycle.md) — soft delete, undelete, and hard delete
  (GDPR-style erasure).
