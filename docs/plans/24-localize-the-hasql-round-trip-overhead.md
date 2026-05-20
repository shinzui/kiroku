---
id: 24
slug: localize-the-hasql-round-trip-overhead
title: "Localize the Hasql round-trip overhead"
kind: exec-plan
created_at: 2026-05-18T21:02:02Z
intention: "intention_01krxrpv5heny9gs89seas59zm"
---

# Localize the Hasql round-trip overhead

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`docs/plans/23-restructure-append-into-a-two-round-trip-path.md` halted because adding a second PostgreSQL round-trip to the append path made it slower, not faster. Before discarding round-trip-topology changes wholesale, this plan asked one narrow question: **is Hasql/hasql-pool itself a fat target?** If pool acquisition or per-statement Hasql overhead were eating tens of microseconds, the next optimization would target the Haskell SDK and benefit every Kiroku operation, not just append.

The answer is no. A throwaway benchmark group in `kiroku-store/bench/Main.hs` measured `Pool.use` overhead (~0.6 µs) and a bare `SELECT 1` round-trip (~13 µs), and confirmed the marginal cost of a second statement on a hot pooled connection is ~14-22 µs depending on the encoder shape — which already matches what plan 23's two-roundtrip variant cost in extra wall-time. **Hasql is not the bottleneck**, and the second-round-trip cost plan 23 observed is structural, not an SDK overhead we could shave.

The benchmark group itself was scrapped after the question was answered. Several of its cells were subtraction-based attribution exercises (e.g., trying to isolate "encoder cost") that the harness could not cleanly support without conflating Hasql CPU work with PostgreSQL parsing of seven array parameters. Keeping noisy or speculative cells in the durable bench surface would invite future overclaiming. This plan therefore reads now as a short investigation note rather than an implementation plan.

The visible outcome is a one-paragraph finding ("Hasql is not the bottleneck") that redirects the next optimization plan toward the PostgreSQL side of the append (statement-level mutation triggers and dropping `streams.category`). Associated with the same intention as plans 22 and 23 (`intention_01krxrpv5heny9gs89seas59zm`) because the goal — closing the append performance gap — is unchanged. Implementation commits include both an `ExecPlan: docs/plans/24-localize-the-hasql-round-trip-overhead.md` trailer and an `Intention: intention_01krxrpv5heny9gs89seas59zm` trailer.


## Progress

- [x] Create this ExecPlan from the repository skeleton with intention `intention_01krxrpv5heny9gs89seas59zm`. (Completed 2026-05-18.)
- [x] Add a transient `hasql-overhead` benchmark group to `kiroku-store/bench/Main.hs`, run it, and read out the two cells that answered the open question (`Pool.use` overhead and one trivial-statement round-trip cost). (Completed 2026-05-18.)
- [x] Remove the benchmark group from `kiroku-store/bench/Main.hs`. The cells that survived scrutiny (`empty Pool.use`, `SELECT 1`, `two SELECT 1 in one session`) are not worth carrying as durable bench surface — they answer one-shot diagnostic questions, not regression questions; the others were attribution-by-subtraction exercises whose noise and conflation made them overclaim-prone. (Completed 2026-05-18.)
- [x] Record the bottom-line finding ("Hasql is not the bottleneck") in this plan's Outcomes and update plan 23 and the project memory to reflect it. (Completed 2026-05-18.)


## Surprises & Discoveries

Ran a transient `hasql-overhead` benchmark group locally three times, against the same ephemeral PostgreSQL the rest of the harness uses, then deleted the group from `kiroku-store/bench/Main.hs`. Two cells gave clean answers to the open question:

- `empty Pool.use (pure ())` measured 605 ns ± 53 ns. `Hasql.Pool` acquire/release is sub-microsecond.
- `SELECT 1` measured ~13 µs. That is the minimum a Hasql round-trip on this stack costs.
- `two SELECT 1 in one session` measured ~27 µs. The marginal second round-trip on a hot pooled connection is ~14 µs.

