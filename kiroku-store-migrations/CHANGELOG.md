# Changelog

## 0.1.0.0 — 2026-05-23

### New Features

* Initial release of the migration package.
* Embeds Kiroku's codd SQL migrations and exposes
  `Kiroku.Store.Migrations`.
* Provides the `kiroku-store-migrate` executable for applying the event store
  schema before application startup.
* Bootstraps the dedicated `kiroku` PostgreSQL schema and installs Kiroku
  tables, indexes, functions, and triggers there.
