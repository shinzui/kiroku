---
id: 97
slug: expose-stream-head-global-position-through-an-opt-in-metadata-read
title: "Expose stream head global position through an opt-in metadata read"
kind: exec-plan
created_at: 2026-10-11T02:39:49Z
intention: "intention_01m4md6pjse09s59yrm7wvhwdc"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-11T02:39:49Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T02:44:04Z
      mode: "other"
      note: "Completed initial IR-18 plan with API semantics and focused performance acceptance"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-11T04:18:09Z
      mode: "implement"
      note: "Implement opt-in stream heads and focused compatibility and cost evidence"
---

# Expose stream head global position through an opt-in metadata read


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current during implementation. Distill
project-level decisions into `docs/adr/` before completion. This plan implements
[IR-18](../improvement-requests/expose-a-streams-head-global-position-from-getstream.md).


## Purpose / Big Picture


Expose `getStreamWithHead`, a public, mockable read that returns a stream's metadata
and newest surviving originated event's global position in one database statement.
A consumer of an origin-only stream with retained history can capture both, check
that the stream version has reached a requested version, and wait for its projection
cursor to reach that head. It needs no category-wide proxy or extra metadata/head
round trip. Kiroku supplies the observation; the consumer owns waiting and timeouts.

Performance preservation is a delivery requirement. Existing `getStream`, event
reads, and append/link operations must acquire no extra SQL, columns, decoding,
connection checkouts, schema maintenance, or database work. Only the new opt-in
operation pays for one indexed head probe. The request already measured additional
SQL cost of approximately 20–33% compared with metadata alone; those preliminary
numbers justify isolation, not an application-level performance claim. Completion
requires deterministic isolation checks, bounded query work, and a focused comparison
through the real public runner. It does not promise unchanged latency under arbitrary
additional read traffic competing for the same database resources.


## Progress


- [x] (2026-10-11 04:21Z) Milestone 1: freeze legacy SQL and runner, validate baseline, and seed shared fixture.
- [x] (2026-10-11 04:24Z) Implemented the public read and lifecycle/mock/snapshot tests; 26 focused checks pass.
- [x] (2026-10-11 04:30Z) Milestone 2 integration: full build and all 474 store tests pass.
- [x] (2026-10-11 04:24Z) Milestone 3 structural evidence: all eight natural literal/prepared plans pass bounded origin probes.
- [x] (2026-10-11 04:59Z) Milestone 3 focused timing: verified two six-case remote trials and recorded opt-in costs for both sizes; every cell met 5% relative deviation.
- [x] (2026-10-11 05:02Z) Milestone 3 integration: all 16 remote append/category workload cases pass with required precision; sealed result and owned-lease release verified.
- [ ] Milestone 3 performance acceptance: legacy metadata timing is inconclusive because the 100,000-event ratio failed at 1.17 and passed at 1.00 on the unchanged repeat.
- [x] (2026-10-11 04:41Z) Milestone 4 implementation: Haddocks, guide and changelog complete; ADR-19 and IR-18 bundles validate strictly; Haddock generation passes.
- [x] (2026-10-11 05:03Z) Final evidence/retrospective recorded; all four remote runs verified, all owned leases released, alpha instances independently confirmed TERMINATED.


## Surprises & Discoveries


2026-10-11: Remote preparation found an outdated `cellctl` binary and an ambient GCP project mismatch. Rebuilt the CLI from the registered infrastructure source and scoped subprocesses to the intended project. The rejected document executed no remote trial. The owned lease was released and all four instances reached TERMINATED. Before the resumed proof could acquire a lease, `kiroku-mp13` acquired alpha for inspection validation. No other-owner lease was touched. Alpha subsequently became available; the small proof completed on PostgreSQL 18.3 with a verified sealed manifest, 4.95% relative standard deviation and verified owned-lease release. The first six-case comparison met the 5% precision target but failed the 100,000-event metadata ratio (1.17 versus the 1.10 limit); the 100-event ratio passed at 0.94. The unchanged remote repeat passed at 0.95 and 1.00; both trials met the precision target. Their conflict makes metadata performance acceptance inconclusive under the predeclared policy. No third head trial is justified merely to seek a favorable result. All three sealed runs (including proof) and owned-lease releases are verified; the workload gate subsequently passed all 16 cases with required precision and verified lease release.

