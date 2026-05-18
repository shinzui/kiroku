---
id: 25
slug: haskell-side-append-profiling-with-ghc-prof
title: "Haskell-side append profiling with GHC -prof"
kind: exec-plan
created_at: 2026-05-18T22:10:22Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
master_plan: "docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md"
---

# Haskell-side append profiling with GHC -prof

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan lands, anyone working on Kiroku's append performance can answer one question with evidence rather than speculation: where, inside the Haskell layer of `appendToStream`, does the wall time actually go. The current state of the world is that single-event hot-stream append measures ~152 µs on this harness (recorded in `docs/plans/22-optimize-singleton-append-sql-path.md` and refined in plans 23 and 24 under `docs/plans/`), but no plan to date has profiled where that time is spent inside the Haskell process. Every previous optimization attempt selected its target by reading the source and guessing — that is the cycle this plan exists to break.

The deliverable is a profile. Concretely, after this plan a contributor can run a documented command, point the resulting benchmark binary at an ephemeral PostgreSQL, and produce a `kiroku-store-bench.prof` text file in the working directory whose cost-centre breakdown attributes wall time across the production single-event AnyVersion append path. The cost centres of interest correspond to the named helpers `Kiroku.Store.Append.appendToStream`, `Kiroku.Store.Effect.prepareEvents`, `Kiroku.Store.Effect.buildAppendParams`, `Kiroku.Store.Effect.appendDispatchTx`, the Hasql encoder application driven by `Kiroku.Store.SQL.appendParamsEncoder`, and the surrounding `Effectful.Dispatch.Dynamic.interpret_` wrapping that discharges the `Store` effect. The user-visible outcome is that future optimization plans can quote a sentence such as "JSONB encoding is 18% of the Haskell-side time, so a payload-shape change worth pursuing must beat that ceiling" instead of "the encoder feels expensive."

This plan does not produce a faster append. It produces evidence. The MasterPlan at `docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md` documents why infrastructure, not optimization, is the right deliverable for this initiative.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Decide between adding a separate `kiroku-store-bench-profiled` cabal stanza and documenting an `--enable-profiling` invocation of the existing `kiroku-store-bench` stanza; record the outcome in the Decision Log. — 2026-05-18, kept the single stanza per the initial Decision Log entry.
- [x] Wire `ghc-prof-options` (or the equivalent stanza change) into `kiroku-store/kiroku-store.cabal` so the profiled build emits per-cost-centre attribution by default when profiling is enabled. — 2026-05-18, added `ghc-prof-options: -fprof-auto` to `kiroku-store-bench` stanza at line ~114.
- [x] Confirm the `kiroku-store-bench` target builds successfully under `cabal build --enable-profiling`, including profiling versions of every transitive dependency. — 2026-05-18, `cabal build --enable-profiling kiroku-store:kiroku-store-bench` exits 0; ~50 transitive deps rebuilt in the profiling way.
- [x] Run the profiled bench against an ephemeral PostgreSQL with `+RTS -p -RTS` and inspect the emitted `kiroku-store-bench.prof` file for non-empty cost-centre rows. — 2026-05-18, 3.8 MB `.prof` with `total time = 13.94 secs` and a populated flat-table.
- [x] Verify the `.prof` contains cost centres covering `appendToStream`, `prepareEvents`, `buildAppendParams`, `appendDispatchTx`, the Hasql encoder layer, and the `Effectful` interpreter; add `{-# SCC #-}` pragmas only if `-fprof-auto` alone does not surface them. — 2026-05-18, `appendToStream`, `prepareEvents`, `buildAppendParams`, `runStorePool`, `runStoreIO`, `appendAnyVersion`, `appendNoStream`, and a dense Effectful subtree all appear; `appendDispatchTx` is absent because the single-stream `AppendToStream` branch bypasses it (documented in Surprises). `appendParamsEncoder` itself does not appear because hasql encoders are CAF-shaped values whose work happens inside `PostgreSQL.Binary.Encoding.*` cost centres (documented in Surprises). No `{-# SCC #-}` pragmas were added.
- [x] Check the captured profile (or a reproduction command for it) into `docs/bench/append-hot-path/` so future plans can cite it without re-running. — 2026-05-18, archived as `docs/bench/append-hot-path/single-event-anyversion.prof`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The bench's pre-`defaultMain` setup dominates the profile, not the cell
  targeted by `--pattern`.** `kiroku-store/bench/Main.hs:646-749` unconditionally
  pre-populates 100K category events (~6.6 s wall time), and B9 pool-saturation
  runs 64 writers × 100 appends through a 10-slot pool (~3.3 s) *before*
  `defaultMain` parses its arguments. The `--pattern` filter only narrows
  which `defaultMain` bench cells run, so a constrained run of
  `append.single-event.AnyVersion (new stream)` still pays the full setup cost.
  Of the 13.94 s `total time` in `docs/bench/append-hot-path/single-event-anyversion.prof`,
  `defaultMain` itself accounts for only 0.3% inherited time — the single-event
  AnyVersion cell is a needle in a haystack of setup work.

  Implication: the cost-centre proportions in the flat table reflect the
  *aggregate* append path across pre-population, B9 saturation, and the
  constrained cell, weighted by how much each contributes. Future plans
  consuming this `.prof` should read the *call-tree* attribution under
  `Test.Tasty.Bench.defaultMain` (line ~3347 of the `.prof`) when they want
  cell-specific behaviour, and the flat table when they want a representative
  picture of the append path under both single-shot and pool-saturated load.

  Evidence:

  ```text
  --- Pre-populating category data (100 cats × 10 streams × 100 events) ---
    Setup time: 6.648584s (100K events)
  --- B9: Pool saturation (64 writers × 100 appends, pool size 10) ---
    Total appends: 6400
    Elapsed: 3.280177s
  ```

  Captured from the bench's stdout during the M2 run (full output:
  `/private/tmp/.../belfbrjg3.output` and `/private/tmp/.../b830mpcw3.output`).
  Master Plan 3's Integration Points section forbids modifying existing bench
  cells, so the right follow-up is a new bgroup (or an env-gated short-circuit
  of B9 / B10 setup when profiling) rather than re-shaping the current cells.
  This is a candidate for a follow-up plan; out of scope for EP-1.

