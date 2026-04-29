---
id: 4
slug: multi-tenancy-security-and-schema-lifecycle-audit
title: "Multi-tenancy, security and schema lifecycle audit"
kind: exec-plan
created_at: 2026-04-29T14:06:25Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Multi-tenancy, security and schema lifecycle audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` exposes a `schema` parameter on `ConnectionSettings` (default `"public"`), claims to support "schema-per-tenant" multi-tenant deployments in `docs/DESIGN.md`, and runs DDL on every `withStore` invocation via `Kiroku.Store.Schema.initializeSchema`. It also exposes a hard-delete API gated by a session GUC (`kiroku.enable_hard_deletes`) and trusts the connection string to be safe input. Once production services depend on these decisions, fixing them becomes a coordination problem across many deployments. The schema-name field is currently *plumbed but mostly unused* — only the LISTEN channel name uses it; the SQL statements never prefix a schema. The hard-delete authorization model is "if you have DB access, you can hard-delete with one SQL command". The schema initialization runs on every `withStore` start, so any change to `schema.sql` is applied opportunistically without a migration story. There is no `kiroku-migrate` package, and an existing memory note (`project_schema_migration.md`) flags schema-migration extraction as the next non-trivial DDL trigger.

After this plan, the package has a written audit of (1) the actual extent of multi-tenant support — what works, what doesn't, what callers can rely on; (2) the security boundary around hard-delete and trusted DDL; (3) the schema lifecycle / migration story; (4) the connection-string handling surface. Every must-fix finding has landed: at minimum, the schema-name field's actual contract is documented (or the field is removed if undocumentable), the hard-delete authorization model is made explicit, and the schema initialization has either a clear "do not change this file in place" warning or a documented coordination procedure.

A reader can verify the change by reading the new audit document, running `cabal test kiroku-store`, and confirming that the package builds with whatever changes the audit motivated.


## Progress

- [ ] Milestone 1: Audit findings document
  - [ ] Trace the `schema` parameter end-to-end through the codebase: what reads it, what writes it, what *should* use it but doesn't
  - [ ] Audit the hard-delete authorization model and the GUC mechanism
  - [ ] Audit DDL execution and identify the migration gap
  - [ ] Audit connection-string handling and SQL-injection surface
  - [ ] Classify every finding by severity
- [ ] Milestone 2: Land must-fix corrections
  - [ ] Decide and act on the schema-name field (wire it through, remove it, or document its actual contract)
  - [ ] Document the hard-delete authorization model in `Kiroku.Store.Lifecycle` Haddocks
  - [ ] Add a schema-initialization warning or coordination doc; align with the existing `project_schema_migration.md` memory note
  - [ ] Update the MasterPlan's Exec-Plan Registry status and Progress section


## Surprises & Discoveries

(None yet. The findings document produced in Milestone 1 will be reflected here with file:line references and severity classification.)

Initial leads identified during MasterPlan research:

- The `schema` field of `ConnectionSettings` (default `"public"`) is plumbed into `KirokuStore.schema` (`Connection.hs:60`, line 91) and read by `Notifier.startNotifier` to construct the LISTEN channel name `<schema>.events` (`Notification.hs:46`). Nothing else in the codebase reads it. Crucially, the SQL statements in `SQL.hs` reference table names *without* any schema prefix (e.g. `FROM stream_events`, `UPDATE streams`). Severity: must-fix-or-document. The advertised "schema-per-tenant" support does not actually exist as long as PostgreSQL's `search_path` has not been explicitly set per session — the SQL hits whatever `streams`/`events`/`stream_events` are first in `search_path`. Two stores with different `schema` values pointing at the same database will write to the same tables.
- `initializeSchema` (`Schema.hs:26-31`) runs the embedded DDL on every `withStore` acquire. The DDL is idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`) but does not migrate. Severity: must-decide. Either (1) document that `schema.sql` cannot be changed in a backwards-incompatible way without a migration tool, or (2) extract a `kiroku-migrate` package now (per the existing `project_schema_migration.md` memory note that flagged schema-migration extraction as the next non-trivial DDL trigger).
- Hard-delete authorization: any SQL session with `INSERT/UPDATE` privilege on `streams` can issue `SET LOCAL kiroku.enable_hard_deletes = 'on'; DELETE FROM streams WHERE ...`. The trigger `protect_deletion()` checks the GUC; the GUC is settable by the session. Severity: should-fix-or-document. The current model is "if you have DB write access, you can hard-delete" — fine for trusted-application contexts, surprising for anyone reading the trigger as a security boundary.
- DDL execution privilege: `initializeSchema` requires the connection's user to have `CREATE TABLE`, `CREATE INDEX`, and `CREATE FUNCTION` privileges. Production deployments often run application services as low-privilege users. Severity: must-document. Recommend separating DDL initialization from application runtime — a one-time setup script or migration tool.
- Connection string: `ConnectionSettings.connString :: Text` is passed to `Hasql.Connection.Settings.connectionString`. Confirm that hasql sanitises libpq input correctly (it does — libpq parses it directly). No SQL injection at this boundary.
- All SQL queries use parameterised placeholders (`$1`, `$2`, ...) via hasql encoders. Confirm by reading every prepared statement; no string concatenation of user input into SQL.
- `notify_events()` payload includes `NEW.stream_name`. A stream name of `'foo,1,2','attacker_payload'` could form a malformed NOTIFY payload. The Notifier's listener does not parse the payload (`Notification.hs:69-70` just writes `()` ticks), so this is benign for the in-process subscription system. But any *external* consumer of the NOTIFY channel that parses the payload as CSV is at risk. Severity: should-document.
- The `protect_deletion` trigger at `schema.sql:119-141` is row-level. `TRUNCATE streams` would bypass it. EP-1 also flags this as a TRUNCATE bypass; EP-4 owns the security framing. Decide: add `BEFORE TRUNCATE ... FOR EACH STATEMENT` triggers, or document the bypass as a known administrative escape hatch.