2026-10-11: Initial focused test compilation found an ambiguous `wait` import; qualifying Async fixed it. All 26 focused examples then passed.

2026-10-11: Cabal runs benchmarks from the package directory; a relative CSV destination failed before measurement. Retained `baseline-cost.log`; the absolute-path retry completed all four cells in 14.69 seconds. Reported uncertainty is twice standard deviation; all cells met the 5% target. Baseline legacy ratios were 0.99 for both sizes.


## Decision Log


2026-10-10: Use the opt-in tuple API requested by IR-18. Preserve `StreamInfo` and
ordinary `getStream` in full. Adding a nullable field to every metadata read would
charge all callers for the already measured extra work; a separate head-only API
would not provide metadata and head from one snapshot.

2026-10-10: Define the head uniformly as an originated-event head. `$all` returns
its existing metadata paired with `Nothing`, even when other streams have events.
It is a reserved aggregation stream, not an event origin. Do not special-case it
into a store-wide head; `visibleGlobalHeadPosition` already supplies that operation.
This preserves the distinction between stream existence and absence of an originated
head and avoids adding a new error case or another database query.

2026-10-10: Reuse the existing partial origin index. No migration, trigger, stored
head column, new index, event payload read, or write-path edit is needed. Preserve
logical deletion/truncation behavior and document that physical removal can make an
observed head disappear.

2026-10-10: Use four implementation milestones and the minimum relevant performance
evidence: existing tests, deterministic structural checks, and six focused timing
cells on one PostgreSQL server. Run existing authoritative gate coverage once for integration.
Do not schedule a remote experiment, broad configuration matrix, or new statistics
framework for this read-only addition. Expand only for a named unresolved risk or
consistent adverse signal, within one 60-minute experiment budget.

2026-10-11: The user explicitly authorized moving timing to the existing remote cell infrastructure after reporting local contention. The local candidate timing command was interrupted before measurement; its log and stage record remain. Reuse the original experiment deadline, the exact benchmark actions and thresholds, and a cell-only database-lifecycle adapter. Remote work uses `mori://shinzui/load-testing-infra` and its project-relative `scripts/cell/` lifecycle tools (artifact-level URI pending), with a sealed small proof before expansion. The six head cells and unchanged append/category workload gate are the only timing scope. Because `just perf-check` combines structural tests already passed in the full suite with a local timing invocation, run its unchanged `RegressionGate.hs` actions on the cell and reuse the complete local structural evidence. Do not rerun its timing half on the busy local host.

2026-10-11: The user reports the machine is very busy. Initially limit local work to one candidate diagnostic timing invocation and one aggregate gate invocation; do not perform the quiet-host retry policy on a host known to be busy. Retain any timing failure/noise as inconclusive acceptance without weakening thresholds. A clean quiet-host timing run can be deferred if needed; functional and structural completion remain separate.

2026-10-11: The implementation keeps all twelve protected production SQL texts byte-identical and leaves both decoder bodies, legacy handlers, StreamInfo and migrations unchanged. Use Cabal data-files plus its generated Paths module for working-directory-independent frozen fixtures. The full local package build passes with the new effect constructor.

2026-10-10: Create and associate the intention using the user's requested
`mina ci --json` command. Its returned identifier is in the generated frontmatter.
Do not create another intention when resuming this plan.


## Outcomes & Retrospective


Milestone 1 baseline at `109d58f57dbd5757ad55792474d046a37cc2e87d`: 448 existing tests and 13 frozen SQL/column checks passed. Four metadata timing cells passed, with raw evidence in `docs/bench/stream-head/2026-10-11-ep97/`. The additive API and nine lifecycle/mock/snapshot examples now pass; all 26 focused examples include frozen SQL and four literal/prepared plan checks. Full local integration passes (474 store tests, all-package build and Haddocks). Candidate source is committed as `daae3f1ab6b27f8de5d1ba2deed1c3fd5a65e16a`. Two six-case remote trials on PostgreSQL 18.3 measured opt-in reads at approximately 168–198 microseconds per call. The 100-event legacy metadata ratio passed in both (0.94 and 0.95), while the 100,000-event ratio conflicted (1.17 then 1.00). Every timing cell met the 5% deviation target, but this conflict leaves performance acceptance inconclusive; it does not undo functional or structural completion. The unchanged append/category workload gate passed all 16 cases with required precision. The local full suite covers the aggregate structural checks, so its full coverage is satisfied without timing on the busy local machine. Full strict bundle validation passes (19 ADR and 18 IR concepts). Four remote sealed runs and all owned-lease releases are verified; alpha is independently confirmed fully TERMINATED with no active lease. The full experiment ended after 44.95 minutes within its original 60-minute budget. Evidence is retained under `docs/bench/stream-head/2026-10-11-ep97/`. Functional delivery is complete; the plan remains open solely for legacy metadata performance acceptance. ADR-19 records the durable API/snapshot decision. No release or dependency-version change was made.


