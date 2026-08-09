---
id: 69
slug: expose-a-performant-durable-subscription-checkpoint-inventory
title: "Expose a performant durable subscription checkpoint inventory"
kind: exec-plan
created_at: 2026-08-09T13:01:15Z
intention: intention_01kzkbfhxjextbwheaq969h303
---

# Expose a performant durable subscription checkpoint inventory

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If implementation changes durable project context, update or create the relevant ADR in
`docs/adr/` in the same change.


## Purpose / Big Picture

Kiroku already persists one checkpoint per subscription name and consumer-group member and
maintains a single-row global store tail, but a library consumer cannot read those facts together
through the mockable `Store` effect. After this plan, `kiroku-store` exposes a public, read-only
`subscriptionCheckpointInventory` operation which returns the captured store position and the
exact persisted checkpoint rows in a stable order. An operator can distinguish durable progress
from the process-local cursor returned by `subscriptionStates`, including after a worker has
stopped, without importing Hasql or querying Kiroku-owned tables.

The operation performs one prepared query under one PostgreSQL statement snapshot and one
database round trip, with no per-row follow-up work. The query point-reads the `$all` stream row
and left-joins the checkpoint inventory, retaining the position-zero store row even when no
checkpoint exists. Its unavoidable work is linear in the number of checkpoints returned. The
existing unique B-tree on `(subscription_name, consumer_group_member)` can supply the requested
order; this plan deliberately does not add another write-amplifying index. Correctness tests,
`EXPLAIN (ANALYZE, BUFFERS)` evidence, and a 10,000-row benchmark make the performance claim
observable rather than assumed.

This plan implements
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-2`. It does not implement or
prescribe Keiro's lag calculation, category-head lookup, CLI rendering, or topology model. The
captured store position makes a global position-distance calculation trivial; it does not claim
that the distance equals the number of relevant events a filtered, category, or sharded member
still has to process.

Once the Kiroku API has been implemented, measured, documented, and released, the final
milestone creates a separate Keiro ExecPlan under the operational CLI MasterPlan. That plan
will consume the released API, so all Keiro applications inherit the behavior through the
supported library boundary instead of duplicating Kiroku SQL.


## Progress

- [x] (2026-08-09T13:38:11Z) Milestone 1: added the public inventory/checkpoint types, `Store`
  operation, one-query SQL interpreter, smart constructor, empty-store integration coverage, and
  Hasql-free mock-interpreter coverage. `cabal build kiroku-store` and the 9-example focused suite
  passed.
- [ ] Milestone 2: prove the durable semantics with integration and mock-interpreter tests,
  and document the boundary from live subscription state.
- [ ] Milestone 3: establish and record query-plan and benchmark evidence at representative
  and stress cardinalities.
- [ ] Milestone 4: complete the Kiroku IR and perform the PVP-major `kiroku-store`/dependent-bound
  release after explicit release confirmation.
- [ ] Milestone 5: create, but do not execute, the dependent Keiro adoption ExecPlan.


## Surprises & Discoveries

- The current member-aware checkpoint upsert writes `subscription_name`,
  `consumer_group_member`, `last_seen`, and `updated_at`; it does not maintain the legacy
  `stream_name` or `consumer_group_size` columns. Those topology columns therefore cannot be
  exposed as authoritative facts by this API.
- A missing checkpoint is read internally as position zero without inserting a row. The
  inventory consequently means “persisted checkpoint rows,” not “every configured or live
  subscription.” A subscription appears only after a checkpoint-writing transaction commits.
- Member zero is used both for a non-group subscription and for member zero of a consumer
  group. The persisted row alone cannot distinguish those cases, so the API must not infer a
  topology classification.
- `updated_at` is refreshed by every checkpoint upsert, while `last_seen` is protected by
  `GREATEST`. Therefore `checkpointUpdatedAt` is the last successful write time, not proof
  that the checkpoint position advanced.
- Kiroku already has a cheap `currentGlobalPositionStmt` which point-reads
  `streams.stream_version` for `stream_id = 0`. Returning that position with the inventory in one
  statement gives consumers a consistent observation point and avoids a second network round
  trip. The standalone public frontier and bounded replay API remain separately requested by
  `docs/improvement-requests/expose-bounded-fan-in-replay-windows.md`.
- Hasql's registered source at `mori://hasql/hasql/packages/hasql` documents `rowVector` as
  notably preferable to `rowList` for multi-row results, and its result decoder is a `Functor`.
  The statement can therefore decode the left-join rows into a strict vector and finalize the
  singleton captured head plus optional checkpoint rows in one linear pass.
