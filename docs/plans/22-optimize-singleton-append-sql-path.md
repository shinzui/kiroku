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
- [ ] Design a different optimization candidate before attempting another implementation.

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

## Outcomes & Retrospective

The first scalar singleton SQL implementation was not accepted. It added a `SingletonAppendParams` record, scalar Hasql encoders, four singleton append statements, and dispatch branches for `appendToStream`, `appendToStreamTx`, and `runTransactionAppending`. The code compiled and passed all semantic tests, including the full `kiroku-store` test suite, but local benchmark evidence did not show the required speedup. The implementation was reverted from the working tree, leaving this plan updated with the benchmark evidence.

The next attempt should not simply reintroduce the same scalar CTE shape. A useful next milestone would compare raw SQL variants inside the Kiroku benchmark harness before wiring them into the public append path. Candidate variants include a statement with no `new_event` CTE, a statement that avoids unused data-modifying CTE result materialization where PostgreSQL permits it, and a raw `EXPLAIN (ANALYZE, BUFFERS)` comparison against the existing array path on the same ephemeral database.

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
