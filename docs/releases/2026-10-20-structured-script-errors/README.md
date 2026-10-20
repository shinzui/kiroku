# Structured script error release — 2026-10-20

The approved store and metrics patch releases are published and verified.
Release commit: `084fd8359850342447cdda8e632b7dc456c7fca4`. Both annotated tags are pushed and point to that
commit. [ExecPlan 98](../../plans/98-preserve-structured-script-session-errors.md)
and [IR-19](../../improvement-requests/preserve-structured-script-session-errors.md)
are complete.

| Package | Hackage | GitHub |
| --- | --- | --- |
| kiroku-store 0.11.0.1 | [package](https://hackage.haskell.org/package/kiroku-store-0.11.0.1) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-store-v0.11.0.1) |
| kiroku-metrics 0.3.0.1 | [package](https://hackage.haskell.org/package/kiroku-metrics-0.3.0.1) | [release](https://github.com/shinzui/kiroku/releases/tag/kiroku-metrics-v0.3.0.1) |

## Verification

The actual release versions pass `cabal build all`, 487 store examples and
117 metrics examples, including the existing store performance structure group.
`nix fmt`, `nix flake check`, both `cabal check` invocations and Hackage Haddock
archive generation pass. No timing experiment was needed for this error-path
change. Compressed command logs are retained in `logs/`.

Every archived source file matches the release checkout: 109 store files and
35 metrics files. Both source hashes exactly match the reviewed candidates and
the archives downloaded after publication. The served current Cabal files and
revision 0 Cabal files match the archives. `artifacts.json` records source and
documentation archive hashes; `publication.json` records package-page checks,
Cabal hashes, served documentation hashes and release URLs. Documentation index
and representative error-mapper module HTML match the upload after removing
only Hackage's known 89-byte injected presentation stylesheet.

## Published consumer

The standalone fixture in `consumer/` pins store 0.11.0.1, metrics 0.3.0.1 and
the already published migrations 0.7.1.0. Its `cabal.project` lists only the
consumer. The resolved plan identifies all three Kiroku packages as Hackage
`repo-tar` sources; the only local package is the consumer. Store and metrics
source/Cabal hashes match the published artifacts. Exact origins, versions,
compiler and fixture hashes are in `consumer-verification.json`; the full plan
is `consumer-plan.json.gz`. No dependency bound exception or package source
override is used.

With PostgreSQL 18.4, the consumer creates and migrates a disposable database,
then proves both public transaction runners preserve script SQLSTATE `42P01`.
The real permanent error maps to HTTP 500, while connection loss, pool timeout,
serialization failure and deadlock map to HTTP 503 in the published metrics
package. The fixture stops its owned database before reporting success:

```text
PASS: published store 0.11.0.1 preserves script SQLSTATE 42P01 through both runners
PASS: published metrics 0.3.0.1 maps permanent errors to 500 and typed unavailable errors to 503
PASS: disposable PostgreSQL stopped cleanly
```

The first three resolution attempts failed before compilation while the signed
index caught up with the uploads: first store, then metrics was absent. Those
attempts are retained alongside `consumer-index-journal.json`. The fourth used
index state `2026-10-20T01:31:03Z` and passed. Constraints and source origins were
kept unchanged during propagation.

The fixture uses the released APIs of `mori://shinzui/ephemeral-pg` 0.3.1.0 and
`mori://shinzui/pg-migrate` 1.2.0.0 to own its database and run the published
migration component. Those versions and APIs were checked against Hackage and
upstream tags through Mori-located source repositories.

## Reproduce

From the repository root, copy the fixture to a fresh directory. The Nix shell
provides the compiler and PostgreSQL tools; Cabal resolves packages from Hackage
inside the copied project:

```bash
consumer_stage=$(mktemp -d /tmp/kiroku-script-errors.XXXXXX)
cp docs/releases/2026-10-20-structured-script-errors/consumer/* "$consumer_stage/"
nix develop .#postgresql18 --command bash -c 'cd "$1" && cabal update && cabal run script-error-consumer -j2' _ "$consumer_stage"
```

Downstream adoption remains with
`mori://shinzui/rei/plans/256-expose-operational-status-and-controlled-periodic-check-apis`.
No downstream checkout was modified.
