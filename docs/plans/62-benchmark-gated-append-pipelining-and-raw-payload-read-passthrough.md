---
id: 62
slug: benchmark-gated-append-pipelining-and-raw-payload-read-passthrough
title: "Benchmark-gated append pipelining and raw-payload read passthrough"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Benchmark-gated append pipelining and raw-payload read passthrough

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

> **This plan is exploratory.** Milestones 1 and 2 are explicitly labelled
> prototyping milestones in the sense of the ExecPlan specification: each builds a
> benchmark-only spike (throwaway measurement code that never touches production
> modules), runs it under the established benchmark harness, and ends at a
> promote-or-discard gate with a numeric threshold stated in advance. A legitimate —
> even likely — outcome of this plan is "measured, rejected, documented with
> numbers", exactly as happened to docs/plans/22 and docs/plans/23 before it.
> Milestone 3 only happens for a prototype that passes its gate.


## Purpose / Big Picture

The Kiroku event store serializes every append in the whole database through a
single PostgreSQL row: the `streams` row with `stream_id = 0`, called the `$all`
row, whose `stream_version` column *is* the store's gap-free global event position.
Every append statement takes a row-level write lock on that row and holds it until
the surrounding transaction commits. That design is deliberate and is not changing
here — it is what makes global positions commit-ordered and gap-free. What this plan
attacks is *how long* that lock is held: today, multi-stream appends and
transactional append-plus-projection writes hold the `$all` lock across multiple
client/server network round trips, so every other writer in the store waits on
network latency that the server spends idle.

