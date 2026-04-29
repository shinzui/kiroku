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

- [x] Milestone 1: Audit findings document (2026-04-29; 18 findings F1–F18: 3 must-fix/must-document with code or Haddock work [F1 schema-field rewrite + dead-plumbing removal, F18 Haddock — folded into F1, F9 production-deployment doc], 4 must-document [F2 listener/trigger coupling, F5 hard-delete authorization framing, F7 migration story, F17 at-rest plaintext]; 4 should-document [F8 concurrent startup race, F12 latent injection vector, F13 NOTIFY payload, F14 connString not logged — closed as no-issue]; 4 defer-with-rationale [F4 tenant lifecycle, F6 hard-delete audit log, F13 JSON payload, F16 partition triggers]; 4 no-issue [F8, F10, F11, F12, F14]; 1 confirmation [F15 TRUNCATE bypass closed by EP-1.F6]; 1 cross-plan tie-back [F18 ↔ EP-2.F14])
  - [x] Trace the `schema` parameter end-to-end through the codebase: what reads it, what writes it, what *should* use it but doesn't (F1)
  - [x] Audit the hard-delete authorization model and the GUC mechanism (F5, F6, F15)
  - [x] Audit DDL execution and identify the migration gap (F7, F8, F9)
  - [x] Audit connection-string handling and SQL-injection surface (F10, F11, F12, F13, F14)
  - [x] Classify every finding by severity (every F-entry has a Severity line)