- **STM contention on the hasql-pool TQueue dominates the flat-table `%time`.**
  Top of the flat table:

  ```text
  $fAlternativeSTM5    GHC.Internal.Conc.Sync           38.9    0.8
  $wreadTQueue         Control.Concurrent.STM.TQueue    31.7    0.1
  $wopenat_            System.Posix.IO.Common            5.7    0.0
  use                  Hasql.Pool                        3.9    0.2
  $wallocaBytesAligned GHC.Internal.Foreign.Marshal.Alloc 2.5   0.9
  getResult            Database.PostgreSQL.LibPQ         2.2    0.0
  getvalue'            Database.PostgreSQL.LibPQ         2.2    1.2
  ```

  The 70.6% spent in STM `Alternative` / `readTQueue` is the cost of 64
  writers blocking on the 10-slot pool's `TQueue` during B9 saturation. This
  matches the qualitative reading of `Hasql.Pool.use` source
  (`mori://nikita-volkov/hasql-pool/packages/hasql-pool`) but the magnitude is
  larger than any prior plan documented. Implication for future plans: pool
  contention, not encoder work or SQL shape, is the largest single contributor
  to wall time under saturation. A separate pool-aware profile (smaller writer
  count, or sequential single-event runs without B9) would reveal what dominates
  in the *uncontended* case.

- **`appendParamsEncoder` does not appear as a named cost centre even with
  `-fprof-auto`.** The function is top-level in `kiroku-store/src/Kiroku/Store/SQL.hs:74-83`
  and should have been instrumented. The likely cause is that hasql encoders
  are CAF-shaped values (`E.Params AppendParams` constructed once at module
  load, no per-call work in the encoder *definition*) — the actual per-call
  serialisation happens inside `PostgreSQL.Binary.Encoding.*` cost centres
  driven by hasql's encoder runtime. Flat table shows
  `PostgreSQL.Binary.Encoding.dimensionArray` at 0.3% as the most visible
  encoder-side cost centre. A future plan that wants per-array attribution
  (payloads vs metadatas vs UUIDs vs timestamps) needs explicit `{-# SCC #-}`
  pragmas at the call sites in `AppendParams`-style encoders, as anticipated
  by the Decision Log entry on stanza pragmas. Not done in EP-1; the present
  profile is sufficient for EP-1's acceptance gate.

