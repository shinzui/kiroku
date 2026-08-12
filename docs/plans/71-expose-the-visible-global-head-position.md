---
id: 71
slug: expose-the-visible-global-head-position
title: "Expose the visible global head position"
kind: exec-plan
created_at: 2026-08-12T16:40:32Z
intention: "intention_01kzvdfcz0esfazrya5y9vyyb9"
---

# Expose the visible global head position

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku currently exposes two indirect ways to ask where the global event log ends, but neither is
the cheap, reachability-oriented answer needed by a subscription waiter. The
`SubscriptionCheckpointInventory.storePosition` field is the monotonic append frontier: it keeps
the greatest position ever allocated even after hard deletion removes the corresponding events.
`readAllBackward (GlobalPosition 0) 1` finds the newest event that remains visible, but it reads and
decodes that event's payload merely to obtain its position. After this plan, a caller can instead
invoke `visibleGlobalHeadPosition` through the mockable `Store` effect and receive the greatest
position still visible in `$all`, or zero when no event remains, without loading or decoding an
event.

The distinction is observable in one disposable-database test. Append events at positions one
through three, hard-delete the source stream that owns position three, and call both APIs. The new
operation returns the greatest surviving position while the inventory still reports three. The
focused test suite also installs a decode hook that would fail if invoked, proving that head lookup
does not pass through the event decode path. A structural PostgreSQL plan test proves that the
query uses the existing `(stream_id, stream_version)` B-tree index and needs no `Sort` node.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-12T16:58:15Z) Milestone 1: added and registered the focused behavior and mock tests;
      the required pre-implementation compile failed on the absent public operation as expected.
- [x] (2026-08-12T17:00:09Z) Milestone 1: implemented the indexed scalar statement, `Store`
      constructor, pool branch, and public `Kiroku.Store.Read` function.
- [x] (2026-08-12T17:00:09Z) Milestone 1: proved empty, populated, direct-runner,
      resource-runner, and hard-deleted-tail behavior while leaving the authoritative checkpoint
      inventory unchanged; the focused run passed 6 examples in 0.7178 seconds.
- [x] (2026-08-12T17:00:09Z) Milestone 2: proved soft-delete and logical-truncation visibility,
      decode-hook isolation, and one-call mock dispatch.
- [x] (2026-08-12T17:01:47Z) Milestone 2: added the production-statement EXPLAIN assertion and
      passed `just perf-structure` with 9 examples in 1.3277 seconds; the plan used
      `ux_stream_events_stream_version` and contained no `Sort`.
- [ ] Milestone 3: update Haddocks, user guides, capability evidence, changelog, IR-4 status and
      evidence, and the durable checkpoint terminology in ADR-4 and its bundle log.
- [ ] Final validation: format the tree; run the focused store tests, structural performance gate,
      full build and tests, capability/ADR/improvement-request validation, and record exact results
      in this plan.
- [ ] Completion: review the Decision Log, Surprises & Discoveries, and Outcomes & Retrospective;
      finish the ADR distillation pass and update this plan's outcome.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The registered tests established the expected red state before production edits;
  the compiler reached both new modules and rejected only the deliberately absent API surface.
  Evidence:

  ```text
  Test.VisibleGlobalHeadPosition.hs:19:30: Variable not in scope: visibleGlobalHeadPosition
  Test.VisibleGlobalHeadPositionMock.hs:8:27:
    Module ‘Kiroku.Store.Read’ does not export ‘visibleGlobalHeadPosition’.
  ```

- Observation: The shared 20,000-event fixture made PostgreSQL select
  `ux_stream_events_stream_version` naturally for the production statement, with no `Sort` node;
  no planner setting or fixture adjustment was needed. Evidence: `just perf-structure` passed the
  named structural assertion as part of 9 examples in 1.3277 seconds.


## Decision Log

Record every decision made while working on the plan.

- Decision: Name the public operation `visibleGlobalHeadPosition`, its effect constructor
  `GetVisibleGlobalHeadPosition`, and its prepared statement `visibleGlobalHeadPositionStmt`.
  Rationale: “Visible” distinguishes surviving `$all` junctions from the authoritative append
  frontier, while “head position” states that the result is a cursor rather than an event. These
  names also match the accepted shape in IR-4 without overloading the existing “current global
  position” terminology used by the append frontier.
  Date: 2026-08-12.

