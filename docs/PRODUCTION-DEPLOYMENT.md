# Production Deployment Guide for kiroku-store

This document covers operational concerns that fall outside the package's
public Haddock surface. Read alongside `docs/DESIGN.md` (architectural
decisions), the in-source Haddocks for `Kiroku.Store.Connection`,
`Kiroku.Store.Schema`, and `Kiroku.Store.Lifecycle`, and the auto-memory
notes `project_schema_migration.md` and `project_partition_plan_parked.md`.

The audience is the operator wiring `kiroku-store` into a real service
for the first time. Everything below is opinion plus evidence; no
function in the package enforces these recommendations.


## Database privilege separation

`Kiroku.Store.Schema.initializeSchema` runs every time `withStore`
acquires the pool. The DDL it executes (`kiroku-store/sql/schema.sql`)
needs higher privileges than the runtime queries do. Production
deployments should split the two.

Privileges required to run `initializeSchema`:

- `CREATE` on the target schema (for `CREATE TABLE`, `CREATE INDEX`,
  `CREATE FUNCTION`).
- `TRIGGER` on `events`, `stream_events`, `streams` (for the
  `prevent_mutation`, `protect_deletion`, `protect_truncation` triggers).
- `INSERT, UPDATE, SELECT` on `streams` (for the seed `$all` row at
  `schema.sql:16-18` and the `setval` at `schema.sql:21`).

Privileges required at runtime by the application user:

- `INSERT, UPDATE, SELECT` on `streams`, `events`, `stream_events`,
  `subscriptions`.
- `DELETE` on `streams`, `events`, `stream_events` /only/ if the
  application calls `Kiroku.Store.Lifecycle.hardDeleteStream`. Without
  hard-delete, the application user can be denied `DELETE` entirely;
  soft-delete works through `UPDATE` on `streams.deleted_at`.
- `EXECUTE` on `protect_deletion()` and `protect_truncation()` (granted
  to `PUBLIC` by default; only restrict if you have a reason to).
- `LISTEN` privilege on the schema for the dedicated listener
  connection (granted to `PUBLIC` by default).
- `USAGE` on the `streams_stream_id_seq` sequence (granted to the
  table owner; if the application user is not the owner, grant
  explicitly).

Recommended pattern:

1. Provision a `kiroku_admin` role with `CREATE` on the schema and
   `INSERT, UPDATE, SELECT, TRIGGER` on the data tables. Run
   `initializeSchema` once at deploy time under this role — either by
   running a small Haskell program that calls `withStore` and exits,
   or (when you outgrow `initializeSchema`) by extracting a dedicated
   `kiroku-migrate` package per the `project_schema_migration.md`
   memory note.
2. Provision a `kiroku_app` role with `INSERT, UPDATE, SELECT` on the
   data tables. The application connects as `kiroku_app`.
3. If hard-delete is required, either grant `DELETE` to `kiroku_app`
   (in which case the GUC-gating in `protect_deletion` is the only
   line of defence — see "Hard-delete authorization" below), or
   provision a separate `kiroku_purge` role with `DELETE` and run
   hard-deletes through a different `withStore` instance gated by
   your application's authorization layer.

The package itself does not detect or warn on insufficient privilege.
A `SchemaInitError` raised at startup is the operator's signal.


## Hard-delete authorization

`Kiroku.Store.Lifecycle.hardDeleteStream` is gated by the session-local
PostgreSQL GUC `kiroku.enable_hard_deletes`. The interpreter sets it
inside its transaction; the `protect_deletion` and `protect_truncation`
triggers raise an exception if the GUC is unset.

The GUC is /advisory protection/, not a /security boundary/. Any
PostgreSQL session with `DELETE` privilege can issue `SET LOCAL
kiroku.enable_hard_deletes = 'on'` before its own `DELETE` —
PostgreSQL grants `SET LOCAL` to every session. The trigger exists to
make accidental issuance of `DELETE` (a typo, an ORM that does not
know the table is meant to be append-only) fail loudly, not to enforce
role-based access control.

If hard-delete must be restricted to specific operators or workflows,
restrict it via PostgreSQL's standard role/grant system rather than
relying on the GUC. The privilege-separation pattern above (a separate
`kiroku_purge` role with `DELETE`) is the simplest version. More
elaborate setups can wrap `hardDeleteStream` in an application-level
authorization layer that enforces the rule before the SQL runs.

Hard-delete emits no in-band audit row. To capture hard-deletes for
compliance, either record an application-level event /before/ calling
`hardDeleteStream` or use the connection pool's
`observationHandler` (see
`Kiroku.Store.Connection.ConnectionSettings.observationHandler`) to
forward connection-level events to your operational logging.


## Schema migration

`schema.sql` is embedded into the binary at compile time and is run
verbatim by `initializeSchema` on every startup. The DDL is idempotent
under additive changes only:

- Safe: adding a column with `IF NOT EXISTS`-equivalent semantics,
  adding a non-unique index, redefining a function with `CREATE OR
  REPLACE`, adding a trigger.
