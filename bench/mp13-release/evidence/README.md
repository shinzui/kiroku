# MP13 release preparation — 2026-10-11

EP-7 is **In Progress**. No package metadata has been applied, no tag or package
has been published, and IR-8 through IR-12 remain in progress. The exact proposal
is [release.patch](release.patch); it is built in an isolated copy rather than
changing the checkout's approved release versions.

## Concrete release proposal

| Package | Released | Proposed | Reason |
| --- | --- | --- | --- |
| kiroku-store | 0.10.0.0 | 0.11.0.0 | Closed Store effect constructors and Subscriber field change |
| kiroku-metrics | 0.2.0.0 | 0.3.0.0 | Exported config and protocol constructor changes; inspection API and executable |
| kiroku-store-migrations | 0.7.0.0 | 0.7.1.0 | Additive migration 0015; runner API preserved |
| kiroku-cli | 0.2.0.9 | 0.2.0.10 | Store dependency bound only |
| kiroku-otel | 0.2.0.11 | 0.2.0.12 | Store dependency bound only |
| shibuya-kiroku-adapter | 0.6.0.0 | 0.6.0.1 | Store dependency bound only |

The patch includes every affected existing internal bound, all six dated
changelogs, and the appended store 0.10-to-0.11 upgrade blueprint (blueprint 0.3.0).
External bounds are preserved. Newly introduced ServerProviders is not falsely
listed as a breaking change to a previously published type. The local release
skill requires confirmation of this concrete proposal before applying or
committing release metadata. Proposed dates must be refreshed if publication
occurs on a later local date.

Hackage preferred-version records and upstream tags establish released commit
`364ffa82136fcfc83d39ead1234abffaf500844b` as the original control. Source archives
in `sdist/` contain integrated source `30307c1ed1606551fe108c24888aa4230924efca`
plus only the proposed metadata/blueprint. `proposal.json`, `archives.json` and
`documentation-archives.json` identify staging paths and SHA-256 hashes.
`proposal-before-cache-fix/` retains the preceding proposal and source archives.
The mutable temporary build directories are conveniences, not durable evidence.

## Functional and packaging evidence

- All six functional children are Complete; `child-acceptance.txt` preserves
  their progress and outcomes.
- Fresh `cabal build all -j1` and all six suites pass **672 examples**. After the
  batch-proportional name-cache change, all **116 metrics examples** pass again.
- Flake/treefmt, capability, ADR and improvement-request validations pass.
- All six proposed `cabal check` invocations pass. All six source archives
  contain their license/changelog/cabal metadata; the metrics archive includes
  `app-inspect/Main.hs` and migrations includes `0015.sql`.
- The final isolated full build and Nix executable build succeed. Both Cabal
  and Nix executable help checks pass; the new-provider and every legacy-starter
  consumer fixture compile against the final proposed cohort.
- Haddock generation succeeds and all six documentation archives contain an
  index. The upgrade blueprint validates; earlier upgrade edges are preserved.

All setup/build errors are retained. Reusing the previous build directory after
relocating the proposal caused vector unit-identity errors, resolved by a fresh
build directory rather than an API or bound workaround. An initial archive
inspection assertion failed; corrected member-name checks verify every required
file and all six documentation indexes. No package files
were changed to accommodate these tooling errors.

## Performance evidence and limits

The whole local experiment uses the original **03:24:23–04:24:23 UTC** budget,
including setup, builds and follow-ups. No remote run or remote lease was started.
No threshold, baseline or policy was changed. Raw samples, failures and
journals are retained; no completed trial is replaced by a favorable retry.

The first `perf-check.log` passes structural invariants and 15/16 workload cases.
Category append fails at 1.57x with very large variance while compilation and
other repository work are observed. Three unchanged focused repeats all pass
(`category-gate-repeats.json`); their high variance remains visible. The final unchanged aggregate check (`final-perf-check.log`) finishes in
210.03 seconds with structural checks passing and **14/16 workload cases
passing**. Pipeline eight is 1.31x (1.71 ± 1.8 ms versus 1.30 ± 0.07 ms);
category append is 6.25x (48.3 ± 50 ms versus 7.74 ± 0.886 ms). These are retained
failed gates with high variance, not waived failures or a proven cause. No more
timing retries are launched. The shared host cannot resolve the inconsistent
signals from these full and focused runs; quiet controlled evidence is required.

A durable PostgreSQL 18.6 observer proof delivers 54,227 events exactly, resolves
27,116 names and completes 48 HTTP polls. Two preceding setup/proof attempts
remain retained. Every comparison checks exact tail delivery, HTTP statuses,
raw percentiles/throughput, more than 4096 candidate stream names and durability.
The external dependency versions of both arms match exactly.

The initial `local-comparison/` (12 verified trials; 567,808 measured appends)
and `cache-fix-comparison/` (6 trials; 208,352 appends) are **confounded**: the
candidate client alone retained names in the server's process. Their adverse
estimates are retained but are not production regression diagnoses. Investigation
also found full retained-cache key enumeration for every small batch; commit
`30307c1` replaces it with membership checks over requested IDs. Cache limits,
lookup count and wire behavior are preserved; ADR-15 records the constraint.

The corrected `matched-client-comparison/` uses identical client bookkeeping
in both arms, retaining original stream IDs and event positions; candidate also
checks name presence. All **6 trials**, **296,504 measured appends**, **355,809
tail events** and **296 HTTP responses** verify. Active effects and descriptive
95% intervals on three log-ratio pairs are:

| Metric | Candidate change | Descriptive interval |
| --- | ---: | ---: |
| Throughput | +4.968% | -15.138% to +29.839% |
| Append p50 | -0.250% | -2.762% to +2.326% |
| Append p95 | -12.257% | -47.540% to +46.755% |
| Append p99 | -21.676% | -70.418% to +107.374% |

These are exploratory local diagnostics, **not cumulative release acceptance**.
Owned compilation is stopped during the corrected comparison, but other host
work (including active VMs) remains. Two-second warmup and ten-second measurement
are short; observers and writers share a process. Lookup count/cache retention
and actual SQL buffers are not dynamically recorded by this harness. Existing
child correctness/structural evidence does not turn these timings into a
controlled-host original-control verdict. The earlier disabled comparison is
also retained; no further repeat is warranted solely to seek favorable numbers.

The authoritative workload gate remains **failed** and must pass before release.
Cumulative observer acceptance remains **inconclusive**. Publication requires a focused
controlled-host comparison or an explicit practical acceptance of these stated
limitations, as allowed by EP-7. Exact-version installation from Hackage and final
request completion can only be verified after authorized publication.
