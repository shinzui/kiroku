---
type: Improvement Request
title: Expose a REST read API for browsing streams, categories, and events
description: >-
  Add paginated JSON endpoints to kiroku-metrics for listing and searching streams, enumerating
  categories, reading a stream's events, paging the $all log from a global position, and fetching
  a single event by id — plus the kiroku-store read primitives beneath them — so a browser UI can
  browse the store instead of only tailing it.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-08-19T00:00:00Z"
requestId: IR-8
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose a REST Read API for Browsing Streams, Categories, and Events

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). The
initiative is preparing a React web UI for operating applications built on the keiro runtime
stack; per `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`, every endpoint lives in the project
that owns the concept, and store browsing belongs to kiroku. Implementation is kiroku's own
downstream work under kiroku's plans.

## Context

`kiroku-metrics` serves metrics snapshots, Prometheus text, health probes, the in-process
subscription registry, and a live replayable WebSocket event tail. What it cannot do is answer a
browsing question: which streams exist, what categories they fall into, what events a given
stream holds, what sits at a given position of `$all`, or what a specific event id contains. The
paginated pull API was explicitly deferred when the package was created
(`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`, out-of-scope list),
and nothing has filled the gap since.

Part of the gap is below HTTP. `Kiroku.Store.Read` already exposes `readStreamForward`,
`readStreamBackward`, `readAllForward`, `readAllBackward`, `readCategory`, `getStream`,
`visibleGlobalHeadPosition`, and the batch name resolver `lookupStreamNames` — but there is no
`listStreams` (page/search over `kiroku.streams`), no category enumeration (the generated
`streams.category` column and its index exist, yet nothing surfaces distinct categories), and no
fetch-event-by-id (`eventExistsInStream` checks existence only). Since kiroku's own discipline
requires endpoints to wrap supported library APIs rather than run ad-hoc SQL, those primitives
are part of this request.

Two constraints from existing decisions shape any implementation:

- `mori://shinzui/kiroku/okf/adrs/concepts/ADR-1`: recorded events fetched across streams carry a
  surrogate `originalStreamId`, not a stream name; browsing responses for fan-in reads (`$all`
  pages, category pages) must resolve names server-side via `lookupStreamNames` (or the endpoint
  documentation must state explicitly that clients receive surrogate ids and how to resolve
  them — resolving server-side is strongly preferred for a browser client).
- Bounded fan-in replay windows are already requested by
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1` and are not restated here; this
  request is about interactive browsing, not replay-completeness semantics.

Wire-format details follow the cross-project inspection conventions defined by the initiative:
`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md` (artifact-level URI
pending). The relevant rules: cursor pagination (`from` exclusive + `limit` in, `items` +
`next_cursor` out, `next_cursor` omitted on the last page, cursors opaque to clients), snake_case
for all new fields, and the structured error envelope
`{"error":{"code":...,"message":...,"details":...}}` for new endpoints.

## Requested Change

1. New `kiroku-store` read primitives, exposed through the mockable `Store` effect (consumers
   must not need Hasql or raw SQL):
   a. list/search streams — a paginated read over `kiroku.streams` with an optional name-prefix
      filter, returning per stream at least its name, current version, category, `created_at`,
      `deleted_at`, and `truncate_before`;
   b. enumerate categories — the distinct non-null values of `streams.category`;
   c. fetch one event by id — the full recorded event (payload, metadata, envelope fields) for a
      given event id, or a typed not-found result.
2. New paginated JSON endpoints in `kiroku-metrics` wrapping those primitives and the existing
   read operations:
   a. `GET /streams` — list/search streams (query parameters for prefix filter, `from` cursor,
      `limit`);
   b. `GET /streams/<name>/events` — one stream's events, forward or backward, from a cursor;
   c. `GET /categories` — the category list;
   d. `GET /categories/<name>/events` — a category page (fan-in; names resolved per ADR-1);
   e. `GET /events?from=<global_position>&limit=<n>` — a page of the `$all` log from an
      exclusive global position (fan-in; names resolved per ADR-1);
   f. `GET /events/<event_id>` — one event by id.
3. Pagination, field casing, and the error envelope per the conventions cited above; all new
   fields snake_case; existing endpoints and frames unchanged.
4. The endpoints remain read-only and are served by the existing sister package — no web
   dependency is added to `kiroku-store`
   (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4` records the packaging rule the stack
   already follows).

Exact route names, query-parameter spellings, and response field inventories are kiroku's to
finalize; the acceptance criteria below pin behavior, not spellings.

## Boundaries

This request is read-only browsing. It does not ask for stream lifecycle mutations, event
appends, deletion, subscription control, dead-letter reads
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-9`), durable checkpoint serving
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-10`), bounded replay windows
(IR-1), authentication, or CORS
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-11`). It does not ask to change any
existing `Kiroku.Store.Read` signature.

## Acceptance

1. `GET /streams?prefix=order-&limit=50` returns HTTP 200 with a JSON page of stream summaries —
   each including at least the stream name, current version, category, and `created_at`, plus
   `deleted_at`/`truncate_before` where set — and a `next_cursor` when more pages exist; passing
   that cursor back as `from` returns the next page; the final page omits `next_cursor`.
2. `GET /streams/<name>/events?limit=100` returns the stream's events in stream order using the
   published recorded-event JSON shape, and supports reading backward from the head.
3. `GET /categories` returns the distinct categories present in the store.
4. `GET /events?from=4200&limit=100` returns `$all` entries strictly after global position 4200,
   and every item exposes its resolved original stream name (not only the surrogate
   `originalStreamId`).
5. `GET /events/<event_id>` returns the event when it exists and the structured error envelope
   with HTTP 404 and a stable machine-readable `code` when it does not.
6. The new library primitives are available through the public `Store` effect and implementable
   by test/mock interpreters without a database.
7. All pre-existing kiroku-metrics endpoints and WebSocket frames are byte-for-byte unchanged
   for existing clients.

## Requested Deliverables

The new `kiroku-store` operations with Haddock and tests; the new `kiroku-metrics` routes with
tests and `docs/user/metrics.md` documentation (including one copyable request/response
transcript per endpoint); changelog entries and PVP-appropriate version bumps, at kiroku's
discretion.
