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
more text column and one more index entry. The repository's authoritative gate for
that cost is the `append-category-column` group of the controlled workload benchmark,
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


## Progress

- [ ] Milestone 1: the populated-and-analyzed setup removed the large effect in one focused run (2026-10-25), with spreads 8.33% / 7.53%; three consecutive confirmations remain unperformed because that run exceeded the ratio ceiling and triggered the adverse stop.
- [ ] Milestone 2: the disposable cell, ratio floors, complete-CSV spread checker and recipe are implemented; seven parser/recipe tests and 41 structural examples pass. Three full gate passes and end-to-end `perf-check` acceptance remain unmet under the adverse stop.
- [x] Milestone 3 (adverse-result branch, 2026-10-25): the failed 1.058478x ratio and its uncertainty are recorded in the ledger, the guide describes all checks, ADR-5 is amended, and strict ADR validation passes. Normal three-run performance acceptance was not achieved.

Execution stopped under the explicit rule in Validation and Acceptance: the first
converged candidate/control ratio exceeded 1.05. No more timing trials were run,
no threshold changed, and no favorable retry replaced this result. The functional
changes are delivered; the repair's repeated-run acceptance and migration write-cost
acceptance remain outstanding for a separate decision. Evidence:
`kiroku-store/bench/results/plan99/README.md`.


## Surprises & Discoveries

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


## Decision Log

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
`append-multi-stream`, `append-category-column` and `category-read`. In the
`append-category-column` group, `control-append-40` runs `runAppendWorkload` with
`preCategoryAppendAnyVersion` (the pre-0012 statement copied verbatim from git
`12d50d5`) against the control store, and `candidate-append-40` runs the production
`SQL.appendAnyVersion` against the candidate store; each iteration appends one event to
each of 20 fresh streams and then 20 events to one hot stream. The disposable first cell
uses its own sixth database; it cannot alter either measured arm. The comparison is
`bcompareWithin 0.5 1.05 "control-append-40"`, which makes `tasty-bench` fail the
candidate when `candidate mean / control mean` is outside `[0.5, 1.05]`.

`tasty-bench` runs cells sequentially in tree order and reports `mean ± 2σ`. With
`--stdev 5` it keeps iterating a cell until the estimated relative standard deviation
is below 5% or it gives up; a cell reported with a spread larger than its mean did not
converge. `--csv FILE` writes the results as CSV; the implementer must inspect the
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

Execution note (2026-10-25): the first converged ratio triggered the explicit
adverse stop. The implementation additionally primes the growing append tables
before analyze; the diagnostic evidence and incomplete acceptance are recorded
above. The remaining normal-path instructions below are retained for a future
separate decision and were not silently treated as passing.

Milestone 1 characterizes the effect just enough to choose a repair. The first
hypothesis to test is the cheapest: the first cell measured after `defaultMain` starts
overlaps work the shared server is still doing after setup (the category-scaling seed
is large; autovacuum and the checkpointer run for a while afterwards), and a throwaway
timed cell placed first in the tree would absorb it. The second hypothesis is that an
explicit quiescence step after setup, `CHECKPOINT` plus `VACUUM (ANALYZE)` on the
scaling database followed by waiting until `pg_stat_progress_vacuum` is empty, removes
it. A side connection sampling `pg_stat_activity`, `pg_stat_progress_vacuum` and the
checkpointer statistics view once per second during the first cell will usually show
which it is; the sampler can live behind an environment variable in the gate
(`KIROKU_GATE_DIAGNOSE=1`) or in a throwaway script, and need not be committed. The
milestone ends when a candidate repair makes both append arms converge (doubled
standard deviation at most 20% of the mean) in three consecutive focused runs of the
cell; record the evidence under Surprises & Discoveries whichever way it goes. Keep
the whole milestone inside one 60-minute budget; a full gate run takes about 160 s and a
focused `-p /append-40/` run about 80 to 140 s on a quiet host, including setup.

Milestone 2 makes the gate self-checking so this cannot recur silently. Three changes
land in `kiroku-store/bench/RegressionGate.hs` and the `Justfile`. First, the
repair from milestone 1 (the throwaway cell `warm-append-40` as the first entry of the
`append-category-column` group, or the quiescence step in `main`, or both). Second,
the compared append cell gets a lower bound: `bcompareWithin 0.5 1.05`, so a control
that is more than twice as slow as the candidate fails loudly instead of passing. The
category-read cells keep their lower bound of zero because the candidate is genuinely
expected to be far faster there; the two pipeline cells may also take 0.5 since their
expected ratio is about 0.87. Third, the `perf-workload-gate` recipe passes
`--csv` to a results file under `kiroku-store/bench/results/` and then runs a new
`kiroku-store/bench/check-gate-spread.sh` that reads the CSV by column name and exits
non-zero when any arm of a compared pair has a doubled standard deviation above 20% of
its mean; `just perf-check` therefore fails on an unconverged arm. The script must
state the bound and the offending cell in its failure message, and
`docs/PERF-REGRESSION-GATES.md` must describe the new failure meaning in the
controlled-workload row of its table.