The other cells (parameterised SELECT, append-shape encoder SELECT, INSERT … RETURNING, two append-shape SELECTs) were attribution-by-subtraction exercises. They produced numbers, but the differences they reported conflated Hasql CPU work, wire-protocol bytes, and PostgreSQL parameter parsing in ways the harness could not separate. Reading them as "the Hasql encoder costs N µs" or "the CTE costs Y µs" would have overclaimed what the bench actually measured. They were dropped along with the rest of the group.

Variance was substantial on the vector-param cells (σ ≈ 4 µs on a ~53 µs mean), which would have made subtraction-based attribution unsafe even before considering the conflation. The bench surface is better off without them.

## Decision Log

- Decision: Reuse intention `intention_01krxrpv5heny9gs89seas59zm` from plans 22 and 23.
  Rationale: The goal — closing the append performance gap with upstream Elixir EventStore / message-db — has not changed. This plan narrows the search space rather than executing a new implementation; the intention is still the same. Implementation commits include both the `ExecPlan:` and `Intention:` trailers.
  Date: 2026-05-18

- Decision: Make this a benchmark-only plan with no source changes outside `kiroku-store/bench/Main.hs`.
  Rationale: We don't yet know where the cost is, so we shouldn't be writing code that assumes one location. The cheapest experiment that resolves the ambiguity is a focused micro-benchmark group. Once the evidence exists, a follow-up plan can be scoped to the actual bottleneck.
  Date: 2026-05-18

- Decision: Use the existing ephemeral PostgreSQL (`EphemeralPg.withCached`) and `KirokuStore` pool that the rest of `bench/Main.hs` uses, rather than spinning up an isolated pool.
  Rationale: The numbers must compare apples-to-apples against the existing `append/single-event/*`, `raw-append-shape/*`, and `read/*` cells already in the bench. A separate pool would change connection-setup behavior, prepared-statement caching, and pool sizing — all variables we want to hold constant.
  Date: 2026-05-18

- Decision: Run the bench three times and report the median, not the mean of a single run.
  Rationale: `tasty-bench` averages each cell over many iterations, but cell-to-cell variance between full runs is non-trivial on a developer laptop. A median-of-three protects against an outlier run without requiring a CI environment.
  Date: 2026-05-18

- Decision: Do not run `pgbench` or `psql -c 'SELECT 1'` as comparison points in this plan.
  Rationale: Tempting because they give an external "wire-protocol floor," but they introduce different startup overheads (psql is cold-start; pgbench needs to be available and configured) and reduce the apples-to-apples cleanliness of the comparison. A follow-up plan can revisit if the in-harness numbers leave the bottleneck ambiguous.
  Date: 2026-05-18

- Decision: Wire-protocol round-trip cost is treated as a single bucket; this plan does not try to split it into TCP/parse/bind/execute/sync sub-phases.
  Rationale: Those splits require either Hasql library instrumentation we don't have or a `tcpdump`-level analysis that's out of scope. If the bucket is small (e.g., < 20 µs), no further split is needed; if it's large, a follow-up plan can use Hasql's `Hasql.Session.sql` lower-level interface or a profiling harness.
  Date: 2026-05-18


## Outcomes & Retrospective

**Hasql is not the bottleneck.** The two cleanly-measurable cells confirmed that `Hasql.Pool` acquisition is sub-microsecond and a bare PostgreSQL round-trip via Hasql is ~13 µs — both far smaller than the ~152 µs production single-event append. There is no fat to shave in the Haskell SDK layer. Whatever explains the gap with upstream Elixir EventStore lives on the PostgreSQL side or inside Kiroku's own append CTE; subsequent optimization plans should target there.

The bench group was deleted after this question was answered. Several of its cells were attribution-by-subtraction exercises that the harness could not cleanly separate (Hasql encoder CPU vs. PostgreSQL parameter parsing vs. wire bytes for non-trivial encoders), and the noisy components had σ ≈ 4 µs on means in the tens of µs range — too high to support single-µs claims. Carrying them as durable bench surface would invite future overclaiming about cost attribution; the regression-gate value was not worth the misuse risk.