- [x] Milestone 2: Land must-fix corrections (2026-04-29; F1/F7/F18 schema-field Haddock + dead-plumbing removal, F5 hard-delete authorization Haddock, F9 Production Deployment guide; F4/F6/F13/F16 deferred-with-rationale per Decision Log)
  - [x] Decide and act on the schema-name field (option C: documented the actual contract; rewrote `Connection.hs:34` Haddock; removed dead `schema :: Text` plumbing from `Worker.runWorker`/`catchUp`/`liveLoopCategoryDriven`/`fetchBatch` and the `Subscription.hs:107` call site; kept the field for forward compatibility with a future option-A implementation) (commit 9f344bc)
  - [x] Document the hard-delete authorization model in `Kiroku.Store.Lifecycle` Haddocks (advisory-not-security framing, audit-log gap, three production tightening patterns) (commit 8470f36)
  - [x] Add a schema-initialization warning or coordination doc; align with the existing `project_schema_migration.md` memory note (folded into `Schema.hs:initializeSchema` Haddock alongside F1's removal of the dead plumbing; references the parked partition plan and the memory note) (commit 9f344bc)
  - [x] Add a Production Deployment doc covering DDL/runtime privilege separation, hard-delete authorization, schema migration, connection-string handling, at-rest encryption, multi-tenant patterns, observability, and required PostgreSQL version (`docs/PRODUCTION-DEPLOYMENT.md`) (commit 9db5a7f)
  - [x] Update the MasterPlan's Exec-Plan Registry status and Progress section (this commit)


## Surprises & Discoveries

### M1 audit — 2026-04-29

Eighteen findings (F1–F18, EP-4 numbering — distinct from EP-1, EP-2, and
EP-3). All citations name files relative to the repo root. Severity tags:
**must-fix** (land code in M2), **must-document** (land Haddock or doc in
M2), **should-fix-or-document** (land in M2 if cheap, otherwise defer with
rationale), **defer-with-rationale** (record reason; revisit when triggers
fire), **no-issue** (audited and closed), **confirmation** (verifies a
prior plan's fix is in place).

#### Multi-tenancy

**F1 — `schema` field is plumbed but inert at the SQL layer.**
*Severity: must-fix (rewrite Haddock + remove dead plumbing) plus
cross-plan to EP-2.*

`ConnectionSettings.schema` (`kiroku-store/src/Kiroku/Store/Connection.hs:34`,
defaults `"public"` at line 52) is held by `KirokuStore.schema`
(`Connection.hs:60`) and read in three places only:

  1. `Kiroku.Store.Notification.startNotifier`
     (`Notification.hs:62`) constructs the LISTEN channel name as
     `toPgIdentifier (schema <> ".events")`. The Notifier subscribes
     to `<schema>.events` and writes `()` ticks to its broadcast
     `TChan` whenever NOTIFY fires.
  2. `Kiroku.Store.Subscription.subscribe`
     (`Subscription.hs:107`) passes `store ^. #schema` as the second
     argument to `runWorker`.
  3. `Kiroku.Store.Schema.initializeSchema` (`Schema.hs:27`) takes a
     `Text` second argument named `_schema` (the underscore prefix is
     intentional — the binding is unused). The body ignores it.

The Worker's chain (`Worker.hs:41` `runWorker` → `catchUp` (line 82) →
`liveLoopCategoryDriven` (line 139) → `fetchBatch` (line 162)) accepts
`schema :: Text` at every level but `fetchBatch`'s body
(`Worker.hs:162-173`) does not reference the parameter. The argument
is dead. So the *Subscription* path also threads a useless schema name.

`Kiroku.Store.SQL.hs` references all tables unqualified (e.g.,
`FROM stream_events`, `UPDATE streams`, `INSERT INTO events`,
`DELETE FROM streams`). The grep at the audit checklist below confirms
zero schema prefixes in SQL.hs. Therefore the advertised "Schema name
for multi-tenant isolation" Haddock at `Connection.hs:35` is incorrect:
two `KirokuStore` handles connecting to the same database with
different `schema` values will write to and read from whichever
`streams`/`events`/`stream_events` PostgreSQL's `search_path` resolves
to first. There is no per-store table isolation.

`docs/DESIGN.md:672` records the original aspiration as Decision-Log
entry "Multi-tenant isolation | Schema-per-tenant from Phase 1 |
Parameterize all SQL with schema prefix and scope NOTIFY channels per
schema." Only the latter half is implemented; the prefixing was never
done.

Resolution path in M2: option (C) from the Plan of Work — document the
actual contract, remove the dead plumbing in `Worker.hs` and
`Schema.hs`, and rewrite the `schema` Haddock to name what the field
actually controls (the LISTEN channel name only). Options (A) wire
through SQL and (B) remove the field are both heavier and warrant a
real multi-tenant requirement; record the rejection rationale in the
Decision Log. Cross-plan to EP-2 — the public Haddock owner — as
EP-4.F1 ↔ EP-2.F14 (the same item, EP-2 named it first; EP-4 owns the
fix).

**F2 — Listener/trigger schema-name coupling is implicit.**
*Severity: must-document.*

`schema.sql:88-91` constructs the NOTIFY channel from
`TG_TABLE_SCHEMA || '.events'` — the schema in which the `streams`
table actually lives, as resolved by PostgreSQL at trigger-fire time.
`Notification.hs:62` constructs the listener's channel name from
`<schema>.events` where `schema` is the application-supplied
`ConnectionSettings.schema`.

These names must be byte-identical for the listener to receive
notifications. With defaults (`schema = "public"` and the default
PostgreSQL `search_path = "$user", public`), they coincide because
`streams` lives in `public` and the connection's `schema` is
`"public"`. Set `schema = "tenant_a"` without also placing `streams`
in a `tenant_a` schema (or vice versa) and the listener silently
receives nothing — the EventPublisher's 30-second safety poll
(`EventPublisher.hs`) eventually catches up but normal subscription
latency stops being notification-driven.

Currently no codepath sets `search_path` per session; no codepath
verifies that `current_schema()` for `streams` matches
`ConnectionSettings.schema`. The mismatch is silent.

Resolution path in M2: document this coupling in the `schema` Haddock
under F1's rewrite. Note that any user setting a non-default `schema`
must also ensure the application's connection-string sets
`search_path` (or the database's per-user `search_path`) such that
`streams`/`events`/`stream_events` resolve to that schema. Defer
mechanical enforcement (a session check or a `current_schema()` probe)
to a follow-up plan if multi-tenant deployments materialise.

**F3 — Two stores against one database silently share tables.**
*Severity: confirmation of F1; documented under F1's resolution.*

Reproduction: open `withStore (defaults { schema = "a" })` and
`withStore (defaults { schema = "b" })` against the same PostgreSQL
instance. Both invoke `initializeSchema` (idempotent, no-op on the
second call). Both `LISTEN` on different channels (`a.events`,
`b.events`). Both append paths `INSERT INTO streams` resolve to the
same table (whichever `streams` PostgreSQL's `search_path` finds).
Subscriber B will not see A's appends because the trigger publishes on
whichever schema `streams` actually lives in (default: `public`), not
on the application-supplied schema name. But the data is in the same
tables.

This is the practical consequence of F1 + F2 and is closed by F1's
documentation work.

**F4 — Tenant lifecycle (create/drop/migrate) is unimplemented.**
*Severity: defer-with-rationale.*

There is no API for creating a new tenant schema, dropping a tenant's
data, or migrating a tenant's tables. `docs/DESIGN.md:672` defers this
to "later phases". No production caller has asked for it.

Defer to a follow-up plan with this trigger: a real production
requirement for tenant isolation appears (a service genuinely needs
two unrelated tenants to share a `kiroku-store` deployment). Until
then, the F1 documentation is the contract.

#### Hard-delete authorization

**F5 — Hard-delete is gated by a footgun GUC, not a security boundary.**
*Severity: should-fix-or-document → resolved as must-document.*

`schema.sql:119-141` defines `protect_deletion()` which checks
`current_setting('kiroku.enable_hard_deletes', true) = 'on'` and raises
otherwise. The GUC is set per-transaction via `Tx.sql "SET LOCAL
kiroku.enable_hard_deletes = 'on'"` inside the `HardDeleteStream` arm
of `Kiroku.Store.Effect.runStorePool` (`Effect.hs:177`).

Authorization model: any PostgreSQL session with `DELETE` privilege on
`events`, `stream_events`, `streams` *and* `SET LOCAL` rights (which
PostgreSQL grants to every session) can hard-delete. The trigger
exists to prevent *accidental* `DELETE` (typo, ad-hoc operator query),
not malicious deletion by a session that already has `DELETE`
privilege. A misreading of this trigger as a security boundary is the
real risk.

Possible tightening (deferred):

  - Replace the GUC with a `SECURITY DEFINER` function callable only by
    a specific role. Requires DBA-managed role provisioning.
  - Check `current_user` / `session_user` against an allowlist inside
    `protect_deletion`. Couples the package to specific role names.
  - Issue a single-use token via the application layer. Adds state.

None of these are clearly better than the GUC-as-footgun-protection
model for the package's current trust assumptions (the application is
trusted; the trigger guards against accidental issuance of `DELETE`).

Resolution path in M2: document the actual model in the
`hardDeleteStream` Haddock at `Lifecycle.hs:34-50`. The existing
Haddock describes the GUC mechanism but does not state explicitly that
this is an *advisory* protection rather than a *security* boundary.
Add that statement, name who can hard-delete (any session with
`DELETE` privilege), and recommend that production deployments use
PostgreSQL's standard role/grant system to scope `DELETE` privilege if
hard-delete must be restricted.

**F6 — Hard-delete emits no audit log.**
*Severity: defer-with-rationale.*

`HardDeleteStream` (`Effect.hs:175-187`) deletes junction rows, orphan
events, and the stream row, but does not record an audit event. A
production deployment that hard-deletes for GDPR compliance has no
in-band record that the deletion happened.

Recommendation surfaced for future: append a `kiroku.HardDeleted` event
to `$all` (or to a dedicated audit stream) before the GUC is enabled,
carrying the deleted stream id and the reason. The current API's
`hardDeleteStream :: StreamName -> Eff es (Maybe StreamId)` does not
take a "reason" argument; adding one is a public API change cross-plan
to EP-2.

Defer to EP-5 (operational hardening) or a follow-up audit-logging
plan. EP-5's observation-handler enrichment already plans to surface
hard-delete events to operators via the existing observation channel;
in-band audit-row generation is a separate concern.

#### Schema lifecycle / migration

**F7 — `initializeSchema` is idempotent only for additive DDL.**
*Severity: must-document.*

`Kiroku.Store.Schema.initializeSchema` (`Schema.hs:23-31`) runs the
embedded DDL on every `withStore` acquire via
`Hasql.Pool.use pool (Session.script schemaDDL)`. The script uses:

  - `CREATE TABLE IF NOT EXISTS` (lines 5, 24, 35, 74)
  - `CREATE INDEX IF NOT EXISTS` (lines 47, 51, 55, 59, 63, 69)
  - `CREATE OR REPLACE FUNCTION` (lines 86, 102, 119, 147)
  - `DROP TRIGGER IF EXISTS` followed by `CREATE TRIGGER` (lines
    96-99, 108-111, 113-116, 128-141, 156-169) — additive in effect
  - `INSERT ... ON CONFLICT DO NOTHING` (lines 16-18) — idempotent
  - `SELECT setval(...)` with `GREATEST` (line 21) — idempotent

This handles every change of the form "add a column with a default",
"add an index", "redefine a function", "add a trigger". It does *not*
handle:

  - Renaming a column. `ALTER TABLE ... RENAME COLUMN` is not
    idempotent. Two starts: first succeeds, second fails with `column
    "x" does not exist`.
  - Changing a column type. Same issue.
  - Adding a constraint. `ALTER TABLE ... ADD CONSTRAINT` is not
    idempotent.
  - Removing a column.
  - Reordering columns.

For any backwards-incompatible change, two simultaneous `withStore`
processes would race; the second would observe a half-applied state.

This aligns with the existing `project_schema_migration.md` memory
note: schema-migration extraction is triggered by the first
non-trivial DDL change. The note is current and correct; this finding
confirms it without changing it.

Resolution path in M2: add a Haddock to `initializeSchema` that names
the additive-only contract explicitly. Reference the parked partition
plan (`docs/plans/partition-ready-schema.md`) and the
`project_schema_migration.md` note as the canonical "extract
`kiroku-migrate` when this becomes a problem" guidance.

**F8 — Concurrent `withStore` startup is safe under additive DDL.**
*Severity: no-issue.*

Two processes invoking `withStore` concurrently each call
`initializeSchema`. PostgreSQL serialises the DDL via the system
catalog locks: the second `CREATE TABLE IF NOT EXISTS` waits for the
first's transaction to commit, then sees the table and returns
silently. `INSERT ... ON CONFLICT DO NOTHING` and `SELECT setval(...,
GREATEST(...))` are commutative. `CREATE OR REPLACE FUNCTION` is
last-write-wins on identical text. `DROP TRIGGER IF EXISTS` followed by
`CREATE TRIGGER` is idempotent — the second process drops the trigger
the first just created and re-creates it; behaviour is unchanged.

A transient race window exists where the second `DROP TRIGGER` sees
the trigger and the second `CREATE TRIGGER` then sees an existing one
and fails. PostgreSQL's catalog locks make this exceedingly unlikely
in practice, but the pattern is "drop before create" which is not
fully atomic. Tracking under M2's documentation work is sufficient —
note that simultaneous deploy starts are theoretically racy and
recommend serialising deploys.

**F9 — DDL execution privilege requirement is undocumented.**
*Severity: must-document.*

`initializeSchema` requires:

  - `CREATE` on the target schema (for `CREATE TABLE`).
  - `CREATE` on the target schema (for `CREATE INDEX`).
  - `CREATE` on the target schema (for `CREATE FUNCTION`).
  - `TRIGGER` on the target tables (for `CREATE TRIGGER`).
  - `INSERT, UPDATE, SELECT` on `streams` (for the seed row + `setval`).

A least-privilege production deployment runs the application as a user
without these privileges; DDL is run once at deploy time by a
migration job under an elevated role.

`Connection.hs` does not name the privilege requirement anywhere. A
caller wiring up a least-privilege role would discover this only at
runtime via `SchemaInitError`.

Resolution path in M2: add a `Production Deployment` section
(README-style) covering the principle of least privilege:

  - One-time setup as elevated user: run the equivalent of
    `withStore` once (or extract the DDL — see `kiroku-migrate`
    extraction trigger in F7) under a role with
    `CREATE`/`TRIGGER`/`INSERT`-on-`streams` privileges.
  - Runtime as application user: needs only `INSERT, UPDATE, SELECT,
    DELETE` on `events`, `stream_events`, `streams`, `subscriptions`
    plus `EXECUTE` on `protect_deletion()`/`protect_truncation()` (the
    latter only if the application performs hard-deletes).

#### Connection-string handling and SQL injection

**F10 — `connString` reaches libpq directly with no application
substitution.** *Severity: no-issue.*

`Connection.hs:101` passes `Conn.connectionString (settings ^.
#connString)` to `Hasql.Pool.Config.staticConnectionSettings`.
`Notification.hs:127` does the same for the listener. Both reach libpq
unchanged. libpq parses the URI/key=value format itself; there is no
intermediate Haskell-level concatenation that could create an
injection vector at this boundary.

**F11 — Every prepared statement uses positional parameters.**
*Severity: no-issue.*

Audit method: read all of `kiroku-store/src/Kiroku/Store/SQL.hs`
end-to-end (804 lines). Every `Statement` declaration uses hasql
positional placeholders (`$1`, `$2`, ...) bound via `Encoders` with
typed parameters. There is no `T.intercalate`, no `T.concat`, no `<>`
in any SQL string body. The only `<>` operators in `SQL.hs` are
hasql's `Contravariant` composition for encoders (e.g., line 72-78,
`(^. #eventTypes) >$< E.param ...`), not string concatenation. SQL
injection via user-supplied stream names, event types, etc. is not
possible.

**F12 — `idle_in_transaction_session_timeout` interpolation is safe by
construction.** *Severity: no-issue.*

`Connection.hs:104` builds the init-session SQL as
`"SET idle_in_transaction_session_timeout = '" <> T.pack (show
(settings ^. #idleInTransactionTimeout)) <> "s'"`. The interpolated
value is the result of `show :: Int -> String`, so it is always a
sequence of decimal digits and possibly a leading `-`. No injection
vector at the current type. Documented as latent-injection-vector for
future change: if `idleInTransactionTimeout` ever becomes
user-supplied `Text`, this pattern becomes an injection risk and
should be rewritten using a prepared statement.

**F13 — `notify_events()` payload is comma-delimited and unescaped.**
*Severity: should-document.*

`schema.sql:86-94` constructs the NOTIFY payload as `NEW.stream_name ||
',' || NEW.stream_id || ',' || NEW.stream_version`. A stream name
containing a literal comma (e.g., `"foo,bar"`) produces a payload
indistinguishable from a `stream_name="foo"`, `stream_id="bar"` pair.

The in-process Notifier (`Notification.hs:90-122`) writes `()` ticks
on every NOTIFY without parsing the payload — the format does not
matter for the EventPublisher's wakeup mechanism. The format is also
not part of any documented external contract: there is no consumer
outside the package.

For a future external consumer (e.g., a sidecar that tails the NOTIFY
channel for cross-process projection updates), the format is a
liability. Recommend a JSON encoding (`json_build_object('stream_name',
NEW.stream_name, 'stream_id', NEW.stream_id, 'stream_version',
NEW.stream_version)::text`) when an external consumer is added. Defer
the change; the Haddock work in M2 will mention this trap.

**F14 — `connString` is not logged.** *Severity: no-issue.*

`grep -rn 'putStrLn\|hPutStrLn\|print\|trace' kiroku-store/src/`
returns zero hits in any code path that touches `connString` or
`ConnectionSettings`. The `ConnectionSettings` and `KirokuStore`
records do not derive `Show`. The dedicated listener connection's
`acquireOrFail` (`Notification.hs:125-135`) calls `fail (... <> show
err)` on acquisition failure: `err` is a hasql
`Hasql.Connection.ConnectionError` whose `Show` instance does not
include the raw connection string. No password leakage path observed.

#### Trigger and bypass surface

**F15 — TRUNCATE bypass is closed by `protect_truncation` triggers.**
*Severity: confirmation of EP-1.F6.*

`schema.sql:147-169` defines `protect_truncation()` and three
`BEFORE TRUNCATE ... FOR EACH STATEMENT` triggers gated by the same
`kiroku.enable_hard_deletes` GUC. The test suite exercises this:
`kiroku-store/test/Main.hs` includes "TRUNCATE on events is rejected
without the GUC", "TRUNCATE on stream_events is rejected without the
GUC", "TRUNCATE on streams is rejected without the GUC" (76/76 tests
green). EP-4 has no further work here; security framing is unified
with the hard-delete GUC discussed under F5.

