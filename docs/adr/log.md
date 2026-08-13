# Bundle Update Log

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