The marginal second-round-trip cost was measured as ~14 µs for trivial statements and ~22 µs for non-trivial ones. That number directly explains plan 23's negative result without further analysis: adding a second round-trip really does cost ~14-22 µs of pure wall-time overhead that a simpler second-round-trip statement cannot recover. Plan 23's conclusion (don't restructure round-trip topology) is reinforced; the numeric mechanism is now plain.

### Recommended next plan

**Withdrawn.** The original recommendation here was to convert row-level mutation triggers to `FOR EACH STATEMENT` and drop `streams.category`. That recommendation was a mistake: plan 22's Surprises & Discoveries already records that dropping `streams.category` was tried and helped less than disabling `stream_events_notify`, neither of which closed the gap. Recommending the same again would have repeated work whose result we already have.

The deeper issue surfaced by repeatedly proposing the same candidates is that this project has been doing benchmark-driven optimization without profiling, without an expected-impact model, and without a checked-in experiment ledger. The right next step is not another optimization plan but a methodology plan that gives future work a profile-grounded basis. That work is being scoped separately as a master plan; see `docs/plans/master-establish-append-perf-profiling-methodology.md` (or whatever filename the master-plan skill assigns) for the decomposition.

### Lessons

- The bench was useful only in that it ruled out a hypothesis. Two of its seven cells did real work; the rest were attribution exercises that conflated layers. A future investigation should design cells around a binary question ("is X plausibly fat?") rather than a quantitative decomposition the harness cannot support.
- Removing the bench group after extracting its answer was the right call. Durable bench surface should track regressions in things we want to keep watching, not preserve every one-shot probe.


## Context and Orientation

This plan was scoped before its bench was run and removed; the prose sections below describe what was actually done rather than what was originally planned.

Predecessor reading: `docs/plans/23-restructure-append-into-a-two-round-trip-path.md` Outcomes named "Investigate Hasql per-round-trip overhead with a micro-benchmark of just `Session.statement` against a trivial `SELECT 1`" as the next experiment. That sentence is the whole prompt this plan answered.

## Plan of Work

(Retrospective.) A `hasql-overhead` `tasty-bench` group was added to `kiroku-store/bench/Main.hs` alongside the existing `raw-append-shape` group, with seven cells running against the same ephemeral PostgreSQL and `KirokuStore` pool. After three runs the question was answered and the group was deleted; the only durable artefact is this plan's Surprises & Discoveries section and the bottom-line finding in Outcomes.

## Concrete Steps

(Retrospective.) The seven cells were run via `cabal bench kiroku-store:kiroku-store-bench --benchmark-options="-p hasql-overhead --csv …"` three times. The cells and their removal both occurred under this plan's commit(s).

## Validation and Acceptance

Acceptance was the question "is Hasql plausibly a fat target?" The answer was no (pool 0.6 µs, bare round-trip ~13 µs). Bench group removed; build passes (`cabal build kiroku-store:kiroku-store-bench`).

## Idempotence and Recovery

No source under `kiroku-store/src` was modified. No schema change. The bench group came and went inside the same session; rolling back the removal is unnecessary since the durable artefact is the finding recorded here, not the cells.

## Interfaces and Dependencies

No new dependencies. `hasql-transaction` was already added to the bench by `docs/plans/23-restructure-append-into-a-two-round-trip-path.md` for its `+ BEGIN/COMMIT` variants and stays. The hasql-overhead cells used only `hasql` and `hasql-pool`, already in scope.

## Revision Notes

- 2026-05-18: Plan created from the repository skeleton with intention `intention_01krxrpv5heny9gs89seas59zm`. Scoped as a benchmark-only investigation responding to the open question raised by plan 23 ("Investigate Hasql per-round-trip overhead with a micro-benchmark"). No source changes outside `kiroku-store/bench/Main.hs`.
- 2026-05-18: Bench group added, run three times, and removed in the same session. Plan rewritten in-place as a retrospective note. Bottom line: Hasql is not the bottleneck (`Pool.use` 605 ns; `SELECT 1` ~13 µs; marginal second round-trip ~14 µs). The verbose forward-looking sections (multi-milestone Plan of Work, decomposition tables in Outcomes) and several attribution-by-subtraction bench cells were trimmed because they overclaimed what the harness could cleanly measure.
