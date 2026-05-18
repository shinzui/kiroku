---
id: 3
slug: append-performance-profiling-and-experiment-tracking-methodology
title: "Append performance profiling and experiment-tracking methodology"
kind: master-plan
created_at: 2026-05-18T22:10:17Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
---

# Append performance profiling and experiment-tracking methodology

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Plans 21 through 24 (in `docs/plans/`) each attempted to close the gap between Kiroku's single-event append latency (~150 µs hot stream) and the upstream Elixir EventStore / message-db floors. Each plan formed a hypothesis from reading the code, built a candidate, ran `tasty-bench`, and made a keep-or-revert decision from eyeball percent deltas. Several arrived at conclusions that overclaimed what the harness could measure (plan 24's now-trimmed encoder-cost decomposition is the clearest example), and the same shortlist of "remaining candidates" — statement-level triggers, dropping `streams.category`, advisory locks, templated SQL, PL/pgSQL — kept being re-proposed across plans because there was no canonical record of what had already been tried. Plan 22's Surprises & Discoveries records that `stream_events_notify` disabling and `streams.category` removal were both tried informally and helped less than was hoped, but that finding was not discovered until plan 24 was already recommending one of them again.

After this initiative is complete, the project has three durable artefacts that prevent further circling:

1. A Haskell-side profiling harness. A `kiroku-store-bench-profiled` runnable target (or equivalently a documented `-prof` build of `kiroku-store-bench`) produces a `.prof` file whose cost-centre breakdown attributes wall time inside `appendToStream`, `appendToStreamTx`, `buildAppendParams`, `prepareEvents`, `appendParamsEncoder`, the Hasql encoders, JSONB serialisation, and surrounding Effectful interpretation. A short doc names exactly which command to run and how to read the output.
2. A PostgreSQL-side profiling harness. A Haskell or shell harness runs the production append CTE under `EXPLAIN (ANALYZE, BUFFERS, TIMING)` with realistic params against an ephemeral PostgreSQL, and captures the per-CTE-node timings. The same harness enables `auto_explain.log_min_duration` for a bench run so the full append path's plan is recorded for review.
3. A checked-in append-only experiment ledger at `docs/perf-experiment-log.md`, backfilled with the experiments from plans 21 through 24 (the SQL-shape variants in `docs/bench/append-hot-path/`, the singleton trial in plan 22, the `stream_events_notify` and `streams.category` informal trials documented in plan 22's Surprises, the two-round-trip restructure in plan 23, the hasql-overhead probe in plan 24). A short methodology README sits next to it stating the discipline future optimization plans must follow: profile to identify the actual hot spot, check the ledger to avoid repeating known-failed experiments, estimate the expected impact from the profile before proposing the change, and re-run the profile after to confirm or refute the prediction.

In scope: all work under `kiroku-store/bench/`, the `kiroku-store.cabal` benchmark stanza, the new `docs/perf-experiment-log.md` ledger, and a short methodology README (either alongside the ledger or as `docs/PERF-METHODOLOGY.md`). Out of scope: any change to `kiroku-store/src/Kiroku/Store/*`, any change to `kiroku-store/sql/schema.sql`, any new optimization plan. This initiative produces infrastructure, not a faster append. The next optimization plan after this initiative completes is its own MasterPlan or ExecPlan, gated by the methodology established here.


## Decomposition Strategy

The work decomposes by tooling layer, not by file. Each layer has a different toolchain (GHC profiling vs. PostgreSQL `EXPLAIN` vs. plain Markdown), a different verification surface (`.prof` output vs. CTE-node timing JSON vs. a backfilled ledger), and can be built and validated without the others. The three child plans are:

- **EP-1**: Haskell-side profiling harness using GHC's `-prof` and cost-centre annotations. Produces a `.prof` file pointing at where Haskell time goes inside the append path.
- **EP-2**: PostgreSQL-side profiling harness using `EXPLAIN (ANALYZE, BUFFERS, TIMING)` and `auto_explain`. Produces per-CTE-node timings for the production append CTE.
- **EP-3**: The experiment ledger at `docs/perf-experiment-log.md` and the methodology README. Backfills the ledger from plans 21-24 and codifies the discipline future plans must follow.

This split keeps each plan independently verifiable. EP-1 is "done" when running a documented command produces a readable `.prof` file with cost centres covering the append path. EP-2 is "done" when running a documented command produces per-node `EXPLAIN` output for the production append CTE. EP-3 is "done" when the ledger exists with at least the plan-21-through-24 experiments recorded and the README states the discipline.

Alternatives considered. **A single-plan implementation** was rejected because the three layers have unrelated toolchains and unrelated failure modes; bundling them would produce a long plan whose milestones tested unrelated tooling. **Merging EP-3 into EP-1 or EP-2** was rejected because the ledger and README are useful even if either profiling harness turns out harder than expected — the discipline ("check the ledger first") does not require the harnesses to be in place. **Adding a fourth child plan that demonstrates the methodology by re-doing the next-optimization analysis** was rejected as out of scope: that is the first work to come *after* this initiative, gated by it, not part of it. **Splitting EP-2 into "EXPLAIN harness" and "auto_explain configuration"** was rejected because both target the same PostgreSQL profiling surface and share the same harness file; keeping them in one plan avoids cross-plan coordination over a small shared artefact.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Haskell-side append profiling with GHC -prof | docs/plans/25-haskell-side-append-profiling-with-ghc-prof.md | None | None | Complete |
| EP-2 | PostgreSQL-side append profiling with EXPLAIN ANALYZE and auto_explain | docs/plans/26-postgresql-side-append-profiling-with-explain-analyze-and-auto-explain.md | None | None | Complete |
| EP-3 | Append performance experiment ledger and methodology README | docs/plans/27-append-performance-experiment-ledger-and-methodology-readme.md | None | EP-1, EP-2 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies between the three plans. EP-1 (Haskell profiling) and EP-2 (PostgreSQL profiling) act on completely separate toolchains and produce separate artefacts. EP-3 (ledger and README) does not require either harness to exist before it can backfill the experiment log from plans 21-24 or state the discipline future plans must follow.

EP-3 has soft dependencies on EP-1 and EP-2 because the methodology README is more useful when it can name the specific runnable harnesses a future plan should consult ("before proposing an optimization, run `cabal bench … --enable-profiling` and read the .prof"). If EP-3 starts first or finishes first, it can be drafted with placeholder commands and revised once EP-1 and EP-2 land.

All three plans can proceed in parallel. EP-1 is the natural first plan to start if a single contributor works sequentially, because its artefact directly answers the most acute open question raised by plan 24: where inside the Haskell append path does the ~150 µs go. EP-2 is the second-most pressing because PostgreSQL-side per-CTE-node attribution is what every prior optimization plan had to guess about. EP-3 can be picked up at any point, including after EP-1 and EP-2 are partially complete, because the ledger backfill is mechanical reading of existing plans and the README can be revised as the harnesses settle.


## Integration Points

`kiroku-store/bench/Main.hs` is shared by EP-1 and EP-2. EP-1 may add cost-centre annotations (`{-# SCC "name" #-}` pragmas) inside the bench runners and/or add a profiled bench cell. EP-2 may add an `EXPLAIN`-running variant of an existing append cell. Both plans should leave the existing `append/*`, `raw-append-shape/*`, `read/*`, and `concurrent/*` benchmark groups untouched so `just bench-regression` against `kiroku-store/bench/results/baseline.csv` stays meaningful. The integration discipline is additive: each plan's new cells live in a new bgroup (`profiled` for EP-1, `explain` for EP-2 are reasonable names), they do not modify existing cell behavior, and they may use shared helpers (the `EphemeralPg.withCached` setup, the `KirokuStore` pool, `mkRawAppendParams`) without coordinating.

`kiroku-store/kiroku-store.cabal` is shared by EP-1 and EP-2. EP-1 either adds a new `benchmark kiroku-store-bench-profiled` stanza or updates `kiroku-store-bench` to declare `ghc-prof-options`. EP-2 may need to add or pin dependencies for `EXPLAIN` output parsing (a JSON decoder if it uses `EXPLAIN (FORMAT JSON)`; `aeson` is already in scope). Both plans should avoid changing the existing `kiroku-store-bench` stanza's `ghc-options`, `hs-source-dirs`, or `build-depends` in ways that affect the non-profiled bench's measurements.

`docs/perf-experiment-log.md` and `docs/PERF-METHODOLOGY.md` (or equivalent paths inside `docs/`) are owned exclusively by EP-3. EP-1 and EP-2 do not write to them; they may add references to their respective harnesses to the methodology README during EP-3's implementation, but the writes belong to EP-3.

Existing benchmark infrastructure that all three plans should leave alone but may reference: `kiroku-store/bench/results/baseline.csv` (regression baseline, owned by the existing `just bench-baseline` workflow), the `bench-baseline` / `bench-regression` / `bench-regression-threshold` / `bench-regression-pattern` recipes in the repo's `Justfile`, and the existing docs in `docs/BENCH-REGRESSION.md`, `docs/BENCH-GATE3.md`, and `docs/BENCH-HASKELL-APPEND.md`. The methodology README from EP-3 should cross-reference these existing docs rather than restating them.


## Progress

- [x] EP-1: Profiled bench target builds and runs against ephemeral PostgreSQL. — 2026-05-18, `ghc-prof-options: -fprof-auto` added to `kiroku-store/kiroku-store.cabal`; `cabal build --enable-profiling kiroku-store:kiroku-store-bench` succeeds.
- [x] EP-1: Single-event AnyVersion append profile (`.prof`) checked in to `docs/bench/append-hot-path/` or referenced with a documented reproduction command. — 2026-05-18, `docs/bench/append-hot-path/single-event-anyversion.prof` (3.8 MB).
- [x] EP-1: Short doc explains how to read the cost-centre output and what to look for. — 2026-05-18, `docs/plans/25-…` Outcomes & Retrospective contains the top-five cost-centre table and a one-paragraph reading; cross-referenced from `docs/PERF-METHODOLOGY.md` "Where the harnesses live" with the now-final cabal command.
- [x] EP-2: Harness runs the production append CTE under `EXPLAIN (ANALYZE, BUFFERS, TIMING)` and produces per-CTE-node timings. — 2026-05-18, both TEXT (`anyversion-singleton.txt`) and JSON (`anyversion-singleton.json`) outputs archived under `kiroku-store/bench/explain-results/`.
- [x] EP-2: `auto_explain` configuration applied to a bench run; output captured. — 2026-05-18, `auto-explain.csv` (42 KB) captured via PostgreSQL's `logging_collector` + `csvlog` because ephemeral-pg discards postgres's stderr.
- [x] EP-2: Short doc explains how to interpret the per-node timings. — 2026-05-18, `kiroku-store/bench/explain-results/README.md` plus the EP-2 plan's Outcomes & Retrospective name the dominant cost as triggers (~51%), not CTE nodes.
- [x] EP-3: `docs/perf-experiment-log.md` exists with a header explaining the ledger format. — 2026-05-18.
- [x] EP-3: Ledger backfilled with the experiments documented in plans 21-24 (anyversion split, event-count, one-event VALUES, singleton SQL trial, `stream_events_notify` informal trial, `streams.category` informal trial, two-round-trip restructure, hasql-overhead probe). — 2026-05-18, 11 rows total.
- [x] EP-3: Methodology README written stating the discipline future plans must follow and cross-referencing EP-1's and EP-2's harnesses. — 2026-05-18, `docs/PERF-METHODOLOGY.md` with the four-step discipline; cross-references to EP-1, EP-2, and the four `docs/BENCH-*.md` docs.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-3 completed first, before EP-1 and EP-2 had landed. The methodology README
  therefore cites EP-1 and EP-2 harness commands by ExecPlan file path
  (`docs/plans/25-…` and `docs/plans/26-…`) rather than by literal `cabal bench`
  invocation. Once EP-1 and EP-2 land, a small follow-up edit to
  `docs/PERF-METHODOLOGY.md` can replace the "see the plan for the exact
  command" wording with the actual command. Captured as the expected shape of
  the soft-dependency window in this MasterPlan's Dependency Graph; no
  cross-plan rework needed. Evidence: see `docs/PERF-METHODOLOGY.md` "Where the
  harnesses live" section and the Outcomes & Retrospective in
  `docs/plans/27-append-performance-experiment-ledger-and-methodology-readme.md`.

- 2026-05-18: EP-1 surfaced a finding that materially changes the strategic
  reading the methodology should support: the Haskell-side cost of the
  production append path is sub-0.1% of total wall time in the captured
  `.prof`, while STM pool-wait + libpq round-trip together account for ~75%.
  Implication for future plans gated by `docs/PERF-METHODOLOGY.md`: a profile
  showing a Haskell-side cost centre at single-digit `%time` is *already*
  unusual relative to this baseline, and a "let's optimise `prepareEvents` /
  `buildAppendParams`" plan that does not first explain why the cost-centre
  picture differs from EP-1's baseline should be redirected toward
  round-trip-count or pool-contention work instead. Evidence:
  `docs/bench/append-hot-path/single-event-anyversion.prof` flat table (top
  five cost centres) and the EP-1 Outcomes & Retrospective section's
  one-paragraph reading.

- 2026-05-18: EP-1 also surfaced a bench-shape finding that affects EP-2 and
  any future profiling work. `kiroku-store/bench/Main.hs` performs ~10 s of
  unconditional setup (pre-population + B9 pool saturation) before
  `defaultMain` parses its arguments, so `--pattern` constraints do not
  isolate a single bench cell's profile. EP-2's `EXPLAIN ANALYZE` harness
  side-steps this by targeting a single SQL statement against a fresh
  PostgreSQL rather than reusing the bench binary, so it does not inherit
  the dilution. A follow-up that wants pure single-event Haskell profiling
  would need either an additive `profile-only` bgroup or an env-gated
  short-circuit of the heavy setup — out of scope for both EP-1 and EP-2,
  noted here so the methodology README's authors can decide whether to
  spawn a follow-up plan.

- 2026-05-18: EP-2 surfaced a quantitative result that should be the
  starting point of the next optimization plan gated by this methodology.
  From `kiroku-store/bench/explain-results/anyversion-singleton.txt`,
  the single-event AnyVersion path's `Execution Time` of ~2.36 ms breaks
  down as:

    * `stream_events_notify` trigger (`pg_notify`): ~0.69 ms (29%)
    * `stream_events_event_id_fkey` FK trigger: ~0.45 ms (19%)
    * `stream_events_stream_id_fkey` FK trigger: ~0.05 ms (2%)
    * All six append CTEs combined: under 1.0 ms (~30%)
    * Planner + result handoff: ~0.18 ms (8%)

  Implication: a plan targeting *CTE shape* alone (Plan 22's category
  removal, Plan 23's two-round-trip, statement-level triggers, etc.) can
  recover at most ~30% of execution time. The first-class candidates are
  now the named per-row triggers on `stream_events` and the `pg_notify`
  trigger on `streams`. Plan 22's Surprises noted `stream_events_notify`
  disabling helped "less than was hoped"; EP-2 quantifies why — it is
  29%, large enough to matter, but not large enough to close the gap to
  the upstream floors on its own. The methodology README and the
  experiment ledger should reflect this so the next plan starts here.

- 2026-05-18: EP-2 also surfaced two upstream-library quirks worth
  remembering for any future PostgreSQL-side profiling work. (a)
  `ephemeral-pg` discards the postgres process's stderr unconditionally
  (`EphemeralPg/Process/Postgres.hs:78`), making `Config.stderr` a
  no-op. EP-2 routes around this via PostgreSQL's `logging_collector`;
  a future upstream patch to ephemeral-pg would simplify. (b) PostgreSQL
  18.3 on this build empirically needs `log_min_messages = 'log'` for
  auto_explain output to reach the csvlog, even though the documentation
  suggests `warning` (the default) should suffice. Re-verifying on
  other builds and platforms is a candidate cross-check.


## Decision Log

- Decision: Scope this initiative as a methodology and tooling MasterPlan, not an optimization MasterPlan.
  Rationale: The previous four append-perf plans (21-24) all ran benchmarks without profiling and arrived at conclusions whose grounding the harness could not actually support; the same "remaining candidates" list kept being re-recommended. Producing one more optimization plan from that list — even a well-scoped one — would continue the cycle. The intervention is to give future plans the profile evidence and the experiment ledger they need to break out of it.
  Date: 2026-05-18

- Decision: Three child plans by tooling layer, not by file.
  Rationale: GHC profiling, PostgreSQL `EXPLAIN ANALYZE`, and a documentation ledger are unrelated toolchains with unrelated failure modes. Bundling them would produce a long single plan whose milestones tested unrelated tooling. Splitting them more finely (e.g., separating EXPLAIN from auto_explain) was rejected because both target the same harness and shared file. See Decomposition Strategy for alternatives.
  Date: 2026-05-18

- Decision: No hard dependencies between the three child plans.
  Rationale: EP-1 (`-prof`) and EP-2 (`EXPLAIN`) act on disjoint toolchains. EP-3 (ledger and README) can backfill from existing plans 21-24 regardless of whether either harness exists yet, and can be revised once the harnesses settle. Marking soft dependencies on EP-1 and EP-2 from EP-3 preserves the ability to do them in parallel while documenting that the README is more useful with the harnesses in place.
  Date: 2026-05-18

- Decision: Bench cell additions from EP-1 and EP-2 must be additive — they live in new bgroups and do not modify existing cells.
  Rationale: `just bench-regression` against `kiroku-store/bench/results/baseline.csv` is the project's existing perf-gate workflow. If EP-1 or EP-2 changes the measurement behavior of existing cells, that gate becomes meaningless and the regression workflow has to be re-baselined for unrelated reasons. The additive discipline keeps the regression gate stable.
  Date: 2026-05-18

- Decision: Reuse intention `intention_01krxrpv5heny9gs89seas59zm` from plans 22, 23, 24.
  Rationale: The goal — making append-perf work disciplined enough to actually close the gap — is the same intent. Carrying the intention across the master plan and all three child plans preserves the chain. Implementation commits include the `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers per the master-plan skill's protocol.
  Date: 2026-05-18

- Decision: Do not produce a faster append as part of this initiative.
  Rationale: The output is infrastructure (profiling harnesses, ledger, README), not a perf improvement. Any optimization plan that uses this infrastructure is a separately scoped follow-up. Bundling an optimization attempt into this MasterPlan would couple the methodology's success to a particular optimization's outcome, defeating the point of treating the methodology as the primary deliverable.
  Date: 2026-05-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

### Delivered

All three child plans complete in a single day (2026-05-18). The
initiative produced the three durable artefacts promised in
Vision & Scope:

1. **Haskell-side profiling harness** — `ghc-prof-options: -fprof-auto`
   on the existing `kiroku-store-bench` cabal stanza plus the
   reference profile at
   `docs/bench/append-hot-path/single-event-anyversion.prof` and the
   reproduction command embedded in `docs/PERF-METHODOLOGY.md`.

2. **PostgreSQL-side profiling harness** — the new
   `kiroku-store-bench-explain` cabal benchmark whose `Explain.hs`
   produces three artefacts under
   `kiroku-store/bench/explain-results/`: `anyversion-singleton.txt`
   (EXPLAIN ANALYZE in TEXT form), `anyversion-singleton.json` (same in
   JSON), and `auto-explain.csv` (auto_explain capture of a small
   workload). README documents reproduction.

3. **Experiment ledger + methodology README** —
   `docs/perf-experiment-log.md` (11 backfilled rows) and
   `docs/PERF-METHODOLOGY.md` (four-step discipline), both cross-linked
   to the four pre-existing `docs/BENCH-*.md` process docs.

### Quantitative findings the next optimization plan should start from

The two profiling harnesses converged on the same picture from
opposite ends of the wire:

- **EP-1 (Haskell side):** cost centres for `appendToStream`,
  `prepareEvents`, `buildAppendParams`, and the Effectful interpreter
  combined are sub-0.1% of total wall time; STM pool-wait + libpq
  round-trip dominate the flat table at ~75%.

- **EP-2 (PostgreSQL side):** the production `AnyVersion` CTE's
  `Execution Time` of ~2.36 ms is 51% triggers
  (`stream_events_notify` 29% + `stream_events_event_id_fkey` FK
  trigger 19% + a small FK trigger), <30% CTE-node work.

Implication: any optimization plan that wants to move append
latency meaningfully must target *either* the per-row triggers on
`stream_events` and the `pg_notify` trigger on `streams` (a schema
change, not a CTE-shape change), *or* round-trip count / pool
contention (a connection-management or batching change). Pure CTE
reshaping or pure Haskell-side encoder work, even taken to its
maximum, recovers less than half of execution time.

Plans 22 and 24 each independently proposed `stream_events_notify`
disabling and `streams.category` removal as candidates, both
qualitatively recorded as "did not move the needle". EP-2 now
quantifies why: removing one trigger recovers some — but not most —
of the cost. The methodology discipline (`docs/PERF-METHODOLOGY.md`)
exists precisely so the next plan doesn't have to re-derive this.

### Gaps and follow-ups (recorded in child plans' Surprises)

- **EP-1:** the bench's pre-`defaultMain` setup (100K pre-population +
  B9 pool saturation) dominates the Haskell profile, diluting the
  single-event AnyVersion cell. An additive `profile-only` bgroup or
  env-gated short-circuit is a candidate follow-up; out of scope for
  this initiative.

- **EP-1:** `appendParamsEncoder` does not appear as a named cost
  centre (it's a CAF). Per-array JSONB attribution would require
  `{-# SCC #-}` pragmas; gated by a future plan that has already
  identified JSONB encoding as the hotspot it wants to attack.

- **EP-2:** `ephemeral-pg` discards postgres's stderr unconditionally
  (`EphemeralPg/Process/Postgres.hs:78`), forcing the harness to use
  PostgreSQL's `logging_collector` rather than the documented
  `Config.stderr` override. An upstream patch is a candidate.

- **EP-2:** `log_min_messages = 'log'` is empirically required for
  auto_explain output to reach the csvlog on PG 18.3. Cross-platform
  verification (especially Linux) is a candidate cross-check.

### Comparison against the original Vision & Scope

The initiative's Vision said the project would have, after this work,
"three durable artefacts that prevent further circling": the Haskell
profile harness, the PostgreSQL profile harness, and the experiment
ledger + methodology. All three landed; the methodology README's
"profile first → check the ledger → state an expected-impact
hypothesis → re-profile after" discipline now has concrete commands
to invoke for steps 1 and 4. The next append-perf plan that arrives
under this MasterPlan's gate has the data it needs to either justify
or reject the candidates that plans 22-24 kept re-proposing without
evidence.

The MasterPlan's Decision Log entry "Do not produce a faster append as
part of this initiative" held: no `kiroku-store/src/Kiroku/Store/*`
file changed, no `kiroku-store/sql/schema.sql` change, no
optimization plan was bundled. The next append-perf optimization is a
separately scoped follow-up plan, gated by the methodology
established here.
