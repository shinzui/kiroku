Hackage: https://hackage.haskell.org/package/kiroku-store-migrations-0.7.1.0

### New Features

- Migration 0015 adds one partial byte-ordered name index for catalog and literal-prefix
  reads, preserving existing unique-name and category/event indexes. The transactional
  build requires a write pause on large stores; write-cost evidence and its limitations are recorded
  by MasterPlan 13. The inspection cohort received practical performance acceptance before publication.
