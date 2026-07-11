# Changelog

## Unreleased

## 0.2.0.0 — 2026-07-11

### Breaking Changes

* The standalone `kiroku` binary is now a pure remote client. It no longer opens
  a store, and the `--database-url`, `--schema`, and `--pool-size` options are
  gone. Subscription status is resolved from `--remote-url` or the
  `KIROKU_REMOTE_URL` environment variable and served by a running worker's
  `kiroku-metrics` `/subscriptions` endpoint; with neither set, the binary exits
  with guidance instead of connecting to a database. The embeddable library path
  (`runKirokuCommandWithStore` / `renderKirokuCommandWithStore`) still reads the
  in-process registry, so host applications are unaffected.
* `StandaloneOptions` and `StandaloneRuntime` are now newtypes carrying only
  `command :: KirokuCommand`. `StandaloneOptions` lost `databaseUrl`, `schema`,
  and `poolSize`; `StandaloneRuntime` lost `settings :: ConnectionSettings`.
  `resolveStandaloneOptions` no longer builds connection settings.
* Record field prefixes were dropped throughout the public API, so field
  selectors are renamed. `StandaloneOptions.standaloneCommand` and
  `StandaloneRuntime.runtimeCommand` both become `command`, and
  `SubscriptionStatusRow`'s `rowSubscription`, `rowMember`, `rowPhase`, and
  `rowGlobalPosition` become `subscription`, `member`, `phase`, and
  `globalPosition`. The affected records now derive `Generic`, so they are
  addressable with `generic-lens` labels (`row ^. #subscription`).
* Requires `kiroku-store ^>=0.3`.

### New Features

* `Kiroku.Cli.Subscription.Status` gains a remote client:
  `fetchRemoteSubscriptionStatusRows` and `renderRemoteSubscriptionStatus` query
  a worker's `/subscriptions` endpoint over `http-client` /`http-client-tls`.
* `SubscriptionStatusRow` gains `ToJSON` / `FromJSON` instances, giving the HTTP
  endpoint and the CLI a single wire contract; `renderJson` now encodes through
  that codec.
* `StatusOptions` gains `endpoint :: Maybe RemoteEndpoint` (`Nothing` reads the
  in-process registry; `Just` queries a remote worker), populated by the new
  `--remote-url` option.

## 0.1.0.0 — 2026-05-31

### New Features

* Initial package with embeddable parser, runner facade, executable wrapper,
  and parser composition tests.
