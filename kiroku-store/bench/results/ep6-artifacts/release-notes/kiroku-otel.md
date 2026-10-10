# kiroku-otel v0.2.0.11

Hackage: https://hackage.haskell.org/package/kiroku-otel-0.2.0.11

### Bug Fixes

* Handle typed publisher decode failures and distinguish `StopUndecodable` in
  subscription stop attributes. Advisory handler-stall events leave span state
  unchanged; stall counters are supplied by kiroku-metrics.

### Other Changes

* Require `kiroku-store ^>=0.10.0.0`. The tracer's exported API is unchanged.
