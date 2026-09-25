---
type: Bug Report
title: Partitioned category reads visit every stream in the category on every poll
description: >-
  readCategoryForwardConsumerGroupSQL starts from every stream of the category and probes
  stream_events for each, so a poll that returns one event, or none, costs work proportional to the
  number of streams ever written in the category. In a consumer with one stream per entity it becomes
  most of the database's time and keeps growing with every entity created.
generated:
  by: anthropic/claude-opus-5-5
  at: "2026-09-25T15:10:00Z"
bugId: BUG-2
status: reported
severity: degraded
origin: mori://tan/notification-hub
affects: mori://shinzui/kiroku/packages/kiroku-store
capability: mori://shinzui/kiroku/okf/capabilities/concepts/CAP-13
affectedVersion: "0.8.0.0"
environment: >-
  kiroku-store 0.8.0.0 (the statement is unchanged through 0.8.0.2 and master at 0a15b00),
  PostgreSQL 17.11 on a GCE n2-standard-4 with a pd-ssd data disk, fsync and synchronous_commit on.
  Consumer: Notification Hub, one Kiroku stream per notification, several partitioned category
  subscriptions (group size 1 and 2).
observed: >-
  Per-case pg_stat_statements from Notification Hub's measurement lane attribute 80% of PostgreSQL
  statement time in a paced delivery run, 77 to 94% in broadcast runs, and 17 to 30% in
  transactional-only runs to this one statement. Buffer pages per call track the number of streams in
  the category, not the number of new events: about 870 per call with 500 streams, 2,700 to 3,900 with
  2,000 to 3,000, and 13,000 with 10,000, while each call returns about one row. In one run with
  10,000 streams it made 48,714 calls and used 777 s of 840 s of statement time.
expected: >-
  A caught-up subscription's poll costs roughly the same whether the category holds a thousand
  streams or ten million, and a poll's cost grows with the events it returns, as the unpartitioned
  $all read does by scanning forward from the checkpoint position.
reproduction:
  - Create N streams in one category (for example `notification-<id>`) with one event each, for N = 1,000 and N = 10,000.
  - Start a partitioned consumer group (size 1 is enough) on that category and let it catch up.
  - With pg_stat_statements enabled and reset, leave the subscription idle or append one event per second for 60 s.
  - Compare shared_blks_hit plus shared_blks_read per call of the consumer-group category read between the two N; it grows roughly linearly with N.
workaround: >-
  None inside Kiroku's API short of avoiding partitioned category subscriptions on large categories.
  A consumer can subscribe to $all through the consumer-group $all read and filter by category in the
  handler, trading wasted rows for a position-driven scan.
---

# Partitioned category reads visit every stream in the category on every poll

`readCategoryForwardConsumerGroupSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs` is shaped as:

```sql
FROM streams s
JOIN LATERAL (
  SELECT se.* FROM stream_events se
  WHERE se.stream_id = 0 AND se.original_stream_id = s.stream_id AND se.stream_version > $1
  ORDER BY se.stream_version ASC LIMIT $5
) se ON true
JOIN events e ON e.event_id = se.event_id
WHERE s.category = $2
  AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3
ORDER BY se.stream_version ASC
LIMIT $5
```

The driving relation is every stream of the category. The partition predicate halves or quarters that
set, but it is still evaluated per stream, and each surviving stream costs an index probe into
`stream_events` even when it has nothing past the checkpoint. The outer `ORDER BY … LIMIT` cannot stop
early, because the planner must see every stream's first candidate before it knows the smallest
positions. So the statement's cost is proportional to the category's stream count on every poll, and a
consumer that polls a few times a second while mostly caught up pays that cost continuously.

The comment above the statement says the predicate is applied "so whole unassigned streams are pruned
before the lateral join". That pruning holds, but it only divides the work by the group size; it does
not bound it.

## Why it matters

For an event-sourced service with one stream per entity, categories grow without bound. Notification
Hub creates one stream per notification, so after ten thousand notifications a single idle poll reads
about 13,000 buffer pages, and the figure keeps rising with every email ever sent. On its measurement
lane this read is what made paced delivery cost about 38 ms of PostgreSQL CPU per send against 16 ms
for a transactional send, what slowed transactional delivery by half while marketing mail was queued,
and part of what capped broadcast fan-out. See `mori://tan/notification-hub` at
`docs/validation/throughput.md` (rows dated 2026-09-25, run `nhb-77b-2026-09-25a`) and its
MasterPlan 14 Surprises & Discoveries; the per-case statement dumps are in `mori://tan/load-testing-infra`
at `experiments/nhb-77b-2026-09-25a/pg-statements-summary.md` (artifact-level URIs pending).

## Suggested fix

Drive the read from the global position instead of from the category's streams, as the consumer-group
`$all` read already does: scan `stream_events` for `stream_id = 0 AND stream_version > $1` in position
order, join `streams` to keep rows whose `category = $2` and whose partition matches, and stop at the
limit. The cost then follows the events after the checkpoint (including other categories' events,
which a category index or a denormalized category column on the `$all` junction row would remove),
not the size of the category.

A regression guard that appends to one stream in a category of 100,000 idle streams and asserts that a
caught-up poll stays within a fixed buffer budget would keep the property from regressing.
