# Kiroku

Kiroku is an experimental PostgreSQL event store written in Haskell.

The name comes from the Japanese word **記録** (*kiroku*), meaning
"record", "log", or "chronicle". That is the core idea of the project:
preserve an ordered, durable record of domain events and make that record
useful for reads, subscriptions, projections, tracing, and operational
workflows.

## What It Provides

- `kiroku-store`: the core event store library, built on `hasql`.
- `kiroku-store-migrations`: forward-only database migrations for the store.
- `kiroku-otel`: W3C trace-context helpers for Kiroku event metadata.
- `shibuya-kiroku-adapter`: an adapter that exposes Kiroku subscriptions to
  the Shibuya queue processing framework.

Kiroku stores immutable events in PostgreSQL, tracks stream membership through
stream-event links, and maintains a contiguous `$all` stream for global event
ordering. The current design uses an atomic row-level counter in PostgreSQL to
claim gap-free global positions in the same transaction that appends events.

## Repository Layout

```text
kiroku-store/              Core event store library, tests, benchmarks, SQL
kiroku-store-migrations/   Embedded codd migrations and migration executable
kiroku-otel/               OpenTelemetry trace-context metadata helpers
shibuya-kiroku-adapter/    Shibuya adapter for Kiroku subscriptions
docs/                      Design notes, production notes, audits, plans
```

## Development

This repository is a Cabal project using GHC 9.12.2.

Common commands are available through `just`:

```bash
just build
just test
just bench
just fmt
```

Database helpers:

```bash
just up
just create-database
just init-schema
just psql
just down
```

The project can also be checked through Nix:

```bash
just nix-build
just nix-check
```

## Schema Management

During development, `kiroku-store` can initialize its embedded schema when a
store is acquired through `withStore`.

For production-style usage, run the migration executable from
`kiroku-store-migrations` first, then start the application with schema
initialization disabled. See
[`kiroku-store-migrations/README.md`](kiroku-store-migrations/README.md) for
the migration command and runtime settings.

## Documentation

- [`docs/DESIGN.md`](docs/DESIGN.md): implementation blueprint and storage
  design.
- [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md): implementation notes.
- [`docs/PRODUCTION-DEPLOYMENT.md`](docs/PRODUCTION-DEPLOYMENT.md):
  deployment guidance.
- [`docs/PRODUCTION-TUNING.md`](docs/PRODUCTION-TUNING.md): operational tuning.
- [`docs/BENCH-REGRESSION.md`](docs/BENCH-REGRESSION.md): benchmark regression
  workflow.

## Status

Kiroku is currently experimental. APIs, schema details, and operational
defaults may change as the event store hardens.
