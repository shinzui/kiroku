---
id: 99
slug: repair-the-append-category-column-workload-cell-and-measure-migration-0012-s-write-cost
title: "Repair the append-category-column workload cell and measure migration 0012's write cost"
kind: exec-plan
created_at: 2026-10-21T14:06:08Z
intention: "intention_01m5fcgrhve7mam08dd9f581h4"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-21T14:06:08Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-25T13:36:13Z
      mode: "implement"
      note: "Implement bounded workload diagnosis, spread validation and measured write-cost evidence"
---

# Repair the append-category-column workload cell and measure migration 0012's write cost

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Migration `0012` (kiroku-store-migrations 0.6.0.0, kiroku-store 0.9.0.0) made
category reads cheap by writing each source stream's category onto every `$all`
junction row and indexing it. That is a trade: every appended event now writes one
more text column and one more index entry. The repository's initial gate for
that cost was the `append-category-column` group of the controlled workload benchmark,
which compares the pre-0012 append statement on a database without the index and
check constraint (the control) against the production statement on a fully migrated
database (the candidate), in one process against one PostgreSQL server, and fails
when the candidate is more than 5% slower.

Before this implementation, that gate had never produced a valid measurement. On 2026-09-25 it reported 1.00x,
1.04x and 1.00x with a spread of about ±100% on a loaded host. On 2026-10-21, on a
quiet host, it reported the control at 54 ms ± 61 ms and the candidate at
3.62 ms ± 25 μs, a 0.07x "pass"; run with only the candidate arm selected the
candidate reported 55.2 ms ± 62 ms, and run with only the control arm selected the
control reported 53.8 ms ± 57 ms. Whichever arm is measured first after the harness
setup pays about 50 ms per iteration with a standard deviation of about 30 ms for its
entire convergence loop, and whichever runs second measures the true cost of 40
single-event appends, about 3.6 ms. The ratio is a function of cell order, and the
comparison's lower bound is zero, so the gate passes without testing anything. Review
record REV-1 in `docs/reviews/kiroku-0-9-category-index-cohort.md` recorded this.

After this plan, `just perf-workload-gate` reports both append arms with a spread a
reader can trust, refuses to pass when either arm is implausible, and the measured
cost of migration 0012's write-path addition is recorded in the performance ledger
with its uncertainty. A consumer asking whether adopting kiroku-store 0.9 slowed its
appends gets a number instead of a shrug.


The subsequent user question asks whether single-event append can be made faster
while keeping the category-read benefit. A benchmark-only feasibility follow-up
uses the current profile: the hot append's `source_links` node is about 7 µs
against 148 µs whole-statement execution, suggesting only a few microseconds of
possible savings from combining two junction INSERTs. A second probe measures
idle-publisher work as an upper bound, preserving all database writes and checks.
Neither probe authorizes disabling subscription behavior in production.


## Progress

Completion validation is now against the independently frozen accepted post-0012
SQL from git `22ac4de`, on matching fully migrated stores. The historical
pre-0012 comparison remains diagnostic. This implements the user's accepted
trade-off without raising the 0.50–1.05 bounds. The final append cells target 1%
relative standard deviation after the initial 5% target produced a false 1.06x
result for identical SQL; rejection still uses the original 20% doubled-spread
limit. Final evidence is retained in
`kiroku-store/bench/results/plan99-completion/`.

- [x] Milestone 1 (2026-10-25): the final batched append comparison passes three consecutive focused runs, approximately 0.98x, 1.00x and 0.99x, all compared spreads below 20%. Evidence: `focused-batched-{1,2,3}.csv`, `focused-batched-summary.json` and the journal in `kiroku-store/bench/results/plan99-completion/`. Formatting alone separates the first from the remaining two; measurement code is identical. Earlier unbatched failures and passes remain retained.
- [x] Milestone 2 (2026-10-25): three consecutive final full workload runs pass all 17 cells and all 16 compared-arm spread checks; accepted append ratios 1.0046x, 0.9895x, 0.9577x. The final run uses `just perf-check` and passes 41 structural examples. Eight parser/recipe tests and 18 transaction/concurrency examples also pass. Evidence: `full-batched-{1,2,3}.log/.csv` and `full-summary.json` in the completion folder.
- [x] Milestone 3 (2026-10-25): the accepted historical 5–6% migration cost remains documented separately from passing validation against the frozen accepted baseline. Guide, ledger, ADRs and plan are reconciled; strict ADR/friction checks pass. FRIC-1 is resolved; FRIC-2 is accepted as the existing unrelated manifest-schema limitation.

