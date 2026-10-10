# Bundle Update Log

## 2026-10-10
* **Update**: ADR-11: record user-approved EP2 practical completion and reserve cumulative append measurement for the integrated release gate.

## 2026-10-09
* **Update**: Clarify the user-accepted EP2 checkpoint-only cost, synchronous subscriber saves and retained event-append regression gate.
* **Update**: ADR-4: bind checkpoints to targets with declared legacy adoption and explicit transactional rebind; preserve binding on resize and the existing startup/save boundaries.
* **Update**: Require proportional performance evidence following the user minimum-evidence correction; preserve original inconclusive statistical reports and unchanged regression policies.
* **Update**: ADR-11 clarifies bounded evidence of unchanged performance without requiring every path to show a speedup; confirmed adverse changes remain blocking.
* **Update**: Narrow controlled subscription-hardening performance acceptance to PostgreSQL 18 following the user scope correction; retain all write-performance and precision requirements.
* **Update**: ADR-2: replace stop/drain/restart advice with durable topology validation and transactional minimum-checkpoint equalization
* **Addition**: ADR-11 records the write-performance acceptance constraint for MasterPlan 12, controlled mixed append/subscription evidence, preserved no-hook fast paths, and opt-in handler-stall diagnostics.

## 2026-09-25
* **Update**: ADR-10 now records that the 0.9 upgrade has no rolling-deploy path (0.8 writers fail with 23514 after 0012), that a compatibility trigger was rejected in favour of a write pause, and that the kiroku-upgrade blueprint carries the cutover.
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
