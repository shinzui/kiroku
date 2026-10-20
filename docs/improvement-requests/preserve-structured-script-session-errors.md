---
type: Improvement Request
title: Preserve structured script session errors
description: Preserve structured PostgreSQL server errors from script-backed transactions so callers can classify permanent and retryable failures without parsing rendered diagnostics.
requestId: IR-19
status: completed
origin: mori://shinzui/rei
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-19T20:25:45Z"
timestamp: "2026-10-20T01:41:04Z"
reviews:
  - kind: model
    reviewer: "codex (author self-review)"
    reviewed_at: "2026-10-19T20:28:51Z"
    document_timestamp: "2026-10-19T20:25:45Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Checked the statement/catch-all branches in the current source and the dated
      consuming probe. This self-review approves request accuracy, not an upstream
      implementation or publication.
---

# Preserve structured script session errors

## Completion — 2026-10-20

Completed by
[ExecPlan 98](../plans/98-preserve-structured-script-session-errors.md) and
[ADR-20](../adr/0020-store-boundaries-preserve-structured-server-errors.md).
The supported releases are
[kiroku-store 0.11.0.1](https://hackage.haskell.org/package/kiroku-store-0.11.0.1)
and [kiroku-metrics 0.3.0.1](https://hackage.haskell.org/package/kiroku-metrics-0.3.0.1),
revision 0, tagged at release commit
`084fd8359850342447cdda8e632b7dc456c7fca4`.

The [retained release record](../releases/2026-10-20-structured-script-errors/README.md)
verifies published source archives, Cabal files, Haddock pages and GitHub
releases. All 487 store and 117 metrics examples passed. A clean consumer
resolved both exact Hackage releases and proved script SQLSTATE `42P01` through
both public transaction runners, permanent HTTP 500 and typed unavailable HTTP
503 mapping, and clean disposable PostgreSQL 18.4 shutdown. The only local
package was the consumer; it used no package source override or bound exception.
Initial signed-index propagation failures are retained separately. Downstream
Rei adoption remains with its consuming plan.

## Released baseline recheck — 2026-10-19

This remains the existing request for the Store error-classification gap; no
duplicate request is needed. Hackage still lists `kiroku-store` 0.11.0.0 as its
newest normal release, and the upstream tag inventory has no 0.11.0.1 tag.
The current owner checkout at `ad866f925ac11484a2ee758fe235035840c85c0a`
still has the rendered session-error fallback and the raw `usePool` fallback
described below. At that recheck the request remained `proposed` pending owner
fulfillment and a supported release; subsequent implementation and release completion are recorded
above. An unpublished local patch is not acceptance evidence.

The initial request filing did not authorize implementation or publication.
The user subsequently authorized implementation and approved both releases
under ExecPlan 98.

Rei needs the same structured error classification for prepared statements and
script-backed store operations. The consuming work is
`mori://shinzui/rei/plans/256-expose-operational-status-and-controlled-periodic-check-apis`
under
`mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.

A disposable Rei fixture recorded a lifecycle call whose missing application
relation produced SQLSTATE `42P01` inside a `ScriptSessionError`. The store facade
rendered that failure into `ConnectionError`, and Rei answered a retryable 503
instead of a permanent 500. Fixing that fixture's missing declarations removed
the trigger, but did not restore the lost error structure. Rei records the
original probe and its date in the consuming plan; this request does not claim
a new production incident.

Baseline source inspection found that `mapSessionError` handled
`StatementSessionError` through the structured server-error mapping while its
catch-all rendered other session errors into `ConnectionError`. The owning
project is `mori://shinzui/kiroku`, source
`kiroku-store/src/Kiroku/Store/Error.hs` (source-artifact URI pending).
Audit the raw store-SQL seam in `kiroku-store/src/Kiroku/Store/Effect.hs` too
(source-artifact URI pending); it also had a rendered UsageError fallback.

## Requested behavior

Preserve SQLSTATE and existing server-error classification when a Hasql
`ScriptSessionError` carries a PostgreSQL `ServerError`. Prefer the existing
mapping used for prepared statements so callers do not need another parallel
error protocol. Real connection establishment/loss and pool acquisition errors
must remain distinguishable from permanent SQL/schema/permission failures.
Private SQL, parameters and server diagnostics can remain internal evidence;
applications must not parse their rendered prose to recover the classification.

This request does not add an HTTP endpoint, a framework-table reader or an
application-specific retry policy. Rei's new periodic admission owner already
retains structured pool/session outcomes and tests sanitized 500/503 decisions;
that does not repair older script-backed facade calls.

## Acceptance

- A real script-backed missing-relation or permission failure preserves its
  structured permanent classification and SQLSTATE through the public store
  operation.
- Script-backed serialization/deadlock errors retain their existing retryable
  classification; genuine connection failures retain their own class.
- The equivalent prepared-statement behavior remains unchanged.
- Tests cover the public transaction/raw-SQL seams involved, using the real
  store and disposable PostgreSQL. No rendered-error substring matching or
  same-context store doubles are introduced.
- Publish the supported release before consumers adopt changed dependency
  bounds; a local source override is not release/adoption evidence.