- `Kiroku.Store.SQL` is currently an exposed library module, as are several subscription worker
  modules. Adding this statement there would unnecessarily enlarge the raw Hasql surface even
  though the requested contract is the `Store` effect. A new Cabal `other-modules` entry can keep
  this statement package-internal without breaking the existing exposed modules.
- The PVP impact is larger than an ordinary new function: `Store` is an exported GADT and custom
  interpreters pattern-match its constructors. Kiroku's own 0.3.0.0 release classified two added
  `Store` constructors as breaking. The local sister packages do not currently implement the
  GADT, but `kiroku-otel`, `kiroku-cli`, `kiroku-metrics`, and
  `shibuya-kiroku-adapter` all bound `kiroku-store` to `^>=0.3`; a 0.4 release requires their
  bounds and releases to be audited. `mori registry dependents shinzui/kiroku --packages --json`
  also reports Keiro and other external registered projects, which may adopt 0.4 independently.
- On 2026-08-09, `mori path` reported “artifact not found” for the Kiroku IR and the two Keiro
  planning artifacts cited here, even though `mori registry show --full` located both projects
  and the files exist in their registered worktrees. This is an artifact-coverage/registry lag;
  per repository policy the plan retains the intended canonical `mori://` URIs rather than
  replacing them with ambiguous cross-repository paths.
- The test suite is Hspec-based and rejects the originally drafted Tasty-style `--pattern` flag.
  The focused command is `--test-options='--match SubscriptionCheckpointInventory'`; it ran 9
  examples with 0 failures.
- The worker does not publish its next `SubscriptionState` cursor before checkpoint persistence.
  `processEvents` handles the batch and saves the checkpoint before the driver loops and writes the
  next state to the registry cell. A deterministic live-handler barrier therefore proved the
  relevant boundary directly: handler work in flight left the durable inventory at position 1,
  and a fresh read after the stopping handler's synchronous checkpoint commit returned position 2.


## Decision Log

- Decision: Use one Kiroku ExecPlan rather than a MasterPlan.
  Rationale: The deliverable is one read API in one package, with tests, performance proof,
  documentation, and a coordinated PVP release. The dependent Kiroku package changes are
  mechanical bound/changelog releases under one gate, not independent implementation tracks. The
  cross-repository Keiro work is intentionally a later independent ExecPlan, not a parallel
  Kiroku workstream requiring a coordinating MasterPlan.
  Date: 2026-08-09

- Decision: Expose the global store tail and persisted checkpoint facts together, but do not
  expose computed lag, a category head, consumer-group size, target stream/category, or live
  state in the same operation.
  Rationale: Both the `$all` tail and checkpoints are Kiroku-owned durable facts, and one SQL
  statement captures them under one PostgreSQL snapshot without a second round trip. Lag still
  depends on which head and which definition are meaningful to a consumer; the checkpoint row
  carries no reliable topology or target information. Kiroku therefore returns inputs, not a
  Keiro-specific interpretation.
  Date: 2026-08-09

- Decision: Return `SubscriptionCheckpointInventory`, containing one captured `storePosition`
  and a strict `Vector SubscriptionCheckpoint` in ascending subscription-name and member order,
  without pagination in the first version.
  Rationale: The inventory must return every row and Kiroku's scaling analysis expects only low
  hundreds of subscriptions. One strict result is easy to use and mock. Its O(N) database,
  decoding, and memory cost is optimal for returning N rows; a 10,000-row stress benchmark guards
  the assumption. Pagination can be added later if real cardinalities invalidate it.
  Date: 2026-08-09

- Decision: Include `checkpointUpdatedAt :: UTCTime` in the public row.
  Rationale: The column already exists and makes stale durable rows operationally useful, as long
  as Haddock explicitly defines it as the last checkpoint upsert time rather than evidence of
  position movement.
  Date: 2026-08-09

- Decision: Use the existing unique index on `(subscription_name,
  consumer_group_member)` and add no migration or covering index.
  Rationale: The inventory is a full-table result, so PostgreSQL may correctly choose either an
  ordered index scan or a sequential scan plus one sort. Including `last_seen` and `updated_at`
  in a second index would churn on every checkpoint write and optimize a low-frequency
  observability read at the expense of the hot write path.
  Date: 2026-08-09

- Decision: Add the operation to the existing `Store` GADT even though the new constructor is a
  source-compatibility break for exhaustive mock interpreters.
  Rationale: The improvement request explicitly requires a mockable supported API. A direct
  Hasql helper would leak storage ownership and would not flow through `runStorePool`,
  `runStoreResource`, and `runStoreIO` consistently.
  Date: 2026-08-09

