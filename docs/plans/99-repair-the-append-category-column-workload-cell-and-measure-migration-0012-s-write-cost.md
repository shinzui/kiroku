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

That gate has never produced a valid measurement. On 2026-09-25 it reported 1.00x,
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

- [ ] Milestone 1: the position effect is characterized with evidence, and a repair is chosen by the stated criterion (both arms' doubled standard deviation within 20% of their means in three consecutive runs of the cell).
- [ ] Milestone 2: the repaired gate is self-checking: a throwaway cell absorbs setup effects, the compared cells carry a lower bound, and a spread check fails the recipe when an arm is noisier than the stated bound; `just perf-workload-gate` passes three times in a row with both append arms plausible.
- [ ] Milestone 3: the measured ratio and its spread are recorded as a new row in `docs/perf-experiment-log.md` that cites the 2026-09-25 G4 row, the gate documentation describes the new checks, and ADR-5 carries the lesson.


## Surprises & Discoveries

(None yet beyond the observations in Purpose; add evidence snippets here as the
characterization proceeds.)


## Decision Log

- Decision: The repair is accepted on the stated numeric criterion, not on a root cause.
  Rationale: The user's standing guidance (`AGENTS.md`) is to spend the minimum evidence
  needed for the actual change. If a throwaway cell or a quiescence wait removes the
  effect in three consecutive runs, that is sufficient; attribution is recorded if it
  falls out of the diagnosis but is not required.
  Date: 2026-10-21
- Decision: Timing evidence comes only from the same-process gate on a quiet host; the
  historical CSV comparison (`just bench-regression`, `just perf-telemetry`) is not
  used to accept or reject anything in this plan.
  Rationale: ADR-5 makes the historical tier telemetry only, and the keiro review of
  2026-10-21 lost time to exactly that kind of absolute comparison.
  Date: 2026-10-21


## Outcomes & Retrospective

(To be filled during and after implementation.)


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
pipelined multi-append group, two for the append-category group through
`withAppendCategoryStores`, and the category-scaling store through
`withCategoryScalingStore`, which seeds 20,200 streams and tens of thousands of events
from `Kiroku.Test.Fixtures.CategoryScaling`), runs one warm-up iteration of each
workload, and only then calls `defaultMain`. The benchmark tree has three groups:
`append-multi-stream`, `append-category-column` and `category-read`. In the
`append-category-column` group, `control-append-40` runs `runAppendWorkload` with
`preCategoryAppendAnyVersion` (the pre-0012 statement copied verbatim from git
`12d50d5`) against the control store, and `candidate-append-40` runs the production
`SQL.appendAnyVersion` against the candidate store; each iteration appends one event to
each of 20 fresh streams and then 20 events to one hot stream. The comparison is
`bcompareWithin 0 1.05 "control-append-40"`, which makes `tasty-bench` fail the
candidate when `candidate mean / control mean` is outside `[0, 1.05]`.

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
(load average below 3, no other builds), and add one row to
`docs/perf-experiment-log.md` with the three control and candidate means, their
spreads and ratios, outcome `kept`, and a lesson that cites the 2026-09-25 G4 row and
states expected (at most 3%) against observed. Then amend ADR-5 with one dated
paragraph under Consequences: a controlled workload gate must bound both arms'
spread and the plausibility of the ratio, because an invalid control arm can produce a
vacuous pass. Bump the ADR's `timestamp`, add an `okf log add` entry, and run the strict
ADR validation. Finally, note in the Outcomes section what the number means for a
consumer that adopted kiroku-store 0.9.


## Concrete Steps

All commands run from the repository root. Build everything once; the first build
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

Milestone 2 is accepted when `just perf-workload-gate` passes three times in a row on a
quiet host with the throwaway cell present, when deliberately corrupting one arm (for
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