**F16 — Partition detach is not relevant at current schema.**
*Severity: defer.*

`ALTER TABLE ... DETACH PARTITION` could bypass row-level triggers if
the schema were partitioned. The schema is not partitioned; the
parked plan at `docs/plans/partition-ready-schema.md` would introduce
partitioning. The trigger semantics under partitioning are documented
in that plan's Known Defects section. EP-4 has no work here unless
the partition plan is unparked.

#### Confidentiality and at-rest concerns

**F17 — Event payloads are stored as plaintext JSONB.**
*Severity: should-document.*

`schema.sql:30-31` declares `data JSONB NOT NULL` and `metadata JSONB`
on `events`. The package does not encrypt these fields. Any caller
storing PII or secrets in event payloads must encrypt before append
and decrypt on read — kiroku-store treats payloads as opaque bytes.

Resolution path in M2: add a brief note to the `Production Deployment`
section that the package does not provide at-rest encryption beyond
PostgreSQL's standard data-at-rest options (filesystem encryption,
TDE). Callers store JSONB; sensitivity classification is the caller's
responsibility.

**F18 — ConnectionSettings Haddock is misleading on the `schema` field.**
*Severity: must-fix (Haddock change), folded into F1's resolution.*

`Connection.hs:35` reads:

    -- ^ Schema name for multi-tenant isolation (default: "public")

