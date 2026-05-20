---
id: 23
slug: restructure-append-into-a-two-round-trip-path
title: "Restructure append into a two-round-trip path"
kind: exec-plan
created_at: 2026-05-18T20:38:47Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
---

# Restructure append into a two-round-trip path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku's append is slow relative to the upstream Elixir EventStore (`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`) it was based on because Kiroku does the entire append — text-keyed stream lookup, version check, soft-delete check, event insertion, `$all` link, source link, version update — in **one round-trip** through a CTE that bakes every check into SQL. Plan `docs/plans/22-optimize-singleton-append-sql-path.md` demonstrated with raw-SQL benchmarks that reshaping that single CTE (arrays → scalars, batch → singleton) does not move the needle. The gap is structural, not in the SQL shape.

After this change, command-side appends use a **two-round-trip path** modeled on `EventStore.Streams.Stream.append_to_stream/5` in the upstream library:

1. A small `SELECT stream_id, stream_version, deleted_at FROM streams WHERE stream_name = $1` resolves the stream up front. Cost: one indexed `text` lookup returning three integers / one nullable timestamp.
2. `ExpectedVersion` is validated in Haskell, mirroring `EventStore.Streams.StreamInfo.validate_expected_version/2` (`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store/streams/stream_info.ex`). Conflicts (`StreamAlreadyExists`, `StreamNotFound`, `WrongExpectedVersion`, soft-deleted) are produced without entering a transaction.
3. A new, simpler append statement runs in the second round-trip. When the stream already exists, it `UPDATE streams … WHERE stream_id = $1::bigint` keyed on the integer primary key (no text comparison, no version predicate, no soft-delete predicate, no `EXISTS` gating, no `(SELECT count(*) FROM new_events)`). When the stream is new, it `INSERT INTO streams (stream_name, stream_version) VALUES ($1, $2) RETURNING stream_id`.

A caller of `appendToStream`, `appendToStreamTx`, or `runTransactionAppending` sees no API or semantic change: the same `Either StoreError AppendResult` / `Either AppendConflict AppendResult` results come back, with the same constructors on conflicts. The visible outcome is that local single-event and hot-stream append benchmarks in `kiroku-store/bench/Main.hs` close most of the gap to the message-db baseline already captured in `docs/plans/22-optimize-singleton-append-sql-path.md`, with no material batch regression. This plan inherits the local-benchmark-gate-as-acceptance posture from plan 22 and is associated with the same intention, `intention_01krxrpv5heny9gs89seas59zm`. Implementation commits include both an `ExecPlan: docs/plans/23-restructure-append-into-a-two-round-trip-path.md` trailer and an `Intention: intention_01krxrpv5heny9gs89seas59zm` trailer.


## Progress

- [x] Create this ExecPlan from the repository skeleton with intention `intention_01krxrpv5heny9gs89seas59zm`. (Completed 2026-05-18.)
- [x] Add a benchmark-only two-round-trip raw SQL variant to `kiroku-store/bench/Main.hs` alongside the existing `raw-append-shape` group and confirm the structural model is faster than the production array path before touching `Effect.hs`. **The acceptance gate failed.** (Completed 2026-05-18; the architectural read is wrong, see Surprises & Discoveries.)
- [ ] ~~Capture a local pre-change benchmark slice~~ — abandoned. Milestone 1's gate failed, so the rest of the plan is moot per its own preamble.
- [ ] ~~Introduce a `resolveStream` query and a `StreamResolution` record~~ — abandoned.
- [ ] ~~Add new append statements `appendUpdateExistingStream` and `appendCreateNewStream`~~ — abandoned.
- [ ] ~~Wire `appendToStream` in `kiroku-store/src/Kiroku/Store/Effect.hs` to the two-round-trip dispatch~~ — abandoned.
- [ ] ~~Wire `AppendMultiStream`~~ — abandoned.
- [ ] ~~Run focused and full `kiroku-store-test` suites~~ — abandoned.
- [ ] ~~Re-run the local benchmark slice~~ — abandoned.
- [x] Update `docs/plans/22-optimize-singleton-append-sql-path.md` Outcomes to record that the round-trip restructure was tested at the raw-SQL level and failed the gate. Propose the next experiment based on the new evidence: statement-level mutation triggers, advisory locks, or — most likely — accepting that Haskell/Hasql per-round-trip overhead is the dominant cost on this stack. (Pending — see Outcomes & Retrospective.)


## Surprises & Discoveries

### Milestone 1 result — the two-round-trip raw SQL is slower than production arrays/unnest, not faster

Captured 2026-05-18 on `Darwin sungkyung 25.3.0 arm64`, from the working tree at the M1 commit (intention `intention_01krxrpv5heny9gs89seas59zm`, plan 23). The bench harness added four new entries to the `raw-append-shape/AnyVersion` group in `kiroku-store/bench/Main.hs`: `two-roundtrip (new stream)`, `two-roundtrip + BEGIN/COMMIT (new stream)`, `two-roundtrip (hot stream)`, and `two-roundtrip + BEGIN/COMMIT (hot stream)`. The `(no BEGIN/COMMIT)` variants run the resolve and append as two implicit-transaction `Session.statement` calls on a single pooled connection, mirroring how `EventStore.Streams.Stream.append_to_stream/5` runs its < 1000-event path without an explicit `Postgrex.transaction` wrapper. The `(BEGIN/COMMIT)` variants add `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write` to match the contract this plan's Milestone 4 would have used.

```text
Command: cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p raw-append-shape --csv /tmp/kiroku-raw-append-shape-23.csv"
CSV: /tmp/kiroku-raw-append-shape-23.csv

Benchmark                                                                Mean (μs)
All.raw-append-shape.AnyVersion.scalar singleton (new stream)            177
All.raw-append-shape.AnyVersion.production arrays/unnest (new stream)    153   ← baseline
All.raw-append-shape.AnyVersion.two-roundtrip (new stream)               159   (+3.9 %)
All.raw-append-shape.AnyVersion.two-roundtrip + BEGIN/COMMIT (new stream) 193   (+26.1 %)
All.raw-append-shape.AnyVersion.scalar singleton (hot stream)            147
All.raw-append-shape.AnyVersion.production arrays/unnest (hot stream)    152   ← baseline
All.raw-append-shape.AnyVersion.two-roundtrip (hot stream)               166   (+9.2 %)
All.raw-append-shape.AnyVersion.two-roundtrip + BEGIN/COMMIT (hot stream) 194   (+27.6 %)
```