Initial execution stopped under the explicit rule in Validation and Acceptance: the first
converged candidate/control ratio exceeded 1.05. No more timing trials were run during that initial execution;
no threshold changed, and no favorable retry replaced this result. The functional
changes are delivered; the repair's repeated-run acceptance and migration write-cost
acceptance remained outstanding at that point. Evidence:
`kiroku-store/bench/results/plan99/README.md`.

At the user's subsequent request, the investigation resumed and included the
requested repeat. It supports a real cost around 5–6%, plus harness noise;
the exact 5% boundary remains unresolved. Fixed-work diagnostics and their
count/plan checks are implemented, with evidence in
`kiroku-store/bench/results/plan99-investigation/README.md`. This investigation
is complete. The user subsequently accepted the measured write cost as a
compromise; normal full-gate validation was still unverified before this completion stage.


## Surprises & Discoveries

`full-prepared-1` passed the pipeline and read gates but again rejected identical
append SQL at 1.06x (3.50 ms versus 3.71 ms), despite low reported spreads.
Thus the tighter target alone does not make the harness reliable. The final
comparison now batches 32 unchanged 40-append units per timed iteration, explicitly
named `accepted-control-append-40x32` / `candidate-append-40x32`; the disposable
cell stays at 40. This reduces the relative contribution of the estimator's fixed
1 ms perturbation and should require less adaptive growth. Both final workload
counts are printed after benchmarking to expose unequal convergence lengths.
This measurement repair subsequently passed three focused and three full runs; no threshold was relaxed.

The tighter four-stream probe measured 360.621 µs sequential versus 330.417 µs
pipeline (0.91624x), with doubled spreads 0.97% / 1.17%: a real miss of the
unchanged 0.90 ceiling on this host. Inspection through Mori showed that the
transaction library prepares BEGIN/COMMIT/ABORT, while the production pipeline
reparsed its BEGIN/COMMIT/ROLLBACK each call. The small production fix makes those
three control statements preparable, preserving transaction boundaries and error
handling. Its first focused probe passed at 0.83x; this is preliminary, with a
19.3% control spread. All 18 existing multi-stream/concurrency examples pass,
including duplicate-event rollback and overlapping transactions. Full validation subsequently passed as recorded below. The source reference is
`mori://hasql/hasql`, project-relative
`hasql-transaction/src/library/Hasql/Transaction/Private/Statements.hs`
(artifact-level URI pending).

Completion validation retained an identical-SQL 1.06x failure with the old 5%
append convergence target (`focused-2`). Tightening only the append target to 1%
then produced three focused passes: 0.971958x, 0.971642x and 1.017089x, with
maximum doubled spreads 3.55%, 4.29% and 4.84%. The 20% rejection bound did not
change, and the estimator may hit its bounded timeout before its tighter target.

The first full completion run (`full-1`) correctly failed the four-stream
pipeline candidate at 2.88 ms ±2.82 ms (8.27x, 97.7% doubled spread), while the
other comparisons passed. Its pools/plans had waited through long append cells.
The pipeline group now acquires a `withResource` warm-up immediately before its
measurements: 20 equal four/eight-stream iterations on both stores, vacuum/analyze,
then one final iteration each. This setup is outside timing; its 0.50–0.90 bounds
and measured workload remain unchanged. The refreshed four-stream pair still
measured a noisy 0.91x near its 0.90 ceiling, so that pair also targets 1%
relative deviation before deciding whether the requirement is actually missed. The resource getter is unused so no
lazy resource thunk reaches a nested STM transaction. All failed attempts remain
in `kiroku-store/bench/results/plan99-completion/`.

On 2026-10-25 the unchanged baseline again passed invalid measurements: control
53.332 ms ±54.058 ms and candidate 28.614 ms ±13.063 ms (0.537x), with
load above 3 and concurrent tests in other repositories. This is diagnostic
evidence only. Raw CSV, command logs and a bounded run journal are retained under
`kiroku-store/bench/results/plan99/`. The first relative CSV path failed because
Cabal changes to the package directory; subsequent commands and the recipe use an
absolute results path.

The plain-shell build could not find GHC 9.12.4. Use
`nix develop --no-write-lock-file -c` before the commands below unless already in
the development shell; see FRIC-1 in `docs/friction-log/`.

