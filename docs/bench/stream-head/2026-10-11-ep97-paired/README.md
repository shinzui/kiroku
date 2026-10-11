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
