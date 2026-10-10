# Revision history for kiroku-metrics

## Unreleased

### Breaking Changes

* `ServerProviders` adds optional `storeBrowsing`; use `defaultServerProviders` plus record updates for custom composition.

* `MetricsServerConfig` gains `cors`, defaulting to `corsDisabled`. Use
  `defaultConfig` record updates; complete or positional construction must supply it.

### New Features

* Add bounded stream/category/event browsing with category-plus-literal-prefix filters, exclusive cursors, validated page limits and GET/HEAD support. Store-backed servers configure the provider automatically.
* Add `recordedEventToJSONResolved`, preserving existing event keys and adding `original_stream_name`.

* `GET /subscription-checkpoints` serves exact durable member checkpoints and
  the same-snapshot store position through `Kiroku.Metrics.Checkpoints`.
* `ServerProviders`, `defaultServerProviders`, `storeServerProviders` and four
  `...WithProviders` functions compose inspection sources without changing
  legacy starter signatures. Store-backed starters include durable inventory.


* `Kiroku.Metrics.Cors` provides validated `AllowedOrigin`, `CorsPolicy` and
  `corsMiddleware`: explicit default-off browser access with cache-correct
  HTTP/preflight handling and WebSocket origin refusal before upgrade.
* Shared `errorEnvelope`, `errorResponse` and sanitized `storeErrorResponse`
  helpers for new inspection routes. CORS refusals use `origin_not_allowed`,
  `cors_method_not_allowed` and `invalid_cors_request` codes.

### Other Changes

* Server acquisition waits for Warp readiness and propagates bind failures;
  bracketed lifetimes supervise server termination and release sockets.
* Prefix-mounted WebSocket dispatch uses escaped mount-relative paths and
  honors `enableWebSocket` before upgrades.
* Add a direct `network` dependency for explicit ephemeral-socket cleanup.

## 0.2.0.0 — 2026-10-10

### Breaking Changes

* `LifecycleCounters` adds `publisherDecodeFailures`,
  `subscriptionsStoppedUndecodable` and `subscriptionHandlerStalls`.

### New Features

* JSON and Prometheus distinguish typed publisher decode failures and
  undecodable stops from programming failures. JSON adds
  `subscription_handler_stalls`; Prometheus adds
  `kiroku_subscription_handler_stalls_total`. Advisory warnings do not advance
  the collector's subscription position.

### Other Changes

* Require `kiroku-store ^>=0.10.0.0` and `kiroku-cli ^>=0.2.0.9`.

## 0.1.0.10 -- 2026-09-25

### Other Changes

* Require `kiroku-store ^>=0.9.0.1` and `kiroku-cli ^>=0.2.0.8` so the
  metrics server resolves the idle publisher retention fix. Its API and wire
  format are unchanged.

## 0.1.0.9 -- 2026-09-25

### Other Changes

* Requires `kiroku-store ^>=0.9`, which requires schema migration `0012` from
  kiroku-store-migrations 0.6.0.0 and serves category reads from the new `$all`
  category index. No source change was required and no `kiroku-metrics` API
  or runtime behavior changed.

## 0.1.0.8 -- 2026-08-16

### Other Changes

* Requires `kiroku-store ^>=0.8`, which adds the `TransientTransactionFailure`
  constructor to `StoreError`. The fixed subscription metrics schema does not
  match on `StoreError`, so no source change was required and no
  `kiroku-metrics` API or runtime behavior changed.

## 0.1.0.7 -- 2026-08-15

### Other Changes

* Built with `ghc-options: -Wall -Werror=incomplete-patterns`, matching every
  other package in the repository. The fixed subscription metrics schema's
  `KirokuEvent` match was already exhaustive, so no source change was required
  and no `kiroku-metrics` API or runtime behavior changed.

## 0.1.0.6 -- 2026-08-13

### Other Changes

* Requires `kiroku-store ^>=0.7`. The fixed subscription metrics schema
  explicitly ignores replay-history retention lifecycle events while composed
  event passthrough still receives them; no `kiroku-metrics` API changed.

## 0.1.0.5 -- 2026-08-12

### Other Changes

* Requires `kiroku-store ^>=0.6`, whose exported `Store` effect now offers the
  visible global head position read. No `kiroku-metrics` API or runtime
  behavior changed.

## 0.1.0.4 -- 2026-08-11

### Other Changes

* The collector consumes the new subscription checkpoint-resolution lifecycle
  event and records its durable position as the subscription checkpoint gauge.
  It also remains exhaustive for typed missing-checkpoint startup refusal.
* Requires `kiroku-store ^>=0.5`. No `kiroku-metrics` API changed.

## 0.1.0.3 -- 2026-08-09

### Bug Fixes

* Corrected the `kiroku_events_appended_total` Prometheus HELP text: the value
  is the current opaque global position and is not guaranteed to be dense.

### Other Changes

* Requires `kiroku-store ^>=0.4`, whose exported `Store` effect now supports
  durable subscription checkpoint inventory reads. No `kiroku-metrics` API
  changed.
* Added a PVP upper bound to the shipped example's internal
  `kiroku-test-support` dependency. Version 0.1.0.2 was tagged but not
  published after `cabal check` found the missing bound.

## 0.1.0.1 -- 2026-07-11

### Other Changes

* Relaxed dependency bounds to `kiroku-store ^>=0.3` and `kiroku-cli ^>=0.2`. No
  change to `kiroku-metrics`' own API or behavior.

## 0.1.0.0 -- 2026-06-15

First release. A sister package to `kiroku-store` that exposes operational
metrics and event streams over HTTP without pulling a web framework into the
core library.

### New Features

* In-process metrics collector and JSON-encodable snapshot type.
* HTTP endpoints serving metrics as JSON, Prometheus exposition format, and a
  health check.
* WebSocket channel for streaming live metrics and events out of a running
  store.
* Live subscription-status endpoint over HTTP, with a CLI remote client.
* Runnable, self-verifying `kiroku-metrics-example` and a user guide.
