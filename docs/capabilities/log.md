# Capability Catalog Log

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