## Context and Orientation


The research baseline is commit `ac1d65504f88d86fba9eb4dee0f5abedfa30afa1`.
The repository is a multi-package Haskell project; `cabal.project` selects GHC 9.12.4
and includes the store, migrations, test support, CLI, metrics, adapters, and examples.
Use the current branch. Preserve unrelated changes and inspect the working tree
before capturing the implementation baseline.

A stream version is the position/count within one stream; appends and links into
that stream advance it. A global position is the position allocated to an original
append in the reserved `$all` stream. The append frontier is the highest allocated
position, stored on `$all`'s metadata row. The visible head is instead the greatest
position still present in its junction rows, and can regress after hard deletion.
A projection cursor records how far a consumer has processed that global sequence.
An originated event was appended to the named stream itself; a linked event was
originally appended elsewhere and subsequently referenced by this stream.

`kiroku-store/src/Kiroku/Store/Read.hs` supplies small public functions that send
constructors of the mockable `Store` effect, defined in
`kiroku-store/src/Kiroku/Store/Effect.hs`. Its `runStorePool` interpreter handles
`GetStream` using one `usePool` and one `Session.statement` call. `runStoreIO` wraps
that interpreter in the error runner; `runStoreResource` obtains the store resource
and delegates to the same interpreter. They do not require independent SQL handlers.
`kiroku-store/src/Kiroku/Store.hs` re-exports the entire Read module, so the new
Read export reaches the umbrella API automatically.

`kiroku-store/src/Kiroku/Store/SQL.hs` owns `getStreamStmt`, `getStreamSQL`, and
`streamInfoRow`. The statement reads six metadata columns from `streams` by name,
including soft-deleted rows. `streamInfoRow` decodes the unchanged `StreamInfo`
record from `kiroku-store/src/Kiroku/Store/Types.hs`. Ordinary stream event reads
currently return zero in `RecordedEvent.globalPosition`; do not add their missing
`$all` join as part of this request. Global/category reads use the shared
`recordedEventRow` decoder. These existing statements and decoders are protected.

`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql` creates
`ix_stream_events_all_by_origin (original_stream_id, stream_version) WHERE stream_id = 0`.
Each originated event has one `$all` junction row. Looking backward in this index for
one origin and stopping at one row finds its head without reading `events` or any
JSON payload. Migration 0012 retained this index while introducing a separate
category index. No migration files should change for this feature.

A PostgreSQL statement reads one MVCC snapshot: the committed database state visible
to that statement. Selecting metadata and the correlated head within the same
statement makes the two observations consistent with each other. Two statements in
an ordinary READ COMMITTED transaction may see different snapshots; composing
`getStream` with a second query is not an implementation of this contract.

`kiroku-store/test/Test/VisibleGlobalHeadPosition.hs` demonstrates lifecycle and
failing-decode-hook tests and both public runners. Its sibling
`kiroku-store/test/Test/VisibleGlobalHeadPositionMock.hs` demonstrates a mock effect
interpreter. `kiroku-store/test/Test/Helpers.hs` supplies `withTestStore`,
`withTestStoreSettings`, and `makeEvent`. The store tests share an ephemeral
PostgreSQL server and use isolated migrated databases through
`kiroku-test-support/src/Kiroku/Test/Postgres.hs`. A PostgreSQL server executable
must be on PATH. No application database is needed.

`kiroku-store/test/Test/PerformanceStructure.hs` already extracts actual production
SQL with `Hasql.Statement.toSql`, executes JSON EXPLAIN plans, walks index/node
names, and counts shared buffers. `kiroku-store/test/Test/BrowseQueryPlans.hs`
shows how to EXPLAIN a prepared statement. `kiroku-store/bench/RegressionGate.hs`
provides existing same-process control/candidate comparisons using `tasty-bench`
and wall time. It eagerly prepares unrelated fixtures, so add a small dedicated
stream-head benchmark component using the same support library rather than enlarging
its default fixture setup. `justfile` supplies `perf-structure`,
`perf-workload-gate`, and their aggregate `perf-check`.

