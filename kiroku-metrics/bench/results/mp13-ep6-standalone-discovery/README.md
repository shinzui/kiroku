# MasterPlan 13 / EP-6: standalone inspection and discovery

Local completion evidence for plan 95, implemented in `7f9e4f0` and closed by
its evidence commit. Baseline is `ac1d655`. No remote performance experiment
was launched for this metadata/startup change. This report makes no comparative
write-cost or cumulative release acceptance claim.

## Functional checks

The baseline metrics suite passed 98 cases. Discovery adds seven cases and
standalone adds eleven (eight options/server cases and three executable cases).
`cabal test all -j1` passed all six suites: store 448, metrics 116, CLI 22,
OpenTelemetry 17, migrations 24 and adapter 45, totaling 672 cases.
The final discovery run additionally pins structured 404/405 codes and passed
seven cases after the full run; production source did not change between them.

`cabal build all -j1` passed without new compiler warnings. The external
consumer importing the full umbrella compiled; its source is retained.
The eleven-step example passed on port 64815 with final position 4.
`cabal check` reported no errors or warnings; the final sdist includes the
executable and both new modules. The actual standalone `/capabilities` response
is in `capabilities.json`, with the current compiled version 0.2.0.0.

Real subprocess checks verify exit 2 for usage/resolution failures, exit 1 with
no success banner for bind failure, redacted connection failures and exit 0
for SIGINT/SIGTERM, including repeated signals. The in-process run exercises
CORS, durable reads, empty process-local registry/metrics, a real event tail,
immediate shutdown, callback failure and cancellation. Existing supervised
server tests cover unexpected worker failure and cancellation during acquisition.

## Packaging and knowledge checks

The final local `nix build .#kiroku-metrics --builders '' --max-jobs 2 -L`
passed and installed `bin/kiroku-inspect`; that binary's `--help` passed.
Nix disables tests, so Cabal supplies runtime verification. Existing source
name-shadow warnings and Haddock documentation/link diagnostics remain in the
raw Nix log; they are not hidden by the Cabal compilation result.
The first Nix attempt was interrupted while waiting on configured remote
building and predates final runtime fixes. Its log is retained as `nix.log.gz`;
only `nix-local.log.gz` is the finished-runtime-source packaging result.
The final test-only error-code assertions were added afterward and passed in
Cabal; Nix does not run those tests.

Capability validation passed 21 concepts, ADR validation passed 18, including
strict profile/log enforcement for ADR-18. Formatting and diff checks passed.
No version was bumped, package published or improvement request completed.

## Proportional performance evidence

Discovery derives and encodes one immutable wiring summary per application,
without a store read. Its test supplies four providers that fail if invoked;
GET discovery succeeds and reports each as present. This is a focused real-path
check of the new metadata behavior, not a statistical throughput estimate.
Structural comparison proves no store, migration or CLI changes from the
baseline, byte-identical collector/configuration/HTTP encoders/WebSocket runtime,
and unchanged existing HTTP dispatch after removing the new discovery arm.

The new executable reuses the existing store/collector/server lifetime and
adds no subscription or polling worker. No append SQL, index, publisher work or
checkpoint write was introduced by this child. Those structural facts do not
accept the cohort's aggregate observer-under-append cost. The index benchmark's
inconclusive policy verdict and cumulative release gate remain with plan 96.

## Retention

Logs include initial compilation failures and the interrupted packaging attempt,
not just passing checks. `source-fingerprints.sha256` describes final source;
`artifacts.sha256` hashes every retained artifact except itself. Verify artifact
hashes from this directory and source hashes from the repository root.
