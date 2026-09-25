# Bundle Update Log

## 2026-09-25
* **Addition**: ADR-10 records, for BUG-2 and plan 91, that category reads (plain and consumer-group) range-scan a (category, global position) partial index over a category column copied onto $all junction rows, replacing plan 10's LATERAL per-stream probe; migration 0012 adds the column, backfill, CHECK, and index.

## 2026-09-10
* **Addition**: ADR-9 records, for IR-13, that every documented kiroku-metrics JSON body, WebSocket frame, and Prometheus metric name is a published contract that grows only additively, with incompatible changes shipping as new paths or frame types, and that the HTTP/WebSocket surface lives in sister packages wrapping supported kiroku-store APIs.
* **Addition**: ADR-8 records the subscription API conventions MasterPlan 12 establishes toward 1.0: construction-time validation, declared startup policies, one exception parent for runtime refusals, and never skipping an event on a consumer's behalf.

## 2026-08-13
* **Addition**: ADR-7 establishes durable replay-history leases, conservative destructive-operation coordination, affected-stream lock ordering, transaction/read-hook boundaries, and ordinary-hot-path exclusion.
* **Addition**: ADR-6 establishes owner-published, frozen versioned SQL relations with owner-rights access, structural read-only behavior, semantic non-null values, and focused catalog tests.

## 2026-08-12
* **Update**: ADR-4 now distinguishes authoritative frontier seeding from the visible global head.

## 2026-08-11
* **Addition**: ADR-5 establishes deterministic structural checks and same-process controlled workload ratios as authoritative performance gates, with exact-coverage historical comparisons retained as telemetry and an opt-in strict smoke check.
* **Addition**: ADR-4 records explicit absent-checkpoint initialization, existing-row precedence, and the separation between monotonic saves and transaction-composable reset.

## 2026-08-09
* **Migration**: Adopt the shared architecture-decision profile: assign stable ADR-1..ADR-3 handles to the existing corpus, convert README.md to the reserved index.md, and enforce strict profile/log validation.
