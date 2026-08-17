You are upgrading a project that consumes **Kiroku** — a PostgreSQL append-only
event store for Haskell — across one released version edge.

Kiroku ships several packages that version independently. This blueprint's
version space is **`kiroku-store`**, the core library, because that is the
version a consuming project is most likely to know it is on. An edge labelled
`0.7.0.1 -> 0.8.0.0` therefore covers every Kiroku package released in that
window, including `kiroku-store-migrations`, whose own version number moves on a
different schedule. Each edge states which packages it actually touches.

## What this project may be

Kiroku is consumed two ways, and a project may do either, both, or neither:

- **As a library.** The project names `kiroku-store` in `build-depends` and
  calls the `Store` effect, `StoreError`, subscriptions, or retention leases
  directly.
- **Through a downstream framework.** The project depends on Keiro, Kioku, or a
  Shibuya adapter and never names Kiroku itself, but still runs Kiroku's
  migrations as part of a composed migration plan and still receives Kiroku's
  error types through the framework's API.

Most projects that reach a Kiroku edge reach it the second way, through another
library's blueprint declaring that its edge entails this one. Establish which
case you are in before you change anything — the answer decides which half of an
edge applies, and an edge whose every half is inapplicable is a normal result to
report, not a failure.

## Two kinds of work

Kiroku edges carry two distinct kinds of instruction, and you must keep them
apart:

1. **Source changes.** Haskell edits in this repository. Make them, then prove
   them with the project's own build and test commands.
2. **Database state.** Kiroku owns SQL migrations, and some edges change how an
   already-migrated database must be brought forward. **You do not migrate a
   database that holds real data.** Your job for that half is to establish, from
   read-only evidence, whether this project has such a database and whether it
   is affected — then report precisely what its operator must run, and stop.
   Applying it is an operator decision made against a backup and a rehearsal on
   a restored clone.

A local, disposable, unshared development database is the exception: if the
project's own tooling recreates it from scratch, say so and let the ordinary
migration path handle it.

Never invent a schema change. Kiroku's migrations are owned by
`kiroku-store-migrations` and applied by its runner (or by a downstream
framework's runner, which composes Kiroku's plan ahead of its own). If an edge's
database half needs a fix, that fix ships in the Kiroku package — locate it and
name its path; do not hand-write equivalent SQL.

## Ground rules

- **Read before you edit.** Kiroku's API surface is large, and this project uses
  a small part of it. Find the real call sites before assuming a symbol is used
  at all.
- **A compiler warning is not a search.** Several changes in this cohort add a
  constructor to an exported sum type. A non-exhaustive `case` is a *warning*
  unless the project builds with `-Werror`, so grep for the type's constructors
  rather than trusting a clean build.
- **Do not widen the change.** Fix what this edge names. Unrelated deprecation
  warnings, formatting, and version bumps of other libraries are out of scope.
- **Report what you could not verify.** If the project's test suite needs a
  database you do not have, say which commands you did not run rather than
  claiming a pass.
