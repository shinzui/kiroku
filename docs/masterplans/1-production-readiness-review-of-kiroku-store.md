---
id: 1
slug: production-readiness-review-of-kiroku-store
title: "Production Readiness Review of kiroku-store"
kind: master-plan
created_at: 2026-04-29T14:05:43Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
---

# Production Readiness Review of kiroku-store

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`kiroku-store` is a Haskell PostgreSQL event store that has been built and benchmarked through Milestone 7, but no production service has yet been wired to it. Once services start writing events to it, certain decisions become very hard to reverse: the on-disk schema, the public API and error types, the subscription delivery contract, the multi-tenancy model, and the operational expectations all get baked into call sites and on-disk data. The goal of this initiative is to perform a structured, end-to-end review of the package, surface every issue that would be hard or expensive to change later, and either fix it now or record an explicit, justified decision to defer it.

After this initiative is complete, the package has: (1) a written, evidence-backed assessment of every "fundamental" element of the package — schema/CTE invariants, the public type and effect surface, the subscription contract, multi-tenancy & security boundaries, operational signals, and test coverage; (2) all "must-fix-before-production" findings landed as code changes and verified by tests; (3) a documented production-readiness verdict naming the blast radius of every "deferred" finding and the conditions that would force a revisit.

In scope: the `kiroku-store` package only — every file under `kiroku-store/` (sources, SQL, tests, benches). The `shibuya-kiroku-adapter` package is in scope only insofar as it reveals issues with the `kiroku-store` API it consumes; the adapter itself is not under review. Out of scope: building a separate `kiroku` framework (subscriptions and projections live inside `kiroku-store` for now), extracting `kiroku-migrate`, and the parked partition-ready schema work.


## Decomposition Strategy

The review is decomposed into six work streams along axes of *fundamental* concerns — those where decisions are hardest to undo once consumers exist — followed by operational and test concerns that are additive and can be tightened incrementally.

The principles guiding the split: (1) each work stream owns one functional concern of the package and produces an independently verifiable artifact (a written audit plus the code changes that follow from it); (2) a reviewer can work a single stream end-to-end with only that stream's child ExecPlan and the working tree, because each ExecPlan repeats every piece of context it needs; (3) where two streams must agree on a shared artifact (an error type, a frontmatter field, a schema column) the agreement is documented in the Integration Points section below.

Alternatives considered. A single monolithic review document was rejected because it would mix correctness concerns (where the answer is binary) with operational concerns (where the answer is a tradeoff), and would not parallelise. Splitting by file or module was rejected because a single concern cuts across files (the soft-delete TOCTOU race spans `Effect.hs`, `SQL.hs`, and `schema.sql`; the multi-stream error attribution bug spans `Effect.hs` and `Error.hs`). Splitting into more than seven streams (e.g. one per file) would multiply context-switching cost without making any individual stream more tractable.

Each child plan begins with an *audit milestone* that produces a findings document, classifies findings by severity (must-fix-before-production, should-fix, defer-with-rationale), and is followed by *fix milestones* that land code for the must-fix items. Findings that touch multiple streams are recorded as integration points (below) and resolved by whichever stream has the fix; the other streams reference the resolution.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Schema, CTE and concurrency correctness audit | docs/plans/1-schema-cte-and-concurrency-correctness-audit.md | None | None | Complete |
| EP-2 | Public API surface, types and error model audit | docs/plans/2-public-api-surface-types-and-error-model-audit.md | None | EP-1 | Not Started |
| EP-3 | Subscription system robustness audit | docs/plans/3-subscription-system-robustness-audit.md | None | EP-1, EP-2 | Not Started |
| EP-4 | Multi-tenancy, security and schema lifecycle audit | docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md | None | EP-1 | Not Started |
| EP-5 | Operational hardening: observability, failure modes, limits | docs/plans/5-operational-hardening-observability-failure-modes-limits.md | None | EP-1, EP-2, EP-3 | Not Started |
| EP-6 | Test and benchmark hardening for production confidence | docs/plans/6-test-and-benchmark-hardening-for-production-confidence.md | None | EP-1, EP-2, EP-3, EP-4, EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