This plan prototypes and benchmark-judges two independent performance ideas raised
by the 2026-06-10 store audit (this is EP-7 of the master plan at
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`):

1. **Append pipelining (HIGH opportunity).** Use hasql's `Hasql.Pipeline` API
   (libpq pipeline mode — many statements sent in one network flush, one reply
   read) to collapse `appendMultiStream`'s `BEGIN` + pre-lock + N append statements
   + `COMMIT` sequence (roughly N+3 round trips today) into two round trips,
   shrinking the `$all` lock-hold window from "N+2 round trips" to "one server-side
   batch". Pipelining removes round trips *without changing the SQL shape*, which is
   precisely the lever the plans 21/22/23 benchmark campaign said is the only one
   that matters on this stack (see Context).

2. **Raw-payload read passthrough (MEDIUM opportunity).** Read paths decode every
   event's `data`/`metadata` columns from PostgreSQL `jsonb` into an
   `Data.Aeson.Value` (a parsed Haskell JSON syntax tree) unconditionally. Consumers
   that immediately re-serialize to JSON text — most concretely the WebSocket event
   tail in `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`, which wraps each event
   in an envelope and calls `Data.Aeson.encode` on it — pay a parse-then-render
   cycle per event for nothing. hasql 1.10 ships `Hasql.Decoders.jsonbBytes`, which
   hands back the raw JSON bytes without parsing. The prototype measures an additive
   raw-bytes `$all` read variant against the existing `Value`-decoding path.

A third, LOW-priority item rides along *conditionally*: `buildAppendParams` in
`kiroku-store/src/Kiroku/Store/Effect.hs` traverses the prepared-event list seven
times, and ships N identical `created_at` timestamps as an array where one scalar
parameter would do. This is recorded as fold-in work to do **only if** Milestone 1
promotes and those statements are already being rewritten (see Milestone 3).

Expected-impact hypothesis, as required by `docs/PERF-METHODOLOGY.md` step 3: the
plan-24 round-trip cost model (`docs/perf-experiment-log.md`, rows dated 2026-05-18
for `docs/plans/24-localize-the-hasql-round-trip-overhead.md`) measured ~13 µs for a
bare round trip and ~14–22 µs marginal cost per additional non-trivial statement
round trip on localhost. The checked-in baseline
(`kiroku-store/bench/results/baseline.csv`) has
`All.reliability-audit.appendMultiStream 3 existing streams` at ~386 µs mean, which
today spends 6 round trips (`BEGIN`, lock, 3 appends, `COMMIT`). Collapsing 6 round
trips to 2 should remove roughly 4 × 15–22 µs ≈ 60–90 µs, i.e. **a predicted 15–25 %
mean improvement at N=3, growing with N** — and the localhost numbers *understate*
the win, since every eliminated round trip on a real network saves a full network
RTT (hundreds of microseconds in-datacenter) of `$all` lock-hold time, not ~15 µs.
For the read side: `All.read.$all forward (100-event page)` sits at ~998 µs (~10 µs
per event); the Aeson decode share is unknown until the Milestone 2 profiling step
runs, which is why Milestone 2 starts by profiling before building anything.

**Sequencing constraint (soft dependencies).** Per the master plan's dependency
graph, this plan soft-depends on EP-4
(`docs/plans/59-fix-backward-read-pagination-and-append-edge-case-errors.md`) and
EP-5
(`docs/plans/60-schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes.md`).
Do not start benchmarking until both have landed on `master`: EP-4 changes append
edge-case behavior (empty batches rejected before touching the pool; single-stream
deadlock handling), and EP-5 halves the `NOTIFY` trigger traffic that fires on the
append hot path (the trigger currently fires twice-plus per append; the
perf-experiment ledger's plan-22 row records that disabling it measurably helped).
Benchmarking before they land would conflate their effects with this plan's, and a
baseline captured before EP-5 would be stale the moment it merges. Concretely: after
EP-4 and EP-5 are on `master`, recapture the baseline with `just bench-baseline`
*before* running any experiment in this plan, and note the recapture date in this
plan's Progress section. The pipelining prototype must also preserve EP-4's
empty-batch rejection (an empty `ops` list must never open a transaction).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining").

- [ ] Preflight: confirm EP-4 (docs/plans/59) and EP-5 (docs/plans/60) are merged to
      `master`; record their landing commits here.
- [ ] Preflight: recapture the benchmark baseline post-EP-4/EP-5 with
      `just bench-baseline`; commit the refreshed
      `kiroku-store/bench/results/baseline.csv` and note the date here.
- [ ] M1: re-run the Haskell-side append profile (methodology step 1) and check the
      ledger (step 2) for pipelining-adjacent rows; record findings in Surprises &
      Discoveries.
- [ ] M1: add the `pipelined-multi-append` benchmark-only spike cells to
      `kiroku-store/bench/Main.hs` (baseline N=4 cell, pipelined N=4 cell, N=8
      pair, contention-probe pair).
- [ ] M1: run the spike cells, capture CSV + transcripts under
      `docs/bench/append-hot-path/`, and decide promote vs. discard against the
      ≥20 % gate; append the ledger row in `docs/perf-experiment-log.md`.
- [ ] M2: profile the `$all` read path with the GHC profiling harness to measure the
      Aeson decode share; record the share in Surprises & Discoveries and state the
      refined expected-impact sentence here before building the spike.
- [ ] M2: add the `read-raw-shape` benchmark-only spike cells (Value vs. raw-bytes,
      100-event and 1000-event pages) to `kiroku-store/bench/Main.hs`.
- [ ] M2: run the spike cells, capture CSV + transcripts under
      `docs/bench/read-hot-path/` (new directory), decide promote vs. discard
      against the ≥15 % gate; append the ledger row.
- [ ] M3 (only if M1 promoted): rewrite the `AppendMultiStream` interpreter in
      `kiroku-store/src/Kiroku/Store/Effect.hs` onto the two-phase pipeline session;
      full test suite green; `just bench-regression` green; ledger row appended.
- [ ] M3 (only if M1 promoted): fold in the `buildAppendParams` single-pass rewrite
      and the scalar `created_at` parameter, each gated by `just bench-regression`.
- [ ] M3 (only if M2 promoted): add the additive `RecordedEventRaw` /
      `readAllForwardRaw` surface to `kiroku-store/src/Kiroku/Store/SQL.hs` and
      `kiroku-store/src/Kiroku/Store/Read.hs`; document the `decodeHook` bypass;
      record the kiroku-metrics adoption note.
- [ ] M3 (unconditional): add the loud Haddock guidance on continuation minimalism
      and `$all` lock-hold to `runTransactionAppending` and friends in
      `kiroku-store/src/Kiroku/Store/Transaction.hs`; record the decision on the
      optional pre-append continuation affordance in the Decision Log.
- [ ] Wrap-up: update the master plan's Exec-Plan Registry row for EP-7 and its
      Progress checklist; write this plan's Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Both performance ideas are quarantined behind benchmark gates with
  numeric promote-or-discard thresholds stated before any measurement (≥20 % for
  pipelining at N=4, ≥15 % for raw reads at 1000-event pages), and the spikes live
  entirely in `kiroku-store/bench/Main.hs`, never in `kiroku-store/src/`.
  Rationale: Plans 21/22/23 established that benchmark evidence, not SQL-shape
  intuition, decides append-path changes; their reverted experiments each cost a
  src-level build-out before being measured away. Benchmark-only spikes (the
  plan-23 pattern, whose `raw-append-shape` cells still live in the bench as
  durable evidence) make rejection cheap.
  Date: 2026-06-10

- Decision: The pipelining prototype uses a **two-phase** shape — one pipeline sync
  carrying `BEGIN` + pre-lock + N appends, then a second ordinary round trip
  carrying `COMMIT` or `ROLLBACK` chosen after inspecting the N append results —
  rather than pipelining `COMMIT` into the same sync.
  Rationale: Kiroku append preconditions fail *silently*: a version conflict or
  soft-deleted stream makes the append CTE return zero rows (decoded to `Nothing`),
  not a SQL error. libpq pipeline aborts only propagate from SQL *errors*; a queued
  `COMMIT` after a zero-row append would commit a partial multi-stream append,
  breaking the all-or-nothing contract that `Tx.condemn` enforces today. Two phases
  keep the contract and still collapse N+3 round trips to 2. See "How hasql
  pipelining works" in Context for the full reasoning.
  Date: 2026-06-10

- Decision: This plan must not add a stream-name field (or any per-row denormalized
  column) to `RecordedEvent` or to the raw read variant.
  Rationale: `docs/plans/36-add-originalstreamname-to-recordedevent.md` measured
  returning a stream name on every read row at ~13 % on `$all` reads regardless of
  join-vs-column approach, and the field was rejected; `lookupStreamNames` is the
  supported path. The raw-payload variant changes column *decoding*, never the
  column *set*.
  Date: 2026-06-10

- Decision: Benchmark only after EP-4 (docs/plans/59) and EP-5 (docs/plans/60) land,
  and recapture `baseline.csv` before the first experiment.
  Rationale: EP-4 changes append edge-case behavior and EP-5 halves NOTIFY trigger
  firing on the append path; measuring against a pre-EP-5 baseline would attribute
  their wins/losses to this plan. Master plan dependency graph records the same
  soft dependency.
  Date: 2026-06-10

- Decision: The `buildAppendParams` micro-costs (seven list traversals; N identical
  `created_at` array elements) are conditional fold-in work under Milestone 3, not
  a standalone milestone.
  Rationale: They only pay for themselves if the append statements are already
  being touched by a promoted pipelining change, and the ledger's plan-21
  "event-count as bind parameter" row is a direct warning that encoder/parameter
  micro-changes in this region have measured *slower* before. Standalone, they
  cannot clear the methodology's profile-first bar (the checked-in profile shows
  encoding is a small share of append time).
  Date: 2026-06-10

- Decision: The raw-bytes prototype targets the `$all` forward read
  (`readAllForwardStmt`) only, with the kiroku-metrics WebSocket event tail named
  as the adopting consumer; per-stream and category raw variants are out of scope.
  Rationale: The WS tail is the one in-repo consumer that demonstrably
  re-serializes every event verbatim (`recordedEventToJSON` then `Aeson.encode` in
  `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`); `$all` forward is both its
  replay path and the store's hottest read. A promoted API with no adopting
  consumer would be dead weight.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. If a prototype is discarded, record
the numbers that killed it here (and in the ledger) so it is never re-proposed
without new evidence.

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained: everything a newcomer needs to understand the two
experiments, in plain language, with full paths. Read it before touching anything.

### The store, in one paragraph

Kiroku is a PostgreSQL-backed event store. Events are appended to named *streams*
(`streams` table; one row per stream, `stream_version` counts its events) and every
event is also linked into a global pseudo-stream called `$all`, which is physically
the `streams` row with `stream_id = 0`. That row's `stream_version` is the *global
position* counter: each append `UPDATE`s it by the batch size and uses the returned
value to number the new events globally. Because an `UPDATE` takes a PostgreSQL
row-level write lock held until the transaction commits, appends serialize on that
row — which is exactly what makes global positions gap-free and commit-ordered. The
audit re-confirmed this design is sound and it is **not** to be changed; the cost is
that the `$all` row lock is the store's global write-throughput ceiling, so every
microsecond it is held matters.

### The append path and where round trips happen

A *round trip* is one client-to-server-and-back network exchange. On hasql (the
PostgreSQL driver this project uses), each `Session.statement` call is one round
trip; `docs/plans/24-localize-the-hasql-round-trip-overhead.md` measured the floor
at ~13 µs on localhost (`SELECT 1`) with ~14–22 µs marginal cost per additional
statement.

Single-stream appends (`appendToStream`) run as **one** round trip: one big SQL
statement built from CTEs. A *CTE* (common table expression, the `WITH name AS
(...)` SQL form) chains several inserts/updates into one statement. The four append
statements (one per `ExpectedVersion` variant) live in
`kiroku-store/src/Kiroku/Store/SQL.hs` (`appendAnyVersionSQL` at ~line 318,
`appendNoStreamSQL` at ~line 264, plus the exact-version and stream-exists
variants). Each takes seven parallel arrays (`$1::uuid[]` event ids, `$2::text[]`
types, `$3`/`$4::uuid[]` causation/correlation, `$5`/`$6::jsonb[]` payload/metadata,
`$7::timestamptz[]` created-at) plus the stream name `$8`, `unnest`s them into rows,
upserts the stream row, inserts the events, and — the part that matters here —
updates the `$all` row (`all_update` CTE: `UPDATE streams SET stream_version =
stream_version + count WHERE stream_id = 0`) and links the events into `$all`
(`all_links` CTE). The statement returns one row, decoded to `Maybe AppendResult`; a
failed precondition (version conflict, soft-deleted stream) returns **zero rows —
not a SQL error**. Keep that fact in mind; it drives the pipeline design below.

Two paths hold the `$all` lock across *multiple* round trips today:

1. **`appendMultiStream`** (effect constructor `AppendMultiStream`, interpreter at
   `kiroku-store/src/Kiroku/Store/Effect.hs` lines ~201–249). It wraps the work in
   `hasql-transaction`'s `TxSessions.transaction TxSessions.ReadCommitted
   TxSessions.Write`, which issues `BEGIN`, then runs one
   `SQL.lockStreamsForMultiStmt` statement (a `SELECT ... ORDER BY stream_id FOR
   UPDATE` pre-lock defined at `kiroku-store/src/Kiroku/Store/SQL.hs` lines
   ~999–1009, which deterministically orders the user-stream locks to prevent
   deadlocks; `$all` is intentionally *not* in the pre-lock — each append CTE takes
   it after its source-stream lock), then runs N append statements via
   `appendDispatchTx` (`Effect.hs` lines ~430–439), then — if any result was
   `Nothing` — calls `Tx.condemn` (which makes hasql-transaction issue `ROLLBACK`
   instead of `COMMIT`), then `COMMIT`/`ROLLBACK`. Total: **N+3 round trips**, and
   the `$all` lock is held from the *first* append statement's `all_update` until
   the final commit — i.e. across N+2 round trips of pure network latency during
   which every other append in the entire store is blocked.

2. **`runTransactionAppending` / `runTransactionAppendingWith`**
   (`kiroku-store/src/Kiroku/Store/Transaction.hs`, the shared worker at lines
   ~300–320). This is the recommended append-plus-projection API (used by the keiro
   projection layer): inside one transaction it appends to a stream and then runs
   the *caller's* continuation — an arbitrary `Tx.Transaction` of projection
   inserts/updates, each its own round trip — before `COMMIT`. The continuation runs
   *after* the append, so the `$all` lock is held across every continuation round
   trip plus the commit. A caller with a three-statement continuation holds the
   global append lock across five round trips. Nothing warns callers about this
   today; Milestone 3 adds that warning (and evaluates, without committing to, an
   affordance for running continuation work *before* the append so the `$all` lock
   is taken last — note the constraint that the continuation receives the
   `AppendResult`, so only continuation work that does not need the new positions
   can be hoisted).

Established constraints from the prior benchmark campaign, all recorded in
`docs/perf-experiment-log.md` and re-affirmed by the master plan: a purpose-built
singleton (non-array) SQL shape was measured at parity-or-worse and reverted
(plan 22); restructuring append into two round trips was measured 4–28 % *slower*
and killed (plan 23); the driver layers are not the bottleneck (plan 24: pool
acquire ~605 ns, bare round trip ~13 µs). The standing conclusion: **round-trip
count dominates SQL shape on this stack.** Pipelining is the one untried lever that
*reduces* round trips without changing SQL shape — it aligns with the campaign's
conclusion instead of fighting it, but it must prove itself under the same harness
and methodology that killed its predecessors.

### How hasql pipelining works (verified against the pinned source)

kiroku-store pins `hasql >=1.10 && <1.11` (see `kiroku-store/kiroku-store.cabal`);
the source for the locally registered 1.10.3 lives at
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql` (found via `mori registry
show hasql/hasql --full`; do not go hunting in `/nix/store`). What the source says,
in plain language:

- `Hasql.Pipeline` exports an abstract type `Pipeline a` and one constructor
  function, `statement :: params -> Statement params result -> Pipeline result` —
  the same `Statement` values used everywhere else in this codebase work unchanged,
  prepared-statement caching included.
- `Pipeline` is **`Applicative` only, deliberately not `Monad`**: a later
  statement's *parameters* cannot depend on an earlier statement's *result*,
  because all statements are sent before any result is read. That is fine for
  `appendMultiStream`: the pre-lock takes the stream-name vector and each append
  takes its own pre-built `AppendParams`; there are no value dependencies between
  the statements. Results compose applicatively, e.g.
  `traverse` over a list of per-stream pipelines yields `Pipeline [Maybe
  AppendResult]`.
- A pipeline executes via `Hasql.Session.pipeline :: Pipeline a -> Session a`, so
  it slots into the existing `Pool.use (store ^. #pool) $ ...` pattern. Under the
  hood (`Hasql/Engine/Contexts/Pipeline.hs`) it uses libpq's *pipeline mode*: all
  queued statements are flushed to the server followed by one *sync point* (a
  protocol marker that ends the batch), then all results are read. The module's
  own documentation states that if the sent and received data fit the driver and
  server buffers (typically 8 KB), the whole pipeline is **a single network round
  trip**. Large event payloads can exceed 8 KB and degrade to streaming writes —
  still one *latency* exchange, but worth noting when interpreting numbers.
- Pipeline mode uses the extended query protocol only. hasql's `Session.script`
  (simple protocol) cannot appear inside a pipeline, so `BEGIN` must be issued as
  an ordinary `Statement () ()` — SQL `"BEGIN ISOLATION LEVEL READ COMMITTED"` (or
  plain `BEGIN`; the store's default isolation is ReadCommitted anyway) with
  `Hasql.Encoders.noParams`, `Hasql.Decoders.noResult`, non-preparable. This is
  exactly what `hasql-transaction` does internally; the spike just does it
  explicitly because **`hasql-transaction`'s `Tx.Transaction` has no pipeline
  support** (verified: no pipeline references anywhere in
  `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-transaction/src`). The
  spike therefore bypasses `Tx.Transaction` and works in raw `Session`, the same
  thing the plan-23 spike did.
- **Error semantics**: if a statement in the pipeline raises a SQL error, the
  server aborts every subsequent statement up to the sync point (libpq reports
  `PGRES_PIPELINE_ABORTED`); hasql surfaces the first failure as the session's
  `Left SessionError` and the connection recovers at the sync point. So a *SQL
  error* mid-pipeline is safe even with a queued `COMMIT` — the `COMMIT` is
  aborted and the transaction rolls back. The trap is that Kiroku append
  preconditions are **not** SQL errors: they are zero-row results decoded to
  `Nothing`. A queued `COMMIT` after a zero-row append *executes normally* and
  would commit the partial batch. Today `Tx.condemn` prevents that. Hence the
  two-phase prototype shape (see Decision Log): **pipeline #1** = `BEGIN` +
  pre-lock + N appends, one sync, one round trip; client inspects the N
  `Maybe AppendResult`s; **round trip #2** = `COMMIT` if all `Just`, else
  `ROLLBACK`. N+3 round trips become 2, and the `$all` lock-hold window shrinks
  from N+2 round trips to roughly one round trip (the lock is taken inside the
  batch and held only until the commit exchange).

### The read path and the raw-bytes idea

`readAllForward` (effect constructor `ReadAllForward`, interpreter at
`kiroku-store/src/Kiroku/Store/Effect.hs` lines ~164–168) executes
`SQL.readAllForwardStmt` (`kiroku-store/src/Kiroku/Store/SQL.hs` lines ~431–436 over
`readAllForwardSQL` at ~507–521: a `stream_events`-to-`events` join on
`stream_id = 0`). Rows decode through the shared 11-column `recordedEventRow`
decoder (`SQL.hs` lines ~374–387), whose `data` and `metadata` columns use
`Hasql.Decoders.jsonb` — i.e. every payload byte is parsed into a
`Data.Aeson.Value` heap structure whether or not the consumer wants structure. After
decoding, the interpreter applies the store's optional `decodeHook`
(`Kiroku.Store.Settings.decodeEvents`), a user-supplied `RecordedEvent -> IO
RecordedEvent` rewrite used for things like payload decryption.

The pinned hasql provides the exact passthrough decoder needed (verified at
`/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql/src/library/Hasql/Codecs/Decoders/Value.hs`
line 269, re-exported from `Hasql.Decoders`):

```haskell
jsonbBytes :: (ByteString -> Either Text a) -> Value a
```

so `D.jsonbBytes Right` yields the raw JSON bytes (hasql strips the one-byte jsonb
binary-format version header itself). A matching `jsonbBytes` *encoder* also exists
should round-tripping ever be wanted. The prototype is an alternate row type —
call it `RecordedEventRaw`, identical to `RecordedEvent` except `payload ::
ByteString` and `metadata :: Maybe ByteString` — plus a `readAllForwardRaw`
statement reusing the *same SQL text* (`readAllForwardSQL`; only the decoder
changes, so the server-side cost is identical by construction and any delta is pure
client-side decode).

Three hard constraints on this work, stated up front:

- **No new columns, no stream name.** `RecordedEvent` deliberately has no
  stream-name field; `docs/plans/36-add-originalstreamname-to-recordedevent.md`
  measured that returning one costs ~13 % on `$all` reads and rejected it. The raw
  variant mirrors the existing column set exactly.
- **The typed API is untouched.** `readAllForward`, `RecordedEvent`, and every
  existing decoder stay as they are; the raw surface is additive and clearly
  marked as a hot-path specialization.
- **The raw path bypasses `decodeHook`.** A store configured with a decode hook
  (e.g. payload decryption) would hand consumers raw *stored* bytes. If promoted,
  the Haddock must say so loudly, and the natural adopter must check: the
  kiroku-metrics WS tail at `kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`
  (`recordedEventToJSON` ~line 170, `sendEvents` ~line 449) builds a JSON envelope
  *around* the payload, so adopting raw bytes there means splicing bytes into the
  envelope with a `ByteString` builder instead of `Aeson.encode` over a `Value` —
  an `Aeson.Value` cannot hold pre-rendered bytes. That adoption cost is part of
  the promote/reject judgement, not an afterthought.

### The benchmark infrastructure you will reuse

All measurement uses the established harness; do not invent a new one.

- **The bench target**: `kiroku-store/bench/Main.hs`, cabal benchmark
  `kiroku-store:kiroku-store-bench` (a `tasty-bench` suite). It boots its own
  throwaway PostgreSQL via `ephemeral-pg` — no external database needed — and its
  unconditional pre-`defaultMain` setup (100 K category events, a pool-saturation
  pass) costs ~10 s per run. Existing groups relevant here: `append.*`,
  `raw-append-shape.*` (the durable plan-22/23 spike cells — the pattern this
  plan's spikes copy), `read.*` (`$all forward (100-event page)` at ~998 µs in the
  baseline), and `reliability-audit.appendMultiStream 3 existing streams` (~386 µs
  in the baseline; three pre-created streams `bench-multi-a/b/c`, one event each,
  `AnyVersion`).
- **Focused runs with CSV** (the plan-21/22/23 convention), run from the repo
  root:

  ```bash
  cabal bench kiroku-store:kiroku-store-bench \
    --benchmark-options="-p <pattern> --csv /tmp/<name>.csv"
  ```

- **Baseline and regression gate** (`Justfile`): `just bench-baseline` rewrites
  `kiroku-store/bench/results/baseline.csv` from a full run; `just
  bench-regression` re-runs everything against that baseline and fails if any cell
  is >10 % slower; `just bench-regression-pattern PATTERN` scopes it.
- **Haskell-side profiling harness** (methodology step 1; from
  `docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`, reproduction
  recipe in `docs/PERF-METHODOLOGY.md`):

  ```bash
  cabal build --enable-profiling kiroku-store:kiroku-store-bench
  BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
  rm -f kiroku-store-bench.prof
  "$BENCH" +RTS -p -RTS --pattern '$0 == "<full cell name>"' --stdev 100
  ```

  (No `--` between `-RTS` and the bench's arguments; cell names carry the implicit
  `All.` prefix. The first profiled build recompiles ~50 dependencies.) The
  reference append profile is checked in at
  `docs/bench/append-hot-path/single-event-anyversion.prof`; a stale working copy
  `kiroku-store-bench.prof` sits at the repo root from a previous run.
- **PostgreSQL-side profiling harness** (`docs/plans/26-...md`): `cabal bench
  kiroku-store-bench-explain` — only needed here if a result is surprising enough
  to demand server-side attribution, since neither experiment changes SQL text.
- **Evidence homes**: numeric ledger rows are appended (never edited) to
  `docs/perf-experiment-log.md` following its header schema; run transcripts and
  CSVs go under `docs/bench/append-hot-path/` with `YYYY-MM-DD-<experiment>-`
  prefixes (Milestone 2 creates a sibling `docs/bench/read-hot-path/` for read
  artefacts); the methodology contract itself is `docs/PERF-METHODOLOGY.md` —
  follow its four steps (profile first, check the ledger, state expected impact,
  re-profile/measure after) for each milestone.


## Plan of Work

The work is three milestones. Milestones 1 and 2 are independent prototyping
milestones (either can run first; both end at a numeric gate). Milestone 3 is
conditional integration plus one unconditional documentation deliverable. Nothing in
Milestones 1–2 touches `kiroku-store/src/`; everything they add lives in
`kiroku-store/bench/Main.hs` and `docs/`.

### Milestone 1 — Pipelined multi-stream append spike (prototype; promote-or-discard gate)

*Scope.* Prove or disprove, with benchmark-only code, that hasql pipelining
materially improves multi-stream append throughput and shrinks `$all` lock-hold.
At the end of this milestone there exists a new `pipelined-multi-append` bench
group in `kiroku-store/bench/Main.hs`, captured CSVs/transcripts under
`docs/bench/append-hot-path/`, a ledger row, and a recorded promote/discard
decision. No production code changes.

*Preflight (methodology steps 1–2).* Re-run the Haskell-side profiling harness on
`All.reliability-audit.appendMultiStream 3 existing streams` to confirm where
multi-stream append time goes today (expect: dominated by round-trip wait, per the
plan-24 model). Re-read every `docs/perf-experiment-log.md` row touching round-trip
topology (the plan-23 and plan-24 rows). This plan's justification for re-entering
round-trip territory after plan 23's rejection — required by methodology step 2 —
is: plan 23 *added* a round trip to simplify SQL and lost; pipelining *removes*
round trips while keeping SQL identical, which is the mechanism plan 23's lesson
("round-trip count, not SQL shape, dominates") actually predicts will win.

*Build the spike.* In `kiroku-store/bench/Main.hs`, following the local conventions
of the existing `raw-append-shape` spike helpers (local param records, helpers named
`runRaw...`, `forceX` result-forcing functions that `error` on failure):

1. Pre-create four bench streams (`bench-pipe-a` … `bench-pipe-d`) in the setup
   block next to the existing `bench-multi-*` pre-creation, and four more for the
   N=8 cells.
2. Add a *baseline* helper that reproduces the production interpreter shape in raw
   `Session` form — `TxSessions.transaction` wrapping `Tx.statement names
   SQL.lockStreamsForMultiStmt` followed by four `appendDispatchTx`-equivalent
   `Tx.statement` calls — or simply call the public `appendMultiStream` with four
   ops, mirroring `runAppendMultiStream`. Use the public API: it measures what
   users get, and the existing 3-stream cell stays comparable. Reuse
   `Kiroku.Store.SQL` (exposed) and `buildAppendParams` (exported from
   `Kiroku.Store.Effect`) where helpful.
3. Add the *pipelined* helper: on `Pool.use (store ^. #pool)`, phase 1 is
   `Session.pipeline` over `(,) <$> beginStmt <*> ...` — concretely a local
   `beginStmt :: Statement () ()` (`"BEGIN"`, `noParams`, `noResult`,
   non-preparable), `Hasql.Pipeline.statement names SQL.lockStreamsForMultiStmt`,
   and `traverse` of `Hasql.Pipeline.statement params <appendStatement>` over the
   four pre-built `AppendParams` (all `AnyVersion`, matching the baseline cell);
   phase 2 inspects the `[Maybe AppendResult]` and runs `Session.statement` on a
   local `commitStmt` or `rollbackStmt`. Force the results like `forceAppendList`.
4. Add four throughput cells under a new `bgroup "pipelined-multi-append"`:
   `"current shape (4 streams)"`, `"pipelined (4 streams)"`, `"current shape (8
   streams)"`, `"pipelined (8 streams)"`.
5. Add the **contention probe** (the lock-hold measurement, since lock-hold time
   is not directly observable from tasty-bench): two cells, `"single-stream append
   under 4 multi-stream writers (current)"` and `"... (pipelined)"`. Each cell
   starts 4 background `async` threads looping the respective 4-stream
   multi-append against their own stream quartets, measures 10 sequential
   `appendToStream` calls to a fresh stream (the measured body), then cancels the
   writers. The single-stream appender must wait on the `$all` lock behind the
   multi-stream writers, so its latency is a direct proxy for how long they hold
   it. Follow the `runConcurrentWriters` cell for the async/counter pattern.

*Measure.* From the repo root, three runs of the focused group, CSV per run:

```bash
cabal bench kiroku-store:kiroku-store-bench \
  --benchmark-options="-p pipelined-multi-append --csv /tmp/kiroku-pipeline-62-runN.csv"
```

plus one run of the untouched neighbors to confirm no harness disturbance:

```bash
cabal bench kiroku-store:kiroku-store-bench \
  --benchmark-options="-p reliability-audit"
```

Copy transcripts and CSVs to
`docs/bench/append-hot-path/2026-MM-DD-pipelined-multi-append-*.{txt,csv}`.

*Numbers to capture*: mean and 2·stdev for all six new cells across the three runs;
the existing `appendMultiStream 3 existing streams` cell for continuity; the
percentage delta pipelined-vs-current at N=4 and N=8; the contention-probe delta.

*Gate (promote criteria, fixed in advance).* Promote to Milestone 3 iff **the
pipelined 4-stream cell's mean is ≥20 % below the current-shape 4-stream cell's
mean, consistently across the three runs (the means' 2·stdev intervals must not
overlap)**, and the contention probe moves in the same direction (single-stream
latency under multi-stream load improves; treat <5 % there as "no regression"
rather than requiring a win, since the probe is noisy). If the gate fails, discard:
keep the bench cells as durable evidence (the plan-23 precedent), append the ledger
row with outcome `not-implemented`, and write the numbers into this plan's
Outcomes & Retrospective.

*Acceptance.* The bench group runs green; three CSVs and transcripts are checked in
under `docs/bench/append-hot-path/`; `docs/perf-experiment-log.md` has a new row
citing this plan's path with verbatim numbers; the Progress checklist and Decision
Log here record the verdict.

### Milestone 2 — Raw-bytes `$all` read spike (prototype; promote-or-discard gate)

*Scope.* Quantify what skipping Aeson decoding is worth on the `$all` read path.
At the end there exists a `read-raw-shape` bench group, artefacts under a new
`docs/bench/read-hot-path/`, a ledger row, and a verdict. No production code
changes.

*Preflight — profile first (methodology steps 1–3).* The append profile says
nothing about reads, so this milestone must generate its own evidence before
building: run the profiling harness on the read cell —

```bash
cabal build --enable-profiling kiroku-store:kiroku-store-bench
BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
rm -f kiroku-store-bench.prof
"$BENCH" +RTS -p -RTS \
  --pattern '$0 == "All.read.$all forward (100-event page)"' --stdev 100
```

— and read the `.prof` cost-centre rows to find the share attributable to jsonb
value decoding (look for hasql decoder and aeson cost centres versus
session/round-trip wait). Record the share in Surprises & Discoveries and write the
required expected-impact sentence into this plan's Progress entry before building
the spike, in the methodology's form: "the profile shows payload decoding is N % of
`$all` read time; raw passthrough should remove most of it, predicting roughly an
N·0.8 % improvement." If the profile shows decoding is a trivial share (say <10 %),
stop here, record the discovery, and reject experiment B without building the spike
— that outcome is cheaper and equally valid.

*Build the spike.* In `kiroku-store/bench/Main.hs`, local to the bench:

1. A local row record `RawEventRow` mirroring `RecordedEvent`'s 11 columns but
   with `payload :: ByteString` / `metadata :: Maybe ByteString`, and a local
   decoder `rawEventRow :: D.Row RawEventRow` that copies the 11-column shape of
   `recordedEventRow` (`kiroku-store/src/Kiroku/Store/SQL.hs` lines ~374–387 —
   the row decoder, encoders, and SQL texts are *not* exported from
   `Kiroku.Store.SQL`, only the assembled `Stmt` values are, so the spike
   re-declares them locally; the plan-22/23 spikes did the same) with the two
   `D.jsonb` columns swapped for `D.jsonbBytes Right` (import `Data.ByteString`
   and use the `D.column (D.nonNullable (D.jsonbBytes Right))` /
   `D.nullable` forms).
2. A local statement `rawReadAllForwardStmt :: Statement (Int64, Int32) (Vector
   RawEventRow)` built with `preparable <sql> readAllEncoderLocal (D.rowVector
   rawEventRow)`, where `<sql>` is a verbatim local copy of `readAllForwardSQL`
   (`kiroku-store/src/Kiroku/Store/SQL.hs` lines ~507–521) and
   `readAllEncoderLocal` re-declares the two-column `contrazip2` int8/int4
   encoder. Add a comment naming the source lines so drift is auditable.
3. Bench cells under `bgroup "read-raw-shape"`, each forcing the full vector
   (deepseq the payload bytes / Values — an unforced vector would measure nothing):
   `"Value decode (100-event page)"`, `"raw bytes (100-event page)"`,
   `"Value decode (1000-event page)"`, `"raw bytes (1000-event page)"`. The Value
   cells run the same local statement shape but with a local copy of the
   11-column `Value`-decoding row, so both sides bypass the effect interpreter and
   `decodeHook` symmetrically and the *only* difference is the payload decoder. The setup block already inserts 100 K
   events, so 1000-event pages have data; read from position 0.

*Measure.* Three runs from the repo root:

```bash
cabal bench kiroku-store:kiroku-store-bench \
  --benchmark-options="-p read-raw-shape --csv /tmp/kiroku-read-raw-62-runN.csv"
```

Create `docs/bench/read-hot-path/` and copy transcripts/CSVs there as
`2026-MM-DD-read-raw-shape-*.{txt,csv}`. Capture: means and 2·stdev for all four
cells per run; deltas at both page sizes; the pre-spike profile's decode share next
to the observed delta (the falsifiable check).

*Gate (promote criteria, fixed in advance).* Promote iff **the raw-bytes
1000-event-page mean is ≥15 % below the Value 1000-event-page mean across the three
runs (non-overlapping 2·stdev)** *and* the adoption story holds: the kiroku-metrics
WS tail (`kiroku-metrics/src/Kiroku/Metrics/WebSocket.hs`) can consume raw bytes by
building its envelope with a `ByteString` builder — sketch the envelope change in
prose in this plan (do not implement it here) and confirm no consumer-visible JSON
change. Otherwise discard: keep the cells, ledger row with outcome
`not-implemented`, numbers in Outcomes & Retrospective.

*Acceptance.* Bench group green; artefacts in `docs/bench/read-hot-path/`; ledger
row appended; verdict recorded here.

### Milestone 3 — Conditional promotion and the lock-hold documentation (integration)

*Scope.* Integrate whatever passed its gate, fold in the conditional micro-work,
and land the unconditional documentation improvements. Every sub-item below states
its condition.

*(M3a — only if M1 promoted) Production pipelined `AppendMultiStream`.* Rewrite the
`AppendMultiStream` interpreter branch in `kiroku-store/src/Kiroku/Store/Effect.hs`
(lines ~201–249) from `TxSessions.transaction` onto the two-phase pipeline session
validated by the spike, inside a single `Pool.use` so both phases share one
connection. Preserve, exactly: the reserved-`$all`-stream rejection; EP-4's
empty-batch rejection (no transaction may open for an empty ops list); event
enrichment and preparation outside the transaction; the deterministic pre-lock as
the first pipelined statement after `BEGIN`; all-or-nothing semantics (`ROLLBACK`
on any `Nothing`); and the existing error mapping (`attributeMultiStreamError`,
`emptyResultError`). Mind the failure paths the spike could ignore: if phase 1
returns `Left` (SQL error — pipeline aborted at the sync point, transaction left
aborted on the connection), issue a best-effort `ROLLBACK` before releasing the
connection so the pool never returns a connection stuck in a failed transaction;
hasql-transaction did this housekeeping for us before. Define `BEGIN` / `COMMIT` /
`ROLLBACK` as module-local non-preparable statements. Add/extend tests in
`kiroku-store`'s test suite covering: happy-path multi-append (positions gap-free
and commit-ordered across two streams), conflict on the second of three streams
rolls back all three, empty list rejected, reserved stream rejected, and the
post-rollback connection is reusable. Then run the full gates: the store test
suite, `just bench-regression` (the existing 3-stream cell must improve, nothing
else may regress >10 %), and append a `kept` ledger row with before/after numbers.
Re-run the M1 profile (methodology step 4) and record predicted-vs-observed.

*(M3b — only if M1 promoted; fold-in-only) Append param micro-costs.* While the
append statements are already on the operating table: rebuild `buildAppendParams`
(`kiroku-store/src/Kiroku/Store/Effect.hs` lines ~403–414) as a single pass that
constructs the seven vectors in one traversal of `prepared` (e.g. build a
`Vector PreparedEvent` once with `V.fromList`, then seven cheap `V.map`s over it,
or one explicit fold into seven accumulators — measure, don't guess); and replace
the `createdAts = V.fromList (replicate n now)` array with a single scalar
`timestamptz` parameter, which requires editing all four append CTE texts in
`kiroku-store/src/Kiroku/Store/SQL.hs` to drop `$7::timestamptz[]` from the
`unnest` and select the scalar `created_at` parameter as a constant column (the
parameter numbering shifts: stream name becomes `$8`'s neighbor — renumber
carefully in all four statements and `appendParamsEncoder`). Each of the two
changes lands as its own commit gated by `just bench-regression`; the ledger's
plan-21 row ("event-count as bind parameter" measured *slower*) is the explicit
warning that these may individually fail their gate, in which case revert that
commit and record the numbers. If M1 was discarded, do none of this — record the
items as rejected-by-condition in the Decision Log.

*(M3c — only if M2 promoted) Additive raw read surface.* In
`kiroku-store/src/Kiroku/Store/SQL.hs`: a `RecordedEventRaw` record (same 11 fields
as `RecordedEvent`; `payload :: ByteString`, `metadata :: Maybe ByteString`), a
`recordedEventRawRow :: D.Row RecordedEventRaw`, and `readAllForwardRawStmt ::
Statement (Int64, Int32) (Vector RecordedEventRaw)` sharing `readAllForwardSQL`.
In `kiroku-store/src/Kiroku/Store/Read.hs` (and the `Store` effect in `Effect.hs`,
following how `ReadAllForward` is wired): `readAllForwardRaw :: GlobalPosition ->
Int32 -> Eff es (Vector RecordedEventRaw)`. The interpreter must *not* apply
`decodeEvents` (it cannot — the hook's type is `RecordedEvent -> IO
RecordedEvent`), and the Haddock on the type, the statement, and the combinator
must each state: bytes are the stored representation; `decodeHook` (decryption
etc.) is bypassed; no stream-name field exists by design (cite
`docs/plans/36-add-originalstreamname-to-recordedevent.md`); intended consumer is
relay-style code that re-emits JSON verbatim, e.g. the kiroku-metrics WS tail.
Tests: raw and typed reads over the same seeded events agree on every non-payload
field, and the raw payload bytes parse (via `Aeson.decodeStrict`) to exactly the
typed `Value`. Actually adopting it in `kiroku-metrics` is recorded as a follow-up
in the Outcomes section, not done here — this plan's deliverable is the measured,
documented store API.

*(M3d — unconditional) Lock-hold documentation.* Regardless of both gates: in
`kiroku-store/src/Kiroku/Store/Transaction.hs`, add a prominent Haddock section to
`runTransactionAppending`, `runTransactionAppendingNoRetry`, both `-Resource`
variants, and `appendToStreamTx`, stating in plain language: the append takes the
global `$all` row lock; every statement the continuation runs afterwards extends
the window during which **all other appends store-wide are blocked**; therefore
continuations must be minimal and pre-computed (no per-row work that could be done
before the transaction, no unbounded loops, never any external I/O — which
`Tx.Transaction` cannot express anyway, but say it); and continuation work that
does not need the `AppendResult` should be structured to run *before* the append.
Evaluate (Decision-Log it either way) the optional API affordance: a variant such
as `runTransactionAppendingAfter :: ... -> Tx.Transaction b -> (b -> AppendResult
-> Tx.Transaction a) -> ...` whose first continuation runs before the append (so
the `$all` lock is taken last) and whose second receives the result. The default
disposition is *documentation only* — add the combinator only if a concrete keiro
call site would use it today; otherwise record "guidance only, affordance
deferred" with rationale.

*(M3e — unconditional) Bookkeeping.* Update the EP-7 row and the two EP-7 Progress
items in
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`
with the verdicts; write this plan's Outcomes & Retrospective comparing predicted
vs. observed for both experiments; if anything was promoted, add CHANGELOG entries
in `kiroku-store` following the repository's conventional-commit and changelog
habits.

*Acceptance for Milestone 3 as a whole.* Everything conditional that ran is gated
by tests plus `just bench-regression`; everything discarded has a ledger row and
numbers in Outcomes; the Haddock guidance renders (build the docs or at minimum
`cabal build kiroku-store` with `-haddock` in scope per project habit); the master
plan reflects reality.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`) unless stated otherwise.
This section repeats the exact command lines so a contributor can execute without
re-deriving them; update it as work proceeds.

1. **Preflight.**

   ```bash
   git log --oneline master -- docs/plans/59* docs/plans/60*   # confirm EP-4/EP-5 landed
   just bench-baseline                                          # recapture post-EP-4/EP-5 baseline
   git add kiroku-store/bench/results/baseline.csv && git commit -m "chore(bench): recapture baseline after EP-4/EP-5"
   ```

   Expected: `bench-baseline` prints `Baseline written to
   kiroku-store/bench/results/baseline.csv` after a full suite run (several
   minutes; ~10 s of it is the fixed setup).

2. **M1 profile + ledger check.**

   ```bash
   cabal build --enable-profiling kiroku-store:kiroku-store-bench
   BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
   rm -f kiroku-store-bench.prof
   "$BENCH" +RTS -p -RTS \
     --pattern '$0 == "All.reliability-audit.appendMultiStream 3 existing streams"' --stdev 100
   ```

   Read `kiroku-store-bench.prof`; re-read the plan-23/24 rows in
   `docs/perf-experiment-log.md`.

3. **M1 spike.** Edit `kiroku-store/bench/Main.hs` per Milestone 1. Build check:

   ```bash
   cabal build kiroku-store:kiroku-store-bench
   ```

4. **M1 measurement** (three runs, increment `run1`):

   ```bash
   cabal bench kiroku-store:kiroku-store-bench \
     --benchmark-options="-p pipelined-multi-append --csv /tmp/kiroku-pipeline-62-run1.csv" \
     | tee /tmp/kiroku-pipeline-62-run1.txt
   mkdir -p docs/bench/append-hot-path
   cp /tmp/kiroku-pipeline-62-run1.csv \
      docs/bench/append-hot-path/$(date +%F)-pipelined-multi-append-run1.csv
   cp /tmp/kiroku-pipeline-62-run1.txt \
      docs/bench/append-hot-path/$(date +%F)-pipelined-multi-append-run1.txt
   ```

   Expected transcript shape (numbers illustrative only — record real ones):

   ```text
   All.pipelined-multi-append.current shape (4 streams):  OK
     470 μs ± 40 μs
   All.pipelined-multi-append.pipelined (4 streams):      OK
     3XX μs ± XX μs
   ```

5. **M1 verdict.** Compute deltas; apply the ≥20 % gate; append the ledger row to
   `docs/perf-experiment-log.md`; update Progress/Decision Log/Outcomes here;
   commit (conventional commits, e.g.
   `feat(kiroku-store): benchmark pipelined multi-stream append spike` or
   `docs(perf): record pipelining rejection` as appropriate).

6. **M2 profile gate.** Run the read-cell profile (command in Milestone 2); record
   the decode share; if <10 %, skip to step 9 recording rejection-by-profile.

7. **M2 spike + measurement** (three runs):

   ```bash
   cabal bench kiroku-store:kiroku-store-bench \
     --benchmark-options="-p read-raw-shape --csv /tmp/kiroku-read-raw-62-run1.csv" \
     | tee /tmp/kiroku-read-raw-62-run1.txt
   mkdir -p docs/bench/read-hot-path
   cp /tmp/kiroku-read-raw-62-run1.csv \
      docs/bench/read-hot-path/$(date +%F)-read-raw-shape-run1.csv
   cp /tmp/kiroku-read-raw-62-run1.txt \
      docs/bench/read-hot-path/$(date +%F)-read-raw-shape-run1.txt
   ```

8. **M2 verdict.** Apply the ≥15 % gate plus the adoption check; ledger row;
   update this plan; commit.

9. **M3 conditional integration.** For each promoted item, implement per
   Milestone 3, then:

   ```bash
   cabal build all
   cabal test kiroku-store:kiroku-store-test     # expect all examples pass, 0 failures
   just bench-regression                          # expect: no cell >10% slower
   ```

   For M3a additionally re-run step 2's profile and diff predicted vs. observed.

10. **M3d/M3e always.** Edit `kiroku-store/src/Kiroku/Store/Transaction.hs`
    Haddocks; `cabal build kiroku-store`; update the master plan registry; write
    Outcomes & Retrospective; final commits.


## Validation and Acceptance

This plan's "demonstrably working behavior" is *evidence*, not features — except
for promoted items, which carry code-level acceptance too.

- **Prototype milestones (M1, M2).** Acceptance is: the new bench groups execute
  green under `cabal bench kiroku-store:kiroku-store-bench` with the patterns
  shown above; three CSV+transcript pairs per experiment are checked in under
  `docs/bench/append-hot-path/` (M1) and `docs/bench/read-hot-path/` (M2); each
  experiment has exactly one new append-only row in `docs/perf-experiment-log.md`
  quoting cell names and figures verbatim with outcome `kept` or
  `not-implemented`; and this plan's living sections record the verdicts. A
  *discard* with clean numbers fully satisfies the milestone.
- **M3a (if reached).** `cabal test kiroku-store:kiroku-store-test` passes
  including the new multi-stream tests (conflict-rollback, empty-batch rejection,
  connection reuse after rollback); `just bench-regression` passes; the
  `reliability-audit.appendMultiStream 3 existing streams` cell improves vs. the
  step-1 baseline by an amount consistent with the M1 spike; observable behavior
  check: a two-stream `appendMultiStream` against a live store returns the same
  `AppendResult`s (same versions/positions for same inputs) as before the change,
  and a forced conflict on stream 2 leaves stream 1 unappended (verified by the
  test reading both streams back).
- **M3c (if reached).** New raw-read tests pass: for seeded events,
  `readAllForwardRaw` returns rows whose payload bytes `Aeson.decodeStrict` to the
  exact `Value` that `readAllForward` returns, with all other fields equal; the
  Haddock on `readAllForwardRaw` states the `decodeHook` bypass.
- **M3d (always).** The Haddock sections exist on all five Transaction.hs
  combinators; `cabal build kiroku-store` succeeds (Haddock syntax errors fail the
  build under the project's warning settings); the Decision Log contains the
  affordance verdict.
- **Methodology compliance (all milestones).** Each experiment shows the four-step
  trail: a profile artefact, a ledger-check note (in this plan), the
  expected-impact sentence written *before* measurement, and a post-measurement
  ledger row comparing prediction to observation.


## Idempotence and Recovery

Every step here is safe to repeat. Benchmarks run against a throwaway PostgreSQL
instance that `ephemeral-pg` creates and destroys per run; re-running a bench
mutates nothing durable. `just bench-baseline` overwrites
`kiroku-store/bench/results/baseline.csv` — that is its job; only run it at the
designated preflight point (re-running it *mid-experiment* would move the goalposts;
if that happens, `git checkout -- kiroku-store/bench/results/baseline.csv` restores
the committed one). The profiling run deletes and recreates
`kiroku-store-bench.prof` in the repo root; copy anything worth keeping into
`docs/bench/` before re-running. The perf ledger is append-only by convention —
never edit prior rows; a wrong row is corrected by appending a new row that
cross-references it.

Spike code in `kiroku-store/bench/Main.hs` is additive and isolated to new
`bgroup`s and helpers; abandoning a spike is `git revert` of its commit (though the
convention, after plans 22/23, is to *keep* spike cells as durable evidence — prefer
keeping them unless they meaningfully slow the full bench run). M3a replaces the
interpreter's transaction mechanics in one commit so a single revert restores the
`TxSessions.transaction` path; the test suite is the guard that the revert is clean.
M3b lands as two separately revertible commits by design. M3c is purely additive —
new type, new statement, new combinator — and removable without touching existing
callers. Benchmark numbers are machine-sensitive: note the machine and load context by hand
at the top of each saved transcript (tasty-bench prints only timings), close noisy
applications, and treat cross-machine comparisons as invalid; all gates compare
cells measured in the same session on the same machine.

If a pipelined session errors mid-experiment and a pooled connection ends up inside
an aborted transaction, the blast radius is one ephemeral bench database that the
next run recreates; in M3a production code this is handled explicitly (best-effort
`ROLLBACK` on the error path) and tested.


## Interfaces and Dependencies

**Libraries (all already in `kiroku-store/kiroku-store.cabal`; no new dependencies
are added by this plan):**

- `hasql >=1.10 && <1.11` — provides `Hasql.Pipeline` (`Pipeline`, `statement`),
  `Hasql.Session.pipeline`, `Hasql.Decoders.jsonbBytes :: (ByteString -> Either
  Text a) -> Value a`, and `Hasql.Decoders.noResult`. Source on disk for reference:
  `/Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql` (registered in mori as
  `hasql/hasql`).
- `hasql-pool` — `Pool.use` remains the session entry point everywhere.
- `hasql-transaction` — still used by every path this plan does *not* touch; note
  again it has no pipeline support, which is why M3a leaves `Tx.Transaction`
  behind for `AppendMultiStream` only.
- `tasty-bench`, `ephemeral-pg`, `async`, `deepseq` — the bench harness, already
  wired into the `kiroku-store-bench` stanza.

**Existing internal interfaces relied on (full module paths):**

- `Kiroku.Store.SQL` (exposed module): `appendAnyVersion` / `appendNoStream` /
  `appendExpectedVersion` / `appendStreamExists` statements, `AppendParams`,
  `lockStreamsForMultiStmt`, `readAllForwardStmt`. Note the module exports only
  assembled `Statement` values — SQL texts (`readAllForwardSQL`), row decoders
  (`recordedEventRow`), and param encoders are internal, so the M2 spike copies
  them locally and M3c (if reached) exports the new raw pieces explicitly.
- `Kiroku.Store.Effect`: `buildAppendParams`, `prepareEvents`, `appendDispatchTx`
  (exported for `Kiroku.Store.Transaction`; the spikes may reuse them),
  `attributeMultiStreamError` / `emptyResultError` mapping (M3a must preserve).
- `Kiroku.Store.Settings`: `decodeEvents` / `decodeHook` — the hook the raw path
  documents itself as bypassing.

**Interfaces that must exist at the end of each milestone:**

- *End of M1:* no new public interfaces. `kiroku-store/bench/Main.hs` contains the
  `pipelined-multi-append` group and its local helpers (suggested names:
  `runCurrentMultiAppend4`, `runPipelinedMultiAppend4`, `beginStmt`, `commitStmt`,
  `rollbackStmt`, `runContentionProbe`); all helpers are bench-local.
- *End of M2:* no new public interfaces. Bench-local `RawEventRow`, `rawEventRow ::
  Hasql.Decoders.Row RawEventRow`, `rawReadAllForwardStmt ::
  Hasql.Statement.Statement (Int64, Int32) (Data.Vector.Vector RawEventRow)`, and
  the `read-raw-shape` group.
- *End of M3, only for promoted items:*
  - M3a: `Kiroku.Store.Effect`'s `AppendMultiStream` interpreter runs the
    two-phase pipeline; the public signature `appendMultiStream :: [(StreamName,
    ExpectedVersion, [EventData])] -> Eff es [AppendResult]` in
    `Kiroku.Store.Append` is unchanged.
  - M3c: `Kiroku.Store.SQL.RecordedEventRaw` (record with the same 11 fields as
    `RecordedEvent`, `payload :: Data.ByteString.ByteString`, `metadata :: Maybe
    Data.ByteString.ByteString`), `Kiroku.Store.SQL.readAllForwardRawStmt`, and
    `Kiroku.Store.Read.readAllForwardRaw :: GlobalPosition -> Int32 -> Eff es
    (Data.Vector.Vector RecordedEventRaw)` (with the matching `Store` effect
    constructor), all additive; `RecordedEvent` and every existing read combinator
    byte-for-byte unchanged.
  - M3d (always): no type changes — Haddock-only on
    `Kiroku.Store.Transaction.runTransactionAppending` and its four siblings,
    plus a Decision Log entry on the deferred-or-added pre-append affordance.

**Documents this plan reads from and writes to:** `docs/PERF-METHODOLOGY.md`
(contract), `docs/perf-experiment-log.md` (append rows),
`docs/bench/append-hot-path/` and `docs/bench/read-hot-path/` (artefacts),
`docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`
(registry/progress updates at wrap-up), and the prior-art plans cited throughout:
`docs/plans/21-evaluate-append-hot-path-performance-experiments.md`,
`docs/plans/22-optimize-singleton-append-sql-path.md`,
`docs/plans/23-restructure-append-into-a-two-round-trip-path.md`,
`docs/plans/24-localize-the-hasql-round-trip-overhead.md`,
`docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md`,
`docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md`,
`docs/plans/36-add-originalstreamname-to-recordedevent.md`,
`docs/plans/59-fix-backward-read-pagination-and-append-edge-case-errors.md`,
`docs/plans/60-schema-and-trigger-hygiene-notify-guard-dead-letter-fk-policy-and-index-fixes.md`.

---

Revision note (2026-06-10): initial authoring. Fleshed out the skeleton into the
full exploratory plan: embedded the verified `Hasql.Pipeline` semantics from the
pinned hasql 1.10.3 source (Applicative-only composition, single sync point,
extended-protocol-only, abort-at-sync error behavior) and derived the two-phase
transaction shape from the zero-rows-on-conflict property of Kiroku's append CTEs;
fixed promote thresholds (≥20 % pipelining at N=4, ≥15 % raw reads at 1000-event
pages) before any measurement per `docs/PERF-METHODOLOGY.md`; recorded the EP-4/EP-5
soft-dependency sequencing and baseline-recapture requirement; and scoped the
`buildAppendParams` micro-costs as conditional fold-in only, citing the plan-21
negative result. Reason: this is EP-7 of master plan 9, deliberately last and
benchmark-gated so unproven optimizations never block the correctness waves.
