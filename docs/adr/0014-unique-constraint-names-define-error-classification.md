---
type: Architecture Decision Record
title: Unique constraint names define error classification
description: "Classify owned unique constraints by exact names and distinguish duplicate event IDs from internal stream-version invariant failures."
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-10T01:31:04Z"
docId: ADR-14
status: Accepted
date: 2026-10-10
timestamp: "2026-10-10T01:31:04Z"
originatingPlan: docs/plans/86-make-append-unique-violation-classification-exact.md
---

# ADR-0014: Unique constraint names define error classification

## Context

SQLSTATE `23505` alone does not distinguish caller duplication from store corruption.
The name `events_pkey` is a substring of `stream_events_pkey`; substring matching
mistook a composite key for a scalar key and lost the offending event ID. Treating
the stream-version index violation as an expected-version conflict also encouraged
callers to handle an internal invariant failure as a normal precondition mismatch.

## Decision

Owned constraint names are a durable interface between migrations and error mapping.
Extract the quoted constraint from the PostgreSQL message and compare it exactly.
Only when that name is absent may a complete identifier in detail supply the name.
An unknown quoted name takes precedence over recognizable detail tokens. Scalar
and composite keys retain distinct event-ID parsers; unparseable details return
`Nothing` rather than inventing an ID. Append, opaque transaction, link and
multi-stream attribution use the same extractor on the failed-statement path.

For append, `events_pkey` and `stream_events_pkey` yield `DuplicateEvent`;
`ix_streams_stream_name` yields `StreamAlreadyExists`; and
`ux_stream_events_stream_version` yields `UnexpectedServerError "23505"` with the
original server message. Stream-version uniqueness is enforced by append serialization
and a violation warrants investigation. Unknown append unique constraints retain the
existing `WrongExpectedVersion` fallback. Link duplicates continue to return
`EventAlreadyLinked`, and opaque transactions keep their generic fallback when a
failure is not an event duplicate. Class-40 retry classification is unchanged.

No constraint is renamed, no public type is added, and no parsing or query is added
to a successful append. [ADR-11](0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
continues to govern cumulative write-performance acceptance.

## Consequences

Migrations that rename these constraints must update the mapper and its exact-name
tests in the same change. Message and detail parsing remains dependent on the server
text format; missing or unrecognized names preserve the established fallback.
Mapping tests prove the invariant-failure classification without manufacturing
database corruption. An isolated real append test proves same-stream duplicate IDs
leave the event, both stream links and stream versions unchanged.

Substring matching was rejected because branch ordering cannot resolve overlapping
constraint names safely. Broadening unknown-constraint classification was excluded
to keep this fix within the existing public error contract.