The feasibility evidence in `docs/bench/stream-head/2026-10-09/` includes
`evaluate.py`, `queries.json`, `timings.json`, and `query-plans.json`. It measured
100-event and 100,000-event streams on a 200,000-event fixture. A backward index-only
probe needed no Sort; the full lookup touched seven shared buffers for both sizes.
Heap fetches differed before and after vacuum. Reuse this evidence to choose the
query; do not rerun that raw-SQL experiment as a substitute for testing production
SQL and the implemented public runner.

Relevant ADRs were discovered by scanning local filenames and headings:
[ADR-1](../adr/0001-resolve-stream-names-via-lookup-not-recordedevent-field.md)
keeps optional metadata off existing event rows because even one extra text column
caused a measured read regression. [ADR-5](../adr/0005-three-tier-performance-regression-gates.md)
makes structural checks and controlled workloads authoritative, with historical CSVs
as telemetry. [ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md)
requires query work to follow the requested result rather than all streams or all
global events, and records why the origin index still exists. This plan follows
those decisions. `docs/PERF-REGRESSION-GATES.md` explains the gate commands.

`mori show --full` identifies `docs/adr` as a profiled OKF bundle using
`docs/adr/profile.dhall`. Its pinned descriptor supplies the local metadata contract,
including `generated` authorship; inspect and type-check it before writing an ADR.
Allocate the stable `ADR-N` identifier with OKF, maintain the log, and validate strictly.
Dependency discovery used Mori for `mori://hasql/hasql` and
`mori://Bodigrim/tasty-bench`. The Hasql decoder source confirms `rowMaybe` for an
optional row and `nullable int8` for an optional column. The benchmark source
confirms wall-time comparisons, relative deviation, and per-cell timeouts. No
new dependency, bound, or pin is proposed.


## Plan of Work


### Milestone 1: Establish the compatibility and cost baseline


At the end of this milestone, unchanged metadata/event/write SQL is captured in
executable structural checks, and a small benchmark can measure ordinary metadata
reads against a frozen control before the feature exists. Run the current store
suite and the baseline timing comparison to show that the test harness is valid.

Add `kiroku-store/test/Test/StreamHeadIsolation.hs`, register it in
`kiroku-store/test/Main.hs` inside the `performance structure` group, and add it to
the test component's `other-modules` in `kiroku-store/kiroku-store.cabal`. Compare
`Statement.toSql` for the legacy `getStreamStmt`, both stream directions, both
`$all` directions, category and consumer-group category reads, the four append
variants, and `linkToStreamStmt` against frozen baseline SQL. Store those SQL
fixtures under `kiroku-store/test/fixtures/stream-head-isolation/`, include them in
Cabal source distribution, and resolve their location independently of the test's
working directory. Capture from the baseline before editing production code; never
regenerate them from the candidate to pass a failure. Assert the old getStream result
still has exactly the original six fields and the event decoder still has eleven;
review the source diff to verify decoder bodies and existing dispatch branches are
unchanged. Avoid an unrelated decoder or interpreter refactor.

Add `kiroku-store/bench/StreamHeadCost.hs` and benchmark component
`kiroku-stream-head-cost`. Reuse `withSharedMigratedPostgres`,
`withMigratedTestDatabase`, and `withStore`; use the existing dependency set plus the
already-used Effectful packages for a benchmark-local interpreter. Freeze the
baseline `getStream` SQL, six-column row decoder, GetStream handler, `usePool` error
mapping, and `runStoreIO` composition in benchmark-only control code. Interpret only
GetStream there and fail on any unexpected effect. The production arm must execute
`runStoreIO store (getStream name)`. Both arms must include effect dispatch, pool
checkout, statement execution, decoding, and result validation. Calling current
`getStreamStmt` in the frozen control would hide a future production regression.

Seed the same migrated database for all read-only arms with 1,000 streams of 100
events each, interleaved global positions, plus one stream of 100,000 originated
events. Adapt the checked-in evaluation's fixture to current migrations; populate
category on `$all` junctions and keep the `$all` frontier consistent. Seed outside
measurement; analyze and vacuum once before timing. Add the fixture as
`kiroku-test-support/src/Kiroku/Test/Fixtures/StreamHead.hs`, expose it in
`kiroku-test-support/kiroku-test-support.cabal`, and reuse it for query-plan tests.
Do not copy the evaluation's temporary-database/migration lifecycle; the Haskell
support library owns the migrated database lifecycle.