This Haddock implies that setting `schema` produces multi-tenant
isolation. F1 establishes that it does not. Cross-references
EP-2.F14, which routed the schema-field decision to this plan. F1's
M2 resolution rewrites this Haddock to name the actual contract (the
LISTEN channel name only) and adds the F2 coupling note.


## Decision Log

- Decision: Treat the schema-name field's resolution as a must-fix or must-document item — it cannot remain in its current "plumbed but inert" state once consumers depend on the package.
  Rationale: A field whose name suggests multi-tenant isolation but does nothing is a footgun. Either wire it through (substantial change), remove it (minor breaking change), or document its actual contract (documentation only). The choice depends on whether the package commits to multi-tenant isolation as a feature now or defers it.
  Date: 2026-04-29

- Decision: Adopt option (C) for the schema-name field — document the actual contract and remove dead plumbing — over option (A) wire-through-SQL or option (B) remove-the-field.
  Rationale: There is no production caller asking for schema-per-tenant isolation today (F4). The DESIGN.md aspiration (schema-prefixed SQL) was never implemented, and implementing it now would touch every prepared statement in `SQL.hs` (~30+ statements, 800 lines) plus require coordinating with EP-1's owned file. Removing the field (option B) is a public API breaking change for any caller already setting it (notably the adapter at `shibuya-kiroku-adapter/`). Option (C) is the lightest intervention that closes the footgun: the Haddock will name the only thing the field actually controls (the LISTEN channel name) and the dead plumbing in `Worker.hs:41,82,139,162` and `Schema.hs:27` will be removed. The field stays for forward compatibility — when a real multi-tenant requirement appears, option (A) becomes the right next step and the field is already in place. Cross-plan EP-2.F14 routed the decision here; EP-2's audit reached the same conclusion (a Haddock note rather than a constructor change).
  Date: 2026-04-29

