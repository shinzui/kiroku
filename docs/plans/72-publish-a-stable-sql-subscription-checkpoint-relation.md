---
id: 72
slug: publish-a-stable-sql-subscription-checkpoint-relation
title: "Publish a stable SQL subscription checkpoint relation"
kind: exec-plan
created_at: 2026-08-13T19:08:51Z
intention: "intention_01kzy7xty0eg18f534v2rdvbb8"
---

# Publish a stable SQL subscription checkpoint relation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a PostgreSQL client can read exact durable subscription-member checkpoints
through the supported relation `kiroku.subscription_checkpoints_v1` instead of depending on
Kiroku's private `kiroku.subscriptions` table or importing the Haskell `Store` effect. A downstream
component can create its own persisted view over that relation, and a later Kiroku migration can
replace the private checkpoint storage while preserving the downstream dependency through
`CREATE OR REPLACE VIEW`.

The relation exposes exactly four frozen v1 columns: subscription name, consumer-group member,
checkpoint position, and checkpoint update time. It returns one row per persisted checkpoint and
zero rows when there are none. It is deliberately non-updatable even to its owner, uses the view
owner's base-table privileges so a reader needs only schema `USAGE` and view `SELECT`, and grants no
role automatically. A user can see the result by applying the migration, granting a test role
access to the view, successfully querying it, and observing that the same role cannot query the
private table.

