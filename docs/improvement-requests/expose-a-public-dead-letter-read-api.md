---
type: Improvement Request
title: Expose a public dead-letter read API
description: >-
  Promote the existing internal dead-letter read statement to a public, paginated Store-effect
  operation and serve it over HTTP in kiroku-metrics, so an operator can browse a subscription's
  dead letters — with the failure reason JSON intact — without querying kiroku-owned tables.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-08-19T00:00:00Z"
requestId: IR-9
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose a Public Dead-Letter Read API

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`).
Dead letters recorded by kiroku subscriptions are kiroku-owned state, so their read API belongs
here per `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`. Implementation is kiroku's own
downstream work under kiroku's plans.

## Context

When a subscription handler exhausts its retries, kiroku parks the event in the
`kiroku.dead_letters` table with the failure reason recorded as JSON (column reference in
`docs/user/schema.md`). For an operator, the dead-letter list is the single most important
"something is wrong" screen a UI can show: what failed, for which subscription, why, and when.

Today that state is almost — but not quite — readable. `Kiroku.Store.SQL` already contains
`readDeadLettersStmt` and the `DeadLetterRecord` row type (around lines 1303–1357 of
`kiroku-store/src/Kiroku/Store/SQL.hs`), but they are exercised only by tests: no `Store` effect
operation exposes them (the only effect-level touch of dead letters is the internal cleanup
statement `deleteDeadLettersForOrphanedEventsStmt`), and no `kiroku-metrics` route serves them.
An operator's only options are raw SQL against a kiroku-private table — exactly what
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-6`'s ownership discipline exists to prevent — or
nothing.

Wire-format details follow the cross-project inspection conventions
(`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level URI
pending): cursor pagination, snake_case new fields, structured error envelope.

## Requested Change

1. A public, read-only `Store`-effect operation that lists dead letters for a subscription,
   paginated, in a deterministic order, returning for each dead letter at least: the
   subscription name, the dead-lettered event's identifying fields, the failure reason with its
   JSON structure intact (not flattened to a display string), the retry/attempt information the
   table records, and the timestamp. Mock interpreters must be able to implement it without a
   database; consumers must not need Hasql or the table name.
2. A paginated JSON endpoint in `kiroku-metrics` wrapping that operation — for example
   `GET /subscriptions/<name>/dead-letters` (the exact route is kiroku's to finalize) — with
   `from`/`limit` cursor pagination and the structured error envelope for failures.
3. The reason JSON is served as JSON, so a UI can render structured failure details rather than
   re-parsing a stringified blob.

## Boundaries

This request is read-only. It does not ask for dead-letter deletion, redrive/requeue, retry
policy changes, or any mutation — those need separate safety semantics (and per the initiative's
layer matrix, job-level redrive policy belongs to the layers above the store). It does not ask
for cross-subscription aggregation or counts beyond what a paginated list naturally provides.

## Acceptance

1. For a subscription with parked dead letters, `GET /subscriptions/<name>/dead-letters?limit=50`
   (or the finalized route) returns HTTP 200 with a JSON page of dead-letter entries, each
   carrying the failure reason as structured JSON, and a `next_cursor` when more exist.
2. For a subscription with none, the same request returns HTTP 200 with an empty `items` list —
   not an error.
3. Entries appear in a documented, deterministic order, and paging with the returned cursor
   never skips or repeats an entry while the underlying set is unchanged.
4. The new library operation is available through the public `Store` effect and implementable by
   a mock interpreter without a database.
5. Existing endpoints, frames, and the dead-letter write/cleanup paths are unchanged.

## Requested Deliverables

The public `kiroku-store` read operation with Haddock and tests; the `kiroku-metrics` route with
tests and a documented request/response transcript in `docs/user/metrics.md`; changelog entries
and PVP-appropriate version bumps, at kiroku's discretion.
