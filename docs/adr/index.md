---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [Resolve stream names via an on-demand lookup API, not a `RecordedEvent` field](0001-resolve-stream-names-via-lookup-not-recordedevent-field.md) - Resolve stream names on demand via a batch lookup API instead of adding an originalStreamName field to RecordedEvent, keeping the read hot path byte-identical and inside the 10% read-regression gate.
- [Consumer groups are static, hash-partitioned competing consumers](0002-static-hash-partitioned-consumer-groups.md) - Implement consumer groups as static, hash-partitioned competing consumers over each stream's surrogate stream_id, with structured per-member checkpoint columns and no dynamic rebalancing.
- [Install Kiroku objects in a dedicated `kiroku` schema](0003-dedicated-kiroku-schema.md) - Install all Kiroku-owned objects into a dedicated schema (default kiroku), making ConnectionSettings.schema authoritative for both table resolution and the LISTEN notification channel.
- [Subscription checkpoint initialization is explicit and reset is a separate transaction operation](0004-explicit-subscription-checkpoint-lifecycle.md) - Resolve an absent exact subscription checkpoint through one of three atomic policies, preserve existing rows, keep ordinary saves monotonic, and expose rewind only as an exact transaction-composable reset.
- [Separate performance regression evidence into structural, controlled workload, and historical telemetry tiers](0005-three-tier-performance-regression-gates.md) - Use deterministic structural checks and same-process controlled workloads as authoritative performance gates while retaining exact-coverage historical CSV comparisons as telemetry and an opt-in strict smoke check.
- [Versioned public SQL relations are owner-published and frozen](0006-versioned-public-sql-relations-are-owner-published-and-frozen.md) - Publish database-native integration surfaces as owner-rights, structurally read-only versioned relations with frozen ordered shapes, semantic non-null guarantees, and focused catalog tests.
