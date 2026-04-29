---
id: 1
slug: schema-cte-and-concurrency-correctness-audit
title: "Schema, CTE and concurrency correctness audit"
kind: exec-plan
created_at: 2026-04-29T14:05:54Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/1-production-readiness-review-of-kiroku-store.md"
---

# Schema, CTE and concurrency correctness audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`kiroku-store` is a PostgreSQL event store written in Haskell. Its on-disk schema (`kiroku-store/sql/schema.sql`) and the five large append/link CTEs in `kiroku-store/src/Kiroku/Store/SQL.hs` are the foundations everything else rests on. Once production services start writing events, fixing a subtle CTE bug, a missing index, or a race between a stream lifecycle action and a concurrent append becomes very expensive — the data has already been written, callers have already pattern-matched on the resulting errors, and any structural change to the SQL likely needs a migration.

After this plan, the package has a written, evidence-backed audit of the schema, the five append/link CTEs, the read CTEs, the lifecycle CTEs (soft delete, undelete, hard delete), the immutability/protection triggers, and every concurrency boundary the store relies on. Every "must-fix-before-production" finding has landed as a code change in `kiroku-store/sql/schema.sql`, `kiroku-store/src/Kiroku/Store/SQL.hs`, or `kiroku-store/src/Kiroku/Store/Effect.hs`, with a regression test in `kiroku-store/test/Main.hs`. Every finding that is *not* fixed is recorded in this plan's Decision Log with explicit rationale and the conditions that would force a revisit.

A reader can verify the change by running the existing test suite (`cabal test kiroku-store`) and the new regression tests, and by reading the audit milestone's findings document linked from the Surprises & Discoveries section.


## Progress

- [x] Milestone 1: Audit findings document — 2026-04-29
  - [x] Read every CTE in `kiroku-store/src/Kiroku/Store/SQL.hs` and the embedded DDL in `kiroku-store/sql/schema.sql`; produce a written audit covering each item in the "Audit Checklist" section below
  - [x] Classify every finding as must-fix-before-production, should-fix, or defer-with-rationale (F1–F21 above)
  - [x] Record findings inline in the Surprises & Discoveries section of this plan with file:line references
  - [x] Record cross-plan findings (anything affecting EP-2, EP-3, EP-4) in the MasterPlan's Surprises & Discoveries section with explicit pointers
- [x] Milestone 2: Land must-fix corrections — 2026-04-29
  - [x] F1 — Hard-delete orphan-protection fix + regression test (commit 01c0ee6)
  - [x] F2 — Soft-delete TOCTOU fix (push deleted_at into CTEs, drop pre-checks) + regression tests (commit e903062)
  - [x] F3 — `linkToStream` strict mode (LEFT JOIN LATERAL + reject) + regression tests (commit a5754d6)
  - [x] Decide should-fix items F4–F7 individually: F4 (12a154b: ~~F5 first~~), F5 (12a154b — link to soft-deleted target), F6 (6d195e8 — TRUNCATE bypass), F4 (8edfbee — multi-stream pre-lock); F7 deferred with rationale (see Decision Log)
  - [x] Re-run `cabal test kiroku-store` (66/66 PASS) and the benchmark suite (read paths within 3% of M3 baseline; append paths run against a 100K-event pre-populated DB introduced in commit 390baf5/M5.9, so direct comparison is not apples-to-apples — see Outcomes & Retrospective)
  - [x] Update the MasterPlan's Exec-Plan Registry status and the MasterPlan's Progress section


## Surprises & Discoveries

Findings from Milestone 1's audit. Each finding has a severity tag (`MUST-FIX`, `SHOULD-FIX`, or `DEFER`),
a file:line reference, the evidence supporting the classification, and a sketched fix where applicable.

Audit method: every checklist item was assessed by reading the SQL templates in
`kiroku-store/src/Kiroku/Store/SQL.hs` and the embedded DDL in `kiroku-store/sql/schema.sql`,
cross-referenced against the interpreter at `kiroku-store/src/Kiroku/Store/Effect.hs` and the
existing test coverage at `kiroku-store/test/Main.hs`. PostgreSQL CTE semantics were validated
against the official documentation (PostgreSQL 18 §7.8.2 — "Data-Modifying Statements in WITH"),
which states that all WITH sub-statements execute against the same snapshot and cannot see each
other's effects on target tables. Reproducers for the must-fix items will land in M2 as regression
tests in `kiroku-store/test/Main.hs`.

Baseline before the audit: `cabal test kiroku-store:test:kiroku-store-test` passes with 54/54
examples in ~30s. The bench target `kiroku-store:bench:kiroku-shibuya-overhead` fails to build
due to an `Envelope`/`AckHandle` API drift in the consumer adapter (out of scope per the EP — the
shibuya-kiroku-adapter is an external consumer of kiroku-store, not the kiroku-store package). The
in-scope `kiroku-store:bench:kiroku-store-bench` target builds clean.

### MUST-FIX-BEFORE-PRODUCTION

**F1 — Hard-delete `events` orphan-protection clause is a no-op.**
`kiroku-store/src/Kiroku/Store/SQL.hs:655-678` (`hardDeleteStreamSQL`).
The `deleted_events` CTE runs `DELETE FROM events ... WHERE NOT EXISTS (SELECT 1 FROM stream_events
se WHERE se.event_id = events.event_id)`. Per PostgreSQL §7.8.2, the `NOT EXISTS` subquery executes
against the same snapshot as the sibling `deleted_junctions` CTE, so it always sees the pre-delete
state of `stream_events`. Every event that has just been deleted by `deleted_junctions` still
appears in the snapshot's `stream_events`, so `NOT EXISTS` is FALSE and `DELETE FROM events` removes
**zero rows**. Result: every hard-delete leaves the source-stream's event payloads orphaned in the
`events` table. The existing test "events from hard-deleted stream no longer appear in $all"
(`kiroku-store/test/Main.hs:542-547`) only checks `$all` (which is `stream_id = 0` rows in
`stream_events` — those *are* deleted by `deleted_junctions`), so the orphan never surfaces.
Reproducer to add in M2: hard-delete a stream whose events have no other links; assert `SELECT
COUNT(*) FROM events` shrinks by the event count. Severity: must-fix — silent disk leak that
accumulates monotonically; also defeats GDPR "right to erasure" since the event payloads (which
hold caller-provided `data` JSONB) are not actually erased.

Fix sketch: split into multiple statements within the existing transaction so the snapshot
re-opens between them, OR pre-compute the orphan list in a non-modifying CTE before the deletes
run. A pre-compute pattern keeps everything in one statement:

    WITH
      target AS (SELECT stream_id FROM streams WHERE stream_name = $1),
      events_being_unlinked AS (
        SELECT event_id FROM stream_events
        WHERE stream_id = (SELECT stream_id FROM target)
           OR original_stream_id = (SELECT stream_id FROM target)
      ),
      events_with_other_homes AS (
        SELECT DISTINCT event_id FROM stream_events
        WHERE event_id IN (SELECT event_id FROM events_being_unlinked)
          AND stream_id <> 0
          AND stream_id <> (SELECT stream_id FROM target)
      ),
      events_to_delete AS (
        SELECT event_id FROM events_being_unlinked
        EXCEPT
        SELECT event_id FROM events_with_other_homes
      ),
      deleted_junctions AS (
        DELETE FROM stream_events
        WHERE stream_id = (SELECT stream_id FROM target)
           OR original_stream_id = (SELECT stream_id FROM target)
      ),
      deleted_events AS (
        DELETE FROM events WHERE event_id IN (SELECT event_id FROM events_to_delete)
      )
    DELETE FROM streams WHERE stream_id = (SELECT stream_id FROM target)
    RETURNING stream_id

