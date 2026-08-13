---
id: 73
slug: protect-replay-history-with-retention-leases-and-stream-guards
title: "Protect replay history with retention leases and stream guards"
kind: exec-plan
created_at: 2026-08-13T20:04:58Z
intention: "intention_01kzyay9mmejbsg12a31xmxzce"
---

# Protect replay history with retention leases and stream guards

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kiroku currently lets a long-running consumer capture a global replay ceiling, but that ceiling
does not keep the retained event set stable: `hardDeleteStream` or a GUC-enabled direct SQL delete
can remove events and junction rows while the consumer is paging. A one-stream repair has the same
problem on a shorter timescale because metadata inspection and ordered reads do not share a
lifecycle lock. After this plan, a rebuild can acquire a durable, renewable history-retention
lease whose database-derived expiry and protected global position survive process restarts, and a
transactional repair can lock one stream's complete ordered history until its surrounding
transaction ends.

The guarantee is observable in deterministic two-connection tests. If lease acquisition wins its
race with hard delete, deletion returns a typed retention conflict and neither Kiroku's supported
path nor an ordinary GUC-enabled `DELETE` or `TRUNCATE` changes history. If deletion wins, the lease
protects the post-delete retained store and returns the frontier observed after that deletion. A
guarded stream read blocks appends, links into the stream, logical truncation, soft delete,
undelete, and every supported hard delete that would remove one of its home or link junctions
until the guard transaction commits or rolls back.

This plan treats “no performance degradation” as a strict no-regression contract for existing
ordinary operations: append, `$all` and category reads, per-stream reads outside a guard, soft
delete, undelete, and logical truncate acquire no new coordinator lock, run no new statement, and
fire no new trigger. The feature's necessary cost is confined to explicit lease/guard calls and
destructive `DELETE`/`TRUNCATE` paths. The existing authoritative performance gate must continue
to pass, and new structural assertions must prove that no history-retention dependency entered an
ordinary hot path. A literal zero-cost guarantee for hard delete itself would contradict the
requested serialization check; this plan accepts a bounded cost on that rare destructive path
rather than weakening correctness.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13T21:30:38Z) Milestone 1: added forward migration `0010`, the validated lease
      model, shared internal SQL/transaction algorithms, public transaction-composable
      acquire/renew/release/inventory/prune operations, and focused coverage. All 18 migration
      examples and all 7 focused store examples pass after formatting.
- [x] (2026-08-13T21:19:49Z) Reconciled the implementation baseline after plan 72 released
      migration `0009`: this plan now creates forward migration `0010`, expects ten native
      migrations, and preserves the seven-entry Codd import boundary.
- [x] (2026-08-13T21:20:34Z) Captured the clean implementation baseline: all 9 performance
      structure examples passed, and the controlled four- and eight-stream production pipelines
      measured `0.87x` and `0.84x` of their sequential controls against the unchanged `0.90x`
      maximum.
- [x] (2026-08-13T21:21:13Z) Created forward migration
      `kiroku-store-migrations/migrations/0010.sql` through `kiroku-store-migrate new`; the
      scaffolder appended it after released `0009.sql` without touching historical payloads.
- [x] (2026-08-13T21:29:24Z) Implemented Milestone 1's validated public lease types, shared
      transaction algorithms, prepared SQL, public module, and focused tests. The 2 selected
      migration catalog examples and all 7 focused store examples passed before the full
      18-example migration-suite milestone gate also passed.
- [x] (2026-08-13T21:38:15Z) Milestone 2: added all five mockable `Store` operations,
      post-commit observability without reason text, and typed supported hard-delete conflicts on
      the shared transaction implementation. All 10 focused retention/mock examples and all 10
      pre-existing hard-delete examples pass after formatting.
- [ ] Milestone 3: add the transaction-scoped stream-history guard and make supported hard delete
      pre-lock every stream whose history it can change.
- [ ] Milestone 4: complete concurrency, raw-SQL defense, rollback, deadlock, performance,
      documentation, capability, improvement-request, and ADR evidence.
- [ ] Milestone 5: prepare and, only after explicit release confirmation, publish the independently
      versioned package cohort and prove the public API from a clean downstream consumer.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Plan 72 completed and released `kiroku-store-migrations` 0.3.1.0 after this plan was written,
  consuming migration number `0009`. The authoritative manifest now ends in `0009.sql`, and tag
  `kiroku-store-migrations-v0.3.1.0` peels to the released checkpoint-relation implementation.
  Therefore replay-history retention must be additive migration `0010`; released `0009` remains
  byte-for-byte immutable.

- PostgreSQL 18 exposes column `NOT NULL` constraints through `pg_constraint`, so counting every
  constraint on the two new tables returned 17 rather than the nine explicitly named primary-key
  and check constraints. The migration contract assertion now selects the exact stable constraint
  names; this proves the intended surface without coupling to version-specific catalog expansion.


## Decision Log

Record every decision made while working on the plan.

- Decision: Accept the improvement request with a no-regression contract for existing ordinary
  operations, while allowing the unavoidable coordination work on opt-in guards and destructive
  operations.
  Rationale: The new invariant can be kept completely off append, ordinary read, soft-delete,
  undelete, and logical-truncate statements. Hard delete cannot both perform a new serialized
  conflict check and remain literally instruction-for-instruction free of added cost. Scoping and
  measuring that cost is honest; placing it on the append or read hot path is not.
  Date: 2026-08-13.

- Decision: Serialize lease acquisition, renewal, supported hard delete, raw `DELETE`, and raw
  `TRUNCATE` through a dedicated one-row `history_retention_coordinator` table in each Kiroku
  schema.
  Rationale: Locking the reserved `$all` stream row would block every append and violate the
  performance requirement. A fixed advisory-lock key risks unrelated collisions and would need
  extra care for several Kiroku schemas in one database. A Kiroku-owned row lock is per schema,
  collision-free, automatically released at transaction end, and inspectable with ordinary
  PostgreSQL tooling.
  Date: 2026-08-13.

