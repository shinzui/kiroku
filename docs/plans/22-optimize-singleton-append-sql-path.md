---
id: 22
slug: optimize-singleton-append-sql-path
title: "Optimize singleton append SQL path"
kind: exec-plan
created_at: 2026-05-18T14:38:59Z
intention: intention_01krxrpv5heny9gs89seas59zm
---

# Optimize singleton append SQL path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

## Purpose / Big Picture

Most command-side Kiroku writes append exactly one event. Today those writes still use the general batch SQL shape: Haskell packs one event into seven arrays, PostgreSQL unnests those arrays with ordinality, and the CTEs repeatedly compute the count of the one-row input. The result is correct, but the raw Message DB versus raw Kiroku comparison shows that this shape is now the suspicious cost center.

After this change, a one-event append through `appendToStream`, `appendToStreamTx`, and `runTransactionAppending` uses a dedicated scalar SQL path while multi-event appends continue to use the existing array/unnest path. A caller sees no API or semantic change: version checks, duplicate-event rejection, soft-delete behavior, stream metadata, and returned `AppendResult` stay the same. The visible outcome is lower latency for single-event append benchmarks, especially `AnyVersion` hot-stream writes, with no material regression to batch appends. This plan is associated with intention `intention_01krxrpv5heny9gs89seas59zm`; any implementation commits made under this plan must include both the `ExecPlan:` trailer and the `Intention:` trailer.

## Progress

- [x] Create this ExecPlan from the repository skeleton.
- [x] Associate this plan with intention `intention_01krxrpv5heny9gs89seas59zm`. (Completed 2026-05-18.)
- [x] Capture a local pre-change benchmark slice for single-event and batch append paths and record the exact command, date, machine context, and `Mean (ps)` values in this plan before changing append SQL. (Completed 2026-05-18.)
- [x] Implement a scalar singleton append trial in `kiroku-store/src/Kiroku/Store/SQL.hs`, `kiroku-store/src/Kiroku/Store/Effect.hs`, and `kiroku-store/src/Kiroku/Store/Transaction.hs`. (Completed 2026-05-18; not retained.)
- [x] Run focused and full store tests against the scalar singleton trial. (Completed 2026-05-18.)
- [x] Run after benchmarks and compare them with local before/control runs. (Completed 2026-05-18.)
- [x] Revert the scalar singleton trial because it did not make the append path measurably faster under the local benchmark gate. (Completed 2026-05-18.)
- [x] Add a benchmark-only raw SQL shape comparison in `kiroku-store/bench/Main.hs` for scalar singleton AnyVersion versus production arrays/unnest AnyVersion. (Completed 2026-05-18.)
- [x] Compare Kiroku's append path against the upstream Elixir EventStore (`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`) Kiroku was based on, and explain structurally why the singleton SQL shape cannot close the gap. (Completed 2026-05-18.)
- [ ] Design a different optimization candidate before attempting another production implementation. Candidates carried forward to a follow-up plan: pre-resolve `stream_id` in a separate round-trip (eventstore-style two-trip path), templated SQL per event count, FOR EACH STATEMENT mutation triggers, in-process `stream_name → stream_id` cache, advisory-lock-based version reservation.

## Surprises & Discoveries

The earlier source-level experiment in `docs/plans/21-evaluate-append-hot-path-performance-experiments.md` tried a one-event `VALUES` shape and reverted it because Kiroku's own benchmark gate did not justify the extra code. The later cross-store benchmark changes that interpretation. The prior run did not compare Kiroku's production-shape SQL against a raw scalar SQL shape with the same benchmark harness and isolation.

The current external comparison harness in `/Users/shinzui/Keikaku/bokuno/keiro/benchmarks/message-db-vs-kiroku` measured these medians with `just compare-message-db-kiroku 5000 3 8 1`:

```text
raw-message-db-sql/write_message/new-streams                         50.5724 us
raw-message-db-sql/write_message/hot-stream                          54.1572 us
raw-message-db-sql/write_message/concurrent-new-streams               36.6462 us
raw-message-db-sql/write_message/concurrent-hot-stream                41.2166 us

raw-kiroku-sql/append-any-version/new-streams                        283.244 us
raw-kiroku-sql/append-any-version/hot-stream                         102.4982 us
raw-kiroku-sql/append-any-version/concurrent-new-streams              303.3048 us
raw-kiroku-sql/append-any-version/concurrent-hot-stream               138.692 us

raw-kiroku-production-sql/append-any-version/new-streams              357.3674 us
raw-kiroku-production-sql/append-any-version/hot-stream               171.869 us
raw-kiroku-production-sql/append-any-version/concurrent-new-streams   330.923 us
raw-kiroku-production-sql/append-any-version/concurrent-hot-stream    158.9532 us

haskell-kiroku-store/appendToStream/new-streams                       383.2678 us
haskell-kiroku-store/appendToStream/hot-stream                        186.517 us
haskell-kiroku-store/appendToStream/concurrent-new-streams            314.9444 us
haskell-kiroku-store/appendToStream/concurrent-hot-stream             161.2708 us
```

The same run showed that `single-runStoreIO` was not consistently faster than the normal Haskell Kiroku path. That makes Effectful interpreter startup an unlikely primary target for this pass.

