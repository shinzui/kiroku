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
| EP-2 | Public API surface, types and error model audit | docs/plans/2-public-api-surface-types-and-error-model-audit.md | None | EP-1 | Complete |
| EP-3 | Subscription system robustness audit | docs/plans/3-subscription-system-robustness-audit.md | None | EP-1, EP-2 | Complete |
| EP-4 | Multi-tenancy, security and schema lifecycle audit | docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md | None | EP-1 | Complete |
| EP-5 | Operational hardening: observability, failure modes, limits | docs/plans/5-operational-hardening-observability-failure-modes-limits.md | None | EP-1, EP-2, EP-3 | In Progress |
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
- [x] EP-2: M1 — Public API and error model audit findings document (2026-04-29; 34 findings F1–F34: 1 must-fix [F25 `withSubscription` bracket], 11 should-fix including F1 [downgraded from must-fix after reading SQL — buggy in principle but unreachable via current paths] and the Haddock D-series, 7 deferred-with-rationale, 5 cross-plan to EP-3/EP-4/EP-5, 5 no-issue)
- [x] EP-2: M2 — Landed F25 (`withSubscription` bracket — IO + Eff variants), F1 (defensive multi-stream attribution helper), F19/F20/F22 (`StoreError` refinement: `PoolAcquisitionTimeout`/`ConnectionLost`/`UnexpectedServerError` constructors, `DuplicateEvent` takes `Maybe EventId`, derives `Exception`), F18 (`SchemaInitError` re-exported), F26 (`defaultSubscriptionConfig`), D-series Haddocks across `Types.hs`/`Append/Lifecycle/Link/Read.hs`/`Connection.hs`/`Effect/Resource.hs`/`Subscription/Effect.hs`. 7 items deferred-with-rationale. 73/73 tests pass; reads/appends behave identically (no functional regressions). (commits 323cf0f, 4d994eb, 971a307, 6a3f35d, 6b3903c, plus b159d0c reclassification and 9bd82a1 adapter hotfix)
- [x] EP-3: M1 — Subscription robustness audit findings document (2026-04-29; 30 findings F1–F30: 3 must-fix [F1 listener leak on reconnect, F6 unbounded broadcast, F18 Category live-mode filter] + at-least-once Haddock contract; 8 should-fix [4 cross-plan to EP-5, 4 deferred-with-rationale]; 2 cross-plan to EP-2/EP-6; remainder no-issue)
- [x] EP-3: M2 — Landed F1 (listener-conn leak), F18 (Category live filter via DB-driven loop), F6 (bounded per-subscriber backpressure with OverflowPolicy), at-least-once Haddock contract; deferred F2, F3, F7, F8, F12, F13, F29, F30 with rationale. 76/76 kiroku-store tests pass; 5/5 adapter tests pass; Haddock builds clean. (commits 6041e8f, bd107d4, 2c3f3f4, fe69688)
- [x] EP-4: M1 — Multi-tenancy, security, schema lifecycle audit findings document (2026-04-29; 18 findings F1–F18: schema field is plumbed-but-inert at the SQL layer with two layers of dead plumbing in `Worker.hs` and `Schema.hs` [F1, must-fix to land Haddock + dead-code removal in M2, ties EP-2.F14]; listener/trigger schema-name coupling is implicit and silently breaks under non-default `schema` [F2, must-document]; hard-delete is footgun-protection rather than a security boundary [F5, must-document via Lifecycle Haddock]; `initializeSchema` is idempotent only for additive DDL [F7, must-document, aligns with the existing `project_schema_migration.md` memory note]; DDL execution privilege requirement is undocumented [F9, must-document via a Production Deployment doc]; TRUNCATE bypass already closed by EP-1.F6 [F15, confirmation]; connection-string and prepared-statement audit returned no SQL-injection vectors [F10/F11/F12/F14, no-issue]; tenant lifecycle, hard-delete audit log, NOTIFY-payload JSON encoding, partition-trigger semantics are deferred-with-rationale [F4/F6/F13/F16])
- [x] EP-4: M2 — Landed F1/F18 (rewrote `Connection.hs:34` Haddock to name the actual schema-field contract; removed the dead `schema :: Text` parameter from `Worker.runWorker`/`catchUp`/`liveLoopCategoryDriven`/`fetchBatch` and the `Subscription.hs:107` call site), F5 (Lifecycle Haddock with advisory-not-security framing for hard-delete authorization, audit-log gap, three production tightening patterns), F7 (Schema.hs Haddock with additive-only DDL contract + privilege requirements, references parked partition plan + `project_schema_migration.md`), F9 (`docs/PRODUCTION-DEPLOYMENT.md` aggregating DDL/runtime privilege separation, hard-delete authorization, schema migration, connection-string handling, at-rest encryption, multi-tenant pattern, observability, PostgreSQL 18+ requirement); deferred F4, F6, F13, F16 with rationale + the option-A schema-prefixing rejection. 76/76 kiroku-store tests pass; 5/5 adapter tests pass; Haddock builds clean. (commits 9f344bc, 8470f36, 9db5a7f)
- [x] EP-5: M1 — Failure-mode and observability gap inventory (2026-04-29; 18 findings F1–F18: 5 must-fix [F1 Notifier-reconnect signal, F2 publisher pool-error swallow, F3/F4/F5 Worker checkpoint/fetch/save silent failures]; 7 should-fix [F6 structured NotifierStartError, F7 exponential reconnect backoff, F8 statementTimeout field, F13 hard-delete observation event, F14 subscription-lifecycle events, F16 PRODUCTION-TUNING.md]; 6 deferred-with-rationale [F9 acquisition-timeout exposure, F10 internal tunables, F11 queueCapacity guidance folds into F16, F12 publisher pool isolation, F15 schema-init events, F17 per-statement latency]; F18 cross-plan to EP-6)
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

