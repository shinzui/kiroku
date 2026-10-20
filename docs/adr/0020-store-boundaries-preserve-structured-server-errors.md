---
type: Architecture Decision Record
title: Store boundaries preserve structured server errors
description: Preserve PostgreSQL SQLSTATE and server messages through script, statement and pool boundaries while leaving retry and HTTP policy to callers.
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-20T00:24:00Z"
docId: ADR-20
status: Accepted
date: 2026-10-20
timestamp: "2026-10-20T00:26:15Z"
originatingPlan: docs/plans/98-preserve-structured-script-session-errors.md
---

# ADR-0020: Store boundaries preserve structured server errors

## Context

A PostgreSQL SQLSTATE is a five-character machine-readable failure code.
Hasql wraps server errors differently for SQL scripts and prepared statements.
Rendering an unrecognized script wrapper as `ConnectionError` erased SQLSTATE
and made permanent missing-table failures appear retryable to applications.
The shared pool helper also flattened typed read failures.

## Decision

Extract server errors from both script and statement session wrappers at every
store boundary. Preserve the original SQLSTATE and message. Exactly `40001`
(serialization failure) and `40P01` (deadlock) yield
`TransientTransactionFailure`; other generic server failures yield
`UnexpectedServerError`. Connection establishment and connection-session loss
yield `ConnectionLost`, while acquisition timeout yields `PoolAcquisitionTimeout`.
Unsupported non-server driver errors retain the legacy `ConnectionError` fallback;
do not fabricate SQLSTATE from diagnostic prose.

Keep contextual mapping separate from extraction. Append and link operations can
attribute owned constraints to streams as described in
[ADR-14](0014-unique-constraint-names-define-error-classification.md).
Opaque transactions recognize event-ID duplicates but do not invent a stream
identity for foreign-key or unknown uniqueness failures.

Classification adds no SQL, acquisition, schema work or retry policy. The
transaction runner's existing retry behavior remains in force; callers needing
one attempt use the no-retry runner. Applications choose their retry policy from
typed results. The HTTP sister package sanitizes unavailable failures as 503 and
permanent server failures as 500, retaining existing response envelopes and
route-specific codes under
[ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md).
Never expose server diagnostics, parameters or connection strings through that mapper.

## Consequences

Real PostgreSQL public-operation tests must protect script/statement parity,
rollback, read classification and connection refusal. Constructor-level mapper
tests supplement that evidence. Consumers matching only `ConnectionError` must
handle more specific existing constructors. Parsing rendered diagnostics was
rejected because it loses driver structure and depends on human-readable prose.