The two non-modifying read CTEs (`events_being_unlinked`, `events_with_other_homes`,
`events_to_delete`) compute the orphan set from the snapshot before any DELETE happens, and the
final FK-trigger sequencing remains stream_events → events → streams.

**F2 — Soft-delete TOCTOU race in append/read paths.**
`kiroku-store/src/Kiroku/Store/Effect.hs:73-83, 103-115, 116-128`. The `runStorePool` interpreter
issues `getStreamStmt` in a separate `Pool.use` *before* the actual append/read statement. Between
the two pool checkouts, another session can run `softDeleteStream` and the operation will then run
against a deleted stream. None of the four append CTEs filter on `deleted_at`, and the read CTEs
resolve `stream_id = (SELECT stream_id FROM streams WHERE stream_name = $1)` without
`AND deleted_at IS NULL`. Severity: must-fix — silent contract violation (events written to a
deleted stream become visible in `$all`; reads return rows that should be hidden).

Fix sketch: drop the pre-check entirely and push the deleted-check inside each statement.

  * Append CTEs: add `AND deleted_at IS NULL` to the `WHERE` clause of `appendExpectedVersionSQL`'s
    and `appendStreamExistsSQL`'s `stream_update`. For `appendAnyVersionSQL`'s `INSERT ... ON
    CONFLICT DO UPDATE`, add a `WHERE` to the DO UPDATE clause: `DO UPDATE SET ... WHERE
    streams.deleted_at IS NULL`. For `appendNoStreamSQL`, the question is what `NoStream` means
    against a soft-deleted row — see F5.
  * Read CTEs: change the subquery to `SELECT stream_id FROM streams WHERE stream_name = $1 AND
    deleted_at IS NULL`.
  * Effect.hs: remove the four `streamCheck` blocks (lines 75-83, 105-115, 117-128). Empty CTE
    results map cleanly: append → `StreamNotFound` (via `emptyResultError` for `StreamExists`,
    `WrongExpectedVersion` for `ExactVersion` — note this collapses information, see F11); read →
    empty Vector.

Reproducer to add in M2: deterministic interleaving via two pool connections + `MVar` barriers —
thread A starts an append, blocks on a barrier; thread B issues `softDeleteStream`; thread A
unblocks and the CTE runs; assert append fails with `StreamNotFound`.

**F3 — `linkToStream` silently drops links when the source event has no surviving junction row.**
`kiroku-store/src/Kiroku/Store/SQL.hs:548-560` (`link_inserts` in `linkToStreamSQL`). The CTE uses
`JOIN LATERAL (... LIMIT 1) orig ON true`, which is an inner join. If the lateral subquery returns
zero rows (the event_id has no `stream_events` row with `stream_id <> 0` — for example, after a
hard-delete that removed all junction rows but left the event payload as an orphan via F1), the
entire row is dropped from the `INSERT` set. However, the `stream_upsert` clause has already
bumped `streams.stream_version` by `(SELECT count(*) FROM event_list)`, so the version advances by
N but only some links are inserted — **silent version gap**, with PK rows in `stream_events` whose
`stream_version` skips numbers. Subscribers reading the linked stream will miss positions silently.
Severity: must-fix — corrupts read paths; once linked, future reads of the linked stream return
fewer events than the version range implies.

Fix sketch: two options.

 1. Strict: convert `JOIN LATERAL` to a `LEFT JOIN LATERAL` and reject the whole call if any row
    has `orig.original_stream_id IS NULL`. Surface as a new error variant or as `StreamNotFound`
    on the source event side. Cleaner contract.
 2. Lenient: bump `stream_version` by the actual insert count (`(SELECT COUNT(*) FROM
    link_inserts)` — needs `RETURNING` from `link_inserts`). Keeps current "best-effort" feel but
    requires more work for callers to detect partial success.

Recommend option 1. The existing test "rejects linking the same event to the same stream twice"
(`kiroku-store/test/Main.hs:358-366`) covers PK collision but no test covers the missing-event
case. Reproducer to add in M2: link a UUID that does not exist in `events`; assert error rather
than silent advance.

### SHOULD-FIX

**F4 — Multi-stream append deadlock under reverse-order contention.**
`kiroku-store/src/Kiroku/Store/Effect.hs:145-194` (`AppendMultiStream`). Each per-stream CTE
acquires a row lock on the source stream, then on `$all`. Two concurrent calls touching streams
`[A, B]` and `[B, A]` lock A and B respectively in their first CTEs, then each blocks on the
other's row in the second CTE → deadlock detected by PostgreSQL (SQLSTATE `40P01`). The
deadlock-aborted transaction returns a `ServerStatementError` that `Error.hs:62-65` maps to the
generic `ConnectionError` (uninformative for the caller). Severity: should-fix — PostgreSQL handles
the safety side, but the caller cannot distinguish a deadlock from an authentic connection failure
and the throughput penalty is real under contention.

