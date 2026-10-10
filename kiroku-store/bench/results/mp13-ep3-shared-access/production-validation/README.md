# Production browse validation — 2026-10-10

PostgreSQL 18.6, GHC 9.12.4, macOS ARM64. These are correctness and structural
checks, not append-cost samples. The selected index is migration 0015.

- `cabal build all` succeeds; existing migration-test shadowing warnings remain.
- Serial store/migration/metrics suites pass 434/24/68 examples. Production
  prepared statements are tested under generic and custom plans in C and English
  ICU databases with a 40,000-stream catalog: range scans examine at most 11
  rows, the pair at most 22, and top shared buffers at most 64.
- The example verifies all nine steps, including browsing, historical events,
  lookup by id and unchanged WebSocket behavior.
- Initial tests retain six stale migration-assertion failures and a backpressure
  resumed-signal failure under concurrent compilation. Updated assertions and
  the serial rerun pass. Overlapping local Cabal builds also collided on object
  files; final validation is serial. No failures were used as benchmark samples.

Hashes cover the retained raw logs. Final-layout write-cost and cumulative
release acceptance remain independent.
