## 0.3.0.0 — 2026-10-28

### Breaking Changes

- Add `KirokuCompaction` and `KirokuStore` constructors to `KirokuCommand`; exhaustive host matches need new arms.

### New Features

- Require `kiroku-store ^>=0.13.0.0`; maintenance outcomes use exit 0 for success/already applied, 2 for refusal and 1 for file/usage/store errors.

- Embed manifest preview, digest-confirmed apply, ledger listing and store identity commands in a host owning a `KirokuStore`. The standalone remote client refuses these commands with guidance.
- Return structured exit codes with `KirokuCommandOutcome` and `executeKirokuCommandWithStore`; expose validated manifest loading and table/JSON renderers in `Kiroku.Cli.Compaction`.