- Decision: The first implementation conservatively blocks every Kiroku data-table `DELETE` and
  `TRUNCATE` while any lease is active, regardless of `protectedThrough`.
  Rationale: Hard delete removes `$all`, source, and link junctions. Proving that an arbitrary
  deletion cannot intersect one lease's replay window would add complex, easy-to-regress planning
  logic to a rare operation. The request explicitly permits the conservative policy, which is
  simpler to test, explain, and maintain. `protectedThrough` still identifies the inclusive replay
  frontier captured by acquisition.
  Date: 2026-08-13.

- Decision: Treat direct `TRUNCATE` as part of the lease guarantee even though the request's raw
  bypass acceptance example names only `DELETE`.
  Rationale: Kiroku already protects all three data tables with GUC-gated `BEFORE TRUNCATE`
  triggers. Allowing that supported maintenance escape hatch to erase leased history would make
  the retention promise false.
  Date: 2026-08-13.

- Decision: Use SQLSTATE `KR001` for database-level retention refusal and add no ordinary
  application override that bypasses an active lease.
  Rationale: A stable non-standard SQLSTATE lets direct SQL callers branch without parsing prose.
  Waiting for expiry or obtaining an owner-aware release is the normal recovery path. A superuser
  can still disable triggers or perform physical maintenance, but that is explicitly outside the
  application guarantee and must follow a maintenance-window protocol.
  Date: 2026-08-13.

- Decision: Before deleting its first junction, supported hard delete must lock the target stream
  and every non-`$all` stream containing a junction for an event originated by that target, in
  ascending `stream_id` order.
  Rationale: Locking only the stream named in `hardDeleteStream` is insufficient. The current
  delete cascade removes link junctions from other streams. A guard held on one of those linked
  streams would otherwise fail to protect its history. Deterministic all-affected-stream locking
  closes the gap and matches the repository's existing sorted multi-stream append discipline.
  Date: 2026-08-13.

- Decision: A stream-history guard uses `SELECT ... FOR SHARE`, and the public transactional read
  surface includes `readStreamForwardTx` rather than requiring callers to compose with
  `Kiroku.Store.SQL` directly.
  Rationale: `FOR SHARE` conflicts with the row updates used by append, link, soft delete,
  undelete, and logical truncate, and with hard delete's new `FOR UPDATE` pre-locks. A guard without
  a supported same-transaction read would push Keiro toward private statement APIs, defeating
  schema ownership. The transactional read is documented as bypassing the IO-only `decodeHook`,
  just as the existing transactional append surface documents its enrichment-hook boundary.
  Date: 2026-08-13.

- Decision: Bound a lease's requested remaining lifetime to one second through one hour, compute
  expiry with PostgreSQL `clock_timestamp()`, and derive Active/Expired/Released state rather than
  run a background expiry worker.
  Rationale: A one-hour ceiling bounds how long an abandoned process can block destructive work,
  while renewal supports multi-hour rebuilds. Deriving expiry makes a crashed process safe without
  another thread, connection, or cleanup dependency. Renewal uses
  `GREATEST(old_expiry, clock_timestamp() + requested_duration)`, so it never shortens a live lease
  and never places expiry more than the maximum duration ahead of database time.
  Date: 2026-08-13.

- Decision: Provide both public `Hasql.Transaction.Transaction` combinators and mockable `Store`
  operations for lease acquisition, renewal, release, bounded inventory, and pruning.
  Rationale: Keiro needs transaction composition with its rebuild metadata; ordinary Kiroku
  consumers and unit tests benefit from the established effect surface. Both layers share one
  internal implementation. Effect wrappers emit structured events after their owning transaction
  commits; direct transaction combinators leave process-local telemetry to the composing caller
  while preserving database audit evidence.
  Date: 2026-08-13.

- Decision: Treat lease ownership as an accidental-mutation guard, not a security boundary.
  Renewal and release require both the lease ID and declared owner and return typed owner-mismatch
  results, while database privileges remain the authorization boundary.
  Rationale: The lease inventory intentionally exposes operator-visible IDs and owners, and the
  existing hard-delete GUC is also advisory. Introducing secret bearer tokens or a security-definer
  subsystem would add a different authorization feature not requested here.
  Date: 2026-08-13.

- Decision: Create or update a durable ADR during implementation for the coordinator, conservative
  deletion policy, affected-stream lock order, and hot-path exclusion.
  Rationale: No current local ADR owns lifecycle coordination. ADR-3 owns schema placement, ADR-4
  establishes the public transaction-combinator pattern, and ADR-5 owns performance evidence, but
  none should absorb this new cross-cutting retention contract.
  Date: 2026-08-13.

- Decision: Keep publication as the final milestone and require the release skill's explicit
  confirmation immediately before tags, pushes, Hackage uploads, or GitHub releases.
  Rationale: The improvement request asks for released downstream-consumable packages, but a plan
  is not authorization for irreversible external publication. Package versions remain independent
  and must be chosen from actual PVP impact and authoritative Hackage/tag state at release time.
  Date: 2026-08-13.

- Decision: Advance the replay-history retention migration from the plan's provisional `0009` to
  `0010` and update native-manifest assertions from nine to ten entries.
  Rationale: Plan 72 published `0009` in `kiroku-store-migrations` 0.3.1.0 before implementation of
  this plan began. Kiroku migrations are forward-only released artifacts, so reusing, renaming, or
  editing `0009` is invalid. The seven-entry Codd import boundary is unchanged; native migrations
  `0008`, `0009`, and `0010` follow it.
  Date: 2026-08-13.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

Milestone 1 established durable, passively expiring replay-history leases without touching an
ordinary append or read statement. Migration `0010` adds the coordinator, constrained audit rows,
partial expiry index, and raw destructive triggers; the public transaction API validates all
bounded inputs, captures the authoritative frontier with database time, preserves owner-aware
renew/release transitions, derives inventory state, and safely prunes only terminal evidence. The
18-example migration suite and 7-example focused Store suite pass. Effect wrappers, supported
hard-delete behavior, stream guards, and operational documentation remain for later milestones.

Milestone 2 connected that core to ordinary Effectful applications and mock interpreters. The
effect interpreter emits acquisition, successful renewal, actual release, prune, and hard-delete
conflict events only after the owning transaction finishes; repeated release emits no false
transition, and reason text is absent from the event constructors. Supported hard delete now locks
the coordinator, reports `HistoryRetentionActive` with active count and earliest expiry, changes
no rows while any lease remains active, and resumes normally after the final release. Ten focused
retention/mock examples and the ten-example legacy hard-delete group pass.


