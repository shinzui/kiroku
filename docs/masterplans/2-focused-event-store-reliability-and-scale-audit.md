---
id: 2
slug: focused-event-store-reliability-and-scale-audit
title: "Focused Event Store Reliability and Scale Audit"
kind: master-plan
created_at: 2026-05-06T20:42:31Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
---

# Focused Event Store Reliability and Scale Audit

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

This initiative is a focused follow-up to the completed production-readiness review in `docs/masterplans/1-production-readiness-review-of-kiroku-store.md`. The store is still a work in progress, and the goal here is narrower than another broad review: prove that event ordering remains reliable under high write pressure, prove that hot or system-like streams such as the `skill-installer` stream do not expose hidden ordering bugs, and identify performance red flags before the store grows from test-sized databases to large production tables.

After this initiative is complete, `kiroku-store` has evidence-backed answers to four questions. First, do all append paths preserve per-stream order, `$all` global order, and all-or-nothing atomicity under many concurrent writers? Second, do hot stream names, reserved-looking stream names, and the specific `skill-installer` workload behave predictably? Third, do subscriptions consume the ordered `$all` sequence without gaps, duplicates beyond the documented at-least-once contract, or checkpoint regressions while writes are ongoing? Fourth, do the main read paths, indexes, benchmarks, and operational notes reveal any scaling bottlenecks that would get worse as `events` and `stream_events` grow?

In scope: all event-store code under `kiroku-store/`, including `sql/schema.sql`, `src/Kiroku/Store/SQL.hs`, `src/Kiroku/Store/Effect.hs`, subscription modules, tests, benchmarks, and the existing scaling and tuning docs. The `shibuya-kiroku-adapter` package is in scope only as a consumer if a public contract change affects subscription or stream behavior. Out of scope: replacing Strategy E with another global-ordering design, implementing tenant partitioning, or building an application-level skill installer. This work may add tests, benchmarks, documentation, and targeted correctness fixes if the audits find must-fix issues.


## Decomposition Strategy

The work is decomposed by reliability concern rather than by file. EP-1 owns the append SQL invariants that create order. EP-2 owns hot/system stream behavior, including the user-called-out `skill-installer` stream and reserved `$all` edge cases. EP-3 owns downstream delivery of the ordered stream through subscriptions and checkpoints. EP-4 owns growth and performance, including query plans, benchmark coverage, and scaling documentation.

This split keeps each child plan independently verifiable: EP-1 can prove append ordering with stress tests, EP-2 can prove specific stream-name and hot-stream behavior, EP-3 can prove subscriber catch-up/live ordering, and EP-4 can prove read-path and benchmark health. The plans share code, but their acceptance criteria differ enough that combining them would produce an unfocused audit.

Alternatives considered. Extending the completed production-readiness MasterPlan was rejected because that initiative is already complete and broad; this audit has a new, focused acceptance standard. A single child ExecPlan was rejected because high-write append correctness, hot-stream behavior, subscription delivery, and scaling risk each need different test harnesses and evidence. Splitting by module was rejected because the same reliability invariant crosses `schema.sql`, `SQL.hs`, `Effect.hs`, `Test.Concurrency`, and benchmark code.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | High-write append ordering and atomicity audit | docs/plans/8-high-write-append-ordering-and-atomicity-audit.md | None | None | Complete |
| EP-2 | Hot system stream and skill-installer workload audit | docs/plans/7-hot-system-stream-and-skill-installer-workload-audit.md | None | EP-1 | Complete |
| EP-3 | Subscription ordering catch-up and checkpoint reliability audit | docs/plans/9-subscription-ordering-catch-up-and-checkpoint-reliability-audit.md | None | EP-1, EP-2 | Complete |
| EP-4 | Large-store read path and index performance audit | docs/plans/10-large-store-read-path-and-index-performance-audit.md | None | EP-1, EP-2, EP-3 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

There are no hard dependencies because every child plan can begin by auditing the current working tree. EP-1 is the natural first plan because it validates the write-side invariants that every other plan depends on: stream versions, global positions, row-lock behavior, and transaction atomicity. EP-2 soft-depends on EP-1 because a hot `skill-installer` stream test should reuse any stress harness or invariant checker EP-1 adds, but it can independently audit stream-name semantics and reserved-name behavior.