There are no hard dependencies between child plans — every plan can run its audit milestone independently against the current working tree, since each plan is self-contained and the tree itself is the source of truth for what to review. The dependencies that exist are *soft*: a later plan benefits from the findings of an earlier plan but is not blocked by it.

EP-1 (schema, CTE, concurrency) is the natural starting point because the SQL invariants it audits are referenced by every higher-level concern. If EP-1 finds that a CTE silently allows orphans on a particular code path, EP-2 (API/types/errors) and EP-3 (subscriptions) need to consider whether the API exposes that anomaly to callers. EP-1 has no hard dependencies and can begin immediately.

EP-2 (API, types, errors) soft-depends on EP-1 because the public error model (`StoreError` constructors, the multi-stream attribution bug, the `ConnectionError` catch-all) is downstream of what EP-1 finds at the SQL layer. If EP-1 reveals that a CTE distinguishes two failure modes that the current `StoreError` collapses, EP-2 should refine the type. EP-2 can still run its API-shape audit (effect mockability, ergonomics, documentation completeness) without waiting for EP-1.

EP-3 (subscriptions) soft-depends on EP-1 (it relies on the read paths the publisher uses) and EP-2 (the subscription error contract reuses `StoreError`). EP-3 can run its core audit (Notifier reconnection, EventPublisher backpressure, Worker catch-up correctness, Category live-mode gap, cancellation safety) immediately.

EP-4 (multi-tenancy, security, schema lifecycle) soft-depends on EP-1 because the schema-name plumbing has interactions with the SQL layer that EP-1 owns. The hard-delete authorization model, schema initialization vs migration, and connection-string handling can all be audited independently.

EP-5 (operational hardening) soft-depends on EP-1, EP-2, and EP-3 because the metrics, logging, and failure-injection scenarios it specifies follow naturally from the failure modes those audits surface. EP-5 can begin in parallel by inventorying current observability hooks and known failure modes from research notes, but its prioritisation of new metrics is best done after the upstream audits.

EP-6 (test and benchmark hardening) soft-depends on every other plan because the highest-value new tests are property-based or stress tests that codify the invariants the other audits identify. EP-6 should start late and end last, after the other plans have produced at least their findings documents.

Plans that can proceed in parallel: EP-1, EP-2, EP-3, EP-4 may all begin their audit milestones at the same time. The audit milestones produce written findings and do not modify code, so there is no conflict. Fix milestones (the second milestones of each plan) should be sequenced so that two plans do not edit the same file at once; the Integration Points section below identifies the files involved.


## Integration Points

These are shared artifacts that two or more child plans touch, where uncoordinated changes would conflict. Each integration point names the involved plans, the artifact, the responsible plan, and the contract.

`kiroku-store/src/Kiroku/Store/Error.hs` — `StoreError` data type. Touched by EP-1 (may want to add constructors for newly-distinguished SQL-layer failures), EP-2 (owns the public error contract overall), and EP-3 (subscription failures use `StoreError`). EP-2 is responsible for the final shape; EP-1 and EP-3 propose additions via PR comments on EP-2's fix branch. Existing constructors (`WrongExpectedVersion`, `StreamNotFound`, `StreamAlreadyExists`, `DuplicateEvent`, `ConnectionError`) must remain semantically stable for any consumer that already pattern-matches on them.

`kiroku-store/src/Kiroku/Store/Effect.hs` — the `Store` GADT and `runStorePool` interpreter. Touched by EP-1 (the soft-delete TOCTOU race lives in `runStorePool`'s pre-check), EP-2 (the multi-stream error attribution bug in the `AppendMultiStream` arm maps every conflict to the first stream's name), and EP-4 (schema name is read from `KirokuStore.schema` but never used in SQL — the schema field is dead). EP-1 owns the TOCTOU fix; EP-2 owns the attribution fix; EP-4 owns the schema-name decision (either remove the field or wire it through). All three coordinate on a single edit window for this file.

