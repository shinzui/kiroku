---
type: Improvement Request
title: Publish a stable SQL subscription checkpoint relation
description: >-
  Give PostgreSQL clients a versioned, supported relation for exact durable subscription-member
  checkpoints, so coordinating services can compose database views without depending on Kiroku's
  private subscriptions table or importing the Haskell Store effect.
generated:
  by: openai/gpt-5
  at: "2026-08-13T18:52:50Z"
timestamp: "2026-08-13T21:11:18Z"
requestId: IR-5
status: completed
completedAt: "2026-08-13T21:11:18Z"
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T21:11:18Z"
    document_timestamp: "2026-08-13T21:11:18Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Re-reviewed migration 0009, all 16 migration-package examples, the Haskell inventory and
      reset suites, PostgreSQL 18.4 role/dependency/query-plan evidence, user documentation,
      ADR-6, Hackage metadata and tarball contents, the annotated upstream tag, and an isolated
      clean consumer that applied the published plan and queried the relation. All acceptance
      items are satisfied.
verified:
  by: process:codex
  at: "2026-08-13T21:11:18Z"
---

# Improvement Request: Publish a Stable SQL Subscription Checkpoint Relation

## Status

Completed by
[ExecPlan 72](../plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md) as an
owning-library prerequisite of
`mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.
That artifact handle is intended and awaits a Keiro registry refresh; the producing file is
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md` in
`mori://shinzui/keiro`.

