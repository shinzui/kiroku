---
type: Architecture Decision Record
title: Versioned public SQL relations are owner-published and frozen
description: "Publish database-native integration surfaces as owner-rights, structurally read-only versioned relations with frozen ordered shapes, semantic non-null guarantees, and focused catalog tests."
generated:
  by: openai/gpt-5
  at: "2026-08-13T20:45:05Z"
docId: ADR-6
status: Accepted
date: 2026-08-13
timestamp: "2026-08-13T20:45:05Z"
originatingPlan: docs/plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md
---

# ADR-0006: Versioned public SQL relations are owner-published and frozen

- **Related:** [ExecPlan 72](../plans/72-publish-a-stable-sql-subscription-checkpoint-relation.md);
  [IR-5](../improvement-requests/publish-a-stable-sql-subscription-checkpoint-relation.md);
  [ADR-3](0003-dedicated-kiroku-schema.md);
  [ADR-4](0004-explicit-subscription-checkpoint-lifecycle.md);
  [ADR-5](0005-three-tier-performance-regression-gates.md);
  `mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`.

## Context

Kiroku's Haskell APIs expose durable facts without making its PostgreSQL tables public. A
database-native consumer or a persisted downstream view cannot call a Haskell effect, however; it
needs a relation it can join. Depending directly on a private Kiroku table would freeze internal
storage names and columns and could make a later storage replacement fail because PostgreSQL tracks
downstream object dependencies.

The first required database-native surface is exact subscription-member checkpoints. It must not
become a copied checkpoint authority, add work to checkpoint writes, expose mutation, or require a
reader to receive privileges on the private table. PostgreSQL ordinary views satisfy the no-copy
requirement but do not carry base-column `NOT NULL` flags in their own catalog attributes.
`pg-migrate verify` also has an intentionally narrower job: it compares a declared migration plan
with the durable ledger, not arbitrary live schema objects.

## Decision

Publish supported database-native integration surfaces as Kiroku-owned, explicitly versioned SQL
relations. The first surface is `kiroku.subscription_checkpoints_v1`.

- Freeze the versioned relation name and its ordered column names, SQL types, and value meanings.
  Do not add columns to v1. An incompatible or extended row contract receives a new relation such
  as v2, while v1 remains available for its documented compatibility window.
- Create the relation through `kiroku-store-migrations` under the same owner as its private source.
  Set `security_invoker = false` explicitly so PostgreSQL checks base-table access with the view
  owner's privileges. Deployments create reader roles and grant schema `USAGE` plus view `SELECT`;
  Kiroku migrations create no role and grant no access automatically.
- Make the ordinary view structurally non-updatable with a top-level common-table expression. Mark
  that expression `NOT MATERIALIZED` so PostgreSQL can push caller predicates into private storage.
  Do not use a table, materialized view, trigger, copied checkpoint, or refresh lifecycle merely to
  publish the read surface.
- Guarantee non-null values semantically through constrained sources and non-null decoders. Accept
  and document that PostgreSQL reports ordinary-view columns with
  `pg_attribute.attnotnull = false` and `information_schema.columns.is_nullable = YES`.
- Preserve downstream dependencies during private-storage replacement by creating replacement
  storage, using same-shape `CREATE OR REPLACE VIEW` to repoint the public relation, and only then
  dropping the old storage. Column names, order, and types must remain unchanged for replacement.
- Keep `pg-migrate verify` as plan-versus-ledger verification. Each stable SQL relation receives a
  focused migration-package test for relation kind, frozen ordered shape, catalog-nullability
  behavior, security option, owner relationship, read-only status, comments, privileges,
  replacement behavior, and representative query-plan structure.

## Consequences

**Positive**

- Database clients and downstream views gain a supported integration boundary without importing
  Haskell or depending on private Kiroku storage.
- Reader roles can query public facts without direct access to private tables, while Kiroku retains
  one checkpoint authority and one write path.
- Private storage can change behind a stable PostgreSQL dependency object when the public shape is
  preserved.
- Structural tests detect contract drift without broadening a migration-ledger verifier into a
  runtime schema snapshot system.

**Negative**

- A published versioned relation becomes a compatibility obligation; even an apparently additive
  column requires a new version.
- Generic schema introspection reports the view columns as nullable despite the semantic value
  guarantee, so clients and documentation must account for that PostgreSQL behavior.
- The view owner must retain private-source privileges, and deployments must manage reader roles
  and grants explicitly.
- Representative optimizer assertions must allow equivalent PostgreSQL scan variants while still
  requiring the intended index and absence of materialization.

## Alternatives Considered

- **Let consumers query `kiroku.subscriptions`.** Rejected because it publishes private storage by
  accident and lets downstream dependencies block or coordinate internal migrations.
- **Mirror checkpoints into a public table or materialized view.** Rejected because copied state
  creates a second authority, write or refresh work, and a new failure lifecycle.
- **Rely only on the absence of DML grants.** Rejected because the owner could still update an
  automatically updatable view; structural non-updatability makes read-only behavior intrinsic.
- **Use invoker-rights security.** Rejected because every reader would need private-table
  privileges, defeating the integration boundary.
- **Restore a generic expected-schema snapshot verifier.** Rejected because the focused contract
  test proves this stable surface without restoring the retired Codd snapshot generator, package
  closure, and PostgreSQL-major-specific artifacts or changing pg-migrate's verifier semantics.