## Context and Orientation

Kiroku is a PostgreSQL-backed event store. An application appends immutable payload rows to
`events` and places junction rows in `stream_events`. Each named source stream has a row in
`streams`; the reserved stream with `stream_id = 0` is `$all`. Its `stream_version` is the
monotonic append frontier, and the corresponding `$all` junction version is a
`GlobalPosition`. A hard delete can remove junctions and payloads without decrementing the
frontier, so a captured position is an inclusive replay ceiling but not a promise that all rows
visible at capture remain visible.

The current interpreter is in `kiroku-store/src/Kiroku/Store/Effect.hs`. Its `HardDeleteStream`
branch runs a Read-Committed transaction that sets
`kiroku.enable_hard_deletes = 'on'`, resolves the stream with the unlocked
`findStreamIdStmt`, deletes `$all` junctions for originated events, deletes every remaining home
or link junction for those event IDs, deletes the target stream's own linked-in junctions, removes
orphan dead letters and payload rows, and finally deletes the stream row. The statements are in
`kiroku-store/src/Kiroku/Store/SQL.hs`. Because the stream row is not locked before the first
junction delete, the current path does not serialize with a reader that locks the stream row.

The link behavior is important. `linkToStreamStmt` can place an event originated by stream A into
stream B. Hard-deleting A deliberately removes that event's junction from B. Therefore a correct
guard on B requires hard delete of A to lock B too. The new affected-stream pre-lock must discover
all non-`$all` streams containing junctions for A's originated events, include A even when it is
empty, lock their `streams` rows in ascending `stream_id` order, and only then run the existing
delete statements. This is the main correction to the improvement request's target-row-only
locking sketch.

Soft delete, undelete, and logical truncate are single `UPDATE streams ... RETURNING stream_id`
statements in `kiroku-store/src/Kiroku/Store/SQL.hs`. Append and link also update the target
stream row while assigning versions. PostgreSQL therefore makes all of them conflict naturally
with a `FOR SHARE` guard on the same row; they do not need a new coordinator lookup. `$all` and
category reads deliberately ignore `deleted_at` and `truncate_before`, so a global fan-in lease
does not need to block those logical lifecycle updates. Per-stream ordered reads do honor both
fields and therefore use the stream guard when a repair needs complete history.

`kiroku-store/src/Kiroku/Store/Transaction.hs` is the supported public boundary for composing
Kiroku work with caller-owned SQL. It already exposes `runTransaction`, `appendToStreamTx`, and
high-level append wrappers. Transactions run at Read Committed in Write mode; the default runner
may retry the complete transaction after a serialization conflict, while `runTransactionNoRetry`
does not. The new lease and stream-history functions follow that pattern. The transaction monad
has no `MonadIO`, so `readStreamForwardTx` returns the Hasql-decoded `RecordedEvent` vector without
running `StoreSettings.decodeHook`; its Haddock and example must state this explicitly.

The public effect is the exported `Store` GADT in `kiroku-store/src/Kiroku/Store/Effect.hs`.
Adding lease constructors is source-breaking for exhaustive custom interpreters even though the
new smart constructors are additive. `kiroku-store/src/Kiroku/Store/Observability.hs` defines
`KirokuEvent`, and `ConnectionSettings.eventHandler` receives those events. The effect wrappers
must emit acquisition, successful renewal, actual release, prune, and hard-delete-conflict events
only after the corresponding database transaction has completed. No event contains an event
payload; lease reason remains queryable through inventory but should not be copied into
low-cardinality metrics labels.

The schema is owned by the forward-only `kiroku-store-migrations` package. Its manifest is
`kiroku-store-migrations/migrations/manifest`; released checkpoint-relation migration `0009.sql`
is the current tail. Use the `kiroku-store-migrate new` command to create migration `0010` and
never edit an already released
payload. `kiroku-store-migrations/test/Main.hs` proves manifest order, fresh apply, strict ledger
verification, idempotent rerun, Codd-history import, and selected schema facts. It must be updated
to expect ten native migrations while retaining the seven historical Codd mappings. The new
migration owns the coordinator row, lease table, active-lease index, and statement-level
retention triggers. The existing row-level `protect_deletion` and statement-level
`protect_truncation` GUC gates stay in place; retention is an additional defense.

The coordinator is a one-row table rather than the `$all` row. Lease acquisition, renewal, and
supported hard delete lock it with `FOR UPDATE`. New statement-level triggers on `events`,
`stream_events`, and `streams` take the same lock before every raw `DELETE` or `TRUNCATE` and
reject the statement if any row has `released_at IS NULL` and `expires_at > clock_timestamp()`.
Because a row lock lasts until transaction end, exactly one side of an acquisition/deletion race
establishes its precondition first. The lease table stores only operational metadata: UUID,
owner, reason, protected frontier, creation/renewal/expiry/release timestamps. It contains no
event payload.

The internal lock order is coordinator first, then affected stream rows in ascending ID order,
then junction and payload rows. The lease and one-stream guard are separate workflows. If a caller
deliberately composes both public transaction primitives in one transaction, it must acquire the
lease before the stream guard. Kiroku's own algorithms and all documentation examples follow that
order; reversing independently exposed transaction combinators is caller-defined SQL and is not a
supported lock order.

The initiating request is
[`docs/improvement-requests/protect-replay-history-from-concurrent-lifecycle-mutations.md`](../improvement-requests/protect-replay-history-from-concurrent-lifecycle-mutations.md),
whose canonical reference is
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-6`. It strengthens the bounded replay
request at `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-1`. Its downstream consumer
is `mori://shinzui/keiro/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers`,
especially the intended child artifacts
`mori://shinzui/keiro/plans/256-rebuild-into-versioned-targets-with-atomic-cutover` and
`mori://shinzui/keiro/plans/257-add-targeted-per-stream-reprojection-to-catalog-operations`.
Mori resolved the Kiroku IR but did not yet resolve those newly created Keiro plan/master-plan
handles during this plan's research; the canonical intended handles are retained as required, and
the registry root `mori://shinzui/keiro` supplied their producing checkout.