This plan implements
[IR-5](../improvement-requests/publish-a-stable-sql-subscription-checkpoint-relation.md), which is
an external prerequisite of
`mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.
The planning evaluation found the core request sound but corrects two impossible or unnecessarily
expensive details before implementation. PostgreSQL ordinary-view columns do not carry base-table
`NOT NULL` catalog metadata, so v1 guarantees non-null values semantically while documenting that
generic schema introspection reports them nullable. Also, `pg-migrate verify` intentionally checks
the declared migration plan against its ledger rather than comparing live schema objects. The
implementation therefore adds a focused Kiroku-owned catalog contract test; it does not restore
the removed Codd expected-schema snapshot, generator, dependency closure, or runtime verifier.

The view adds no copied state, trigger, materialization, checkpoint write, or index. PostgreSQL
inlines its `NOT MATERIALIZED` common-table expression (a named query inside the view), so a
subscription-name predicate still uses the existing
`ix_subscriptions_name_member(subscription_name, consumer_group_member)` index. The implementation
must preserve that plan shape and must not introduce a second checkpoint authority.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13T20:37:07Z) Milestone 1: reconciled IR-5's catalog-nullability and verifier
  language, added the forward `0009` migration, and made the native migration suite assert the
  frozen relation contract. The manifest check and all 11 migration examples pass.
- [ ] Milestone 2: prove durable value semantics, read-only privilege isolation, downstream-view
  dependency survival, and index-preserving query behavior against real PostgreSQL.
- [ ] Milestone 3: publish the compatibility and privilege contract in user documentation,
  changelog and an ADR, then pass repository-wide validation.
- [ ] Milestone 4: with explicit release authorization, publish `kiroku-store-migrations` 0.3.1.0,
  verify Hackage and the annotated upstream tag, and complete IR-5 with released evidence.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Accept IR-5's owner-published, versioned SQL relation, but replace its generic
  expected-schema-verifier requirement with a focused catalog contract assertion in
  `kiroku-store-migrations/test/Main.hs`.
  Rationale: Since `kiroku-store-migrations` 0.2.0.0 the native `pg-migrate verify` operation has
  deliberately meant plan-versus-ledger verification. Restoring Codd snapshots, a generator,
  PostgreSQL-major-specific files, Cabal flags, and a Nix closure workaround for one four-column
  relation would create disproportionate maintenance cost and would blur `pg-migrate`'s public
  contract. A focused test can fail on a missing relation or changed relation kind, name, ordered
  columns, data types, security mode, read-only status, owner relationship, or comments.
  Date: 2026-08-13

- Decision: Define v1's four fields as semantically non-null while explicitly accepting that
  PostgreSQL reports ordinary-view columns as nullable in `pg_attribute` and
  `information_schema.columns`.
  Rationale: A PostgreSQL 18.4 proof selecting four `NOT NULL` base columns through an ordinary
  view returned `attnotnull = false` and `is_nullable = YES` for all four. Requiring catalog-level
  `NOT NULL` would force a replicated table or another materially different integration surface.
  The base constraints and non-null result decoders provide the value guarantee without copied
  state or write amplification.
  Date: 2026-08-13

- Decision: Make the view structurally non-updatable with a top-level
  `WITH checkpoint_rows AS NOT MATERIALIZED (...)` query and explicitly set
  `security_invoker = false`.
  Rationale: The direct illustrative view in IR-5 is automatically updatable. Relying only on the
  absence of DML grants would make "read-only" an operator convention. The top-level common-table
  expression makes PostgreSQL report `is_updatable = NO` and reject owner updates with SQLSTATE
  `55000`, while `NOT MATERIALIZED` lets predicates reach the private table. Explicit owner-rights
  evaluation lets a role with only schema `USAGE` and view `SELECT` read the relation while direct
  private-table access fails with SQLSTATE `42501`.
  Date: 2026-08-13

- Decision: Freeze exactly four v1 columns and add no row-order promise, topology fields, store
  frontier, mutation operation, role, grant, materialized copy, trigger, or new index.
  Rationale: Those exclusions preserve IR-2's and ADR-4's established semantics, keep Keiro as the
  owner of expected subscription topology, and make runtime and maintenance cost equivalent to a
  direct read of the current checkpoint rows. SQL consumers must name columns and add their own
  `ORDER BY` when order matters.
  Date: 2026-08-13

- Decision: Prepare `kiroku-store-migrations` 0.3.1.0 as the release carrying the relation, without
  changing the `pg-migrate ^>=1.1.0.0` bounds or releasing other Kiroku packages.
  Rationale: Hackage and upstream tags both identify 0.3.0.0 as the latest migrations package and
  1.1.0.0 as the latest `pg-migrate` release at planning time. The change adds migration behavior
  without changing exported Haskell declarations, so the PVP feature component is the appropriate
  bump and existing `^>=0.3` consumers admit it.
  Date: 2026-08-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestone 1 published the nine-entry native migration plan and the frozen
`kiroku.subscription_checkpoints_v1` catalog contract without changing pg-migrate's verifier or
the seven-entry legacy lock. The full migration package suite passes 11 examples, including fresh,
rerun, concurrent, and both Codd-ledger import shapes. Behavioral, privilege, dependency, and
query-plan proofs remain for Milestone 2.


## Context and Orientation

Kiroku is a PostgreSQL event store. A subscription is a worker that reads events and records how
far its handler has durably completed. The private table `kiroku.subscriptions` contains one row
per `(subscription_name, consumer_group_member)` key. `last_seen` is that member's exact persisted
global position and `updated_at` is the latest upsert time. Member zero can mean either an ordinary
subscription or member zero of a group, so the row does not determine topology.

`kiroku-store-migrations/migrations/manifest` is the authoritative ordered list of schema changes.
`kiroku-store-migrations/src/Kiroku/Store/Migrations/Internal/Definition.hs` embeds that manifest
at compile time and exposes it through `kirokuMigrationPlan` in
`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs`. The current manifest ends at
`0008-schema-management-comment.sql`. The standard authoring command creates the next file as
`kiroku-store-migrations/migrations/0009.sql` and appends that filename to the manifest. Do not edit
the released migrations `0001` through `0008`, and do not add `0009` to
`kiroku-store-migrations/migrations.lock`: that lock is evidence for the first seven historical
Codd payloads only.

`kiroku-store-migrations/test/Main.hs` currently hard-codes the eight-file native plan in
`nativeMigrationFiles`, the fresh-apply and rerun counts, the concurrent-apply outcomes, and the
Codd-import transition. Adding `0009` changes a fresh plan to nine entries. A legacy Codd import
still imports exactly the first seven mappings, after which both `0008` and `0009` are pending and
`up` applies them. The same test module already owns ephemeral PostgreSQL setup, Hasql statements,
and schema assertions; it is the narrowest place for the relation catalog, role, dependency, and
query-plan proofs.

`kiroku-test-support/src/Kiroku/Test/Postgres.hs` applies `kirokuMigrationPlan` to every store test
database. `kiroku-store/test/Test/SubscriptionCheckpointInventory.hs` already proves empty,
single-member, multi-member, monotonic, stopped-worker, in-flight, and dead-letter checkpoint
semantics through the public Haskell inventory.
`kiroku-store/test/Test/SubscriptionCheckpointReset.hs` proves committed and rolled-back explicit
reset, including deliberate regression. The SQL relation test should compare its rows with the
durable Haskell inventory in representative cases rather than duplicate every lifecycle fixture.

A PostgreSQL view is a stored query, not a materialized copy. The proposed relation runs its query
when selected, so checkpoint writes do no additional work. The view must use the following shape:

```sql
CREATE VIEW kiroku.subscription_checkpoints_v1
    (subscription_name,
     consumer_group_member,
     checkpoint_position,
     checkpoint_updated_at)
