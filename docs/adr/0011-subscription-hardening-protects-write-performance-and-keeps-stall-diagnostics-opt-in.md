---
type: Architecture Decision Record
title: Subscription hardening protects write performance and keeps stall diagnostics opt-in
description: "Require performance evidence proportional to subscription changes, preserve cheap default paths, and make handler-stall diagnostics opt-in."
generated:
  by: openai/gpt-6-astra
  at: "2026-10-09T16:25:55Z"
docId: ADR-11
status: Accepted
date: 2026-10-09
timestamp: "2026-10-10T13:52:05Z"
originatingPlan: docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md
---

# ADR-0011: Subscription hardening protects write performance and keeps stall diagnostics opt-in

## Context

MasterPlan 12 adds checkpoint metadata, typed decode failures, and handler-stall diagnostics.
Although none requires extra work in a successful append statement, subscriptions share PostgreSQL
resources and often the same process, pool, CPU, and garbage collector with appenders. Wider
checkpoint rows and additional delivery allocations can therefore reduce write throughput or
increase append latency without changing append SQL. The user explicitly prioritizes performance,
especially write performance.

[ADR-5](0005-three-tier-performance-regression-gates.md) establishes structural and controlled
workload gates. Existing append controls compare pipelining and category-column costs, rather than
this cohort against its pre-change behavior with active subscriptions. The existing Shibuya
overhead benchmark primarily measures catch-up through a synthetic adapter. Neither establishes
write-performance neutrality for this cohort. [ADR-8](0008-subscription-configuration-validates-at-construction-and-runtime-refusals-share-one-parent.md)
continues to govern correctness and validated subscription configuration.

## Decision

Successful event appends must gain no subscription-hardening SQL round trips, pooled checkouts,
locks, indexes, triggers, or per-event instrumentation. Ordinary checkpoint saves remain one
monotonic upsert per batch tail, without extra verification statements or indexes on the new
metadata. Correctness requirements remain mandatory; performance cannot be recovered by dropping
acknowledgements, weakening checkpoint durability, or silently skipping events.

The cohort has no intentional default event-append regression budget. Select the minimum useful
evidence for each actual change: existing ADR-5 controls, structural invariants, and a focused
pre-change comparison of the affected path. Reuse valid results when production source and
measurement inputs have not changed. A checkpoint metadata change does not require a full
write-shape, subscription-mode or load matrix, repeated calibration, or proof at 1%/3% resolution.
Broaden measurements only to resolve a specific affected-path risk or a consistent adverse
signal. The user explicitly required this proportional scope on 2026-10-09 after rejecting
the agent's oversized experiment. This supersedes the earlier universal precision requirement.

On 2026-10-09 the user accepted the measured checkpoint-only save cost after clarifying that
it is a subscription checkpoint operation, outside the event-append transaction. This is a
specific EP-2 trade-off, not permission to slow event appends. Checkpoint saves are synchronous
between subscriber batches and use the shared store pool, so small batches can reduce subscriber
throughput and shared resource contention can indirectly affect appends. Retain those measured
costs and assess the integrated event-append path in EP-6. Report server statement execution
separately from client-observed save latency; neither is event-append latency.

Reproducible event-append regressions block completion and release. Reports distinguish practical
acceptance from statistical equivalence: noisy or undersampled comparisons remain statistically
inconclusive, and absence of significance is not proof of no regression. Retain the original
comparison policy, observed effects and uncertainty; do not tune a threshold after seeing results
to manufacture a pass. A child may complete on the agreed minimum evidence with these limitations
stated. The integrated cohort needs original-control evidence selected for the paths it actually
changes, including real acknowledgement and opt-in diagnostic costs where applicable.
PostgreSQL 18 is the required performance scope; the user's earlier correction excludes
PostgreSQL 17 performance trials.

The user subsequently approved EP-2 practical completion with its statistical
uncertainty retained and continuation to EP-3. Focused correctness, structural
and affected-path checks accompany implementation. Reserve the cumulative
append comparison for the completed cohort in EP-6 before release, using a
focused experiment within the one-hour whole-experiment ceiling. Do not require
another remote mixed-write benchmark for each child or relabel an inconclusive
comparison as a statistical pass.

On 2026-10-10 the user explicitly accepted EP-6's bounded cumulative evidence practically and authorized version review. The retained 25 valid trials include six adapter and five successful-hook pairs across two sessions. The latest adapter p99 estimate is +0.06% (95% -4.17% to +4.47%); the earlier large tail increase did not reproduce. Separate statistical policies remain inconclusive; the operator rejects pooling because reported host memory differs by 4096 bytes across boots. Full historical telemetry retains its timeouts and adverse exhausted-category result despite focused passes. No raw result, fingerprint, threshold or durability requirement changes. This is practical acceptance of this cohort's evidence, not a statistical equivalence claim or permission for reproducible append regressions. Release metadata and publication require their own approvals. The complete decision and evidence links are in `kiroku-store/bench/results/ep6-release/practical-acceptance.md`.

Handler-stall diagnostics are opt-in: `handlerStallWarnAfter = Nothing` in the store and both
adapter defaults. The disabled path creates no watchdog thread, tracking cell, timer, per-delivery
clock read, or tracking STM write. Enabling a duration such as `Just 60` retains the advisory
warning behavior and requires separate documented cost measurements. Plan 84 now implements
this inactive default and the opt-in watchdog, as recorded in
[ADR-13](0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md). This does not make
topology, identity, or decode correctness checks optional.

The absent-decode-hook read path must retain its no-traversal/no-copy behavior. A typed subscription
decode representation must not impose per-event wrapper allocation on the no-hook path merely for
representational uniformity; use an internal batch fast path or another measured design while
retaining the typed per-event failure contract when a hook runs. Disabled diagnostics and absent
hooks are selected outside the per-event delivery loop where feasible.

## Consequences

Evidence effort follows the changed paths and the user's scope. Existing correctness and
structural checks plus a focused mixed-workload comparison can suffice for a small checkpoint
change. The integrated cohort is assessed against the original control for cumulative costs.
A faster reconnect cannot offset a confirmed slowdown in healthy appends.

Operators must explicitly enable stall warnings and choose their threshold. Documentation and
tests must show both enabled behavior and the inactive default. Correctness fixes still ship by
default once their write-performance gates pass. If a safety design causes a confirmed write
regression, revise the design and remeasure; do not silently relax a gate or claim the original
performance objective is complete.

## Alternatives Considered

Keeping `Just 60` as the default was rejected because it charges every existing subscriber for
clock reads, STM updates, and watchdog scheduling before the caller has requested that diagnostic.

Relying solely on unchanged append SQL was rejected because shared CPU, GC, pool contention,
and checkpoint WAL can affect appends indirectly. Requiring a broad matrix and tight statistical
precision for every small change was also rejected as disproportionate; focused evidence retains
its uncertainty rather than being relabelled as a strict statistical pass.

Making correctness checks optional was rejected: the cohort must preserve both its safety
contracts and the user's write-performance requirement.
