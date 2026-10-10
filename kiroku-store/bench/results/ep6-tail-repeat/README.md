# EP6 tail repeat: no reproducible append slowdown, release gate open

The user authorized continuation after the first bounded follow-up. This repeat
completed all **12 declared trials**, three adjacent ABBA pairs for the real
adapter and three for two live subscribers with a successful identity decode
hook. There are **zero replacements** and no failed remote trial. The conservative
fixed clock is 2026-10-10 04:43:41–05:43:41 UTC, including prior planning and
inspection. Remote cleanup completed at 05:21:11 UTC, **37.50 minutes** after the
start; collection and comparison finished before the same deadline. All four
alpha VMs are TERMINATED, with no lease or quarantine. Both pair commands had
already released their owned leases; the cleanup release calls reported no
matching lease, and the independent final status confirms absence.

## This repeat

| Workload | Complete pairs | Throughput change (95% interval) | p99 change (95% interval) |
| --- | ---: | --- | --- |
| Real Shibuya adapter | 3 | +0.39% (-2.88% to +3.77%) | +0.06% (-4.17% to +4.47%) |
| Two live subscribers, successful hook | 3 | +1.60% (+0.89% to +2.31%) | -1.12% (-5.23% to +3.17%) |

The new adapter p99 changes were +1.36%, -1.90% and +0.74%, compared with the
previous session's -8.73%, +26.80% and -4.13%. The earlier large increase did not
reproduce; it is retained rather than removed. New hook throughput rose in all
three pairs, while p99 changed +0.82%, -1.73% and -2.40%. Both new session
comparisons remain `inconclusive` under the unchanged original policy, including
its minimum five pairs, zero regression limits and maximum interval width.
The 10% descriptive p99 uncertainty target is met for this repeat; this is not
proof of zero regression or a strict policy pass.

## Across both sessions, descriptive only

| Workload | Complete pairs | Throughput change (95% interval) | p99 change (95% interval) |
| --- | ---: | --- | --- |
| Real Shibuya adapter | 6 | +2.13% (-0.32% to +4.65%) | +1.77% (-9.72% to +14.74%) |
| Two live subscribers, successful hook | 5 | +2.25% (+0.26% to +4.27%) | -3.34% (-7.76% to +1.29%) |

The original operator refuses both combined comparisons as
`infrastructure-failure`: `machine profiles differ`. The comparison-relevant
fingerprint difference is driver `host.memoryBytes`: **33,657,581,568** in the
prior session versus **33,657,577,472** in this session, a **4,096-byte** difference
across VM boots. CPU, runtime, PostgreSQL and the remaining comparison fields
match. Cell-run and lease IDs also differ, but are excluded by the comparator.
`cross-session-fingerprint-diff.json` retains both originals. No result,
fingerprint, policy or threshold was edited to bypass the rejection. The pooled
intervals are descriptive Student t intervals on paired log ratios (df = pairs
- 1), not an accepted operator comparison. The pooled adapter p99 interval still
exceeds the 10% descriptive uncertainty target. Unmatched and cancelled prior
trials remain excluded from matched effects and retained in `../ep6-diagnosis/`.
Across sessions there are 25 valid trials in total, including the prior calibration,
diagnostic and unmatched control; 22 default-path trials form the eleven pairs.

Append allocation/op increased 1.16% (95% -0.52% to +2.86%) for the new adapter
pairs and 2.53% (+1.44% to +3.62%) for the new successful-hook fan-out pairs.
New WAL/op changes were +0.02% and +0.46%, respectively. Pooled descriptive
allocation changes are +0.77% and +2.73%. These costs are retained independently
of append throughput/latency; the single prior opt-in watchdog cost remains
separate and descriptive. No additional diagnostic trial was run.

## Correctness and source identity

Every accepted trial has a completed cell outcome, zero entry exit code,
benchmark grade, an independently verified reset and immutable artifact
sizes/SHA-256. Delivery equals expected delivered work, including both fan-out
subscribers. Checkpoint table updates and SQL calls exactly equal actual delivery
batches. Durable progress drains and PostgreSQL durability is on/on/on. The
retained progress verifier checks each newly completed slice before accepting it;
the final collector verifies every sealed tree again while copying evidence.

The published payload descriptors are reused byte-for-byte from the prior valid
experiment: control production source `e6ea66433c5320097b6afd3c4ca56cd18ba86bd0`,
candidate production source `5805117edf6bdb988d02d73e19fbb221ef2bf767`, clean
harness `f7273083f1d719ac701500c898152c04dadd5170`. PostgreSQL 18.6, GHC 9.12.4,
four writers, pool 10, append/fetch batch 1, width 1, 512-character payload and
-N4 -T -A32m are unchanged. Each trial has 30 seconds warmup, 61 seconds steady
measurement and up to 30 seconds durable drain. The new paired schedule uses
seed 2026101002 and new run IDs. Calibration and owned-lease-release proof are
reused; there is no extra calibration or broader matrix. Operator:
mori://shinzui/keiro-runtime-kenshou; infrastructure owner:
mori://shinzui/load-testing-infra.

## Historical telemetry remains failed

The unchanged full `nix develop -c just perf-telemetry` repeat passed **29 of 30**
cases and failed its `AnyVersion (new stream)` case at the existing 100-second
wall timeout. Command duration was 385.67 seconds, including build/setup; the
benchmark reported 301.24 seconds. Both formerly timed-out cases passed.
Exhausted-category reads measured 21.8 microseconds +/- 1.2 microseconds, **28%
above** the historical baseline; this adverse telemetry is retained. Historical
CPU timing is not a controlled before/after append comparison.

One focused diagnostic of the newly timed-out case used the same binary,
PostgreSQL 18.6, CPU-time mode, baseline, default relative deviation and test
timeout. It passed in **58.71 seconds** through setup/cleanup (45.98 seconds for
the test), reporting **173 microseconds +/- 14 microseconds**, 10% below baseline.
This suggests suite-context or timing variability, but does not prove the original
failure's cause, replace the failed full run, or grant performance acceptance.
The earlier full 2/30 failure and focused two-case pass remain unchanged.
No threshold, duration or baseline was tuned to produce a pass.

## Remaining work

The five implementation children remain Complete. Production library code and
release metadata are unchanged. Existing 554-example PostgreSQL 18.6 integrated
correctness and structural/controlled checks remain valid. ADR-11's stale
unimplemented-watchdog sentence is corrected to cite implemented plan 84/ADR-13;
its performance policy is unchanged. Formatting, both native aarch64-darwin
flake checks and strict ADR validation pass.

EP6 remains In Progress: no reproducible candidate-specific append slowdown is
established, but strict/statistical acceptance remains open, combined comparison
is rejected and the full telemetry command remains failed. Version approval,
new-version archives/Haddocks, publication, clean-consumer proof and downstream
adoption are outstanding. No tag, push, upload or downstream edit occurred.
No further experiment is queued. `summary.json` preserves this repeat;
`combined-summary.json` and the two combined comparison reports preserve the
cross-session descriptive assessment and formal rejection. `evidence-manifest.json`
records the final committed evidence inventory without modifying sealed artifacts.