WITH (security_invoker = false)
AS
WITH checkpoint_rows AS NOT MATERIALIZED (
    SELECT subscription_name,
           consumer_group_member,
           last_seen AS checkpoint_position,
           updated_at AS checkpoint_updated_at
    FROM kiroku.subscriptions
)
SELECT subscription_name,
       consumer_group_member,
       checkpoint_position,
       checkpoint_updated_at
FROM checkpoint_rows;
```

The top-level `WITH` makes the view non-updatable. `NOT MATERIALIZED` directs PostgreSQL to fold the
named query into the caller's query, retaining predicate pushdown. `security_invoker = false`
means base-table privileges are checked against the view owner. Kiroku migrations create the view
as the same role that owns the private table; an external reader needs only `USAGE` on schema
`kiroku` and `SELECT` on the view. The migration must not create or guess an application role.

The planning proof used PostgreSQL 18.4 with 10,000 checkpoint rows. A filtered `min` query through
the view selected 100 rows using a bitmap scan on `ix_subscriptions_name_member`, with no CTE scan
or materialization. The non-updatable CTE form completed in 0.088 ms in that local diagnostic.
Timing is environment-specific and is not an absolute gate; the structural requirements are that
the plan names the existing index and contains no `CTE Scan`. A real role with only `USAGE` and
view `SELECT` read all rows while `has_table_privilege` on the private table was false and a direct
private-table query returned SQLSTATE `42501`. A downstream aggregate view remained queryable after
`CREATE OR REPLACE VIEW` repointed the Kiroku relation to replacement storage and the old private
table was dropped.

`kiroku-store-migrations` depends on `mori://shinzui/pg-migrate/packages/pg-migrate` and its
companion packages. Mori locates the source at `mori://shinzui/pg-migrate`; its public documentation
and source state that `verify` compares plan and ledger and does not inspect live schema. At plan
creation, authoritative Hackage metadata and upstream tags both reported `pg-migrate` 1.1.0.0 as
current, matching the existing Cabal bounds and Git tag pin. They also reported
`kiroku-store-migrations` 0.3.0.0 as the current published/tagged version.

The relevant local decisions are [ADR-2](../adr/0002-static-hash-partitioned-consumer-groups.md),
which fixes per-member identity and rejects inferred topology;
[ADR-3](../adr/0003-dedicated-kiroku-schema.md), which makes Kiroku the schema owner and migrations
the sole DDL authority; [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md), which
separates monotonic save from explicit transactional reset; and
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md), which prefers structural plan
assertions over noisy absolute timing gates. No existing ADR owns the compatibility promise for a
versioned public SQL relation, so Milestone 3 creates one using the profiled `docs/adr` workflow.
`docs/adr/profile.dhall` was read and successfully type-checked during planning.