Migration `0009` and its manifest entry, focused catalog and behavior tests, Haskell-inventory
comparison, user guides, changelog, capability evidence, and
[ADR-6](../adr/0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) shipped in
[`kiroku-store-migrations` 0.3.1.0](https://hackage.haskell.org/package/kiroku-store-migrations-0.3.1.0).
The corresponding
[GitHub release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-migrations-v0.3.1.0)
and annotated upstream tag resolve to release commit
`8e53cf0a7efb1434176e745dc9fb3751425b2dcc`. Keiro adoption remains downstream work and does not
hold this owning-library request open.

The technical review has reconciled two PostgreSQL and pg-migrate constraints before source
implementation. An ordinary view returns non-null values from Kiroku's constrained base columns,
but PostgreSQL reports those view columns as nullable in generic catalog metadata. Also,
`pg-migrate verify` compares the declared migration plan with its ledger; it deliberately does not
inspect live schema objects. The acceptance contract below therefore requires semantic non-null
values plus a focused Kiroku-owned catalog test.


## Context

Kiroku owns durable subscription checkpoints. The private `subscriptions` table stores one row
per `(subscription_name, consumer_group_member)` key with exact `last_seen` and `updated_at`
values. Ordinary checkpoint saves are monotonic; explicit lifecycle reset is separate and
transaction-composable under
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-3` and
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`.

The completed
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2` publishes those durable facts
through `Kiroku.Store.Subscription.subscriptionCheckpointInventory`. Its implementation in
`kiroku-store/src/Kiroku/Store/Subscription/CheckpointInventory/SQL.hs` captures the monotonic
store position and every checkpoint in one statement, then returns a Haskell
`SubscriptionCheckpointInventory`. That is the correct API for Haskell consumers and mock
interpreters.

A PostgreSQL relation is a different integration boundary. A database view in another component
cannot call the Haskell effect. It can only join another database object. Today its only possible
source is the private `subscriptions` table, whose name and column layout carry no public
compatibility promise. PostgreSQL records dependencies between persisted views and their source
objects, so a future Kiroku migration that renames or replaces that private table can be blocked
by a downstream view or force a coordinated cross-repository migration.

Keiro MasterPlan 41 exposed this concrete problem. Keiro wants to publish
`keiro_read.projection_group_status_v1`, including the minimum durable checkpoint of every
subscription bound to a projection group. Reading `kiroku.subscriptions` directly would violate
the schema-ownership rule already used by Kiroku's public Haskell operations. Mirroring checkpoint
writes into a Keiro table would add a second cursor authority that can drift.


## Requested Change

Publish a Kiroku-owned, read-only, versioned SQL relation for exact durable checkpoint-member
facts. The requested v1 contract uses this structurally read-only form:

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

The top-level common-table expression, which is a named query inside the view, makes the view
non-updatable even to its owner. `NOT MATERIALIZED` lets PostgreSQL fold that query into a caller's
query so subscription-name predicates can still use the private table's existing index.
`security_invoker = false` explicitly uses the view owner's base-table privileges. Kiroku may
change the private source table or replace the view body without affecting clients. The supported
v1 contract is the relation name and these columns in this exact order:

```text
subscription_name       text        semantically non-null
consumer_group_member   integer     semantically non-null
checkpoint_position     bigint      semantically non-null
checkpoint_updated_at   timestamptz semantically non-null
```

The source columns are constrained `NOT NULL` and fixture rows must decode every field with
non-null decoders. PostgreSQL nevertheless reports ordinary-view columns with
`pg_attribute.attnotnull = false` and `information_schema.columns.is_nullable = YES`. That catalog
behavior is part of the documented v1 integration contract rather than a reason to introduce a
materialized copy or a second checkpoint authority.

The relation has one row per persisted checkpoint member. It returns no synthetic row for an
empty inventory. A consumer that needs a subscription-wide floor calculates
`min(checkpoint_position)` across all known members and must separately know which subscription
names and member set it expects. The relation does not claim that member zero distinguishes a
non-group subscription from member zero of a group.

Ship the relation through `kiroku-store-migrations` so pg-migrate owns its lifecycle. Keep
`pg-migrate verify` as strict plan-versus-ledger verification. Add a focused migration-package
test which queries PostgreSQL catalogs and fails if the relation is absent or its kind, ordered
columns, types, catalog nullability, security option, read-only status, owner relationship, or
comments drift. Do not restore the retired Codd expected-schema snapshot system or add a
production runtime schema verifier. Add SQL `COMMENT` text to the relation and every column
documenting the exact semantics.

Freeze v1. Do not use an open-ended “additive columns may appear” promise. A future incompatible
or extended row contract receives a separately named relation such as
`subscription_checkpoints_v2`; v1 remains available for its documented compatibility window.
Clients should name columns explicitly rather than use `SELECT *`.

Document deployment-owned privileges. Kiroku migrations do not create roles or grant access to a
guessed application role. The user guide gives a copyable least-privilege example equivalent to:

```sql
GRANT USAGE ON SCHEMA kiroku TO checkpoint_reader;
GRANT SELECT ON kiroku.subscription_checkpoints_v1 TO checkpoint_reader;
```

The granted role must be able to select the supported view without receiving `SELECT` on the
private `subscriptions` table or other Kiroku tables. The view owner and security mode must make
that behavior explicit and covered by a real-role database test.


## Semantics

`checkpoint_position` is the exact persisted global position for one durable subscription-member
key at the statement snapshot. It may trail an active worker's process-local cursor while a
handler is in flight. Stopped subscriptions remain present. Ordinary saves are monotonic, while a
supported explicit reset can deliberately move a checkpoint backward or forward; the SQL relation
reports the resulting persisted value without attempting to classify why it changed.

`checkpoint_updated_at` is the timestamp of the latest checkpoint-row upsert. It is not proof
that the position advanced, not a heartbeat, and not worker liveness. `subscriptionStates`
continues to own process-local worker state.

SQL statement snapshot semantics are sufficient. The relation does not promise a long-lived
snapshot across several statements. A consumer that needs a stable multi-relation view performs
its reads in one PostgreSQL transaction at an isolation level appropriate to that consumer.


## Boundaries

This request does not expose checkpoint mutation through SQL. Initialization, save, and reset
remain supported Kiroku Haskell operations with their existing atomicity and ownership. The
relation is read-only to consumers.

It does not expose `stream_name` or `consumer_group_size` as authoritative topology. Existing
IR-2 deliberately excluded those columns because every checkpoint-writing path does not maintain
them as a complete public contract.

It does not replace `subscriptionCheckpointInventory`. The Haskell inventory additionally
captures the authoritative append frontier in the same statement and remains the mockable API for
library and operator consumers. A zero-row SQL relation cannot by itself return that scalar
frontier, and Keiro's projection-group status does not require it.

It does not make Kiroku understand projection groups, projection freshness, or downstream role
names. Keiro owns group-to-subscription bindings and computes its own group floor from this
owner-published checkpoint relation.


## Acceptance

1. A freshly migrated database contains `kiroku.subscription_checkpoints_v1` with exactly the
   documented v1 columns, types, and order. Fixture values decode as non-null, while ordinary-view
   catalog metadata is explicitly asserted and documented as nullable.
2. An empty checkpoint inventory returns zero rows.
3. Saving a non-group checkpoint produces the exact name, member zero, persisted position, and
   update timestamp.
4. Saving several consumer-group members produces one row per exact member key; no row is merged
   or synthesized.
5. Stopping a worker leaves its durable row visible; an in-flight worker remains represented only
   by its last committed checkpoint.
6. Explicit checkpoint reset is reflected atomically after its transaction commits, including a
   deliberate regression, and is invisible if the surrounding transaction rolls back.
7. A database role granted only schema usage plus view selection can query the relation but cannot
   select the private checkpoint table.
8. A focused migration-package catalog test detects a missing view, renamed, reordered or retyped
   columns, catalog-nullability drift, changed security or read-only mode, owner divergence, and
   changed comments. `pg-migrate verify` remains plan-versus-ledger verification.
9. Kiroku user documentation states the frozen v1 compatibility promise and distinguishes this
   SQL relation from the Haskell inventory and live worker registry.
10. A downstream fixture can create a persisted view that joins
    `kiroku.subscription_checkpoints_v1`, migrate Kiroku forward, and retain a valid dependency
    without referencing `kiroku.subscriptions`.
11. At 10,000 mixed checkpoint rows, a subscription-name-filtered aggregate through the public
    relation uses `ix_subscriptions_name_member` and contains no materialized common-table scan.


## Implementation Evidence

`kiroku-store-migrations/migrations/0009.sql` creates the four-column
`kiroku.subscription_checkpoints_v1` view and all five reviewed comments. The manifest now has nine
native entries; the seven legacy Codd payloads and lock evidence remain byte-identical. The focused
group in `kiroku-store-migrations/test/Main.hs` proves the frozen catalog contract, empty and exact
non-null rows, two-connection commit/rollback visibility, view-only role access, direct-table
SQLSTATE `42501`, owner-update SQLSTATE `55000`, downstream-view survival across replacement
storage, and index use without a `CTE Scan` on PostgreSQL 18.4. The full migration package suite
passes 16 examples.

`kiroku-store/test/Test/SubscriptionCheckpointInventory.hs` compares the SQL relation with the
public Haskell inventory in empty, multi-member, stopped-worker, and synchronized in-flight
scenarios; the matched inventory group passes 10 examples. The existing
`kiroku-store/test/Test/SubscriptionCheckpointReset.hs` group passes four examples and remains the
authoritative public-API proof for committed regression and rollback. User documentation now
publishes the v1 compatibility, semantic-nullability, ordering, privilege, and three-surface
contracts. No production Haskell declaration, checkpoint write, copied table, trigger, or new
index changed.


## Release Evidence

Hackage's preferred-version metadata lists `0.3.1.0`. The published source tarball has SHA-256
`f93e2cdbd51301f51d846fccda45e21e24da25897c6b28537f3b99534db1687a`, matching the pre-upload
archive byte-for-byte; it contains `migrations/0009.sql`, and its packaged manifest ends with
`0009.sql`. Upstream tag object `30dfa04f79cf44c4256555320390eb868458883a` peels to release
commit `8e53cf0a7efb1434176e745dc9fb3751425b2dcc`.

An isolated temporary Cabal project used a fresh package index, cache, and store, constrained
`kiroku-store-migrations == 0.3.1.0`, and downloaded the package from Hackage. Its executable used
the published `kirokuMigrationPlan`, applied all nine migrations to an ephemeral PostgreSQL
database, queried `kiroku.subscription_checkpoints_v1`, and printed:

```text
published checkpoint relation verified: (True,0)
```


## Requested Deliverables

- A native `kiroku-store-migrations` migration for the view and comments.
- Focused catalog-contract and migration-fixture coverage for the view and ordered columns.
- Real PostgreSQL semantic and least-privilege tests.
- User documentation with explicit v1 compatibility and grants examples.
- Changelog entries identifying the new supported SQL contract.
- A released `kiroku-store-migrations` version whose authoritative registry metadata and upstream
  tag agree, so downstream migration bounds can be chosen from released evidence rather than the
  local corpus alone.
