---
type: Improvement Request
title: Preserve structured script session errors
description: Preserve structured PostgreSQL server errors from script-backed transactions so callers can classify permanent and retryable failures without parsing rendered diagnostics.
requestId: IR-19
status: accepted
origin: mori://shinzui/rei
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-19T20:25:45Z"
timestamp: "2026-10-20T00:14:26Z"
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

## Status and implementation plan

Accepted for planning under
[ExecPlan 98: Preserve structured script session errors](../plans/98-preserve-structured-script-session-errors.md).
The plan covers structured script and transaction error mapping, the shared
pool helper, real PostgreSQL regression tests, local HTTP classification
compatibility, and supported-release verification. Implementation has not
started; planning acceptance does not claim fulfillment or publication.

## Released baseline recheck — 2026-10-19

This remains the existing request for the Store error-classification gap; no
duplicate request is needed. Hackage still lists `kiroku-store` 0.11.0.0 as its
newest normal release, and the upstream tag inventory has no 0.11.0.1 tag.
The current owner checkout at `ad866f925ac11484a2ee758fe235035840c85c0a`
still has the rendered session-error fallback and the raw `usePool` fallback
described below. At that recheck the request remained `proposed` pending owner
fulfillment and a supported release; subsequent planning acceptance is recorded
above. An unpublished local patch is not acceptance evidence.

Creating this request does not authorize upstream implementation or publication.

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

Current source inspection finds that `mapSessionError` handles
`StatementSessionError` through the structured server-error mapping while its
catch-all renders other session errors into `ConnectionError`. The owning
project is `mori://shinzui/kiroku`, source
`kiroku-store/src/Kiroku/Store/Error.hs` (source-artifact URI pending).
Audit the raw store-SQL seam in `kiroku-store/src/Kiroku/Store/Effect.hs` too
(source-artifact URI pending); it also has a rendered UsageError fallback.

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
