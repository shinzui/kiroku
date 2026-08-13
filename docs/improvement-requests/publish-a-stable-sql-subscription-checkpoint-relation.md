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
timestamp: "2026-08-13T20:32:58Z"
requestId: IR-5
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T20:32:58Z"
    document_timestamp: "2026-08-13T20:32:58Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against the Kiroku checkpoint inventory, checkpoint SQL, native migration schema,
      pg-migrate 1.1.0.0 source and PostgreSQL ordinary-view behavior. The request is sound after
      specifying semantic non-null values, a structurally read-only owner-rights view, and a
      focused Kiroku catalog test instead of treating ledger verification as live-schema
      verification.
verified:
  by: process:codex
  at: "2026-08-13T20:32:58Z"
---

# Improvement Request: Publish a Stable SQL Subscription Checkpoint Relation

## Status

Proposed as an owning-library prerequisite of
`mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.
That artifact handle is intended and awaits a Keiro registry refresh; the producing file is
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md` in
`mori://shinzui/keiro`.

Keiro needs this relation before it can publish a durable SQL status contract for out-of-process
projection readers. The request is independently useful to database-native monitoring and
coordination tools that cannot call Kiroku's Haskell `Store` effect.

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


## Requested Deliverables

- A native `kiroku-store-migrations` migration for the view and comments.
- Focused catalog-contract and migration-fixture coverage for the view and ordered columns.
- Real PostgreSQL semantic and least-privilege tests.
- User documentation with explicit v1 compatibility and grants examples.
- Changelog entries identifying the new supported SQL contract.
- A released `kiroku-store-migrations` version whose authoritative registry metadata and upstream
  tag agree, so downstream migration bounds can be chosen from released evidence rather than the
  local corpus alone.
