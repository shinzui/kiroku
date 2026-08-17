# Revision history for kiroku-metrics

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