## Decision Log

- Decision: Treat the schema-name field's resolution as a must-fix or must-document item — it cannot remain in its current "plumbed but inert" state once consumers depend on the package.
  Rationale: A field whose name suggests multi-tenant isolation but does nothing is a footgun. Either wire it through (substantial change), remove it (minor breaking change), or document its actual contract (documentation only). The choice depends on whether the package commits to multi-tenant isolation as a feature now or defers it.
  Date: 2026-04-29


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The reader is assumed to have only the working tree and this file.

`kiroku-store` is a Haskell PostgreSQL event-store library. Its connection model is a `Pool` from `hasql-pool`, a single dedicated `Hasql.Connection.Connection` for the LISTEN/NOTIFY listener, and a worker thread for the centralised event publisher. The DDL is embedded into the binary at compile time via `embedFile` in `Kiroku.Store.Schema`.

Files in scope for this audit:

- `kiroku-store/sql/schema.sql` — the embedded DDL.
- `kiroku-store/src/Kiroku/Store/Schema.hs` — DDL execution.
- `kiroku-store/src/Kiroku/Store/Connection.hs` — `ConnectionSettings` (including `schema`, `idleInTransactionTimeout`, `observationHandler`), `defaultConnectionSettings`, `withStore`, `KirokuStore`.
- `kiroku-store/src/Kiroku/Store/Notification.hs` — the only place the `schema` field is currently read (line 46, `toPgIdentifier (schema <> ".events")`).
- `kiroku-store/src/Kiroku/Store/SQL.hs` — every prepared statement; reviewed here for whether table names are schema-prefixed (they are not).
- `kiroku-store/src/Kiroku/Store/Effect.hs` — for the hard-delete `SET LOCAL` invocation (line 200).

External documents referenced (not modified):

- `docs/DESIGN.md` — claims "schema-per-tenant from Phase 1" and "Multi-tenant isolation: parameterize all SQL with schema prefix and scope NOTIFY channels per schema" (Design Decisions Log, line 672). The actual implementation only does the latter; SQL is not parameterised by schema. This audit treats the DESIGN.md claim as aspirational.
- The auto-memory note `project_schema_migration.md` records that "Schema migrations should be extracted to a separate package long-term" — the trigger event is the first non-trivial DDL change. The parked partition-ready plan (`docs/plans/partition-ready-schema.md`) names this as its blocker.

Hard-delete mechanism:

The `protect_deletion` PL/pgSQL function (`schema.sql:119-126`) reads the session GUC `kiroku.enable_hard_deletes` via `current_setting('kiroku.enable_hard_deletes', true)`. The third argument `true` means "return NULL if undefined". The function checks `= 'on'` and raises an exception otherwise. The trigger fires `BEFORE DELETE` on `events`, `stream_events`, and `streams`.

The Haskell layer (`Effect.hs:198-203`) wraps the hard-delete CTE in an explicit transaction (`hasql-transaction`) and calls `Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"` at the start of the transaction. `SET LOCAL` is reset at transaction end, so the GUC is only "on" for the duration of one hard-delete.

The trust model: any session with `EXECUTE` privilege on `protect_deletion` (default: anyone who can `DELETE`) can `SET LOCAL kiroku.enable_hard_deletes = 'on'` from raw SQL. The GUC mechanism is therefore a *footgun protection*, not a security boundary.