For each stream size, initially provide `control-metadata` and
`production-metadata` timing cells in one process. Each measured action executes
100 calls and checks/forces each result, including every metadata field, before it
returns. Fail on any store error or unexpected version. Use equal validation work
in the two arms. Warm all statements with 100 calls per arm before measurement.
Gate `production-metadata/control-metadata <= 1.10` with `bcompareWithin 0 1.10`.
This is a focused legacy-read regression threshold, not a claim of exact zero
latency movement. Preserve raw output and estimates, even on failure.


### Milestone 2: Implement and prove the combined public read


At the end of this milestone, callers and mock interpreters can capture metadata
and an optional originated head in one call. Focused integration tests demonstrate
all lifecycle and linked-stream semantics, and the full store suite stays green.

Add `GetStreamWithHead :: StreamName -> Store m (Maybe (StreamInfo, Maybe GlobalPosition))`
beside `GetStream` in `kiroku-store/src/Kiroku/Store/Effect.hs`. Add its handler as
one `usePool` call containing exactly one `Session.statement` for the new statement.
It must not call `getStream`, perform a second statement, decode events, or emit a
write/notification. Add and export `getStreamWithHead` from
`kiroku-store/src/Kiroku/Store/Read.hs` as a single `send` of that constructor.

Add and export `getStreamWithHeadStmt` and define `getStreamWithHeadSQL` in
`kiroku-store/src/Kiroku/Store/SQL.hs`. Keep the six original metadata columns in
the same order and append a nullable scalar subquery result:

```sql
SELECT s.stream_id, s.stream_name, s.stream_version,
       s.created_at, s.deleted_at, s.truncate_before,
       (SELECT se.stream_version
        FROM stream_events AS se
        WHERE se.stream_id = 0
          AND se.original_stream_id = s.stream_id
        ORDER BY se.stream_version DESC
        LIMIT 1) AS head_global_position
FROM streams AS s
WHERE s.stream_name = $1
```

Use the existing text parameter encoder and `preparable`. The decoder is
`D.rowMaybe ((,) <$> streamInfoRow <*> (fmap GlobalPosition <$> D.column (D.nullable D.int8)))`.
Do not alter `streamInfoRow` itself. No row means the stream is absent. A null last
column means the stream exists but has no surviving originated `$all` row. Do not
coalesce it to zero and do not filter `deleted_at` or `truncate_before`.

Create `kiroku-store/test/Test/StreamHead.hs` and
`kiroku-store/test/Test/StreamHeadMock.hs`, register their specs in
`kiroku-store/test/Main.hs`, and list both in the test Cabal stanza. Use the spec
prefix `stream head` so a single Hspec match runs them. Use fixture-only SQL to
create an empty stream row: empty public appends intentionally fail and must keep
failing. Expected positions should come from append results or the global log,
never from the ordinary stream reader's zero global-position field.

Exercise both direct and resource-backed runners over absent, empty, populated,
soft-deleted, truncated, and hard-deleted streams. In an isolated store, append to A,
then B, then A, then B, then A: A has version 3 and head 5. Another append to B raises
the global head to 6 while A remains at 5. Check the returned `StreamInfo` equals
ordinary `getStream` for stable fixtures. Soft-delete and truncate A without losing
its head; hard-delete A and require outer `Nothing`. Recreate the same name and
prove the new row cannot inherit the old origin's head.

Create a link-only target with positive version and require inner `Nothing`. For
a mixed target, originate an event, link a newer event from another source, and
prove that the target version advances while its originated head does not. Append
to that target again and prove the head now advances. Pin `$all` to metadata plus
`Nothing` in both an empty and populated store. Test a throwing event decode hook
with a zero invocation count. In the mock, verify the stream argument, one
GetStreamWithHead constructor, and all nested-Maybe outcomes; any GetStream or
other constructor must fail the mock.

Prove the snapshot guarantee with the single production SQL statement and handler
structure, plus a bounded concurrent integration case. In an isolated origin-only
stream with no other writers, append one event at a time while repeatedly reading
the pair; every observed populated pair must have equal version and global head,
even if the next append commits immediately afterwards. Coordinate worker startup
with MVars/STM, bound waits, propagate writer failures, and join workers on exit.
This stress check supplements the structural proof; timing luck is not its substitute.