## Plan of Work

### Milestone 1 — Correct the request and publish the migration contract

First update
`docs/improvement-requests/publish-a-stable-sql-subscription-checkpoint-relation.md` without
changing its stable `requestId: IR-5`. Replace catalog-level `NOT NULL` and generic expected-schema
claims with the semantic non-null and focused catalog-test contract described in this plan. State
plainly that `pg-migrate verify` remains ledger verification. Preserve the four column names,
order, SQL types, value semantics, grants example, v1 freeze, and all lifecycle boundaries. Update
the document timestamp and review provenance according to
`mori/improvement-requests-profile.dhall`, add the bundle log entry, and leave status `proposed`
until source implementation exists.

Run the standard migration authoring command against
`kiroku-store-migrations/migrations/manifest`. Fill the generated
`kiroku-store-migrations/migrations/0009.sql` with the exact view above and `COMMENT ON VIEW` plus
one `COMMENT ON COLUMN` statement for each column. Comments must say that positions are exact
persisted member positions, timestamps are latest upserts rather than liveness or advancement,
member zero carries no topology classification, rows are not ordered without caller `ORDER BY`,
and v1 is frozen. Do not use `IF NOT EXISTS`: the manifest runner applies the migration once and a
pre-existing conflicting object must fail loudly.

Extend `kiroku-store-migrations/test/Main.hs` so `nativeMigrationFiles` contains `0009.sql`, all
fresh/concurrent/rerun expectations contain nine outcomes, and Codd-import expectations contain
seven imported entries followed by two native pending/applied entries. Replace prose such as
"eight migrations" with values derived from `length nativeMigrationFiles` where that improves
future maintainability, while keeping assertions explicit enough to detect accidental manifest
changes.

Add a focused `describe "subscription checkpoint SQL relation"` group to that test module. Query
`pg_catalog.pg_class`, `pg_catalog.pg_attribute`, `information_schema.views`,
`pg_catalog.obj_description`, and `pg_catalog.col_description`. Assert the relation is an ordinary
view; its ordered `(name, format_type)` vector is exactly the four-column contract; its
`attnotnull` values are all false for the documented PostgreSQL metadata behavior; its
`reloptions` explicitly contain `security_invoker=false`; it is not updatable or insertable; its
owner OID equals the private table owner OID; and all five comments match reviewed text. Keep the
catalog query and expected value local to tests—do not add a production runtime verifier or public
Haskell API.

At the end of this milestone, a fresh migrated database has the relation and the focused catalog
test passes. `kiroku-store-migrate verify` still means plan-versus-ledger verification and reports
all nine migrations applied.

### Milestone 2 — Prove semantics, privilege isolation, dependency survival, and performance

In `kiroku-store-migrations/test/Main.hs`, add real PostgreSQL behavior examples around the catalog
contract. An empty migrated database must return zero relation rows. Seed ordinary and grouped
checkpoint rows and decode all four columns with non-null Hasql decoders; assert exact name/member,
position, timestamp, and one-row-per-member behavior. Perform a direct position reassignment inside
a transaction, show the relation changes only after commit, and show a rolled-back reassignment is
invisible. This is migration-package SQL evidence; the existing store tests remain authoritative
for the public save/reset APIs.

Create a temporary real PostgreSQL role inside the ephemeral test cluster, with cleanup in
`finally` or `bracket`. Grant only schema `USAGE` and view `SELECT`. Under `SET ROLE`, assert that a
view query succeeds, `has_table_privilege` for `kiroku.subscriptions` is false, and a direct table
query fails with SQLSTATE `42501`. Separately, as the owner, attempt an update through the view and
assert SQLSTATE `55000`, proving that read-only behavior is structural rather than merely an ACL
convention. Do not put any `CREATE ROLE` or `GRANT` in `0009.sql`.

