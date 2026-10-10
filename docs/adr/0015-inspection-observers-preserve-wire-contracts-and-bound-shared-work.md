---
type: Architecture Decision Record
title: Inspection observers preserve wire contracts and bound shared work
description: "Keep inspection composition compatible, preserve typed decoding, and require bounded observer work with focused write-performance evidence."
generated:
  by: openai/gpt-6-astra
  at: "2026-10-10T15:29:20Z"
docId: ADR-15
status: Accepted
date: 2026-10-10
timestamp: "2026-10-10T15:29:20Z"
originatingPlan: docs/masterplans/13-expose-the-kiroku-inspection-surface-for-the-keiro-runtime-ui-and-a-standalone-kiroku-ui.md
---

# ADR-0015: Inspection observers preserve wire contracts and bound shared work

## Context

MasterPlan 13 adds browser reads and standalone inspection to the existing metrics server.
A read-only endpoint can still contend with appenders for PostgreSQL, pool connections,
CPU, and memory. A page limit bounds response size, not necessarily query work.
The September drafts also precede the released typed-decoding contract in
[ADR-12](0012-decode-failures-are-per-event-outcomes-with-independent-subscription-dispositions.md).

## Decision

[ADR-9](0009-published-http-and-websocket-wire-shapes-are-frozen-and-served-only-by-sister-packages.md)
continues to freeze published routes, bodies, and frames. New paths must not shadow valid
existing resource names: durable inventory uses `/subscription-checkpoints`, leaving
`/subscriptions/checkpoints` available for a live subscription named `checkpoints`.
Only new read routes enforce GET and HEAD with a bodyless HEAD response and 405 otherwise.
Existing legacy errors remain unchanged. New errors are structured and sanitized; a typed
decode failure is not a database outage and cannot produce partial successful event pages.

One providers record and one CORS-wrapped composition serve both embedded and standalone
hosts. Path-prefix mounting must work for HTTP and WebSocket dispatch; the latter receives
the raw path in wai-websockets. Capability flags describe actual dispatch, including the
WebSocket enable switch, not merely configuration intent. A starter reports readiness only
after Warp is listening and propagates bind failures with resource cleanup.

Disabled CORS is the identity application. Enabled CORS varies every ordinary HTTP response
on Origin, including nonmatching and absent origins, without granting those requests access.
Origin allowlisting is not authentication. Validation accepts explicit HTTP(S) origins only;
wildcards, opaque origins, malformed authorities, and user information are refused.

Existing append statements, indexes, locks, pool checkouts and default publisher decoding
must not gain inspection work. Keep `DecodedBatch` and its no-hook `UnchangedBatch` fast path.
The publisher drop counter is updated only on an actual drop, in the same STM transaction.
The tail samples queue and counter atomically and emits loss notification before survivor
events, so the client retains a safe recovery cursor. Name enrichment uses at most one
batched lookup per delivered batch and a bounded per-tail cache (4096 entries initially),
never one lookup per event or an ever-growing lifetime map.

Stream/category/dead-letter reads use existing indexes first. No index or migration may be
added merely to hide an expensive observer without separately reviewing append cost.
All-member dead-letter paging must limit each member's index scan before merging;
its cost depends on member count and page size, not every historical dead letter.
Prefix filtering and optional-cursor prepared plans require focused EXPLAIN evidence,
including sparse or absent matches. Unbounded checkpoint inventory remains explicitly
proportional to inventory size; hosts must avoid overlapping polls.

Follow [ADR-11](0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
for proportional evidence, not its prior cohort's acceptance verdict. Correctness tests,
structural checks and a focused original-control comparison of affected paths precede release.
The integrated comparison includes real inspection/tail load alongside appends and a disabled
baseline. PostgreSQL 18 is the performance scope; do not default to a full matrix. The default
one-hour ceiling includes setup, recovery and repeats. Record the comparison policy before
measurement; retain uncertainty and adverse samples. A consistent append regression blocks
release. An inconclusive result is not proof of neutrality, and does not authorize relaxing
the gate or silently adopting another cohort's practical acceptance.

## Consequences

These are implementation constraints, not evidence that the unimplemented inspection cohort
has passed. Children can complete focused local checks; the release child owns cumulative
performance acceptance. Broad repeated remote experiments are not required per child.
If an existing-index design cannot meet the focused gate, report that limitation and revise
the design before accepting it. API constructor changes still require PVP review even when
the wire change is additive. September version forecasts cannot reuse already released versions.

## Alternatives considered

Route shadowing, post-survivor loss notices, unbounded caches, and full-history top-N scans
were rejected because they undermine compatibility, recovery, or shared-resource protection.
Unchanged append SQL and old pipeline-versus-sequential benchmarks alone were rejected as
proof of observer neutrality. A mandatory broad statistical matrix was rejected as
disproportionate to the affected paths.
