# ADR-0003: Install Kiroku objects in a dedicated `kiroku` schema

- **Status:** Accepted — 2026-05-21 (recorded retroactively 2026-05-22)
- **Related:** ExecPlan `docs/plans/20-install-kiroku-objects-in-a-dedicated-schema.md`;
  audit `docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md`;
  codd adoption `docs/plans/16-evaluate-codd-for-first-class-schema-migrations.md`.

## Context

Kiroku installed its tables, indexes, sequences, and triggers into whichever
schema appeared first in a connection's `search_path` — with default PostgreSQL
settings, `public`. That collides with application-owned objects and other
libraries, and makes Kiroku's objects impossible to grant/back up/drop as one
group. Worse, the `ConnectionSettings.schema` field only controlled the `LISTEN`
notification channel, while *table* resolution depended on the connection-string
`search_path` — a split that was the main source of misconfiguration.

## Decision

Install **all** Kiroku-owned objects into a **dedicated schema (default
`kiroku`)**, leaving `public` free for the application.

- `ConnectionSettings.schema` is **authoritative** for object location, table
  resolution, and the `LISTEN <schema>.events` channel — a single setting.
  `defaultConnectionSettings` defaults it to `"kiroku"` (was effectively
  `public`).
- The prepared statements in `Kiroku.Store.SQL` stay **unqualified**; every
  pooled connection runs `SET search_path TO "<schema>", pg_catalog` before any
  statement, so unqualified names (and text→`regclass` resolution) land in the
  Kiroku schema. `pg_catalog` stays on the path so built-ins resolve and nothing
  falls back to `public`.
- `kiroku-store/sql/schema.sql` uses a literal `__KIROKU_SCHEMA__` token in its
  `CREATE SCHEMA` and `SET search_path`; `Kiroku.Store.Schema.initializeSchema`
  substitutes the configured, double-quoted identifier at runtime (so the field
  genuinely controls placement). The codd bootstrap migration is the same file
  with the token resolved to the literal `kiroku`. `quoteIdentifier` lives once
  in `Kiroku.Store.Schema` and is shared with `Connection`.
- The PostgreSQL 17 `uuidv7()` fallback function is created inside `kiroku`, not
  `public` (PG 18's `pg_catalog.uuidv7()` is preferred when present).

## Consequences

**Positive**

- `public` stays clean; Kiroku objects are one named, grantable, droppable group.
- One authoritative setting for table resolution and notifications removes the
  prior split-brain misconfiguration.
- Statement text is unchanged (hundreds of unqualified references preserved), and
  a custom schema name remains possible.

**Negative**

- Operational changes: the runtime role needs privileges on `kiroku` rather than
  `public`; codd is run with `CODD_SCHEMAS=kiroku`; the SQL-track benchmarks set
  the path via `PGOPTIONS="-c search_path=kiroku,pg_catalog"`.
- One `SET search_path` runs per connection acquisition. It is per-connection,
  not per-statement, so it does not add a round trip to the append/read hot paths
  (the SQL-track benches deliberately use `PGOPTIONS` instead of a per-transaction
  `SET` to avoid distorting round-trip-sensitive measurements).
- `schema.sql` and the codd bootstrap must stay in sync (the bootstrap is the
  token-resolved projection of `schema.sql`).

## Alternatives Considered

- **Stay in `public`.** Rejected: collides with application objects and offers no
  way to manage Kiroku's objects as a unit; the status quo's schema/notification
  split was itself a defect.
- **Schema-qualify every statement (`kiroku.streams`, …).** Rejected: hundreds of
  references across `SQL.hs`, a large diff, and it would bake the schema name into
  statement text, losing configurability. Setting `search_path` per connection
  achieves the same placement while preserving the existing SQL.
- **Hardcode `kiroku` literally in `schema.sql` (no token).** Rejected: combined
  with a configurable runtime `search_path`, a hardcoded install schema would
  silently install objects in `kiroku` while runtime statements looked in the
  configured schema — an inconsistency worse than the status quo. The
  `__KIROKU_SCHEMA__` sentinel keeps install-time and runtime placement in lockstep.
