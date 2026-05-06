---
id: 7
slug: hot-system-stream-and-skill-installer-workload-audit
title: "Hot system stream and skill-installer workload audit"
kind: exec-plan
created_at: 2026-05-06T20:42:40Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/2-focused-event-store-reliability-and-scale-audit.md"
---

# Hot system stream and skill-installer workload audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan audits hot stream behavior and stream-name edge cases, with special attention to the `skill-installer` stream named by the user. After it is complete, a maintainer can show whether a stream that receives many writes remains ordered, whether reserved-looking stream names behave safely, and whether any naming rule should be enforced before real consumers depend on it.

The practical result is confidence that application streams can be hot without corrupting order, and that system-like streams are either explicitly supported or explicitly rejected.


## Progress

- [ ] Audit stream-name semantics, reserved `$all` behavior, and current tests.
- [ ] Add a `skill-installer` hot-stream workload that verifies per-stream and `$all` order.
- [ ] Decide whether `$all` and other reserved-looking names need validation, documentation, or code-level rejection.
- [ ] Land must-fix tests or code changes.
- [ ] Record the final hot/system stream verdict.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Treat `skill-installer` as a normal event stream name unless the audit finds a code path that requires reserving it.
  Rationale: The schema stores stream names as free-form `TEXT`; only `$all` is currently special because it is seeded as `stream_id = 0`.
  Date: 2026-05-06


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The schema in `kiroku-store/sql/schema.sql` creates `streams.stream_name TEXT NOT NULL` with a unique constraint named `ix_streams_stream_name`. It also inserts a reserved row `(stream_id = 0, stream_name = '$all', stream_version = 0)`. There is no `CHECK` constraint that prevents a caller from using names that start with `$`, contain commas, contain spaces, or equal `$all`. The generated `category` column is `split_part(stream_name, '-', 1)`, so `skill-installer` has category `skill`.

Append behavior is implemented in `kiroku-store/src/Kiroku/Store/SQL.hs` and dispatched from `kiroku-store/src/Kiroku/Store/Effect.hs`. Reads are in `kiroku-store/src/Kiroku/Store/Read.hs`. Stream-name errors are mapped in `kiroku-store/src/Kiroku/Store/Error.hs`, where unique violations on `ix_streams_stream_name` map to `StreamAlreadyExists`.

The NOTIFY trigger in `schema.sql` emits `NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version`. The in-process notifier ignores the payload and treats it as a tick, but an external listener parsing comma-separated payloads could be confused by stream names containing commas. That risk was previously documented in `docs/plans/4-multi-tenancy-security-and-schema-lifecycle-audit.md`; this plan should decide whether it matters for hot/system stream reliability.

Current tests cover ordinary stream names such as `order-123`, `all-s1`, and generated `prop-*` streams. They do not appear to include a dedicated high-write `skill-installer` scenario, nor do they clearly state the contract for attempting to append to `$all` as a user stream.


## Plan of Work

Milestone 1 audits naming behavior. Read `schema.sql`, `SQL.hs`, `Effect.hs`, `Error.hs`, and the stream-name-related tests in `kiroku-store/test/Main.hs`. Test or inspect the behavior for stream names `skill-installer`, `$all`, `$skill-installer`, names containing commas, and names with no dash. Record whether each is supported, rejected, or undocumented.

Milestone 2 adds a hot `skill-installer` workload. Use many concurrent writers against `StreamName "skill-installer"` and verify that exactly the successful writes appear in stream-version order. Use both `AnyVersion` and a realistic optimistic-concurrency pattern if feasible. Also verify that the same events appear in `$all` in global-position order. If the hot stream produces expected `WrongExpectedVersion` failures under `ExactVersion`, count those as successful conflict handling, not ordering failures.

Milestone 3 resolves reserved-name behavior. If appending directly to `$all` can corrupt order, produce confusing errors, or create duplicated `stream_events` rows, make a decision: reject `$all` at the public API/interpreter boundary, add a schema `CHECK`, or document it as reserved and unsupported. Prefer code-level rejection if the current behavior is dangerous or surprising. Include `$skill-installer` in the audit because it is a plausible system stream name but is not the reserved `$all` stream.

Milestone 4 records the stream-name contract in Haddock or docs. If the final contract is "all names except `$all` are ordinary application streams," state that in `Kiroku.Store.Types.StreamName` Haddock and add tests. If the final contract reserves all `$`-prefixed streams for system use, enforce and document that broader rule.


## Concrete Steps

Run the current suite:

    cabal test kiroku-store

Inspect the relevant implementation:

    sed -n '1,180p' kiroku-store/sql/schema.sql
    sed -n '130,360p' kiroku-store/src/Kiroku/Store/SQL.hs
    sed -n '1,220p' kiroku-store/src/Kiroku/Store/Types.hs
    rg -n '"\\$all"|skill-installer|stream_name|StreamName' kiroku-store/test kiroku-store/src docs

Add tests in `kiroku-store/test/Test/Concurrency.hs` for the hot `skill-installer` workload if the test is concurrency-heavy. Add reserved-name API tests in `kiroku-store/test/Main.hs` if they are simple behavioral checks.

Validate:

    cabal test kiroku-store --test-options='--match "skill-installer"'
    cabal test kiroku-store

If a code-level rejection of reserved names is added, run Haddock or the build:

    cabal build kiroku-store


## Validation and Acceptance

Acceptance requires explicit evidence for `StreamName "skill-installer"` under concurrent writes. The test must verify that the stream contains exactly the committed events, stream versions are strictly ascending and gap-free from 1 to N, and the corresponding `$all` entries are globally ordered.

Acceptance also requires an explicit `$all` verdict. Either attempts to append/link/use `$all` as an application stream are rejected with a documented `StoreError` or they are proven safe and documented as supported. Leaving `$all` behavior implicit is not acceptable for this plan.


## Idempotence and Recovery

All tests should use `withTestStore`, so they are safe to rerun. If adding a schema constraint, remember that `schema.sql` is embedded and applied by `withStore`; rerunning tests creates a new database with the changed schema. Avoid migration work in this plan unless a reserved-name constraint is mandatory before production.


## Interfaces and Dependencies

This plan uses existing store APIs from `Kiroku.Store`: `appendToStream`, `appendMultiStream` if needed, `readStreamForward`, `readAllForward`, `getStream`, `runStoreIO`, `StreamName`, `ExpectedVersion`, `StreamVersion`, and `GlobalPosition`.

Coordinate with EP-1 at `docs/plans/8-high-write-append-ordering-and-atomicity-audit.md` for shared concurrency helpers. Coordinate with EP-4 at `docs/plans/10-large-store-read-path-and-index-performance-audit.md` if the `skill-installer` workload should become a benchmark.