- Decision: Put the new prepared statement in the hidden
  `Kiroku.Store.Subscription.CheckpointInventory.SQL` module, not the already exposed
  `Kiroku.Store.SQL` module.
  Rationale: Consumers need the public effect operation and types, not another raw Hasql
  statement. Listing the new module under the library's `other-modules` keeps the implementation
  importable by `Kiroku.Store.Effect` while avoiding a new supported SQL surface. Existing exposed
  SQL APIs remain unchanged to avoid an unrelated breaking cleanup.
  Date: 2026-08-09

- Decision: Treat `0.4.0.0` as the expected `kiroku-store` release, subject to an authoritative
  Hackage and upstream-tag check immediately before release.
  Rationale: The currently verified release is `0.3.1.0`, but the exported `Store` GADT gains a
  constructor and exhaustive custom/mock interpreters must add a case. Kiroku's 0.3.0.0 changelog
  explicitly treated prior `Store` constructor additions as breaking, so PVP requires a major
  `A.B` bump rather than calling this a backwards-compatible export. Release state can change
  before implementation finishes, so the plan must still recalculate from the then-current tag.
  Date: 2026-08-09

- Decision: Test in-flight-versus-durable semantics with a blocked live handler rather than
  asserting that `subscriptionStates` publishes an ahead-of-database cursor.
  Rationale: The current worker publishes its next FSM state only after checkpoint persistence, so
  an ahead cursor is not an observable current-state transition. Blocking a confirmed live handler
  still proves the contract that handled-but-uncommitted work never appears in the durable
  inventory, without changing the worker lifecycle as an unrelated side effect.
  Date: 2026-08-09


## Outcomes & Retrospective

(To be filled during and after implementation. Record measured row counts, query plans,
benchmark means, the released version/tag, the completed IR reference, and the canonical URI of
the generated Keiro plan.)


## Context and Orientation

A subscription checkpoint is the highest global event position whose processing Kiroku has
durably acknowledged for one subscription member. `GlobalPosition` is a monotonically increasing
cursor in Kiroku's global event log. The new inventory's `storePosition - checkpointPosition`
is therefore cheap to calculate and useful as a global *position distance*. It is not universally
an event-count backlog: category and event-type filters skip unrelated global positions,
consumer-group members handle only their assigned events, and hard deletion can remove historical
rows without rewinding the tail. A category projection may also want its category head instead of
the store tail. This plan publishes a same-statement store position and checkpoint inputs, then
leaves the choice of lag definition and presentation to the consumer.

The global store position is `streams.stream_version` on the primary-key row `stream_id = 0` and
is already read cheaply by `currentGlobalPositionStmt`. The durable checkpoint rows live in the
`subscriptions` table created by
`kiroku-store-migrations/migrations/0001-kiroku-bootstrap.sql`. Its uniqueness constraint on
`(subscription_name, consumer_group_member)`, named `ix_subscriptions_name_member`, is the
physical access path relevant to this plan.
`kiroku-store/src/Kiroku/Store/SQL.hs` contains the existing member-aware
`getCheckpointMemberStmt` and `saveCheckpointMemberStmt`; the latter uses `GREATEST` so a stale
write cannot move `last_seen` backwards. The dead-letter path also advances this same checkpoint
inside its transaction. The new inventory reads those committed rows from a dedicated hidden SQL
module and does not alter any write path.

`kiroku-store/src/Kiroku/Store/Subscription.hs` currently exposes `subscriptionStates`. That
function reads an in-memory registry attached to one `KirokuStore`; a worker disappears when it
stops, and its FSM cursor can be ahead of the database while a batch is in flight. The new
`subscriptionCheckpointInventory` function answers the durable database question and must sit
beside, not replace or merge with, that live API.