A disposable cell alone left spreads of 31.34% / 26.26%. Adding a checkpoint and
vacuum/analyze alone produced a plausible 3.336 ms control but an invalid
52.031 ms ±33.143 ms candidate. Neither attempt was accepted. The 45 one-second
samples in `diagnostic.jsonl` observed zero completed checkpoints and an active
vacuum only once, alongside append and publisher head queries. The root cause
is not proven; setup effects are not merely a global delay absorbed by any first
cell on this host.

Priming all three append stores with 20 untimed workload iterations each, then
checkpointing and vacuuming/analyzing all six databases, produced control
3.327034 ms ±0.277265 ms and candidate 3.521592 ms ±0.265205 ms immediately.
The disposable cell uses its own store so it cannot grow either append arm or
bias the pipeline candidate's fixture. This is one successful convergence check,
not the required three. Its 1.058478x ratio failed and ended the experiment.


The authorized follow-up reproduced one invalid-control ratio (0.7843x) and two
converged failures (1.0554x / 1.0567x) without changing the harness. Thus the
populated/analyzed setup did not eliminate all startup noise. Reading the resolved
benchmark library showed that its estimate uses only the latest n/2n batches,
with a 1 ms timing perturbation; its spread is not a confidence interval for the
candidate/control ratio. Independent convergence can also give growing arms
different database sizes.

Twelve-pair equal-work comparisons alternate arm order and verify the final counts
of both stores (8,082 streams, 16,160 events, 32,320 junction rows). The first
exploratory protocol omitted pre-batch GC and produced false overhead even for
identical SQL; those samples are retained. Matching tasty's pre-batch collection
produced identical-code 0.9986x and full-migration 1.0489x. The user's requested
repeat produced identical-code 0.9692x with a retained control spike and
full-migration 1.0644x, positive in all 12 pairs and similar in either order.
This supports a real 5–6% cost, while preserving uncertainty at the exact gate
boundary and without claiming GC caused the original startup defect.

The component comparison measured 1.0437x for the column/statement change with
index and CHECK absent in both stores, and 1.0029x for adding index/CHECK with
identical production SQL. The sampled plans have identical scan/join structure;
`$all` rows grow from 72 to 79 bytes for this category, and their insert adds
87 WAL bytes and one WAL record in both sampled cases. Most measured overhead
therefore points to the SQL/category value path rather than index maintenance
alone; the experiment does not separate RETURNING from tuple construction.


The append-speed feasibility follow-up tested a merged junction INSERT three
times: 0.9639x initially, then 0.9971x and 0.9951x. The initial benefit depended
on early control spikes and did not reproduce meaningfully. Both arms retained
the full category index/CHECK and all foreign keys. A separate subscriber-free
upper-bound probe stopped only the candidate publisher worker: 0.9364x, 0.9689x,
0.9945x across unchanged runs, also not a dependable gain. Stopping it violates
the existing idle cursor advancement contract, so even its best sample cannot
be promoted as an implementation. Every pair and database count check passed;
these are negative/inconclusive performance findings, not a production change.


## Decision Log

- Decision: Fix repeated parsing of the pipeline transaction-control statements
  rather than changing its 0.90 ceiling after a precise 0.91624x failure.
  Rationale: The existing transaction library prepares the same control statements.
  Applying that approach preserves the production transaction structure; existing
  atomicity, rollback and concurrency tests plus the full gate verify it.
  Date: 2026-10-25

- Decision: Complete the gate against a frozen, accepted post-0012 append
  implementation, keeping the pre-0012 statement and comparison in diagnostic
  modes. Use fully migrated stores for both authoritative append arms and retain
  the original 0.50–1.05 ratio bounds and 20% spread guard.
  Rationale: The user accepted the existing migration cost and explicitly asked
  to finish this plan. Comparing every future candidate with the pre-0012 schema
  would repeatedly reject that accepted design; increasing an arbitrary ceiling
  would mix acceptance with a new regression budget. Freeze the accepted SQL
  from git 22ac4de, independent of the current production statement. This is a
  declared baseline change for the accepted trade-off, not a retrospective pass
  for the old comparison or permission for later regressions. Validate three
  focused runs and three full runs, with the last full run through perf-check,
  inside one budget from 16:26:53 to 17:26:53 UTC. Preserve every failed attempt.
  Date: 2026-10-25