Three local ADRs are relevant. [ADR-3](../adr/0003-dedicated-kiroku-schema.md) requires all
Kiroku-owned tables, functions, and triggers to live in the configured Kiroku schema and keeps
ordinary prepared SQL unqualified under the connection's controlled `search_path`.
[ADR-4](../adr/0004-explicit-subscription-checkpoint-lifecycle.md) establishes the pattern of a
public `Hasql.Transaction.Transaction` combinator over Kiroku-owned private schema and distinguishes
the monotonic append frontier from the visible global head. [ADR-5](../adr/0005-three-tier-performance-regression-gates.md)
makes deterministic structural checks and same-process controlled workloads authoritative while
treating historical timing as telemetry. The ADR scan found no existing record for replay-history
retention or lifecycle lock ordering, so implementation must allocate a new stable ADR handle
through the profile workflow rather than guessing its number.

The dependency source was located through Mori at `mori://hasql/hasql/packages/hasql`.
`hasql` 1.10's `interval` encoder and decoder use `Data.Time.Clock.DiffTime`, and
`Hasql.Transaction.statement` accepts the same prepared `Statement` values used by sessions. No
new package or dependency-bound change is needed. The current feasibility baseline, run from the
repository root on 2026-08-13, passed `just perf-check`: nine structural examples passed, and the
production four- and eight-stream append candidates measured `0.81x` and `0.76x` of their
sequential controls against the required maximum ratio of `0.90x`.


## Plan of Work

Implementation proceeds in five milestones. Keep the migration, internal SQL, public surfaces,
tests, documentation, and this living plan synchronized at each stopping point. Do not begin the
release milestone until all local behavior and performance evidence are complete.


### Milestone 1 — Persist and expose durable history-retention leases

Create migration `0010` with the repository's migration scaffolder. Add
`kiroku.history_retention_coordinator` with exactly one checked Boolean row, and add
`kiroku.history_retention_leases` with a UUID primary key, non-empty bounded owner and reason,
non-negative `protected_through`, `created_at`, `renewed_at`, `expires_at`, and nullable
`released_at`. Add an index on `expires_at` for unreleased rows. Update the schema management
comment to name migration `0010`. The migration is additive and must be safe on a populated store.

Add `kiroku-store/src/Kiroku/Store/HistoryRetention/Types.hs` for public types and validation.
Hide raw constructors for the validated duration, owner, reason, and inventory limit. The duration
smart constructor accepts one through 3,600 seconds. Owner is one through 512 UTF-8 bytes, reason
is one through 2,048 bytes, and inventory limit is one through 1,000. Define lease ID, request,
record, handle, derived state, renewal error, release result, inventory query, prune result, and
hard-delete conflict types with `Eq`, `Show`, and `Generic` where their fields allow it.

Add `kiroku-store/src/Kiroku/Store/HistoryRetention/Internal.hs` and, if separation keeps codecs
readable, `kiroku-store/src/Kiroku/Store/HistoryRetention/SQL.hs` as Cabal `other-modules`. These
modules own prepared statements and the shared transaction algorithms. Acquisition locks the
coordinator, reads the authoritative `$all` row frontier, obtains database time and a database
UUID, inserts the lease, and returns the row. Renewal locks the coordinator and target lease,
requires matching owner plus still-active/unreleased state, and computes its non-shortening,
bounded expiry. Release locks the coordinator and row, distinguishes unknown, wrong owner,
expired, newly released, and already released, and changes only its own row. Inventory derives
state with database time, orders deterministically by creation time and ID, and obeys its bounded
limit. Pruning removes only released rows whose release time is before a caller-supplied cutoff and
expired unreleased rows whose expiry is before that cutoff; it never removes an active row.

Expose the transaction combinators and types through a new public module
`kiroku-store/src/Kiroku/Store/HistoryRetention.hs`, the `kiroku-store.cabal` exposed-module list,
and `kiroku-store/src/Kiroku/Store.hs`. Add focused tests in
`kiroku-store/test/Test/HistoryRetention.hs`, register them in the Cabal test suite and
`kiroku-store/test/Main.hs`, and extend `kiroku-store-migrations/test/Main.hs` with exact table,
column, constraint, index, singleton-row, function, and trigger facts. Prove database time,
frontier capture, rollback, duration boundaries, renewal before/after expiry, owner mismatch,
idempotent release, two simultaneous leases, bounded inventory, crash-by-expiry behavior, and
safe pruning. Use PostgreSQL-controlled time waits only for the smallest expiry test; prefer
explicit database timestamps or transaction ordering so the suite remains deterministic.

Milestone acceptance is that the migration suite passes from an empty database and on idempotent
rerun, and the focused store test proves that rolling back acquisition leaves no lease while a
committed lease is visible as Active and later derives as Expired without a worker.


### Milestone 2 — Add the effect surface, telemetry, and typed destructive conflict

Extend the exported `Store` GADT in `kiroku-store/src/Kiroku/Store/Effect.hs` with acquire, renew,
release, bounded inventory, and prune constructors. Implement each `runStorePool` branch by
running the Milestone 1 transaction algorithm; do not copy SQL or state-transition logic into the
interpreter. Add effect smart constructors to `Kiroku.Store.HistoryRetention`. Mock interpreters
must be able to match every operation without importing Hasql.

Extend `KirokuEvent` in `kiroku-store/src/Kiroku/Store/Observability.hs` with committed
acquisition, renewal, actual release, prune, and hard-delete-retention-conflict events. Events
contain IDs, owners, counts, frontiers, and timestamps as appropriate but no event payload and no
reason text intended for metric labels. Document that a direct `*Tx` combinator cannot emit a
process-local event from inside an opaque caller-owned transaction; its persisted lease row is
the durable evidence, and the composing caller emits its own event after commit.

Change the supported `HardDeleteStream` transaction to lock the coordinator before destructive
work. If the stream is absent it still returns `Nothing`. If the stream exists and any lease is
active, return a `HistoryRetentionConflict` carrying active count and earliest expiry, make no
deletion, map it to a specific `StoreError` constructor, and emit the conflict event. Do not alter
the successful `hardDeleteStream` return type. Add a custom, stable SQLSTATE to the database
retention trigger for raw callers, while the supported Haskell path relies on its early typed
query rather than parsing error text. The raw trigger's SQLSTATE is `KR001`.

