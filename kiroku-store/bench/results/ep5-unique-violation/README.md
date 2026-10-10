# EP5 unique-violation classification evidence

Pre-EP5 source: `250d44693136ed5fb89a2b524248ffca7d027c0b`.
Implementation source: `5805117`.
PostgreSQL 18.6, GHC 9.12.4, Cabal 3.16.1.0, aarch64 macOS, Cabal O1.

The original production mapper fails 26 of the initial 43 mapping examples
(`mapping-before.log`). The final mapping group passes 49 examples
(`mapping-after.log`), including message/detail forms, overlapping constraint
names, identifier lookalikes, missing UUIDs, message precedence, transaction
composite IDs, link classification and multi-stream attribution.

Both real duplicate-append tests pass (`duplicate-append.log`). The new case
retries the same caller ID under AnyVersion, StreamExists and ExactVersion 1;
each failure carries that ID and preserves one payload, one original-stream
link, one global link and stream version 1. The full store suite passes 423
examples in 71.40 seconds (`store-tests.log`), preserving transaction, link,
expected-version, retry and concurrency coverage.

The first combined Hspec pipe filter selected zero examples; `focused.log`
retains that mistake and is excluded from acceptance. The two corrected
focused commands and the full suite select nonzero examples. Invariant failure
is proved with synthetic Hasql errors; normal append serialization prevents it,
and a real fixture would require deliberate inconsistency or an artificial
trigger. No such fixture, constraint disabling or schema change was introduced.

ADR-14 distills exact-name identity and the caller-duplicate/internal-invariant
boundary. Strict ADR profile/log validation and formatting pass.

The extractor runs only for failed statements with SQLSTATE 23505. Production
Effect.hs, SQL.hs, publisher and worker sources are unchanged from the pre-EP5
commit; no successful append parsing, query, instrumentation or retry change
is introduced. The existing ADR-5 aggregate passes 20 structural checks and all 16 controlled
workload cases in 117.74 seconds (`perf-check.log`). The category append control
remains noisy (43.6 ± 46 ms); its favorable ratio is not a cohort comparison.
These controls do not compare the integrated cohort to its original control:
cumulative append acceptance and prior statistical uncertainty remain EP6 work.
No remote experiment or package publication ran for EP5. `summary.json` records
transcript and changed-source checksums; `unchanged-paths.json` verifies the four
unchanged production paths against the pre-EP5 commit.

Commands, from the repository root:

```bash
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "unique violation mapping"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct --test-options='--match "duplicate event ID"'
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
just perf-check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix fmt
```
