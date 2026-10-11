Hackage: https://hackage.haskell.org/package/kiroku-metrics-0.3.0.0

### Breaking Changes

- New umbrella exports can make record labels ambiguous; qualify configuration record updates.

- `ClientMessage` gains `UnsubscribeMetrics` and `ServerMessage` gains `CodedError`; exhaustive Haskell matches must handle the additions. Published wire growth is additive.

* `MetricsServerConfig` gains `cors`, defaulting to `corsDisabled`. Use
  `defaultConfig` record updates; complete or positional construction must supply it.

### New Features

- `GET`/`HEAD /capabilities` reports actual wiring, declared WebSocket channels and process-local scope without database reads. `Kiroku.Metrics.Capabilities` exports codecs and the generated `kirokuMetricsVersion`.
- `kiroku-inspect` and `Kiroku.Metrics.Standalone` serve the store-backed inspection API from a database URL, with validated CLI/environment options, explicit CORS and joined SIGINT/SIGTERM shutdown. It runs no subscriptions.
- Add `optparse-applicative` as a library dependency for the reusable standalone parser.

- `unsubscribe_metrics` stops periodic snapshots; `subscribe_metrics` requests a fresh snapshot and resumes periodic delivery without duplicate workers.
- Tail errors carry stable `code` values: `replay_failed`, `category_read_failed`, `live_decode_failed`, `event_stream_overflowed`, with sanitized messages.
- Live, replay and category event frames add `original_stream_name` through one batched lookup and a bounded 4096-name FIFO cache per tail.
- Drop-oldest loss now sends an overflow notice before surviving events. Earlier versions documented that notice but never emitted it.

- Read-only `GET`/`HEAD /subscriptions/<name>/dead-letters`, structured reasons and errors, member filtering and opaque cursor pages. `Kiroku.Metrics.DeadLetters` exports the codec and provider; store-backed starters configure the new `deadLetters` provider automatically.

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

- Require `kiroku-store ^>=0.11.0.0` and `kiroku-cli ^>=0.2.0.10`. Construct the new `ServerProviders` from `defaultServerProviders`; full construction supplies all six fields.

- Cache-miss detection inspects only current-batch stream IDs, avoiding a walk of every retained name on each small tail batch.

- Document discovery, standalone hosting and the complete client workflow in `docs/guides/building-an-inspection-ui.md`.

* Server acquisition waits for Warp readiness and propagates bind failures;
  bracketed lifetimes supervise server termination and release sockets.
* Prefix-mounted WebSocket dispatch uses escaped mount-relative paths and
  honors `enableWebSocket` before upgrades.
* Add a direct `network` dependency for explicit ephemeral-socket cleanup.