### Milestone 3: Verify bounded work and measure the public operation


At the end of this milestone, the production query demonstrably uses the existing
origin index with bounded work, existing paths pass the frozen checks, and the new
operation has recorded public-runner cost. Performance acceptance and any uncertainty
are reported separately from functional completion.

Extend `kiroku-store/test/Test/PerformanceStructure.hs` with a `stream head query
work` group using the shared StreamHead fixture. EXPLAIN the actual
`SQL.getStreamWithHeadStmt` obtained through `Statement.toSql`, not a handwritten
lookalike. Use natural planner settings with ANALYZE statistics. For both the
100-event and 100,000-event streams, require a backward scan of
`ix_stream_events_all_by_origin` below Limit, at most one head row, no Sort or
sequential/bitmap scan of `stream_events`, and no access to `events`. Accept Index
Scan or Index Only Scan; heap visibility can change without violating bounded work.
Set a whole-query budget of 32 execution shared buffers (hits plus reads, counted
at the top node without summing inclusive child totals) for each populated probe.
The preliminary seven-buffer measurement leaves room for normal index depth and
heap fetch differences while detecting an unbounded scan. Do not change the budget
in response to a failure without explaining the concrete planner/fixture evidence.

Cover an empty and missing stream as well: the empty row has a null head, and the
missing row returns nothing with zero executions of the correlated probe. Capture
JSON plans for review. Also EXPLAIN a server-prepared statement after enough
executions for PostgreSQL's default plan-cache behavior, using the prepared-query
helper pattern in `Test.BrowseQueryPlans`; do not disable sequential scans or force
an index to manufacture a pass. One PostgreSQL major, the one available in the
normal development environment, is the initial scope; record the exact version.

Add `production-with-head` to both size groups in `StreamHeadCost.hs`, executing
`runStoreIO store (getStreamWithHead name)` and forcing/validating the metadata and
head. The benchmark now has six cells: frozen metadata control, public metadata,
and public metadata-plus-head for each size. Report the opt-in cost in microseconds
per call and its ratio to metadata alone. It is additional functionality: do not
apply the legacy 1.10 regression threshold to the new operation or claim it must be
as fast as metadata-only. Its acceptance combines measured public-runner cost,
correctness, and the deterministic bounded-work gate. Missing/error results must
not be timed as successful cheap reads.

Use wall time, `--stdev 5`, a 60-second per-cell timeout, and one initial benchmark
invocation. Together with 100-call warmups, fixture setup and compilation, expect
approximately 10–20 minutes for focused evidence on a warm toolchain; timeouts allow
up to six minutes of measurement per invocation. Record actual setup, warmup,
measurement and total durations. The single experiment budget is 60 minutes,
including calibration, baseline capture, current structural/aggregate checks,
recovery, and any repeats. Use remaining time, never a restarted budget.

A passing legacy ratio and an achieved relative-deviation target require no repeats.
If there is a timing failure or noisy/incomplete result, preserve it and run at
most two additional unchanged invocations on a quiet host within the remaining
budget. Treat consistent failures as a regression to investigate. If estimates
straddle the threshold, the target deviation is missed, evidence conflicts, or the
budget expires, report performance acceptance as inconclusive. `tasty-bench` can
print a result when its timeout prevents the requested precision; exit success
alone does not establish precision. Keep all runs, not only favorable retries.
Never refresh historical CSVs or weaken thresholds to obtain a pass.

