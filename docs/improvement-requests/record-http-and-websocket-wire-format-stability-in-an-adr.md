---
type: Improvement Request
title: Record HTTP and WebSocket wire-format stability in an ADR
description: >-
  Record in kiroku's own ADR corpus the stability contract of the kiroku-metrics HTTP and
  WebSocket wire formats and the sister-package endpoint-ownership boundary, so external clients
  can depend on published frames not changing shape silently.
generated:
  by: anthropic/claude-fable-5
  at: "2026-08-19T00:00:00Z"
timestamp: "2026-08-19T00:00:00Z"
requestId: IR-13
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Record HTTP and WebSocket Wire-Format Stability in an ADR

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/2-audit-kiroku-and-file-ui-endpoint-improvement-requests`). This
request asks for a decision record, not code. Implementation is kiroku's own downstream work.

## Context

kiroku's ADR corpus (seven records as of commit `c2d0328`) covers stream-name resolution, the
dedicated schema, checkpoint lifecycle, performance gates, versioned SQL relations, and replay
retention — but nothing covers the HTTP/WebSocket surface. The rationale for `kiroku-metrics`'s
existence and boundaries lives only in masterplan Decision Logs
(`docs/masterplans/5-metrics-and-event-streaming-http-endpoint-package.md`), and no record
states what a client may rely on: whether the JSON metric shapes, the recorded-event wire shape
(snake_case envelope, camelCase payload fields such as `eventId` and `globalPosition`), the
subscription rows, or the WebSocket frame inventory are stable, and what kind of change requires
a new path or frame rather than an in-place mutation.

For database-native surfaces kiroku already made this promise explicit:
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-6` records that published relations are frozen and
versioned. The keiro runtime UI initiative is now building a browser client directly against the
kiroku-metrics wire formats, and its own conventions
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2` for the WebSocket dialect-freezing rule;
`mori://shinzui/keiro-ui`, `docs/architecture/inspection-api-conventions.md`, artifact-level URI
pending, area 9 for wire stability) presume the owning project stands behind the same discipline
at the HTTP layer. That presumption is currently undocumented on kiroku's side — a silent
reshaping of a frame would break external clients without any recorded promise having been
violated.

## Requested Change

kiroku records, in its own `docs/adr/` bundle, a decision covering at least:

1. **Wire stability.** Which shipped kiroku-metrics wire shapes are published contracts (JSON
   endpoint bodies, the recorded-event JSON shape including its mixed casing, the WebSocket
   frame inventory), and the change discipline over them: fields are never removed or re-typed,
   additive optional fields and new frame types are allowed, and incompatible changes ship as a
   new path or new frame type — the HTTP-layer analogue of ADR-6.
2. **Endpoint ownership.** The sister-package boundary as a recorded decision: `kiroku-store`
   never gains web dependencies; the HTTP/WebSocket surface lives in `kiroku-metrics` and wraps
   supported library APIs.

The decision's content is kiroku's to word; the request is that the contract exist as a stable,
citable record (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-N`) rather than as folklore in
masterplan logs.

## Boundaries

This request asks for no code change and no new endpoint. It does not ask kiroku to adopt the
initiative's conventions document wholesale, to promise stability for surfaces it considers
experimental (a record that explicitly scopes what is and is not covered is a fully acceptable
outcome), or to backfill ADRs for other subsystems.

## Acceptance

1. A new record exists in kiroku's `docs/adr/` bundle, allocated by kiroku's own tooling,
   passing kiroku's own bundle validation, covering wire stability and endpoint ownership as
   described above (or explicitly scoping them).
2. The record is citable by canonical handle (`mori://shinzui/kiroku/okf/adrs/concepts/ADR-N`)
   and is referenced from the kiroku-metrics user documentation, so an implementer touching the
   wire formats encounters the contract.
3. External clients (the keiro runtime UI among them) can cite the record as the authority for
   what will not change out from under them.

## Requested Deliverables

The ADR itself, its index/log bookkeeping in kiroku's bundle, and a reference to it from
`docs/user/metrics.md` (or the equivalent kiroku-metrics documentation).