The public effect is the `Store` GADT in `kiroku-store/src/Kiroku/Store/Effect.hs`.
`runStorePool` interprets each constructor against PostgreSQL;
`runStoreResource` and `runStoreIO` delegate through it. Consumer-facing modules use small
`send`-based smart constructors such as those in `Kiroku.Store.Read`. The new operation follows
that pattern, while its two public result types live in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` and are re-exported by
`Kiroku.Store.Subscription` and the umbrella `Kiroku.Store` module.

ADR 0002 (`docs/adr/0002-static-hash-partitioned-consumer-groups.md`) defines the current static,
member-aware consumer-group model. ADR 0003
(`docs/adr/0003-dedicated-kiroku-schema.md`) explains why SQL statements remain unqualified and
resolve the configured Kiroku schema through each connection's `search_path`. The new statement
must follow both decisions. No schema migration is expected.

The integration test suite is declared in `kiroku-store/kiroku-store.cabal`, entered from
`kiroku-store/test/Main.hs`, and contains related coverage in
`kiroku-store/test/Test/SubscriptionState.hs`,
`kiroku-store/test/Test/SubscriptionRegistry.hs`, and
`kiroku-store/test/Test/ConsumerGroupSql.hs`. Performance benchmarks live in
`kiroku-store/bench/Main.hs`; their checked baseline is
`kiroku-store/bench/results/baseline.csv`, with operating instructions in
`docs/BENCH-REGRESSION.md` and focused execution through `just bench-regression-pattern`.

The downstream consumer is the separate project `mori://shinzui/keiro`. Its operational CLI
initiative is `mori://shinzui/keiro/masterplans/31-build-the-keiro-ops-operational-cli`, and the
currently deferred consumer work is discussed in
`mori://shinzui/keiro/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops`.
This Kiroku plan neither edits Keiro code nor preserves Keiro's current workaround shape.
Milestone 5 creates a fresh Keiro plan from the final, released Kiroku contract.


## Plan of Work

### Milestone 1: implement one public, member-aware inventory read

Add `SubscriptionCheckpoint` to
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs` with strict fields for the subscription
name, member, exact persisted position, and last upsert time. Add
`SubscriptionCheckpointInventory` with strict `storePosition :: GlobalPosition` and
`checkpoints :: Vector SubscriptionCheckpoint` fields. Derive `Eq`, `Show`, and `Generic` in the
same style as nearby public records. Do not include `consumer_group_size`, `stream_name`, an
inferred non-group/group discriminator, live cursor, category head, or computed lag.

Add `GetSubscriptionCheckpointInventory` to the `Store` GADT in
`kiroku-store/src/Kiroku/Store/Effect.hs`. In `runStorePool`, interpret it with exactly one
`Session.statement` call. `runStoreResource` and `runStoreIO` require no special branch because
they already delegate to the pool interpreter; verify this with tests rather than duplicating
logic.

Create the package-internal module
`kiroku-store/src/Kiroku/Store/Subscription/CheckpointInventory/SQL.hs`, add it under the
library's `other-modules` in `kiroku-store/kiroku-store.cabal`, and define
`getSubscriptionCheckpointInventoryStmt` there. Do not add this module to `exposed-modules` or
re-export its statement from an exposed module. The statement has no parameters. Decode the
result with Hasql's `rowVector`, then use `Hasql.Statement.refineResult` to finalize the captured
non-null head and optional checkpoint values in one strict linear pass. The left join
intentionally returns one row with nullable checkpoint columns when the store has no checkpoints,
so the public value is `SubscriptionCheckpointInventory (GlobalPosition 0) V.empty` rather than
no result. Treat a missing `$all` row, inconsistent repeated heads, or a partially null checkpoint
tuple as a decoder/invariant error, not as an empty store. The SQL contract is:

```sql
SELECT store_head.stream_version,
       checkpoint.subscription_name,
       checkpoint.consumer_group_member,
       checkpoint.last_seen,
       checkpoint.updated_at
FROM streams AS store_head
LEFT JOIN subscriptions AS checkpoint ON TRUE
WHERE store_head.stream_id = 0
ORDER BY checkpoint.subscription_name ASC,
         checkpoint.consumer_group_member ASC