Add `kiroku-store/test/Test/HistoryRetentionMock.hs` and event-handler assertions to the focused
lease suite. Acceptance is that each effect operation dispatches once in a mock, committed
transitions emit once, rollbacks and no-op repeated releases emit no false transition, and
`hardDeleteStream` returns the typed conflict without changing row counts while any of several
leases remains active.


### Milestone 3 — Guard one stream and correct hard-delete lock coverage

Add `lockStreamHistoryForReplayTx` and `readStreamForwardTx` to
`Kiroku.Store.HistoryRetention`. The guard validates that `$all` is not used, selects the complete
`StreamInfo` by name with `FOR SHARE`, and returns a typed unavailable result for a missing stream.
It returns soft-deleted and logically truncated rows so the caller can enforce its own
completeness policy from exact locked metadata. The forward transactional read reuses the
production prepared statement, retains exclusive-lower cursor and ascending order semantics, and
documents that the guard lasts only until the caller's surrounding transaction ends.

Add a prepared hard-delete pre-lock statement to the internal lifecycle SQL. Given the target
stream ID, discover the target plus every non-`$all` stream containing a junction for an event
originated by the target, join those IDs back to `streams`, order by `stream_id`, and lock the
rows `FOR UPDATE`. Run it after coordinator acquisition and active-lease rejection but before the
first junction delete. Keep the existing delete sequence and result semantics unchanged.

Add `kiroku-store/test/Test/StreamHistoryGuard.hs`. Use two independent pooled connections and
MVars or STM only to establish transaction phases; use short `statement_timeout` settings to make
unexpected blocking fail rather than hang. Prove that a held guard returns exact `deletedAt`,
`truncateBefore`, and version; permits ordered pagination in the same transaction; and blocks
append, link into the guarded stream, soft delete, undelete, logical truncate, hard delete of the
guarded origin, and hard delete of another origin whose event is linked into the guarded stream.
After guard commit and rollback, each waiter must complete. Run opposing hard deletes and
multi-stream appends repeatedly under a timeout to prove deterministic ordering and absence of a
deadlock.

Milestone acceptance is the linked-stream case: guard stream B, start hard delete of origin A
whose event is linked into B, observe that deletion cannot remove B's junction until the guard
ends, then observe normal deletion afterward. A target-row-only implementation fails this test and
must not be accepted.


### Milestone 4 — Defend raw SQL, preserve performance, and deliver durable documentation

Finish migration `0010`'s statement-level defense. A function invoked before `DELETE` and
`TRUNCATE` on `kiroku.events`, `kiroku.stream_events`, and `kiroku.streams` locks the coordinator
row and checks active leases. It composes with, rather than replaces, the existing GUC triggers.
Use the trigger's table schema safely when locating its coordinator and lease table so a
schema-qualified raw statement cannot select a different schema's coordinator through the
caller's `search_path`. With a lease active, a direct transaction that sets
`kiroku.enable_hard_deletes = 'on'` must receive SQLSTATE `KR001` and change no rows. Without
an active lease, current GUC-enabled maintenance remains possible.

Extend `kiroku-store/test/Test/PerformanceStructure.hs` with deterministic exclusions: no new
trigger fires for INSERT or UPDATE on the three data tables; the production append, ordinary read,
soft-delete, undelete, and logical-truncate statements contain no history-retention table or
coordinator reference; the active-lease lookup uses the unreleased-expiry index on a representative
fixture; and invalid validated requests do no pool work. Do not weaken ADR-5's current controlled
append workload or thresholds. Run `just perf-check` before and after the feature. Historical
telemetry may identify unrelated movement but cannot replace a failed structural or controlled
gate.

Update module Haddocks in `Kiroku.Store.HistoryRetention`,
`Kiroku.Store.Lifecycle`, `Kiroku.Store.Transaction`, and
`Kiroku.Store.Observability`. Add copyable examples to `docs/user/README.md` or the most relevant
existing reading guide, and update `docs/PRODUCTION-DEPLOYMENT.md` with runtime grants, lease
inventory/pruning, maximum outage after a crash, renewal scheduling, direct-SQL behavior, custom
SQLSTATE, emergency maintenance boundaries, and the distinction between lease ownership and
authorization. Update both package READMEs if their migration counts or public module inventory
are stated, plus `kiroku-store/CHANGELOG.md` and `kiroku-store-migrations/CHANGELOG.md`.

Create a capability concept for protected replay history or update an existing concept only if it
already owns that exact contract. Mark IR-6 implemented only after every local acceptance test is
green, add evidence paths and timestamps, and maintain the OKF logs. Allocate a new ADR through
`okf id next` and record the coordinator choice, conservative global block, affected-stream lock
order, transaction/read-hook boundary, and hot-path exclusion. Summarize the ADR inside this plan
as well so the plan remains self-contained.

Milestone acceptance is the full local gate: formatting, diff checks, build, all tests, migration
tests, `nix flake check`, strict capability/ADR/improvement-request validation, and the unchanged
`just perf-check` thresholds all pass. Record exact counts and ratios in Progress and Outcomes &
Retrospective.


### Milestone 5 — Release and prove downstream consumption

Audit the actual public API diff and use PVP to determine independent next versions for
`kiroku-store` and `kiroku-store-migrations`; include another in-repository package only when its
dependency bound or exposed API actually requires a release. Before choosing versions or bounds,
query Hackage and upstream tags as authoritative sources and use `mori registry dependents
shinzui/kiroku --packages --json` to identify consumers. Do not infer a cohort from repository
proximity.

Invoke the repository's `release` skill and follow its checks exactly. Stop for its explicit
confirmation immediately before external publication. After confirmed release, build a clean
temporary Cabal consumer against the Hackage versions, importing
`Kiroku.Store.HistoryRetention`, constructing a validated request, compiling the transaction
lease/guard example, and not relying on the source checkout. Verify the new upstream tags and
Hackage package pages, refresh Mori registry data through the normal registry workflow, and record
the exact released canonical package evidence in IR-6 and this plan. Downstream Keiro adoption is
not implemented here; hand off the released contract through the existing canonical Keiro
artifacts.

Milestone acceptance is that the released packages, tags, GitHub releases, Hackage docs, clean
consumer, and refreshed Mori package metadata all agree. If publication is not authorized, leave
the plan accurately marked complete through Milestone 4 and pending at Milestone 5 rather than
claiming the improvement request is fully delivered.