EP-3 soft-depends on EP-1 and EP-2 because subscriptions consume `$all`, and any discovered stream-name or hot-stream issue may affect subscription target naming and checkpoint tests. EP-3 can still start by reading the existing subscription implementation and tests. EP-4 soft-depends on all prior plans because performance gates should include the scenarios that proved correctness. It can begin with query-plan research and benchmark inventory, but final acceptance should incorporate any new high-write, hot-stream, or subscription tests.

Plans that can proceed in parallel: EP-1 and EP-2 can run their audit milestones at the same time if they do not edit `Test.Concurrency` concurrently. EP-3 can do read-only research in parallel with both. EP-4 can do documentation and query-plan inventory in parallel, but benchmark edits should wait until EP-1 and EP-2 decide which stress scenarios become permanent.


## Integration Points

`kiroku-store/src/Kiroku/Store/SQL.hs` is shared by EP-1, EP-2, and EP-4. EP-1 owns append CTE semantics. EP-2 may request changes if reserved/system stream names need explicit rejection or documentation. EP-4 may add `EXPLAIN` helper SQL or benchmark statements but should not alter append behavior unless a performance finding becomes a correctness fix.

`kiroku-store/src/Kiroku/Store/Effect.hs` is shared by EP-1 and EP-2. EP-1 owns interpreter behavior for `AppendToStream` and `AppendMultiStream`, including pre-locking. EP-2 owns any validation or documentation around special stream names such as `$all` and `skill-installer`.

`kiroku-store/sql/schema.sql` is shared by all plans. EP-1 owns constraints that protect ordering and atomicity. EP-2 owns any schema-level reserved-name decision. EP-4 owns index and maintenance findings, especially risks around `ix_stream_events_stream_version`, `ix_stream_events_all_by_origin`, and `streams` autovacuum pressure.

`kiroku-store/test/Test/Concurrency.hs`, `kiroku-store/test/Test/Properties.hs`, and `kiroku-store/test/Main.hs` are shared test surfaces. EP-1 owns high-write append stress tests. EP-2 owns hot/system stream tests. EP-3 owns subscription ordering and checkpoint tests. EP-4 may refactor benchmark-related helpers only after the correctness tests have landed.

`kiroku-store/bench/Main.hs`, `kiroku-store/bench/results/baseline.csv`, `docs/BENCH-REGRESSION.md`, `docs/SCALING-ANALYSIS.md`, and `docs/PRODUCTION-TUNING.md` are shared by EP-4 and referenced by the other plans. EP-4 owns benchmark gates and documentation updates.


## Progress

- [x] EP-1: Audit append CTE and interpreter ordering invariants under concurrent writes.
- [x] EP-1: Land must-fix ordering tests or code changes and record the verdict.
- [x] EP-2: Audit hot/system stream names, including `skill-installer` and `$all`.
- [x] EP-2: Land reserved-name or hot-stream fixes, tests, and documentation if needed.
- [x] EP-3: Audit subscription catch-up, live delivery, and checkpoint ordering under write pressure.
- [x] EP-3: Land subscription reliability tests or fixes and record delivery-contract verdict.
- [x] EP-4: Audit query plans, benchmark coverage, and large-store performance red flags.
- [x] EP-4: Land benchmark/doc updates and final growth-risk verdict.


## Surprises & Discoveries

- EP-1 found no must-fix append SQL or interpreter correctness issue. The permanent change is regression coverage in `kiroku-store/test/Test/Concurrency.hs` proving contiguous per-stream versions, contiguous `$all` positions, overlapping `appendMultiStream` ordering, and duplicate-event rollback under high-write scenarios. Focused validation passed with 8 concurrency examples and full validation passed with 91 examples.
  Date: 2026-05-06

- EP-2 found that `$all` needed an explicit public mutation guard because it is the seeded global stream row. The final contract reserves only the exact `$all` name; `skill-installer`, `$skill-installer`, comma-containing names, and no-dash names remain ordinary application streams. Validation passed with 1 focused `skill-installer` stress example, 5 stream-name contract examples, and the full 97-example `kiroku-store` suite.
  Date: 2026-05-06