Milestone 3 records the result. Run the repaired gate three times on a quiet host
(load average below 3, no other builds unless explicitly waived by the user (as on 2026-10-25); record actual load), and add one row to
`docs/perf-experiment-log.md` with the three control and candidate means, their
spreads and ratios, outcome `kept` only if accepted, and a lesson that cites the 2026-09-25 G4 row and
states expected (at most 3%) against observed. Then amend ADR-5 with one dated
paragraph under Consequences: a controlled workload gate must bound both arms'
spread and the plausibility of the ratio, because an invalid control arm can produce a
vacuous pass. Bump the ADR's `timestamp`, add an `okf log add` entry, and run the strict
ADR validation. Finally, note in the Outcomes section what the number means for a
consumer that adopted kiroku-store 0.9.


## Concrete Steps

All commands run from the repository root inside `nix develop --no-write-lock-file`
(or prefix each command with `nix develop --no-write-lock-file -c`). Build everything once; the first build
without a `dist-newstyle` directory takes several minutes.

```bash
cabal build kiroku-store:kiroku-store-bench-workload-gate kiroku-store:kiroku-store-test
```

Reproduce the defect before changing anything, so the repair has a baseline:

```bash
uptime
cabal bench kiroku-store:kiroku-store-bench-workload-gate \
  --benchmark-options="--stdev 5 -p /append-40/"
```

Expected output today (the control's spread is the defect):

```text
    control-append-40:   OK
      54.0 ms ±  61 ms
    candidate-append-40: OK
      3.62 ms ±  33 μs, 0.07x
All 2 tests passed (136.59s)
```

Run each arm alone to confirm the position effect on the implementer's host:

```bash
cabal bench kiroku-store:kiroku-store-bench-workload-gate \
  --benchmark-options="--stdev 5 -p /candidate-append-40/"
cabal bench kiroku-store:kiroku-store-bench-workload-gate \
  --benchmark-options="--stdev 5 -p /control-append-40/"
```

Both should report about 54 ms ± 60 ms. If the candidate alone converges at about
3.6 ms on the implementer's host, the effect is host-dependent; record that under
Surprises & Discoveries and continue with the throwaway-cell repair anyway, because the
2026-10-21 host reproduced it five times.

For the diagnosis, a side sampler can be as small as this loop run from a second shell
against the gate's server while the first cell is measuring (the server's socket
directory is printed by `ephemeral-pg` under `/tmp/ephpg-kiroku-<uid>`; `psql -l`
against it lists the databases):

```bash
for i in $(seq 1 60); do
  psql "host=/tmp/ephpg-kiroku-$(id -u)/<cluster>/sock dbname=postgres" -Atc \
    "select now(), (select count(*) from pg_stat_progress_vacuum), (select count(*) from pg_stat_activity where state <> 'idle')"
  sleep 1
done
```

After the repair, the focused run must look like this (figures illustrative; the
candidate is expected within a few percent of the control):

```text
    warm-append-40:      OK
      ...
    control-append-40:   OK
      3.55 ms ±  40 μs
    candidate-append-40: OK
      3.64 ms ±  38 μs, 1.03x
All 3 tests passed
```

The spread check and the recipe:

```bash
just perf-workload-gate
```

```text
All 17 tests passed (...)
gate spread OK: every compared arm within 20% of its mean
```

A failing spread check must print the cell name, its mean, its doubled standard
deviation and the bound, and exit 1.


## Validation and Acceptance

Milestone 1 is accepted when Surprises & Discoveries holds the sampler or run evidence
and three consecutive focused runs of the repaired cell report both append arms with a
doubled standard deviation at most 20% of their means.

Milestone 2 is accepted when `just perf-workload-gate` passes three times in a row under the user-authorized host conditions with the throwaway cell present, when deliberately corrupting one arm (for
example by running the recipe while a `cabal build` of another package is in progress)
makes the spread check fail with a message naming the cell, and when
`just perf-check` still passes end to end. Also run `cabal test kiroku-store:kiroku-store-test --test-options='--match "performance structure"'`
to confirm the structural tier is untouched.

Milestone 3 is accepted when the new ledger row exists with three ratios and spreads,
`okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce`
passes after the ADR-5 amendment, and `docs/PERF-REGRESSION-GATES.md` describes the
spread check. The measured ratio is reported as what it is: three same-process ratios on
one host with their spreads, not a universal guarantee. If the ratio exceeds the 1.05
ceiling, the gate fails and the plan stops at that fact; do not raise the ceiling.
Report it in Outcomes and in the ledger as an adverse finding for a separate decision.


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
is the frozen control and must not be edited. `Kiroku.Test.Postgres.withSharedMigratedPostgres`
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
