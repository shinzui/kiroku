# kiroku-store v0.10.0.0

Hackage: https://hackage.haskell.org/package/kiroku-store-0.10.0.0

### Breaking Changes

* `ConsumerGroup` and `ConsumerGroupSize` are opaque validated types. Construct
  them with `mkConsumerGroupSize` and `mkConsumerGroup`; use `mkBatchSize` for
  positive subscription batches and `mkStreamBufferSize` for bridge capacities.
* `decodeHook` returns `Either DecodeFailure RecordedEvent` in IO;
  `decodeEvents` returns `DecodedBatch`. Return `Right` from successful hooks.
* `SubscriptionConfigM` adds `undecodableHandler` (default `Nothing`) and
  `handlerStallWarnAfter` (default `Nothing`). Observers must handle typed
  publisher decode failures, group-size mismatch, advisory handler stalls and
  `StopUndecodable`.
* Apply migrations 0013 and 0014 from kiroku-store-migrations 0.7.0.0 with
  subscription workers stopped. Startup verifies persisted group size and
  target binding. Declare adoption of legacy targets explicitly; incompatible
  restart refuses before delivery through `SomeSubscriptionStartupFailure`.

### New Features

* Public `resizeConsumerGroupTx` equalizes every new member at the old minimum
  checkpoint and returns `ConsumerGroupResizeReport`, composing with caller SQL.
  Stop every member before resizing, including same-size hash-assignment changes.
* Public `rebindSubscriptionTargetTx` atomically changes a stopped subscription's
  target. Resize preserves target bindings.
* Typed undecodable events use bounded retries and preserve the checkpoint before
  a failed event. Explicit callbacks can skip, stop, retry or dead-letter with
  `DeadLetterDecodeFailure`; reads return `EventDecodeFailed` without partial data.
* A positive `handlerStallWarnAfter` enables a scoped advisory watchdog. Invalid
  intervals refuse on `wait` before checkpoint initialization. Warnings do not
  acknowledge, retry or checkpoint an event; the default path has no tracking work.

### Bug Fixes

* Live reconnect retains processed progress. Typed hook failures no longer stall
  the shared publisher; absent hooks retain the unchanged-vector fast path.
  Hook exceptions remain programming failures.
* Match unique constraints by exact name across append, transaction, link and
  multi-stream error attribution. `events_pkey` and `stream_events_pkey` return
  `DuplicateEvent` with a parseable caller ID. `ux_stream_events_stream_version`
  returns `UnexpectedServerError "23505"` with the original message for an
  invariant failure. Unknown append constraints retain the expected-version fallback.