- Decision: Defer F4 (tenant lifecycle), F6 (hard-delete audit log), F13 (NOTIFY payload JSON encoding), F16 (partition trigger semantics).
  Rationale: All four are feature additions, not defects, and none has a production caller. Triggers for each are recorded in the finding text. Recording the deferrals in this plan's Decision Log preserves the rationale for the production-readiness verdict.
  Date: 2026-04-29

- Decision: Frame the hard-delete authorization model (F5) as advisory, not security; document in `Lifecycle.hs` rather than tighten the GUC mechanism.
  Rationale: The trust model "applications running with full DELETE privilege are trusted" is correct for the package's current consumer set (single-application services). Tightening the trigger (`SECURITY DEFINER` function, role allowlist, single-use token) is a feature for a different trust model that no consumer has asked for; the cost is API or operational complexity. The risk is that a reader of the trigger code mistakes the GUC for a security boundary; the fix is a documentation note that names the model explicitly. This avoids the worst outcome (false sense of security) at the lowest cost.
  Date: 2026-04-29

- Decision: Defer extracting `kiroku-migrate` (F7); land a Haddock warning instead.
  Rationale: The existing `project_schema_migration.md` memory note already records "extract `kiroku-migrate` when a non-trivial DDL change appears". No such change is queued today; the parked partition plan is the most likely future trigger, and `project_partition_plan_parked.md` already names the unpark conditions. Adding a Haddock to `initializeSchema` that names the additive-only contract gives any future contributor — including the MasterPlan's reader — the heads-up they need without spinning up a parallel package now.
  Date: 2026-04-29