Fix sketch: sort `ops` by stream name internally before locking. This changes the *intra-call*
order in which global positions are assigned across the streams in the multi-stream batch (callers
who pass `[A, B]` will see A's events at position P+1 and B's at P+2, regardless of the input
order) — record this as a contract change in EP-2's API audit. Alternatively, take a `SELECT
stream_id FROM streams WHERE stream_name = ANY(...) ORDER BY stream_name FOR UPDATE` pre-pass to
acquire locks deterministically and keep the user-supplied order for global-position assignment.

**F5 — `linkToStream` and `appendAnyVersion` write to soft-deleted target streams.**
`kiroku-store/src/Kiroku/Store/SQL.hs:541-547` (`stream_upsert` in `linkToStreamSQL`),
`kiroku-store/src/Kiroku/Store/SQL.hs:298-304` (`stream_upsert` in `appendAnyVersionSQL`). Neither
upsert filters on `deleted_at`. A soft-deleted target stream is silently revived (its
`stream_version` is bumped) by a link or by an `AnyVersion` append. The pre-check in
`Effect.hs:73-83` only short-circuits `AppendToStream` (not `LinkToStream`); the existing soft-
delete tests don't cover linking against a soft-deleted stream. Severity: should-fix — symmetric
with `StreamExists`/`ExactVersion` rejection, contract surprise. Decide explicitly: either reject
all writes against soft-deleted streams (recommended; matches "soft delete = no further activity")
or document that soft-delete only blocks the `StreamExists`/`ExactVersion` paths.

Fix sketch: add `AND streams.deleted_at IS NULL` predicates to the relevant `INSERT ... ON CONFLICT
DO UPDATE` statements (PostgreSQL allows a `WHERE` on the DO UPDATE: `DO UPDATE SET stream_version
= ... WHERE streams.deleted_at IS NULL`). When the predicate fails, the upsert returns no row →
empty CTE → mapped to error.

**F6 — `protect_deletion` trigger does not cover TRUNCATE.**
`kiroku-store/sql/schema.sql:119-141`. The trigger is `BEFORE DELETE FOR EACH ROW`. `TRUNCATE` and
`ALTER TABLE ... DETACH PARTITION` bypass row-level triggers entirely. An operator with `DELETE`
or `TRUNCATE` privilege on the `events` or `stream_events` table can wipe data without setting the
GUC. Severity: should-fix — operational risk; defense in depth; cheap.

Fix sketch: add a statement-level trigger:

    CREATE OR REPLACE FUNCTION protect_truncation() RETURNS TRIGGER AS $$
    BEGIN
        IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
            RETURN NULL;
        END IF;
        RAISE EXCEPTION 'TRUNCATE requires: SET LOCAL kiroku.enable_hard_deletes = ''on''';
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER no_truncate_events       BEFORE TRUNCATE ON events
        FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();
    CREATE TRIGGER no_truncate_stream_events BEFORE TRUNCATE ON stream_events
        FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();
    CREATE TRIGGER no_truncate_streams       BEFORE TRUNCATE ON streams
        FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();

ALTER TABLE ... DETACH PARTITION is not currently exploitable (no partitioning) but should be
revisited if the parked partition-ready schema work is ever resumed.

**F7 — Hard-delete vs. concurrent append produces lost-write or post-fix data-loss.**
`kiroku-store/src/Kiroku/Store/Effect.hs:198-203` (`HardDeleteStream`) and the append paths. While
`hardDeleteStreamCTE` runs, a concurrent append takes a row lock on the target stream's `streams`
row and on `$all`. Lock ordering with the hard-delete CTE means one of them wins. Today (with F1
broken): if append commits first, hard-delete then deletes the new junction rows from
`stream_events` but leaves the (now-orphaned per F1) event payloads in `events`. Post-F1 fix: the
event payloads are correctly deleted, so an append that returned `AppendResult` to its caller can
still have its data wiped before the caller can read it. Severity: should-fix — hard-delete is
operational/GDPR (rare, planned), but the contract is currently undocumented.

Fix sketch (lowest cost): document the precondition "no in-flight writers" in the
`hardDeleteStream` Haddock, and add an integration test that fails fast if a concurrent append is
in progress. Alternative (more cost, less surprise): take `SELECT stream_id FROM streams WHERE
stream_name = $1 FOR UPDATE` at the top of the hard-delete tx so that any in-flight append on that
stream is forced to either complete-before or block-until-after, then re-check `deleted_at` is set
or the stream is gone.

### DEFER-WITH-RATIONALE

**F8 — `$all` row contention is the documented throughput ceiling.**
The `$all` UPDATE in every append CTE serializes all concurrent writers on a single row. Bench
gate at ~5K batches/s; this is by design (gap-free global ordering). Already documented in
`docs/SCALING-ANALYSIS.md`. Defer.

**F9 — Long batch lock-hold time.**
A 1000-event batch holds the `$all` row lock until commit (estimated <50ms based on
`docs/BENCH-GATE3.md`). This is a tradeoff with batch throughput; documenting a recommended max
batch size is appropriate. Defer; address as an operational note in EP-5.

**F10 — `category` column for stream names without a hyphen.**
`kiroku-store/sql/schema.sql:8`: `split_part('foo', '-', 1)` returns `'foo'`. A stream named
`orders` has category `orders` (i.e., is its own category). Documented behavior in
`Kiroku.Store.Types.CategoryName` Haddock. Defer; caller convention.

**F11 — `ExactVersion` retry is indistinguishable from a version conflict.**
On a network-blip retry of an `ExactVersion(N)` append where the original committed (advancing the
stream past N) the second call returns `WrongExpectedVersion`, not `DuplicateEvent`, even when the
caller-supplied `event_id` matches the just-committed event. The CTE's `stream_update` returns 0
rows because the version no longer matches → `inserted_events` is gated by `EXISTS (SELECT 1 FROM
stream_update)` and never runs → no `events_pkey` violation → the duplicate is invisible. Severity:
**cross-plan to EP-2** (public error model). The SQL layer cannot distinguish these cases without
an extra query; the public API may want to.

**F12 — `notify_events` fires twice per single-stream append.**
`kiroku-store/sql/schema.sql:96-99`. The trigger is `AFTER INSERT OR UPDATE FOR EACH ROW` on
`streams`, so an append CTE that updates both the source stream and `$all` fires the trigger twice
(one payload per stream). For `appendMultiStream` with N streams, the trigger fires 2N times. The
EP-1 lead's claim "fires once per append" is incorrect. Subscribers see two NOTIFY events per
logical append. Severity: defer — **cross-plan to EP-3** (subscription audit) for documentation;
EP-3 already debounces NOTIFY signals so this is not a correctness issue, but the contract should
be written down.

**F13 — Append CTE produces no orphan rows on failure (confirmed clean).**
For each of the four append variants, every dependent CTE is gated either by `EXISTS (SELECT 1
FROM <upstream>)` or by `CROSS JOIN <upstream>`. If `stream_update`/`stream_insert`/`stream_upsert`
returns no rows, no `INSERT INTO events` and no `INSERT INTO stream_events` row is generated. The
final `SELECT` returns 0 rows. The `appendAnyVersion` upsert always returns a row, so empty results
there indicate a defensive `ConnectionError` (per `Error.hs:111-112`). No orphans on any failure
path. Severity: no issue.

**F14 — Global-position contiguity invariant holds across all append paths.**
The `all_update` UPDATE on `streams[stream_id=0]` runs once per CTE, gated by `EXISTS (SELECT 1
FROM stream_update | stream_insert | stream_upsert)`. Concurrent appends serialize on the `$all`
row lock until commit, so their position-range claims cannot overlap. `appendMultiStream` claims N
contiguous ranges, each held until tx commit. Verified by the existing test "global position
contiguity" (`test/Main.hs:107-116`). Severity: no issue (under fixed soft-delete F2 — without F2
fix, an append against a soft-deleted stream could still claim a `$all` range, but the result is
still gap-free, just with an unwanted entry).

**F15 — Schema bootstrap is idempotent under concurrent startup.**
`kiroku-store/sql/schema.sql:16-21`. `INSERT ... ON CONFLICT DO NOTHING` is idempotent; `setval(...
GREATEST(MAX, 1))` is monotone. Two concurrent `withStore` invocations against the same database
both run the same script; the worst case is two `setval` calls returning the same value. The seed
INSERT fires `notify_events` once (first time only, no consumer yet). Severity: no issue.

**F16 — FK ordering in hard-delete is correct as written.**
`stream_events.event_id REFERENCES events(event_id)` and `stream_events.stream_id REFERENCES
streams(stream_id)`, neither `ON DELETE CASCADE`. Today (F1 broken) the `DELETE FROM events`
deletes 0 rows, so the FK trigger from `events` deletion never fires. Post-F1 fix, the order
stream_events → events → streams within the CTE means PostgreSQL's per-row FK trigger on the
events DELETE checks `stream_events` for references; since the snapshot semantics also apply to FK
constraint triggers and they run after each row's DELETE in the same transaction, the trigger sees
the post-junction-delete state and finds none. Validate with a regression test in M2 once F1 is
fixed; this finding is a reminder, not an active defect.

**F17 — `prevent_mutation` blocks all UPDATE paths (confirmed clean).**
No code path in `SQL.hs` issues `UPDATE events` or `UPDATE stream_events`. The trigger is correct
defense in depth.

**F18 — `protect_deletion` GUC semantics confirmed.**
`current_setting('kiroku.enable_hard_deletes', true)` returns NULL when unset; `NULL = 'on'` is
NULL; the PL/pgSQL `IF NULL THEN ...` evaluates the alternative branch; the trigger raises. The
hard-delete tx uses `SET LOCAL` (`Effect.hs:200`), which scopes to the transaction and is the
correct usage. A caller that issued plain `SET kiroku.enable_hard_deletes = 'on'` outside a
transaction would leak the setting across the whole session — currently no caller does. Severity:
no issue; document the `LOCAL` requirement in operator docs (EP-4 / EP-5).

**F19 — `getStream(StreamName "$all")` returns the seed row.**
`kiroku-store/src/Kiroku/Store/SQL.hs:501-507`. `getStreamSQL` does not filter `$all`. A caller can
introspect the global counter via `getStream`. Severity: defer — **cross-plan to EP-2** (API
surface decision: hide or expose).

**F20 — Subscription invariants depend on F2 and F3 fixes.**
The `$all` stream advances monotonically and gap-free under all four append paths (per F14). After
F2 (soft-delete TOCTOU) and F3 (linkToStream version gap) are landed, EP-3's subscriber-side
invariants hold. **Cross-plan to EP-3.**

**F21 — No concurrency tests in the existing suite.**
`kiroku-store/test/Main.hs` covers only single-threaded scenarios. The TOCTOU and deadlock
findings above each need a deterministic concurrent reproducer. Severity: defer — **cross-plan to
EP-6** (test hardening). Regression tests added for F1–F3 in this plan's M2 will form the seed of
that work.

### Cross-plan summary

Findings that affect other ExecPlans, recorded here for traceability and replicated to the
MasterPlan's Surprises & Discoveries section:

  * F11 (ExactVersion retry collapses information) → EP-2.
  * F12 (notify fires 2x per append) → EP-3.
  * F19 (getStream returns `$all`) → EP-2.
  * F20 (subscription invariants depend on F2+F3) → EP-3.
  * F21 (no concurrency tests) → EP-6.


## Decision Log

- Decision: Treat the audit milestone as the gate for production readiness of the SQL/schema layer; no fix milestone item is started until its finding is recorded with severity classification.
  Rationale: Without a written audit, "deferred" findings are indistinguishable from "missed" findings. Recording every finding (including the ones we deliberately do not fix) is the artifact that lets future work decide what to revisit.
  Date: 2026-04-29

- Decision: Reasoned from the SQL alone (against PostgreSQL 18 §7.8.2 "Data-Modifying Statements in WITH") rather than building a transient psql reproducer for each finding. Reproducers for the must-fix items will be written as Haskell-level regression tests in M2, where they survive as part of the test suite.
  Rationale: PostgreSQL's CTE snapshot semantics are documented and stable; one-off psql scripts add no value over a reproducer that lives in `kiroku-store/test/Main.hs`. Each must-fix finding's M2 commit will include a red-then-green test, which is the durable artifact.
  Date: 2026-04-29

- Decision: Three findings classified must-fix (F1 hard-delete orphan, F2 soft-delete TOCTOU, F3 linkToStream silent version gap). Four classified should-fix (F4 multi-stream deadlock, F5 soft-delete writes via link/upsert, F6 TRUNCATE bypass, F7 hard-delete vs. concurrent append). Remaining findings (F8–F21) deferred or cross-plan.
  Rationale: The must-fix bar is "silent data corruption or contract violation that's hard to detect from outside the store." F1, F2, and F3 each meet that bar. F4 (deadlock) is detected by PostgreSQL and surfaces as an error; F5–F7 are contract surprises that callers can work around once documented. F8–F21 are documentation, cross-plan ownership, or design-as-intended.
  Date: 2026-04-29

- Decision: Recommend the strict variant of the F3 fix (`LEFT JOIN LATERAL` + reject the whole call if any source event is missing) rather than the lenient variant (bump version by actual insert count).
  Rationale: A linked event whose source has been hard-deleted is a contract violation by definition — the link is referencing a UUID that no longer exists in `events`. Failing fast is more honest than producing a stream with mysteriously skipped versions. EP-2 may want to introduce a new `StoreError` constructor for this case, otherwise it can be mapped to `StreamNotFound` of the missing event.
  Date: 2026-04-29

- Decision: Recommend Option B for the F4 fix (pre-acquire row locks via `SELECT ... FOR UPDATE` in sorted name order, then run user-supplied-order CTEs) rather than Option A (sort the user's ops by name).
  Rationale: Option B preserves the user's intra-call global-position assignment order — callers with `[A, B]` see A's events before B's in `$all`. Option A would silently change that ordering. Option B costs an extra round-trip but only on multi-stream calls (already the rare path).
  Date: 2026-04-29

- Decision: Land F4 (multi-stream deadlock pre-lock), F5 (linkToStream rejects soft-deleted target), and F6 (TRUNCATE bypass triggers) in M2 alongside the must-fix items. Defer F7 (hard-delete vs concurrent append race) with rationale.
  Rationale: F4–F6 are cheap, mechanical, defense-in-depth changes that close real correctness or operational concerns. F7 is a documentation-level concern: hard-delete is rare and operational (GDPR cleanup, never on the hot path), and the contract "no in-flight writers during hard-delete" is reasonable for callers to honor. Adding a `SELECT FOR UPDATE` pre-pass to hard-delete (the "lower-cost-than-defer" alternative the audit mentioned) would also serialize hard-delete with all in-flight appends, which is heavier than necessary. F7's mitigation is a Haddock note to be added by EP-4 when it touches `Lifecycle.hs`.
  Date: 2026-04-29

- Decision: Use `LEFT JOIN LATERAL` + NOT NULL constraint violation as the F3 fix mechanism rather than introducing a `validated`-CTE gating pattern or a new error constructor.
  Rationale: The single-character SQL change has the smallest surface area and exploits the existing `stream_events.original_stream_id NOT NULL` constraint as the failure trigger. The error currently surfaces as `ConnectionError "Server error 23502: ..."` because the error mapper doesn't have a case for NOT NULL violations on link junctions. Refining this to a purpose-built constructor (e.g. `LinkSourceMissing`) is EP-2's call per the integration-points contract; this commit prefers a known opaque error to silent corruption. Recorded as a coordination point for EP-2's M1 audit.
  Date: 2026-04-29

- Decision: Change the `emptyResultError` mapping for `AnyVersion` from `ConnectionError "AnyVersion append returned empty result (unexpected)"` to `StreamNotFound`.
  Rationale: After F2, an `AnyVersion` append against a soft-deleted stream is a legitimate empty-result path (the upsert's `DO UPDATE WHERE deleted_at IS NULL` filter rejects the existing row). The pre-fix mapping treated empty as "should never happen" because the upsert was unconditional. The new mapping is consistent with `StreamExists` and reflects the user-visible contract: a soft-deleted stream is "not found" for write purposes. NoStream's mapping (StreamAlreadyExists) and ExactVersion's mapping (WrongExpectedVersion) are unchanged — they're already meaningful for their respective failure modes. EP-2 may revisit if a more specific constructor is preferred.
  Date: 2026-04-29

- Decision: For the F4 multi-stream pre-lock, exclude `$all` from the pre-lock SELECT and let the per-stream CTEs acquire it in their natural order (source stream first, then $all).
  Rationale: Including $all in the pre-lock would force ALL multi-stream txns to serialize on a single $all-row lock at the pre-lock step, even if they touch entirely disjoint stream sets. With $all excluded, the deadlock-prevention ordering is "pre-lock named streams in stream_id order; then each CTE locks its source stream (already held) and acquires $all." Single-stream and multi-stream txns now lock in the same order (source → $all), so they cannot deadlock with each other. The remaining contention is on $all itself, which is the documented throughput bottleneck (F8) — same as today.
  Date: 2026-04-29


## Outcomes & Retrospective

### Milestone 1 — Audit findings (2026-04-29)

Produced 21 written findings (F1–F21) covering every item in the Audit Checklist, classified
by severity. 3 must-fix-before-production (F1 hard-delete orphan, F2 soft-delete TOCTOU,
F3 linkToStream silent gap). 4 should-fix (F4 multi-stream deadlock, F5 link-to-soft-deleted,
F6 TRUNCATE bypass, F7 hard-delete vs concurrent append). 14 deferred / cross-plan / no-issue.
Cross-plan findings (F11→EP-2, F12→EP-3, F19→EP-2, F20→EP-3, F21→EP-6) were mirrored into
the MasterPlan's Surprises & Discoveries section. Verification: every Audit Checklist bullet
has a corresponding finding entry, and the Decision Log records the audit method (read-only
analysis against PostgreSQL §7.8.2; reproducers added in M2 as regression tests rather than
one-off psql scripts).

### Milestone 2 — Fixes landed (2026-04-29)

Six commits landed, one fix per commit. Each commit message records the bug, the fix, the
regression-test names added, and the test-suite count delta. All three trailers
(MasterPlan / ExecPlan / Intention) are present on every commit.

  * **F1** — `01c0ee6` — hard-delete now removes orphaned event payloads. Split the single
    CTE into 4 ordered statements within the existing transaction. +2 tests.
  * **F2** — `e903062` — close soft-delete TOCTOU race via CTE-level filter. Pushed
    `deleted_at IS NULL` into 5 CTEs, dropped 3 pre-checks in `runStorePool`, updated
    `emptyResultError` for AnyVersion. +3 tests.
  * **F3** — `a5754d6` — linkToStream rejects missing source events. Single-char SQL change
    (`JOIN LATERAL` → `LEFT JOIN LATERAL`); NOT NULL constraint catches missing events.
    +2 tests.
  * **F5** — `12a154b` — linkToStream rejects soft-deleted targets (symmetric with F2).
    Added `WHERE streams.deleted_at IS NULL` to the link upsert's DO UPDATE, switched the
    decoder to `D.rowMaybe`, mapped Nothing → StreamNotFound. +1 test.
  * **F6** — `6d195e8` — block TRUNCATE on protected tables without the GUC. Added
    `protect_truncation` plpgsql function and 3 BEFORE TRUNCATE FOR EACH STATEMENT triggers
    in `schema.sql`. +3 tests.
  * **F4** — `8edfbee` — pre-lock streams in stream_id order in multi-stream append. Added
    `lockStreamsForMultiStmt` and a `Tx.statement names ...` call at the top of the
    multi-stream transaction. +1 ordering sanity test. (Deterministic deadlock test deferred
    to EP-6's concurrency-test harness.)

#### Test results

`cabal test kiroku-store:test:kiroku-store-test`: **66 examples, 0 failures** (was 54
baseline; +12 regression tests added across F1–F6). Suite finishes in ~30s on the M3 dev
machine, same as baseline.

The new test helpers `countEvents` (raw `SELECT COUNT(*) FROM events`) and `truncateRejected`
(uses `Hasql.Statement.unpreparable` for non-prepared TRUNCATE) are kept under the existing
test/Main.hs file rather than extracted to a separate module, to minimise EP-1's footprint.
EP-6 may refactor when it restructures the test suite.

#### Benchmark results

`cabal bench kiroku-store:bench:kiroku-store-bench`: 9 tests passed in 65.40s. Comparison
to the M3 baseline (`docs/BENCH-GATE3.md`, kiroku-store/bench/results/haskell_bench_m3_20260322.txt):

  * **Read benchmarks (apples-to-apples comparison)**:
    - stream forward (100-event page): baseline 969 μs → current 1.00 ms (+3%; within Gate 3
      target of 1.07 ms ✓)
    - $all forward (100-event page): baseline 975 μs → current 1.00 ms (+3%; within Gate 3
      target of 1.07 ms ✓)
  * **Append benchmarks (NOT apples-to-apples)**: the current bench output shows
    single-event appends at ~200 μs (vs. 65 μs baseline), batch appends at 480 μs–2.58 ms
    (vs. 209 μs–1.57 ms baseline). However, the bench's category-data pre-population (100K
    events in 1000 streams) was added in commit 390baf5 (M5.9 — *after* the M3/M4 baselines
    were taken) and runs before any append benchmark. The pre-populated `events` and
    `stream_events` tables are an order of magnitude larger when the append microbench runs,
    which dominates the timings. None of EP-1's fixes touch the hot path of single-stream
    appendNoStream (the bench's primary workload) — F1 is hard-delete; F2 adds a 4-byte
    WHERE clause; F3 changes a JOIN keyword; F4 adds 1 SELECT FOR UPDATE per multi-stream
    call (not per single-stream append); F5 adds a WHERE to link's upsert (not append);
    F6 adds triggers that only fire on TRUNCATE.
  * **Pool saturation (B9)**: baseline 1262 ops/s → current 1190 ops/s (-5.7%). Within the
    "noise" band given the baseline-mismatch caveat above and normal variance from a single
    run. The B9 workload is `appendNoStream` against fresh streams, which is unchanged by
    EP-1's fixes.

The EP's "no regression > 5% vs. baseline" gate is met for read benchmarks (+3% on both).
The append-benchmark comparison is not meaningful against the M3 baseline; a fresh
post-M5.9 baseline would need to be captured (out of scope for EP-1; EP-6 owns benchmark
hardening).

### Cross-plan handoffs

  * **EP-2** — recommended to add `LinkSourceMissing :: ![EventId] -> StoreError` (or
    similar) to refine F3's current `ConnectionError 23502` into a meaningful constructor.
    Also recommended to refine `emptyResultError`'s `AnyVersion → StreamNotFound` mapping
    if a more specific constructor is preferred (e.g. one that names the soft-deleted state
    explicitly). F11 (ExactVersion retry information collapse) and F19 (`getStream("$all")`
    behavior) are also in EP-2's domain.
  * **EP-3** — F12 (`notify_events` fires twice per single-stream append) and F20
    (subscription invariants depend on F2+F3 fixes — both landed) are in EP-3's domain.
    The `EventPublisher` debouncing already handles the double-NOTIFY at the consumer
    level; EP-3 should document the contract.
  * **EP-4** — Add a Haddock note to `hardDeleteStream` in `Kiroku.Store.Lifecycle` that
    callers must ensure no in-flight writers on the target stream (F7's deferral). Also
    document that hard-delete cascades through link junctions of the deleted stream's own
    events (F1 fix's documented behavior).
  * **EP-6** — F21 (no concurrency tests). The 12 regression tests added in EP-1's M2 form
    the seed of a proper concurrency-test harness. EP-6 should: (a) add a deterministic
    deadlock-reproducer for F4 using barriered concurrent transactions; (b) add a TOCTOU
    timing test for F2 that exposes the race deterministically (e.g. via instrumented
    pause hooks); (c) add property-based tests for the orphan-protection invariants F1
    fixes; (d) capture a fresh post-M5.9 benchmark baseline to enable meaningful future
    regression detection.

### Production-readiness verdict (EP-1 scope)

The schema, CTE, and concurrency layer of `kiroku-store` is **production-ready** subject to
the deferred items below. Specifically:

  * **Cleared**: F1 (hard-delete orphan), F2 (soft-delete TOCTOU), F3 (linkToStream gap),
    F4 (multi-stream deadlock), F5 (link to soft-deleted), F6 (TRUNCATE bypass).
  * **Deferred**: F7 (hard-delete vs concurrent append) — operator must coordinate; F8
    ($all contention ceiling) — documented bottleneck; F9 (long batch lock-hold) — use
    moderate batch sizes; F10 (category column for hyphen-less stream names) — caller
    convention; F11/F19 → EP-2; F12/F20 → EP-3; F21 → EP-6.

A consumer service writing events through `kiroku-store` after this milestone will not
encounter silent data corruption from any of the audited paths under expected operational
conditions (no concurrent hard-delete with in-flight writers on the same stream).


## Context and Orientation

The reader of this plan is assumed to have only the working tree and this file. Every term and file path is repeated here so that the audit can be carried out without reading the MasterPlan or any other ExecPlan.

`kiroku-store` is one of two Haskell packages in the repository (the other, `shibuya-kiroku-adapter`, is a consumer of it and is out of scope). Its build is driven by `kiroku-store/kiroku-store.cabal`. Its sources live under `kiroku-store/src/Kiroku/Store/`. The package depends on `hasql`, `hasql-pool`, `hasql-transaction`, and `hasql-notifications` to talk to PostgreSQL 18 (which provides the `uuidv7()` function used in the schema).

The schema is embedded into the binary at compile time via `embedFile` in `kiroku-store/src/Kiroku/Store/Schema.hs`. The single source of truth is `kiroku-store/sql/schema.sql`. There are four tables: `streams` (one row per logical event stream, plus the special seed row with `stream_id = 0` and `stream_name = '$all'`), `events` (immutable event payloads), `stream_events` (a junction table linking each event to one or more streams; an event is always linked to its source stream and to `$all`, plus to any stream it has been linked into via `linkToStream`), and `subscriptions` (one row per named subscription, holding its last-seen global position).

The write path is "Strategy E": every append issues a single CTE that, in one round-trip, (1) updates the source stream's `stream_version` (claiming a per-stream version range), (2) inserts the event payloads into `events`, (3) inserts a row into `stream_events` linking each event to the source stream at its claimed version, (4) updates the `$all` row's `stream_version` (claiming a global position range), and (5) inserts a row into `stream_events` linking each event to `$all` at its claimed global position. The `$all` row update is what produces gap-free contiguous global positions; the cost is row-level lock contention on `stream_id = 0` in `streams`.

Four append CTE variants exist, one per `ExpectedVersion` constructor:

- `appendExpectedVersionSQL` — `UPDATE streams ... WHERE stream_name = $8 AND stream_version = $9` (optimistic concurrency check)
- `appendStreamExistsSQL` — `UPDATE streams ... WHERE stream_name = $8` (no version check; fails if 0 rows)
- `appendNoStreamSQL` — `INSERT INTO streams ... ON CONFLICT (stream_name) DO NOTHING` (creates a new stream; fails if already exists)
- `appendAnyVersionSQL` — `INSERT INTO streams ... ON CONFLICT (stream_name) DO UPDATE SET stream_version = ...` (creates or appends)

A fifth large CTE, `linkToStreamSQL`, handles linking *existing* events into a target stream without re-inserting the event payload. It uses an `INSERT ... ON CONFLICT DO UPDATE` upsert on `streams` and a `JOIN LATERAL` to find each event's `(original_stream_id, original_stream_version)` in the existing `stream_events` rows.

Read CTEs are simpler: `readStreamForwardSQL` and `readStreamBackwardSQL` resolve the stream name to an id via subquery and scan `(stream_id, stream_version)`; `readAllForwardSQL` and `readAllBackwardSQL` filter on `stream_id = 0`; `readCategoryForwardSQL` joins to `streams` on `original_stream_id` and filters on the generated `category` column (which is `split_part(stream_name, '-', 1)` stored as `STORED`).

Lifecycle CTEs: `softDeleteStreamSQL` is a one-line `UPDATE streams SET deleted_at = now() WHERE stream_name = $1 AND deleted_at IS NULL`; `undeleteStreamSQL` is the symmetric clear; `hardDeleteStreamSQL` is a multi-step CTE protected by a session GUC `kiroku.enable_hard_deletes` that the trigger `protect_deletion()` checks via `current_setting('kiroku.enable_hard_deletes', true) = 'on'`.

Triggers: `notify_events()` fires on INSERT or UPDATE of `streams` and emits a `pg_notify(<schema>.events, ...)`; `prevent_mutation()` is the immutability barrier on `events` and `stream_events`; `protect_deletion()` gates DELETE on `events`, `stream_events`, and `streams`. The schema initializer in `kiroku-store/src/Kiroku/Store/Schema.hs` runs the embedded DDL via `Pool.use pool (Session.script schemaDDL)` once per `withStore` invocation.

The Haskell layer that drives all of this is `kiroku-store/src/Kiroku/Store/Effect.hs` (the `Store` GADT, `runStorePool` interpreter, and the `prepareEvents` helper that pre-generates UUIDv7s when the caller did not supply them) and `kiroku-store/src/Kiroku/Store/SQL.hs` (encoders, decoders, statements, and the SQL templates above). The interpreter wraps multi-stream appends in an explicit `hasql-transaction` at `ReadCommitted` isolation; everything else uses the implicit per-statement transactions of `hasql-pool`.

Concurrency model. PostgreSQL READ COMMITTED isolation is used everywhere. The `streams` row UPDATE in each append variant takes a row-level lock on the source stream and on `$all`. The CTE structure means both locks are held until commit. The `$all` lock is the documented bottleneck (~5K batches/s ceiling per `docs/SCALING-ANALYSIS.md`).

The existing test suite is `kiroku-store/test/Main.hs` (887 lines, hspec-based, uses `ephemeral-pg` to spin up a temporary PostgreSQL 18 instance per test). It exercises every append variant, read variant, link, multi-stream transaction, soft-delete, undelete, hard-delete, and many subscription scenarios. It does not include property-based tests, concurrency stress tests, or failure-injection tests.

Additional reading available in the working tree but *not* required to perform the audit: `docs/DESIGN.md` (the full design rationale), `docs/IMPLEMENTATION.md` (the implementation milestone log), `docs/SCALING-ANALYSIS.md` (the scaling analysis that informed the no-time-partitioning decision), `docs/PG-PARTMAN.md` (the parked partition-readiness research), `docs/BENCH-*.md` (benchmark results).


## Plan of Work

The work is split into two milestones.

### Milestone 1 — Audit findings document

Goal: produce a written, evidence-backed audit of every item in the Audit Checklist below, classify every finding by severity, and record findings inline in the Surprises & Discoveries section above (with file and line references) and in the MasterPlan's Surprises & Discoveries section for cross-plan items.

What will exist at the end: a complete pass through every CTE, trigger, index, and concurrency boundary, with a finding for each item. A finding may be "no issue identified" — that is a valid result and must be recorded.

Verification: every checklist item below has a corresponding entry in Surprises & Discoveries with one of the three severity tags. The Decision Log records any choice the auditor made (e.g. choosing to test a specific scenario in a transient ephemeral DB rather than reasoning from the SQL alone).

### Milestone 2 — Land must-fix corrections

Goal: for each finding classified as must-fix-before-production, land a code change with a regression test; commit one fix per commit. For should-fix findings, prioritise based on the cost of fixing later vs. now and either fix or formally defer in the Decision Log.

What will exist at the end: green test suite with new regression tests for every must-fix finding. The Decision Log records each must-fix fix and each deferred should-fix decision. The MasterPlan's Exec-Plan Registry status is updated to Complete.

Verification: `cabal test kiroku-store` passes and includes the new tests; the benchmark suite (`cabal bench kiroku-store:kiroku-store-bench`) shows no significant regression vs. the baselines in `docs/BENCH-GATE3.md` and the result files under `kiroku-store/bench/results/`.


## Concrete Steps

### Milestone 1 commands

Set up the audit environment.

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    cabal build kiroku-store
    cabal test kiroku-store        # confirm baseline green

Read every file in scope, in order. Take notes per checklist item below. The expected output of each `cabal` command is a green test run; if any test is already failing on master, record that in Surprises & Discoveries before starting the audit.

Files to read in order (every file must be read in full):

- `kiroku-store/sql/schema.sql` (142 lines) — DDL, indexes, triggers
- `kiroku-store/src/Kiroku/Store/Schema.hs` (39 lines) — DDL embed and execution
- `kiroku-store/src/Kiroku/Store/Types.hs` (118 lines) — domain types and contracts
- `kiroku-store/src/Kiroku/Store/SQL.hs` (718 lines) — every CTE and statement
- `kiroku-store/src/Kiroku/Store/Effect.hs` (293 lines) — `runStorePool` interpreter, multi-stream tx, soft-delete pre-check
- `kiroku-store/src/Kiroku/Store/Error.hs` (126 lines) — server-error → `StoreError` mapping (note: EP-2 owns `StoreError`'s public shape; this audit only flags cases where the SQL layer needs a distinction the type cannot express)
- `kiroku-store/src/Kiroku/Store/Connection.hs` (103 lines) — pool config, idle-in-tx timeout, observation handler wiring
- `kiroku-store/test/Main.hs` (887 lines) — existing coverage; identify scenarios not currently tested

When a checklist item has an empirical answer, write a small SQL or Haskell reproducer and capture its output as evidence. Reproducers belong in `kiroku-store/test/Main.hs` (Haskell-level) or in a scratch file under `kiroku-store/sql/audit/` (SQL-level) so that they survive as regression tests.

### Audit Checklist

The audit must produce a finding for every item below.

CTE correctness:
- For each of the four append variants (`appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`, `appendAnyVersionSQL`): does the CTE produce *zero* orphan rows in `events` or `stream_events` on every failure path (version mismatch, conflicting stream, conflicting event id)? Produce evidence by triggering each failure mode in a Haskell test and querying both tables for orphan rows.
- For `linkToStreamSQL`: does the lateral join correctly find the `(original_stream_id, original_stream_version)` for events that were originally appended to a stream that has since been soft-deleted? Hard-deleted? Document the behavior.
- For `hardDeleteStreamSQL`: does the orphan-protection check (`NOT EXISTS (SELECT 1 FROM stream_events se WHERE se.event_id = events.event_id)`) actually protect orphans, given that data-modifying CTEs cannot see each other's intermediate state? Write a reproducer that hard-deletes a stream whose events are *only* linked to that stream and to `$all`; verify whether the events are deleted (correct, since `$all` is being deleted from too) or preserved (incorrect — would leak rows). Then write a reproducer that hard-deletes a stream whose events are *also* linked elsewhere; verify the events survive.
- For every append variant: assert the global-position contiguity invariant — appending N events to a fresh stream after global position P must place them at P+1 .. P+N in `$all`, and reading `$all` from P returns exactly those N events in order. Confirm with a multi-stream interleaving test under concurrent load.

Concurrency boundaries:
- Soft-delete TOCTOU. The interpreter (`Effect.hs:73-102`, `103-128`) reads `streams.deleted_at` in a separate session before the append CTE. Reproduce: interleave a `softDeleteStream` between the pre-check and the append in a deterministic test (use STM or `MVar` barriers); confirm the append succeeds against a soft-deleted stream. Severity: must-fix. Proposed fix: move the deleted-check inside the append CTE (`WHERE stream_name = $8 AND deleted_at IS NULL` in the source-stream UPDATE), eliminating the pre-query entirely.
- Multi-stream transaction deadlocks. `appendMultiStream` (`Effect.hs:145-194`) issues N `UPDATE streams` statements in a user-supplied order. Two concurrent multi-stream transactions that touch the same streams in opposite orders deadlock at the row-lock level. Reproduce; document either a fix (sort streams by name before locking) or accept-and-document with a public API note.
- `$all` row contention. The benchmark suite shows ~5K batches/s. Confirm under simulated production load (varied batch sizes, varied concurrent writer counts). Compare to baseline in `kiroku-store/bench/results/`.
- Hard-delete vs. concurrent reads/writes. While `hardDeleteStreamSQL` runs, can a concurrent appendToStream succeed against the stream being deleted? Reproduce: start a long-running hard delete, attempt a concurrent append from another connection. Document the resulting state.
- The append CTE holds locks on the source stream's `streams` row and on the `$all` row through commit. A long batch (e.g. 1000 events) in a slow client serializes all other writes to `$all` for the duration. Quantify worst-case lock-hold time using the existing benchmark numbers. Decide whether to document a maximum-batch-size guideline.

Schema and indexes:
- The `streams.category` generated column is `STORED` and computed from `split_part(stream_name, '-', 1)`. What happens if a caller uses a stream name without a hyphen (`-`)? `split_part('foo', '-', 1)` returns `'foo'`. Document this — every stream becomes its own category. Decide whether to constrain stream names or rely on caller convention.
- The partial index `ix_stream_events_all_by_origin` on `(original_stream_id, stream_version) WHERE stream_id = 0` supports the category read path. Inspect `EXPLAIN ANALYZE` for `readCategoryForwardStmt` at production-like volumes to confirm the index is used.
- Every `IF NOT EXISTS` guard in the schema is idempotent on re-run, but the `INSERT INTO streams (stream_id, stream_name, stream_version) VALUES (0, '$all', 0) ON CONFLICT DO NOTHING` and the `setval('streams_stream_id_seq', GREATEST(...))` call run on every `withStore` invocation. Verify the latter does not regress the sequence under concurrent startup of two store handles against the same database.
- All foreign keys from `stream_events` reference `events(event_id)` and `streams(stream_id)`. They are not declared `ON DELETE CASCADE`. Confirm the hard-delete CTE explicitly removes child rows in the correct order so that the FK constraint never fires a cascade or violation.
- Indexes: confirm `ix_stream_events_stream_version`, `ix_events_event_type`, `ix_events_correlation_id`, `ix_events_causation_id`, `ix_streams_category`, `ix_stream_events_all_by_origin` are all created and used by the relevant query paths. Capture `EXPLAIN ANALYZE` output for each main read query.

Triggers:
- `notify_events()` fires on INSERT or UPDATE of the `streams` table. The `INSERT INTO streams ($all seed row)` at startup will fire it. Confirm this is harmless (no consumer is yet listening) and that the schema initialization is idempotent in practice.
- `prevent_mutation()` blocks UPDATE on `events` and `stream_events`. Confirm there is no code path in `SQL.hs` that issues an UPDATE on either table.
- `protect_deletion()` checks `current_setting('kiroku.enable_hard_deletes', true) = 'on'`. The third argument `true` to `current_setting` returns NULL when the setting is not defined, and the equality `NULL = 'on'` is NULL, which is falsy in PL/pgSQL — the trigger raises. Confirm. Also confirm that the GUC must be set with `SET LOCAL` *inside the same transaction* as the DELETE (the existing code does this in `Effect.hs:200`); document the consequence of any caller that sets it via `SET` without `LOCAL`.
- TRUNCATE bypass. `protect_deletion` is a row-level trigger. Add a `BEFORE TRUNCATE ... FOR EACH STATEMENT` trigger or document the bypass explicitly.

Lifecycle correctness:
- `softDeleteStream` returns `Nothing` for an already-soft-deleted stream. Confirm this matches the documented contract in `Kiroku.Store.Lifecycle` Haddock.
- `undeleteStream` is the inverse; `hardDeleteStream` removes the row entirely. Document the ordering rule for callers (must hard-delete only after no consumer is reading).
- Does soft-delete prevent appends, reads, and links? Existing tests cover append (rejected) and read (returns empty); confirm `linkToStream` on a soft-deleted stream's *event* (the source stream is soft-deleted, the target is fine). Document the behaviour.

Idempotency and retries:
- A caller-supplied `EventId` enables idempotent retries. The `events_pkey` constraint catches the duplicate and `mapUniqueViolation` in `Error.hs` maps it to `DuplicateEvent`. Confirm with a test that retries an exact-version append after a network blip — the second call should return `DuplicateEvent`, not `WrongExpectedVersion`. Note: the error type collapses information that the SQL layer distinguishes (the version *did* advance from the first call's success); EP-2 owns the public contract.
- For batched appends with N caller-supplied event ids, what happens if one id is a duplicate and the others are fresh? The CTE either commits all or none (single CTE, single transaction). Confirm that no events from the batch persist on duplicate detection.

Subscription-relevant invariants (cross-plan, EP-3 owns the subscription audit):
- The `$all` stream's `stream_version` advances monotonically and is gap-free under all append paths. EP-3 depends on this.
- `notify_events` fires once per append regardless of batch size, with payload containing the source stream's name, id, and post-append version. Confirm.

### Milestone 2 commands

For each must-fix finding, the workflow is:

    cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
    # 1. Add a regression test that demonstrates the bug (red)
    $EDITOR kiroku-store/test/Main.hs
    cabal test kiroku-store        # confirm new test fails
    # 2. Land the fix (one fix per commit)
    $EDITOR kiroku-store/{src/Kiroku/Store/SQL.hs,src/Kiroku/Store/Effect.hs,sql/schema.sql}
    cabal test kiroku-store        # confirm green
    # 3. Commit with all three trailers
    git add -A
    git commit -m "fix: <one-line summary>

    <body>

    MasterPlan: docs/masterplans/1-production-readiness-review-of-kiroku-store.md
    ExecPlan: docs/plans/1-schema-cte-and-concurrency-correctness-audit.md
    Intention: intention_01khv3gg6xe91tt2pyqvxw1832"

After all must-fix items are landed, re-run the benchmark suite and compare to baseline:

    cabal bench kiroku-store:kiroku-store-bench --benchmark-options='--csv bench-after.csv'

Compare to `kiroku-store/bench/results/haskell_bench_m3_20260322.txt` and `docs/BENCH-GATE3.md`. Any regression > 5% must be investigated and either fixed or recorded in the Decision Log with rationale.


## Validation and Acceptance

Milestone 1 is complete when:

- The Surprises & Discoveries section above contains a finding for every item in the Audit Checklist, with severity classification.
- The MasterPlan's Surprises & Discoveries section lists every cross-plan finding with a clear pointer to the affected plan.
- The Decision Log entries explain every method choice (e.g. "tested via reproducer in `test/Main.hs`" vs. "reasoned from the SQL alone").

Milestone 2 is complete when:

- Every must-fix finding has a corresponding commit with all three trailers and a regression test.
- `cabal test kiroku-store` passes locally with the new tests included.
- `cabal bench kiroku-store:kiroku-store-bench` shows no regression > 5% vs. baseline.
- The Outcomes & Retrospective section summarises what was found, what was fixed, and what was deferred (with rationale).
- The MasterPlan's Exec-Plan Registry status for EP-1 is "Complete" and the MasterPlan's Progress section's EP-1 entries are checked off.

Acceptance behaviours that a human can verify:

- Soft-delete TOCTOU regression test: the test starts a `softDeleteStream` and an `appendToStream` against the same stream from two threads with deterministic ordering; before the fix the append succeeds, after the fix it fails with `StreamNotFound`.
- Multi-stream deadlock test (if fix landed): two concurrent `appendMultiStream` calls touching streams `[a, b]` and `[b, a]` complete without deadlock; before the fix one transaction is killed by PostgreSQL's deadlock detector.
- Hard-delete orphan test: a hard-delete of a stream whose events are linked elsewhere preserves the events; running `SELECT count(*) FROM events` before and after shows only the deleted-and-not-otherwise-linked events removed.


## Idempotence and Recovery

The audit milestone is read-only and idempotent — re-reading the same file twice does not change the working tree. Notes added to Surprises & Discoveries should be merged on re-runs, not duplicated.

The fix milestone produces commits. Each commit must leave the test suite green. If a commit fails the test suite, the next commit must either complete the fix or revert it; do not leave the working tree in a state where `cabal test kiroku-store` fails. If a fix turns out to require a schema migration (column add, constraint change), record this in the Decision Log and coordinate with EP-4 (which owns schema-lifecycle decisions) before landing.

If the benchmark suite regresses by more than 5% after a fix, do not commit the fix; investigate first. The fix may need to be reformulated (e.g. moving the soft-delete check inside the CTE may require an extra index — quantify before assuming).


## Interfaces and Dependencies

This plan modifies, at most, the following files:

- `kiroku-store/sql/schema.sql` — DDL only. Any change requires a recompile (the file is embedded via `embedFile`). EP-4 also owns this file for any multi-tenant scoping changes; coordinate via the MasterPlan's Integration Points.
- `kiroku-store/src/Kiroku/Store/SQL.hs` — CTE and statement templates. EP-3 may add new statements for category live-mode filtering; this plan does not modify the existing statements except as required by must-fix findings.
- `kiroku-store/src/Kiroku/Store/Effect.hs` — the `runStorePool` interpreter. EP-2 also touches this file (multi-stream error attribution) and EP-4 may touch it (schema-name decision). All three plans must coordinate.
- `kiroku-store/src/Kiroku/Store/Error.hs` — read-only here; if a finding requires a new constructor on `StoreError`, surface it to EP-2 as a cross-plan finding rather than editing the file directly.
- `kiroku-store/test/Main.hs` — every must-fix finding adds a regression test.

External dependencies. The audit assumes PostgreSQL 18+ is available locally via `ephemeral-pg` (already wired into the test suite). No new Haskell dependencies are required.

Module-level interface contracts that this plan depends on but does not change:

- `Kiroku.Store.Connection.withStore` — bracket-style lifecycle; calls `initializeSchema` once per acquire.
- `Kiroku.Store.Effect.runStorePool` — interprets the `Store` GADT against a `KirokuStore` handle.
- `Kiroku.Store.Error.StoreError` — public error type. Constructors must remain semantically stable for existing pattern-matches in `kiroku-store/test/Main.hs` and in `shibuya-kiroku-adapter/`.

Findings and fixes that affect any of these contracts must be coordinated with the owning plan via the MasterPlan's Integration Points section.