- Decision: Implement the scalar query as an ordered one-row lookup rather than an aggregate:

  ```sql
  SELECT COALESCE((
    SELECT stream_version
    FROM stream_events
    WHERE stream_id = 0
    ORDER BY stream_version DESC
    LIMIT 1
  ), 0)
  ```

  Rationale: `ux_stream_events_stream_version` is a B-tree on `(stream_id, stream_version)`.
  Equality on its leading column and a backward scan of the second column can return one matching
  index entry without sorting or scanning event payloads. `MAX(stream_version)` is normally
  optimized similarly, but the ordered `LIMIT 1` form makes the intended top-one access path
  explicit and lets the structural test assert the production statement's index and absence of a
  `Sort` node.
  Date: 2026-08-12.

- Decision: Add no schema migration and no new index.
  Rationale: bootstrap migration `0001` supplies the ordered `(stream_id, stream_version)` index and
  migration `0005` replaces it with the unique `ux_stream_events_stream_version`. The query reads
  existing junction state only. Like any MVCC index lookup immediately after a very large tail
  deletion, it may transiently skip dead entries until PostgreSQL cleanup catches up; adding a
  redundant index would not remove that behavior.
  Date: 2026-08-12.

- Decision: Treat the result as one statement-time observation, not a durable or transaction-wide
  snapshot.
  Rationale: each call runs one prepared statement under the pool's normal connection behavior. A
  concurrent append or hard deletion may change the answer immediately after return, and no public
  API in this plan holds a snapshot open for a caller.
  Date: 2026-08-12.

- Decision: Classify the release as source-breaking even though the public read function is
  behaviorally additive.
  Rationale: `Store(..)` is exported and custom interpreters may match its GADT constructors
  exhaustively. Adding `GetVisibleGlobalHeadPosition` therefore requires those interpreters to be
  recompiled and possibly edited. Kiroku's 0.4.0.0 and 0.5.0.0 changelogs classify prior `Store`
  constructor additions the same way. Record this under an Unreleased breaking-change heading;
  leave the actual version assignment to the independent package release workflow.
  Date: 2026-08-12.

- Decision: Test the direct and resource-backed runners, but describe only `runStorePool` as the
  concrete interpreter.
  Rationale: `runStoreIO` composes `runStorePool`, and `runStoreResource` obtains a handle before
  delegating to `runStorePool`; there are not two independent SQL implementations. Both public
  runner shapes still deserve coverage, along with a true mock interpreter.
  Date: 2026-08-12.

- Decision: Mark repository implementation of IR-4 complete without making downstream Keiro
  adoption a Kiroku acceptance gate.
  Rationale: Kiroku can prove the public operation and mock contract locally. Keiro should remove
  its private compatibility query only after a release containing this API is available; that
  follow-up belongs to
  `mori://shinzui/keiro/plans/238-target-strong-consistency-waits-at-the-visible-store-head`.
  Date: 2026-08-12.

- Decision: Clarify ADR-4 rather than create a new ADR during implementation.
  Rationale: ADR-4 already owns `FromCurrentHead` checkpoint initialization. That policy must
  continue to seed the monotonic append frontier so a future-only worker skips every position
  allocated before initialization, including hard-deleted positions. Updating its terminology to
  “authoritative append frontier” makes its relationship to the new visible head durable without
  creating a second overlapping checkpoint ADR. ADR-5 already supplies the structural performance
  gate policy.
  Date: 2026-08-12.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Milestones 1 and 2 delivered the public effectful scalar API and its exact production SQL, with
behavioral proof that it diverges from the append frontier only when hard deletion removes the
visible tail. The focused suite also proved that the scalar path supports both public runner
shapes, is mockable, and never invokes event decoding. The structural performance suite selected
the existing unique `(stream_id, stream_version)` index without a `Sort`. Documentation, durable
ADR terminology, bundle updates, and the full validation matrix remain for Milestone 3 and final
completion.


## Context and Orientation

Kiroku is a PostgreSQL-backed event store. An application appends immutable events to named source
streams. Every appended event also receives a globally ordered cursor by inserting a junction row
into the reserved `$all` stream. `GlobalPosition` is the Haskell newtype for that cursor. Positions
are opaque and strictly increasing when allocated; callers must not assume every smaller numeric
position remains readable because hard deletion can remove rows and leave gaps.