## Outcomes & Retrospective

### M2 outcomes (2026-04-29)

What this plan delivered:

  * The `ConnectionSettings.schema` field's actual contract is now
    unambiguous in the `Connection.hs:34` Haddock (option C from the
    Plan of Work). It controls only the LISTEN channel name; tables
    are looked up via `search_path`. The Haddock names the
    listener/trigger coupling requirement (F2) so any user who sets a
    non-default `schema` understands they must align it with
    `TG_TABLE_SCHEMA` via `search_path` discipline. Two layers of dead
    plumbing — `Worker.runWorker`/`catchUp`/`liveLoopCategoryDriven`/
    `fetchBatch` accepting an unused `schema :: Text`, and
    `Subscription.subscribe` passing `store ^. #schema` to it — have
    been removed. The field stays in the public type for forward
    compatibility with a future option-A implementation that
    schema-prefixes SQL.

  * The hard-delete authorization model is documented in
    `Lifecycle.hardDeleteStream`'s Haddock as /advisory protection,
    not security boundary/. A reader of the `protect_deletion` trigger
    cannot now mistake the GUC for role-based access control. The
    Haddock names two production patterns for stricter control: a
    separate `kiroku_purge` role with `DELETE` privilege, or
    application-level authorization wrapping `hardDeleteStream`. The
    audit-log gap is named explicitly with a recommended workaround
    (record an application event /before/ calling).

  * The schema migration story is documented in `Schema.hs:
    initializeSchema`'s Haddock (additive-only DDL contract; reference
    to `project_schema_migration.md` and the parked partition plan as
    the "extract `kiroku-migrate` when this becomes a problem"
    guidance). Required privileges for the connecting user are named
    explicitly.

  * `docs/PRODUCTION-DEPLOYMENT.md` aggregates DDL/runtime privilege
    separation, hard-delete authorization, schema migration,
    connection-string handling (including the "do not derive Show on
    `ConnectionSettingsM`" rule), at-rest encryption non-coverage, the
    supported multi-tenant pattern, observability, and the PostgreSQL
    18+ requirement. This is a docs-only addition.

What this plan deliberately did /not/ do:

  * No SQL.hs changes. Option (A) — schema-prefixed table names —
    requires touching every prepared statement and is a substantial
    change to a file owned by EP-1. No production caller has asked
    for table-level multi-tenant isolation. When such a requirement
    appears, option (A) becomes the right next step and the existing
    `schema` field is already in place.

  * No removal of `ConnectionSettings.schema`. Option (B) is a public
    API breaking change for any caller already setting it (notably
    the adapter at `shibuya-kiroku-adapter/`). The cost outweighs the
    benefit when the field has a coherent (if narrow) contract under
    option (C).

  * No tightening of the hard-delete GUC mechanism. The current model
    "applications running with full DELETE privilege are trusted" is
    correct for the package's current consumer set. Tightening
    (`SECURITY DEFINER`, role allowlist, single-use token) is a
    feature for a different trust model and was deferred. The
    documentation change closes the highest-leverage risk (false
    sense of security) at the lowest cost.

  * No `kiroku-migrate` extraction. The `project_schema_migration.md`
    memory note already records the trigger; the parked partition
    plan is the most likely first migration target. A Haddock warning
    on `initializeSchema` gives any future contributor the heads-up
    they need without spinning up a parallel package now.

  * No NOTIFY-payload JSON encoding (F13). The current
    comma-delimited payload is benign for the in-process Notifier
    (which ignores the payload) and there is no external consumer
    today. When one appears, encode the payload as JSON.

  * No partition-trigger semantics work (F16). The schema is not
    partitioned; the parked plan owns the analysis when the partition
    work is unparked.

  * No hard-delete audit row (F6). Routed to EP-5 (operational
    hardening) for observation-handler enrichment plus a separate
    decision on whether to add an in-band `kiroku.HardDeleted` event
    (which would require a public API change to `hardDeleteStream`
    cross-plan to EP-2).

Production-readiness verdict for the multi-tenancy / security /
schema-lifecycle subsystem:

  * **Multi-tenancy.** `kiroku-store` does not provide table-level
    multi-tenant isolation today. The supported pattern (separate
    schema per tenant + `search_path` discipline + one `withStore` per
    tenant) is documented in `Connection.hs` Haddock and in
    `docs/PRODUCTION-DEPLOYMENT.md`. Acceptable for production use
    with single-tenant services or operationally-isolated tenants;
    /not/ acceptable for production use as a shared multi-tenant
    backbone without an audit of `search_path` discipline and tenant
    role provisioning.

  * **Hard-delete security.** Acceptable for production use under the
    documented trust model (applications with full DELETE privilege
    are trusted). Operators wanting stricter control have the
    documented `kiroku_purge` pattern. The audit-log gap is a known
    deferred item routed to EP-5.

  * **Schema lifecycle.** Acceptable for production use at the
    current single-schema-version state. The next non-trivial DDL
    change (most likely the unparking of the partition plan) is the
    documented trigger to extract `kiroku-migrate`.

  * **Connection-string handling and SQL injection.** No defects.
    Audit closed.

  * **TRUNCATE / row-trigger bypass.** Closed by EP-1.F6.

Deferred-findings register (recorded for the MasterPlan's final
verdict):

  * F4 — Tenant lifecycle (create/drop/migrate). Trigger: a real
    multi-tenant deployment requirement.
  * F6 — Hard-delete audit log. Routed to EP-5; in-band audit row
    would also need EP-2 coordination.
  * F13 — NOTIFY-payload JSON encoding. Trigger: an external consumer
    of the NOTIFY channel that parses the payload.
  * F16 — Partition-trigger semantics. Trigger: the parked partition
    plan is unparked.
  * Option (A) — wire `schema` through SQL. Trigger: a real
    multi-tenant deployment requirement that needs table-level
    isolation rather than search-path-driven isolation.
  * `kiroku-migrate` extraction. Trigger: the first non-trivial DDL
    change (per `project_schema_migration.md`).

Tests: 76/76 kiroku-store, 5/5 shibuya-kiroku-adapter. Build clean.
Haddock builds clean (warnings present are pre-existing and unrelated
to this plan).


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