- Decision: Accept migration 0012's measured roughly 5–6% single-event append
  latency cost as a compromise for the category-read improvement, and retain the
  category column/index.
  Rationale: After reviewing the measured cost and the unsuccessful small
  optimization probes, the user explicitly directed: "let's mark the regression
  as an accepted compromise then". The read benefit is bounded category reads
  instead of probing every stream (about 60,000 to 6 buffers at 20,000 streams).
  This closes the known write-cost acceptance decision. It preserves all adverse
  measurements and uncertainty, the original 1.05 comparison ceiling, and the
  distinction between accepted trade-off and passing gate evidence. Additional
  regressions need their own decision; further optimization of this cost is optional.
  Date: 2026-10-25

- Decision: Keep the append-speed follow-up benchmark-only and retain the category
  index, CHECK, foreign keys, one-round-trip append and publisher contract.
  Rationale: The user asked whether single-event append can be faster after
  considering the category-read trade-off. Consulted the profiles and ledger;
  rejected re-running scalar singleton and two-round-trip ideas already tested.
  Tested merged junction INSERTs and the idle-publisher upper bound in 12-pair,
  equal-work runs, three unchanged runs each. Neither demonstrated a dependable
  shipping improvement. The budget was one hour from 14:27:10 UTC, including
  profiling, build and repeats; measurements ended at 14:38:03 UTC.
  Date: 2026-10-25

- Decision: Resume diagnosis of the adverse result without changing promotion
  bounds or discarding the failed sample.
  Rationale: On 2026-10-25 the user explicitly asked whether the regression was
  real or the harness was wrong. Run three unchanged focused gates, then 12
  alternating fixed-work pairs (32 iterations per arm) and an identical-code
  negative control. Component comparisons follow only if needed for attribution.
  The investigation has one 60-minute budget from 13:56:36 UTC, including setup,
  builds and repeats; target 10–20 minutes and retain unresolved uncertainty.
  Date: 2026-10-25

- Decision: Continue measurements on the available machine, retaining actual host
  load and the original spread and ratio bounds.
  Rationale: On 2026-10-25 the user directed continuing because the machine is
  powerful enough. The quiet-host precondition is waived for this execution;
  convergence is still required, and uncertainty cannot be relabelled as a pass.
  Date: 2026-10-25

- Decision: The repair is accepted on the stated numeric criterion, not on a root cause.
  Rationale: The user's standing guidance (`AGENTS.md`) is to spend the minimum evidence
  needed for the actual change. If a throwaway cell or a quiescence wait removes the
  effect in three consecutive runs, that is sufficient; attribution is recorded if it
  falls out of the diagnosis but is not required.
  Date: 2026-10-21
- Decision: Timing evidence comes only from the same-process gate under the host conditions
  authorized for this execution; the
  historical CSV comparison (`just bench-regression`, `just perf-telemetry`) is not
  used to accept or reject anything in this plan.
  Rationale: ADR-5 makes the historical tier telemetry only, and the keiro review of
  2026-10-21 lost time to exactly that kind of absolute comparison.
  Date: 2026-10-21


## Outcomes & Retrospective

Plan 99 is complete on 2026-10-25. The final batched harness passed three focused
runs (0.9780x, 0.9987x, 0.9920x) and three consecutive full runs (1.0046x, 0.9895x, 0.9577x);
all ratio bounds are unchanged and maximum compared doubled spread is 9.63%.
The final `perf-check` also passes 41 structural examples. Eight parser/recipe
checks, 18 existing transaction/concurrency examples, exact SQL snapshot checks
and strict ADR/friction validation pass. The production change prepares only the
three multi-stream transaction-control statements; category SQL/schema and
subscription behavior are unchanged. The required formatter also reformatted the
touched interpreter; a token comparison verifies no other production code change.

The accepted ~5–6% migration write cost is preserved as a separate historical
trade-off. The new frozen SQL baseline protects subsequent SQL changes, while
future schema/index costs need schema-aware controls. Batching and nearby warm-up
produce repeated operational gate passes on this host; unequal adaptive database
growth and ratio uncertainty remain explicit limitations. All failed and noisy
attempts remain retained in `kiroku-store/bench/results/plan99-completion/README.md`.
The completion stage finished within its original 16:26:53–17:26:53 UTC budget.
No new friction was recorded; FRIC-1 remains resolved and FRIC-2 accepted.

Historical execution and investigation outcomes follow.

