# Selective compaction release candidate

Six implementation children are complete through `01792b8`. The release child is
preparing this cohort for version/changelog approval before commit, tags or upload.

| Package | Current → candidate | Reason | Changelog |
|---|---|---|---|
| kiroku-store | 0.12.0.0 → 0.13.0.0 | major: expanded Store, StoreError and KirokuEvent sums | [Notes](notes/kiroku-store.md) |
| kiroku-store-migrations | 0.7.2.0 → 0.7.3.0 | minor: additive migration 0017 | [Notes](notes/kiroku-store-migrations.md) |
| kiroku-cli | 0.2.0.11 → 0.3.0.0 | major: expanded KirokuCommand sum | [Notes](notes/kiroku-cli.md) |
| kiroku-otel | 0.3.0.0 → 0.3.0.1 | patch: maintenance event no-ops and bounds | [Notes](notes/kiroku-otel.md) |
| kiroku-metrics | 0.4.0.0 → 0.4.0.1 | patch: maintenance event no-ops and bounds | [Notes](notes/kiroku-metrics.md) |
| shibuya-kiroku-adapter | 0.7.0.0 → 0.7.0.1 | patch: bounds and atomic test collector | [Notes](notes/shibuya-kiroku-adapter.md) |

All internal dependent stanzas admit Store 0.13; metrics admits CLI 0.3. Internal
examples pin Store 0.13 and test support pins migrations 0.7.3. The existing
blueprint edges remain; the [new edge](../../../blueprints/kiroku-upgrade/migrations/0-12-to-0-13.md)
covers source adaptation, migration 0017, fixtures, grants and optional adoption.

Registry/tag baseline facts are in [registry-before.json](registry-before.json).
Local verification and archive hashes are recorded as checks complete. These are
candidate artifacts, not publication evidence. The adapter retains its existing
non-failing `cabal check` advisory about `-O2`.

The [consumer](consumer/) is prepared for a registry-only proof after publication.
Copy it outside the repository, set a fresh `CABAL_DIR`, run `cabal update`, then
`cabal build` and `cabal run kiroku-compaction-consumer` with PostgreSQL on PATH.
Its own project pins both public packages and contains no source-repository stanza
or local package path. The witness exercises migration, identity, inventory,
preview, exact apply, identical reapply, ledger, unchanged survivors/head and append.
Keep the resolved plan and logs when the published proof runs.