```

Keep both table names unqualified for configured-schema support. The singleton `streams` point
lookup and checkpoint scan are the entire query. Do not join to event rows, count events, run one
statement per checkpoint, or add a schema migration/index.

In `kiroku-store/src/Kiroku/Store/Subscription.hs`, export and implement
`subscriptionCheckpointInventory` as the ordinary
`send GetSubscriptionCheckpointInventory` smart constructor. Its Haddock must state all of these
facts: `storePosition` and `checkpoints` come from one SQL statement snapshot; an empty vector
means no checkpoint has yet been written; stopped subscriptions remain; rows are sorted by
name/member; a new read is required to observe later commits; live cursors may be ahead; member
zero does not reveal whether a subscription belongs to a group; `checkpointUpdatedAt` is a write
timestamp, not proof of an advance; and subtracting positions is not an exact relevant-event count
for filtered, category, or sharded consumers.

This milestone is complete when the package compiles, the empty-store integration test returns
position zero plus an empty vector, and a tiny mock interpreter can pattern-match
`GetSubscriptionCheckpointInventory` without importing Hasql.

### Milestone 2: lock down semantics and documentation

Create `kiroku-store/test/Test/SubscriptionCheckpointInventory.hs`, register it in
`kiroku-store/test/Main.hs`, and add it to the test-suite `other-modules` in
`kiroku-store/kiroku-store.cabal`. Use the existing test-store/migration helpers. Fixture setup
may use the existing checkpoint-writing helpers where starting a worker would obscure the case,
but every inventory assertion must exercise the public effect API rather than the new raw read
statement. At minimum cover:

1. an empty migrated store returns `storePosition == GlobalPosition 0` and `V.empty` checkpoints;
2. after appending events and writing a non-group checkpoint, the result returns the exact current
   store position plus the checkpoint's name, member zero, and persisted `GlobalPosition`;
3. interleaved writes for multiple names and multiple members return one row per durable key,
   sorted by name and then numeric member;
4. a lower later save does not regress the returned position, and a committed higher save is
   visible on a fresh inventory call;
5. cancellation/removal from `subscriptionStates` does not remove the durable row;
6. while a confirmed-live handler is processing an event but its checkpoint write has not
   committed, the inventory still reports the prior durable position; after commit, a fresh read
   reports the new one;
7. a checkpoint advanced by the dead-letter transaction appears with the exact committed
   position, preserving the existing atomicity contract; and
8. every normally written checkpoint is less than or equal to the captured store position, and
   the SQL/statement test asserts the head and rows are fetched by one statement rather than two
   effect calls; and
9. a custom test interpreter can return an inventory record for the new constructor without a
   database.

Use synchronization primitives in the live-versus-durable test; do not rely on sleeps or racing
poll loops. Compare `checkpointUpdatedAt` for presence/order only where the test controls commit
order; do not assert wall-clock precision.

Update `docs/user/subscriptions.md` with a copyable Effectful example and an explicit comparison
between `subscriptionStates` and `subscriptionCheckpointInventory`. Show a global position-
distance calculation, label it as such, and explain why it is not an exact relevant-event count
for every subscription target or member. Update
`docs/user/observability.md` to route durable inventory to the new function. Correct
`docs/user/schema.md` wherever it implies `consumer_group_size` is authoritative under the
current member-aware writer. Update Haddocks and the improvement request at
`docs/improvement-requests/expose-a-durable-subscription-checkpoint-inventory.md` so its core
contract is Kiroku-owned and requires the same-statement `storePosition`; retain Keiro only as a
canonical downstream dependency, not as the source of the API design. Cross-reference the
repository-local bounded replay IR for the separate standalone-frontier/page-window work rather
than claiming this inventory operation completes it.

This milestone is complete when focused and full tests pass and the docs clearly distinguish a
cheap global position distance from an exact backlog or a target-specific lag.

### Milestone 3: prove the performance contract

First capture PostgreSQL evidence with `EXPLAIN (ANALYZE, BUFFERS)` against an isolated migrated
test database containing 100 rows (representative) and 10,000 rows (100 times the expected low-
hundreds cardinality). Seed rows before measurement. Preserve the ordered query exactly as the
public statement executes it. Record the PostgreSQL version, row count, execution time, shared
buffer activity, and complete plan summary in this plan's Surprises & Discoveries section.

Accept either an ordered scan of the existing unique index or a sequential scan followed by one
sort for `subscriptions`, plus one primary-key lookup of the `$all` `streams` row. A singleton
`Nested Loop Left Join` between that one-row lookup and the one checkpoint scan is expected and is
not N+1 behavior. Reject and investigate any per-checkpoint lookup/subplan, repeated checkpoint or
event-table scan, or on-disk temporary sort at 10,000 rows. Do not force a particular planner node
or disable sequential scans merely to make the plan look index-backed.

Add a `subscription-checkpoint-inventory` benchmark group to
`kiroku-store/bench/Main.hs`. Construct separate migrated stores containing 100 and 10,000
checkpoint rows outside the timed actions. Each benchmark must call the public
`subscriptionCheckpointInventory` effect path and force the captured position and full returned
vector so database execution, transfer, decoding, finalization, and materialization are included.
Name the cases so
`just bench-regression-pattern subscription-checkpoint-inventory` selects both.

Capture a clean baseline following `docs/BENCH-REGRESSION.md` and commit the new baseline entries.
Record both benchmark means and the ratio between 10,000 and 100 rows in the plan. The hard gate
is structural: one round trip, no N+1 behavior, and completion without spill or failure at 10,000
rows. The scaling expectation is approximately linear in returned row count, but do not invent a
machine-independent millisecond SLA. Rerun the focused regression gate and require no unexplained
slowdown greater than the repository's existing 10% threshold on subsequent runs.

This milestone is complete only when both the query-plan evidence and public-API benchmark are
recorded. If the result is unexpectedly expensive, optimize the query/decoder first and repeat
the evidence. Add an index only if measurements demonstrate a read benefit that justifies its
checkpoint-write cost, document that tradeoff in the Decision Log, and add the required migration
and write-path benchmarks.

### Milestone 4: finish the IR and release the supported API

During implementation, update the improvement request's requested shape and acceptance evidence
but leave its status uncompleted until the package is actually published. Run the complete
repository checks and validate the improvement-request bundle before release. After the Hackage,
tag, and GitHub release evidence exists, set the IR status to `completed`, refresh its review and
verification timestamps/context, validate again, and commit that evidence. Keep the IR complete
independently of whether Keiro has adopted the API; the Keiro work is a downstream plan, not part
of Kiroku's acceptance.

Before changing versions or release metadata, follow `.agents/skills/release/SKILL.md` and ask the
user for explicit release confirmation. Re-query Hackage and upstream tags at that time. If
`0.3.1.0` remains current, release `kiroku-store-0.4.0.0`; otherwise calculate the next PVP major
version from the then-current release. Explain in the proposal that the public effect constructor,
not the read-only runtime behavior, drives the major bump.

Audit every Kiroku publishable dependent and every stanza before proposing the release. At the
time of writing, `kiroku-otel`, `kiroku-cli`, `kiroku-metrics`, and
`shibuya-kiroku-adapter` contain `kiroku-store ^>=0.3` bounds and need compatible 0.4 bounds plus
their own release metadata if they are to remain compatible with the new store release;
`kiroku-store-migrations` currently has no Cabal dependency despite the release skill's general
package-order note. Search again rather than trusting this snapshot. Compile the sister packages
against 0.4 and inspect their source for exhaustive `Store` interpreters before deciding whether
their bumps are patch-only bound releases or require source changes. If `kiroku-cli` is released,
also follow the release skill's `kiroku-metrics` bound audit. Registered external dependents are
reported, but are not edited from this repository; the Keiro adoption is handled by Milestone 5.

After confirmation, let the release skill's current ordering govern version/changelog edits,
complete builds, commits, annotated tags, pushes, Hackage uploads, documentation uploads, and
GitHub releases. Do not substitute an older remembered release sequence. Every implementation
commit uses Conventional Commits and the trailer:

```text
ExecPlan: docs/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory.md
```

This milestone is complete when `kiroku-store` and every in-repository package included by the
confirmed bound audit exist on Hackage, their annotated tags and GitHub releases exist upstream,
the plan records final versions/URLs, and a clean consumer can compile the inventory API from the
released package set.

### Milestone 5: create the Keiro adoption plan

Only after Milestones 1–4 have fixed and released the contract, switch to the registered
`mori://shinzui/keiro` worktree. Read a repository-local `AGENTS.md` if one exists, followed by
`agents/skills/exec-plan/SKILL.md`, `agents/skills/exec-plan/PLANS.md`, and
`agents/skills/exec-plan/ADR.md` before editing. Inspect
`docs/masterplans/31-build-the-keiro-ops-operational-cli.md`, inherit its intention
`intention_01kzagac32ehp93amx1sfar2ab`, and initialize a child ExecPlan with the local generator,
rather than guessing its sequence number:

