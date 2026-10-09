---
type: Architecture Decision Record
title: Subscription hardening protects write performance and keeps stall diagnostics opt-in
description: "Require controlled append and mixed-workload evidence for subscription hardening, preserve cheap default paths, and make handler-stall diagnostics opt-in."
generated:
  by: openai/gpt-6-astra
  at: "2026-10-09T16:25:55Z"
docId: ADR-11
status: Accepted
date: 2026-10-09
timestamp: "2026-10-09T18:45:40Z"
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

The cohort has no intentional default write-regression budget. Its acceptance requires controlled
append-only and mixed append/subscription comparisons against the pre-cohort implementation,
including PostgreSQL 18, real acknowledgements, sustainable throughput, append latency
percentiles, durable subscriber progress, and checkpoint write cost. Reproducible write regressions
block completion and release. Noisy evidence is inconclusive and requires better measurement;
lack of statistical significance is not proof of equivalence. Detailed workload controls and
measurement resolution belong in the active MasterPlan and child evidence, not a new global
replacement for ADR-5's existing thresholds. On 2026-10-09 the user explicitly
narrowed the required database-version scope to PostgreSQL 18; PostgreSQL 17
performance testing is excluded from this cohort's acceptance requirement.

Handler-stall diagnostics are opt-in: `handlerStallWarnAfter = Nothing` in the store and both
adapter defaults. The disabled path creates no watchdog thread, tracking cell, timer, per-delivery
clock read, or tracking STM write. Enabling a duration such as `Just 60` retains the advisory
warning behavior and requires separate documented cost measurements. This changes the planned
default in plan 84; the feature is not yet implemented. It does not make topology, identity, or
decode correctness checks optional.

The absent-decode-hook read path must retain its no-traversal/no-copy behavior. A typed subscription
decode representation must not impose per-event wrapper allocation on the no-hook path merely for
representational uniformity; use an internal batch fast path or another measured design while
retaining the typed per-event failure contract when a hook runs. Disabled diagnostics and absent
hooks are selected outside the per-event delivery loop where feasible.

## Consequences

Implementation and release require more evidence than isolated subscription benchmarks. Both
individual changes and the integrated cohort are compared with the original control to expose
cumulative small costs. A faster reconnect cannot offset slower healthy appends in acceptance;
each workload is assessed separately.

Operators must explicitly enable stall warnings and choose their threshold. Documentation and
tests must show both enabled behavior and the inactive default. Correctness fixes still ship by
default once their write-performance gates pass. If a safety design causes a confirmed write
regression, revise the design and remeasure; do not silently relax a gate or claim the original
performance objective is complete.

## Alternatives Considered

Keeping `Just 60` as the default was rejected because it charges every existing subscriber for
clock reads, STM updates, and watchdog scheduling before the caller has requested that diagnostic.

Relying on unchanged append SQL or aggregate benchmark averages was rejected because shared
CPU, GC, pool contention, and checkpoint WAL can affect appends indirectly. Faster cases must not
hide a slower write scenario.

Making correctness checks optional was rejected: the cohort must preserve both its safety
contracts and the user's write-performance requirement.