## Plan of Work

### Milestone 1 — Audit findings document

Goal: produce a written audit of multi-tenancy, security boundaries, schema lifecycle, and connection-string handling. Classify every finding by severity.

What will exist at the end: every Audit Checklist item below has a finding entry in Surprises & Discoveries with a severity tag and (where the audit is empirical) evidence.

Verification: every checklist item has a corresponding entry; cross-plan items are listed in the MasterPlan's Surprises & Discoveries.

### Milestone 2 — Land must-fix corrections

Goal: land code changes for every must-fix finding. The most likely outcomes are:

- A decision on the `schema` field. Three options:
  - (A) Wire it through SQL: every prepared statement gets schema-prefixed table names. Substantial change in `SQL.hs`. Coordinate with EP-1.
  - (B) Remove it from the public API. Breaking change for any consumer setting it. Cross-plan with EP-2.
  - (C) Document its actual contract: "the LISTEN channel is schema-scoped, but tables are looked up via search_path; for true multi-tenant isolation, set the connection's `search_path` and use a separate schema per tenant via your DBA tooling".
  Recommend (C) initially; revisit after a real multi-tenant requirement appears.
- Hard-delete authorization Haddock. Document the trust model in `Kiroku.Store.Lifecycle.hardDeleteStream` and in the package readme (if any).
- Schema lifecycle warning. Add a Haddock to `Kiroku.Store.Schema.initializeSchema` that explicitly says "this is idempotent only for additive DDL changes; backwards-incompatible changes require a migration tool — see the parked plan at `docs/plans/partition-ready-schema.md` and the `project_schema_migration.md` memory note".
- DDL privilege guidance. Add a `## Production Deployment` section to a top-level package README (or create one if absent) describing the principle of least privilege for the application user vs. the DDL-initialising user.

What will exist at the end: green build, green tests, updated Haddocks, an explicit `project_schema_migration.md`-aligned coordination procedure for schema changes, and a Decision Log entry per fix.


## Concrete Steps

### Milestone 1 commands

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal test kiroku-store
    # Search for every reference to the `schema` field:
    grep -rn 'schema' kiroku-store/src/

Files to read in full:

- `kiroku-store/sql/schema.sql` (142 lines)
- `kiroku-store/src/Kiroku/Store/Schema.hs` (39 lines)
- `kiroku-store/src/Kiroku/Store/Connection.hs` (103 lines)
- `kiroku-store/src/Kiroku/Store/Notification.hs` (88 lines)
- `kiroku-store/src/Kiroku/Store/SQL.hs` (718 lines, scan for `FROM`, `UPDATE`, `INSERT INTO`)
- `kiroku-store/src/Kiroku/Store/Effect.hs` (293 lines, focus on hard-delete arm)
- `docs/DESIGN.md` Design Decisions Log section (lines 657–678)
- The relevant memory note. View via:

        cat /Users/shinzui/.claude/projects/-Users-shinzui-Keikaku-bokuno-kiroku-project-kiroku/memory/project_schema_migration.md

### Audit Checklist

Multi-tenancy:
- Does any SQL statement in `SQL.hs` reference a schema prefix? Search for `schema.` and `<schema>` and `\$\{schema\}`. Document the result.
- Does the hasql connection or pool config set `search_path`? Read `Connection.hs:71-79`. Currently no — the only `initSession` is `SET idle_in_transaction_session_timeout`. Confirm.
- The Notifier's LISTEN channel uses `<schema>.events`. The `notify_events()` trigger emits `pg_notify(TG_TABLE_SCHEMA || '.events', ...)`. The trigger reads the *table*'s schema (`TG_TABLE_SCHEMA`), so if the tables are in `tenant_a` schema, the channel is `tenant_a.events`, regardless of what the connection's `schema` setting says. Confirm. Decide whether the design intent is to align the connection's `schema` setting with `TG_TABLE_SCHEMA` (it is, but currently nothing enforces it).
- What happens if two `KirokuStore` handles connect to the same database with different `schema` settings? The Notifiers listen on different channels, but the SQL hits whatever tables `search_path` resolves. Reproduce: open two stores with `schema = "a"` and `schema = "b"` against one database; append to one; observe that the other's subscriptions do *not* see the events (because the listener is on a different channel) but the data is in the same tables. Document this.
- Decide on a recommendation: (A) wire schema through SQL, (B) remove the field, or (C) document the actual contract. Surface the choice to the user before landing.

