---
type: Improvement Request
title: Expose a stream's head global position from getStream
description: >-
  Let a consumer capture stream metadata and the newest visible originated event's global
  position in one opt-in public read, so read-your-writes waits on origin-only streams can use
  a per-stream target while existing getStream, event reads, and writes retain their cost.
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-10-06T23:32:09Z"
timestamp: "2026-10-10T16:10:46Z"
requestId: IR-18
status: proposed
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-10-10T16:10:46Z"
    document_timestamp: "2026-10-10T16:10:46Z"
    scope: authoring-metadata
    outcome: comments
    provider: openai
    model: gpt-6.1-sol
    context: >-
      Checked the required title, description, request identity, lifecycle, origin and
      timestamp metadata against the bundle profile. This is an authoring-metadata
      review only; source claims, implementation acceptance and release evidence were
      not reviewed here.
---

# Improvement Request: Expose a Stream's Head Global Position from getStream

## Status

Proposed by the notification render service
(`mori://tan/notification-render-service`), whose admin API implements the platform's
read-your-writes contract in
`mori://tan/notification-render-service/plans/16-give-the-admin-api-one-command-answer-and-a-read-your-writes-position-floor`.
That plan is complete; it works today with a category-wide proxy that this request would let it
replace with an exact per-stream target. Nothing is blocked. The request is non-urgent and
additive in intent.

The request was merged in PR #1 on 2026-10-09. It remains `proposed`: the performance evaluation
below recommends an opt-in combined metadata/head operation; implementation and release are
still pending.

## Context

A platform convention (registration-service-v2, admin-graphql-server, admin-web, and now the
notification render service) hands clients the **per-stream version** of a change: a mutation
answers `visibleAsOf = N`, every view carries `version`, and a read with `?minPosition=N` must
not answer a view older than event `N` of that entity's stream. The number is a stream version
because the same number serves optimistic concurrency (`expectedVersion` on a later command), so
clients track one integer per entity.

Keiro's read-model freshness protocol
(`mori://shinzui/keiro-runtime-patterns/docs/keiro-read-models-and-projections`) waits on a
projection's durable cursor, and that cursor is kept in **global positions**. To honour a
stream-version floor the service must therefore answer one question before it waits: *what is the
global position of event `N` of stream `S`*, or at least of some event at or after it?

Kiroku's public API cannot answer it today:

- `Kiroku.Store.Read.getStream` returns `StreamInfo` with `version` (the count of appended events)
  but no global position. Its statement reads the `streams` row only
  (`getStreamSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs`).
- `readStreamForward` and `readStreamBackward` return `RecordedEvent.globalPosition = 0` for every
  event: their SQL selects `0::bigint AS global_position` with the comment "not available
  without `$all` join".
- `visibleGlobalHeadPosition` (IR-4, `kiroku-store` 0.6.0.0) answers the store-wide visible head,
  and Keiro's `categoryHeadPosition` answers a category's; neither is scoped to one stream.

The service's current workaround, recorded as a documented proxy in its pattern register
(`mori://tan/notification-render-service/docs/KEIRO-PATTERNS.md`): after `getStream` shows
`version >= N` (so event `N` is committed), capture the **category's** visible head with Keiro's
`categoryHeadPosition` and wait for the projection cursor to reach it. That head is at or past
event `N`, so the wait is correct, but it also covers every other stream's events appended before
the capture. The over-wait is harmless when the projection is caught up and only lengthens a wait
that is already lagging; it is still a looser target than the one the caller means, and it costs a
second round trip after `getStream`.

The storage fact needed is already indexed. Each event has exactly one `$all` link row in
`stream_events` with `stream_id = 0`, whose `stream_version` is the global position and whose
`original_stream_id` names the source stream. The index
`ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE stream_id = 0`
(migration `0001-kiroku-bootstrap.sql`) makes "the newest `$all` link of stream `S`" a single
index probe.

## Requested Change

Add an opt-in sibling read that returns stream metadata and the global position of the stream's
newest visible **originated** event together, with these semantics:

1. The value is the greatest `$all` `stream_version` among the visible link rows whose
   `original_stream_id` is the stream's, or absent when the stream has no visible `$all` entry
   (a stream with no events; a hard-deleted stream is already absent from `getStream`).
2. It is a position, not an event: no event data or metadata is fetched and the store's decode
   hook is not invoked.
3. Visibility matches Kiroku's global reads and IR-4's `visibleGlobalHeadPosition`: soft deletion
   and logical truncation (`truncateBefore`) do not hide events from `$all`; hard deletion removes
   them and may make the value regress or disappear.
