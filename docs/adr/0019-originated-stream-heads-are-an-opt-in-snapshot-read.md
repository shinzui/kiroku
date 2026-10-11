---
type: Architecture Decision Record
title: Originated stream heads are an opt-in snapshot read
description: Capture metadata and an originated global head in one statement while preserving legacy metadata, event-read and write costs.
generated:
  by: openai/gpt-6-astra
  at: "2026-10-11T04:23:00Z"
docId: ADR-19
status: Accepted
date: 2026-10-11
timestamp: "2026-10-11T04:23:00Z"
originatingPlan: docs/plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md
---

# ADR-0019: Originated stream heads are an opt-in snapshot read

## Context

Consumers need a global projection target after observing a requested per-stream
version. Metadata alone has no global position. Adding it to every metadata or
event row imposes work on existing callers, contrary to
[ADR-1](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md).
[ADR-10](0010-category-reads-use-a-denormalized-category-index-on-all-rows.md)
retains the partial origin index, which supports a bounded head probe.
[Plan 97](../plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md)
implements [IR-18](../improvement-requests/expose-a-streams-head-global-position-from-getstream.md).

## Decision

`getStreamWithHead` returns `Maybe (StreamInfo, Maybe GlobalPosition)` using one
Store effect, pool checkout and SQL statement. The metadata and correlated head
therefore observe the same statement snapshot. The head is the greatest surviving
`$all` junction position whose origin id is the stream's current surrogate id.
A backward probe of `ix_stream_events_all_by_origin`, limited to one row, reads
no event payload. No schema change, stored head, trigger or write maintenance is
introduced. Ordinary metadata reads, event reads and writes gain no extra work.

Outer absence means the stream does not exist. Inner absence means no surviving
originated event. Links advance a stream version but do not contribute to its
originated head. `$all` aggregates events and always has an absent originated
head; store-wide visible head and allocation frontier remain separate concepts.
Soft deletion and logical truncation preserve the head. Physical retention can
remove it; hard deletion removes the metadata, and a recreated name has a new
origin identity.

For an origin-only stream with retained required history, consumers can require
`version >= N` and a present head, then wait for their projection cursor to reach
that head. Consumers own timeouts. The observation does not freeze appends or lock
history against later removal. Linked streams do not have this version-to-head
guarantee.

## Consequences

`StreamInfo` construction stays source-compatible. Exhaustive custom `Store`
interpreters must handle the new `GetStreamWithHead` constructor. The opt-in caller
pays an indexed probe; extra traffic can still contend for shared database resources.

Following [ADR-5](0005-three-tier-performance-regression-gates.md), frozen legacy
SQL, unchanged decoders and handler review protect existing work. Natural literal
and warmed prepared plans must use a backward origin-index probe below Limit,
without event access or sorting and within 32 execution shared buffers. A frozen
public-runner control protects legacy metadata cost with a 1.10 ratio; the new
operation's measured cost is diagnostic rather than subject to that legacy bound.

## Alternatives considered

Adding a field to every `StreamInfo` charges existing callers. A separate head-only
query or two statements in a READ COMMITTED transaction cannot promise one
observation snapshot. A stored head would add write and retention maintenance.
Treating linked events or `$all` as originated heads would conflate different
position domains. None is needed for the consumer contract.
