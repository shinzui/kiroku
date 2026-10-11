# MP13 release — 2026-10-11

Publication is in progress. The user accepted the measured performance and its
uncertainty, then explicitly instructed completion of the release. See
`authorization.json`; the statistical comparison is retained unchanged.

The release versions are store 0.11.0.0, migrations 0.7.1.0, metrics 0.3.0.0,
CLI 0.2.0.10, OTel 0.2.0.12 and adapter 0.6.0.1. Store includes the separately
completed and accepted opt-in stream-head read; the upgrade blueprint lists all
five added closed-effect constructors. The migration README now correctly lists
fifteen embedded payloads. External dependency bounds are unchanged.

## Validation

The full build passes. All six suites pass 698 examples (474 store, 116 metrics,
45 adapter, 24 migrations, 22 CLI and 17 OTel). All six `cabal check` invocations,
Nix flake checks, ADR/capability/request checks and both executable help checks
pass. The final Nix executable is built locally (`nix-runtime-local.log`); the
initial configured-builder attempt was interrupted and remains retained.
`source-archives.json` hashes all six sdists and verifies every archived file
against the release source. The previously validated eleven-step example and
structural/workload evidence remain applicable; no performance experiment was
repeated for publication.

A redundant Cabal help command overlapped Haddock in the same build directory,
causing inconsistent compiler metadata. Both failed logs remain retained. The
already-built executable help passed directly; documentation was successfully rebuilt in a
fresh isolated directory recorded in `docs-stage.json`. No source or dependency
bound was changed to accommodate that build-directory failure.

The exact-version consumer fixture has no local package override. Its final
build/install and executable smoke results will be recorded after publication.

## Retained limitation

The prior remote experiment released its lease and stopped every machine. Its
small diagnostic database remains on the stopped PostgreSQL disk after the
recorded SSH cleanup timeout. Removal is deferred to the next owned maintenance
lease; release work does not restart that experiment or its expired budget.

The local pre-commit configuration pointed at an older generated formatter. The
configuration symlink was refreshed from the current dev-shell hook output,
without initializing a database or bypassing formatting. All archived source
bytes were rechecked against the restored current formatter output.