The database represents `$all` in two places. The `streams` row whose `stream_id` is zero stores
`stream_version`, a monotonic append counter. Append statements in
`kiroku-store/src/Kiroku/Store/SQL.hs` increment that row and use the allocated values as
`stream_events.stream_version` for junction rows whose `stream_id` is zero. The counter is the
authoritative append frontier: it records the greatest allocated position even if an event later
disappears. The actual visible global log is the surviving set of `stream_events` rows with
`stream_id = 0`; its greatest `stream_version` is the visible global head.

The schema begins in `kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`. Migration
`kiroku-store-migrations/migrations/0005-index-hygiene-and-streams-fillfactor.sql` installs
`ux_stream_events_stream_version` on `(stream_id, stream_version)`. PostgreSQL B-trees can scan in
either direction. Since the proposed query constrains the leading key to zero, the database can
seek to the end of that key range and return one position in descending order. No migration and no
join to the payload-bearing `events` table are needed.

Hard deletion is implemented by the `HardDeleteStream` branch of `runStorePool` in
`kiroku-store/src/Kiroku/Store/Effect.hs`. In one transaction it deletes the target source's `$all`
junctions, removes its remaining junctions, cleans up orphan payload and dead-letter rows, and
deletes the source stream row. It deliberately does not decrement the reserved `$all` stream row.
Soft deletion only writes `streams.deleted_at`, and logical truncation only writes
`streams.truncate_before`; neither removes `$all` junctions. A visible-head query over
`stream_events` therefore inherits exactly the visibility rules of `readAllForward` and
`readAllBackward`.

`kiroku-store/src/Kiroku/Store/Effect.hs` declares the dynamically dispatched `Store` GADT and
contains its single concrete pool interpreter, `runStorePool`. `runStoreIO` is a convenience
composition over that interpreter. `runStoreResource` obtains a `KirokuStore` from
`KirokuStoreResource` and then calls the same interpreter. Adding an effect constructor is what
makes the operation mockable, but because `Store(..)` is public it is also a source-compatibility
change for exhaustive downstream matches.

`kiroku-store/src/Kiroku/Store/Read.hs` contains public effectful read functions. It is an exposed
module and is re-exported by `kiroku-store/src/Kiroku/Store.hs`, so adding the smart constructor
there automatically exposes it through both import styles. `kiroku-store/src/Kiroku/Store/SQL.hs`
contains prepared Hasql statements and is also currently exposed, although ordinary consumers
must use `Kiroku.Store.Read.visibleGlobalHeadPosition` rather than depending on raw Hasql. The
existing `currentGlobalPositionStmt` selects the authoritative counter from `streams` and must
remain unchanged.

The current payload-bearing path demonstrates what this feature avoids. `readAllBackwardStmt`
selects the eleven `RecordedEvent` columns from `stream_events JOIN events`; the `ReadAllBackward`
interpreter branch then calls `decodeEvents`, which invokes the configured `decodeHook` on every
returned event. The new scalar branch must execute only its position statement and return its
`GlobalPosition` directly.

Store tests use Hspec and disposable PostgreSQL databases. `kiroku-store/test/Test/Helpers.hs`
exports `withTestStore` and `withTestStoreSettings`; the latter can install a deliberately failing
decode hook. Focused modules are imported and invoked from `kiroku-store/test/Main.hs` and listed
as `other-modules` in `kiroku-store/kiroku-store.cabal`. Existing mock patterns live in
`kiroku-store/test/Test/SubscriptionCheckpointInventoryMock.hs` and
`kiroku-store/test/Test/SubscriptionCheckpointInitializationMock.hs`. Existing resource-runner
coverage lives in `kiroku-store/test/Test/SubscriptionCheckpointInventory.hs`.

`kiroku-store/test/Test/PerformanceStructure.hs` wraps the exact production SQL returned by
`Hasql.Statement.toSql` in `EXPLAIN (FORMAT JSON, COSTS OFF)`. Its shared 20,000-event fixture is
large enough for PostgreSQL to select production indexes naturally, and its helpers collect index
names and plan node types. The visible-head statement should be added to this test rather than
copying SQL or disabling sequential scans. Hasql was located through Mori as
`mori://hasql/hasql/packages/hasql`; the checked-out API confirms that `Statement.preparable`,
`Decoders.singleRow`, `Decoders.column`, `Decoders.int8`, and `Statement.toSql` are available under
the repository's `hasql >=1.10 && <1.11` bound. This plan changes no dependency bound.

