# Revision history for kiroku-metrics

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
