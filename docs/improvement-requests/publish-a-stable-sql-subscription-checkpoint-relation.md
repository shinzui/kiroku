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
timestamp: "2026-08-13T18:52:50Z"
requestId: IR-5
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-08-13T18:52:50Z"
    document_timestamp: "2026-08-13T18:52:50Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against the Kiroku checkpoint inventory, checkpoint SQL, native migration schema,
      and Keiro MasterPlan 41. Kiroku publishes the durable inventory through its Haskell Store
      effect, but it has no stable SQL relation; a downstream persisted view would otherwise have
      to reference the private subscriptions table and become coupled to Kiroku's internal DDL.
verified:
  by: process:codex
  at: "2026-08-13T18:52:50Z"
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
facts. The requested v1 contract is equivalent to:

```sql
CREATE VIEW kiroku.subscription_checkpoints_v1 AS
SELECT subscription_name,
       consumer_group_member,
       last_seen AS checkpoint_position,
       updated_at AS checkpoint_updated_at
FROM kiroku.subscriptions;
```

The definition is illustrative, not the contract. Kiroku may change the private source table or
replace the view body without affecting clients. The supported v1 contract is the relation name
and these columns in this exact order:

```text
subscription_name       text        not null
consumer_group_member   integer     not null
checkpoint_position     bigint      not null
checkpoint_updated_at   timestamptz not null
```

The relation has one row per persisted checkpoint member. It returns no synthetic row for an
empty inventory. A consumer that needs a subscription-wide floor calculates
`min(checkpoint_position)` across all known members and must separately know which subscription
names and member set it expects. The relation does not claim that member zero distinguishes a
non-group subscription from member zero of a group.

Ship the relation through `kiroku-store-migrations` so pg-migrate owns its lifecycle and the
expected-schema verifier detects its absence or incompatible shape. Add SQL `COMMENT` text to the
relation and every column documenting the exact semantics. If the current verifier does not
inspect views and ordered view columns, extend its checked object classes in the same change.

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
   documented v1 columns, types, order, and nullability.
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
8. The migration and expected-schema verifier detect a missing view, renamed column, reordered or
   retyped column, and changed nullability.
9. Kiroku user documentation states the frozen v1 compatibility promise and distinguishes this
   SQL relation from the Haskell inventory and live worker registry.
10. A downstream fixture can create a persisted view that joins
    `kiroku.subscription_checkpoints_v1`, migrate Kiroku forward, and retain a valid dependency
    without referencing `kiroku.subscriptions`.


## Requested Deliverables

- A native `kiroku-store-migrations` migration for the view and comments.
- Expected-schema and migration-fixture coverage for views and ordered columns.
- Real PostgreSQL semantic and least-privilege tests.
- User documentation with explicit v1 compatibility and grants examples.
- Changelog entries identifying the new supported SQL contract.
- A released `kiroku-store-migrations` version whose authoritative registry metadata and upstream
  tag agree, so downstream migration bounds can be chosen from released evidence rather than the
  local corpus alone.
