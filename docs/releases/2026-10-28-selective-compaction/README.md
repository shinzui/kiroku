# Selective compaction release

The user approved this cohort on 2026-10-28. Release commit
`7511adf7ed57bc30a330bfb6431451e5004fd9f0`, six annotated tags, six Hackage
source/documentation pairs and six non-draft GitHub releases are published.
The fresh registry-only consumer passed. All seven implementation/release children
and IR-14 are complete.

| Package | Previous → released | Reason | Changelog |
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
[Publication](publication.json), [published registry/hash checks](registry-after.json),
[tags](remote-tags.txt), [GitHub releases](github-releases.json) and
[archive hashes](artifacts.json) retain the release evidence.
[Verification](verification.json) distinguishes completed local gates from the
fresh registry-only consumer, whose resolved origins are in [consumer-proof.json](consumer-proof.json). The adapter retains its existing
non-failing `cabal check` advisory about `-O2`.

The [consumer](consumer/) resolves exact published versions from Hackage.
Copy it outside the repository, set a fresh `CABAL_DIR`, run `cabal update`, then
`cabal build` and `cabal run kiroku-compaction-consumer` with PostgreSQL on PATH.
Its own project pins both public packages and contains no source-repository stanza
or local package path. The witness exercises migration, identity, inventory,
preview, exact apply, identical reapply, ledger, unchanged survivors/head and append.
Keep the resolved plan and logs when the published proof runs.

| Package | Hackage | GitHub release |
|---|---|---|
| kiroku-store | [0.13.0.0](https://hackage.haskell.org/package/kiroku-store-0.13.0.0) | [Release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-v0.13.0.0) |
| kiroku-store-migrations | [0.7.3.0](https://hackage.haskell.org/package/kiroku-store-migrations-0.7.3.0) | [Release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-migrations-v0.7.3.0) |
| kiroku-cli | [0.3.0.0](https://hackage.haskell.org/package/kiroku-cli-0.3.0.0) | [Release](https://github.com/shinzui/kiroku/releases/tag/kiroku-cli-v0.3.0.0) |
| kiroku-otel | [0.3.0.1](https://hackage.haskell.org/package/kiroku-otel-0.3.0.1) | [Release](https://github.com/shinzui/kiroku/releases/tag/kiroku-otel-v0.3.0.1) |
| kiroku-metrics | [0.4.0.1](https://hackage.haskell.org/package/kiroku-metrics-0.4.0.1) | [Release](https://github.com/shinzui/kiroku/releases/tag/kiroku-metrics-v0.4.0.1) |
| shibuya-kiroku-adapter | [0.7.0.1](https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.7.0.1) | [Release](https://github.com/shinzui/kiroku/releases/tag/shibuya-kiroku-adapter-v0.7.0.1) |

The isolated proof used signed index state `2026-10-28T11:40:47Z`, a fresh config,
index, cache and package store. Its only local package is the proof consumer; all
configured dependencies are secure Hackage sources. Both downloaded Kiroku archive
hashes match the approved artifacts. The [resolved plan](registry-consumer-plan.json.gz),
[build log](logs/registry-consumer-build.log.gz), [run log](logs/registry-consumer-run.log.gz)
and [structured proof](consumer-proof.json) retain the evidence.

The first four index updates lagged publication; all five attempts are retained.
FRIC-12 accepts that propagation latency without source overrides or weakened pins.

```text
clean consumer verified: kiroku-store 0.13.0.0, kiroku-store-migrations 0.7.3.0, store StoreIdentity 01a1825a-8900-7579-aaff-49b8206eee12, manifest "b15157c4728297ca8d3475fcd9303a3e5c526cf87f889bdc1b1b1acbcf0bfec6", selected 1, applied CompactionId 01a1825a-8911-7f5d-9ac1-cbf2f8763e40, surviving versions [1,3], appended at version 4
disposable PostgreSQL stopped cleanly
```
