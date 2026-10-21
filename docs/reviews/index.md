---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Review

- [Kiroku 0.10.0.0 subscription hardening cohort](kiroku-0-10-subscription-hardening-cohort.md) - The 0.9.0.1 to 0.10.0.0 cohort changes no append or read SQL and its per-batch subscription cost is bounded by the retained same-process evidence, the new startup verification, decode-failure containment, reconnect repair and adapter acknowledgement paths trace correctly, but migration 0013 plus the documented resize remedy permanently skips the backlog of a legacy member that never checkpointed, the kiroku-store changelog omits several public API breaks, the consumer upgrade edge landed two days after publication, and the operator migration guide still stops at 0012.
- [Kiroku 0.11.0.1 structured script error patch](kiroku-0-11-0-1-structured-errors-patch.md) - The 0.11.0.0 to 0.11.0.1 patch preserves SQLSTATE and server messages from script and statement failures through every error mapper, keeps connection loss and pool timeouts typed, adds no work to any append, read or subscription hot path, is covered by a new store suite and updated sanitization tests, and its one behavioural change, typed constructors replacing the ConnectionError catch-all on pool-backed reads, is documented and already handled by keiro's transient-error classification.
- [Kiroku 0.11.0.0 inspection cohort](kiroku-0-11-inspection-cohort.md) - The 0.10.0.0 to 0.11.0.0 cohort adds only index maintenance from migration 0015 to the append path, with a retained five-pair cell comparison bounding its throughput effect within a few percent and a paired gate proving metadata reads unchanged, its browse, dead-letter, stream-head and standalone surfaces are bounded and correct, but the kiroku-metrics changelog claims a WebSocket origin refusal that the default-off policy does not perform, the kiroku-store changelog omits a record-selector break, the release commit's docs still called the surface unreleased, and the performance ledger records none of the cohort's experiments.
- [Kiroku 0.9.0.0 and 0.9.0.1 category-index cohort](kiroku-0-9-category-index-cohort.md) - The 0.8.0.2 to 0.9.0.1 cohort correctly replaces the per-stream LATERAL category reads with one index range scan that fresh same-process gates show 2.5x to 100x faster, correctly fixes the idle publisher's heap retention and wakes category group members only on their category, and documents migration 0012's maintenance window, but the only same-process measurement of 0012's per-event write cost, the append-category-column cell, has a reproducible position effect that makes its 1.05 ceiling pass vacuously, so that cost has never been validly measured.

