## 0.7.3.0 — 2026-10-28

### New Features

* Migration `0017` installs the immutable store identity and empty append-only event-compaction ledger, with named constraints and mutation guards. The manifest now has seventeen entries; ordinary hot tables are unchanged. Existing sixteen-step databases gain one pending migration and schema comment `Managed by pg-migrate component kiroku through 0017`; migration-count fixtures must advance to seventeen.