Add an isolated dependency fixture. Create a downstream view in `public` that groups
`kiroku.subscription_checkpoints_v1`; create replacement private storage; repoint the public Kiroku
view with `CREATE OR REPLACE VIEW` while preserving names, order and types; drop the old private
table; and assert the downstream view still returns the same result. This fixture proves the
integration benefit without making Kiroku tests depend on the Keiro checkout.

Seed 10,000 rows spread across at least 100 subscription names, run `ANALYZE`, and capture
`EXPLAIN (COSTS OFF)` for a filtered `min(checkpoint_position)` query through the public view. Add a
structural assertion that the plan names `ix_subscriptions_name_member` and contains no `CTE Scan`.
Do not assert an elapsed-time threshold or require a particular `Index Scan` versus `Bitmap Index
Scan`, because both are valid choices across PostgreSQL 17 and 18.

Extend `kiroku-store/test/Test/SubscriptionCheckpointInventory.hs` with one test-only statement
that selects the public SQL relation in explicit key order. In the existing empty, multi-member,
stopped-worker, and synchronized in-flight scenarios, compare those SQL rows with the matching
fields returned by `subscriptionCheckpointInventory`. Reuse the reset suite's existing commit and
rollback evidence rather than duplicating its setup; the direct-view definition plus both suites
together prove reset visibility and rollback. No source module in `kiroku-store/src` changes.

At the end of this milestone, the relation has real role, lifecycle, downstream dependency, and
query-plan evidence. There is still one checkpoint authority and no extra write work.

### Milestone 3 — Document and record the stable contract

Update `docs/user/schema.md` with a dedicated `subscription_checkpoints_v1` section. Include the
four columns and value meanings, semantic non-null guarantee versus nullable catalog metadata,
zero-row empty behavior, no implicit row order, explicit read-only/security mode, v1 compatibility
policy, and the least-privilege `GRANT` example. State that future incompatible or extended shapes
receive `subscription_checkpoints_v2`; do not promise additive v1 columns.

Update `docs/user/subscriptions.md` near "Reading Durable Checkpoints" to distinguish three
surfaces: `subscriptionStates` for process-local live workers, the Haskell
`subscriptionCheckpointInventory` for a mockable inventory plus same-statement store frontier, and
the SQL relation for database-native clients without that frontier. Update
`docs/user/schema-migrations.md`, `kiroku-store-migrations/README.md`, and
`docs/capabilities/schema-provisioning.md` so their migration counts distinguish nine native
entries from the first seven legacy Codd entries and their verifier language remains accurate.
Correct the now-stale `cabal.project` comment which says pg-migrate 1.1.0.0 is not on Hackage, but
do not change dependency bounds or source pins in this feature.

Add the feature under `Unreleased` in `kiroku-store-migrations/CHANGELOG.md`. Do not add a
`kiroku-store` package changelog entry because that package ships no source API or SQL payload in
this plan.

Create a new ADR under `docs/adr/` using the profile-governed allocation workflow. Run
`okf id list` and `okf id next`; if the reported handle is `ADR-6`, name the file
`docs/adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md`, otherwise use the
returned number with the same slug. Record owner-published relations, frozen name/version/ordered
shape, owner-rights view access, structural read-only design, semantic rather than catalog
nullability, and the choice not to make pg-migrate a live-schema verifier. Add the ADR bundle log
entry and cite the new ADR from IR-5 and this plan once its path is known.

After source and documentation are complete, set IR-5 to `implemented`, update its review evidence,
and keep `completedAt` absent. Run formatting, focused suites, all package tests, the Nix checks,
strict ADR and improvement-request profile validation, and `git diff --check`. Update this plan's
Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective with actual evidence.

