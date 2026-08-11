---
type: Architecture Decision Record
title: Separate performance regression evidence into structural, controlled workload, and historical telemetry tiers
description: "Use deterministic structural checks and same-process controlled workloads as authoritative performance gates while retaining exact-coverage historical CSV comparisons as telemetry and an opt-in strict smoke check."
generated:
  by: openai/gpt-5
  at: "2026-08-11T17:54:14Z"
docId: ADR-5
status: Accepted
date: 2026-08-11
timestamp: "2026-08-11T17:54:14Z"
originatingPlan: docs/plans/64-harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates.md
---

# ADR-0005: Separate performance regression evidence into structural, controlled workload, and historical telemetry tiers

- **Related:** [ExecPlan 64](../plans/64-harden-benchmark-regression-detection-with-structural-checks-and-controlled-a-b-workload-gates.md);
  [performance regression gates](../PERF-REGRESSION-GATES.md);
  [performance methodology](../PERF-METHODOLOGY.md).

## Context

Kiroku has a checked-in `tasty-bench` CSV baseline that preserves useful historical timings. An
absolute comparison with an earlier run, however, also includes changes in the host, PostgreSQL,
compiler, linker layout, and background load. It is therefore too noisy to decide whether a code
change may be promoted. A missing baseline row is also not a failed `tasty-bench` comparison, so
coverage must be checked separately.

Some performance properties can be protected without a clock: a no-op must not check out a
connection, notification cardinality must remain exact, and representative PostgreSQL plans must
use the indexes that make the intended query shape scale. When elapsed time is essential, a real
control and candidate can run in one process against matching databases on one PostgreSQL server,
which makes their ratio a more credible promotion signal than two absolute measurements captured
at different times.

## Decision

Separate performance-regression evidence into three tiers:

1. Deterministic structural checks assert protected notification, no-work, and PostgreSQL
   query-plan invariants. These checks are authoritative.
2. Controlled workload gates run a pre-registered control and the production candidate in one
   benchmark process against matching seeded databases. Database workloads use wall-clock time,
   and the declared workload and ratio threshold are fixed before evaluating a change. These gates
   are authoritative.
3. The checked-in historical CSV remains non-failing telemetry. Its benchmark names must match the
   current historical suite exactly before any comparison runs. A separate opt-in strict command
   may fail on a declared percentage, but it is a diagnostic smoke check rather than an
   authoritative promotion veto.

The aggregate `just perf-check` runs only the structural and controlled workload tiers. Baseline
rows are refreshed deliberately to represent a new historical reference, never merely to make a
regression report green. Historical movement still requires investigation, especially when it
overlaps a protected workload, but it does not override a passing controlled comparison by itself.

## Consequences

**Positive**

- Promotion decisions rely on deterministic facts or a same-process counterfactual instead of
  host-to-host timing drift.
- Exact name coverage prevents new or renamed historical cells from silently escaping comparison.
- Historical timings remain available for broad regression discovery and longitudinal context.
- Contributors can distinguish an invariant failure, a controlled-ratio failure, and an absolute
  timing movement from the command they ran.

**Negative**

- Important workloads need an explicit control that may duplicate an older implementation inside
  benchmark-only code and must be maintained as production behavior evolves.
- Representative PostgreSQL plan fixtures can require adjustment when supported PostgreSQL
  versions legitimately choose a different but equivalent plan.
- The authoritative aggregate does not automatically veto unrelated historical slowdowns;
  maintainers must inspect telemetry and add a structural or controlled gate when a newly important
  risk is discovered.

## Alternatives Considered

- **Make every historical CSV comparison a required percentage gate.** Rejected because unrelated
  machine-state changes can veto a sound change and a fixed percentage does not establish causal
  contrast.
- **Keep historical comparison without an exact coverage preflight.** Rejected because a missing
  baseline row is otherwise accepted without comparison and can look like a passing regression
  check.
- **Use only structural checks.** Rejected because some end-to-end database improvements depend on
  protocol round trips and transaction topology that cannot be reduced to one stable structural
  assertion.
- **Build a custom statistics and report framework.** Rejected because the resolved benchmark
  library already supports same-process relative gates; repository-specific code should focus on
  workload control, exact coverage, and contributor workflow.
