# Plan 97 implementation evidence

This directory retains local PostgreSQL 18.6 correctness/baseline evidence and
remote PostgreSQL 18.3 / GHC 9.12.4 timing evidence for
[Plan 97](../../../plans/97-expose-stream-head-global-position-through-an-opt-in-metadata-read.md).
Baseline production source: `109d58f57dbd5757ad55792474d046a37cc2e87d`.
Frozen fixtures and full metadata interpreter: `25b0b8e`.
The candidate adds only the opt-in originated-head read. No migrations or legacy
statement, decoder, handler or StreamInfo changes are included.

The experiment started at the UTC timestamp in `started.txt`, with one 60-minute
budget covering baseline, compilation, setup, recovery, candidate and aggregate
gates. `stages.jsonl` records command durations and remaining budget. The user subsequently authorized remote timing because the local host was busy;
the original deadline still applies and no configuration matrix was added.

The fixture has 1,000 interleaved 100-event streams, one 100,000-event stream and
an empty stream: 200,000 events and 400,000 junctions. All arms share one migrated
database. Setup, ANALYZE and VACUUM run outside measurement. Each cell warms 100
calls, then measures batches of 100 public-runner calls. All six metadata fields
are forced by equality to the validated fixture metadata; heads are also checked.

The two legacy gates compare production metadata with the frozen effect handler,
pool error mapping, statement, decoder and runner. Their maximum ratio is 1.10.
Metadata-plus-head cells are diagnostic additional functionality. All timing uses
wall time, 5% relative standard deviation and 60 seconds per cell. Tasty's printed
and CSV uncertainty is **twice** standard deviation; divide it by twice the mean
to check the 5% target.

Baseline: 448 existing tests and 13 frozen statement/column checks passed.
Metadata ratios were 0.987 and 0.988; all four cells met the precision target.
`baseline-cost.log` is the failed pre-measurement attempt: Cabal changed directory,
so a relative CSV path did not exist. `baseline-cost-2.log` and `baseline.csv` are
the successful absolute-path retry (14.69 seconds measurement).

`functional.log` preserves a compile failure from an ambiguous Async `wait` name;
`functional-2.log` has 26 passing focused cases after qualification. `query-plans.json`
extracts its complete literal and warmed prepared EXPLAIN JSON. Both populated
sizes use seven execution shared buffers, empty six, missing two. Missing streams
execute the origin probe zero times. Natural prepared plans used generic parameters
after six executions. No planner settings were forced.

Candidate source is `daae3f1ab6b27f8de5d1ba2deed1c3fd5a65e16a`.
All local packages build, all 474 store tests pass, and the final 26 focused tests
pass after deriving lifecycle expectations from append results or the global log.
`source-review.json` records unchanged legacy decoder/encoder bodies and dispatch.

The local candidate timing was interrupted during build, before any timing cells,
after the user offered remote-cell infrastructure. Remote actions copy the exact
`StreamHeadCost.hs` and `RegressionGate.hs` from the committed candidate into an
isolated payload. The only replacement is the fixture lifecycle: the cell owns five
fresh PostgreSQL databases and reset/cleanup; no ephemeral database runs on the driver.
Both remote executables use GHC 9.12.4 and `-N4 -A32m`. The original aggregate's
structural half is covered by the passing full suite; its unchanged workload half
runs on the cell. No claim is made that the literal local `just perf-check` command
was run on the busy host.

Remote build preparation retained a relative-flake-path failure and a short-revision
failure; the successful build used a full pinned local Git revision. Publication
initially lacked `zstd`; the retry uses the existing flake's pinned package. None
of these failures executed a measured trial. The focused results below retain both successful and failed measured trials.

The user reported a very busy local host before candidate timing; no local timing
retry ran. The one unchanged remote repeat followed the plan's bounded failure
policy, with the first failure retained and thresholds unchanged.

Haddock generation and strict ADR/IR bundle validation pass. Remote setup retained
client failures for empty-lease handling, explicit project selection and an outdated
cellctl binary. The rebuilt CLI comes from the registered infrastructure source;
no infrastructure source changes were made. The rejected submission ran no trial.
The setup attempt's owned lease was released, and all four instances reached TERMINATED.
Alpha was then leased by another inspection-validation owner; that lease was left
alone. After alpha became available, the proof completed with a verified sealed
manifest and owned-lease release. Its single measured case had 4.95% relative
standard deviation; the entry took 10.40 seconds (9.02 seconds fixture setup).
The proof journal retains an earlier acquisition error alongside its final verified
status; command history and retained controller logs distinguish these attempts.


Remote focused results (microseconds per public call; each sample batches 100 calls):

| Trial | Events | Frozen metadata | Production metadata | With head | Legacy ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| remote-head | 100 | 156.43 | 147.79 | 167.69 | 0.945 |
| remote-head | 100000 | 149.67 | 174.57 | 174.37 | 1.166 |
| remote-head-repeat-1 | 100 | 187.15 | 177.03 | 198.14 | 0.946 |
| remote-head-repeat-1 | 100000 | 163.69 | 163.18 | 173.72 | 0.997 |

Both trials met the 5% relative-deviation target for every cell. The first failed
the 100,000-event legacy ratio; its unchanged repeat passed. Per the declared
conflicting-evidence rule, **metadata performance acceptance is inconclusive**.
No further head trial is run merely to obtain a passing result. Opt-in timings are
diagnostic; they do not establish a universal overhead percentage. These are
networked public-runner calls on one PostgreSQL 18.3 cell, not SQL-only timings.

The first head trial used 8.60 seconds setup, 0.109 seconds warmup and 2.56 seconds
measurement (11.30 seconds total entry). The repeat used 8.62 seconds setup,
0.123 seconds warmup and 2.11 seconds measurement (10.90 seconds total entry).
During the first run's full observation window, driver CPU busy time averaged 1.99%
and PostgreSQL 4.54%, with zero recorded steal ticks; this does not rule out
short-term latency variation. All three sealed runs and owned-lease releases
(proof plus two focused trials) are verified. The existing workload gate passed all 16 cases with every cell meeting the 5%
relative-deviation target. Its entry took 15.06 seconds, including 10.42 seconds
measurement. Pipeline append ratios were 0.747 and 0.721 against a 0.90 limit;
category-column append was 1.007 against 1.05. All five category-read ratios passed
their original limits. `remote-gate-summary.json` records exact ratios. Four sealed
runs are now verified in total, with every owned lease released. Final independent checks confirm all four alpha instances TERMINATED and no
active lease (`final-power.json`, `final-lease.stderr`). Full strict validation passes for all 19 ADR concepts and
18 improvement-request concepts.

The complete experiment, including setup failures, waiting, repeats, verification
and shutdown, ended after 44.95 minutes, within the original
60-minute budget. `experiment-summary.json` records its exact boundaries. No remote
execution remains active. Functional and structural acceptance and the existing
workload gate pass; legacy metadata timing acceptance remains open.