At the end of this milestone, all behavior is implemented and validated from source. Publication
is the only remaining acceptance item.

### Milestone 4 — Release the owning migration package and complete IR-5

Do not upload, push a tag, or create a GitHub release until the user explicitly authorizes the
release in the implementation session. After approval, use the repository's `release` skill for
`kiroku-store-migrations` and follow its preflight, PVP, build, upload, tag, and verification rules.
Bump only `kiroku-store-migrations/kiroku-store-migrations.cabal` from 0.3.0.0 to 0.3.1.0 and turn
the Unreleased changelog entry into a dated 0.3.1.0 section. Existing consumers have no bound
change because `^>=0.3` admits the feature release.

After Hackage index refresh, verify that authoritative Hackage metadata reports 0.3.1.0, the
annotated upstream tag `kiroku-store-migrations-v0.3.1.0` resolves to the release commit, and the
published source tarball contains `migrations/0009.sql` plus the manifest line. Build the published
package in a clean temporary Cabal project, apply its migration plan to ephemeral PostgreSQL, and
run a query against `kiroku.subscription_checkpoints_v1`. Record URLs, tag object/commit, package
hash or tarball evidence, and the clean-consumer output in this plan.

Only after that evidence exists, set IR-5 to `completed`, add `completedAt`, update its technical
review and verification metadata, write the improvement-request bundle log entry, and rerun strict
profile validation. The owning request may complete without editing Keiro; downstream adoption is
tracked by the canonical Keiro MasterPlan and its child plan.


## Concrete Steps

Run all commands from repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless a step says otherwise.

Before editing, confirm the worktree and authoritative dependency/release state:

```bash
git status --short
mori registry show shinzui/pg-migrate --full
mori registry docs shinzui/pg-migrate
curl -fsSL https://hackage.haskell.org/package/pg-migrate/preferred.json
curl -fsSL https://hackage.haskell.org/package/kiroku-store-migrations/preferred.json
git ls-remote --tags https://github.com/shinzui/pg-migrate.git
git ls-remote --tags https://github.com/shinzui/kiroku.git 'refs/tags/kiroku-store-migrations-v*'
```

Expected release facts before implementation are:

```text
pg-migrate normal version: 1.1.0.0
pg-migrate latest upstream tag: v1.1.0.0
kiroku-store-migrations normal version: 0.3.0.0
kiroku-store-migrations latest upstream tag: kiroku-store-migrations-v0.3.0.0
```

Create the forward migration through the checked-in authoring surface:

```bash
cabal run kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "publish stable subscription checkpoints v1"
```

Expected output includes:

```text
Created kiroku-store-migrations/migrations/0009.sql
```

After filling the SQL and tests, validate the manifest and focused relation group:

```bash
cabal run kiroku-store-migrate -- check \
  --manifest kiroku-store-migrations/migrations/manifest
cabal test kiroku-store-migrations:kiroku-store-migrations-test \
  --test-show-details=direct \
  --test-options='--match "subscription checkpoint SQL relation"'
```

Expected focused result:

```text
subscription checkpoint SQL relation
  ...
0 failures
```

Run the existing durable API and reset suites together with the new SQL comparison:

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "SubscriptionCheckpointInventory"'
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "SubscriptionCheckpointReset"'
```

Both commands must finish with `0 failures`. The relation plan diagnostic must contain the existing
index and no materialized CTE:

```text
Index Name: ix_subscriptions_name_member
CTE Scan: absent
```

Allocate and validate the ADR using the repository profile:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Update the improvement-request bundle with its own profile and validate it strictly:

```bash
okf validate docs/improvement-requests \
  --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
```

Run repository-wide validation before any release:

```bash
nix fmt
cabal build all
cabal test all
nix flake check
git diff --check
```

Record the actual example counts and any PostgreSQL 17/18 plan differences in this plan. Do not
claim completion from a build alone.

Every implementation commit must use Conventional Commits and include both active trailers. For
example:

```text
feat(migrations): publish subscription checkpoints v1