Hard-delete authorization:
- The `protect_deletion` trigger is a PL/pgSQL function. Anyone with `EXECUTE` on the function (default: PUBLIC) can call it via DELETE. The GUC is settable by anyone with `SET LOCAL` rights (anyone). Confirm.
- In multi-tenant deployments, application users often have only `INSERT/UPDATE/SELECT` on the data tables and not `DELETE`. The Haskell `runStorePool`'s hard-delete arm requires `DELETE` privilege at the SQL layer. Document.
- Should hard-delete be gated by a *role* check rather than a session GUC? This is a design question — surface to the user with a recommendation.
- Should the `kiroku.enable_hard_deletes` GUC name be made schema-scoped (`kiroku.tenant_a.enable_hard_deletes`) for tenant isolation? Probably not; document.

Schema lifecycle / migration:
- `initializeSchema` runs the entire embedded DDL on every `withStore` acquire. It uses `CREATE ... IF NOT EXISTS` and `CREATE OR REPLACE FUNCTION`. Document: this is idempotent for additive changes only.
- The `INSERT INTO streams VALUES (0, '$all', 0) ON CONFLICT DO NOTHING` and the `setval('streams_stream_id_seq', GREATEST(...))` run on every acquire (`schema.sql:16-21`). Confirm: under concurrent startup of two processes, neither corrupts the sequence (`setval` is idempotent given the same `MAX`).
- Backwards-incompatible changes (column rename, type change, constraint addition without `IF NOT EXISTS`) would silently fail or partially apply. Document. Surface to the user the question: "extract `kiroku-migrate` now or defer with explicit migration coordination procedure".
- The parked plan at `docs/plans/partition-ready-schema.md` enumerates known migration challenges (composite PKs, FK removal, the `DuplicateEvent` regression). Use it as the canonical example of what a migration story would need to handle.

Connection-string handling and SQL injection:
- `connString :: Text` is passed to `Hasql.Connection.Settings.connectionString`. libpq parses it. No application-level SQL substitution. Confirm by reading `Connection.hs`.
- Every prepared statement uses positional parameters. No `T.intercalate` or `<>` construction of SQL from user input. Confirm by reading `SQL.hs` end-to-end.
- The `notify_events()` trigger constructs its NOTIFY payload as `NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version`. A stream name with a comma would produce a malformed payload for any external listener that parses it as CSV. The in-process Notifier ignores the payload (writes `()` ticks). Severity: should-document for any external consumer. Decide whether to encode the payload as JSON for safety.
- `idle_in_transaction_session_timeout` is set via `Pool.Config.initSession` with a string-interpolated value: `Session.script ("SET idle_in_transaction_session_timeout = '" <> T.pack (show ...) <> "s'")` (`Connection.hs:78`). The interpolated value is the result of `show` on an `Int`, so no injection — but document the brittleness; if `idleInTransactionTimeout` ever became user-supplied text, this would be an injection vector.

DDL privilege:
- `CREATE TABLE`, `CREATE INDEX`, `CREATE OR REPLACE FUNCTION`, `CREATE TRIGGER`, `INSERT INTO streams`, `SELECT setval(...)` — what's the minimum privilege the application's runtime user needs to (a) initialise the schema, (b) only run the application?
  - (a) requires `CREATE ON SCHEMA <name>` and `INSERT, UPDATE, SELECT` on `streams`.
  - (b) requires only `INSERT, UPDATE, SELECT, DELETE` on `streams`, `events`, `stream_events`, `subscriptions`.
- Recommend in the README: separate the two, run DDL once via a migration step (or via `withStore` only at deploy time with elevated privilege).

Trigger bypass:
- `BEFORE DELETE` triggers fire only on row-level DELETE, not TRUNCATE or `DROP TABLE`. Decide whether to add `BEFORE TRUNCATE` triggers.
- `ALTER TABLE streams DETACH PARTITION ...` would also bypass the trigger if the schema were ever partitioned. Cross-plan with the parked partition plan.

Confidentiality / encryption:
- The package does not encrypt event payloads. Callers store JSONB. Document if any caller is expected to encrypt at rest.
- `connString` may contain a password; it is held in `KirokuStore` via the dedicated listener connection's lifetime. Confirm no logging path emits it. The Haddock should warn.

Audit logging:
- Hard-delete is irreversible and emits no audit log row. Should it? Surface to the user with a recommendation: at minimum, emit an event on the `$all` stream of type `kiroku.HardDeleted` with the deleted stream id.

### Milestone 2 commands