Run the `perf-check` coverage once after the focused work (reuse the passing full-suite structural checks and execute the unchanged workload actions remotely after the user's 2026-10-11 steering); it contains existing append and
category workload checks as well as structural tests. This is the existing
repository integration gate, not a reason to create a new append/link benchmark
matrix. Investigate any adverse existing gate under its unchanged policy. If a
new concern requires broader evidence, name the changed path and unanswered question
in this plan before increasing coverage. The user authorized a focused remote run on 2026-10-11 because the local host is busy. Use the existing sealed-cell protocol, preserve the original start/deadline, and run only the six head cells and existing workload gate after a small verified lifecycle proof. Any remote
escalation must first satisfy all repository AGENTS.md requirements, including the
complete runtime/uncertainty proposal, a verified small lifecycle run, persistent
bounded controller, progress verification, retained journal, and owned-lease release.


### Milestone 4: Document the contract and complete integration


At the end of this milestone, public documentation explains how to use the value,
the source-compatibility caveat is explicit, and a durable ADR records the cost
boundary. The full build, focused/full store tests, and relevant documentation
validation pass, with exact evidence linked from this plan.

Write Haddocks in `kiroku-store/src/Kiroku/Store/Read.hs` and constructor documentation
in `kiroku-store/src/Kiroku/Store/Effect.hs`. Update the stream metadata section of
`docs/user/reading-events.md` and add an Unreleased entry to
`kiroku-store/CHANGELOG.md`. Explain outer versus inner absence, originated versus
linked events, `$all`, stream version versus global position versus append frontier,
soft deletion/truncation versus hard deletion, and the one-statement observation.
Give the consumer example: capture metadata and head together; for an origin-only
stream with retained required history, require `version >= N` and `Just head`, then
wait for the projection cursor to reach head. The observation neither locks history
nor freezes later appends; physical retention/hard deletion after capture can require
a consumer timeout. A positive linked version is outside this guarantee.

State that existing `StreamInfo` construction remains compatible, but custom
exhaustive `Store` interpreters must handle `GetStreamWithHead`. Compile all local
packages to expose local exhaustive matches; do not guess a package release number
or publish packages in this plan. Do not alter downstream services or send them
messages. Release/version policy can be handled in the separate release workflow.

Create a narrowly scoped ADR for opt-in originated stream heads using the next OKF
handle, linking ADR-1, ADR-5, ADR-10, and this plan. Preserve the descriptor's actual
metadata contract, update the bundle log with `okf log add`, and validate it strictly.
The ADR should retain the one-snapshot invariant, the linked-stream/$all semantics,
and the rule that legacy reads and writes acquire no extra work. Record results in
this plan and link implementation evidence from IR-18 without marking it released
before a release exists. If editing IR-18, update its bundle metadata/log according
to its profile rather than leaving its previous timestamp misleading.


## Concrete Steps


Run these commands from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Commands naming new modules or
components below become available in their stated milestones. Use the development
shell if GHC or PostgreSQL is absent; do not traverse `/nix/store` to find tools.

```bash
git status --short
git rev-parse HEAD
ghc --numeric-version
postgres --version
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

Before changing production code, capture the legacy SQL fixtures and run the
Milestone 1 metadata-only benchmark. Save evidence under a new uniquely named
subdirectory of `docs/bench/stream-head/`; retain the original 2026-10-09 evidence.
After implementing Milestone 2, run:

```bash
cabal build all
cabal test kiroku-store:kiroku-store-test --test-show-details=direct \
  --test-options='--match "stream head"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

The new tests must report zero failures and display the lifecycle, linking, mock,
snapshot, and hook cases. Then run the focused structural and timing evidence:

```bash
just perf-structure
cabal bench kiroku-store:kiroku-stream-head-cost \
  --benchmark-options='--time-mode wall --stdev 5 --timeout 60s'
just perf-check
```

Record the baseline and candidate source revisions, frozen-control identity,
compiler and PostgreSQL versions, database settings, fixture counts, natural
EXPLAIN JSON, raw timing output, measured ratios/deviations, and total elapsed time.
A README in the evidence directory must distinguish the two legacy metadata gates
from diagnostic opt-in timings and list every failed, interrupted, or repeated run.
Do not fabricate expected speedups or copy the feasibility timings as new results.

Before writing the ADR, inspect the current profile and allocated IDs:

```bash
dhall type --file docs/adr/profile.dhall
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add --help
```

Use the returned handle and the current CLI's log options. After documentation and
ADR edits, validate:

```bash
cabal haddock kiroku-store
okf validate docs/adr --strict --profile docs/adr/profile.dhall \
  --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall --profile-enforce --log-enforce
git diff --check
git diff -- kiroku-store/src/Kiroku/Store/SQL.hs \
  kiroku-store/src/Kiroku/Store/Effect.hs kiroku-store/src/Kiroku/Store/Types.hs \
  kiroku-store-migrations/migrations
```

The source diff should show additive head-related definitions and exports, no change
to the StreamInfo representation, no legacy decoder/SQL/handler changes, and no
migration changes. Commit coherent milestones on the current branch using
Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md
Intention: intention_01m4md6pjse09s59yrm7wvhwdc
```

Resolve the implementing model using the skill's `PROVENANCE.md`, append one revision
entry with `record-provenance.ts --mode implement` at the first plan update, and
maintain timestamped Progress entries and the implementation revision note.


## Validation and Acceptance


Functional acceptance means a public caller can distinguish a missing stream from
an empty one and observe A's version 3/head 5 together while another stream advances
the store-wide head to 6. The same observations work through `runStoreIO`,
`runStoreResource`, and a mock Store interpreter. Logical lifecycle changes retain
the head; hard deletion removes the stream; recreating a name cannot reuse its old
head. Link-only and mixed streams follow originated events only. `$all` always has
no originated head. A failing event decode hook is never called.

Snapshot acceptance requires one real SQL statement for the version/head pair,
one effect dispatch and pool checkout, no intervening metadata lookup, and the
bounded concurrent test. A one-checkout test alone is insufficient because a session
can execute multiple statements. Review the handler and production SQL explicitly.

Performance acceptance requires frozen legacy SQL checks and unchanged legacy
encoders/decoders/dispatch, no schema or write-path additions, the natural indexed
head probe and 32-buffer bound, measured opt-in public-runner results for both
sizes, and passing legacy metadata ratios within 1.10 with the stated uncertainty
policy. Existing `perf-check` gates must also pass or remain explicitly unresolved;
preliminary SQL evidence alone cannot close this milestone. Report what was measured
and protected rather than claiming performance at every workload/concurrency level.

Documentation acceptance requires usable Haddocks and the user-guide example,
the custom-interpreter changelog note, strictly valid ADR/IR bundle edits, and a
final Outcomes entry that separately names functional completion and performance
acceptance. A build alone, an unexecuted test, or an inconclusive timing run cannot
be reported as completed acceptance.


## Idempotence and Recovery


All tests and benchmarks use disposable migrated databases; setup and cleanup are
bracketed by existing support functions. They must be repeatable without touching
an application database. No persistent schema migration or rollback is needed.
Never run the fixture SQL against a user's store. Keep benchmark fixtures outside
measurement and ensure failed setup aborts rather than timing an empty database.

Retain the frozen control and baseline fixtures across retries. A baseline source
change must be explained and captured before measuring again, with prior evidence
kept. On test failure, fix the implementation and rerun affected checks. On timing
failure, keep logs, investigate, and follow the bounded repeat policy; no indefinite
retry loop. If interrupted, preserve completed artifacts and carry forward elapsed
experiment time. Do not infer progress from a process ID alone. Avoid a broad reset
or reverting other contributors' files when removing this feature or repairing tests.


## Interfaces and Dependencies


The following public interface must exist in `Kiroku.Store.Read` and be re-exported
by `Kiroku.Store`:

```haskell
getStreamWithHead ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe (StreamInfo, Maybe GlobalPosition))
```

`Kiroku.Store.Effect.Store` adds:

```haskell
GetStreamWithHead ::
    StreamName -> Store m (Maybe (StreamInfo, Maybe GlobalPosition))
