# Proposed subscription hardening release cohort

Approval status: pending. This is a proposal only; package metadata is unchanged.
Publication requires a separate approval and all acceptance gates.

Authoritative Hackage preferred-version responses and upstream peeled tags were verified on 2026-10-10 UTC. The date in the proposed changelogs is 2026-10-09 in the workspace timezone.

| Package | Hackage / current | Latest tag | Package commits at audit | Proposed | Reason |
| --- | --- | --- | ---: | --- | --- |
| kiroku-store | 0.9.0.1 | kiroku-store-v0.9.0.1 | 16 | 0.10.0.0 | Major: opaque validated types, typed decode result, config fields and startup/checkpoint semantics. |
| kiroku-store-migrations | 0.6.0.0 | kiroku-store-migrations-v0.6.0.0 | 3 | 0.7.0.0 | Major: migration 0014 removes a schema column and introduces target-binding semantics; stopped-worker upgrade required. |
| kiroku-otel | 0.2.0.10 | kiroku-otel-v0.2.0.10 | 4 | 0.2.0.11 | Patch: handle new internal events/stop attributes and adopt the store bound; exported API unchanged. |
| kiroku-cli | 0.2.0.8 | kiroku-cli-v0.2.0.8 | 0 | 0.2.0.9 | Patch: bound-only release required by the new store major line. |
| kiroku-metrics | 0.1.0.10 | kiroku-metrics-v0.1.0.10 | 4 | 0.2.0.0 | Major: public LifecycleCounters record gains fields; JSON/Prometheus additions. |
| shibuya-kiroku-adapter | 0.5.1.5 | shibuya-kiroku-adapter-v0.5.1.5 | 4 | 0.6.0.0 | Major: validated capacity/group types and new config fields; kirokuProcessor added. |

Commit counts include evidence/benchmark documentation and are the frozen scope audit at harness commit 904a066. Later benchmark-wrapper preparation changes no production package API.

The exact 12-file proposal is [release-metadata.patch](release-metadata.patch). All existing bounded kiroku-store dependencies become `^>=0.10.0.0`; bounded kiroku-cli dependencies in metrics become `^>=0.2.0.9`. Internal self-dependencies and external bounds are retained. Migrations has no direct store dependency, so no bound is invented.

The lifetime member-guard plans 92/93 are unimplemented and excluded. Registered consumer discovery is retained in dependents.json; downstream adoption in mori://shinzui/keiro follows publication, with a separately authorized commit and no Keiro release.

Completed preparation: all six PostgreSQL 18.6 suites pass (554 examples), full build passes, six cabal checks pass, native flake formatting/pre-commit checks pass. Archives and Haddocks for new versions follow metadata approval. Cumulative performance is inconclusive: zero valid matched pairs after the control failed its checkpoint-frequency invariant. Historical telemetry failed two of 30 cases. Original statistical/regression policy is unchanged and no publication approval is requested.
