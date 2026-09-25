# Capability Catalog Log

## 2026-09-25
* **Update**: CAP-1 now records the twelve-entry native manifest and migration `0012`, which puts the source stream's category on `$all` junction rows and indexes it for category reads (plan 91).
* **Update**: CAP-13 notes that consumer-group category members now wake only on appends to their category (plan 91), while $all group members still wake on every global advance.

## 2026-09-20
* **Update**: CAP-19 now records masked consumer-group ownership transfer, exception-preserving
cleanup, single-subscription monitor ownership, and real-store replay/leak evidence for halt and
cancellation at the checkpoint boundary. It also replaces the obsolete handler-exception
limitation with the exact candidate-core contract and release-bound caveat.

## 2026-08-13
* **Addition**: CAP-21 records durable replay-history leases and transaction-scoped one-stream guards, shipped in `kiroku-store` 0.7.0.0 and `kiroku-store-migrations` 0.3.2.0 with raw-SQL, concurrency, hot-path, and clean-consumer evidence.
* **Update**: CAP-1 now records the ten-entry native manifest, seven-entry Codd import prefix, frozen least-privilege subscription checkpoint SQL relation, and replay-retention schema contract.

## 2026-08-12
* **Update**: CAP-4 now exposes and proves the payload-free visible global head position.

## 2026-08-11
* **Addition**: CAP-20 records explicit atomic checkpoint initialization policies and exact transaction-composable reset evidence.

## 2026-08-08
* **Adoption**: Authored the initial profile-governed capability catalog for Kiroku under the
shared `coordination.capabilities` profile (okf-profiles v0.9.0). Nineteen capabilities
(CAP-1..CAP-19) were derived from package descriptions, exposed modules, the test suites, the
user guides, and per-package changelogs, each backed by at least one openable artifact.
Registered the `capabilities` bundle in `mori.dhall`. The catalog records provision, not
composition: internal packages (`kiroku-jitsurei`, `kiroku-test-support`) are excluded, and the
`shibuya-kiroku-adapter` record is scoped to the adapter this repository ships and proves.