- EP-3 found one must-fix subscription transition issue: all-stream subscribers register their live queue before catch-up, so writes during catch-up could be fetched from SQL and later replayed from the queued live batch. The fix filters live batches to positions greater than the worker cursor and makes checkpoint upserts monotonic with `GREATEST`. New tests cover catch-up/live transition under writes, cancellation replay, handler `Stop` boundaries, overflow restart replay, and mixed `skill-installer` category ordering. Validation passed with 14 focused subscription examples and the full 101-example `kiroku-store` suite.
  Date: 2026-05-06

- EP-4 found one must-fix performance issue: the Haskell category read query had drifted from the SQL benchmark's LATERAL partial-index shape and could scan the rest of `$all` when a category had no events after a high cursor. The fix restores the LATERAL shape, which uses `ix_stream_events_all_by_origin` per category stream. New benchmark gates cover exhausted-category reads, hot `skill-installer` appends, `appendMultiStream`, and subscription category catch-up. Validation passed with the full 101-example `kiroku-store` suite, a refreshed 15-entry benchmark baseline, `just bench-regression-pattern category`, and `just bench-regression-pattern reliability-audit`.
  Date: 2026-05-06


## Decision Log

- Decision: Create a focused follow-up MasterPlan instead of reopening the completed production-readiness MasterPlan.
  Rationale: The earlier plan is complete and broad; this request is specifically about event-store ordering reliability under high write pressure, the `skill-installer` stream, and growth-related performance risk.
  Date: 2026-05-06

- Decision: Treat `skill-installer` as a concrete stream/workload name in EP-2, not as a request to install a Codex skill.
  Rationale: The user mentioned it in the context of event-store stream ordering. The `skill-installer` skill itself is already installed as a system skill and is unrelated to the event-store code.
  Date: 2026-05-06

- Decision: Keep hard dependencies empty and model all ordering as soft dependencies.
  Rationale: Each audit can begin against the current working tree. The plans should share findings, but no plan needs another plan's new code to compile before it can start.
  Date: 2026-05-06

- Decision: EP-2 reserves only the exact `$all` stream name and enforces it in the interpreter instead of schema DDL.
  Rationale: The seeded `$all` row is the only name with special ordering semantics. Interpreter-level rejection returns a domain `StoreError`, avoids a migration, and leaves `$`-prefixed application/system streams such as `$skill-installer` usable.
  Date: 2026-05-06

- Decision: EP-3 keeps the live publisher queue registered before catch-up and filters stale all-stream live batches in the worker.
  Rationale: Early registration avoids missing live notifications while catch-up is running. Cursor-based filtering prevents duplicate handler delivery and protects checkpoint ordering without redesigning publisher lifecycle.
  Date: 2026-05-06

- Decision: EP-4 accepts the LATERAL category read query and refreshed benchmark baseline.
  Rationale: The normal category page remains about 1 ms, while the high-cursor exhausted-category case is guarded at tens of microseconds instead of scanning a large `$all` suffix. This is the right scale tradeoff for category subscriptions and projection catch-up.
  Date: 2026-05-06


## Outcomes & Retrospective

Completed 2026-05-06. The initiative proved append ordering, hot/system stream behavior, subscription delivery, and large-store read paths with targeted tests, query plans, benchmark gates, and documentation updates. The store now explicitly rejects application mutation of `$all`, filters stale all-stream live subscription batches after catch-up, saves checkpoints monotonically, uses an index-friendly category read shape, and carries benchmark guards for the scenarios that motivated this audit.

Residual risks remain operational rather than immediate correctness blockers: `$all` row lock contention under high write concurrency, category cardinality for very broad categories, autovacuum pressure on the hot `streams` row, index bloat after hard deletes, and backup/restore time for large databases. These are documented in `docs/SCALING-ANALYSIS.md`, `docs/PRODUCTION-TUNING.md`, and `docs/BENCH-REGRESSION.md`.