Add the frozen read-only SQL relation, catalog and privilege proofs,
documentation, and compatibility decision.

ExecPlan: docs/plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md
Intention: intention_01kzy7xty0eg18f534v2rdvbb8
```

Milestone 4 must run through `agents/skills/release/SKILL.md`. After authorized publication, verify
the two authoritative identities again:

```bash
curl -fsSL https://hackage.haskell.org/package/kiroku-store-migrations/preferred.json
git ls-remote --tags https://github.com/shinzui/kiroku.git \
  'refs/tags/kiroku-store-migrations-v0.3.1.0*'
```

Expected final evidence contains Hackage normal version `0.3.1.0` and both the annotated tag object
and peeled commit for `kiroku-store-migrations-v0.3.1.0`.


## Validation and Acceptance

Acceptance is behavioral and cumulative:

1. A fresh native migration run reports nine applied Kiroku migrations and creates an ordinary
   view named `kiroku.subscription_checkpoints_v1`. Its ordered columns are exactly
   `subscription_name text`, `consumer_group_member integer`, `checkpoint_position bigint`, and
   `checkpoint_updated_at timestamp with time zone`. PostgreSQL catalog nullability is documented
   as nullable; fixture rows decode all four values as non-null.
2. The relation and each column have reviewed SQL comments. `security_invoker=false` is explicit,
   the view and private table have the same owner, and `information_schema.views` reports the view
   as neither updatable nor insertable.
3. An empty checkpoint inventory returns zero rows. Ordinary and grouped fixtures return one exact
   row per persisted member. A stopped worker remains visible; an in-flight handler exposes only
   its previous committed position; a committed explicit reset is visible, including regression;
   and a rolled-back reset is not visible.
4. A real role granted only `USAGE ON SCHEMA kiroku` and
   `SELECT ON kiroku.subscription_checkpoints_v1` successfully reads the view. Its direct select
   from `kiroku.subscriptions` fails with SQLSTATE `42501`. An owner update through the view fails
   with SQLSTATE `55000`.
5. A downstream persisted aggregate view depends only on
   `kiroku.subscription_checkpoints_v1`, survives a same-shape `CREATE OR REPLACE VIEW` that points
   to replacement private storage, and remains queryable after the old private table is dropped.
6. At 10,000 mixed checkpoint rows, a subscription-name-filtered aggregate through the public view
   uses `ix_subscriptions_name_member` and has no `CTE Scan`. There is no new table, materialized
   view, trigger, index, checkpoint write, or runtime round trip.
7. `pg-migrate verify` remains plan-versus-ledger verification. The focused migration test—not a
   restored generic snapshot system—fails if the relation is absent or its kind, ordered names,
   types, security option, owner relationship, read-only status, or comments drift.
8. User documentation contains the frozen v1 promise, semantic-nullability caveat, exact value
   meanings, explicit column selection and ordering advice, Haskell/live/SQL distinction, and a
   copyable least-privilege grant example. It says migrations create neither roles nor grants.
9. All focused and full validation commands in Concrete Steps pass. The new ADR and corrected IR-5
   pass strict profile and log enforcement.
10. After separately authorized release, Hackage and the annotated upstream tag agree on
    `kiroku-store-migrations` 0.3.1.0, its source archive contains `0009.sql`, a clean consumer can
    apply the published plan and query the relation, and IR-5 is marked completed with that
    evidence.


## Idempotence and Recovery

The authoring command is exclusive: if `0009.sql` or the manifest entry already exists, inspect
both and continue rather than running `new` again. Before `0009` has been applied anywhere
persistent, an authoring mistake can be corrected in the pending file. After it is applied or
released, never edit it; append `0010.sql` as a forward correction.

The migration is transactional. If `CREATE VIEW` or a comment fails, pg-migrate rolls back both
the schema effect and its ledger row, so correcting the pending file and rerunning is safe. A
pre-existing relation with the public name is a collision that must be investigated, not bypassed
with `IF NOT EXISTS` or `CREATE OR REPLACE` in the initial migration.

Tests create roles and downstream fixtures only inside ephemeral PostgreSQL clusters. Use
`bracket` or `finally` for role cleanup so a failed assertion does not poison a cached test server.
The dependency-replacement fixture runs in its own disposable database because it drops the
private table; it must never target a developer or persistent database.

`CREATE OR REPLACE VIEW` can preserve an existing view only when the existing columns retain their
names, order, and data types. Future private-storage migrations should create replacement storage,
copy or redirect data as appropriate, replace the v1 query without dropping the public view, and
only then retire old storage. If an incompatible public shape is needed, create v2 and leave v1 in
place for its documented compatibility window.

Do not attempt to make ordinary view columns catalog-`NOT NULL` by replacing the view with a table
or materialized view. That would create copied state and a new write/refresh lifecycle and requires
a new request and performance design.

Release operations are the only externally irreversible part. Before upload, rerun all validation
and confirm 0.3.1.0 is unused on Hackage and upstream. If upload succeeds but later verification
fails, do not move or delete the public tag and do not overwrite Hackage; follow the release
skill's recovery procedure and publish a higher patch/feature version. IR-5 stays `implemented`,
not `completed`, until both authoritative artifacts and clean-consumer evidence agree.


## Interfaces and Dependencies

The new supported database interface is the relation:

```text
kiroku.subscription_checkpoints_v1
  subscription_name       text
  consumer_group_member   integer
  checkpoint_position     bigint
  checkpoint_updated_at   timestamp with time zone