## Concrete Steps

Run every command in this section from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless a command explicitly changes
directory. Begin by preserving the user's existing uncommitted documentation work and recording
the baseline:

```bash
git status --short
just perf-check
```

At plan creation, `git status --short` showed user-owned changes in the improvement-request
bundle and plan 72; do not overwrite or stage them incidentally. The baseline performance result
was:

```text
performance structure: 9 examples, 0 failures
production-pipeline-4: 0.81x of sequential control
production-pipeline-8: 0.76x of sequential control
All 4 controlled workload tests passed
```

Create the forward migration only through the package CLI:

```bash
cabal run kiroku-store-migrate -- new \
  --manifest kiroku-store-migrations/migrations/manifest \
  --description "add replay history retention"
```

The command should create and append `kiroku-store-migrations/migrations/0010.sql`. If it prints a
different path, use the printed path and update this plan before continuing; do not rename the
generated migration manually. After editing it and the migration assertions, run:

```bash
cabal test kiroku-store-migrations:kiroku-store-migrations-test \
  --test-show-details=direct
```

Expected output ends with zero failures and proves ten native migrations, seven legacy Codd
history mappings, fresh apply, strict verify, and idempotent rerun. Do not change the seven-entry
Codd mapping to include migrations `0008`, `0009`, or `0010`; those migrations are native forward
work after the legacy import boundary.

Build and run each focused store group as it lands:

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "history retention"'
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "history retention mock"'
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "stream history guard"'
```

Each group must report zero failures. Tests that coordinate two transactions must impose a bounded
database statement timeout and clean up both connections on assertion failure. A timeout is a test
failure, not evidence that blocking worked; blocking is proved by observing that the waiter has not
completed at a controlled phase, ending the guard, and then observing successful completion.

Run the raw SQL and performance selections:

```bash
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "history retention raw SQL"'
just perf-structure
just perf-check
```

The raw SQL group must prove both `DELETE` and `TRUNCATE` refusal under an active lease after
`SET LOCAL kiroku.enable_hard_deletes = 'on'`, and normal destructive behavior after the final
lease is released or expired. `perf-structure` must include the new hot-path-exclusion and active
lease index assertions. `perf-check` must retain the controlled workload's declared `0.90x`
maximum production/control ratio; do not adjust that threshold to accommodate this feature.

Allocate and validate the durable ADR using the profiled bundle workflow:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Use the returned unused handle in the new ADR; do not assume it is `ADR-6`. Add its bundle-log
entry with `okf log add` after the record has its final timestamp. Apply the analogous local
profile/ID workflow for a new capability rather than guessing its handle.

After updating IR-6 and the documentation bundles, run:

```bash
just capabilities-validate
just adr-validate
okf validate docs/improvement-requests \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce \
  --log-enforce
