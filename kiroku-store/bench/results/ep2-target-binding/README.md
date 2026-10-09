# EP-2 target-binding evidence

These are local PostgreSQL 18.6 correctness and affected-path diagnostics for
plan 82. They are not benchmark-grade Linux acceptance evidence and do not claim
statistical equivalence or unchanged write performance. No remote instance or
lease was used. `summary.json` records source identities and artifact checksums.

`correctness.log` contains the six passing package suites for the functional
implementation at `d2a4032eea789d84d5c630e1f76b02bea9a142e6` (339 store,
24 migration, 38 adapter, 17 tracing, 20 metrics, 22 CLI examples). A subsequent
structural target-mismatch example brings the store suite to 340 examples.
`perf-check.log` records 20 structural examples and 16 controlled comparisons;
`baseline-coverage.log` verifies the 30 historical benchmark names.

The historical telemetry control was the immediate pre-EP2 source
`23a03a1b8b56773a140d0683c4c8d4d34b9d7e36`. The copied control executable was
run before edits. The candidate was `d2a4032`. Both selected
`/category/ || /subscription-checkpoint-inventory/`; the candidate also received
the absolute path to the checked-in baseline CSV. The test harness disables
PostgreSQL durability, so these are exploratory timing observations. The control
passed 11 cells in 261.20 seconds. The candidate passed 10 cells in 329.54 seconds
and timed out the unchanged plain caught-up read at 20,000 streams after 100
seconds. Its partial CSV and full failed transcript are retained; no favorable
replacement sample is substituted. Source inspection shows that timed-out cell
executes unchanged category read SQL, with no subscription initialization or
checkpoint save. The full optimized store suite separately covers its query plan
and bounded-buffer invariant.

Catch-up for 100 category events was 1.250 ms in the local control and 1.427 ms
in the first candidate, while the older checked-in baseline is 2.775 ms. Separate
uncontrolled runs do not establish equivalence. Category forward reads were
794/768 us (control/candidate), exhausted reads 16.67/17.07 us, and inventory
100/10,000 rows was 375 us/37.525 ms versus 388 us/38.888 ms. The CSVs retain every
completed cell, including adverse signals.

The supplementary `kiroku-checkpoint-target-cost` executable compares the
immediate pre-EP2 checkpoint table/statement against the actual production
category-save statement in the same PostgreSQL instance. Both schemas have the
same primary and member-key indexes. Durability is on, with full-page writes,
128 MB shared buffers and replica WAL. Four member rows receive 200 warm-up saves
and three alternating pairs of 2,000 saves per arm. Final row counts, exact cursor
sum and candidate bindings must agree. The first probe overlapped unrelated
benchmark setup and is retained only as `checkpoint-cost-overlapped.log`. The
quiet repeat showed 61.43/66.08, 58.54/63.20 and 57.23/66.94 us per save
(control/candidate), a consistent 7.6–17.0% cost signal. WAL per save was about
198.7/207.0 bytes. This prompted the fixed-kind statement optimization rather
than an acceptance claim.

`local-mixed.json` retains all six original-control mixed trials, their raw stdout
and stderr, executable SHA-256 values and full work counters. The control is
`e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`; the candidate is `d2a4032`. The
harness differs only in validated batch-size construction and the existing
legacy-topology CPP branch. Each trial runs four appenders, pool size 10,
512-character JSON and four category consumer-group members, with batch/checkpoint size 1 and 100
events/s. It warms up for two seconds and measures for 15 seconds; three pairs
alternate arm order. All trials delivered 1,500 events, performed 1,500 checkpoint
updates and drained durable work. Append SQL, round trips and default
instrumentation are unchanged.

Initial mixed point changes were p50 +0.21%, p95 +7.60%, p99 +27.43%, total WAL
+0.065% and allocation +6.01%. `summary.json` retains descriptive paired-log-ratio
95% Student-t intervals (three pairs, two degrees of freedom). Tail intervals
are wide and adverse point estimates are not discarded. Allocation is a clear
local increase against the original control, including both EP1 and EP2. These
short trials do not satisfy the optional strict comparison policy; that policy
has not been changed to make these results pass.

The focused follow-up is pinned to
`66125237a75827783e52f17c7d0a54654a23df3d`. Bound ordinary saves now use fixed-kind
prepared statements: four values for AllStreams and five for Category, instead
of always encoding six values. Both binding columns are still written in the
INSERT and conflict UPDATE; startup and dead-letter writes keep the shared
pair encoder. No target check, extra round trip, index or default instrumentation
was added. `optimized-build.log` records the successful workspace build.
`optimized-correctness.log` passes 340 examples, including all 20 structural
checks for every statement form. The unchanged controlled append paths reuse
all 16 passing comparisons from the initial gate.

`optimized-correctness-first-failed.log` is retained. Its only failure was the
new dead-letter fixture, which treated live state as proof of durable delivery
and cancelled before the save. The corrected fixture waits for the durable
checkpoint before cancellation; it passes in the final suite.

`checkpoint-cost-optimized.log` retains all three same-process pairs: control
64.49/62.51/60.04 us, candidate 81.00/79.05/75.49 us, a repeated local cost of
25.6–26.5%. Equal durable work passed again. Both table layouts and indexes were
checked against the actual bootstrap and migration 0013; subscriptions have no
triggers. This probe cannot establish production append cost, but it also cannot
be reported as checkpoint equivalence or a successful optimization of latency.

`local-mixed-optimized.json` and its driver preserve the six follow-up trials
with the identical workload and original control, including raw output and
binary hashes. Every trial again delivered and durably saved exactly 1,500 events.
The optimized point comparisons are p50 +14.84%, p95 +64.02%, p99 +109.27%, total
WAL +0.181% and allocation +2.34%. The third pair reverses the tail direction;
the descriptive 95% intervals are extremely wide. Allocation’s initial +6.01%
point change was reduced, but append timing remains inconclusive and adverse
samples are retained. See `summary.json` for all interval endpoints, not just
point estimates.

EP2 remains **In Progress**: functional and structural work is complete, while
the repeated checkpoint-save cost and append-performance acceptance are
unresolved under the MasterPlan’s gate. Nothing is released and the gate has not
been weakened. The next step must resolve that cost or record an explicit user
change to the trade-off. This artifact is not an EP6 release acceptance report.