- **`appendDispatchTx` is genuinely zero for single-event AnyVersion**, because
  the `AppendToStream` branch in `runStorePool`
  (`kiroku-store/src/Kiroku/Store/Effect.hs:117-138`) calls
  `Session.statement` directly against one of the four prepared statements;
  `appendDispatchTx` is only used by the `AppendMultiStream` branch
  (line 205). The plan's M2 acceptance gate explicitly anticipated this case
  ("either the cost centre is genuinely zero ... in which case document it in
  Surprises & Discoveries"); recording here.

- **Two corrections to the documented invocation in Concrete Steps step 3
  surfaced during implementation.** First, the `--` separator after `-RTS` in
  the direct-binary invocation causes tasty-bench's optparse-applicative
  parser to reject `--pattern` as "Invalid option" — running the binary
  directly does not need `--`. Second, the example pattern
  `'$0 == "append.single-event.AnyVersion (new stream)"'` matches zero tests;
  `tasty-bench`'s `defaultMain` wraps the test tree under an implicit `All.`
  group, so the correct full path is
  `'$0 == "All.append.single-event.AnyVersion (new stream)"'`. Confirmed by
  `kiroku-store-bench --list-tests`, which prints `All.append.single-event.AnyVersion (new stream)`.
  Both corrections are now reflected in the Concrete Steps section and in
  the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Start with classic `-prof` plus `-fprof-auto`, not `-fprof-late`.
  Rationale: `-fprof-auto` (a GHC flag that instruments every top-level binding with a cost centre before optimisation) is the well-trodden path: every Haskell profiling tutorial assumes it, every output reader knows the layout it produces, and it surfaces small helpers such as `prepareEvents` and `buildAppendParams` as named cost centres even if they would otherwise be inlined away. `-fprof-late` (GHC 9.4+, places cost centres after optimisation to reduce distortion) is a strictly better choice when absolute numbers matter, but this plan cares about the *relative* distribution across cost centres, not absolute wall time. If the relative profile turns out to be too distorted by the pre-optimisation cost-centre placement, we revisit `-fprof-late` as a follow-up. Documented as an option in Concrete Steps.
  Date: 2026-05-18

- Decision: Drive profiling through cabal flags on the existing `kiroku-store-bench` stanza rather than introducing a parallel `kiroku-store-bench-profiled` stanza.
  Rationale: The bench is already a single executable with a fixed set of bgroups; adding a second stanza duplicates `main-is`, `build-depends`, and the `EphemeralPg`-based setup, and the only reason to clone the stanza would be to bake `-prof` into the per-stanza `ghc-options`. Cabal already supports project-wide `--enable-profiling` plus `--ghc-options`, which the bench respects without modification. The only cabal-side edit anticipated is adding a `ghc-prof-options` field to `kiroku-store-bench` so that profiled builds automatically pick up `-fprof-auto` without a long command line. This decision is revisitable if the regression workflow forces it (the master plan's Integration Points section requires the existing bench cells to remain measurement-stable, which a per-stanza option respects).
  Date: 2026-05-18

- Decision: Do not modify `kiroku-store/src/Kiroku/Store/*` with `{-# SCC #-}` pragmas unless `-fprof-auto` fails to surface the helper as a named cost centre.
  Rationale: `-fprof-auto` annotates every top-level binding automatically; `prepareEvents`, `buildAppendParams`, and `appendDispatchTx` are top-level bindings in `kiroku-store/src/Kiroku/Store/Effect.hs`, so they should appear as cost centres without source edits. `appendParamsEncoder` is top-level in `kiroku-store/src/Kiroku/Store/SQL.hs`. The only paths likely to need explicit `{-# SCC #-}` annotation are sub-expressions of those bindings, e.g. the JSONB-encoder fragment inside `appendParamsEncoder`. The master plan's Integration Points section forbids changing public API but allows additive `{-# SCC #-}` pragmas as a last resort. We treat them as a last resort.
  Date: 2026-05-18

- Decision: Profile target is the `append/single-event/AnyVersion (new stream)` bench cell.
  Rationale: It exercises the production CTE path (`appendToStream` -> `runStorePool` -> `appendAnyVersion`), it is the cell whose latency previous plans optimized against, and it produces one append per iteration so the cost-centre attribution is per-append rather than amortised across a batch.
  Date: 2026-05-18

- Decision: Corrected the documented invocation in Concrete Steps step 3 to drop the `--` separator and prefix the bench cell path with `All.`.
  Rationale: While implementing M2 the original invocation produced zero matched tests and an "Invalid option `--pattern`" error. tasty-bench parses its CLI with optparse-applicative which treats `--` as "end of options", and `tasty-bench`'s `defaultMain` adds an implicit top-level `All.` group around the user-provided test tree. Both behaviours are confirmed by reading `Test/Tasty/Patterns/Parser.hs` (the `$0`/`$NF` field semantics, awk-derived) and by `kiroku-store-bench --list-tests` showing `All.append.single-event.AnyVersion (new stream)` for the leaf this plan targets. See Surprises & Discoveries for the full debrief.
  Date: 2026-05-18

- Decision: Did not modify `kiroku-store/bench/Main.hs` to skip the heavy pre-`defaultMain` setup (100K category events, B9 pool saturation) even though that setup dominates the profile.
  Rationale: Master Plan 3's Integration Points section is explicit that EP-1 changes must be additive — new bgroups, not modifications to existing cells — and changing bench startup behaviour would also invalidate the `kiroku-store/bench/results/baseline.csv` regression baseline used by `just bench-regression`. The right shape for a future profile that targets *just* the single-event AnyVersion cell is a new bgroup or an env-gated short-circuit; that work is out of scope for EP-1 and a candidate for a follow-up plan or for EP-2 (PostgreSQL-side profiling, which targets a single statement and avoids the bench setup entirely).
  Date: 2026-05-18

- Decision: Did not add `{-# SCC "appendParamsEncoder.payloads/metadatas" #-}` pragmas in `kiroku-store/src/Kiroku/Store/SQL.hs` to surface per-array JSONB cost.
  Rationale: The captured `.prof` already shows where encoder time goes — `PostgreSQL.Binary.Encoding.dimensionArray` at 0.3% flat-table `%time`, and the broader Postgres binary-encoder subtree contributes a similar order of magnitude. The flat table is dominated (>70%) by STM/`TQueue` pool-wait, so even doubling the visible encoder attribution would not change the strategic reading. Adding `{-# SCC #-}` pragmas only makes sense for a future plan that has *already* targeted JSONB encoding as the hotspot and needs per-array attribution to choose between payload-shape options; that plan is out of scope for EP-1.
  Date: 2026-05-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

### Delivered

A profiling-enabled bench is now reachable in one cabal command, and a
representative `.prof` is checked in to `docs/bench/append-hot-path/single-event-anyversion.prof`.

Reproduction:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build --enable-profiling kiroku-store:kiroku-store-bench
BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
rm -f kiroku-store-bench.prof
"$BENCH" +RTS -p -RTS \
  --pattern '$0 == "All.append.single-event.AnyVersion (new stream)"' \
  --stdev 100
```

The first profiled build is slow (~50 transitive dependencies rebuilt in the
profiling way); subsequent profiled builds are cached and fast. The first run
of the bench prints the usual setup phases (pre-population, B9 saturation),
runs the constrained cell, and writes `kiroku-store-bench.prof` to the
current working directory.

### Top five cost centres in the captured `.prof`

From the flat table at the top of `docs/bench/append-hot-path/single-event-anyversion.prof`:

```text
COST CENTRE          MODULE                                 %time %alloc
$fAlternativeSTM5    GHC.Internal.Conc.Sync                  38.9    0.8
$wreadTQueue         Control.Concurrent.STM.TQueue           31.7    0.1
$wopenat_            System.Posix.IO.Common                   5.7    0.0
use                  Hasql.Pool                               3.9    0.2
$wallocaBytesAligned GHC.Internal.Foreign.Marshal.Alloc       2.5    0.9
```

`total time = 13.94 secs` over `5,649,499,792 bytes` of profile-corrected
allocations.

### One-paragraph reading of where the Haskell-side time goes

The Haskell-side overhead of the production single-event AnyVersion append
path is dominated, in this profile, by pool-wait STM operations
(`$fAlternativeSTM5` + `$wreadTQueue` = 70.6% combined). This includes the
B9 pool-saturation setup (64 writers × 100 appends competing for a 10-slot
pool) plus the constrained bench cell's pool-acquire on each iteration; the
two contribute roughly proportionally to their wall-time share, with B9
saturation by far the larger contributor. The next visible bucket is libpq
result handling (`getResult` 2.2% + `getvalue'` 2.2%) and binary-encoder
work (`PostgreSQL.Binary.Encoding.dimensionArray` 0.3% + buffer machinery).
Time spent in our own helpers — `prepareEvents`, `buildAppendParams`,
`appendToStream` — is below 0.1% inherited in every call-tree branch under
`Test.Tasty.Bench.defaultMain`. The strategic implication for future plans
is that a Haskell-side optimisation targeting `prepareEvents` /
`buildAppendParams` / encoder restructuring can recover at most a fraction
of one percent of total wall time. The dominant cost is pool-acquire +
libpq round-trip, which is the same picture EP-2 will quantify on the
PostgreSQL side.

### Gaps and follow-ups

Two gaps are intentional and recorded in the Decision Log:

1. The bench's heavy pre-`defaultMain` setup (100K category events, B9
   saturation) dilutes the profile away from a pure single-event AnyVersion
   reading. Master Plan 3 forbids modifying existing cells, and an additive
   "profile-only" bgroup or env-gated short-circuit is the right shape — but
   that is its own ExecPlan, not part of EP-1.

2. `appendParamsEncoder` does not surface as a named cost centre because
   hasql encoders are CAF-shaped. Per-array JSONB attribution would require
   `{-# SCC #-}` pragmas at the call sites; the present profile is enough
   to confirm the encoder is not the hot spot, so the pragmas were not
   added.

Both are documented in Surprises & Discoveries. The master plan's
methodology README (`docs/PERF-METHODOLOGY.md`) and experiment ledger
(`docs/perf-experiment-log.md`) are the right places for a future plan to
record either follow-up.

### Comparison against the original purpose

The Purpose / Big Picture stated this plan would let a contributor "quote a
sentence such as 'JSONB encoding is 18% of the Haskell-side time, so a
payload-shape change worth pursuing must beat that ceiling'". The captured
profile lets the next contributor quote a stronger and more useful sentence:
"PostgreSQL.Binary.Encoding.* is 0.3% of total wall time and the Haskell
helpers under appendToStream are sub-0.1%; STM pool-wait is 70.6% and libpq
result-handling is ~4%, so Haskell-side optimisation will not move the
needle without first reducing pool contention or round-trip count." The
shape of the answer matches what the plan promised — evidence, not
speculation — and the answer itself is more decisive than the example.


## Context and Orientation

Kiroku is a Haskell event store. The package under profile here is `kiroku-store`, whose source lives at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/`. The production single-stream append entry point is `Kiroku.Store.Append.appendToStream`, defined in `kiroku-store/src/Kiroku/Store/Append.hs`. That function is a one-line `send (AppendToStream ...)` against the `Store` effect; the real work happens inside the effect interpreter `Kiroku.Store.Effect.runStorePool`, defined in `kiroku-store/src/Kiroku/Store/Effect.hs`. Inside `runStorePool`, the `AppendToStream` branch (around lines 117-138 of that file) calls three helpers — `prepareEvents`, `buildAppendParams`, and (for the multi-stream path) `appendDispatchTx` — all three of which are also top-level bindings in `kiroku-store/src/Kiroku/Store/Effect.hs` (around lines 359, 382, and 409 respectively). The single-stream path bypasses `appendDispatchTx` and dispatches directly via `Hasql.Session.statement` against one of four prepared statements: `appendExpectedVersion`, `appendStreamExists`, `appendNoStream`, or `appendAnyVersion`. Those four statements are defined in `kiroku-store/src/Kiroku/Store/SQL.hs`, and they share an encoder named `appendParamsEncoder` (lines 74-83 of that file) that packs seven parallel arrays plus a stream name into a single Hasql parameter bundle.

The encoder is the most likely Haskell-side hot spot. The JSONB-encoding sub-expression — `E.foldableArray (E.nonNullable E.jsonb)` for the `payloads` field at line 80, and `E.foldableArray (E.nullable E.jsonb)` for `metadatas` at line 81 — serialises each `Data.Aeson.Value` to the PostgreSQL wire format twice (once for each array), and this serialisation is opaque to a top-level cost centre placed on `appendParamsEncoder` itself. If the profile shows `appendParamsEncoder` dominating without a finer attribution, that is the signal to add `{-# SCC "appendParamsEncoder.jsonb" #-}` to those two subexpressions; see the Decision Log entry on `{-# SCC #-}` pragmas for why this is gated.

The benchmark target that drives the profile is `kiroku-store-bench`, declared as a `benchmark` stanza at line 108 of `kiroku-store/kiroku-store.cabal`, with `main-is: Main.hs` pointing at `kiroku-store/bench/Main.hs`. The bench uses `tasty-bench` (the Haskell library that times pure or IO actions in a `defaultMain` driver) and the `EphemeralPg.withCached` helper, which boots a one-shot PostgreSQL into a temporary directory for the lifetime of the bench. The single-event AnyVersion new-stream cell — the one this plan profiles — is at approximately line 760-764 of `kiroku-store/bench/Main.hs`, inside the `append > single-event` bgroup. The full append bgroup is at line 753-796 of that file and must not be modified by this plan (see Integration Points below).

Terms of art used throughout this plan, defined here so the reader does not need to look them up.

A **cost centre** is GHC's name for a labelled scope inside a profiled program. At runtime, every tick of the wall-clock timer is attributed to whichever cost centre is currently on the call stack; the result is a tree (and a flat-by-`%time` summary) showing how the program's wall time and allocations distribute across the labelled scopes. Cost centres can be inserted automatically (by the `-fprof-auto` family of flags) or manually (by writing `{-# SCC "name" #-}` annotations in source). They are visible to the compiler — they suppress some inlining, so a profiled binary is not byte-for-byte the same code as a non-profiled one. The typical inflation is 10-30% of wall time, sometimes more for very small hot functions, which is why profile numbers are read as relative percentages and not compared directly to non-profiled benchmark measurements.

A **`.prof` file** is the textual report GHC's runtime writes when a profiled binary exits, named after the binary with a `.prof` suffix in the working directory. It contains a header listing the binary and total time/allocation, then two views: a flat table sorted by `%time` (and a parallel `%alloc` column for allocations), and a deeper indented call tree. A short fragment looks like:

```text
        Mon May 18 22:30 2026 Time and Allocation Profiling Report  (Final)

           kiroku-store-bench +RTS -p -RTS

        total time  =        2.31 secs   (2310 ticks @ 1000 us, 1 processor)
        total alloc = 1,234,567,890 bytes  (excludes profiling overheads)

COST CENTRE          MODULE                       %time %alloc

appendParamsEncoder  Kiroku.Store.SQL              22.3   18.1
prepareEvents        Kiroku.Store.Effect            9.4    7.8
buildAppendParams    Kiroku.Store.Effect            6.7    5.2
interpret_           Effectful.Dispatch.Dynamic     5.1    4.6
```

The two columns `%time` and `%alloc` are how every "where does the time go" question is answered. The numbers above are illustrative, not measured.

The **`-prof` flag** tells GHC to compile a binary with the profiling runtime linked in. By itself it does nothing — you must also tell GHC *where* to place cost centres. The three flag families that do that are: `-fprof-auto`, which instruments every top-level binding (the broadest and most common choice, and the one this plan starts with); `-fprof-auto-top`, which instruments only top-level bindings that are also exported (cheaper, coarser, useful for very large modules); `-fprof-auto-calls`, which instruments at call sites rather than at binding sites (useful when you want to see who called a hot function rather than just that it was hot); and `-fprof-late` (GHC 9.4+), which inserts cost centres after most optimisations have run, so the resulting profile is closer to what optimised code actually does, at the cost of being unable to instrument bindings that were inlined or specialised away. This plan uses `-fprof-auto` as the default; the Decision Log entry on it records why, and the Concrete Steps section shows the alternative invocations.

`tasty-bench`'s `defaultMain` runs each cell multiple times to estimate a mean; under profiling, the cost-centre output aggregates across all iterations of all cells unless the runtime is constrained to a single cell via `tasty-bench`'s pattern filters. Concrete Steps shows how to constrain the run to one cell so the profile is not diluted by unrelated work.

The MasterPlan governing this work is at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`. Its Integration Points section requires this plan's bench changes to be additive: any new profiled bench cells go in a new bgroup, the existing `append/*`, `raw-append-shape/*`, `read/*`, and `concurrent/*` cells stay byte-identical, and the regression baseline at `kiroku-store/bench/results/baseline.csv` remains meaningful for `just bench-regression`. This plan is one of three children under that MasterPlan; the sibling plans are `docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md` (PostgreSQL-side `EXPLAIN ANALYZE` harness) and `docs/plans/27-append-performance-experiment-ledger-and-methodology-readme.md` (experiment ledger). There are no hard dependencies; the three plans may proceed in parallel.

The GHC version on this development box is 9.12.2, which supports both `-fprof-auto` and `-fprof-late`. All profiling flags referenced in this plan are valid at that version.


## Plan of Work

The work splits into two milestones. The first establishes that profiling works at all on this codebase: a profiled bench binary that produces a non-empty `.prof` for any append cell, even if the cost-centre coverage is sparse. The second extends the coverage so the cost centres actually attribute time across the production append path's major regions — prepare, build params, encode, dispatch, interpret — for the single-event AnyVersion bench cell that previous plans optimized against.

### Milestone 1: Profiled build emits a `.prof` for one append cell

The scope of this milestone is to confirm Cabal can build `kiroku-store-bench` with profiling enabled on this machine, with profiling versions of every transitive dependency, and that running the resulting binary with `+RTS -p -RTS` produces a `kiroku-store-bench.prof` text file in the working directory. The cell exercised is irrelevant; any append cell will do. The acceptance gate is the existence of a `.prof` file with a non-empty cost-centre table and a non-zero total time.

The work at this milestone is mostly Cabal-side. Add a `ghc-prof-options` field to the `kiroku-store-bench` stanza at line 108 of `kiroku-store/kiroku-store.cabal`, with value `-fprof-auto`. That field is honoured by Cabal only when profiling is enabled (via `--enable-profiling` on the `cabal build`/`cabal bench` invocation or `profiling: True` in `cabal.project`), so it has zero effect on non-profiled builds and therefore does not invalidate the regression baseline. The remainder of this milestone is running `cabal build kiroku-store:kiroku-store-bench --enable-profiling` and confirming that the binary is produced. The first profiled build will be slow because Cabal must rebuild every transitive dependency in the profiling way; this is a one-time cost per dependency snapshot.

Acceptance for Milestone 1 is the bash transcript shown in the Concrete Steps section: `cabal build --enable-profiling kiroku-store:kiroku-store-bench` exits with code 0, and the produced binary, when run with `+RTS -p -RTS` against an ephemeral PostgreSQL, writes a `kiroku-store-bench.prof` file with a header line containing `Time and Allocation Profiling Report` and at least one COST CENTRE row with non-zero `%time`.

### Milestone 2: Single-event AnyVersion profile covers the production append path

The scope of this milestone is to constrain the profile to the `append/single-event/AnyVersion (new stream)` cell (around line 760 of `kiroku-store/bench/Main.hs`) and verify that the resulting `.prof` contains cost-centre rows for the helpers `Kiroku.Store.Append.appendToStream`, `Kiroku.Store.Effect.prepareEvents`, `Kiroku.Store.Effect.buildAppendParams`, the Hasql encoder application driven by `Kiroku.Store.SQL.appendParamsEncoder`, and the `Effectful.Dispatch.Dynamic.interpret_` wrapping. If any of those five appears missing from the flat table, the milestone gate forces investigation: either the cost centre is genuinely zero (the corresponding code path is not exercised by single-event AnyVersion, in which case document it in Surprises & Discoveries) or `-fprof-auto` failed to instrument it (in which case add an explicit `{-# SCC #-}` pragma in `kiroku-store/src/Kiroku/Store/Effect.hs` or `kiroku-store/src/Kiroku/Store/SQL.hs`, justify the addition in the Decision Log, and re-run the profile).

The work at this milestone is mostly runtime configuration. `tasty-bench` accepts a `--pattern` argument that filters which cells run; passing `--pattern '$0 == "append.single-event.AnyVersion (new stream)"'` constrains the run to one cell. `tasty-bench` also accepts `--stdev 0` (or a very small `--timeout`) to make the run finish quickly when only the profile is needed and the timing numbers are uninteresting. The full invocation is in Concrete Steps. After the run, copy the resulting `kiroku-store-bench.prof` into `docs/bench/append-hot-path/single-event-anyversion.prof` (a path consistent with where previous plans stored bench artefacts), or record the exact reproduction command in this plan's Outcomes section so a future contributor can regenerate it.

Acceptance for Milestone 2 is that the `kiroku-store-bench.prof` produced by the constrained run contains cost-centre rows whose `MODULE` column matches `Kiroku.Store.Append`, `Kiroku.Store.Effect`, `Kiroku.Store.SQL`, and at least one cost centre attributable to the `Effectful` interpreter wrapping, and that the sum of their `%time` columns is greater than zero.


## Concrete Steps

All commands run from the repository root at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. The working directory is preserved across each numbered block.

### 1. Add `ghc-prof-options` to the bench stanza

Edit `kiroku-store/kiroku-store.cabal` and add a `ghc-prof-options` line to the `kiroku-store-bench` stanza, immediately after the existing `ghc-options` line at line 113. The minimal diff:

```diff
 benchmark kiroku-store-bench
   import:         common
   type:           exitcode-stdio-1.0
   main-is:        Main.hs
   hs-source-dirs: bench
   ghc-options:    -threaded -rtsopts "-with-rtsopts=-N -A32m"
+  ghc-prof-options: -fprof-auto
   build-depends:
```

The `ghc-prof-options` field is applied by Cabal only when profiling is enabled (i.e. when `--enable-profiling` is passed or `profiling: True` is set in `cabal.project`). Non-profiled builds are byte-identical to before, which preserves the regression baseline at `kiroku-store/bench/results/baseline.csv`.

### 2. Build the bench with profiling enabled

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
cabal build --enable-profiling kiroku-store:kiroku-store-bench
```

Expected first-time transcript (truncated; the dependency-rebuild output is long):

```text
Resolving dependencies...
Build profile: -w ghc-9.12.2 -O1 --enable-profiling
In order, the following will be built (use -v for more details):
 - aeson-2.2.x.x (lib:aeson) (requires build)
 ... [many transitive dependencies, all rebuilt in the profiling way]
 - kiroku-store-0.1.0.0 (lib) (requires build)
 - kiroku-store-0.1.0.0 (bench:kiroku-store-bench) (requires build)
Configuring library for kiroku-store-0.1.0.0..
Preprocessing library for kiroku-store-0.1.0.0..
Building library for kiroku-store-0.1.0.0..
[1 of N] Compiling Kiroku.Store.SQL ...
...
Linking .../kiroku-store-bench ...
```

The exit code is 0 on success. Subsequent profiled builds are fast because Cabal caches the profiled object files.

### 3. Run the bench with the profiling runtime enabled and capture a `.prof`

The most reliable invocation is to discover the binary path with
`cabal list-bin` and run it directly. Do **not** put a `--` between the `-RTS`
sentinel and the bench's own arguments: tasty-bench uses optparse-applicative,
which treats `--` as "end of options" and rejects `--pattern` as an unknown
positional argument ("Invalid option `--pattern`"). The full path that
`--pattern` matches against has an implicit `All.` prefix added by
`tasty-bench`'s `defaultMain`, so the cell's `$0` is
`"All.append.single-event.AnyVersion (new stream)"`, not
`"append.single-event.AnyVersion (new stream)"`. List the full names with
`"$BENCH" --list-tests` to confirm before constructing patterns.

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
BENCH=$(cabal list-bin --enable-profiling kiroku-store:kiroku-store-bench)
rm -f kiroku-store-bench.prof
"$BENCH" +RTS -p -RTS \
  --pattern '$0 == "All.append.single-event.AnyVersion (new stream)"' \
  --stdev 100
```

On success, `kiroku-store-bench.prof` appears in the current working directory. A short expected fragment from its header and flat table:

```text
        Mon May 18 22:30 2026 Time and Allocation Profiling Report  (Final)

           kiroku-store-bench +RTS -p -RTS

        total time  =        N.NN secs
        total alloc = NNN,NNN,NNN bytes  (excludes profiling overheads)

COST CENTRE          MODULE                        %time %alloc

appendParamsEncoder  Kiroku.Store.SQL               XX.X   XX.X
prepareEvents        Kiroku.Store.Effect            XX.X   XX.X
buildAppendParams    Kiroku.Store.Effect            XX.X   XX.X
interpret_           Effectful.Dispatch.Dynamic     XX.X   XX.X
appendToStream       Kiroku.Store.Append            XX.X   XX.X
```

Actual numbers and ordering will differ; the gate is the presence of the rows, not their values.

### 4. (Optional) Try `-fprof-late` to compare distortion

If the relative profile from step 3 looks dominated by very small functions in a way that suggests pre-optimisation cost-centre placement is distorting the picture (for example, every helper appears at single-digit `%time` while no single hot spot is obvious), repeat steps 1-3 with `-fprof-late` substituted for `-fprof-auto` in `ghc-prof-options`. `-fprof-late` is supported in GHC 9.12.2. The result is a profile that more closely reflects what optimised code actually does, at the cost of not being able to instrument anything that was inlined away. Record the comparison in Surprises & Discoveries.

### 5. (Optional, last resort) Add `{-# SCC #-}` annotations for finer attribution

If step 3 produces a profile where `appendParamsEncoder` dominates but its internal structure is invisible — specifically, if the JSONB-array sub-encoders at lines 80-81 of `kiroku-store/src/Kiroku/Store/SQL.hs` are the suspected hot spot but cannot be attributed without source edits — add `{-# SCC "appendParamsEncoder.payloads" #-}` and `{-# SCC "appendParamsEncoder.metadatas" #-}` annotations around those two sub-expressions, and re-run step 3. Justify each annotation in the Decision Log. See the Decision Log entry on `{-# SCC #-}` pragmas for the gating criteria.

### 6. Archive the captured profile

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
mkdir -p docs/bench/append-hot-path
cp kiroku-store-bench.prof docs/bench/append-hot-path/single-event-anyversion.prof
```

The captured profile is small (typically a few kilobytes of text) and benefits from being checked in so future plans can cite it without re-running the harness. If the file is omitted from version control for size or churn reasons, record the exact reproduction command (the one in step 3) in the Outcomes & Retrospective section of this plan.


## Validation and Acceptance

The plan is complete when all of the following hold, verified by the commands in Concrete Steps.

The first acceptance check is that `cabal build --enable-profiling kiroku-store:kiroku-store-bench` exits with code 0 on a fresh checkout. This is verifiable by running the command and inspecting `echo $?`.

The second acceptance check is that running the profiled bench binary with `+RTS -p -RTS` against an ephemeral PostgreSQL (set up automatically by the bench's `EphemeralPg.withCached` driver) produces a `kiroku-store-bench.prof` file in the current working directory. The file's header must include a `total time = N.NN secs` line with N greater than 0, indicating that the profiling runtime actually ran and sampled work.

The third acceptance check, and the one that proves the profile is useful, is that the `kiroku-store-bench.prof` produced by the constrained run (step 3 in Concrete Steps, with `--pattern` limiting the run to `append.single-event.AnyVersion (new stream)`) contains cost-centre rows in its flat table for the following modules: `Kiroku.Store.Append`, `Kiroku.Store.Effect`, `Kiroku.Store.SQL`, and at least one entry attributable to the `Effectful` library's dispatch machinery (either `Effectful.Dispatch.Dynamic` or `Effectful.Internal.*`). The sum of the `%time` columns across those rows must be greater than zero — i.e. the profile is non-trivial. This is verifiable by reading the `.prof` file and grepping for the four module names; for example:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
grep -E '(Kiroku\.Store\.(Append|Effect|SQL))|Effectful\.' kiroku-store-bench.prof
```

The fourth and final acceptance check is that the existing non-profiled benchmark workflow is unaffected. Running `cabal build kiroku-store:kiroku-store-bench` (without `--enable-profiling`) on the same source tree must continue to produce a binary whose `tasty-bench` output for the `append/single-event/AnyVersion (new stream)` cell is within the regression-threshold band documented in `docs/BENCH-REGRESSION.md`. The `ghc-prof-options` field, by Cabal's contract, is only applied to profiled builds, so this check should pass without further work; the verification is a sanity check that the cabal edit was correct.


## Idempotence and Recovery

Every step in this plan is safe to repeat. Editing `kiroku-store/kiroku-store.cabal` to add `ghc-prof-options` is idempotent: re-applying the same edit produces no change. Building with `--enable-profiling` is safe to repeat as many times as needed; Cabal caches the profiled object files in `dist-newstyle/` so subsequent builds are fast.

Running the profiled bench is safe to repeat: each invocation overwrites the `kiroku-store-bench.prof` file in the working directory. There is no risk of corrupting a prior profile other than discarding it. If the prior profile must be preserved, copy it aside (`cp kiroku-store-bench.prof kiroku-store-bench.prof.bak`) before re-running.

The one place where Cabal occasionally misbehaves is when the same `dist-newstyle/` is used for both profiled and non-profiled builds. If a profiled build fails with a complaint about missing profiling versions of dependencies that were just built in the non-profiling way, the safe recovery is to clear the per-target build cache:

```bash
cd /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku
rm -rf dist-newstyle/build/*/ghc-*/kiroku-store-0.1.0.0/b/kiroku-store-bench
cabal build --enable-profiling kiroku-store:kiroku-store-bench
```

That is a per-bench-target clean, not a full nuke. A full `rm -rf dist-newstyle` is correct but expensive, since every dependency (including the profiled and non-profiled versions of `aeson`, `hasql`, `effectful`, and friends) is rebuilt from scratch.

Adding `{-# SCC #-}` annotations to `kiroku-store/src/Kiroku/Store/*` is reversible by deleting the pragmas; they have no effect on a non-profiled build and only insert cost centres in a profiled build, so backing them out cannot break the production code path. If a pragma is added under step 5 of Concrete Steps and the profile turns out not to need it, simply remove it and the Decision Log entry that justified it.


## Interfaces and Dependencies

This plan introduces no new build-depends. The only library required to produce a profile is GHC's built-in profiling runtime, which is part of every GHC distribution. The `tasty-bench` library used by the existing bench is unaffected; its `defaultMain` accepts `+RTS -p -RTS` transparently because every Haskell binary linked with the threaded RTS does.

The cabal-side change is the addition of a `ghc-prof-options: -fprof-auto` field to the `kiroku-store-bench` benchmark stanza at line 108 of `kiroku-store/kiroku-store.cabal`. No new stanza is added (see the Decision Log entry on stanza duplication for the rationale). The existing `kiroku-store-bench` stanza's `ghc-options`, `hs-source-dirs`, and `build-depends` are not changed.

The Haskell-side interface contract at the end of this plan is unchanged. `Kiroku.Store.Append.appendToStream`, `Kiroku.Store.Effect.runStorePool`, `Kiroku.Store.Effect.prepareEvents`, `Kiroku.Store.Effect.buildAppendParams`, `Kiroku.Store.Effect.appendDispatchTx`, and `Kiroku.Store.SQL.appendParamsEncoder` retain their existing type signatures and call sites. The plan may insert `{-# SCC #-}` pragmas inside those bindings under the gating in Concrete Steps step 5, but pragmas affect only the profiling-enabled compile and do not change the function signature or runtime semantics in a non-profiled build.

One optional dependency worth mentioning but deferring: `eventlog2html` is a small Haskell tool that renders GHC's `.eventlog` (heap-profile) output into an interactive HTML page. It would be useful if heap-allocation hotspots become the focus of follow-up work — for example, if the `.prof` reveals `%alloc` numbers that motivate a heap-profile rather than a time-profile. This plan does not require heap profiling; we mention `eventlog2html` so a future plan that does need it can pick the tool up without re-deriving the choice. The corresponding RTS option is `+RTS -h -RTS` (or one of its variants such as `-hc` for closure type, `-hd` for description), which writes an `.eventlog` and an `.hp` file alongside the `.prof`.


## Revision Notes

- 2026-05-18: Initial flesh-out under MasterPlan 3 (`docs/masterplans/3-append-performance-profiling-and-experiment-tracking-methodology.md`), intention `intention_01krxrpv5heny9gs89seas59zm`. Scoped the plan as a two-milestone profiling deliverable: M1 confirms profiled build and `.prof` emission, M2 confirms cost-centre coverage of the production single-event AnyVersion append path. Recorded initial scoping decisions (`-prof` vs `-fprof-late`, single stanza vs separate stanza, no `{-# SCC #-}` in `src/` unless needed) in the Decision Log. Implementation commits under this plan must include the `MasterPlan:`, `ExecPlan:`, and `Intention:` git trailers per the master-plan skill's protocol.

- 2026-05-18: Implementation complete. Added `ghc-prof-options: -fprof-auto` to the `kiroku-store-bench` cabal stanza; the profiled build succeeded and a 3.8 MB `.prof` was captured for the constrained single-event AnyVersion cell and archived under `docs/bench/append-hot-path/single-event-anyversion.prof`. Concrete Steps step 3 was corrected (no `--` separator, `All.` prefix on the pattern). Four new Decision Log entries record the corrections, the choice not to restructure the bench, and the choice not to add `{-# SCC #-}` pragmas; four new Surprises & Discoveries entries record the dominant cost centres, the pre-`defaultMain` setup dilution, the missing `appendParamsEncoder` cost centre (a CAF artefact), and the `appendDispatchTx` zero result (single-stream path bypasses it). Outcomes & Retrospective is filled with the top-five cost-centre table, the one-paragraph reading, and the gap-and-follow-up list.
