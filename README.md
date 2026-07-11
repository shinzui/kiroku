# Kiroku

Kiroku is an experimental PostgreSQL event store written in Haskell.

> [!WARNING]
> Kiroku packages are under active development. APIs, schemas, and operational
> defaults may change in breaking ways before the project stabilizes.

The name comes from the Japanese word **記録** (*kiroku*), meaning
"record", "log", or "chronicle". That is the core idea of the project:
preserve an ordered, durable record of domain events and make that record
useful for reads, subscriptions, projections, tracing, and operational
workflows.

## What It Provides

- `kiroku-store`: the core event store library, built on `hasql`; includes
  append, read, link, lifecycle, transaction, subscription, consumer-group, and
  observability APIs.
- `kiroku-store-migrations`: a native `pg-migrate` component, Codd history
  import mapping, and the `kiroku-store-migrate` executable.
- `kiroku-cli`: an embeddable operator CLI library plus the standalone
  `kiroku` executable for commands such as subscription status.
- `kiroku-otel`: W3C trace-context helpers for Kiroku event metadata.
- `shibuya-kiroku-adapter`: an adapter that exposes Kiroku subscriptions to
  the Shibuya queue processing framework.

Kiroku stores immutable events in PostgreSQL, tracks stream membership through
stream-event links, and maintains a totally ordered `$all` stream for global
event ordering. Global positions are strictly increasing, opaque cursors;
consumers must not assume they are dense (`pos + 1` may not exist) or derive
them by arithmetic. The current implementation happens to assign contiguous,
gap-free positions via an atomic row-level counter claimed in the same
transaction that appends events, but contiguity is an implementation detail
rather than an API guarantee — see
`docs/architecture/global-position-migration-path.md`.

## Repository Layout

```text
kiroku-store/              Core event store library, tests, and benchmarks
kiroku-store-migrations/   Native pg-migrate component and migration executable
kiroku-cli/                Embeddable operator CLI and standalone executable
kiroku-otel/               OpenTelemetry trace-context metadata helpers
shibuya-kiroku-adapter/    Shibuya adapter for Kiroku subscriptions
docs/                      Design notes, production notes, audits, plans
```

## Development

This repository is a Cabal project using GHC 9.12.4.

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

Kiroku installs all of its objects into a dedicated `kiroku` PostgreSQL schema
by default, leaving `public` free for application objects.

`kiroku-store` does not run DDL when a store is acquired through `withStore`.
Apply the embedded migrations from `kiroku-store-migrations` before opening the
store. The default `schema` setting is `kiroku`; it controls the `search_path`
of every pooled connection and the notification channel that subscriptions
listen on.

Run the migration executable from `kiroku-store-migrations` first (with
`CODD_SCHEMAS=kiroku`), then start the application normally with
`withStore (defaultConnectionSettings connString)`. See
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
- [`docs/user/operator-cli.md`](docs/user/operator-cli.md): standalone and
  embedded operator CLI usage.

## Status

Kiroku is currently experimental. APIs, schema details, and operational
defaults may change in breaking ways as the event store hardens.