The originating request is
`docs/improvement-requests/expose-the-visible-global-head.md` (IR-4). The downstream defect and
temporary compatibility implementation belong to
`mori://shinzui/keiro/plans/238-target-strong-consistency-waits-at-the-visible-store-head`.
Registry resolution for that newly authored Keiro plan may lag its source repository; the
canonical URI remains the durable reference.

Three local ADRs apply. [ADR-3](../adr/0003-dedicated-kiroku-schema.md) requires SQL statements to
remain unqualified because each pooled connection sets the configured Kiroku schema in its
`search_path`. [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) owns the
`FromCurrentHead` initialization policy and explains why adding a `Store` constructor is
source-breaking; implementation must clarify that this policy uses the authoritative append
frontier, not the new visible head. [ADR-5](../adr/0005-three-tier-performance-regression-gates.md)
makes deterministic production-statement EXPLAIN checks authoritative performance evidence. No
other local ADR controls this feature.


## Plan of Work

### Milestone 1: Add the scalar API and core lifecycle proof

Create `kiroku-store/test/Test/VisibleGlobalHeadPosition.hs` and initially write the externally
observable cases. An empty migrated store returns `GlobalPosition 0`. Three appended events return
position three. A fixture in which positions one, two, and three belong to three different source
streams must show that hard-deleting the position-two source leaves the visible head at three,
hard-deleting the position-three source falls back to one, and hard-deleting the final source falls
back to zero. Read `subscriptionCheckpointInventory` after each tail deletion and assert that its
`storePosition` remains three. This proves the two concepts diverge without issuing private SQL.

The same module must exercise both public pool-backed entry shapes. The ordinary examples call
`runStoreIO store visibleGlobalHeadPosition`. One example follows the established resource pattern:
run `runStoreResource visibleGlobalHeadPosition` under `runKirokuStoreWith store`,
`runErrorNoCallStack`, and `runEff`, and compare it with the direct result.

Register the test module in `kiroku-store/test/Main.hs` and the `other-modules` list of
`kiroku-store/kiroku-store.cabal`. Add it before implementation so the missing symbols establish
the expected failing state; a compile failure naming `visibleGlobalHeadPosition` is sufficient
because the operation does not yet exist. Do not commit a deliberately uncompilable tree; continue
through the production edits before the milestone commit.

In `kiroku-store/src/Kiroku/Store/SQL.hs`, export and define
`visibleGlobalHeadPositionStmt :: Statement () GlobalPosition`. Use the ordered scalar query from
the Decision Log, `E.noParams`, and a single-row decoder that wraps the non-null `int8` in
`GlobalPosition`. Keep table names unqualified per ADR-3. Do not edit
`currentGlobalPositionStmt`, the append statements, or migrations.

In `kiroku-store/src/Kiroku/Store/Effect.hs`, add
`GetVisibleGlobalHeadPosition :: Store m GlobalPosition` beside the other global reads, with a
Haddock that contrasts surviving visibility with the inventory's authoritative position. Add one
`runStorePool` arm that calls `usePool`, executes the new statement with unit parameters, and
returns its result directly. It must not access `storeSettings`, `decodeEvents`, `events`, or a
transaction escape hatch.

In `kiroku-store/src/Kiroku/Store/Read.hs`, export and define the smart constructor with the exact
signature recorded under Interfaces and Dependencies. Its Haddock must state the empty result,
soft/hard/truncate visibility, distinction from `storePosition`, and statement-time observation
semantics. `Kiroku.Store` already re-exports the entire read module, so do not add a redundant
explicit export there.

At the end of this milestone, the focused test command must compile and pass the empty, populated,
resource, and hard-delete divergence cases. The production diff must contain no migration.

### Milestone 2: Prove mockability, decode isolation, and the indexed plan

Extend `Test.VisibleGlobalHeadPosition` with the remaining visibility and hook cases. Append a
multi-event stream, set its logical truncate-before marker, and verify that the visible head does
not change. Soft-delete the stream and verify the same result. These state changes affect named
stream reads but must not hide the stream's `$all` junctions.

For decode isolation, create an `IORef` counter and open a store with
`defaultStoreSettings{decodeHook = Just failingHook}`. The hook increments the counter and throws
an IO failure if called. Append one event, invoke only `visibleGlobalHeadPosition`, assert the
result is position one, and assert the counter remains zero. The append path uses `enrichEvent`,
not `decodeHook`, so the hook can safely be installed before the append.