```bash
bun agents/skills/exec-plan/init-plan.ts \
  --title "Adopt Kiroku's durable subscription checkpoint inventory" \
  --master-plan docs/masterplans/31-build-the-keiro-ops-operational-cli.md \
  --intention intention_01kzagac32ehp93amx1sfar2ab
```

The Keiro plan must cite
`mori://shinzui/kiroku/plans/69-expose-a-performant-durable-subscription-checkpoint-inventory`,
the completed IR, and the released package through canonical `mori://` URIs. It must research
Keiro's current code at that future point and define how to replace any private checkpoint SQL
with `subscriptionCheckpointInventory`, use the captured `storePosition` for explicitly named
global position distance, select a category head or another definition where actual projection lag
requires it, update the lower bound on `kiroku-store` to the first release carrying the API, cover
member-aware output, and test the central Keiro library/ops surface so its downstream consumers
inherit the change rather than reproducing the calculation.
It must not assume that member zero identifies a non-group subscription or that subtracting every
checkpoint from the store-wide global head yields an exact relevant-event count.

Do not implement the Keiro plan in this milestone. Commit only the new living plan and any
necessary MasterPlan bookkeeping in the Keiro repository, using Conventional Commits, the Keiro
ExecPlan/Intention trailers, and canonical cross-repository references. Construct the canonical
URI from the generator-produced id and slug, verify it with `mori path` when available, and record
it in this plan's Outcomes. A registry-resolution delay is not a reason to replace the canonical
URI with a bare path.