Disabling `stream_events_notify` helped more than removing the stored generated `streams.category` column. Notification remains a separate optimization candidate, but it does not explain the gap between raw scalar Kiroku SQL and raw production-shape Kiroku SQL. This plan focuses on the append SQL shape first.

Local baseline captured 2026-05-18 on `Darwin sungkyung 25.3.0 arm64` from branch `master` at commit `d31443db01838ec252cf8d75121360d79713943c`. The original filtered benchmark command in this plan failed because Cabal split the `-p` pattern at spaces before `tasty-bench` parsed it; a second attempt with repeated `--benchmark-option=-p` selected zero tests because `tasty-bench` treated the patterns as an intersection. The accepted baseline therefore uses a full benchmark CSV and extracts the relevant rows.

```text
Command: cabal bench kiroku-store:kiroku-store-bench --benchmark-option=--csv --benchmark-option=/tmp/kiroku-singleton-before.csv
CSV: /tmp/kiroku-singleton-before.csv

Benchmark                                                    Mean (ps)
All.append.single-event.NoStream (new stream)                205538940
All.append.single-event.AnyVersion (new stream)              177421173
All.append.batch-10.NoStream                                 434935742
All.append.batch-100.NoStream                                2544087500
All.append.sequential.10 appends to same stream              1764870312
All.concurrent.32 writers x 10 appends                       586458962500
All.reliability-audit.hot invoice-payment 10 AnyVersion appends 1508472656
```

The scalar singleton trial compiled and passed tests but failed the performance gate. The first after run used the same full CSV method as the baseline and wrote `/tmp/kiroku-singleton-after.csv`. It showed broad slowdown, including unchanged batch benchmarks, so a narrower near-time control was added to separate code effect from machine noise. The focused scalar run wrote `/tmp/kiroku-singleton-after-focused.csv`; the implementation files were then stashed and the exact same focused benchmark was rerun against the original batch append path as `/tmp/kiroku-singleton-before-focused-control.csv`.

```text
Focused command:
cabal bench kiroku-store:kiroku-store-bench --benchmark-option=-p --benchmark-option='$0 == "All.append.single-event.NoStream (new stream)" || $0 == "All.append.single-event.AnyVersion (new stream)" || $0 == "All.append.batch-10.NoStream" || $0 == "All.append.batch-100.NoStream" || $0 == "All.append.sequential.10 appends to same stream" || $0 == "All.concurrent.32 writers x 10 appends" || $0 == "All.reliability-audit.hot invoice-payment 10 AnyVersion appends"' --benchmark-option=--csv --benchmark-option=<csv-path>

Benchmark                                                    Before control Mean (ps)  Scalar trial Mean (ps)  Change
All.append.single-event.NoStream (new stream)                169827420                 173689501               +2.27%
All.append.single-event.AnyVersion (new stream)              166038525                 189620605               +14.20%
All.append.batch-10.NoStream                                 399379296                 463682617               +16.10%
All.append.batch-100.NoStream                                2574535156                2589526562              +0.58%
All.append.sequential.10 appends to same stream              1730798828                1989978125              +14.97%
All.concurrent.32 writers x 10 appends                       784906775000              955480800000            +21.73%
All.reliability-audit.hot invoice-payment 10 AnyVersion appends 1691260156             1636809375              -3.22%
```

Evidence from validation before the revert:

```text
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"
19 examples, 0 failures

cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"
3 examples, 0 failures

cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"
4 examples, 0 failures

cabal test kiroku-store:kiroku-store-test
129 examples, 0 failures
```

A later benchmark-only raw SQL shape comparison was added to `kiroku-store/bench/Main.hs` without changing production append dispatch. It compares `AnyVersion` scalar singleton SQL with the current production arrays/unnest SQL using the same `Hasql.Pool` and ephemeral Kiroku schema. The benchmark target built with:

```sh
cabal build kiroku-store:kiroku-store-bench
```

The focused benchmark command was:

```sh
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p raw-append-shape --csv /tmp/kiroku-raw-append-shape.csv"
```

It produced:

```text
Name                                                              Mean (ps)
All.raw-append-shape.AnyVersion.scalar singleton (new stream)     261766113
All.raw-append-shape.AnyVersion.production arrays/unnest (new stream) 256862695
All.raw-append-shape.AnyVersion.scalar singleton (hot stream)     280996533
All.raw-append-shape.AnyVersion.production arrays/unnest (hot stream) 240184185
```

This local benchmark does not prove a scalar speedup. In this harness, the scalar statement is effectively tied for new-stream appends and slower for hot-stream appends. Treat this as evidence that the scalar CTE shape itself is not the next production optimization candidate.

### Why Kiroku cannot close the gap with upstream Elixir EventStore

