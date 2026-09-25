---
type: Architecture Decision Record
title: Category reads use a denormalized category index on $all rows
description: "Copy each source stream's category onto its $all junction rows and serve plain and consumer-group category reads as one range scan of a (category, global position) partial index, so a read's cost follows the rows it returns rather than the category's stream count or the rest of $all."
generated:
  by: anthropic/claude-opus-5-5
  at: "2026-09-25T18:00:00Z"
docId: ADR-10
status: Accepted
date: 2026-09-25
timestamp: "2026-09-25T18:00:00Z"
originatingPlan: docs/plans/91-evaluate-and-fix-partitioned-category-reads-that-scan-every-stream-in-the-category.md
---

# ADR-0010: Category reads use a denormalized category index on $all rows

- **Related:** [ExecPlan 91](../plans/91-evaluate-and-fix-partitioned-category-reads-that-scan-every-stream-in-the-category.md);
  [BUG-2](../bug-reports/partitioned-category-read-scans-every-stream-in-the-category.md);
  [ExecPlan 10](../plans/10-large-store-read-path-and-index-performance-audit.md);
  [ADR-2](0002-static-hash-partitioned-consumer-groups.md);
  [ADR-5](0005-three-tier-performance-regression-gates.md);
  [Schema reference](../user/schema.md);
  [Schema migrations](../user/schema-migrations.md).

## Context

A category is the prefix of a stream name before its first `-`, stored as the generated column
`streams.category`. A category read returns the events of every stream in one category in `$all`
global-position order, after a cursor, up to a limit. `readCategory`, category subscriptions, and
consumer-group category members all run one of two statements: `readCategoryForwardSQL` and its
consumer-group variant, which adds a hash predicate on the source stream's surrogate id (ADR-2).

Plan 10 (May 2026) measured two shapes for these reads. A position-driven join, which scans `$all`
forward from the cursor and keeps rows whose source stream has the category, took 9.88 ms against
0.116 ms for the alternative when the category had nothing after the cursor, because it read every
later `$all` row of every other category. Plan 10 therefore chose a LATERAL join: take every stream
of the category through `ix_streams_category`, probe `ix_stream_events_all_by_origin` once per
stream, merge, sort, and limit. That decision lived only in plan 10's Decision Log.

The LATERAL shape costs one index descent per stream in the category on every call, whether or not
any stream has new events, because the outer `ORDER BY ... LIMIT` must see every stream's first
candidate. BUG-2, reported from `mori://tan/notification-hub`, showed the result in a service with
one stream per entity: the consumer-group category statement took 80% of PostgreSQL statement time,
about 13,000 buffer pages per poll at 10,000 streams, while returning about one event. Plan 91
reproduced it on PostgreSQL 18: a caught-up poll of a 20,000-stream category read 60,384 buffers for
the plain statement and 29,958 for a member of a size-2 group, and the plain statement had the
identical defect.

So neither available shape bounded a read by what it returned. LATERAL grew with the category's
stream count; the position-driven join grew with the `$all` rows after the cursor, which is
unbounded for a quiet category in a busy store and for rebuilding a small category's projection on
a large store.

## Decision

Kiroku stores each source stream's category on its `$all` junction rows and serves both category
statements from an index on `(category, global position)`.

- Migration `0012` adds `kiroku.stream_events.category TEXT`, populated on `$all` rows
  (`stream_id = 0`) only. Source-stream rows and link rows leave it `NULL`; nothing reads them by
  category.
- The four append statements take the value from `RETURNING category` on the stream row they
  create or update, so it is always byte-identical to the generated `streams.category`; no second
  copy of the `split_part` rule exists.
- `ck_stream_events_all_category CHECK (stream_id <> 0 OR category IS NOT NULL)` makes any writer
  that omits the column fail with SQLSTATE `23514` instead of writing an `$all` row that category
  reads cannot see.
- `ix_stream_events_all_by_category ON stream_events (category, stream_version)
  INCLUDE (original_stream_id) WHERE stream_id = 0` serves both reads. Each is one range scan from
  `(category, cursor)` that stops at the limit. The consumer-group hash applies to
  `se.original_stream_id`, an included column, so a member skips other members' rows on index
  tuples and adds no join, as ADR-2 requires.
- The migration backfills existing `$all` rows inside its own transaction, suspending the
  `no_update_stream_events` immutability trigger for that one statement.

## Consequences

- A category read's cost follows the rows it returns. The 20,000-stream caught-up poll reads 6
  buffers (3 for the group member), a 100-event page about 400, and plan 10's exhausted-category
  case got faster too (0.43x of LATERAL in the same process). The `category-read` workload gate
  and the `category read cost` structural tests, including a 32-buffer budget on a 20,000-stream
  category, protect this under ADR-5.
- Every append writes one more column and one more partial-index entry per event. The
  `append-category-column` gate measured 1.00x to 1.04x against the pre-`0012` append, within its
  1.05 bound, on a loaded host.
- The index adds storage roughly one-third larger than `ix_stream_events_all_by_origin`, because
  it carries a text key and an included bigint.
- `0012` rewrites every `$all` row and builds the index in one transaction that blocks appends, so
  large stores apply it in a maintenance window and vacuum afterwards. kiroku-store 0.9.0.0 cannot
  append to a schema without it (SQLSTATE `42703`).
- Code that inserts junction rows directly, including benchmark fixtures and out-of-repository
  tools such as `kiroku-bench`, must set `category` on `$all` rows.
- `ix_stream_events_all_by_origin` no longer serves category reads; it remains for hard deletes,
  which find a stream's `$all` rows by source stream.
- A stream's category cannot change after its first event without also rewriting its `$all` rows.
  Stream names are immutable today, so this is a constraint on future features, not a present
  cost.

## Alternatives Considered

- **Keep the LATERAL join.** Cheap for small categories and for plan 10's exhausted-category
  regime, but its cost is proportional to the category's stream count on every poll, which is the
  defect.
- **Position-driven join from the cursor (BUG-2's suggestion).** Cost proportional to the `$all`
  rows after the cursor until enough matches accumulate. Plan 10 measured the regression (9.88 ms
  against 0.116 ms); it trades one unbounded cost for another.
- **Worker-side gap skipping.** Keep a per-subscription hint of where the category's next event
  is and jump the cursor. It fixes only subscriptions, not `readCategory`, and adds state that
  must stay consistent with appends.
- **Adaptive hybrid.** Pick LATERAL or the position-driven join per call from statistics. Two
  statements to maintain, planner-like logic in the library, and still an unbounded cost whenever
  the estimate is wrong.
- **Index on an expression of `streams.category` through a join.** PostgreSQL cannot index across
  tables, so the category has to live on the junction row for one index to order a category's
  events by global position.