```

Every returned value is semantically non-null. The relation contains one row per persisted exact
checkpoint key and no synthetic empty-inventory row. It has no inherent row order. It does not
include the current store frontier, stream target, group size, live worker state, reset cause, or
projection-group identity.

The privilege interface is deployment-owned:

```sql
GRANT USAGE ON SCHEMA kiroku TO checkpoint_reader;
GRANT SELECT ON kiroku.subscription_checkpoints_v1 TO checkpoint_reader;
```

Kiroku creates neither `checkpoint_reader` nor either grant. The view owner must retain access to
its private source relation. Consumers receive no `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`,
`REFERENCES`, `TRIGGER`, or base-table privileges.

No exported Haskell declaration changes. The existing interfaces remain:

```haskell
kirokuMigrations :: Either DefinitionError MigrationComponent
kirokuMigrationPlan :: Either PlanError MigrationPlan

subscriptionCheckpointInventory ::
    (HasCallStack, Store :> es) =>
    Eff es SubscriptionCheckpointInventory
```

The Haskell inventory still returns the same-statement append frontier and remains mockable. The
SQL relation is for database-native composition and returns only checkpoint-member rows.

The implementation uses the already-bound `pg-migrate`, `pg-migrate-embed`,
`pg-migrate-import-codd`, and `pg-migrate-test-support` 1.1.0.0 packages located through
`mori://shinzui/pg-migrate`. It must not import any `Internal` pg-migrate module and requires no
dependency upgrade. PostgreSQL 17 and 18 are the supported database majors; both support
`security_invoker` view options and `NOT MATERIALIZED` common-table expressions.

The local artifacts controlling durable context are IR-5, the newly allocated ADR, and this plan.
The downstream dependency remains
`mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.
Its current registry cannot yet resolve that MasterPlan handle, but the producing Keiro repository
defines that exact intended canonical URI; do not replace it with an absolute path or bare plan
number.


## Revision Note

2026-08-13T20:37:07Z: Recorded Milestone 1 completion after generating `0009.sql`, correcting
IR-5's PostgreSQL catalog and verifier contract, and passing the manifest check plus all 11 native
migration examples. The remaining milestones and release authorization boundary are unchanged.