- Unsafe: renaming a column or table, changing a column type, removing
  a column, adding a constraint without `IF NOT EXISTS`. Two
  simultaneous deploys would race; the second sees a half-applied
  state.

Once a non-trivial DDL change is required, do not evolve `schema.sql`
in place. Extract a dedicated migration tool — the
`project_schema_migration.md` memory note records this trigger, and
the parked partition plan (`docs/plans/partition-ready-schema.md`)
describes the most likely first migration target.

Until the migration tool exists, two operational practices reduce
risk:

1. Serialise deploys when changing `schema.sql`. Two simultaneous
   `initializeSchema` calls against the same database are usually safe
   for additive DDL (PostgreSQL serialises catalog updates) but a
   transient `DROP TRIGGER IF EXISTS` followed by `CREATE TRIGGER` can
   in principle race. A staggered rollout avoids the window.
2. Treat any `schema.sql` diff in code review as a migration event
   subject to the same scrutiny as a column drop in a relational ORM
   migration.


## Connection-string handling

`Kiroku.Store.Connection.ConnectionSettings.connString` is passed to
libpq verbatim via `Hasql.Connection.Settings.connectionString`. There
is no Haskell-level parsing or substitution. Implications:

- The string may contain a password. The package does not redact it
  in any error path, but no error path explicitly logs the connection
  string either; an operator catching `SchemaInitError` should not
  expect to see a password leak through it (the underlying hasql
  `ConnectionError`'s `Show` instance does not include the URI).
  Application-level error handling that pretty-prints
  `ConnectionSettings` records would leak the password — the
  `ConnectionSettingsM` type does not derive `Show` for this reason;
  do not add such an instance.
- Standard libpq connection-string features apply: include
  `application_name`, `connect_timeout`, `sslmode`, etc., as needed.
  The package sets `application_name = 'kiroku-listener'` on the
  dedicated listener connection (overriding any value from the
  connection string for that connection only) for operator visibility
  in `pg_stat_activity`.


## At-rest encryption

`kiroku-store` does not encrypt event payloads. `events.data` and
`events.metadata` are stored as plain JSONB. Callers storing PII or
secrets must encrypt before append and decrypt on read; the package
treats payloads as opaque.

For deployments requiring at-rest encryption beyond what the
application provides, rely on PostgreSQL's standard data-at-rest
options: filesystem-level encryption (LUKS, FileVault), the cloud
provider's managed encryption (AWS RDS encrypted volumes, GCP CMEK),
or transparent data encryption from a managed Postgres vendor.
Application-layer encryption of payloads is the only option for
field-level confidentiality (where the database operator should not
be able to read the data).


## Multi-tenant deployments

`ConnectionSettings.schema` controls only the LISTEN channel name; it
does not prefix tables in any SQL the package issues. Genuine
schema-per-tenant table isolation is not provided today (see the
`schema` field's Haddock for the full contract).

If you need to run `kiroku-store` against multiple tenants in the same
PostgreSQL instance, the supported pattern is:

1. Create a separate PostgreSQL schema per tenant (e.g., `tenant_a`,
   `tenant_b`).
2. Per-tenant, set the application user's default `search_path` (via
   `ALTER ROLE ... SET search_path = ...`) or include
   `options=-c search_path=...` in that tenant's
   `ConnectionSettings.connString`.
3. Run `initializeSchema` once per tenant (the embedded DDL will
   create `streams`, `events`, etc. in whichever schema `search_path`
   resolves to first).
4. Run a separate `withStore` instance per tenant in the application,
   each with its own pool and its own listener.

Set `ConnectionSettings.schema` to the tenant's schema name in each
case; this aligns the listener's `LISTEN <schema>.events` channel with
the trigger's `TG_TABLE_SCHEMA || '.events'` payload-target. They must
match for notification-driven subscription wakeups to work; mismatched
values silently degrade subscriptions to the EventPublisher's
30-second safety poll.

This pattern is operational, not architectural — the package does not
enforce isolation. Cross-tenant data leakage is prevented only by
`search_path` discipline and the correctness of your per-tenant role
provisioning. A real multi-tenant audit before this pattern is
adopted at scale is recommended.


## Observability

The connection pool's lifecycle events (acquired, released,
terminated, etc.) are surfaced through
`ConnectionSettings.observationHandler`. Wire this to your structured
logger or metrics pipeline. Connection acquisition latency, the
listener's reconnection events, and pool exhaustion all surface here.

The package does not (yet) emit structured operational events for
hard-deletes, soft-deletes, schema-init failures, or subscription
worker lifecycle changes. EP-5 (operational hardening) of the
production-readiness review tracks the gap.


## Required PostgreSQL version

PostgreSQL 18 or newer. The schema uses `uuidv7()` (introduced in 18)
as the default for `events.event_id`. Earlier versions will fail at
`initializeSchema` time with a function-not-found error.