### EP-2 audit (2026-04-29) — cross-plan findings

EP-2 Milestone 1 produced 34 findings (F1–F34, EP-2 numbering — distinct from EP-1's F1–F21).
Five items are cross-plan and recorded here for traceability. Full details and severity
classification live in EP-2's Surprises & Discoveries section
(`docs/plans/2-public-api-surface-types-and-error-model-audit.md`).

  * **EP-2.F14 → EP-4.** `ConnectionSettings.schema` (`Connection.hs:34-35`) is consumed by the
    Notifier (it builds the LISTEN channel name `<schema>.events`) but ignored by every SQL
    statement in `SQL.hs` (all references unqualified table names). Multi-tenant isolation is
    impossible. EP-4 owns the decision to either wire the schema through SQL statements or
    remove the field. EP-2 will not touch this in M2.

  * **EP-2.F15 → EP-5.** `defaultConnectionSettings` sets `idle_in_transaction_session_timeout`
    via the pool's `initSession` but does not set `statement_timeout`. A runaway query holds a
    pool slot indefinitely. EP-5 owns operational tuning of session-level Postgres GUCs.

  * **EP-2.F18 → EP-4 coordination.** `kiroku-store.cabal` lists `Kiroku.Store.Schema` and
    `Kiroku.Store.Notification` as `exposed-modules` but `Kiroku.Store` does not re-export them.
    Consumers that want to catch `SchemaInitError` must import `Kiroku.Store.Schema` directly,
    leaking an internal module name. EP-2 plans to re-export `SchemaInitError` from
    `Kiroku.Store` in M2; if EP-4's schema-lifecycle work moves the type or replaces it with a
    multi-tenant equivalent, the two plans must coordinate in `Connection.hs` / `Schema.hs`.

  * **EP-2.F25 → EP-3 coordination.** The missing `withSubscription` bracket
    (`Subscription.hs`, `Subscription/Effect.hs`) is must-fix and EP-2 will land it in M2. The
    new helper takes the same `SubscriptionConfig` and returns the same `SubscriptionHandle`,
    so the surface change is additive. EP-3 (subscription robustness) should adopt the bracket
    in any tests it writes and is the natural home for the lifecycle-failure semantics
    (handler crash, worker crash, cancel-while-handling-batch).

  * **EP-2.F27 → EP-3.** `subscriptionStream` returns the cancel action but discards the
    `wait :: Either SomeException ()` half of the `SubscriptionHandle`. If the underlying
    worker crashes the Streamly stream hangs on an empty queue with no observable error. EP-3
    owns subscription robustness; the fix is in `Subscription/Stream.hs` and likely involves
    threading the `wait`-style observer through the stream's termination signal.

EP-2 explicitly *does not* introduce a new constructor for the F11/F23 idempotent-retry case
(`ExactVersion` retry collides with `WrongExpectedVersion` instead of `DuplicateEvent`). The
recovery is the same in both cases (re-read and decide), so a Haddock note on `appendToStream`
is the right intervention. This decision overrides MasterPlan's earlier "F11 → EP-2 should
decide whether to distinguish" prompt.

### EP-3 audit (2026-04-29) — cross-plan findings

EP-3 Milestone 1 produced 30 findings (F1–F30, EP-3 numbering — distinct from EP-1 and EP-2).
Four items are cross-plan and recorded here for traceability. Full details and severity
classification live in EP-3's Surprises & Discoveries section
(`docs/plans/3-subscription-system-robustness-audit.md`).

  * **EP-3.F3 → EP-5.** `Notification.hs:67-79` listener reconnect loop has no
    observability hook; operators have no signal that the listener crashed and
    reconnected. Cross-plan: EP-5 owns the observation-handler enrichment.
    Bundled with F2 (listener dies on reacquire failure) — both fixes naturally
    land together as a single retry-with-backoff-plus-observation change.

  * **EP-3.F7 / F12 → EP-5.** `EventPublisher.hs:104-110` swallows pool errors
    silently; the publisher uses the application pool which means pool
    exhaustion can stall progress. Both gaps surface to operators only via the
    30-second safety poll's eventual recovery. EP-5 owns the unified
    observation-handler enrichment (publisher pool errors, publisher
    queue-depth metric).

  * **EP-3.F13 → EP-5.** `Worker.hs:43-49` `loadCheckpoint` swallows DB errors
    and returns `GlobalPosition 0`, silently re-processing every event. The
    correctness impact is bounded by at-least-once handlers being idempotent,
    but the observability impact is poor. Routed to EP-5 as part of the
    structured-logging pass.

  * **EP-3.F30 → EP-6.** `kiroku-store/test/Main.hs:716-990` existing
    subscription tests rely on `threadDelay` for synchronisation. EP-3 M2 adds
    new regression tests using deterministic STM/`MVar` barriers but does
    *not* refactor the existing tests; EP-6 owns the suite restructure and
    will convert them in one pass to avoid mixing styles.

EP-3 explicitly *does not* extend `RecordedEvent` with a `category` field as the
MasterPlan's initial decomposition contemplated. The chosen fix for the Category
live-mode filter (a DB-driven loop bypassing the broadcast) reuses the existing
`readCategoryForwardStmt` and avoids changing the public type owned by EP-2.
This decision overrides the MasterPlan's earlier "RecordedEvent shape change
crosses EP-2" prompt.

### EP-4 audit (2026-04-29) — cross-plan findings

EP-4 Milestone 1 produced 18 findings (F1–F18, EP-4 numbering — distinct from
EP-1, EP-2, and EP-3). Two items are cross-plan and recorded here for
traceability. Full details and severity classification live in EP-4's Surprises
& Discoveries section
(`docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md`).

  * **EP-4.F1 / F18 ↔ EP-2.F14.** `ConnectionSettings.schema` is plumbed but
    inert at the SQL layer: `SQL.hs` references all tables unqualified, and
    the `schema` parameter is also threaded dead through
    `Subscription.hs:107` → `Worker.hs:41,82,139,162` (where `fetchBatch`'s
    body never references it) and `Schema.hs:27` (where it is bound as
    `_schema`). EP-4 owns the resolution and adopts option (C) — document the
    actual contract (the LISTEN channel name only), remove the dead
    plumbing, and rewrite the `Connection.hs:35` Haddock. EP-2's earlier
    `EP-2.F14 → EP-4` route is now resolved here in M2; EP-2 will not need
    to revisit `Connection.hs`.

  * **EP-4.F6 → EP-5.** Hard-delete emits no in-band audit row. The current
    `hardDeleteStream` removes junctions, orphan events, and the stream row
    but records nothing on `$all`. Recommend EP-5 surface hard-deletes via
    the observation handler at minimum; an in-band `kiroku.HardDeleted`
    event on `$all` (or a dedicated audit stream) would also need a public
    API change cross-plan to EP-2 (a `reason` argument). Routed to EP-5 for
    operational-hardening prioritisation.

EP-4 explicitly *does not* implement schema-prefixed SQL (option A) or remove
the `schema` field (option B). The DESIGN.md aspiration "schema-per-tenant from
Phase 1, parameterize all SQL with schema prefix" remains documentation-only;
when a real multi-tenant deployment requirement appears, option (A) becomes
the right next step and the field is already in place. This decision overrides
the MasterPlan's earlier "EP-4 owns the schema-name decision (either remove the
field or wire it through)" framing in the Integration Points section — the
third option (document the actual contract) was not enumerated there but is
documented in EP-4's Decision Log.