## Concrete Steps

Run implementation commands from
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless a step says otherwise.

Establish a clean, current baseline and rediscover registered dependency locations before code
changes:

```bash
git status --short --branch
mori registry show shinzui/kiroku --full
mori registry dependents shinzui/kiroku --packages --json
mori registry show hasql/hasql --full
mori registry docs hasql/hasql
cabal test kiroku-store:kiroku-store-test
```

After Milestone 1, format and run the new focused test pattern (adjust the pattern to the final
Tasty group name), then the package suite:

```bash
nix fmt
cabal test kiroku-store:kiroku-store-test \
  --test-options='--match SubscriptionCheckpointInventory'
cabal test kiroku-store:kiroku-store-test
```

Expected focused output contains a passing group and no failures, for example:

```text
SubscriptionCheckpointInventory
  empty store:                                  OK
  rows are member-aware and deterministically ordered: OK
All tests passed
```

Run the performance evidence against the same PostgreSQL major version used by normal test and
benchmark runs. Put transient seed SQL or scripts in a temporary directory, not in the source
tree, unless the implementation reveals a reusable repository need:

```bash
cabal bench kiroku-store:kiroku-store-bench \
  --benchmark-options='--pattern subscription-checkpoint-inventory'
just bench-baseline
just bench-regression-pattern subscription-checkpoint-inventory
```

The baseline command intentionally changes `kiroku-store/bench/results/baseline.csv`; inspect and
commit only the expected new or deliberately refreshed rows. Record a reason for any unrelated
baseline movement instead of silently accepting it.

Before release, run the full gates prescribed by the release skill, including:

```bash
nix fmt
cabal build all
cabal test all
nix flake check
mori improvement-requests validate \
  --path /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
git diff --check
git status --short
```

Then enter each package selected by the confirmed release scope and run its `cabal check`, test,
sdist, and Hackage Haddock commands exactly as the release skill prescribes. The release skill
remains authoritative for the exact confirmation, commit, tag, push, Hackage, and GitHub-release
commands. Do not infer approval from this plan.

For Milestone 5, first resolve and inspect Keiro through Mori:

```bash
mori registry show shinzui/keiro --full
mori registry docs shinzui/keiro
cd /Users/shinzui/Keikaku/bokuno/keiro
git status --short --branch
```

Then run the initializer shown in Milestone 5, fill the generated plan completely, update the
MasterPlan's child-plan ledger if its instructions require it, validate using Keiro's local plan
workflow, and commit the planning-only change. Do not modify Keiro source code in this milestone.


## Validation and Acceptance

The implementation is accepted when all of the following are demonstrably true:

1. `subscriptionCheckpointInventory` on an empty migrated store returns
   `storePosition == GlobalPosition 0` and an empty checkpoint vector, not an error or a synthetic
   checkpoint row.
2. The captured store tail and durable rows round-trip exact `GlobalPosition`,
   `SubscriptionName`, `Int32` member, and `UTCTime` values through the public `Store` effect.
   Multiple members of one name remain independent and all output is sorted by
   `(subscriptionName, consumerGroupMember)` ascending.
3. The operation performs exactly one prepared database statement and returns the point-read
   `$all` tail plus all checkpoint rows from that statement snapshot. Neither SQL nor Haskell
   performs per-checkpoint head, event, stream, or topology lookups.
4. A stopped worker's row remains visible; work performed by an active live handler does not leak
   into the inventory before its checkpoint commits; a fresh read observes the later checkpoint
   only after that write commits.
5. Monotonic checkpoint protection and dead-letter/checkpoint atomicity remain unchanged and are
   visible through the inventory.
6. A custom `Store` interpreter can implement `GetSubscriptionCheckpointInventory` using only the
   public inventory and row types. Ordinary consumers need neither Hasql nor knowledge of Kiroku
   table names.