`kiroku-store/src/Kiroku/Store/SQL.hs` — every prepared statement and CTE template. Touched by EP-1 (correctness fixes to the CTEs, e.g. moving the soft-delete check inside the CTE), EP-3 (any new SQL needed for category live-mode filtering), and EP-4 (any schema-prefix changes for multi-tenant isolation). EP-1 owns this file's contract; EP-3 and EP-4 add new statements rather than altering existing ones.

`kiroku-store/sql/schema.sql` — the embedded DDL. Touched by EP-1 (any constraint or trigger fixes), EP-4 (multi-tenant schema scoping if pursued), and indirectly by EP-6 (test fixtures may extend it). The schema is embedded at compile time via `embedFile`; any change requires a rebuild. EP-1 owns the file; EP-4's changes either extend it or live in a separate per-tenant DDL.

`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` and `Subscription/EventPublisher.hs` — the subscription delivery path. Touched by EP-3 (its core focus) and EP-5 (observability hooks: subscriber lag, publisher queue depth). EP-3 owns the file; EP-5 contributes metric callback parameters that EP-3 wires through.

`kiroku-store/test/Main.hs` — the test suite. Touched by every plan that lands a fix milestone (each fix should add a regression test) and especially by EP-6 (which restructures the suite, eliminates `threadDelay`-based synchronization in subscription tests, and adds property-based and stress tests). EP-6 owns the suite's structure; earlier plans add tests that EP-6 may then refactor.

`kiroku-store/bench/Main.hs` and `bench/ShibuyaOverhead.hs` — benchmarks. Touched by EP-5 (failure-injection harness, pool saturation under varying sizes) and EP-6 (regression baseline, stress benchmarks). EP-6 owns the file.

`shibuya-kiroku-adapter/` — out-of-scope as a target, but used by EP-2 as a real-world consumer to validate API ergonomics findings. No edits from this initiative are expected.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: M1 — Schema, CTE, concurrency audit findings document (2026-04-29; 21 findings: 3 must-fix, 4 should-fix, 14 deferred / cross-plan / no-issue)
- [x] EP-1: M2 — Landed F1 (hard-delete orphan), F2 (soft-delete TOCTOU), F3 (linkToStream gap), F4 (multi-stream deadlock pre-lock), F5 (link rejects soft-deleted target), F6 (TRUNCATE bypass triggers); deferred F7 to EP-4 Haddock. 66/66 tests pass; reads within 3% of baseline; +12 regression tests. (commits 01c0ee6, e903062, a5754d6, 12a154b, 6d195e8, 8edfbee)
- [ ] EP-2: M1 — Public API and error model audit findings document
- [ ] EP-2: M2 — Land API/error-model fixes and document the contract
- [ ] EP-3: M1 — Subscription robustness audit findings document
- [ ] EP-3: M2 — Land subscription fixes (Category live-mode filter, lifecycle helpers, etc.)
- [ ] EP-4: M1 — Multi-tenancy, security, schema lifecycle audit findings document
- [ ] EP-4: M2 — Land must-fix corrections and explicit deferred-decisions for the rest
- [ ] EP-5: M1 — Failure-mode and observability gap inventory
- [ ] EP-5: M2 — Land observation-handler enrichment and failure-injection harness
- [ ] EP-6: M1 — Test and benchmark gap inventory
- [ ] EP-6: M2 — Land property tests, deterministic subscription tests, stress benchmarks
- [ ] MasterPlan: Final production-readiness verdict and deferred-findings register


## Surprises & Discoveries

Cross-plan insights, dependency changes, scope adjustments, and unexpected interactions discovered during the review.

### EP-1 audit (2026-04-29) — cross-plan findings