Create `kiroku-store/test/Test/VisibleGlobalHeadPositionMock.hs`. Follow the existing Effectful
mock modules: interpret `GetVisibleGlobalHeadPosition`, increment a call counter, return a supplied
`GlobalPosition`, and reject every other constructor with an “unexpected Store operation” error.
Call the public smart constructor and prove exactly one effect dispatch. Register this module in
`Main.hs` and the Cabal test stanza.

In `kiroku-store/test/Test/PerformanceStructure.hs`, pass
`SQL.visibleGlobalHeadPositionStmt` and an empty placeholder list to
`explainProductionStatement`. Assert that the collected index names contain
`ux_stream_events_stream_version` and that the node types do not contain `Sort`. Do not require
the exact spelling `Index Only Scan Backward`: visibility-map state can legitimately make
PostgreSQL choose an ordinary index scan, and both plans retain the protected ordered top-one
shape. Do not set `enable_seqscan=off`; ADR-5 requires the seeded production-like planner choice to
be natural.

At the end of this milestone, the focused visible-head tests and `just perf-structure` must pass.
The EXPLAIN JSON should show the unique stream-version index and no sort, while the hook test proves
that no event decode occurs.

### Milestone 3: Make the distinction durable in public documentation

Add an Unreleased section to `kiroku-store/CHANGELOG.md`. Under Breaking Changes, state that the
exported `Store` GADT gains `GetVisibleGlobalHeadPosition` and exhaustive custom interpreters must
handle it. Under New Features, document the public scalar API, its hard-deleted-tail behavior, and
the fact that it reads no payload. Do not assign or bump a package version in this plan; release
versioning is handled by the repository's independent package release workflow.

Update `docs/user/reading-events.md` with a copyable call and a hard-deleted-tail example. Replace
the current claim that visible `$all` is “gap-free”: allocation is globally ordered, but hard
deletion can leave gaps. Define the authoritative append frontier and visible head side by side,
and explain that a captured visible head is one observation rather than a retained snapshot.

Update `docs/user/subscriptions.md` where it describes the checkpoint inventory and computes
position distance. Label `storePosition` as the authoritative append frontier, warn that it can
remain above every visible event after tail hard deletion, and point callers needing an actionable
global reachability target to `visibleGlobalHeadPosition`. Clarify that `FromCurrentHead` uses the
authoritative frontier deliberately: it seeds a future-only boundary and does not promise that an
event currently exists at that position. Do not silently change the inventory's one-statement
snapshot contract or claim that a separately read visible head shares that snapshot.

Update `docs/capabilities/reading-events.md` so CAP-4 names the new function and cites
`kiroku-store/test/Test/VisibleGlobalHeadPosition.hs` as evidence. Update
`docs/capabilities/explicit-subscription-checkpoint-lifecycle.md` to replace ambiguous “current
head” wording with “authoritative current append frontier.” Add one capability log entry using
`okf log add` and validate the bundle.

Update [ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) without changing its
stable `docId`. Clarify in Context, Decision, and Consequences that `FromCurrentHead` captures the
authoritative append frontier, while `visibleGlobalHeadPosition` is the separate reachability
observation that may regress after hard deletion. Advance its timestamp, preserve the existing
producer-owned frontmatter, add the required bundle-log entry with `okf log add`, and run strict
ADR validation. Do not create a new ADR unless implementation discovers a durable decision not
already covered by ADR-4 or ADR-5; if that happens, update this plan before allocating a record.

Finally update `docs/improvement-requests/expose-the-visible-global-head.md`. Correct its
compatibility terminology: the read function is additive, while the `Store` constructor is
source-breaking. Replace “package-internal Hasql statement” with the accurate requirement that
consumers need not import `Kiroku.Store.SQL` or Hasql. Describe the direct and resource-backed
runners as wrappers over one concrete interpreter. Move downstream Keiro adoption out of local
acceptance and into the follow-up status. Once all local evidence passes, set `status: implemented`,
link this plan with `mori://shinzui/kiroku/plans/71-expose-the-visible-global-head-position`, and add
an implementation entry to `docs/improvement-requests/log.md`. Publication and Keiro adoption
remain pending and must not be reported as complete.

At the end of this milestone, the guides, capability records, ADR, changelog, and improvement
request all use the same terminology. Strict bundle validation, full build, and full tests must
pass.