7. The 100-row and 10,000-row plans contain one checkpoint scan, one singleton store-head lookup,
   no per-checkpoint work, and no disk spill; the public effect benchmark fully materializes both
   result sizes and passes the focused baseline-regression workflow after baseline capture.
8. Haddock and user docs define this as a point-in-time durable inventory, distinguish it from
   `subscriptionStates`, explain member-zero ambiguity and `checkpointUpdatedAt`, and label
   store-position subtraction as position distance rather than an exact relevant-event backlog.
9. All repository tests/checks pass, the IR is completed with evidence, and the PVP-major store
   release plus every required in-repository dependent-bound release is published under the
   confirmed versions.
10. A separate, initialized Keiro ExecPlan exists under
    `mori://shinzui/keiro/masterplans/31-build-the-keiro-ops-operational-cli`, cites the released
    Kiroku API canonically, plans adoption and consumer coverage, and contains no implementation
    changes yet.


## Idempotence and Recovery

The inventory query is read-only and can be rerun safely. No migration is planned, so a failed
implementation can be reverted at the Haskell/SQL statement level without database recovery.
Integration tests and benchmarks must use isolated migrated databases or uniquely scoped test
fixtures; seeding should happen outside measured actions and be safe to recreate.

Formatting, compilation, tests, `EXPLAIN`, Haddock generation, sdist construction, and benchmark
runs are repeatable. `just bench-baseline` overwrites a tracked file, so inspect its diff and keep
the previous file recoverable through Git. Do not refresh the baseline to conceal an unexplained
regression.

Publishing and tag creation are not idempotent. Before retrying a partially failed release, check
Hackage, local tags, upstream tags, and Git status to identify which step succeeded. Never reuse a
published version for different contents, delete a public tag to replay the procedure, or upload
without the release skill's explicit confirmation gate.

The Keiro initializer refuses accidental reuse of an existing plan number. If Milestone 5 is
interrupted after creating the file, resume by editing that generated file; do not run the
initializer again and create a duplicate. If Mori cannot yet resolve the newly created artifact,
keep the canonical URI, refresh/reregister only through approved Mori workflow, and document the
temporary resolution gap.


## Interfaces and Dependencies

At the end of Milestone 1, the supported public shape is:

```haskell
-- Kiroku.Store.Subscription.Types
data SubscriptionCheckpoint = SubscriptionCheckpoint
    { subscriptionName :: !SubscriptionName
    , consumerGroupMember :: !Int32
    , checkpointPosition :: !GlobalPosition
    , checkpointUpdatedAt :: !UTCTime
    }
    deriving stock (Eq, Show, Generic)

data SubscriptionCheckpointInventory = SubscriptionCheckpointInventory
    { storePosition :: !GlobalPosition
    , checkpoints :: !(Vector SubscriptionCheckpoint)
    }
    deriving stock (Eq, Show, Generic)

-- Kiroku.Store.Effect
data Store :: Effect where
    -- existing constructors ...
    GetSubscriptionCheckpointInventory ::
        Store m SubscriptionCheckpointInventory

-- Kiroku.Store.Subscription
subscriptionCheckpointInventory ::
    (HasCallStack, Store :> es) =>
    Eff es SubscriptionCheckpointInventory
```

The package-internal module
`Kiroku.Store.Subscription.CheckpointInventory.SQL` (a Cabal `other-modules` entry, not an
exposed module) provides:

```haskell
getSubscriptionCheckpointInventoryStmt ::
    Statement () SubscriptionCheckpointInventory
```

No new library dependency is required. `effectful`, `hasql`, `time`, and `vector` are already
dependencies of `kiroku-store`; PostgreSQL and the existing Kiroku migrations remain the only
runtime services. Use the Hasql source and curated documentation located through
`mori registry show hasql/hasql --full` and `mori registry docs hasql/hasql` if decoder or
statement behavior is uncertain; do not guess from memory or inspect `/nix/store`.

The public compatibility cost is one new constructor in an exported GADT. Pool-backed consumers
gain behavior automatically; custom exhaustive interpreters must add a case. Treat that as a PVP
major change, call it out under Breaking Changes in the changelog, and update the confirmed
dependent bounds/releases. No existing constructor, checkpoint write, subscription lifecycle,
schema column, or index changes as part of this plan.

The downstream Keiro plan depends on the final tagged version of
`mori://shinzui/kiroku/packages/kiroku-store`, not on this repository's working tree. It owns the
meaning and presentation of lag: the inventory supplies a same-statement global store position,
but a category or filtered consumer may require a different head or an event-count query. This
plan owns only the durable snapshot facts and the evidence that reading them together is correct
and performant.