4. Metadata and head come from one SQL statement and its MVCC snapshot. For an origin-only
   stream with retained history, a caller that reads `version >= N` and the head together knows
   the head is at or past event `N`. This observation does not freeze later state: a concurrent
   append may raise both immediately afterwards. Two statements in an ordinary READ COMMITTED
   transaction do not provide the same shared snapshot.
5. It is exposed through the mockable `Store` effect and `Kiroku.Store.Read`; consumers need not
   import `Kiroku.Store.SQL` or Hasql.

The preferred shape keeps the existing `StreamInfo` record and `getStream` statement intact:

```haskell
-- Illustrative name/result shape; the final public type belongs to Kiroku.
getStreamWithHead ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe (StreamInfo, Maybe GlobalPosition))
```

The outer `Nothing` means the stream is absent; the inner `Nothing` means the stream exists but
has no surviving originated `$all` row. One statement provides both the version check and wait
target, removing the category proxy and its additional round trip. Only callers that need the
head pay for the indexed probe. Adding a `Store` constructor still requires custom exhaustive
interpreters to handle it; retaining `StreamInfo` avoids changing that record's constructors.

The original alternatives remain possible but are less suitable under the performance
constraint. Adding `headGlobalPosition` directly to `StreamInfo` and filling it in ordinary
`getStream` charges every caller for the measured extra read work and changes an exported record.
A head-only sibling preserves the existing paths but requires a separate metadata observation;
it does not by itself deliver the requested version/head pair in one statement.

An exact lookup, "the global position of event `N` of stream `S`"
(`StreamName -> StreamVersion -> Eff es (Maybe GlobalPosition)`), would answer the question
literally. It is not requested here: for a wait target the head is as good as the exact event (the
cursor reaching the head implies it reached event `N`), the head needs no second probe to tell
"no stream" from "version beyond the stream", and the head is the fact the existing index serves
best. Populating `RecordedEvent.globalPosition` on stream reads is also not requested: it would
put the `$all` join on every stream read, including every command hydration.

## Performance Evaluation (2026-10-09)

The evaluation used the current SQL at commit `36b7551`, PostgreSQL 18.6 on aarch64 macOS, and a
fresh isolated database with every migration through `0012`. The fixture contained 1,000 streams
with 100 originated events each, plus one stream with 100,000 events: 200,000 events and 400,000
home/`$all` junction rows. Global positions were interleaved across the 1,000 smaller streams.

The candidate adds this scalar subquery to the stream metadata lookup:

```sql
SELECT se.stream_version
FROM stream_events AS se
WHERE se.stream_id = 0
  AND se.original_stream_id = s.stream_id
ORDER BY se.stream_version DESC
LIMIT 1
```

With natural planner settings, EXPLAIN ANALYZE used a backward index-only scan of
`ix_stream_events_all_by_origin` below a `Limit`, with no `Sort` and one returned row. The full
metadata/head lookup touched seven shared buffer blocks for both the 100-event and 100,000-event
streams. The probe made one heap fetch before vacuum and zero after vacuum. An existing empty
stream returned metadata with a null head; a missing stream returned no row and did not execute
the head subplan.

Three two-second `pgbench` prepared-query trials per shape and stream alternated candidate/control
order on the same PostgreSQL server. Session search_path was established through `PGOPTIONS`,
outside the measured transaction. After vacuum, medians were:

| Stream size | Existing `getStream` | Metadata plus head | Increase | Version plus head only |
| --- | ---: | ---: | ---: | ---: |
| 100 events | 15 microseconds | 20 microseconds | approximately 33% | 18 microseconds |
| 100,000 events | 15 microseconds | 18 microseconds | approximately 20% | 17 microseconds |

These are short, warm-cache SQL measurements, including client round trips but excluding Hasql
and Haskell decoding. `pgbench` printed millisecond latencies to three decimal places. The ratios
establish measurable added read cost on this fixture; they are not production latency promises
or a completed application-level regression gate.

The extra work is **read work**. Both original API alternatives can use the existing origin index
without changing append/link SQL, maintaining another index, storing another column, or adding
triggers. Migration `0012` added the separate category index and retained the origin index, which
has existed since `0001`; the recent schema change is not what makes this lookup possible. No
additional migration or write amplification is needed. Extra lookup traffic still consumes
shared database resources, so this is a claim about unchanged write-path work, not a promise
that arbitrary added read load can never affect concurrent write latency.

The earlier documented rejection was [ExecPlan 36](../plans/36-add-originalstreamname-to-recordedevent.md)
and [ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md): returning a
stream-name text field on every event cost roughly 12-13% on `$all` reads, even after
denormalization. That experiment charged each event row for transfer/decoding. No prior benchmark
rejecting this precise stream-head API was found in repository history. The original stream-read
decision to return zero global position is recorded in
[Milestone 3](../plans/milestone-3-read-operations.md), with the extra `$all` join as its rationale.