Historical migration-cost acceptance decision (2026-10-25): the user explicitly accepted the existing
roughly 5–6% append cost as a compromise for the category-read improvement.
Migration 0012's category column/index is retained, and further optimization is
optional. ADR-10, ADR-11 and an appended ledger row record the decision. The
adverse samples and statistical uncertainty remain unchanged. This closes the
known regression's acceptance question; the original 1.05 comparison, outstanding
harness convergence checks and absence of a full-gate pass remain accurately
reported. No benchmark rerun or code/budget change was needed to record acceptance.

On 2026-10-25 the gate gained a disposable first cell, a populated/analyzed setup,
append ratio floors of 0.50x, and a fail-closed CSV check on all 16 compared arms.
The frozen control and production statements are unchanged. Seven parser/recipe
tests pass, including corruption of every arm and preservation of a benchmark's
nonzero status; all 41 structural examples pass. Final benchmark compilation and
strict ADR/friction bundle validation pass. The full timed recipe and aggregate
were not rerun after the adverse result; neither has passing acceptance evidence.

The first converged comparison observed +5.85%, above the unchanged +5% gate.
The append timing experiment stopped at 13:46:22 UTC, about 11 minutes after its
13:35:27 start, including builds and rejected attempts. This follows the explicit
adverse-stop branch, not completion of the normal three-run criterion. A consumer
adopting 0.9 now has a retained, plausible but single-run adverse measurement:
3.327034 ms to 3.521592 ms per 40 appends, with doubled standard deviations of
0.277265 ms and 0.265205 ms. The 8.33% / 7.53% spreads exceed the effect being
estimated, so these are not a confidence interval, proof of a reproducible
regression, or a universal 5.85% migration cost. Further performance acceptance
requires a separate decision; do not raise the ceiling or discard this sample.

ADR-5 now records why both arms and the ratio need safeguards. The new ledger
row explicitly revisits the inconclusive 2026-09-25 G4 row. FRIC-1 in
`docs/friction-log/` is resolved: the plan and gate guide now document the Nix
environment required by the commands. FRIC-2 is accepted: whole-manifest Dhall
validation fails on the pre-existing `versionConstraint` dependency-helper/schema
mismatch, reproduced on the original HEAD manifest. Strict validation of both
bundles passes; the unrelated dependency-schema migration is outside this plan.


Follow-up (2026-10-25): the user authorized further diagnosis and explicitly
requested another attempt. The unchanged gate reproduced two usable failures,
and matched-work comparisons measured +4.89% and +6.44%, supporting a real cost
around 5–6%. Identical-code comparisons also expose continuing runtime/host
noise. Most measured cost persists without the index/CHECK; the exact 5% boundary
remains unresolved. Optional `paired`, `paired-aa`, `paired-column`,
`paired-index-check` and `explain` modes now reuse the frozen/production statements,
verify work/database counts and retain plans without replacing the promotion gate.
ADR-5 and ADR-10 and an additional ledger row carry this qualification. All raw
samples, including noisy and exploratory ones, are retained in the investigation
folder. Timing ended at 14:12:10 UTC, about 16 minutes into the single one-hour
investigation budget; no further timing trials were needed to answer the user's
question. Full-gate acceptance and a production optimization remain outside the
completed diagnosis. No additional friction occurred.


Append-speed follow-up (2026-10-25): the user's question was investigated with
existing profiles/ledger, one current instrumented profile and two bounded
benchmark-only probes. Neither showed a reliable improvement across three
runs. No production code, schema, subscriber behavior or gate bound changed.
The merged INSERT and stopped-publisher variants remain optional evidence, with
all samples in `kiroku-store/bench/results/plan99-append-probe/README.md` and two
new ledger rows. Further work needs a targeted profile/design, especially if
optimizing idle publisher bookkeeping without weakening subscriber attachment.
For callers, `appendToStream` already avoids an unnecessary explicit transaction
when no atomic projection writes are needed. Timing ended about 11 minutes into
the one-hour budget; no additional timing was needed. ADR-5 and ADR-10 were
reviewed for distillation; no new architecture decision was made. No additional
friction was recorded.


## Context and Orientation

Kiroku is a PostgreSQL event store written in Haskell. The package `kiroku-store`
holds the store library; its benchmarks live under `kiroku-store/bench/`. A
"controlled workload gate" is a benchmark executable that runs a control
implementation and the production candidate in the same process against databases on
the same PostgreSQL server and compares their mean wall-clock times. "Same process"
matters because host drift, compiler changes and background load then affect both arms
alike, which is what makes the ratio trustworthy.

The gate is `kiroku-store/bench/RegressionGate.hs`, built by the Cabal stanza
`kiroku-store-bench-workload-gate` in `kiroku-store/kiroku-store.cabal` (around line
220) and run by the `perf-workload-gate` recipe in the root `Justfile`:

```bash
cabal bench kiroku-store:kiroku-store-bench-workload-gate --benchmark-options="--stdev 5"
```

`main` in `RegressionGate.hs` does all setup before handing the benchmark tree to
`tasty-bench`'s `defaultMain`: it starts one shared ephemeral PostgreSQL server
(`withSharedMigratedPostgres` from `kiroku-test-support/src/Kiroku/Test/Postgres.hs`,
which uses the `ephemeral-pg` package's default configuration with the temporary root
pinned under `/tmp/ephpg-kiroku-<uid>`), creates six migrated databases (two for the
pipelined multi-append group, three for the append-category group (including the disposable store) through
`withAppendCategoryStores`, and the category-scaling store through
`withCategoryScalingStore`, which seeds 20,200 streams and tens of thousands of events
from `Kiroku.Test.Fixtures.CategoryScaling`), runs 20 warm-up iterations on each append-category store and one on each pipeline
workload, checkpoints and vacuums/analyzes the databases, and only then calls `defaultMain`. The benchmark tree has three groups:
`append-accepted-category`, `append-multi-stream` and `category-read`. In the
`append-accepted-category` group, `accepted-control-append-40x32` runs
`runAppendWorkload` with `acceptedCategoryAppendAnyVersion`, a frozen literal of
the accepted post-0012 SQL from git `22ac4de`, against the control store;
`candidate-append-40x32` runs the production
`SQL.appendAnyVersion` against the candidate store; each comparison iteration repeats 32 units, each appending one event to
each of 20 fresh streams and then 20 events to one hot stream (1,280 appends total). Means therefore describe a batch; the ratios are unchanged. The disposable first cell
uses its own sixth database; it cannot alter either measured arm. The comparison is
`bcompareWithin 0.5 1.05 "accepted-control-append-40x32"`, which makes `tasty-bench` fail the
candidate when `candidate mean / control mean` is outside `[0.5, 1.05]`.

`tasty-bench` runs cells sequentially in tree order and reports `mean ± 2σ`. With
`--stdev 5` it keeps iterating a cell until the estimated relative standard deviation
is below 5% or it gives up; a cell reported with a spread larger than its mean did not
converge. The two authoritative append arms override the CLI target with 1%;
the four-stream pipeline pair also targets 1%, while the disposable cell and remaining comparisons retain 5%. The CSV spread guard remains 20%.
`--csv FILE` writes the results as CSV; the implementer must inspect the
header line of such a file to learn the exact column names before parsing it, because
they differ from criterion's.

The relevant performance process documents are `docs/PERF-REGRESSION-GATES.md` (the
three tiers and the commands), `docs/PERF-METHODOLOGY.md` (the five steps every
append-performance experiment follows, including pre-registration and the ledger), and
`docs/perf-experiment-log.md` (the append-only ledger; its header defines the row
columns Date, Plan, Hypothesis, Variant, Bench Numbers, Outcome, Lesson). The ledger's
2026-09-25 rows for plan 91 record the G3 read gate and the G4 write gate; the G4 row's
lesson is "Expected ≤ 3%, observed 0% to 4% with noise larger than the effect. The gate
passed but did not resolve the cost; repeat on a quiet host."