Kiroku was originally based on the Elixir EventStore library at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore` (commonly used via Commanded). The plan's earlier sections compared Kiroku to Message DB; the user's concern is the gap to that Elixir upstream. Reading `lib/event_store/streams/stream.ex`, `lib/event_store/storage/appender.ex`, `lib/event_store/sql/init.ex`, and `lib/event_store/sql/statements/insert_events.sql.eex` / `insert_events_any_version.sql.eex` makes the structural divergence explicit. The singleton SQL shape investigated above cannot close the gap because the gap is not in the SQL shape — it is in the round-trip topology, the trigger model, the schema, and where version checks live.

Upstream eventstore append path (per append call):

1. **Round-trip 1 — `query_stream_info`** is a one-row `SELECT stream_id, stream_uuid, stream_version, created_at, deleted_at FROM streams WHERE stream_uuid = $1`. The `stream_uuid` column is plain `text` with a unique B-tree index; no `category` generated column, no soft-delete predicate inside the index. The result feeds `EventStore.Streams.StreamInfo.validate_expected_version/2`, which runs **in Elixir, not SQL**. It is the validator that decides `stream_exists`, `stream_not_found`, `wrong_expected_version`, `stream_deleted`, and that `no_stream` corresponds to `stream_id == nil`.
2. **Round-trip 2 — `insert_events` or `insert_events_any_version`** is a CTE that already knows the `stream_id` (integer) and the count of events (`$2`). The SQL has no version check, no soft-delete check, no `EXISTS (SELECT 1 FROM stream_update)` gating, and no `(SELECT count(*) FROM new_events)`. The `stream` CTE is a single-row `UPDATE streams SET stream_version = stream_version + $2 WHERE stream_id = $1::bigint RETURNING stream_id` when the stream is known, or a `INSERT INTO streams (stream_uuid, stream_version)` when it is new.
3. The CTE materialises events as an inline `VALUES (…), (…), …` list. The SQL template (`insert_events.sql.eex`) is rendered per event count: 1 event compiles to 11 bind parameters, 100 events compiles to 902. Each rendered statement gets its own prepared-statement entry, so each "shape" is planned once and reused.

Kiroku's append path (per append call):

1. **One round-trip** that does everything. `appendExpectedVersionSQL`, `appendStreamExistsSQL`, `appendNoStreamSQL`, and `appendAnyVersionSQL` in `kiroku-store/src/Kiroku/Store/SQL.hs` each look up the stream by `stream_name = $8` (text), check `stream_version` and `deleted_at IS NULL` inside the same statement, and fan out events via `unnest($1::uuid[], …, $7::timestamptz[]) WITH ORDINALITY`.
2. `(SELECT count(*) FROM new_events)` appears **six times** per statement. PostgreSQL may collapse some of these into a shared scan, but the planner still has to reason about each instance.
3. `appendAnyVersionSQL` uses `INSERT INTO streams … ON CONFLICT (stream_name) DO UPDATE`. For the hot-stream case — which is the common command-side write — this attempts an INSERT before falling through to the UPDATE branch every time.
4. `kiroku-store/sql/schema.sql` adds work eventstore does not have:
    - A `category` column declared `GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED`. Every UPDATE that touches `streams` recomputes this.
    - A `stream_events_notify` AFTER INSERT OR UPDATE trigger on `streams` that calls `pg_notify`. Eventstore has the equivalent (`event_notification` trigger calling `notify_events`), so this isn't an extra cost over upstream — note it only for completeness.
    - `prevent_mutation` / `protect_deletion` / `protect_truncation` triggers attached **FOR EACH ROW** to `events` and `stream_events`. Eventstore declares the same protective triggers **FOR EACH STATEMENT** in `lib/event_store/sql/init.ex` (`prevent_event_update`, `prevent_event_delete`, `prevent_stream_events_update`, `prevent_stream_events_delete`). For a 1-event append the difference is invisible; for a 100-event append, Kiroku's row-level triggers fire 100 times on `events` and 200 times on `stream_events`, even though they only `RAISE EXCEPTION` and otherwise no-op.

Why the gap is structural, not array-versus-scalar:

- Even the benchmark-only raw scalar Kiroku CTE (`raw-kiroku-sql/append-any-version/hot-stream` at 102.5 µs) is roughly twice the cost of message-db's single-roundtrip scalar `write_message` (54.2 µs), and slower than what two well-tuned eventstore round-trips would cost. Rewriting only the parameter binding from arrays to scalars keeps every other expensive ingredient: text-keyed stream lookup, in-SQL version and soft-delete checks, the EXISTS gating that conditions every downstream CTE on `stream_update`, the `count(*)` repetitions, the `stream_upsert` INSERT-then-UPDATE for AnyVersion.
- Eventstore wins by **moving work out of the append statement**, not by writing a clever statement. Its first round-trip is essentially free of CTE complexity; its second round-trip operates on a known integer primary key with no conditional logic. The two round-trips together approximate the cost of one Kiroku CTE because each is much simpler than what Kiroku tries to do atomically.
- The local benchmark gate set by this plan (≥ 10 % faster on `single-event.AnyVersion`, faster on `hot invoice-payment 10 AnyVersion appends`, no batch regression) is therefore unreachable by any rewrite that preserves Kiroku's one-round-trip, text-keyed, in-SQL-validated append shape. The raw-shape comparison added to `kiroku-store/bench/Main.hs` is direct evidence: even with the friendliest possible Kiroku-shape SQL (scalar singleton, no arrays), the result is tied with or slower than the production array path. The reason there is no headroom in that comparison is that both statements pay the same `count(*)`, `EXISTS`, text-keyed lookup, and trigger costs.

Implications for the next plan:

- **Round-trip topology.** Adopt an eventstore-style two-round-trip path for command-side writes: a `SELECT stream_id, stream_version, deleted_at FROM streams WHERE stream_name = $1` followed by a simpler append CTE keyed on `stream_id`. Move `ExpectedVersion`, `NoStream`, `StreamExists`, and soft-delete handling out of SQL into Haskell, mirroring `StreamInfo.validate_expected_version/2`. This is the single change most likely to close most of the gap.
- **Stream identity cache.** Once stream_id is the primary key for append, an in-process `stream_name → (stream_id, deleted_at)` cache per pool (invalidated on rare lifecycle changes) can collapse the two round-trips back to one for hot streams without resurrecting the text-keyed CTE.
- **Trigger model.** Convert the row-level `prevent_mutation` triggers in `kiroku-store/sql/schema.sql` to statement-level triggers, matching eventstore. This pays off on batch appends and link-to-stream operations.
- **Schema.** Reconsider `streams.category` as a generated column. Earlier evidence in this plan says removing it alone did not move the needle, but in combination with the round-trip change it may compound.
- **Templated SQL per event count.** Eventstore renders one statement shape per event count and relies on PostgreSQL prepared-statement caching. Kiroku could do the same in Haskell using a small LRU keyed by event count for, say, 1, 2, 4, 8, 16, 32, 64 events, with the array/unnest path as the fall-through above that bound. This is only worth attempting after the round-trip restructure.
- **Advisory locks for version reservation.** Eventstore relies on PostgreSQL constraint violations (`unique_violation` on `events_pkey` / `stream_events_pkey`) plus the validator's earlier read to detect conflicts. Kiroku could instead take a per-stream advisory lock, read the current version cheaply, and then insert without an in-SQL version predicate. This is a larger change and should not be the first thing tried.

This is why the singleton SQL shape, on its own, is not enough — and why the next plan must restructure the round-trip topology rather than refine the existing one-shot CTE.

## Decision Log

- Decision: Do not target Effectful overhead in this plan.
  Rationale: `haskell-kiroku-store/appendToStream/.../single-runStoreIO` did not consistently improve over the normal Haskell path, while raw scalar SQL was much faster than production-shape SQL.
  Date: 2026-05-18

- Decision: Keep the existing array/unnest SQL path for empty and multi-event appends, and add a narrow scalar path for exactly one prepared event.
  Rationale: Batch append is a real feature and the current shape is appropriate for many events. The suspicious cost is paying batch machinery for the dominant singleton case.
  Date: 2026-05-18

- Decision: Implement singleton statements for every `ExpectedVersion` constructor, not only `AnyVersion`.
  Rationale: The user-visible API dispatches on `ExpectedVersion`; optimizing only one constructor would create an internal performance cliff and leave `ExactVersion` command handlers on the old path.
  Date: 2026-05-18

- Decision: Preserve public APIs and schema.
  Rationale: The improvement should be internal to `kiroku-store`; callers should not change imports, migrations, event data, or error handling.
  Date: 2026-05-18

- Decision: Associate this work with intention `intention_01krxrpv5heny9gs89seas59zm`.
  Rationale: The user explicitly requested that this plan use that intention for the work, so implementation commits must include an `Intention: intention_01krxrpv5heny9gs89seas59zm` trailer in addition to the plan trailer.
  Date: 2026-05-18

- Decision: Treat the local benchmark comparison as a hard acceptance gate, not optional evidence.
  Rationale: The user wants to ensure the change makes the append path measurably faster. The implementation should only be accepted if the same local benchmark slice is captured before and after the SQL change and shows the required single-event improvement without material batch regression. The local benchmark suite uses `tasty-bench`, whose CSV output records `Mean (ps)` and `2*Stdev (ps)`, so this plan compares `Mean (ps)` unless the benchmark command is changed to produce a different documented statistic.
  Date: 2026-05-18

- Decision: Use full benchmark CSVs for the local before/after comparison instead of the originally planned filtered benchmark invocation.
  Rationale: The benchmark runner did not preserve the intended space-containing pattern through Cabal, and multiple `-p` arguments selected zero tests. Full CSV output includes the same relevant benchmark rows and avoids changing benchmark semantics between before and after runs.
  Date: 2026-05-18

- Decision: Revert the scalar singleton append trial.
  Rationale: The trial passed the focused and full test suites but did not make the local append benchmarks measurably faster. In the near-time focused control comparison, `AnyVersion` single-event append was 14.20% slower and `NoStream` single-event append was only within noise at 2.27% slower; the hot invoice-payment benchmark improved by only 3.22%, below the acceptance threshold.
  Date: 2026-05-18

- Decision: Keep the raw SQL shape comparison as benchmark evidence only.
  Rationale: The benchmark-only comparison also failed to show scalar singleton SQL beating production arrays/unnest SQL, so it should not be wired into `appendToStream`.
  Date: 2026-05-18

- Decision: Stop trying to close the gap by reshaping the one-round-trip append CTE; the next attempt must restructure the round-trip topology.
  Rationale: A structural reading of the upstream Elixir EventStore (`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`) Kiroku was based on shows that its speed comes from splitting append into two simple round-trips (one read by `stream_uuid` returning `stream_id`/`stream_version`/`deleted_at`, with version validation in Elixir; then a per-event-count templated INSERT keyed on integer `stream_id`), plus statement-level mutation-prevention triggers and a leaner streams schema. Kiroku's single-round-trip CTE bundles text-keyed lookup, version check, soft-delete check, `count(*)` over `new_events`, EXISTS gating of every downstream CTE, and an `INSERT … ON CONFLICT DO UPDATE` upsert for AnyVersion, plus row-level mutation triggers and a generated `category` column. The benchmark-only raw scalar Kiroku CTE was already at most tied with the production array shape, which means there is no remaining slack inside the existing CTE shape to recover from a singleton rewrite.
  Date: 2026-05-18

## Outcomes & Retrospective

The first scalar singleton SQL implementation was not accepted. It added a `SingletonAppendParams` record, scalar Hasql encoders, four singleton append statements, and dispatch branches for `appendToStream`, `appendToStreamTx`, and `runTransactionAppending`. The code compiled and passed all semantic tests, including the full `kiroku-store` test suite, but local benchmark evidence did not show the required speedup. The implementation was reverted from the working tree, leaving this plan updated with the benchmark evidence.

A subsequent benchmark-only comparison added to `kiroku-store/bench/Main.hs` confirmed the negative result at the raw-SQL level: a scalar singleton CTE in the same Kiroku shape was tied with the production array/unnest path on new-stream appends and slower on hot-stream appends. There is no remaining slack inside Kiroku's one-round-trip append CTE shape that a singleton rewrite can recover.

This plan also produced the clearer architectural finding the user was after: **why we cannot close the gap with the upstream Elixir EventStore Kiroku was based on**. See *Why Kiroku cannot close the gap with upstream Elixir EventStore* under Surprises & Discoveries for the detailed reading of `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore` against `kiroku-store/src/Kiroku/Store/SQL.hs` and `kiroku-store/sql/schema.sql`. The short version: eventstore wins on round-trip topology, not on SQL cleverness. It splits append into a one-row `SELECT stream_id, stream_uuid, stream_version, …` followed by a templated insert keyed on the integer `stream_id`, with `validate_expected_version/2` running in Elixir. Kiroku does all of that in one CTE — text-keyed lookup, in-SQL version and soft-delete checks, `count(*)` over `new_events` repeated six times, `EXISTS`-gated downstream CTEs, and an upsert for AnyVersion — plus row-level mutation triggers and a generated `category` column on `streams`. The gap is the sum of those structural costs, not the array binding.

The next plan should therefore not try a third variant of the singleton SQL shape. The highest-leverage move is to restructure the round-trip topology: pre-resolve `stream_id` / `stream_version` / `deleted_at` in a small read query, move `ExpectedVersion` validation into Haskell mirroring `EventStore.Streams.StreamInfo.validate_expected_version/2`, and run a far simpler append CTE keyed on `stream_id`. Once that is in place, an in-process `stream_name → stream_id` cache can collapse the two round-trips back to one for hot streams, statement-level mutation triggers can replace the current row-level ones, and a per-event-count templated SQL renderer can match eventstore's prepared-statement-per-shape model. Advisory-lock-based version reservation is a further option but should not be the first thing tried. Any of those follow-ups belongs in its own ExecPlan because each touches the public append path in ways this plan's "internal-only, additive" scoping rule does not permit.

**Update 2026-05-18 — the round-trip topology hypothesis was tested and disproven.** `docs/plans/23-restructure-append-into-a-two-round-trip-path.md` ran a benchmark-only Milestone 1 that compared the two-round-trip raw SQL shape against the production arrays/unnest CTE on the same harness. The result: the two-roundtrip variant is **9-28 % slower**, not faster. The plan-23 acceptance gate required ≥ 30 % faster on hot-stream and the gate failed; plan 23 halted at Milestone 1 without touching live code. A follow-up (`docs/plans/24-localize-the-hasql-round-trip-overhead.md`) measured the marginal cost of a second round-trip on a hot pooled connection at ~14-22 µs and confirmed `Hasql.Pool` itself is sub-microsecond — i.e., the SDK is not the bottleneck, and the second-round-trip penalty is structural rather than overhead we could shave.

**Update 2026-05-18 — recommending another optimization plan from the "remaining candidates" list (statement-level triggers, dropping `streams.category`, advisory locks, templated SQL) was identified as the wrong move.** Several of those candidates have been informally tried before (this plan's Surprises & Discoveries records that `streams.category` removal was tested and helped less than disabling `stream_events_notify`, and neither closed the gap), and the list is being re-recommended across plans without an expected-impact model or profile-grounded reason to prefer one over another. The next work is a methodology plan that introduces Haskell-side profiling, PostgreSQL-side `EXPLAIN (ANALYZE, BUFFERS, TIMING)`, and a checked-in experiment ledger so subsequent optimization plans have a profile-grounded basis. That work is scoped as a master plan separate from this one.

## Context and Orientation

`kiroku-store/src/Kiroku/Store/SQL.hs` owns the append SQL and Hasql encoders. It currently defines `AppendParams`, `appendParamsEncoder`, and statements such as `appendNoStream`, `appendStreamExists`, `appendExpectedVersion`, and `appendAnyVersion`. `AppendParams` stores seven vectors plus `streamName`, and each append SQL statement starts from:

```sql
unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
```

The SQL is internal. `kiroku-store/kiroku-store.cabal` lists `Kiroku.Store.SQL` under `other-modules`, so this plan can add internal types and statements without exposing them as a public API.

`kiroku-store/src/Kiroku/Store/Effect.hs` owns the normal pool-backed interpreter. The append branch in `runStorePool` rejects `$all`, enriches events, calls `prepareEvents`, captures `now`, calls `buildAppendParams`, and then dispatches through the SQL statement selected by `appendDispatchTx` or the pool equivalent. `buildAppendParams` currently builds the seven vectors for all event counts, including one event.

`kiroku-store/src/Kiroku/Store/Transaction.hs` exposes `appendToStreamTx`, `prepareEventsIO`, and `runTransactionAppending`. `appendToStreamTx` currently calls `buildAppendParams` and `appendDispatchTx`, so a complete fix must make the transaction path benefit from singleton dispatch too. `runTransactionAppending` delegates to `appendToStreamTx`.

`kiroku-store/test/Main.hs` already contains broad public tests for `appendToStream`, including `NoStream`, `ExactVersion`, `StreamExists`, `AnyVersion`, duplicate event IDs, reserved stream names, soft-deleted streams, and batch append. `kiroku-store/test/Test/Transaction.hs` covers `appendToStreamTx` and `runTransactionAppending`. `kiroku-store/test/Test/Concurrency.hs` covers hot and concurrent append behavior.

`kiroku-store/bench/Main.hs` already has relevant benchmark names:

```text
append/single-event/NoStream (new stream)
append/single-event/AnyVersion (new stream)
append/batch-10/NoStream
append/batch-100/NoStream
append/sequential/10 appends to same stream
concurrent/32 writers x 10 appends
reliability-audit/hot invoice-payment 10 AnyVersion appends
```

Definitions used in this plan:

- A singleton append is an append where the prepared event list has exactly one event.
- The batch path is the existing vector, array, and `unnest` SQL path.
- A scalar SQL path is a statement whose parameters are one event's scalar fields, not arrays.
- The hot stream case repeatedly appends one event to the same stream with `AnyVersion`.
- `AppendResult` is the stream version and global position returned to callers after a successful append.

## Plan of Work

Milestone 1 captures the current local baseline before implementation. Run a focused benchmark slice before editing SQL so the final result can be compared against this working tree, not only against the external cross-store harness. Record the date, branch or commit, machine context if known, exact command, CSV path, and relevant `Mean (ps)` values for single-event, batch, sequential, concurrent, and hot invoice-payment append benchmarks in `Surprises & Discoveries`. Do not start the SQL change until the baseline is recorded in this plan; without a local "before" value, there is no defensible way to prove this plan made anything faster.

Milestone 2 adds scalar SQL machinery in `kiroku-store/src/Kiroku/Store/SQL.hs`. Add a `SingletonAppendParams` record with these fields:

```haskell
eventId :: UUID
eventType :: Text
causationId :: Maybe UUID
correlationId :: Maybe UUID
payload :: Value
metadata :: Maybe Value
createdAt :: UTCTime
streamName :: Text
```

Add a `singletonAppendParamsEncoder` with scalar Hasql encoders in the same order. Add singleton statement variants for `NoStream`, `StreamExists`, `ExactVersion`, and `AnyVersion`. Each statement returns the same decoded result as the current statement: `Maybe AppendResult`. The singleton SQL should use a one-row `VALUES` or `SELECT` CTE named like `new_event` instead of `new_events`, use literal `1` wherever the current batch statement uses `(SELECT count(*) FROM new_events)`, and keep the same locks, version checks, soft-delete checks, duplicate-event handling, stream update, event insert, and result columns as the existing statement.

Milestone 3 wires dispatch without changing public APIs. In `kiroku-store/src/Kiroku/Store/Effect.hs`, add `buildSingletonAppendParams :: Text -> UTCTime -> PreparedEvent -> SingletonAppendParams`. Add `appendSingletonDispatchTx :: ExpectedVersion -> SingletonAppendParams -> Tx.Transaction (Maybe AppendResult)` or an equivalent helper next to `appendDispatchTx`. Add the pool-backed equivalent if the existing interpreter dispatches outside `Tx.Transaction`. Change the append branch so that exactly one prepared event calls the singleton dispatch and two or more events call the existing batch dispatch. Preserve current empty-list behavior by leaving it on the existing batch path unless a separate plan changes the public contract.

Milestone 3 must also cover `appendToStreamTx` in `kiroku-store/src/Kiroku/Store/Transaction.hs`. Either call a shared `appendPreparedEventsTx` helper exported from `Kiroku.Store.Effect`, or pattern match in `appendToStreamTx` and call `buildSingletonAppendParams` plus singleton dispatch directly. At the end of the milestone, `appendToStream`, `appendToStreamTx`, and `runTransactionAppending` all use the singleton path for exactly one prepared event.

Milestone 4 proves semantics. Run the existing store tests. If existing public tests do not force each singleton statement variant, add targeted tests under `kiroku-store/test/Main.hs` or `kiroku-store/test/Test/Transaction.hs` that append exactly one event through `NoStream`, `StreamExists`, `ExactVersion`, and `AnyVersion`, then verify returned stream versions and expected conflict constructors. Keep batch append tests in place to prove the old path still works.

Milestone 5 measures and decides whether to keep the optimization. Re-run the focused Kiroku benchmarks with the same command filter used in Milestone 1 and write results to a separate after CSV. Add a before/after table to `Surprises & Discoveries` with benchmark name, before `Mean (ps)`, after `Mean (ps)`, percent change, and verdict. The singleton path is accepted only if the `Mean (ps)` for one-event append benchmarks improves by at least 10 percent, `hot invoice-payment 10 AnyVersion appends` improves, and `batch-10` and `batch-100` do not regress materially. If the result is within noise or slower after repeated runs, revert the singleton implementation and record why in Outcomes.

## Concrete Steps

Work from the repository root:

```sh
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
```

Confirm project identity and dependency layout before changing code:

```sh
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