Recommendation: implement the combined operation only as an opt-in read. Keep ordinary
`getStream`, event reads, append/link statements, and their result decoders unchanged; verify
that isolation structurally and run the production Hasql/application performance gates before
shipping. The new operation has a small additional read cost, while existing operations acquire
no additional work from the feature.

Reproducible evidence is checked in under
[`docs/bench/stream-head/2026-10-09`](../bench/stream-head/2026-10-09/): the executable
`evaluate.py`, measured SQL in `queries.json`, all trial results in `timings.json`, EXPLAIN output
in `query-plans.json`, and raw `pgbench` output in `pgbench-transcripts.json`. The script starts
and stops its own temporary database and applies the checked-in migrations directly; it is a
SQL feasibility experiment, not a migration-ledger or public-runner test.

## Originated Events and Linked Streams

The origin-index probe does not report the newest event linked **into** a stream from another
source. `linkToStream` increases the target's `stream_version`, preserves the source event's
`original_stream_id`, and does not append another `$all` row. A link-only stream can therefore
have a positive version and no originated head; a mixed stream can have a version floor above
its last originated event. Waiting on its originated head does not prove that a linked version
has been projected, and `$all` does not record the later link mutation at all.

The read-your-writes example is consequently for origin-only streams with retained history.
Document and test that scope; callers must not apply it to linked versions as a general
stream-version-to-global-position mapping. Define the reserved `$all` input explicitly before
implementation as well: an `original_stream_id = 0` probe is not its store-wide visible head.

## Boundaries

This request does not change global-position allocation, `$all` linking, hard or soft deletion,
truncation, checkpoint advancement, or subscription delivery. It does not ask Kiroku to implement
query freshness, waits, or any read-your-writes policy; Keiro and its consumers decide what to
wait for. It does not touch `SubscriptionCheckpointInventory.storePosition`,
`visibleGlobalHeadPosition`, or Keiro's `categoryHeadPosition`, whose contracts stay as they are.

It does not promise that the captured position stays visible. If a concurrent hard delete removes
the stream's newest events after the call returns, the consumer applies its own timeout, exactly as
with IR-4's store-wide head.

## Acceptance

1. A stream with no events reports no head position; after appending events at stream versions 1
   through 3 (global positions, say, 810, 811 and 815 with other streams interleaved), the head
   position is 815 and `version` is 3, from one call.
2. Appending to another stream leaves the first stream's head position unchanged while the
   store-wide visible head moves.
3. Soft-deleting the stream or setting `truncateBefore` leaves the head position unchanged;
   hard-deleting the stream makes the combined lookup answer `Nothing`, as `getStream` does today.
4. A deliberately failing decode hook does not affect the call: no event payload passes through
   the read or decode path.
5. The production statement's EXPLAIN uses `ix_stream_events_all_by_origin` for the head probe
   with no `Sort` node and no scan of `stream_events` beyond the probe, using the existing schema
   and natural planner settings.
6. The direct and resource-backed runners and a mock `Store` interpreter expose the value with the
   same semantics. Existing `StreamInfo` construction stays unchanged; the changelog names the
   additional constructor that exhaustive custom `Store` interpreters must handle.
7. Haddocks contrast the stream head with `version` (a count, not a position), with
   `visibleGlobalHeadPosition` (store-wide), and with the append frontier, and give the
   origin-only read-your-writes example: "capture version and head together; check `version >= N`,
   then wait for the projection cursor to reach the head". Explain retained-history requirements
   and why a linked version is outside that guarantee.
8. A link-only stream with a positive version has no originated head. A mixed stream's head
   follows originated events only; linking another event does not advance it. Neither case is
   advertised as proving freshness for a linked version. Pin the reserved `$all` input behavior.
9. Structural checks preserve the ordinary metadata/event-read and append/link SQL and decoders.
   Measure the implemented opt-in operation through the actual public runner; do not treat the
   preliminary SQL numbers above as proof of end-to-end performance.

## Follow-up

When released, the notification render service replaces its category-head proxy
(`Server/Seam.hs` `categoryHead` and the `otherwise` branch of `Handler.hs` `floored`) with the
stream's own head position, with no change to its HTTP contract, and updates the two rows of its
pattern register that describe the proxy. A later request to Keiro may add a freshness mode that
takes a stream name and version directly and resolves it through this read, so consumers of the
platform convention need no handler-level translation at all.