EP-1 Milestone 1 produced 21 findings (F1–F21). Three cross-plan items affect downstream plans
and are recorded here for traceability. Full details and severity classification live in the EP-1
plan's Surprises & Discoveries section.

  * **F11 → EP-2.** `ExactVersion` retry after a successful first call (e.g., a network blip)
    returns `WrongExpectedVersion`, not `DuplicateEvent`, even when the caller-supplied event_id
    matches the just-committed event. The CTE's `stream_update` returns 0 rows because the
    version no longer matches → `inserted_events` is gated by `EXISTS (SELECT 1 FROM
    stream_update)` and never runs → no `events_pkey` violation surfaces. EP-2 should decide
    whether the public `StoreError` should distinguish "your retry collided with your previous
    success" from "a different writer raced you."

  * **F12 → EP-3.** The `notify_events` trigger fires twice per single-stream append (once for
    the source-stream `streams` UPDATE, once for the `$all` UPDATE) and `2N` times per
    `appendMultiStream` call with N streams. The MasterPlan's initial research note "fires once
    per append" is incorrect. EP-3's subscription contract should document that subscribers see
    multiple NOTIFY events per logical append; the existing debouncing in `EventPublisher` masks
    this at the consumer level but EP-3's audit should confirm the invariant.

  * **F19 → EP-2.** `getStream(StreamName "$all")` returns the seed row's metadata (the global
    counter as `stream_version`). EP-2 should decide whether the `getStream` API hides `$all` or
    exposes it as a documented introspection point.

  * **F20 → EP-3.** The subscription invariants (`$all` advances monotonically, gap-free under
    all four append paths) hold *after* EP-1's must-fix items F2 (soft-delete TOCTOU) and F3
    (`linkToStream` silent version gap) are landed. Without the F3 fix, links to a hard-deleted
    event silently advance `stream_version` while inserting fewer junction rows, which would
    surface as gaps in the linked stream's read path.

  * **F21 → EP-6.** The existing test suite at `kiroku-store/test/Main.hs` is single-threaded.
    EP-1's must-fix regression tests for F1–F3 will introduce the first concurrent reproducers
    (deterministic interleaving via `MVar` barriers). EP-6 should treat these as the seed of a
    proper concurrency-test harness and expand from there.

### Integration-points clarification (2026-04-29)

The EP-1 audit confirms the file-level integration-point assignments below remain accurate. Of
note: the should-fix item F4 (multi-stream deadlock) recommends a fix in `Effect.hs` that EP-1
will implement; EP-2's planned multi-stream-error-attribution fix and EP-4's planned schema-name
decision both also touch `Effect.hs`. The three plans must coordinate sequencing on that file —
EP-1 should land first (its fix is mechanical: insert a sorted `SELECT ... FOR UPDATE` pre-pass at
the top of the multi-stream branch), then EP-2 and EP-4 in either order.


## Decision Log

- Decision: Decompose the review into six work streams (Schema/CTE/concurrency, API/types/errors, Subscriptions, Multi-tenancy/security/schema-lifecycle, Operational hardening, Test & benchmark hardening) rather than one monolithic document or one plan per file.
  Rationale: Each stream owns one functional concern of the package and produces an independently verifiable findings-plus-fixes artifact. Splitting by file would fragment cross-cutting concerns (the soft-delete TOCTOU race spans three files); a monolith would not parallelise and would mix binary-correctness findings with operational tradeoffs.
  Date: 2026-04-29

- Decision: No hard dependencies between child plans. Audit milestones can run in parallel against the current working tree; soft dependencies guide ordering of fix milestones.
  Rationale: Audits do not modify code, so they cannot conflict. The integration points section identifies file-level conflicts that fix milestones must coordinate on.
  Date: 2026-04-29

- Decision: Treat `shibuya-kiroku-adapter` as a real-world API consumer for EP-2's ergonomics check, but exclude it from review otherwise.
  Rationale: The user's stated concern is locking in fundamental kiroku-store decisions before *services* depend on it. The adapter is one such consumer; reviewing it as a target would expand scope without changing the decisions that affect future consumers.
  Date: 2026-04-29

- Decision: Each child plan ships its own audit milestone before any fix milestone, even when the must-fix items are already known from initial research (e.g. the soft-delete TOCTOU race in EP-1, the multi-stream error attribution bug in EP-2).
  Rationale: The audit milestone produces a written findings document that becomes the basis for the production-readiness verdict, including the rationale for any deferred items. Skipping the audit and going straight to fixes loses the deferred-items record.
  Date: 2026-04-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original vision.

(To be filled during and after implementation. The final entry must include the production-readiness verdict and the deferred-findings register.)
