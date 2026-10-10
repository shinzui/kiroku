# EP4 acknowledgement and handler diagnostics evidence

Implementation source: `96c7d4f`; pre-EP4 source: `6733239`.
PostgreSQL 18.6, GHC 9.12.4, Cabal 3.16.1.0, aarch64 macOS, Cabal O1.
`summary.json` records counts and SHA-256 checksums for every retained transcript.

All 504 workspace examples pass: 373 store, 45 adapter, 23 metrics, 17
OpenTelemetry, 24 migration and 22 CLI. `tests-verified.log` contains the final
six-suite pass. This includes 13 new handler-stall cases, seven real-adapter
acknowledgement/retry-policy cases, and one JSON/Prometheus counter case.
`build-verified.log` and the final incremental `build-final.log` record the
all-component build. Formatting and strict ADR/capability validation pass.

`ack-verified.log` pins the standard Shibuya runner's finalized immediate retry,
the new helper's one-second guard, and raw consumers with disabled/enabled
warnings: withholding finalization blocks the next item and preserves checkpoint
zero; manual finalization resumes delivery. `retry-verified.log` proves the
five-delivery default, two total deliveries for a single adapter, and both size-2
member keys receiving the custom limit and stall interval.

The store tests cover catch-up, confirmed live, category and group delivery;
warning identity, monotonic elapsed duration and periodic pacing; default-disabled
and complete-before-threshold behavior; replaced invocations; guarded observer
exceptions; handler exceptions; cancellation/join; and nonpositive interval refusal
before checkpoint initialization through the shared startup-failure family.
Source inspection of `withHandlerStallDiagnostics` pins the construction-time
`Nothing -> action config` arm: no cell, thread, timer, diagnostic clock read,
per-event diagnostic branch or tracking write. Enabled workers reuse one interval
timer across quick calls rather than abandoning one registration per event.

Two failed correctness fixtures are retained, with their corrections:
`retry-fixture-failure.log` read only member zero's dead letters while expecting
all group events; the helper now reads both member keys. `stall-fixture-failure.log`
expected checkpoint one while a second normal native handler held an unsaved batch;
the correct batch-boundary checkpoint is zero. No production change was needed for
these failures. The final full suite verifies the corrected assertions. These are
fixture corrections, not replaced performance samples.

`perf-check.log` passes 20 structural checks and all 16 existing controlled SQL
workload cases (116.73 seconds for the workload gate). These do not compare EP4
or the cohort against its predecessor. The category-append control remains noisy
(44.4 ± 48 ms); favorable ratios do not establish cumulative performance neutrality.
No new remote experiment or per-child benchmark queue ran. Cumulative original-
control append/real-adapter comparisons and enabled diagnostic costs remain EP6
work, under ADR-11 and the user's one-hour whole-experiment ceiling. Prior adverse
samples, uncertainty and the original comparison policy remain intact.

ADR-13 records worker ownership and advisory consumer finalization. ADR-8 documents
the optional raw-duration validation exception. Configuration fields, operational
constructors and lifecycle counters are source-breaking; release/version selection
remains EP6 work. No schema, append SQL, package version or publication changed.

Commands, from the repository root:

```bash
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test --test-options='--match "acknowledgement liveness"' --test-show-details=direct
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test --test-options='--match "retry policy"' --test-show-details=direct
cabal test kiroku-store:kiroku-store-test --test-options='--match "handler stall"' --test-show-details=direct
cabal build all
cabal test all --test-show-details=direct
just perf-check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
nix fmt
```
