---
type: Bug Report
title: Migration 0010 cannot apply to an already-bootstrapped PostgreSQL 17 database
description: >-
  Migration 0010 defaults history_retention_leases.lease_id to an unqualified uuidv7() while
  pinning no search_path, so on PostgreSQL 17 it parses only when an earlier migration in the
  same session happened to leave search_path pointing at the kiroku schema.
generated:
  by: anthropic/claude-opus-5
  at: "2026-08-16T13:29:06Z"
bugId: BUG-1
status: fixed
severity: degraded
fixedVersion: "0.4.0.0"
resolution: >-
  Fixed in kiroku-store-migrations 0.4.0.0 by the second option below. 0010 now publishes
  kiroku.uuidv7() on every supported major version -- PostgreSQL 17 already had 0001's fallback,
  PostgreSQL 18 gets a thin alias for the builtin -- and defaults lease_id to that qualified name,
  so the file stays search_path-free and every later migration has one generator to call.
  Correcting a released payload changes its checksum, which no forward migration could avoid
  because the withdrawn payload fails at DDL parse time; ledger-fixups/2026-08-16-rebaseline-
  0010-checksum.sql re-baselines the one ledger row for databases that already applied it, and
  new forward migration 0011 converges their schema. 0.3.2.0 and 0.3.2.1 are deprecated.
  The suggested component-wide audit found 0010 to be the only migration relying on 0001's
  search_path. The reason a fresh-install-only suite could not tell the difference is now
  recorded: the suite connects as role "kiroku", so the default "$user" search_path entry
  resolves to the Kiroku schema in every session it opens. The regression case pins
  search_path to pg_catalog and fails on the withdrawn payload against PostgreSQL 17.10.
origin: mori://shinzui/kioku
affects: mori://shinzui/kiroku/packages/kiroku-store-migrations
capability: mori://shinzui/kiroku/okf/capabilities/concepts/CAP-1
affectedVersion: "0.3.2.0"
lastWorkingVersion: "0.3.1.0"
environment: >-
  PostgreSQL 17.10. PostgreSQL 18 is unaffected, because pg_catalog.uuidv7() exists there and the
  0001 fallback is never installed.
observed: >-
  Applying the pending migrations to a database already bootstrapped through 0009 fails with
  SQLSTATE 42883, "function uuidv7() does not exist", while parsing 0010's
  kiroku.history_retention_leases table definition. Nothing in 0010 is applied.
expected: >-
  0010 applies to every PostgreSQL version the component supports, as CAP-1 claims for the
  embedded pg-migrate component and as 0001 intends by installing a kiroku.uuidv7() fallback
  specifically so that PostgreSQL 17 can resolve the name.
reproduction:
  - Start a PostgreSQL 17 server and create an empty database.
  - Apply kiroku migrations 0001 through 0009 in one psql session; this is the state any database managed by kiroku-store-migrations 0.3.1.0 or earlier is in.
  - Confirm the fallback exists — SELECT to_regprocedure('kiroku.uuidv7()') IS NOT NULL returns true.
  - In a new session, apply 0010 alone, which is what the runner does when 0010 is the only pending migration.
  - The session fails with 42883, "function uuidv7() does not exist", pointing at the lease_id default on line 18 of 0010.sql.
workaround: >-
  Run ALTER DATABASE <db> SET search_path TO kiroku, pg_catalog before applying, then reset it
  afterwards; the migration then parses and applies. Verified on PostgreSQL 17.10. The stored
  default is unaffected either way — PostgreSQL resolves a column default to a function OID at
  DDL time, so once 0010 is applied every session inserts leases correctly regardless of its own
  search_path.
---

# Migration 0010 cannot apply to an already-bootstrapped PostgreSQL 17 database

`0010.sql` declares

```sql
lease_id UUID PRIMARY KEY DEFAULT uuidv7(),
```

with the function name unqualified, and the file sets no `search_path` — correctly so, since the
component deliberately ships schema-qualified, `search_path`-free migrations, and every other
object in `0010` is written as `kiroku.<name>`.

`uuidv7()` is a PostgreSQL 18 builtin. On PostgreSQL 17 the name is supplied by the fallback that
`0001-kiroku-bootstrap.sql` installs, and `0001` creates it *unqualified* under
`SET search_path TO kiroku, pg_catalog`, so it lands in the `kiroku` schema as `kiroku.uuidv7()`.
Nothing puts `kiroku` on the search path of a later session.

## Why fresh installs pass and upgrades fail

The runner applies a plan over one connection. On a fresh install `0001` runs first in that
session and its `SET search_path` persists for the rest of the run, so by the time `0010` is
parsed the unqualified name resolves. The migration is correct only by that side effect.

An upgrade has no such luck. A database already bootstrapped through `0009` starts its run at the
first pending migration, in a session whose `search_path` is the default, and `0010` fails to
parse. This is the ordinary upgrade path, so the defect reaches every PostgreSQL 17 consumer
moving onto 0.3.2.0 — not only test fixtures.

Kioku sees both halves at once, which is what makes the split visible:

- `kioku-migrations-test`'s fresh-install and Kiroku-only-adoption cases apply all ten kiroku
  migrations in one run and pass.
- Its `testCoddCohortImport` case imports an existing ledger and then applies only the pending
  forward migrations. That case fails with exactly this error.

## Scope

The failure is entirely at DDL parse time. Once `0010` is applied — on PostgreSQL 18, on a fresh
PostgreSQL 17 install, or on PostgreSQL 17 through the workaround above — the column default is
stored as a resolved function OID, so lease acquisition works from any session and no runtime
behavior is at risk. Confirmed by inserting into `kiroku.history_retention_leases` from a session
with `search_path` set to `public, pg_catalog`, which succeeds.

`0.3.2.1` does not change this; it is a `-Wall` cleanup and `0010.sql` is byte-identical.

## Suggested fix

Either pin the search path at the top of `0010.sql` the way `0001` does:

```sql
SET search_path TO kiroku, pg_catalog;
```

or, to keep the file `search_path`-free, resolve the name explicitly — for example by selecting
`pg_catalog.uuidv7` when it exists and `kiroku.uuidv7` otherwise inside a `DO` block that issues
the `CREATE TABLE`. The first is smaller; the second preserves the property that every migration
after `0001` names its objects without relying on session state, which is worth keeping because
this defect is precisely what the loss of that property costs.

Whichever is chosen, the same audit is worth running across the component: `0010` is unlikely to
be the only file that inherited `0001`'s `search_path` by accident, and a fresh-install-only test
suite cannot tell the difference.