Capture a focused baseline:

```sh
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p 'append.single-event|append.batch-10|append.batch-100|append.sequential|32 writers|hot invoice-payment' --csv /tmp/kiroku-singleton-before.csv"
```

Expected output includes benchmark rows with names like:

```text
All.append.single-event.NoStream (new stream)
All.append.single-event.AnyVersion (new stream)
All.reliability-audit.hot invoice-payment 10 AnyVersion appends
```

Before editing append SQL, paste a concise baseline note into `Surprises & Discoveries` using this shape:

```text
Local baseline captured 2026-05-18 on <machine/context>.
Command: cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p 'append.single-event|append.batch-10|append.batch-100|append.sequential|32 writers|hot invoice-payment' --csv /tmp/kiroku-singleton-before.csv"
CSV: /tmp/kiroku-singleton-before.csv

Benchmark                                                    Mean (ps)
All.append.single-event.NoStream (new stream)                <value>
All.append.single-event.AnyVersion (new stream)              <value>
All.append.batch-10.NoStream                                 <value>
All.append.batch-100.NoStream                                <value>
All.append.sequential.10 appends to same stream              <value>
All.concurrent.32 writers x 10 appends                       <value>
All.reliability-audit.hot invoice-payment 10 AnyVersion appends <value>
```

Edit the internal append SQL:

```sh
$EDITOR kiroku-store/src/Kiroku/Store/SQL.hs
$EDITOR kiroku-store/src/Kiroku/Store/Effect.hs
$EDITOR kiroku-store/src/Kiroku/Store/Transaction.hs
```

Run formatting if the repository has a formatter target, otherwise keep the existing style:

```sh
just --list
```

Run the focused tests:

```sh
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"
cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"
cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"
```

Run the full store test suite before accepting the change:

```sh
cabal test kiroku-store:kiroku-store-test
```

Capture the after benchmark with the same filter:

```sh
cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p 'append.single-event|append.batch-10|append.batch-100|append.sequential|32 writers|hot invoice-payment' --csv /tmp/kiroku-singleton-after.csv"
```

Compare the local before and after CSVs before accepting the change:

```sh
python3 - <<'PY'
import csv
from pathlib import Path

before_path = Path("/tmp/kiroku-singleton-before.csv")
after_path = Path("/tmp/kiroku-singleton-after.csv")

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

If the CSV column names differ from the helper's assumptions, inspect the first line of each CSV and adapt the key names. Paste the resulting comparison table into `Surprises & Discoveries`, then summarize the keep-or-revert decision in `Outcomes & Retrospective`.

Optionally rerun the external cross-store harness that exposed the production-shape SQL gap:

```sh
cd /Users/shinzui/Keikaku/bokuno/keiro
just compare-message-db-kiroku 5000 3 8 1
```

Record the before and after local benchmark means in `Surprises & Discoveries` and summarize the decision in `Outcomes & Retrospective`.

## Validation and Acceptance

Compilation acceptance:

- `cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStream"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m appendToStreamTx"` passes.
- `cabal test kiroku-store:kiroku-store-test --test-options="-m runTransactionAppending"` passes.
- `cabal test kiroku-store:kiroku-store-test` passes.

Behavioral acceptance:

- Appending one event with `NoStream` to a new stream returns `Right AppendResult` with `streamVersion = StreamVersion 1`.
- Appending one event with `NoStream` to an existing stream returns `Left StreamAlreadyExists`.
- Appending one event with `StreamExists` to an existing stream increments the stream version by one.
- Appending one event with `StreamExists` to a missing stream returns `Left StreamNotFound`.
- Appending one event with `ExactVersion` succeeds only when the expected version matches.
- Appending one event with `AnyVersion` works for both missing and existing non-deleted streams.
- Reusing an event ID still returns `Left DuplicateEvent`.
- Appending to a soft-deleted stream still returns the same error constructors currently expected by tests.
- `appendToStreamTx` and `runTransactionAppending` use the same singleton behavior as `appendToStream`.
- Appending two or more events still uses the batch path and preserves sequential stream versions.

Performance acceptance:

- `All.append.single-event.NoStream (new stream)` improves by at least 10 percent versus the local pre-change `Mean (ps)`.
- `All.append.single-event.AnyVersion (new stream)` improves by at least 10 percent versus the local pre-change `Mean (ps)`.
- `All.reliability-audit.hot invoice-payment 10 AnyVersion appends` improves versus the local pre-change `Mean (ps)`.
- `All.append.batch-10.NoStream` and `All.append.batch-100.NoStream` do not regress materially. Treat less than 5 percent movement in `Mean (ps)` as noise unless repeated runs prove otherwise.
- If the external harness is rerun, Haskell Kiroku should move closer to `raw-kiroku-sql/append-any-version` than to the prior `raw-kiroku-production-sql/append-any-version` medians.
- The implementation is not complete until `Surprises & Discoveries` contains the local before benchmark, the local after benchmark, and a before/after percent-change table produced from the same benchmark filter on the same machine.

## Idempotence and Recovery

The baseline and after benchmark commands are safe to repeat. They use ephemeral PostgreSQL through the benchmark harness and write CSV files under `/tmp`.

The implementation is additive and internal: new parameter types, encoders, statements, and dispatch branches can be removed without changing schema or public Haskell APIs. If a singleton statement fails a semantic test, route exactly-one-event appends back through `buildAppendParams` and `appendDispatchTx`, then inspect the SQL diff between the singleton and batch statement.

Do not change `kiroku-store/sql/schema.sql` for this plan. Notification trigger work and generated-column work are separate concerns; changing schema here would make the performance result harder to attribute.

If benchmark results are noisy, repeat both the before and after focused benchmark commands at least three times before deciding. Compare `Mean (ps)` values within the same command filter and same machine load. Do not update `kiroku-store/bench/results/baseline.csv` until the code change is accepted.

## Interfaces and Dependencies

This plan uses existing dependencies only:

- `hasql` for `Statement`, encoders, decoders, and transaction execution.
- `hasql-transaction` for `Tx.Transaction` in `appendToStreamTx`.
- `aeson` for event `Value` payloads and metadata.
- `uuid` for `UUID`.
- `time` for `UTCTime`.
- `vector` remains in use for the batch path but should not be needed by singleton parameter construction.

Internal interfaces to add or update:

```haskell
data SingletonAppendParams = SingletonAppendParams
    { eventId :: UUID
    , eventType :: Text
    , causationId :: Maybe UUID
    , correlationId :: Maybe UUID
    , payload :: Value
    , metadata :: Maybe Value
    , createdAt :: UTCTime
    , streamName :: Text
    }
