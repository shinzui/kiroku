# EP6 practical performance acceptance

Recorded at 2026-10-10T13:52:05Z; user instruction: “accept let's continue”. This responds to the explicit recommendation to accept the bounded cumulative evidence practically and proceed to version review, after reporting the unresolved strict comparisons, rejected pooling and retained telemetry timeout.

The practical evidence decision is accepted. Package versions, bounds and changelogs are still proposals; publication, tags, pushes, clean-consumer verification and downstream adoption have not occurred and retain their separate gates. No additional performance queue is required.

## Accepted evidence and preserved limits

Production candidate: `5805117edf6bdb988d02d73e19fbb221ef2bf767`; original control: `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`; corrected measurement harness: `f7273083f1d719ac701500c898152c04dadd5170`. PostgreSQL 18.6; durable default paths, real adapter acknowledgements and successful-hook fan-out.

- [Original stopped experiment](README.md): zero valid matched pairs; failed/cancelled artifacts and original full telemetry failures retained.
- [Bounded diagnosis](../ep6-diagnosis/README.md): 13 valid trials, three adapter/two fan-out pairs, one calibration, one descriptive enabled-diagnostic run and one unmatched control. Interrupted final candidate excluded, zero replacements.
- [Bounded tail repeat](../ep6-tail-repeat/README.md): 12 additional valid trials, three pairs per path, zero replacements. All sealed work/artifacts independently verified. Total 25 valid trials and eleven matched default-path pairs across both sessions.
- Latest adapter throughput +0.39% (95% -2.88% to +3.77%); p99 +0.06% (-4.17% to +4.47%). Earlier +26.80% pair tail signal did not recur. Latest hook throughput +1.60% (+0.89% to +2.31%); p99 -1.12% (-5.23% to +3.17%). These observations do not prove equivalence or universal speedup.
- Separate original-policy reports remain **inconclusive**. Cross-session operator pooling remains **infrastructure-failure**, because host memory fingerprints differ by 4096 bytes. Pooled Student-t estimates remain descriptive only: adapter p99 +1.77% (-9.72% to +14.74%); hook p99 -3.34% (-7.76% to +1.29%). No fingerprint normalization or statistical-policy change is authorized or performed.
- Both full historical telemetry commands retain their failures (2/30 and 1/30 timeouts). Focused cases subsequently passed without replacing those failures; exhausted-category CPU-time telemetry was 28% above its historical baseline. A timing-variability cause has not been proved.
- Integrated correctness passes 554 examples across six PostgreSQL 18.6 suites; existing structural/controlled ADR-5 gates, migration paths, package checks and native formatting/pre-commit checks pass at the unchanged production source. Final new-version archives/Haddocks follow metadata approval.

No reproducible candidate-specific append slowdown is established. Practical acceptance explicitly preserves uncertainty and adverse evidence; a reproducible append regression would still block release. Historical reports and raw artifacts are unchanged. All remote VMs are stopped and no lease remains.

Decision: [ADR-11](../../../../docs/adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md). Execution: [EP6](../../../../docs/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption.md).