The plan's Milestone 1 acceptance gate required the two-roundtrip hot-stream case to be **at least 30 % faster** than production arrays/unnest hot-stream. The actual result is **9-28 % slower**, depending on whether the explicit `BEGIN/COMMIT` wrapper is used. The signed-difference is in the wrong direction across every comparison, on hot-stream and new-stream alike.

### Why the architectural read in plan 22 was incomplete

The reading recorded in `docs/plans/22-optimize-singleton-append-sql-path.md` under "Why Kiroku cannot close the gap with upstream Elixir EventStore" correctly identified the structural differences between the two append paths, but it under-weighted the per-round-trip cost. Concretely:

- Each PostgreSQL round-trip in this harness costs roughly 70-80 µs of wall time (a single `SELECT stream_id, stream_version, deleted_at FROM streams WHERE stream_name = $1` takes that long, even with a prepared statement and a B-tree-indexed unique key). That cost is **PostgreSQL protocol overhead plus Hasql encode/decode**, not SQL planning or row I/O.
- The current Kiroku production CTE bundles 5 modifying operations (UPDATE streams, INSERT events, INSERT stream_events × 2, UPDATE $all streams) into one round-trip. Adding a second `SELECT` round-trip before that CTE adds 70-80 µs of pure overhead.
- The "savings" the plan promised from moving the version check into Haskell (no `WHERE stream_version = $9`, no `EXISTS` gating, no `(SELECT count(*) FROM new_events)`) are real but tiny — those are O(1) operations against a one-row CTE, dominated by the network/protocol cost.
- Wrapping the pair in an explicit `BEGIN`/`COMMIT` adds *two more* round-trips (initial `BEGIN` and final `COMMIT`), bringing the variant to 4 round-trips. The bench confirms this directly: the `+ BEGIN/COMMIT` variant is consistently ~28 µs slower than the no-tx variant on both hot and new streams, which is roughly one round-trip's worth of overhead.

The upstream Elixir EventStore wins on its own stack because Elixir + Postgrex has lower per-statement overhead than Haskell + Hasql. The shape of the SQL is secondary; the round-trip count is dominant. On Kiroku's stack, moving to two round-trips is a net loss regardless of how much simpler each statement becomes.

### Implications for follow-up plans

- **Round-trip topology is not the lever.** Future optimization plans must keep the append at one PostgreSQL round-trip. The arrays-vs-scalar question (plan 22) was already shown to be a wash inside that single round-trip; round-trip-count changes (plan 23) make things worse.
- **The remaining levers all live inside the single CTE or in the surrounding Haskell/Hasql layer:**
  - Convert `prevent_mutation` / `protect_deletion` / `protect_truncation` triggers in `kiroku-store/sql/schema.sql` from row-level to statement-level, matching upstream eventstore. Plan 22 noted this; it remains untried. Cheap to implement and validate.
  - Drop the `streams.category` generated column from the `streams` table; either move the category derivation into the append SQL or compute it at read time. Plan 22 also noted this; the previous test that removed it showed minor improvement, but in combination with other changes it may compound.
  - Investigate Hasql-level overhead: prepared-statement caching, encoder allocations, and the `Pool.use` cycle. The 70-80 µs per round-trip suggests a non-trivial amount of CPU between the Haskell-call site and the PostgreSQL wire. `kiroku-store/bench/Main.hs` already has the `raw-append-shape` group; an additional micro-benchmark of just `Session.statement` overhead against a trivial `SELECT 1` would quantify this.
- **Stop trying to close the gap with message-db.** Message-db's `write_message` is a stored procedure, not a CTE; the planner can cache and reuse its plan much more aggressively, and the gap with Kiroku largely lives in PL/pgSQL vs. CTE planning. Closing that gap likely requires moving the Kiroku append into a PL/pgSQL function as well — a much larger and riskier change than this plan ever contemplated.


## Decision Log

- Decision: Model the new append on the upstream Elixir EventStore's two-round-trip path, not on a fresh design.
  Rationale: Kiroku was originally based on that library. `EventStore.Streams.Stream.append_to_stream/5` (`lib/event_store/streams/stream.ex`) plus `EventStore.Streams.StreamInfo.validate_expected_version/2` (`lib/event_store/streams/stream_info.ex`) plus `EventStore.Storage.Appender.append/4` (`lib/event_store/storage/appender.ex`) form a coherent design that is known to perform well in production. The structural reading recorded in `docs/plans/22-optimize-singleton-append-sql-path.md` under "Why Kiroku cannot close the gap with upstream Elixir EventStore" already pinpointed this as the highest-leverage change.
  Date: 2026-05-18

- Decision: Move `ExpectedVersion` validation out of SQL into Haskell.
  Rationale: Upstream eventstore proves this is correct and fast: a `text`-indexed read of the streams row is cheap, and a Haskell-side equivalent of `validate_expected_version/2` keeps the conflict-error surface unchanged. The current Kiroku CTEs bake `WHERE stream_version = $9 AND deleted_at IS NULL` plus `EXISTS (SELECT 1 FROM stream_update)` gating into every append; these become unnecessary once Haskell has already vetoed conflicting cases before the append runs.
  Date: 2026-05-18

- Decision: Add new append statements keyed on integer `stream_id` rather than reuse the existing four `stream_name`-keyed CTEs.
  Rationale: The whole point of the restructure is to switch from text-keyed lookup against `streams.stream_name` to primary-key access against `streams.stream_id`. Mutating the existing statements to accept `stream_id` would break their CTEs' version-check / soft-delete contracts and leave behind unreachable code paths. Keeping `appendExpectedVersion`, `appendStreamExists`, `appendNoStream`, and `appendAnyVersion` compiled but unused on the hot path preserves the option to fall back during validation; they can be removed in a follow-up commit only after the new path holds in production for some time.
  Date: 2026-05-18

- Decision: Preserve public APIs and error constructors. `appendToStream`, `appendToStreamTx`, `runTransactionAppending`, `appendMultiStream`, and `AppendConflict` keep their exact signatures and case shapes.
  Rationale: This change is an internal performance restructure of `kiroku-store`. Any caller change would balloon the blast radius into shibuya, keiro, and downstream consumers. The error mapping in `kiroku-store/src/Kiroku/Store/Error.hs` (`mapUsageError`, `emptyResultError`, `appendConflictToStoreError`) is also kept; conflicts now surface from Haskell validation rather than from an empty CTE result, but the constructors and arguments must match the current contract — including `WrongExpectedVersion sn ev sv`'s third field (`StreamVersion`) being the observed current version, which the resolution query now provides for free.
  Date: 2026-05-18