## Concrete Steps

Run every command from the repository root:

```text
/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

After registering the first tests but before the production API exists, run the focused selection
once and record the expected missing-symbol failure in Surprises & Discoveries. Do not commit that
state.

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "visible global head position"'
```

The useful failure is a compiler diagnostic naming `visibleGlobalHeadPosition` or
`GetVisibleGlobalHeadPosition`. After Milestone 1 implementation, run the same command. Expected
shape:

```text
visible global head position
  ...

Finished in ... seconds
... examples, 0 failures
```

After Milestone 2, run the mock selection if its group name does not fall under the first pattern,
then run the structural gate:

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "visible global head position mock"'
just perf-structure
```

The mock result must report zero failures. The structural result must include the visible-head
query-plan example and report zero failures; if it prints a plan on failure, the collected facts
must be investigated rather than suppressed with planner settings.

Use the OKF CLI to append the capability and ADR log entries after advancing their documents. The
messages may be tightened during implementation, but must name the semantic change.

```bash
okf log add docs/capabilities CAP-4 \
  --kind Update \
  --message "CAP-4 now exposes and proves the payload-free visible global head position."
okf log add docs/adr ADR-4 \
  --kind Update \
  --message "ADR-4 now distinguishes authoritative frontier seeding from the visible global head."
```

Validate each documentation bundle. `just capabilities-validate` and `just adr-validate` both run
Mori validation as well as profile enforcement. The improvement-request bundle has no Just recipe,
so invoke its declared profile directly.

```bash
just capabilities-validate
just adr-validate
okf validate docs/improvement-requests \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
```

Expected shape:

```text
Validation passed
```

Format and inspect the complete diff, then run the repository gates:

```bash
nix fmt
git diff --check
just build
just test
just perf-check
```

`just build` must build the whole Cabal project, `just test` must pass every configured suite, and
`just perf-check` must pass both the structural tier containing this query and the existing
controlled workload tier. Record exact counts, durations, and any relevant EXPLAIN facts in
Progress and Outcomes & Retrospective. Before completion, inspect the changed file set and confirm
there is no migration:

```bash
git status --short
git diff --stat
git diff -- kiroku-store-migrations/migrations
```

The last command must produce no diff. Every implementation commit must follow Conventional
Commits and include both active trailers, separated from the body by a blank line:

```text
ExecPlan: docs/plans/71-expose-the-visible-global-head-position.md
Intention: intention_01kzvdfcz0esfazrya5y9vyyb9
```


## Validation and Acceptance

The implementation is accepted only when all of the following behavior is observable through the
public API and the named commands above.

An empty migrated store returns `Right (GlobalPosition 0)` through both `runStoreIO` and the
resource-backed effect stack. No event row is required to manufacture the zero sentinel.

After appending three events, the operation returns `GlobalPosition 3`. Hard-deleting a source
whose greatest originated position is below three leaves the result at three. Hard-deleting the
source that owns position three returns the greatest surviving position, and deleting the final
surviving source returns zero. Throughout those deletes,
`SubscriptionCheckpointInventory.storePosition` remains `GlobalPosition 3`.

Soft deletion and `setStreamTruncateBefore` leave the visible head unchanged because both preserve
the `$all` junction rows. A decode hook that increments a counter and throws if called remains
uninvoked; the operation returns normally and the counter stays zero.

A custom `Store` interpreter can handle `GetVisibleGlobalHeadPosition`, return a configured value,
and observe exactly one dispatch from `visibleGlobalHeadPosition`. The pool and resource runners
produce the same result because both reach `runStorePool`.

The production-statement EXPLAIN test reports `ux_stream_events_stream_version` among its index
names and no `Sort` among its node types. It is acceptable for PostgreSQL to choose an index-only
or ordinary index scan. It is not acceptable to copy a different SQL query into the test, disable
sequential scans, add a redundant index, or weaken the assertion to a timing threshold.

The public Haddock and guides state that `visibleGlobalHeadPosition` is a statement-time
reachability observation that may regress, while `storePosition`,
`currentGlobalPositionStmt`, and `FromCurrentHead` retain authoritative monotonic semantics. The
reading guide no longer calls the hard-delete-visible log gap-free.

The changelog identifies the new GADT constructor as source-breaking. IR-4 is marked implemented
only after local code, test, plan, documentation, and profile evidence pass; it still identifies
release publication and Keiro adoption as pending.

Finally, formatting, full build, full tests, `just perf-check`, strict capability validation,
strict ADR validation, and improvement-request validation all exit zero. No migration or dependency
bound changes appear in the final diff.


## Idempotence and Recovery

All test databases are ephemeral and newly migrated, so the focused tests and full suite can be
rerun without retaining hard-deleted data. Hard deletion in this plan must occur only inside those
fixtures; no command targets an operator or production database.

The implementation is additive at the database level: it creates no table, index, migration, or
durable runtime row. If a Haskell edit fails partway, keep the new test modules registered only
while the missing production symbols are being completed; restore compilation before committing.
Repeated formatting and validation commands are safe.

`okf log add` appends an entry, so inspect the relevant `log.md` before retrying a command that may
have succeeded despite later shell output. Do not add duplicate entries. Preserve ADR-4's
`docId: ADR-4`; never allocate a new identifier merely to fix terminology.

If PostgreSQL unexpectedly chooses a sequential scan in the structural fixture, first print and
record the JSON plan, confirm the query still uses the exact production SQL, and inspect fixture
statistics. Do not set `enable_seqscan=off`. A realistic fixture adjustment is permitted only when
it preserves ADR-5's requirement that the planner choose the protected index naturally; record the
discovery and rationale in this plan.

Immediately after an unusually large hard deletion, PostgreSQL may have dead index entries that
remain until normal MVCC cleanup. The one-row ordered query can transiently walk past such entries.
If implementation testing discovers material latency at the repository's supported workload,
record the measured `EXPLAIN (ANALYZE, BUFFERS)` evidence and revise this plan before introducing
any maintained-head state, vacuum side effect, or schema change. Those would be broader designs,
not incidental fixes.


## Interfaces and Dependencies

At completion, `kiroku-store/src/Kiroku/Store/Read.hs` exports:

```haskell
visibleGlobalHeadPosition ::
    (HasCallStack, Store :> es) =>
    Eff es GlobalPosition