```

Expected output for each bundle is a successful validation with no profile or log errors. Preserve
Mori's canonical cross-repository references even if a just-created Keiro artifact still reports a
registry-resolution lag.

Before local completion, format, inspect, and run all repository gates:

```bash
nix fmt
git diff --check
git status --short
git diff --stat
just build
just test
just perf-check
nix flake check
```

Review the complete diff, especially ordinary SQL statements and the migration manifest. Record
test counts, benchmark ratios, and the exact changed-file inventory in this plan. Every commit
made while implementing must follow Conventional Commits and include both trailers:

```text
ExecPlan: docs/plans/73-protect-replay-history-with-retention-leases-and-stream-guards.md
Intention: intention_01kzyay9mmejbsg12a31xmxzce
```

At release time, first refresh dependency and authoritative release evidence:

```bash
mori registry show shinzui/kiroku --full
mori registry dependents shinzui/kiroku --packages --json
git tag --list '*kiroku*' --sort=-version:refname
```

Then invoke the `release` skill. Its current instructions are authoritative for Hackage queries,
tag verification, package checks, source distributions, Haddock builds, confirmation, commits,
pushes, uploads, and GitHub releases. Do not paste guessed publication commands into this plan and
do not publish before confirmation.


## Validation and Acceptance

Acceptance is behavioral, not merely compilation.

First, acquire a lease in a transaction on a store containing events. Its UUID, owner, reason,
protected frontier, creation time, and expiry come from the committed row; `protectedThrough`
equals the authoritative frontier observed in that transaction. Condemning or rolling back the
transaction leaves no row. The effect and transaction APIs return the same semantics.

Second, race acquisition against supported hard delete and against direct GUC-enabled deletion on
independent connections. Exactly one side wins the coordinator. If acquisition wins, supported
hard delete returns `HistoryRetentionConflict`, raw `DELETE` and `TRUNCATE` return the documented
SQLSTATE `KR001`, and row counts plus repeated bounded `$all`/category reads through the captured
frontier remain unchanged. If deletion wins, acquisition commits afterward and protects the
post-delete retained store. No test may accept a partially deleted state.

Third, renew a live lease before expiry. Database time advances expiry without shortening it and
never places it more than one hour ahead of the renewal statement's database time. Renewal after
expiry, after release, for an unknown ID, or with a mismatched owner returns a distinct typed result
and never resurrects or changes the row. Releasing is idempotent, and releasing one of several
leases leaves destructive work blocked by the others. After the last lease releases or expires,
hard delete and authorized raw maintenance succeed.

Fourth, inventory returns deterministic, bounded records whose Active, Expired, and Released
states agree with database time. Pruning deletes only terminal rows older than the cutoff. A
simulated crashed owner requires no cleanup process: after expiry, destructive work proceeds and
inventory still exposes the abandoned evidence until pruning.

Fifth, hold `lockStreamHistoryForReplayTx` on a live stream and read its complete ordered history
inside the same transaction. The returned `StreamInfo` is the exact locked version, deletion time,
and truncate-before value. While held, append, link, soft delete, undelete, logical truncate, hard
delete of that origin, and hard delete of another origin linked into the guarded stream all wait.
After commit or rollback they complete. Missing streams return a typed unavailable result; a
soft-deleted or truncated existing stream returns locked metadata so the caller can refuse it
before any target mutation.

Sixth, run opposing multi-stream appends, guarded reads, and hard deletes repeatedly with bounded
statement timeouts. There is no deadlock. Inspection or test evidence shows the global order is
coordinator first, then affected `streams` rows by ascending `stream_id`, then junction/payload
deletes. No Kiroku-owned lifecycle or lease algorithm acquires the coordinator after taking an
affected stream row lock; a caller combining lease and stream guard follows the documented
lease-before-guard order.

Seventh, prove the performance boundary structurally. The migration installs no history-retention
trigger for INSERT or UPDATE. The production append, ordinary read, soft-delete, undelete, and
logical-truncate statements have no coordinator or lease reference and perform the same number of
round trips as before. `just perf-check` passes ADR-5's unchanged structural checks and controlled
append ratios. Any failure is investigated; neither thresholds nor baseline rows are changed just
to make the feature pass.

Eighth, all public Haddocks and operator docs contain copyable long-rebuild and one-transaction
repair examples, state the one-hour maximum and renewal responsibility, distinguish ownership from
authorization, explain passive expiry observation, and describe the raw SQL/emergency-maintenance
boundary. IR-6, the capability catalog, changelogs, migration facts, and the newly allocated ADR
all validate under their repository profiles.

Finally, the full build, every test suite, migration verification, performance gate, and Nix checks
pass. If release is authorized, the Hackage packages and upstream tags compile from a clean
consumer and Mori reports the released versions. If release is not authorized, local
implementation is complete but IR-6 and Milestone 5 remain pending publication.


## Idempotence and Recovery

The transaction operations are retry-safe. Acquisition rolled back by PostgreSQL leaves neither
its UUID row nor caller-owned metadata. Hasql may retry a transaction after a serialization
failure; only the successful attempt's database-generated lease is visible. Release reports an
already-released result on repetition. Renewal never recreates an expired or released lease.
Inventory is read-only. Prune is monotonic and may be repeated with the same cutoff.

The coordinator and trigger functions are installed by a forward-only migration. The migration
must use idempotent object creation/replacement where repository policy permits, but once `0010` is
released its bytes and manifest identity are immutable. On a disposable database, discard and
recreate the database to retry. On a persistent database, take a backup before upgrade; recover
from a bad applied migration by restoring the backup or appending a corrective migration, never by
editing `0010` or deleting `pgmigrate` ledger rows manually.

The coordinator row must never be deleted by application cleanup. A missing or duplicate
coordinator is a schema-integrity failure, not a signal to continue without protection. Migration
and store tests assert exactly one row. If an operator must recover a damaged coordinator, stop
destructive work and lease callers, repair it under the migration/owner role, verify the migration
plan and singleton assertion, then resume.

An expired lease needs no state mutation before hard delete; Active is a derived predicate.
Pruning is optional operational hygiene and cannot restore protection. Reacquiring after expiry
creates a new UUID and protection interval. The replay owner must restart or independently
revalidate its work because the gap is not retroactively protected.

Concurrency tests restore `statement_timeout` with `SET LOCAL` or by ending the test transaction,
and every acquired connection is bracketed. If a test fails while a waiter is blocked, cancel the
async waiter and release both connections so later tests do not inherit locks. Do not solve a hang
by increasing an unbounded timeout.

Release operations are externally irreversible in the ordinary workflow. Before publication,
rerun the release skill from the actual clean commit and inspect versions, tags, and package
contents. If confirmation is declined or any preflight fails, publish nothing and leave Milestone
5 unchecked. After a partial external release, follow the release skill's recovery guidance and
record exact state in Surprises & Discoveries before taking another action.


## Interfaces and Dependencies

`kiroku-store/src/Kiroku/Store/HistoryRetention/Types.hs` owns the public data model. Exact field
names may be refined for repository naming conventions, but the semantic surface must remain this
closed and typed shape:

```haskell
newtype HistoryRetentionLeaseId = HistoryRetentionLeaseId UUID
newtype HistoryRetentionLeaseOwner = HistoryRetentionLeaseOwner Text
newtype HistoryRetentionLeaseReason = HistoryRetentionLeaseReason Text
newtype HistoryRetentionLeaseDuration = HistoryRetentionLeaseDuration DiffTime

data HistoryRetentionLeaseRequest = HistoryRetentionLeaseRequest
  { owner :: HistoryRetentionLeaseOwner
  , reason :: HistoryRetentionLeaseReason
  , duration :: HistoryRetentionLeaseDuration
  }

data HistoryRetentionLeaseHandle = HistoryRetentionLeaseHandle
  { leaseId :: HistoryRetentionLeaseId
  , owner :: HistoryRetentionLeaseOwner
  }

data HistoryRetentionLeaseState
  = HistoryRetentionLeaseActive
  | HistoryRetentionLeaseExpired
  | HistoryRetentionLeaseReleased

data HistoryRetentionLease = HistoryRetentionLease
  { leaseId :: HistoryRetentionLeaseId
  , owner :: HistoryRetentionLeaseOwner
  , reason :: HistoryRetentionLeaseReason
  , protectedThrough :: GlobalPosition
  , createdAt :: UTCTime
  , renewedAt :: UTCTime
  , expiresAt :: UTCTime
  , releasedAt :: Maybe UTCTime
  , state :: HistoryRetentionLeaseState
  }

data HistoryRetentionRenewalError
  = HistoryRetentionRenewalUnknown
  | HistoryRetentionRenewalOwnerMismatch
  | HistoryRetentionRenewalExpired
  | HistoryRetentionRenewalReleased

data HistoryRetentionReleaseResult
  = HistoryRetentionReleased HistoryRetentionLease
  | HistoryRetentionAlreadyReleased HistoryRetentionLease
  | HistoryRetentionReleaseExpired HistoryRetentionLease
  | HistoryRetentionReleaseUnknown
  | HistoryRetentionReleaseOwnerMismatch

data HistoryRetentionConflict = HistoryRetentionConflict
  { activeLeaseCount :: Int64
  , earliestExpiry :: UTCTime
  }

newtype HistoryRetentionInventoryLimit = HistoryRetentionInventoryLimit Int32

data HistoryRetentionInventoryQuery = HistoryRetentionInventoryQuery
  { limit :: HistoryRetentionInventoryLimit
  }

data HistoryRetentionPruneResult = HistoryRetentionPruneResult
  { expiredPruned :: Int64
  , releasedPruned :: Int64
  }