Relevant ADRs, all under `docs/adr/`:
[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes structural checks
and controlled same-process workloads the authoritative performance tiers and the
historical CSV telemetry only; this plan adds the lesson that a controlled gate must
also check both of its arms. [ADR-10](../adr/0010-category-reads-use-a-denormalized-category-index-on-all-rows.md)
records the 0012 design and names the write cost as the accepted trade.
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
states that reproducible event-append regressions block release and that reports must
separate practical acceptance from statistical equivalence. No cross-repository ADR
applies.

The experiment budget rules in the repository's `AGENTS.md` apply to every timed run in
this plan: a 60-minute wall-clock budget per experiment stage including builds and
repeats, reported before a stage starts, and no silent weakening of a gate.


## Plan of Work

The original measurement phase and follow-up investigations above are historical
evidence. The user has accepted migration 0012's measured cost and requested
completion of the remaining harness/gate work. The current implementation path
therefore protects the accepted post-0012 SQL and keeps the earlier comparison
as a diagnostic. Do not reinterpret the original failures as passing evidence.

Milestone 1 verifies the final batched append cell on three consecutive focused runs. Batch 32 unchanged 40-append units per measured iteration to reduce the estimator's fixed 1 ms perturbation relative to the measurement; print final counts, and retain the single-unit disposable warm cell.
Both stores are fully migrated, receive identical 20-iteration setup workloads,
and are vacuumed/analyzed after a checkpoint. A third store supplies the first,
disposable timed cell. The accepted control is a literal snapshot from git
`22ac4de`; it must not alias `SQL.appendAnyVersion`. Keep the pre-0012 literal
unchanged for historical diagnostics, whose modes explicitly remove the relevant
index/CHECK before seeding. The final append cells use a 1% relative-deviation
target after an identical-SQL 1.06x false failure at 5%. They must still satisfy
the original 20% doubled-deviation rejection bound and 0.50–1.05 ratio bounds.

Milestone 2 verifies the public recipe and aggregate. The pipeline group uses
`withResource` to refresh both stores at measurement time, after the long append
cells: 20 equal four/eight-stream iterations, vacuum/analyze and one final
iteration each, all outside timing. This repairs the unconverged arm observed
in `full-1` without changing its workload or ratio bounds. Preserve CSV results by
unique run name, require all 16 comparison arms, and reject malformed, missing,
duplicate, non-finite or noisy results. The checker must name each offending
cell and the 20% bound. The parser/recipe tests deliberately corrupt every arm
and preserve nonzero benchmark status; they also reject an old historical
control substituted for the new accepted control. Run the full workload gate
three times on the final source, with the third run through `just perf-check`
so structural checks run once at the same boundary. The three full invocations
then include exactly three executions of `perf-workload-gate`, avoiding an
unnecessary fourth benchmark. Stop on failed validation and retain its evidence;
never replace a failed trial with an unreported favorable retry.

Milestone 3 closes the plan only after the evidence is verified. Keep the
existing adverse measurements and accepted-compromise ledger row. Add a final
completion row that distinguishes validation against the accepted control from
the historical migration-cost result. Update ADR-5/ADR-10, the gate guide and the
living sections, validate the ADR/friction bundles strictly and triage any new
friction. The discovered four-stream miss is addressed by preparing the production transaction-control statements; validate existing multi-stream and concurrency examples before full timing. No category-read design change is required.
The entire completion experiment has one budget from 16:26:53 to 17:26:53 UTC,
including builds, failed attempts, repairs, validation and documentation.


## Concrete Steps

Run from the repository root, using the Nix development environment for the
required GHC/PostgreSQL toolchain. Use a unique CSV/log name for every invocation
and preserve failed attempts. The original host-quiet restriction was explicitly
waived by the user; retain actual load and the declared wall-clock budget.

```bash
nix develop --no-write-lock-file -c cabal build \
  kiroku-store:kiroku-store-bench-workload-gate kiroku-store:kiroku-store-test
python3 kiroku-store/bench/test-gate-spread.py
nix develop --no-write-lock-file -c cabal bench \
  kiroku-store:kiroku-store-bench-workload-gate \
  --benchmark-options="--stdev 5 -p /append-40/ --csv $PWD/kiroku-store/bench/results/plan99-completion/focused-new.csv"
```

Repeat the focused command three times with distinct output names. Expected
output includes `warm-append-40`, `accepted-control-append-40x32` and
`candidate-append-40x32` under `append-accepted-category`, with candidate/control
within 0.50–1.05 and both compared arms' doubled deviation at most 20% of mean.
A focused CSV contains these three rows and is verified separately; the public
complete-CSV checker correctly rejects a focused file as missing other groups.
The append arms target 1% despite the CLI's 5% setting for other groups.

Run two full recipe invocations, retaining each generated CSV before the next
one replaces it, then run the aggregate for the third full invocation:

```bash
nix develop --no-write-lock-file -c just perf-workload-gate
nix develop --no-write-lock-file -c just perf-check
```

The expected full output is 17 passing tests and:

```text
gate spread OK: every compared arm within 20% of its mean
```

The aggregate additionally runs the existing `performance structure` examples.
The parser/recipe test command above verifies deliberate noisy-arm rejection,
header-based parsing, complete coverage, historical-control exclusion and
preservation of a benchmark failure even when the CSV is valid.

Historical cost diagnostics still use the unchanged pre-0012 SQL:

```bash
nix develop --no-write-lock-file -c env KIROKU_GATE_DIAGNOSE=explain \
  cabal bench kiroku-store:kiroku-store-bench-workload-gate
```

Unset `KIROKU_GATE_DIAGNOSE` for authoritative checks. Finish with:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/friction-log --strict --profile docs/friction-log/profile.dhall --profile-enforce --log-enforce
git diff --check
```


## Validation and Acceptance

Milestone 1 requires three consecutive focused runs of the final measurement code (format-only changes do not invalidate samples) with
both append arms' doubled standard deviation at most 20% of mean and ratio
within 0.50–1.05 against the frozen accepted post-0012 control. Preserve mean,
spread, ratio, actual load, command, exit status and source hashes for each run.
A failed earlier attempt remains retained and is not silently counted as a pass.

Milestone 2 requires three full passing workload runs of that same source;
the final run through `just perf-check` supplies aggregate/structural validation.
The CSV checker must pass every compared arm. Its tests must demonstrate noisy
arm rejection with the cell name/bound, reject historical-control substitution,
and preserve nonzero benchmark status. The accepted SQL literal must match the
production statement at git `22ac4de`, while the pre-0012 literal is unchanged.

Milestone 3 requires the final ledger/guide/ADR and living-plan updates plus
strict ADR/friction validation. The user's accepted roughly 5–6% historical
write-cost compromise remains explicitly separate from the new gate's passing
results. No old ratio, sample, uncertainty or failure status changes. The ratio
bounds are unchanged; the declared frozen accepted baseline is the policy
integration authorized by the user's acceptance and request to finish the plan.
This checks later SQL changes on a shared current schema; a future schema/index
cost needs a separate schema-aware comparison.


## Idempotence and Recovery

Every benchmark run creates fresh ephemeral databases and removes them on exit;
`ephemeral-pg` reaps clusters abandoned by killed runs on the next start, so an
interrupted run needs no cleanup beyond rerunning. The ledger is append-only: never edit
the 2026-09-25 rows; a wrong new row is corrected by appending another row that cites
it. The ADR amendment is additive; if validation fails, fix the frontmatter rather than
reverting the paragraph. Repeating any step is safe.


## Interfaces and Dependencies

`tasty-bench` (Bodigrim/tasty-bench) provides `bench`, `bgroup`, `bcompareWithin`,
`localOption WallTime`, `--stdev`, `--csv` and `-p`; `WallTime` is required because
database work waits on the server and must not be measured as CPU time. `hasql-pool`
and `hasql` run the statements through `Pool.use` and `Session.statement`.
`Kiroku.Store.SQL.appendAnyVersion`, `appendParamsEncoder` and `appendResultDecoder`
are the production statement and its codecs; `preCategoryAppendAnyVersion` in the gate
is the historical frozen control and must not be edited. The authoritative
`acceptedCategoryAppendAnyVersionSQL` is an independent literal frozen at git
`22ac4de`, using the same codecs; it must not follow subsequent production edits. `Kiroku.Test.Postgres.withSharedMigratedPostgres`
and `withMigratedTestDatabase` provide the server and databases. The `Justfile`
recipes `perf-workload-gate` and `perf-check` are the public entry points that
`docs/PERF-REGRESSION-GATES.md` documents and that release work runs. No new library
dependency is expected; the spread check is a shell script reading CSV.

Revision note (2026-10-25): use the Nix development environment and absolute CSV
paths; retain the user's authorization to continue on the active host without
weakening the numeric convergence or ratio criteria.

Revision note (2026-10-25): retain the failed warm-only and quiescence-only
attempts, prime each append store equally before analyze, isolate the disposable
store, and record the first converged ratio as an adverse stop. Three-run and
full-gate acceptance remain unclaimed.

Revision note (2026-10-25): follow the user's authorization to investigate the
adverse result and try again; add matched-work/identical-code/component and
exact-statement plan diagnostics, retaining every result and the unresolved
promotion boundary. This does not replace the original adverse row or bounds.

Revision note (2026-10-25): record the user's append-speed question, the
profile-grounded merged-INSERT and publisher upper-bound probes, their three-run
negative/inconclusive evidence and the unchanged production contracts.

Revision note (2026-10-25): record the user's explicit acceptance of the
existing migration 0012 write cost as a category-read trade-off. Preserve raw
evidence, uncertainty, original gate bounds and unverified harness checks.

Revision note (2026-10-25): on the user's request to finish the plan, protect
the accepted post-0012 implementation with an independently frozen SQL control
and retain the historical cost comparison as a diagnostic. Numeric bounds and
workload/structural guards are unchanged; validate the final gate end to end.
