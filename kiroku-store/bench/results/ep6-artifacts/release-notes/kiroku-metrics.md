# kiroku-metrics v0.2.0.0

Hackage: https://hackage.haskell.org/package/kiroku-metrics-0.2.0.0

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