data StreamHistoryUnavailable
  = StreamHistoryNotFound StreamName
  | StreamHistoryReserved StreamName
```

The module also exports smart constructors and documented constants for validation. Raw validated
newtype constructors remain hidden:

```haskell
mkHistoryRetentionLeaseOwner
  :: Text -> Either HistoryRetentionRequestError HistoryRetentionLeaseOwner

mkHistoryRetentionLeaseReason
  :: Text -> Either HistoryRetentionRequestError HistoryRetentionLeaseReason

mkHistoryRetentionLeaseDuration
  :: DiffTime -> Either HistoryRetentionRequestError HistoryRetentionLeaseDuration

mkHistoryRetentionInventoryLimit
  :: Int32 -> Either HistoryRetentionInventoryError HistoryRetentionInventoryLimit

maxHistoryRetentionLeaseDuration :: DiffTime
```

`kiroku-store/src/Kiroku/Store/HistoryRetention.hs` exports the transaction-composable core:

```haskell
acquireHistoryRetentionLeaseTx
  :: HistoryRetentionLeaseRequest
  -> Tx.Transaction HistoryRetentionLease

renewHistoryRetentionLeaseTx
  :: HistoryRetentionLeaseHandle
  -> HistoryRetentionLeaseDuration
  -> Tx.Transaction (Either HistoryRetentionRenewalError HistoryRetentionLease)

releaseHistoryRetentionLeaseTx
  :: HistoryRetentionLeaseHandle
  -> Tx.Transaction HistoryRetentionReleaseResult

historyRetentionLeaseInventoryTx
  :: HistoryRetentionInventoryQuery
  -> Tx.Transaction (Vector HistoryRetentionLease)

pruneHistoryRetentionLeasesTx
  :: UTCTime
  -> Tx.Transaction HistoryRetentionPruneResult

lockStreamHistoryForReplayTx
  :: StreamName
  -> Tx.Transaction (Either StreamHistoryUnavailable StreamInfo)

readStreamForwardTx
  :: StreamName
  -> StreamVersion
  -> Int32
  -> Tx.Transaction (Vector RecordedEvent)
```

The Haddock for these functions states the supported composite lock order explicitly: when one
transaction needs both a durable lease operation and a stream guard, execute the lease operation
first and `lockStreamHistoryForReplayTx` second. Kiroku's own examples never reverse that order.

The same module exports effect smart constructors named without the `Tx` suffix for acquire,
renew, release, inventory, and prune. They require `Store :> es` and return the same semantic
types. They are backed by corresponding `Store` constructors; no stream-guard effect constructor
is added because a row lock is useful only inside a caller-owned transaction.

`hardDeleteStream` keeps its current public success type. Its new semantic failure is represented
in `Kiroku.Store.Error.StoreError`:

```haskell
HistoryRetentionActive !StreamName !HistoryRetentionConflict
```

`Kiroku.Store.Observability.KirokuEvent` gains additive constructors for committed lease
transitions, prune results, and hard-delete conflicts. The implementer must choose concise
constructor field sets that avoid reason text and event payloads, document emission timing, and
update exhaustive in-repository matches.

The database interface contains exactly one coordinator row and an append-only-until-pruned lease
audit table. Active means `released_at IS NULL AND expires_at > clock_timestamp()`. Released takes
precedence over expired when deriving state. All coordinator-taking operations acquire it first.
The raw destructive trigger derives its schema from `TG_TABLE_SCHEMA`; public Hasql statements use
the connection's ADR-3-controlled `search_path`. The affected-stream lock statement excludes
`stream_id = 0`, locks actual `streams` rows in ascending ID order, and completes before any delete
statement.

Migration `0010` uses these stable database object names: tables
`kiroku.history_retention_coordinator` and `kiroku.history_retention_leases`; constraint
`chk_history_retention_coordinator_singleton`; index
`ix_history_retention_leases_unreleased_expiry`; function
`kiroku.protect_replay_history_from_destruction()`; and per-table triggers named
`protect_replay_history_delete` and `protect_replay_history_truncate`. The coordinator has a
Boolean primary key constrained to `TRUE`, and the migration inserts that one row with
`ON CONFLICT DO NOTHING`. The lease table shape is:

```sql
lease_id         UUID        PRIMARY KEY DEFAULT uuidv7(),
owner            TEXT        NOT NULL,
reason           TEXT        NOT NULL,
protected_through BIGINT     NOT NULL,
created_at       TIMESTAMPTZ NOT NULL,
renewed_at       TIMESTAMPTZ NOT NULL,
expires_at       TIMESTAMPTZ NOT NULL,
released_at      TIMESTAMPTZ
```

Checks enforce the documented byte lengths, non-negative frontier, expiry after creation, and
release no earlier than creation. The unreleased-expiry index is a partial B-tree on `expires_at`
where `released_at IS NULL`. The trigger function takes the coordinator lock, queries the active
predicate, and raises SQLSTATE `KR001` before the destructive statement when a lease is active.
There is no second GUC that overrides this check. The existing
`kiroku.enable_hard_deletes = 'on'` requirement remains necessary but is no longer sufficient
while history is retained.

No new library dependency is introduced. Use the existing `time`, `uuid`, `vector`, `hasql`,
`hasql-pool`, `hasql-transaction`, and Effectful dependencies. The Hasql source and transaction
API are identified canonically by `mori://hasql/hasql/packages/hasql` and
`mori://hasql/hasql/packages/hasql-transaction`. Do not change their bounds unless implementation
discovers a real incompatibility, and if it does, re-run Mori discovery and verify the current
released version against Hackage and upstream tags before editing bounds.

PostgreSQL 17 remains the minimum. Use row locks, statement-level triggers,
`clock_timestamp()`, partial B-tree indexes, and the existing schema-local `uuidv7()` fallback; do
not require a new extension. Kiroku migrations remain the sole owner of the tables, functions,
indexes, and triggers. Keiro consumes only these public Haskell APIs and never queries or locks a
Kiroku private relation.


Revision note (2026-08-13): Implementation began after plan 72 had released migration `0009` in
`kiroku-store-migrations` 0.3.1.0. All replay-history-retention migration instructions and native
manifest counts now point to forward migration `0010` and ten native entries while retaining the
seven-entry Codd boundary.
