# Paired metadata release gate

This is the user-authorized follow-up to the inconclusive short sequential tests in
`../2026-10-11-ep97/`. Its independent 60-minute wall-clock budget starts at
`started.txt`; build, diagnosis, lease waits, measurements and shutdown share it.
No production read code changes are made. Existing functional/structural tests and
the 16-case remote workload gate remain valid.

The predeclared protocol is in Plan 97's "Release-blocking paired follow-up" section.
Two fixed trials use separate reset databases and processes: seeds 9701 and 9702,
40 rounds, five cases, ABBA/BAAB orders balanced and shuffled, 1,000 calls per batch,
and a 1,000-call warmup for each distinct metadata action. Identical-code controls
cover both sizes; a fifth case performs 20% extra work in B. All returned fields
are checked, all raw batch timestamps retained, and no observations are dropped.

Each trial must independently pass the unchanged 1.10 legacy limit using the upper
end of its nominal 99% paired interval, identical-code equivalence within 0.95–1.05,
and detection of the 20%-extra-work control. Relative interval half-width must be
at most 3%; order and first/second-half estimates must agree within 5%. Intervals
use the union of circular block-bootstrap results for lengths five and ten, with
20,000 fixed-seed resamples. These are approximate intervals, not universal
performance guarantees. Contiguous resampling retains short-range dependence;
see the primary [CMU bootstrap notes](https://www.stat.cmu.edu/~cshalizi/dst/20/lectures/16/lecture-16.html).

Synthetic checks exercise temporal drift, a 17% slowdown, biased identical-code
controls, missing samples and schedule balance. A small new-payload proof precedes
the two release trials. The original infrastructure lifecycle was already verified.
Every sealed result is checked, and analysis is recomputed from the fetched samples.
No retries merely to obtain a favorable result; failed controls trigger diagnosis
and a documented repair within the same budget. No wider workload matrix.

Expected measured time is about two minutes per trial, plus approximately ten
seconds setup and one second warmup. Complete build/proof/trials/verification/shutdown
is estimated at 15–25 minutes, with the remaining budget reserved for a specific repair.

Run `python3 bench/stream-head-cell/test-paired.py` to test analysis, and use the
existing flake build/publish flow with a committed revision. Controller kinds are
`paired-proof`, `paired-1`, `paired-2`; each has its own journal but shares `started.txt`.
Use `--keep-running` between stages only. See `bench/stream-head-cell/README.md`.

The Linux payload built successfully on the remote builder in 129.73 seconds from
commit `05a11baab7a35335dc38eafd0c9376334e9cc26a`. The frozen control is byte-identical
to the earlier benchmark; no production source or migration differs from `daae3f1`.
The 80-row proof passed with verified manifest, independently reproduced analysis
and lease release. Setup took 8.89 seconds, warmup 0.79 seconds, and measurement
1.62 seconds. That calibration suggests approximately 2–3 minutes sampling per
full trial; sample counts, settings and acceptance rules remain unchanged.

Trial 1 passed all five cases and all order/time checks. Its legacy point ratios
were 1.00503 and 1.00436, with 99% interval upper bounds 1.01932 and 1.01356.
The identical-code controls passed and the known 20% work increase measured 1.20386.
All 800 rows were retained; the sealed manifest and independently recomputed analysis
verified. Setup took 8.77 seconds, warmup 0.83 seconds and sampling 141.18 seconds.
Its owned lease was released before trial 2 was submitted.

## Release decision

**PASS.** Both predeclared independent trials passed every gate. The largest
legacy 99% interval upper bound is 1.01932, below the unchanged 1.10 limit.
No production change, threshold relaxation, dropped sample or favorable retry was
needed. All 1,600 release batches were retained, representing 1,632,000 measured
public reads, plus warmup and the separate 80-batch proof.

| Trial | Stream events | Production / frozen | 99% paired interval |
| --- | ---: | ---: | ---: |
| trial-1 | 100 | 1.00503 | 0.99112–1.01932 |
| trial-1 | 100000 | 1.00436 | 0.99375–1.01356 |
| trial-2 | 100 | 1.00335 | 0.98868–1.01924 |
| trial-2 | 100000 | 0.99520 | 0.98101–1.00728 |

All four identical-code intervals lie within 0.95–1.05. The known 20% work
increase measured 1.20386 and 1.20079, with both lower bounds above 1.18.
Every order/time stability check and the 3% relative interval half-width target
passed. `release-decision.json` retains full bounds and diagnostics; each sealed
`analysis.json` was independently reproduced from its complete raw `samples.csv`.

Trial 2 used 8.99 seconds setup, 0.89 seconds warmup and 152.35 seconds measurement;
total entry time was 162.98 seconds including analysis. Trial 1 sampling took
141.18 seconds. The final six analyzer checks passed in 1.20 seconds, including
nonzero uncertainty and inversion of comparison direction. The last test addition
changed only the test file, not the published sampler or analyzer.

The earlier 1.17 estimate is preserved as an inconclusive short sequential result.
It is not reproduced by the controlled comparisons and does not block release.
The flaw addressed was the comparison design: short independent windows and their
within-window deviation did not establish uncertainty for the ratio. These results
support the stated metadata gate on this cell, not arbitrary deployment loads.
The original 474-test, structural, Haddock and 16-case workload evidence is reused;
no unrelated matrix or local timing was run. Final independent checks confirm all four alpha instances TERMINATED and no
active lease. All three owned leases were released. Strict validation passes for
all 19 ADR concepts and 18 improvement-request concepts.

The follow-up finished in 25.65 minutes within its separately
authorized 60-minute budget; `experiment-summary.json` records exact boundaries.
No remote execution remains active. Plan 97's metadata performance blocker is cleared.
