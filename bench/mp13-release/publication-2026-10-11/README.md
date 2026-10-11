# MP13 release — 2026-10-11

All six packages, Haddock archives and GitHub releases are published and verified. The user accepted the measured performance and its
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

The exact-version consumer fixture has no local package override. Its build and execution pass against the six exact published versions;
`published-consumer-verification.json` and `published-consumer-plan.json` record
registry origins. `published-install-plan.json` and
`published-install-verification.json` also pin the installed executables and their
SHA-256 hashes. Both published executables install into an isolated directory.
The consumer uses GHC 9.12.4 and the repository's existing `haxl:time` upper-bound
override; no released dependency bound or local source override was added.
`published-smoke.json` verifies eight HTTP routes, CORS, capabilities version,
empty process-local registry, WebSocket subscription and clean shutdown of the
inspector and its owned PostgreSQL cluster. The initial index-resolution failures
are retained; Hackage's signed index propagated after the uploads.

IR-8 through IR-12, ExecPlan 96 and MasterPlan 13 are complete. All source tags
remain at the release commit; completion evidence is recorded separately.

## Retained limitation

The prior remote experiment released its lease and stopped every machine. Its
small diagnostic database remains on the stopped PostgreSQL disk after the
recorded SSH cleanup timeout. Removal is deferred to the next owned maintenance
lease; release work does not restart that experiment or its expired budget.

The local pre-commit configuration pointed at an older generated formatter. The
configuration symlink was refreshed from the current dev-shell hook output,
without initializing a database or bypassing formatting. All archived source
bytes were rechecked against the restored current formatter output.

## Published artifacts

Release commit: `7394055de458bef8f6ec2e68231f3ca7932bb9be`. All six annotated tags point to it and
are pushed to origin/master. The journal is `publication.json`.

| Package | Version | Hackage | GitHub |
| --- | --- | --- | --- |
| kiroku-store | 0.11.0.0 | [package](https://hackage.haskell.org/package/kiroku-store-0.11.0.0) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-v0.11.0.0) |
| kiroku-store-migrations | 0.7.1.0 | [package](https://hackage.haskell.org/package/kiroku-store-migrations-0.7.1.0) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-migrations-v0.7.1.0) |
| kiroku-otel | 0.2.0.12 | [package](https://hackage.haskell.org/package/kiroku-otel-0.2.0.12) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-otel-v0.2.0.12) |
| kiroku-cli | 0.2.0.10 | [package](https://hackage.haskell.org/package/kiroku-cli-0.2.0.10) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-cli-v0.2.0.10) |
| kiroku-metrics | 0.3.0.0 | [package](https://hackage.haskell.org/package/kiroku-metrics-0.3.0.0) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-metrics-v0.3.0.0) |
| shibuya-kiroku-adapter | 0.6.0.1 | [package](https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.6.0.1) | [release](https://github.com/shinzui/kiroku/releases/tag/shibuya-kiroku-adapter-v0.6.0.1) |

Every downloaded source archive matches its local SHA-256 exactly. Served
Haddock index and representative module HTML match the uploaded archive after
removing only Hackage's exact 89-byte injected presentation stylesheet. Both
served and local hashes are recorded in the journal. The initial verification
failure and the OTel module-name correction are retained in publication logs.
No source archive or published version was replaced. An initial Cabal install
command used component-qualified targets, which this install command parsed as
URLs; the corrected command uses exact package-version targets. That failed
invocation is retained in `published-install.log`.

## Consumer handoff

Consumers in `mori://shinzui/keiro-ui` and `mori://shinzui/keiro` can use the
[UI guide](../../../docs/guides/building-an-inspection-ui.md). Durable inventory
is `GET /subscription-checkpoints`; `/subscriptions/checkpoints` remains the
legacy route for a live subscription named `checkpoints`. WebSocket errors add
`replay_failed`, `category_read_failed`, `live_decode_failed` and
`event_stream_overflowed`. Preserve the last contiguous pre-overflow cursor for
recovery. Discover actual providers with `/capabilities`; the standalone
inspector has an empty process-local live registry. No downstream files or
messages were changed or sent.

## Reproducing the published consumer

Copy `consumer-fixture/` to a fresh directory, then run `cabal update` and
`cabal build all -j2` there. The consumer executable prints `"0.3.0.0"`.
The full resolved package plans are retained above. The installer command was:

```bash
cabal install kiroku-metrics-0.3.0.0 kiroku-store-migrations-0.7.1.0 \
  --ignore-project --with-compiler=ghc-9.12.4 \
  --installdir="$consumer_stage/bin" --install-method=copy \
  --constraint="kiroku-store ==0.11.0.0" \
  --constraint="kiroku-cli ==0.2.0.10" --allow-newer=haxl:time \
  --builddir="$consumer_stage/install-dist" --keep-temp-files -j2
```

`consumer_stage` denotes that fresh directory. Run this evidence directory's
`smoke.py "$consumer_stage/bin"` with PostgreSQL 18 tools on PATH to create,
migrate, exercise and stop a new owned local database. Raw command output keeps
its original whitespace.
