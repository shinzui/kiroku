# CLI TLS bound correction

Prepared, unpublished Hackage metadata revisions for `kiroku-cli 0.2.0.11`
and `0.3.0.0`. Both library and test dependencies change from
`http-client-tls >=0.3 && <0.4` to `>=0.3 && <0.5`. The current source manifest
carries the same correction for future releases.

This addresses `mori://shinzui/shikigami/okf/friction-log/concepts/FRIC-34`.
Metrics 0.4.0.0 depends on CLI 0.2.0.11 and Store 0.12; fixing only CLI 0.3
would leave that cohort blocked. No metrics or Store bound needs widening.

## Compatibility evidence

The CLI imports only `tlsManagerSettings :: ManagerSettings` from
`mori://snoyberg/http-client/packages/http-client-tls`. Inspection of its source
and [0.4.0 changelog](https://hackage.haskell.org/package/http-client-tls-0.4.0/changelog)
shows that API is retained; 0.4.0 replaces the dependencies used for MD5 digest
authentication. The upstream tag `http-client-tls-0.4.0` resolves to
`071d22a3cbf2159ca6b8bace121b036c6d4d5a89`. Hackage version listings and Kiroku's
remote tags were checked on 2026-10-30: CLI 0.3.0.0, metrics 0.4.0.1 and TLS
0.4.0 are the latest released versions.

Each candidate Cabal file was derived from the corresponding Hackage file,
verified byte-for-byte against its release tag before editing. The only edits
are the two TLS upper bounds. Store compatibility and all source code stay as
released. Candidate files omit `x-revision`; Hackage assigns revision metadata
when accepting an edit.

## Validation

Validation uses GHC 9.12.4 on aarch64 macOS, forces `http-client-tls ==0.4.0`,
and uses no TLS `allow-newer` or Nix jailbreak. All checks passed:

| Cohort | CLI suite | Metrics suite |
| --- | --- | --- |
| Current: CLI 0.3.0.0, Store 0.13.0.1, metrics 0.4.0.1 | 29 passed | 126 passed |
| Legacy: CLI 0.2.0.11, Store 0.12.0.0, metrics 0.4.0.0 | 22 passed | 4 subscription cases passed |

`cabal check` also passes for the current CLI manifest. [Evidence](evidence.json)
records the selected versions, release commits and candidate SHA-256 hashes.
Full output is retained in [current tests](current-tests.log.gz),
[legacy subscription tests](legacy-subscriptions.log.gz) and
[legacy CLI tests](legacy-cli.log.gz). The first legacy command also ran the CLI
with the `/subscriptions` filter, selecting zero CLI examples; the separate
unfiltered CLI run above is the CLI acceptance result.

For the current tree:

```sh
nix develop --no-write-lock-file -c cabal test kiroku-cli-test kiroku-metrics-test --constraint='http-client-tls ==0.4.0' --test-show-details=direct -j2
```

For the legacy cohort, extract `git archive kiroku-cli-v0.2.0.11` to a fresh
directory, replace only `kiroku-cli/kiroku-cli.cabal` with
[the candidate revision](revisions/kiroku-cli-0.2.0.11/kiroku-cli.cabal), and set
its `cabal.project` to:

```cabal
packages: kiroku-store kiroku-store-migrations kiroku-test-support kiroku-cli kiroku-metrics
with-compiler: ghc-9.12.4
tests: True
benchmarks: False
constraints: http-client-tls ==0.4.0
```

Use the Kiroku Nix development shell to run `cabal test kiroku-cli-test`, then
`cabal test kiroku-metrics-test --test-options='--match /subscriptions'`, both
with `--test-show-details=direct -j2`. This keeps Store 0.12.0.0, migrations
0.7.2.0 and metrics 0.4.0.0 from the release tag. The metrics cases exercise
the real CLI remote client against a live store over HTTP and its 404 handling;
they do not qualify a TLS handshake.

## Publication

Publish each [candidate Cabal file](revisions/) as a metadata revision of its
existing package version, then refresh the consumer's package index and verify
the revised metadata. A source release or Store upgrade is unnecessary. Until
these revisions are published, released consumers still need the scoped
`allow-newer: kiroku-cli:http-client-tls` workaround. Do not mark FRIC-34
resolved or remove the consumer workaround before that verification.