```

Its implementation is the single effect send:

```haskell
visibleGlobalHeadPosition = send GetVisibleGlobalHeadPosition
```

`kiroku-store/src/Kiroku/Store/Effect.hs` adds this GADT constructor:

```haskell
GetVisibleGlobalHeadPosition :: Store m GlobalPosition
```

The `runStorePool` branch executes the prepared statement through the existing `usePool` helper.
No new error type is required: connection and statement failures already map to `StoreError` at
that boundary.

`kiroku-store/src/Kiroku/Store/SQL.hs` exports:

```haskell
visibleGlobalHeadPositionStmt :: Statement () GlobalPosition
```

It uses existing Hasql interfaces from `mori://hasql/hasql/packages/hasql`:
`Hasql.Statement.preparable`, `Hasql.Encoders.noParams`,
`Hasql.Decoders.singleRow`, `Hasql.Decoders.column`,
`Hasql.Decoders.nonNullable`, and `Hasql.Decoders.int8`. The SQL returns exactly one non-null
`bigint` through `COALESCE`, decoded directly as `GlobalPosition`.

The following contracts do not change:

- `currentGlobalPositionStmt :: Statement () Int64` continues to select
  `streams.stream_version WHERE stream_id = 0`.
- `SubscriptionCheckpointInventory.storePosition` continues to be the authoritative append
  frontier captured with checkpoint rows.
- `readAllForward`, `readAllBackward`, subscription delivery, checkpoint advancement, hard-delete
  behavior, and `FromCurrentHead` initialization retain their current semantics.
- `Kiroku.Store` continues to re-export `Kiroku.Store.Read`; no new public module is introduced.

The change uses the repository's existing `effectful-core`, `hasql`, `hasql-pool`, `hspec`,
`vector`, and PostgreSQL test infrastructure. It adds no Haskell dependency, version bound,
external service, migration, or runtime configuration.


## Revision Notes

- 2026-08-12T16:58:15Z: Recorded the registered behavior/mock tests and the intentional
  missing-symbol compile failure before production implementation.
- 2026-08-12T17:00:09Z: Recorded the completed scalar API, lifecycle behavior, runner, decode
  isolation, and mock-dispatch proofs after the focused 6-example test run passed.
- 2026-08-12T17:01:47Z: Recorded the completed structural performance gate and the natural
  index-backed, no-sort plan selected by PostgreSQL.
