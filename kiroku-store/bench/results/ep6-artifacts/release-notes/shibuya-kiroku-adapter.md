# shibuya-kiroku-adapter v0.6.0.0

Hackage: https://hackage.haskell.org/package/shibuya-kiroku-adapter-0.6.0.0

### Breaking Changes

* Both configurations use validated `BatchSize` and `StreamBufferSize` capacities.
  `KirokuConsumerGroupConfig.groupSize` and `defaultConsumerGroupConfig` take
  validated `ConsumerGroupSize`; smart constructors and read-only accessors are
  re-exported.
* Both configurations add `retryPolicy` (five total deliveries) and
  `handlerStallWarnAfter` (default `Nothing`), forwarded to each underlying worker.
  Pending raw acknowledgements remain pending; enabled warnings are advisory.

### New Features

* Add `kirokuProcessor`, composing single-processor defaults (`Unordered`,
  `Serial`) with the one-second synchronous exception retry guard.

### Other Changes

* Require `kiroku-store ^>=0.10.0.0`.
