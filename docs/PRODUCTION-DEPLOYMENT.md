# Production Deployment Guide for kiroku-store

This document covers operational concerns that fall outside the package's
public Haddock surface. Read alongside `docs/DESIGN.md` (architectural
decisions), the in-source Haddocks for `Kiroku.Store.Connection` and
`Kiroku.Store.Lifecycle`, and the auto-memory
notes `project_schema_migration.md` and `project_partition_plan_parked.md`.

The audience is the operator wiring `kiroku-store` into a real service
for the first time. Everything below is opinion plus evidence; no
function in the package enforces these recommendations.


## Database privilege separation

`kiroku-store` no longer embeds schema DDL or creates tables during
`withStore`. Run `kiroku-store-migrate up` or the native
`Kiroku.Store.Migrations.kirokuMigrations` component under a migration role
before starting the application.

Privileges required to run migrations:

- `CREATE` on the target schema (for `CREATE TABLE`, `CREATE INDEX`,
  `CREATE FUNCTION`).
- `TRIGGER` on `events`, `stream_events`, `streams` (for the
  `prevent_mutation`, `protect_deletion`, `protect_truncation` triggers).
- `INSERT, UPDATE, SELECT` on `streams` (for the seed `$all` row at
  the seed row and sequence repair in the bootstrap migration).

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
   `kiroku-store-migrate` once at deploy time under this role. The
   migration package embeds Kiroku's ordered native manifest and uses the
   versioned `pgmigrate` ledger to record which migrations have already run.
2. Provision a `kiroku_app` role with `INSERT, UPDATE, SELECT` on the
   data tables. The application connects as `kiroku_app` and uses
   `defaultConnectionSettings connString`.
3. If hard-delete is required, either grant `DELETE` to `kiroku_app`
   (in which case the GUC-gating in `protect_deletion` is the only
   line of defence — see "Hard-delete authorization" below), or
   provision a separate `kiroku_purge` role with `DELETE` and run
   hard-deletes through a different `withStore` instance gated by
   your application's authorization layer.

If migrations have not run, runtime queries fail with ordinary database
errors such as missing relations. Treat migration completion as a deploy
precondition.


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

Schema SQL lives in `kiroku-store-migrations/migrations`, ordered by its
`manifest`. `kiroku-store-migrations` embeds those exact files as component
`kiroku`; `pg-migrate` records their component-local identity and checksum. Do
not edit a released migration file; append a new numeric manifest entry for
every schema change.

The plan is forward-only. Reverting the Haskell package after a migration
has run does not undo the database change. Recovery from a bad migration
means restoring from backup or shipping another forward migration that
repairs state.


## Connection-string handling

`Kiroku.Store.Connection.ConnectionSettings.connString` is passed to
libpq verbatim via `Hasql.Connection.Settings.connectionString`. There
is no Haskell-level parsing or substitution. Implications:

- The string may contain a password. The package does not redact it
  in any error path, but no error path explicitly logs the connection
  string either. Application-level error handling that pretty-prints
  `ConnectionSettings` records would leak the password; the
  `ConnectionSettingsM` type does not derive `Show` for this reason.
  Do not add such an instance.
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

`ConnectionSettings.schema` controls both runtime table resolution and
the LISTEN channel name. It does not create tenant schemas; each schema
must be migrated before a store opens against it.

If you need to run `kiroku-store` against multiple tenants in the same
PostgreSQL instance, the supported pattern is:

1. Create a separate PostgreSQL schema per tenant (e.g., `tenant_a`,
   `tenant_b`).
2. Run the Kiroku migrations once per tenant schema under a migration
   role.
3. Give the application role privileges on that tenant schema.
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

PostgreSQL 17 or newer. PostgreSQL 18 provides the built-in
`pg_catalog.uuidv7()` used as the default for `events.event_id`.
On PostgreSQL 17, Kiroku creates a schema-local PL/pgSQL `uuidv7()`
fallback during schema initialization or migration application, before
the `events` table default is parsed.