For each must-fix finding:

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. If a code change is required, add a regression test (where applicable)
    $EDITOR kiroku-store/test/Main.hs
    # 2. Land the fix
    $EDITOR kiroku-store/src/Kiroku/Store/{Connection,Schema,Lifecycle,Notification}.hs
    cabal test kiroku-store
    # 3. Commit
    git commit -m "<scope>: <one-line summary>

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

Documentation-only changes do not require a regression test; the verification is "the Haddock now exists and accurately describes the behaviour".


## Validation and Acceptance

Milestone 1 is complete when every Audit Checklist item has a finding entry, every cross-plan item is in the MasterPlan's Surprises & Discoveries, and the Decision Log records the rationale for the schema-field decision (A/B/C above) before any code change is made.

Milestone 2 is complete when:

- The schema-field decision is implemented and the `schema` field's actual contract is unambiguous (whether by code change or by Haddock).
- The hard-delete authorization model is documented in `Kiroku.Store.Lifecycle.hardDeleteStream`'s Haddock.
- The schema-initialization warning is in `Kiroku.Store.Schema.initializeSchema`'s Haddock.
- A `Production Deployment` section exists somewhere readable (top-level README or design doc) describing DDL privilege and runtime privilege.
- `cabal test kiroku-store` passes.
- The MasterPlan's Exec-Plan Registry status for EP-4 is "Complete".

Acceptance behaviours that a human can verify:

- Reading `Kiroku.Store.Connection.ConnectionSettings`'s Haddock leaves no ambiguity about what the `schema` field controls.
- Reading `Kiroku.Store.Lifecycle.hardDeleteStream`'s Haddock leaves no ambiguity about who can call it and what privileges it requires.
- Reading `Kiroku.Store.Schema.initializeSchema`'s Haddock leaves no ambiguity about the migration story (or non-story).


## Idempotence and Recovery

The audit milestone is read-only. The fix milestone produces commits. Every commit must keep the test suite green.

If the schema-field decision lands as option (A) — wire schema through SQL — that is a substantial change to `SQL.hs`. Coordinate with EP-1 (which owns `SQL.hs`) before starting; do not edit `SQL.hs` from this plan unless EP-1 has signed off.

If a fix recommends extracting `kiroku-migrate`, do not start the extraction in this plan. Surface to the user as a follow-up plan.


## Interfaces and Dependencies

Files this plan modifies:

- `kiroku-store/src/Kiroku/Store/Connection.hs` — Haddock additions; possibly removing or rescoping the `schema` field.
- `kiroku-store/src/Kiroku/Store/Schema.hs` — Haddock additions; possibly an explicit `migrate` vs `initialize` split.
- `kiroku-store/src/Kiroku/Store/Lifecycle.hs` — Haddock additions on `hardDeleteStream`.
- `kiroku-store/sql/schema.sql` — only if a finding requires a TRUNCATE-bypass trigger or a `notify_events` payload safety change. Coordinate with EP-1.
- `kiroku-store/src/Kiroku/Store/Notification.hs` — only if the schema-field decision changes the listener channel construction.
- A new top-level `README.md` or `docs/PRODUCTION-DEPLOYMENT.md` if the audit motivates one.

Files this plan does *not* modify (owned by other plans):

- `kiroku-store/src/Kiroku/Store/SQL.hs` — owned by EP-1.
- `kiroku-store/src/Kiroku/Store/Effect.hs` — owned by EP-1 (TOCTOU) and EP-2 (multi-stream attribution). If the schema-field decision lands as (A), this plan must also touch `Effect.hs` for the schema-prefixed query path; coordinate.
- `kiroku-store/src/Kiroku/Store/Error.hs` — owned by EP-2.
- `kiroku-store/src/Kiroku/Store/Subscription/*` — owned by EP-3.

External dependencies. None new.

Module-level interface contracts:

- `Kiroku.Store.Connection.ConnectionSettings.schema` — owned by this plan; the contract is finalized here.
- `Kiroku.Store.Schema.initializeSchema` — owned by this plan; the migration story is finalized here.
- `Kiroku.Store.Lifecycle.hardDeleteStream` — Haddock owned by this plan; the public function signature is owned by EP-2.

Cross-plan integration points:

- EP-1 owns `SQL.hs` and `schema.sql`. Any DDL or SQL change requested by this plan goes through EP-1.
- EP-2 owns the public types and effects. If the schema field is removed, EP-2 must approve.
- EP-5 owns observability; any new "schema-mismatch" or "DDL privilege error" metric is owned there.
- EP-6 owns testing; new tests for multi-tenant scenarios go via EP-6's restructure.

The auto-memory note `project_schema_migration.md` documents the schema-migration extraction trigger. This plan must update or refute that note as part of Milestone 2's Decision Log.