```

```haskell
singletonAppendNoStream :: Statement SingletonAppendParams (Maybe AppendResult)
singletonAppendStreamExists :: Statement SingletonAppendParams (Maybe AppendResult)
singletonAppendExpectedVersion :: Statement (SingletonAppendParams, StreamVersion) (Maybe AppendResult)
singletonAppendAnyVersion :: Statement SingletonAppendParams (Maybe AppendResult)
```

```haskell
buildSingletonAppendParams :: Text -> UTCTime -> PreparedEvent -> SingletonAppendParams
appendSingletonDispatchTx :: ExpectedVersion -> SingletonAppendParams -> Tx.Transaction (Maybe AppendResult)
```

The exact names may change to match local style, but the final implementation must have these capabilities and keep `Kiroku.Store.SQL` hidden from public package exports.

## Revision Notes

- 2026-05-18: Added intention `intention_01krxrpv5heny9gs89seas59zm` to the plan frontmatter and clarified commit trailer expectations. Strengthened the benchmark requirements so implementation must record local before and after benchmark means from the `tasty-bench` CSV output, compare percent change from the same benchmark slice, and accept the optimization only when the measured result is faster without material batch regression.
- 2026-05-18: Recorded the scalar singleton implementation trial, corrected the benchmark command details, captured local before/after/control benchmark evidence, and documented the decision to revert the trial because it failed the measurable-speedup gate.
- 2026-05-18: Added a structural comparison against the upstream Elixir EventStore at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore` (`lib/event_store/streams/stream.ex`, `lib/event_store/storage/appender.ex`, `lib/event_store/sql/init.ex`, `lib/event_store/sql/statements/insert_events*.sql.eex`) to answer the question of why Kiroku cannot close the gap with the codebase it was originally based on. Recorded the round-trip topology, trigger model, schema, and version-validation-location differences in Surprises & Discoveries; logged the decision to stop reshaping the single-round-trip CTE; and updated Progress and Outcomes to redirect the next attempt toward an eventstore-style two-round-trip restructure carried into a follow-up plan.
- 2026-05-18: Appended an update to Outcomes & Retrospective recording that the round-trip topology hypothesis carried into `docs/plans/23-restructure-append-into-a-two-round-trip-path.md` was tested at the raw-SQL level and failed its own acceptance gate. The two-roundtrip variant ran 9-28 % slower than the production arrays/unnest CTE; the marginal cost of a second round-trip on this stack is ~14-22 µs (measured in plan 24), which the simpler second-round-trip statement could not recover. The candidates that remain viable are those that preserve the single round-trip: statement-level mutation triggers (most promising), removing the `streams.category` generated column, advisory-lock-based version reservation, and templated SQL per event count.
- 2026-05-18: Plan 24 confirmed `Hasql.Pool` and bare round-trip cost are not fat targets (605 ns and ~13 µs respectively). The SDK is ruled out; the next experiment should target the PostgreSQL side via the schema lever above. This sharpens but does not change this plan's "untried candidates" list.