### EP-5 audit (2026-04-29) — cross-plan findings

EP-5 Milestone 1 produced 18 findings (F1–F18, EP-5 numbering — distinct from
EP-1, EP-2, EP-3, and EP-4). Three items are cross-plan and recorded here for
traceability. Full details and severity classification live in EP-5's
Surprises & Discoveries section
(`docs/plans/5-operational-hardening-observability-failure-modes-limits.md`).

  * **EP-5.F13 ↔ EP-4.F6.** Hard-delete observability event closes the
    audit-log gap EP-4 documented in `docs/PRODUCTION-DEPLOYMENT.md`. EP-5
    surfaces the event through its new `eventHandler` callback so operators
    with a structured log can reconstruct hard-deletes without an
    application-level event being mandatory. EP-4's recommendation that
    compliance-grade audit still be application-level (recorded *before*
    `hardDeleteStream` is called) remains in force; the observation event is
    a fail-safe, not a substitute. No code changes to `Lifecycle.hs` or
    `PRODUCTION-DEPLOYMENT.md`'s authorization framing required from EP-5 —
    only the new emit site in `Effect.hs`.

  * **EP-5.F1/F2/F3/F4/F5 ↔ EP-3.F3/F7/F12/F13.** EP-3 routed four
    silent-failure findings to EP-5 for the unified observation surface.
    EP-5's audit confirms five must-fix sites (EP-3 routed four; EP-5's audit
    surfaced an additional one in `Worker.fetchBatch` that EP-3 did not
    explicitly enumerate). All five resolve through the same change in M2:
    introducing `KirokuEvent` and emitting structured events at every site
    that currently swallows a `Left _err`. The fixes do not modify the
    behaviour of those code paths (failures still degrade gracefully —
    notifier reconnects, publisher waits, worker uses safe defaults); they
    only add a side-channel signal.

  * **EP-5.F18 → EP-6.** `test/Main.hs` subscription tests still mix
    `threadDelay` synchronisation with the deterministic STM/`MVar` style
    EP-3 introduced. EP-5's M2 failure-injection regression tests use the
    deterministic style; the suite-wide restructure to eliminate
    `threadDelay` from older tests remains owned by EP-6 (consistent with
    EP-3.F30's earlier route).

EP-5 explicitly *does not* extend `kiroku-store`'s `cabal` build with a new
external dependency for metrics or logging. The `KirokuEvent` callback is the
extension point; callers wire `prometheus-client`, `ekg-core`, `katip`,
`co-log`, etc., themselves. This continues the pattern established by the
existing `observationHandler` field.


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