```

`Kiroku.Store.SQL` adds:

```haskell
getStreamWithHeadStmt ::
    Statement Text (Maybe (StreamInfo, Maybe GlobalPosition))
```

No new public record or StoreError constructor is needed. Hasql supplies the prepared
statement and optional decoders; Effectful supplies the constructor and interpreter;
Hspec and existing test support exercise real PostgreSQL; tasty-bench supplies
same-process wall-time comparisons. Keep existing dependency bounds and pins. If a
later obstacle appears to require changing a dependency, first use Mori to locate
its source/docs, then verify the current release against the authoritative package
registry and upstream tags before selecting a bound or workaround. Cross-repository
durable references must use canonical `mori://` URIs.


## Revision Notes


2026-10-10: Created from IR-18 and current source research. The plan isolates the
new cost, fixes originated-head and `$all` semantics, and defines focused structural
and public-runner evidence without launching implementation or performance runs.

2026-10-11: Began implementation, froze the pre-feature SQL and full runner control, added the shared fixture and recorded successful baseline validation.

2026-10-11: Implemented the additive API, compatibility/lifecycle/snapshot tests, bounded plan checks and documentation; distilled ADR-19. After the user reported local contention and authorized remote cells, preserved the original experiment deadline and moved unchanged timing actions to alpha. Retained a failed legacy ratio and its conflicting unchanged repeat without claiming performance acceptance.
