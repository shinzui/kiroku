# Verified release artifacts for MasterPlan 12

Metadata approved by the user on 2026-10-10. The six independent version, bound and changelog updates are applied. The final metadata diff also includes a packaging repair: six LICENSE files carrying the existing declared BSD-3-Clause text and author, plus license-file fields. Cabal formatting changes alignment only; external dependency bounds are unchanged.

Publication status: authorized; the user explicitly directs proceeding under the existing approvals, without further confirmation. No release commit, tag, push, Hackage upload, GitHub release or downstream edit has occurred. EP6 remains In Progress for publication, clean published-consumer verification and downstream adoption.

## Verification

- `cabal build all`: PASS at the new versions, then PASS after license metadata changes.
- `cabal test all --test-show-details=direct`: PASS on PostgreSQL 18.6, 554 examples across six suites: store 423, migrations 24, otel 17, CLI 22, metrics 23, adapter 45.
- Six `cabal check` commands: PASS.
- `cabal sdist` and Hackage Haddock generation: PASS for all six packages. Haddock retains nonfatal missing-documentation and ambiguous/missing-link warnings in haddock.log.
- Archive inspection: exact Cabal/changelog/license contents, all 49 public module source files and HTML pages, Hackage symbol indexes and interfaces; migrations manifest/lock and every SQL payload match, including 0013/0014.
- Strict ADR validation: 14 concepts PASS. Configured capability validation: 21 concepts PASS (existing advisory Mori schema-hash warning retained by the command; sealed evaluation and validation pass).
- `nix fmt`: PASS. Native `nix flake check --system aarch64-darwin`: PASS, treefmt and pre-commit checks; raw output in flake-check.log.
- Production source remains byte-for-byte unchanged from `5805117edf6bdb988d02d73e19fbb221ef2bf767`. Reuse the retained passing ADR-5 structural/controlled and fresh/upgrade/no-rewrite migration evidence. The approved practical performance decision preserves all strict inconclusiveness, rejected pooling and adverse telemetry: [decision](../ep6-release/practical-acceptance.md). No additional performance queue ran.
- `consumer/Main.hs` compiles against the six explicit local main-library unit IDs. Initial invocation errors were corrected and retained; this is fixture validation, not clean Hackage consumer proof. After publication, copy `consumer/` to a fresh external directory and resolve the six exact published versions without local sources or package environments.

A final diff check caught copied license-text trailing whitespace; it was removed and all six source archives were regenerated and reinspected. Raw command logs and unified diff context retain their original whitespace; the authored-file diff check excludes these evidence formats.

The final diff is [release-metadata.patch](release-metadata.patch); exact archive paths, sizes and SHA-256 hashes are in [archives.json](archives.json). Generated tarballs remain under dist-newstyle/ and will be hash-checked before uploading. Verification command journals and logs are retained alongside this document. Publication notes for each package are prepared in release-notes/.

## Publication order and reviewed archive hashes

| Package/version | Source archive | Documentation archive |
| --- | --- | --- |
| kiroku-store 0.10.0.0 | kiroku-store-0.10.0.0.tar.gz | kiroku-store-0.10.0.0-docs.tar.gz |
| kiroku-store-migrations 0.7.0.0 | kiroku-store-migrations-0.7.0.0.tar.gz | kiroku-store-migrations-0.7.0.0-docs.tar.gz |
| kiroku-otel 0.2.0.11 | kiroku-otel-0.2.0.11.tar.gz | kiroku-otel-0.2.0.11-docs.tar.gz |
| kiroku-cli 0.2.0.9 | kiroku-cli-0.2.0.9.tar.gz | kiroku-cli-0.2.0.9-docs.tar.gz |
| kiroku-metrics 0.2.0.0 | kiroku-metrics-0.2.0.0.tar.gz | kiroku-metrics-0.2.0.0-docs.tar.gz |
| shibuya-kiroku-adapter 0.6.0.0 | shibuya-kiroku-adapter-0.6.0.0.tar.gz | shibuya-kiroku-adapter-0.6.0.0-docs.tar.gz |

| Archive | SHA-256 |
| --- | --- |
| kiroku-store-0.10.0.0.tar.gz | `ff09ca182e6724e78616f440c9fbe1eb8552960afa4b33ac5ec6cd2cdc0a36d4` |
| kiroku-store-0.10.0.0-docs.tar.gz | `5fccd6d614a9f13d03749adced9510b900d034692fa27863b0c17f089b987891` |
| kiroku-store-migrations-0.7.0.0.tar.gz | `9c04214a5184a699e090396ee6065168bf508b2444f4d292a2e10258a89dacdb` |
| kiroku-store-migrations-0.7.0.0-docs.tar.gz | `8eb24bb1d6e1b5f524d68ee8d312d375a5f928d765fcea5d56e952442ea53f34` |
| kiroku-otel-0.2.0.11.tar.gz | `61d51efc40e3615ba4e3a98fccbf5d33380f95f43f0d0f6877d168eac0ff4345` |
| kiroku-otel-0.2.0.11-docs.tar.gz | `4607eff6c94a1c5e3cc15f3aa853155eda8c336414770620f7b394c360e2fc37` |
| kiroku-cli-0.2.0.9.tar.gz | `001eb1640559566c4400bc1e54d1b589b4743f40dfda2b65cb4070e50d01f778` |
| kiroku-cli-0.2.0.9-docs.tar.gz | `fe780f1046061176987137540db71c9f546736e67c171a8ac92128ec1e842f02` |
| kiroku-metrics-0.2.0.0.tar.gz | `5a868fca3219903c0f4f431e25dee5123797d83533cd31e30e1b31abbb2638f8` |
| kiroku-metrics-0.2.0.0-docs.tar.gz | `11758774ac2e2101bb22c92bc90b37f97641e184fde100fec453b492c30b65c1` |
| shibuya-kiroku-adapter-0.6.0.0.tar.gz | `7e7d27e12908aefc806474efec2809a5f901a6c738cc58efe1f5d3eac8cb5c27` |
| shibuya-kiroku-adapter-0.6.0.0-docs.tar.gz | `4549c86ad0319f386d54f0cd707a5fee861d17515ce6b58344e6c128502aabc1` |

Existing user authorization covers the reviewed license packaging repair and release commit, annotated tags, push, Hackage source/docs uploads and GitHub releases. Post-publication clean-consumer verification follows; downstream adoption in mori://shinzui/keiro remains a later EP6 step with a separately authorized commit and no Keiro release.