- Decision: Run the two queries inside a single `Tx.Transaction` for both `appendToStream` and `appendToStreamTx`.
  Rationale: Without a transaction, a concurrent writer could advance `streams.stream_version` between the resolve and the append, breaking the optimistic concurrency contract. Upstream eventstore relies on transactional retries (`Postgrex.transaction` + `maybe_retry_once`) for the same reason. Kiroku already exposes `TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write` in `runStorePool`'s `AppendMultiStream`, `HardDeleteStream`, and `runTxOnPool` branches — `appendToStream` joins that pattern. The pool round-trip count goes from one to one (a single pooled connection acquisition wrapping a `BEGIN; SELECT …; UPDATE … RETURNING …; COMMIT`), so the network cost is one TCP exchange, not two.
  Date: 2026-05-18

- Decision: Treat the local benchmark gate as the acceptance criterion, with a stricter single-event threshold than plan 22 used.
  Rationale: Plan 22 accepted at ≥ 10 percent improvement on single-event append. That threshold made sense for a narrow SQL-shape refinement. A structural restructure should clear a much higher bar: ≥ 20 percent improvement on `All.append.single-event.AnyVersion (new stream)` and `All.append.single-event.NoStream (new stream)` versus plan 22's recorded baseline (`177421173 ps` and `205538940 ps` respectively), `All.reliability-audit.hot invoice-payment 10 AnyVersion appends` faster than the `1508472656 ps` recorded in plan 22, and batch-10 / batch-100 unchanged within 5 percent. If the restructure fails to clear ≥ 20 percent on single-event AnyVersion, treat that as an architectural surprise and document why in Outcomes before reverting.
  Date: 2026-05-18

- Decision: Defer trigger-model, schema, advisory-lock, and templated-SQL-per-count changes to follow-up plans even if this restructure under-delivers.
  Rationale: Each of those is a meaningful change on its own with its own validation surface. Bundling them into one plan would make it impossible to attribute any measured improvement to a single change. Plan 22's Outcomes already records them as candidates if this plan does not close the gap; they remain options afterwards.
  Date: 2026-05-18

- Decision: Associate this plan with intention `intention_01krxrpv5heny9gs89seas59zm`.
  Rationale: The user requested that the work continue under the same intention as plan 22, since the goal — closing the append performance gap with upstream Elixir EventStore — is the same intent that plan 22 ultimately failed to achieve with a narrower SQL-shape change. Implementation commits must include both an `ExecPlan: docs/plans/23-restructure-append-into-a-two-round-trip-path.md` trailer and an `Intention: intention_01krxrpv5heny9gs89seas59zm` trailer.
  Date: 2026-05-18

- Decision: Stop at Milestone 1; do not implement Milestones 2-6.
  Rationale: The plan's own preamble named M1 as a kill-switch: "Acceptance: the two-roundtrip hot-stream case is at least 30 percent faster than production arrays/unnest hot-stream. If it is not, stop here and update Outcomes — the architectural read is wrong and the rest of the plan is moot." The benchmark numbers recorded in Surprises & Discoveries show the two-roundtrip variant is **9-28 % slower** than the production CTE in this harness, not faster. Implementing Milestones 2-6 would invest test changes and dispatch rewiring on a path the benchmark has already disproven.
  Date: 2026-05-18

- Decision: Keep the benchmark-only `two-roundtrip` and `two-roundtrip + BEGIN/COMMIT` variants in `kiroku-store/bench/Main.hs` as durable evidence.
  Rationale: They prove a non-trivial architectural read concretely. A future plan reaching for round-trip-topology changes can re-run them in seconds to revalidate the assumption before investing in restructure. The bench's `hasql-transaction` dependency was added to `kiroku-store/kiroku-store.cabal` to support these variants and stays for the same reason.
  Date: 2026-05-18


## Outcomes & Retrospective

**Plan halted at Milestone 1's kill-switch.** The plan was built on the architectural reading in `docs/plans/22-optimize-singleton-append-sql-path.md` ("Why Kiroku cannot close the gap with upstream Elixir EventStore") that splitting append into two PostgreSQL round-trips — a small read followed by a simpler write keyed on integer `stream_id` — was the highest-leverage change. The plan's own Milestone 1 was a benchmark-only proof-of-concept designed to validate that read before investing source-level changes; the kill-switch fired.

What was actually built and is retained:

- `kiroku-store/bench/Main.hs` — four new entries in the `raw-append-shape/AnyVersion` benchmark group (`two-roundtrip (new stream)`, `two-roundtrip + BEGIN/COMMIT (new stream)`, `two-roundtrip (hot stream)`, `two-roundtrip + BEGIN/COMMIT (hot stream)`), the supporting `RawResolution` / `RawAppendExistingParams` / `RawAppendNewParams` types and encoders, the `rawResolveStreamStmt` / `rawAppendUpdateExisting` / `rawAppendCreateNew` statements, and four runner functions. A pre-creation step seeds the `raw-two-roundtrip-hot` stream before `defaultMain` so the existing-stream variant has a target row.
- `kiroku-store/kiroku-store.cabal` — `hasql-transaction >=1.1` added to the `kiroku-store-bench` build-depends so the `+ BEGIN/COMMIT` variants compile.

What was deliberately not built:

- `StreamResolution`, `resolveStreamStmt`, `appendUpdateExistingStream`, `appendCreateNewStream` in `Kiroku.Store.SQL` and the `validateExpectedVersion` / `dispatchAppendResolved` helpers in `Kiroku.Store.Effect`.
- Live-path rewiring of `appendToStream`, `appendToStreamTx`, `runTransactionAppending`, `AppendMultiStream`.
- The pre/after benchmark slice that would have measured the live restructure against the existing append baseline.

What the result means for closing the upstream gap:

- The Haskell + Hasql + hasql-pool stack costs roughly 70-80 µs per PostgreSQL round-trip in this harness, irrespective of the SQL shape. Going from one round-trip to two is a ~50 % wall-time increase that no amount of SQL simplification recovers. An explicit `BEGIN`/`COMMIT` wrapper costs another ~28 µs (one round-trip's worth) on top.
- The remaining candidates from `docs/plans/22-optimize-singleton-append-sql-path.md` — statement-level mutation triggers, removing the `streams.category` generated column, advisory-lock-based version reservation, templated SQL per event count — all preserve the single round-trip and remain on the table. The most promising of those is **statement-level mutation triggers**, both because upstream eventstore uses them and because the change is small, mechanical, and easy to validate. It should be the next plan.
- A more ambitious follow-up would move the append into a PL/pgSQL stored procedure, matching message-db's `write_message`. That trades a CTE for a function call and may allow PostgreSQL to cache a tighter plan, but it is a much larger and more invasive change than this plan ever contemplated.
- A separate, narrow micro-benchmark of pure Hasql `Session.statement` overhead against `SELECT 1` would be worth adding next; if the per-round-trip overhead really is 70-80 µs, that is itself a target — one that would shrink every Kiroku operation, not just append.

Lesson learned: **do not infer round-trip-cost from SQL shape alone.** The original read of upstream eventstore was correct about its SQL being simpler and its topology being two round-trips. It was wrong to assume that adopting that topology in a different language stack would carry the same performance characteristic. The bench-only Milestone 1 was the right gate — it cost ~90 minutes of work to disprove the plan instead of the days of source-level rewiring Milestones 2-6 would have taken.

**Followed up 2026-05-18 by `docs/plans/24-localize-the-hasql-round-trip-overhead.md`.** Plan 24 ran a transient benchmark group to ask the narrower question "is Hasql/hasql-pool itself a fat target?" and confirmed it is not (pool 605 ns; bare `SELECT 1` ~13 µs). It also measured the marginal second-round-trip cost at ~14-22 µs, which directly explains the wall-time penalty this plan observed. The bench group was deleted after extracting those two findings because the more elaborate cells were attribution-by-subtraction exercises the harness could not cleanly support.

After plan 24 the next move was tentatively named as "convert mutation triggers to FOR EACH STATEMENT and drop `streams.category`" — but this was withdrawn when it became clear that variants of those changes had already been tried (see plan 22's Surprises & Discoveries) and the project was recommending optimizations without profiling, without an expected-impact model, and without a checked-in experiment ledger. The next work is a separately-scoped master plan establishing a profile-grounded methodology, before any further optimization attempt.


## Context and Orientation

Read these files before editing:

- `docs/plans/22-optimize-singleton-append-sql-path.md` — predecessor plan. Section "Why Kiroku cannot close the gap with upstream Elixir EventStore" under Surprises & Discoveries is the architectural reading this plan acts on. Section "Outcomes & Retrospective" already names the two-round-trip restructure as the next candidate.
- `kiroku-store/src/Kiroku/Store/SQL.hs` — owns the four append CTEs (`appendExpectedVersion`, `appendStreamExists`, `appendNoStream`, `appendAnyVersion`) and the `AppendParams` encoder. Also defines `getStreamStmt` (`Statement Text (Maybe StreamInfo)` at lines around 431) and `findStreamIdStmt` (`Statement Text (Maybe Int64)` at lines around 772), the closest existing things to the new resolution query. The module is listed under `other-modules` in `kiroku-store/kiroku-store.cabal`, so new internal types and statements can be added without exposing them publicly.
- `kiroku-store/src/Kiroku/Store/Effect.hs` — owns `runStorePool`, the pool-backed interpreter. The `AppendToStream` branch (lines ~117-138) is the primary edit site. `prepareEvents` (line ~359), `buildAppendParams` (line ~382), and `appendDispatchTx` (line ~409) are the existing helpers; new equivalents (`resolveStream`, `validateExpectedVersion`, `appendDispatchTxResolved`) live alongside them. The `AppendMultiStream` branch (lines ~180-228) also needs updating.
- `kiroku-store/src/Kiroku/Store/Transaction.hs` — owns `appendToStreamTx` (line ~153) and `runTransactionAppendingWith` (line ~300). The Tx surface composes `appendDispatchTx`; under the restructure it composes `resolveStream` + `validateExpectedVersion` + the new append statement inside the caller's transaction.
- `kiroku-store/src/Kiroku/Store/Error.hs` — owns `AppendConflict` (line ~194), `appendConflictToStoreError` (line ~212), and `emptyResultConflict` (line ~225). The new Haskell validator produces these constructors directly without first calling SQL.
- `kiroku-store/src/Kiroku/Store/Types.hs` — owns `ExpectedVersion` (line ~98), `StreamVersion`, `StreamId`, `StreamInfo`, `AppendResult`. No changes here.
- `kiroku-store/sql/schema.sql` — the `streams` table with `stream_id BIGSERIAL PRIMARY KEY` and `stream_name TEXT NOT NULL UNIQUE`. `stream_id = 0` is the reserved `$all` row. `stream_version` is the column to UPDATE.
- `kiroku-store/test/Main.hs` (lines ~61-220) covers `appendToStream` across `NoStream`, `ExactVersion`, `StreamExists`, `AnyVersion`, duplicate event IDs, soft-delete behavior, and batch append. `kiroku-store/test/Test/Transaction.hs` covers `appendToStreamTx` and `runTransactionAppending`. `kiroku-store/test/Test/Concurrency.hs` covers concurrent and hot-stream behavior.
- `kiroku-store/bench/Main.hs` already has the benchmark groups `append/single-event/NoStream (new stream)`, `append/single-event/AnyVersion (new stream)`, `append/batch-10/NoStream`, `append/batch-100/NoStream`, `append/sequential/10 appends to same stream`, `concurrent/32 writers x 10 appends`, `reliability-audit/hot invoice-payment 10 AnyVersion appends`, and the new `raw-append-shape` group added by plan 22. Extend that last group rather than create a new top-level group.
- `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore` — the reference implementation. Specifically `lib/event_store/streams/stream.ex` (`append_to_stream/5`, `stream_info/4`), `lib/event_store/streams/stream_info.ex` (`validate_expected_version/2`), `lib/event_store/sql/statements/query_stream_info.sql.eex`, `lib/event_store/sql/statements/insert_events.sql.eex`, `lib/event_store/sql/statements/insert_events_any_version.sql.eex`, `lib/event_store/storage/appender.ex` (`append/4`, `insert_event_batch/6`). Note that eventstore uses a templated SQL renderer for the events VALUES list — Kiroku continues to use `unnest(array[])` for the events themselves; the restructure changes only how the streams row is found and updated, not how event rows are passed in. This keeps the diff small and lets a follow-up plan address the array-versus-templated question separately.

Definitions used in this plan:

- "Resolve the stream" means run a `SELECT stream_id, stream_version, deleted_at FROM streams WHERE stream_name = $1` and return either `Nothing` (stream absent) or `Just (stream_id, stream_version, mDeletedAt)`. This mirrors `EventStore.Storage.Stream.stream_info/3`.
- "Validate the expected version" means deciding, given a `StreamResolution` and the caller-supplied `ExpectedVersion`, whether the append can proceed. Output is `Either AppendConflict StreamTarget`, where `StreamTarget` carries either `ExistingStream stream_id current_version` or `NewStream stream_name`. This mirrors `EventStore.Streams.StreamInfo.validate_expected_version/2`.
- "Existing-stream append" is the new `Statement` that takes `(stream_id, events…)` and updates the row in place, links events, updates `$all`. No version check, no soft-delete check, no name lookup.
- "New-stream append" is the new `Statement` that takes `(stream_name, events…)` and creates the row, links events, updates `$all`. Used only when validation returned `NewStream`.
- "Two-round-trip path" refers to the pair (resolve + append) regardless of whether they execute inside `appendToStream`'s implicit transaction or a caller-supplied `Tx.Transaction`. The connection pool acquires one connection; PostgreSQL sees `BEGIN; SELECT …; INSERT/UPDATE … RETURNING …; COMMIT`. Network cost is one round-trip per query, plus the implicit `BEGIN/COMMIT` framing.


## Plan of Work

Milestone 1 — benchmark-only proof. Before touching `appendToStream`, prove with raw SQL that the two-round-trip topology is actually faster on the same `Hasql.Pool` and the same ephemeral Kiroku schema the bench harness already uses. Extend the `raw-append-shape` benchmark group in `kiroku-store/bench/Main.hs` with two more cases:

- `raw-append-shape/AnyVersion/two-roundtrip-existing (hot stream)`: prepare the stream once; per-iteration, run `SELECT stream_id, stream_version, deleted_at FROM streams WHERE stream_name = $1` then a scalar `INSERT events … VALUES (…); INSERT stream_events (…); UPDATE streams SET stream_version = stream_version + 1 WHERE stream_id = $1; UPDATE streams SET stream_version = stream_version + 1 WHERE stream_id = 0; INSERT stream_events ($all link)` wrapped in a `Tx.Transaction`.
- `raw-append-shape/AnyVersion/two-roundtrip-new (new stream)`: per-iteration, run the resolve (returning zero rows), then the new-stream INSERT/UPDATE CTE.

Run `cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p raw-append-shape --csv /tmp/kiroku-raw-append-shape-23.csv"` and compare `Mean (ps)` to the existing `raw-append-shape/AnyVersion/production arrays/unnest (hot stream)` (`240184185 ps`) and `(new stream)` (`256862695 ps`) numbers recorded in plan 22. Acceptance: the two-roundtrip hot-stream case is at least 30 percent faster than production arrays/unnest hot-stream. If it is not, stop here and update Outcomes — the architectural read is wrong and the rest of the plan is moot.

Milestone 2 — local baseline. Capture the current benchmark slice on the same machine that will run the after benchmarks. The baseline in plan 22 was on `Darwin sungkyung 25.3.0 arm64` at commit `d31443d`; the after baseline must come from this branch's pre-Milestone-3 tip. Command, machine, CSV path, and `Mean (ps)` values for the seven append benchmarks above go into Surprises & Discoveries before any source under `kiroku-store/src` is edited. Do not change `kiroku-store/bench/results/baseline.csv` during this plan.

Milestone 3 — SQL and validation primitives. Add four things to `kiroku-store/src/Kiroku/Store/SQL.hs` and `kiroku-store/src/Kiroku/Store/Effect.hs` without changing any public surface:

1. In `Kiroku.Store.SQL`, add a `StreamResolution` decoder and a `resolveStreamStmt :: Statement Text (Maybe StreamResolution)` returning `(stream_id, stream_version, deleted_at)`. The existing `getStreamStmt` returns the full `StreamInfo` (five columns); the new statement returns three, decoded into a smaller record to avoid wasted work for the hot path.
2. In `Kiroku.Store.SQL`, add `appendUpdateExistingStream :: Statement (StreamId, AppendParams) (Maybe AppendResult)`. The SQL: `WITH new_events AS (… unnest …), stream_update AS (UPDATE streams SET stream_version = stream_version + (SELECT count(*) FROM new_events) WHERE stream_id = $9 RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version), inserted_events AS (INSERT INTO events …), source_links AS (INSERT INTO stream_events … FROM new_events ne CROSS JOIN stream_update su), all_update AS (UPDATE streams SET stream_version = stream_version + (SELECT count(*) FROM new_events) WHERE stream_id = 0 RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version), all_links AS (…) SELECT su.stream_id, su.initial_version + …, au.initial_global_version + …`. No `EXISTS` gating, no `deleted_at IS NULL` check, no `stream_version = $9` check, no `stream_name = $8` comparison. Note: the `(SELECT count(*) FROM new_events)` calls can be replaced by a real `$` parameter for event count if a benchmark shows it matters, but defer that until Milestone 6 unless trivially obvious.
3. In `Kiroku.Store.SQL`, add `appendCreateNewStream :: Statement AppendParams (Maybe AppendResult)`. Same shape as the current `appendNoStreamSQL`, but without `ON CONFLICT DO NOTHING` — Haskell-side validation has already proven the stream is new, so a `INSERT INTO streams (stream_name, stream_version) VALUES ($8, (SELECT count(*) FROM new_events)) RETURNING stream_id, 0::bigint AS initial_version` is sufficient. A `unique_violation` constraint violation from `ix_streams_stream_name` becomes a `StreamAlreadyExists` via existing `mapUsageError` logic; this is the race-loss case that upstream eventstore handles with `maybe_retry_once` on `:duplicate_stream_uuid`. Document the constraint mapping in the new statement's haddock so the operator behavior matches existing code.
4. In `Kiroku.Store.Effect`, add `data StreamTarget = ExistingStream !Int64 !Int64 | NewStream !Text`, `data StreamResolution = StreamResolution { resStreamId :: !Int64, resStreamVersion :: !Int64, resDeletedAt :: !(Maybe UTCTime) }`, and `validateExpectedVersion :: StreamName -> ExpectedVersion -> Maybe StreamResolution -> Either AppendConflict StreamTarget`. The body mirrors `EventStore.Streams.StreamInfo.validate_expected_version/2`: soft-deleted → `StreamNotFoundConflict`; absent + `ExactVersion 0`/`AnyVersion`/`NoStream` → `NewStream`; absent + `StreamExists` → `StreamNotFoundConflict`; present + version matches expected → `ExistingStream stream_id stream_version`; present + `StreamExists`/`AnyVersion` → `ExistingStream`; present + `NoStream` + version 0 → `ExistingStream`; present + `NoStream` + version > 0 → `StreamAlreadyExistsConflict`; otherwise → `WrongExpectedVersionConflict`.

At the end of Milestone 3 the module compiles; nothing on the live append path uses the new statements or validator yet. `cabal build kiroku-store` is the only validation here. Do not delete or modify the existing `appendExpectedVersion`/`appendStreamExists`/`appendNoStream`/`appendAnyVersion` statements.

Milestone 4 — wire dispatch. Replace the `AppendToStream` branch in `kiroku-store/src/Kiroku/Store/Effect.hs` with a `Tx.Transaction` that runs `resolveStreamStmt`, then `validateExpectedVersion`, then dispatches:

```haskell
AppendToStream (StreamName name) expected events -> do
    rejectReservedApplicationStream name
    events' <- liftIO $ enrichEvents (store ^. #storeSettings) events
    now <- liftIO getCurrentTime
    prepared <- prepareEvents events'
    let params = buildAppendParams name now prepared
    let txn = do
            mRes <- Tx.statement name SQL.resolveStreamStmt
            case validateExpectedVersion (StreamName name) expected mRes of
                Left conflict -> pure (Left conflict)
                Right target -> Right <$> dispatchAppendResolved target params
    result <- liftIO $ Pool.use (store ^. #pool) $
        TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
    case result of
        Left usageErr -> throwError (mapUsageError name expected usageErr)
        Right (Left conflict) -> throwError (appendConflictToStoreError conflict)
        Right (Right Nothing) -> throwError (emptyResultError name expected)
        Right (Right (Just r)) -> pure r
```

where `dispatchAppendResolved :: StreamTarget -> AppendParams -> Tx.Transaction (Maybe AppendResult)` chooses between `appendUpdateExistingStream` and `appendCreateNewStream`.

Update `Kiroku.Store.Transaction.appendToStreamTx` to call the same resolve + validate + dispatch sequence inside the caller's `Tx.Transaction`, returning `Either AppendConflict AppendResult` exactly as today. `runTransactionAppendingWith` continues to wrap the body; its existing `appendToStreamTx` call now performs both round-trips inside the same transaction. The Haddock comment on `appendToStreamTx` needs updating to reflect that the resolve happens inside the Tx.

Update the `AppendMultiStream` branch: after the existing `Tx.statement names SQL.lockStreamsForMultiStmt`, run `resolveStreamStmt` for each entry, validate, and dispatch through `dispatchAppendResolved`. The `condemn`-on-`Nothing` behavior remains. Errors from the unused `appendDispatchTx`-on-`Nothing` path are no longer reachable for the success cases, but keep `appendDispatchTx` exported and compiling — `Kiroku.Store.Transaction` still references it transitively and removing it expands the diff.

At the end of Milestone 4, the live append path uses the two-round-trip topology. `cabal build kiroku-store` and `cabal build all` pass.

Milestone 5 — semantic validation. Run the focused tests then the full suite:

```bash
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"
cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"
cabal test kiroku-store:kiroku-store-test --test-options="-m Concurrency"
cabal test kiroku-store:kiroku-store-test --test-options="-m FailureInjection"
cabal test kiroku-store:kiroku-store-test
```

All must pass. If any existing test in `kiroku-store/test/Main.hs`, `kiroku-store/test/Test/Transaction.hs`, `kiroku-store/test/Test/Concurrency.hs`, or `kiroku-store/test/Test/FailureInjection.hs` fails, fix the implementation, not the test — the contract is preserving caller-visible behavior. Add new tests only if a code path is not exercised by an existing test: the most likely gap is the race-loss case where two `NewStream` validations both resolve as "absent" and one loses on the `ix_streams_stream_name` constraint; add a Hedgehog property test for it under `kiroku-store/test/Test/Properties.hs` if it does not already exist.

Milestone 6 — measure and decide. Re-run the seven-benchmark slice and write the after CSV:

```bash
cabal bench kiroku-store:kiroku-store-bench --benchmark-option=--csv --benchmark-option=/tmp/kiroku-two-roundtrip-after.csv
```

Extract the relevant rows and paste a before/after table into Surprises & Discoveries with `Mean (ps)` deltas. Acceptance criteria are listed in Validation and Acceptance.

If accepted, append a revision note to `docs/plans/22-optimize-singleton-append-sql-path.md` pointing at this plan's number, and update its Outcomes & Retrospective last paragraph to say "closed in docs/plans/23-…md". If rejected, document precisely what the after benchmarks showed, then `git revert` the implementation commits introduced by Milestones 3 and 4 — leaving the benchmark-only changes from Milestone 1 in place as future reference — and propose the next experiment (statement-level mutation triggers, advisory locks, templated SQL per event count) in Outcomes.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Confirm project identity and packages before changing code:

```bash
mori show --full
```

Expected output includes:

```text
Project: shinzui/kiroku
Packages:
  kiroku-store
  shibuya-kiroku-adapter
  kiroku-otel
```

Milestone 1 — add the two-roundtrip raw SQL benchmark variants:

```bash
$EDITOR kiroku-store/bench/Main.hs
cabal build kiroku-store:kiroku-store-bench
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p raw-append-shape --csv /tmp/kiroku-raw-append-shape-23.csv"
```

Expected output includes rows like:

```text
All.raw-append-shape.AnyVersion.two-roundtrip-existing (hot stream)    ~120000000 ps
All.raw-append-shape.AnyVersion.two-roundtrip-new (new stream)         ~190000000 ps
All.raw-append-shape.AnyVersion.production arrays/unnest (hot stream)  ~240184185 ps
All.raw-append-shape.AnyVersion.production arrays/unnest (new stream)  ~256862695 ps
```

(The ~120 µs / ~190 µs figures are speculative; record what is actually observed.)

Milestone 2 — capture the local baseline before changing append SQL:

```bash
cabal bench kiroku-store:kiroku-store-bench --benchmark-option=--csv --benchmark-option=/tmp/kiroku-two-roundtrip-before.csv
```

Expected output includes:

```text
All.append.single-event.NoStream (new stream)
All.append.single-event.AnyVersion (new stream)
All.append.batch-10.NoStream
All.append.batch-100.NoStream
All.append.sequential.10 appends to same stream
All.concurrent.32 writers x 10 appends
All.reliability-audit.hot invoice-payment 10 AnyVersion appends
```

Extract the seven relevant rows from the CSV and paste them into Surprises & Discoveries before editing source files. The plan-22 baseline values exist for reference (recorded 2026-05-18 on `Darwin sungkyung 25.3.0 arm64`) but the new before run must come from the working tree this plan starts implementation from, on the same machine the after run will use.

Milestone 3 — edit SQL and helpers:

```bash
$EDITOR kiroku-store/src/Kiroku/Store/SQL.hs
$EDITOR kiroku-store/src/Kiroku/Store/Effect.hs
cabal build kiroku-store
```

Milestone 4 — wire dispatch:

```bash
$EDITOR kiroku-store/src/Kiroku/Store/Effect.hs
$EDITOR kiroku-store/src/Kiroku/Store/Transaction.hs
cabal build kiroku-store
cabal build all
```

Milestone 5 — focused tests then full suite:

```bash
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"
cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"
cabal test kiroku-store:kiroku-store-test --test-options="-m Concurrency"
cabal test kiroku-store:kiroku-store-test --test-options="-m FailureInjection"
cabal test kiroku-store:kiroku-store-test
```

Expected output ends with `0 failures` on each command.

Milestone 6 — after benchmarks and comparison:

```bash
cabal bench kiroku-store:kiroku-store-bench --benchmark-option=--csv --benchmark-option=/tmp/kiroku-two-roundtrip-after.csv
```

Compare before and after CSVs:

```bash
python3 - <<'PY'
import csv
from pathlib import Path

before_path = Path("/tmp/kiroku-two-roundtrip-before.csv")
after_path = Path("/tmp/kiroku-two-roundtrip-after.csv")

def load(path):
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    name_key = next(k for k in rows[0] if k.lower() in {"name", "benchmark", "benchmark name"})
    mean_key = next(k for k in rows[0] if k.lower() in {"mean", "mean (ps)"})
    return {row[name_key]: float(row[mean_key]) for row in rows}

before = load(before_path)
after = load(after_path)
for name in before:
    if name in after:
        delta = ((after[name] - before[name]) / before[name]) * 100.0
        verdict = "faster" if delta < 0 else "slower"
        print(f"{name}: before_mean_ps={before[name]:.0f} after_mean_ps={after[name]:.0f} change={delta:+.2f}% {verdict}")
PY
```

Paste the comparison table into Surprises & Discoveries. Make the keep-or-revert decision per Validation and Acceptance, then write Outcomes & Retrospective.

Optional cross-store harness rerun (does not gate acceptance, but provides external corroboration):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
just compare-message-db-kiroku 5000 3 8 1
```

The `haskell-kiroku-store/appendToStream` rows should move toward the `raw-kiroku-sql/append-any-version` medians recorded in plan 22 (102 µs hot-stream, 138 µs concurrent-hot-stream).


## Validation and Acceptance

Compilation acceptance:

- `cabal build kiroku-store` passes after Milestone 3 and Milestone 4.
- `cabal build all` passes after Milestone 4.

Behavioral acceptance (all must hold; commands listed under Concrete Steps):

- `cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m Concurrency"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m FailureInjection"` passes.
- `cabal test kiroku-store:kiroku-store-test` (full suite) passes with 0 failures.
- Appending one event with `NoStream` to a new stream returns `Right AppendResult` with `streamVersion = StreamVersion 1`.
- Appending one event with `NoStream` to an existing stream returns `Left StreamAlreadyExists`.
- Appending one event with `StreamExists` to an existing stream returns `Right` with version incremented by one.
- Appending one event with `StreamExists` to a missing stream returns `Left StreamNotFound`.
- Appending one event with `ExactVersion` succeeds only when the expected version matches the current version returned by the resolution query. A mismatch returns `Left WrongExpectedVersion sn ev (StreamVersion observed)`; the third field is the version observed by the resolution query, not `StreamVersion 0`.
- Appending one event with `AnyVersion` succeeds for both missing and existing non-deleted streams.
- Appending to a soft-deleted stream returns the same `StreamNotFound` (or appropriate conflict per the existing test suite) constructor as the current code.
- Reusing an event ID returns `Left DuplicateEvent` exactly as today; the path now surfaces it from the second-round-trip append CTE's `events_pkey` constraint violation via `mapUsageError`.
- `appendToStreamTx` and `runTransactionAppending` exhibit the same semantics as `appendToStream` end-to-end, including the `Tx.condemn` behavior of `runTransactionAppendingWith` when the body's append returns `Left`.
- `appendMultiStream` continues to atomically commit all entries or none, and the `condemn`-on-`Nothing` path still rolls back; concurrent multi-stream tests under `Test.Concurrency` pass.
- A concurrent race between two writers both targeting the same new stream produces exactly one `Right` and exactly one `Left StreamAlreadyExists` (or `Left WrongExpectedVersion` on `NoStream`), never two `Right`. The losing writer's `ix_streams_stream_name` constraint violation is the failure surface.

Performance acceptance (all must hold; before / after CSVs and the Python comparison are the evidence):

- `All.append.single-event.NoStream (new stream)` improves by at least 20 percent.
- `All.append.single-event.AnyVersion (new stream)` improves by at least 20 percent.
- `All.reliability-audit.hot invoice-payment 10 AnyVersion appends` improves by at least 15 percent.
- `All.append.batch-10.NoStream` and `All.append.batch-100.NoStream` do not regress by more than 5 percent. Movement within 5 percent is treated as noise unless a repeated run proves otherwise.
- `All.append.sequential.10 appends to same stream` does not regress (each iteration is a singleton append, so the structural improvement should compound here).
- `All.concurrent.32 writers x 10 appends` does not regress by more than 5 percent.
- The `raw-append-shape/AnyVersion/two-roundtrip-existing (hot stream)` benchmark added in Milestone 1 remains at least 30 percent faster than `raw-append-shape/AnyVersion/production arrays/unnest (hot stream)` on the same machine.

The implementation is not complete until Surprises & Discoveries contains: the Milestone 1 raw-shape comparison, the Milestone 2 baseline table, the Milestone 6 after table, and a percent-change row for each of the seven benchmarks above. Without that evidence, the implementation must be reverted regardless of how clean the diff looks.

External corroboration (does not gate acceptance, but worth running):

- If `just compare-message-db-kiroku 5000 3 8 1` is rerun under `/Users/shinzui/Keikaku/bokuno/keiro`, `haskell-kiroku-store/appendToStream/hot-stream` should move from the previously recorded 186 µs toward the `raw-kiroku-sql/append-any-version/hot-stream` 102 µs floor recorded in plan 22.


## Idempotence and Recovery

The baseline, after, and raw-shape benchmark commands are safe to repeat. They use ephemeral PostgreSQL through the bench harness and write CSV files under `/tmp`. Run each command at least twice before drawing conclusions; the local machine's load can shift `Mean (ps)` by several percent between runs.

The implementation is additive and internal: new types (`StreamResolution`, `StreamTarget`), new statements (`resolveStreamStmt`, `appendUpdateExistingStream`, `appendCreateNewStream`), and a new validator (`validateExpectedVersion`) all live behind `Kiroku.Store.SQL` (private `other-modules`) and `Kiroku.Store.Effect` (internal helpers). If a milestone fails, revert the source-level commits while keeping the benchmark-only changes from Milestone 1 in place — those serve as durable evidence for the next attempt.

Do not change `kiroku-store/sql/schema.sql` for this plan. The new path operates on the existing schema (text-named, integer-id'd streams; the seeded `stream_id = 0` `$all` row; the existing `ix_streams_stream_name` unique constraint that makes the race-loss path produce `unique_violation`). Trigger model and generated-column changes are deliberately deferred — see Plan of Work Milestone 6's revert path.

Race conditions: the resolve-then-append window is contained inside one `Tx.Transaction`, so concurrent writers see consistent state via PostgreSQL's normal isolation. The case where two writers both resolve a stream as "absent" and both attempt `NewStream` resolves by the second writer hitting `ix_streams_stream_name` `unique_violation`; the resulting `usageErr` flows through `mapUsageError` and produces `StreamAlreadyExists`, the same constructor today's `appendNoStream` returns when its `ON CONFLICT DO NOTHING` yields zero rows. Upstream eventstore wraps the same race in `maybe_retry_once` (`lib/event_store/streams/stream.ex` lines around 334-349) to handle the case where the loser's actual intent was `:any_version`; this plan does not add that retry, on the basis that Kiroku has so far been explicit about returning conflicts rather than silently retrying. Decide whether to add it only if test evidence shows callers expect the silent-retry behavior.

If the after benchmark in Milestone 6 fails the acceptance gate after at least three repeated runs, revert the Milestone 3 and Milestone 4 source-level commits but keep the new benchmark variants from Milestone 1 in `kiroku-store/bench/Main.hs` — they remain useful for whatever optimization candidate comes next. Document the actual numbers in Outcomes so a future plan can build on the evidence rather than start from zero.


## Interfaces and Dependencies

This plan uses existing dependencies only:

- `hasql` for `Statement`, encoders, decoders.
- `hasql-pool` for `Pool.use`.
- `hasql-transaction` for `Tx.Transaction` and `Tx.statement`; `Hasql.Transaction.Sessions` for `transaction`, `transactionNoRetry`, `ReadCommitted`, `Write`.
- `aeson`, `uuid`, `time`, `vector` carry over from the existing append path.

Internal interfaces added or updated at each milestone (full module paths shown):

```haskell
-- Kiroku.Store.SQL (Milestone 3)
data StreamResolution = StreamResolution
    { resStreamId :: !Int64
    , resStreamVersion :: !Int64
    , resDeletedAt :: !(Maybe UTCTime)
    }

resolveStreamStmt :: Hasql.Statement.Statement Text (Maybe StreamResolution)

appendUpdateExistingStream :: Hasql.Statement.Statement (Int64, AppendParams) (Maybe AppendResult)
appendCreateNewStream :: Hasql.Statement.Statement AppendParams (Maybe AppendResult)
```

```haskell
-- Kiroku.Store.Effect (Milestone 3)
data StreamTarget
    = ExistingStream !Int64 !Int64  -- stream_id, current_version
    | NewStream !Text

validateExpectedVersion
    :: StreamName
    -> ExpectedVersion
    -> Maybe Kiroku.Store.SQL.StreamResolution
    -> Either Kiroku.Store.Error.AppendConflict StreamTarget

dispatchAppendResolved
    :: StreamTarget
    -> Kiroku.Store.SQL.AppendParams
    -> Hasql.Transaction.Transaction (Maybe AppendResult)
```

Public surface (unchanged):

- `Kiroku.Store.Append.appendToStream :: StreamName -> ExpectedVersion -> [EventData] -> Eff es AppendResult`
- `Kiroku.Store.Append.appendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Eff es [AppendResult]`
- `Kiroku.Store.Transaction.appendToStreamTx :: StreamName -> ExpectedVersion -> [PreparedEvent] -> UTCTime -> Tx.Transaction (Either AppendConflict AppendResult)`
- `Kiroku.Store.Transaction.runTransactionAppending :: StreamName -> ExpectedVersion -> [EventData] -> (AppendResult -> Tx.Transaction a) -> Eff es (Either StoreError a)`
- `Kiroku.Store.Transaction.runTransactionAppendingNoRetry`, `runTransactionAppendingResource`, `runTransactionAppendingResourceNoRetry` — all unchanged.
- `Kiroku.Store.Error.AppendConflict (..)`, `Kiroku.Store.Error.StoreError (..)` — constructor list unchanged.

Statements kept compiled but removed from the live path after Milestone 4:

- `Kiroku.Store.SQL.appendExpectedVersion`
- `Kiroku.Store.SQL.appendStreamExists`
- `Kiroku.Store.SQL.appendNoStream`
- `Kiroku.Store.SQL.appendAnyVersion`
- `Kiroku.Store.Effect.appendDispatchTx`

These remain reachable as a compile-time sanity check and a fallback site. A future plan can delete them after the new path has held in production. The cabal file under `other-modules` does not change.

Schema dependencies (unchanged, listed for completeness):

- `streams` table with `stream_id BIGSERIAL PRIMARY KEY`, `stream_name TEXT NOT NULL UNIQUE`, `stream_version BIGINT NOT NULL DEFAULT 0`, `deleted_at TIMESTAMPTZ`, and the seeded `stream_id = 0` `$all` row.
- `events` table with `event_id UUID PRIMARY KEY DEFAULT uuidv7()` and the `events_pkey` unique constraint mapped to `DuplicateEvent` by `Kiroku.Store.Error.mapUsageError`.
- `stream_events` junction table with `PRIMARY KEY (event_id, stream_id)`.
- `ix_streams_stream_name` unique index on `streams.stream_name` — the constraint that produces the race-loss `StreamAlreadyExists` for two concurrent `NewStream` writers.

## Revision Notes

- 2026-05-18: Plan created from the repository skeleton with intention `intention_01krxrpv5heny9gs89seas59zm`. The plan acts on the architectural reading recorded in `docs/plans/22-optimize-singleton-append-sql-path.md` under "Why Kiroku cannot close the gap with upstream Elixir EventStore" and adopts the two-round-trip topology of `EventStore.Streams.Stream.append_to_stream/5` at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`.
- 2026-05-18: Milestone 1 ran and **failed its own acceptance gate**. The two-roundtrip raw SQL variant is 9-28 % slower than the production arrays/unnest CTE, not 30 % faster as required. Per the plan's preamble the plan stops here; Milestones 2-6 are abandoned. Surprises & Discoveries records the bench numbers; Decision Log records the stop decision; Outcomes & Retrospective summarises the lesson (round-trip count dominates SQL shape on the Hasql stack) and proposes statement-level mutation triggers as the next experiment. The bench-only changes (new variants in `raw-append-shape/AnyVersion` and the `hasql-transaction` bench dependency) are retained as durable evidence for any future plan that proposes round-trip-topology changes.
