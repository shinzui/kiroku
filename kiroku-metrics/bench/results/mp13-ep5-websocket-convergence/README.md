# MP-13 EP-5 local WebSocket convergence evidence

Baseline: `c725aac` on local `master`, with the Shibuya benchmark's missing
migration setup repaired before its baseline measurement. No versions changed,
no new index or migration, no remote experiment or publication.

## Scope

- Publisher correctness: exact DropOldest counter, newest-batch retention,
  other overflow policies, legacy wrapper and idempotent deregistration.
- Protocol correctness: frozen old encoders/spec, four sanitized error codes,
  real metrics stop/resume and live/replay/category names, deterministic production
  notice-before-survivor delivery with recovery from the pre-notice cursor.
- Cache/lifecycle: 4096 map/FIFO entries, one distinct lookup per cold batch,
  zero on hits/empty input, current-batch names even above capacity, no partial
  typed-decode result, masked worker registration and cancellation/join.
- Existing backpressure fixtures now wait for Live before the blocked first
  handler; catch-up previously bypassed the paths their assertions intended to
  exercise. Original delivery/checkpoint/callback assertions remain intact.

## Local timing

`cabal bench kiroku-store:kiroku-shibuya-overhead` retains the original five
iterations at 100, 1000 and 5000 events. This is predominantly a catch-up check,
not evidence of cumulative append neutrality or resolver cost.

`cabal bench kiroku-metrics:kiroku-websocket-tail` uses 500 real, distinct source
names and 50 deliveries of that 500-event batch per trial, with five alternating
control/warm/cold rounds. A capacity-one in-process queue feeds the production
broadcast helper; the frame writer forces JSON serialization. This excludes
network/socket backpressure and real publisher fetch/fan-out cost. It uses real
batched store lookups and shares the pool with an appender issuing 50 batches of
10 events to the same existing stream per case. It verifies all 7,500 concurrent
appends plus the 501 setup events (visible head 8001). Warm setup is outside the
clock; warm trials make zero measured lookups, cold trials make one, and both
retain 500 map/FIFO entries. High-cardinality eviction is a separate correctness
check, not a measured sustained churn workload.

The first two tail runs used an encoder-only control, omitting the original
loop's filter and post-delivery status sample. They are retained as preliminary.
The final tail control reproduces those steps; it does not omit existing work.

The first post-counter and tail runs overlapped the Nix build. They remain in
`after-overhead.log.gz` and `tail-cost.log.gz`, including adverse samples. They
are not used for acceptance. One isolated follow-up addresses that interference;
its 5000-event row remained adverse, so one bounded original-publisher/control-counter check was added under the same current conditions. These runs are reported separately. There are no favorable sample replacements, additional remote trials or relaxed
precision gates.

Timing values below are descriptive local measurements. Plan 96 still owns the
integrated original-control PG18 append/observer acceptance, including the
previously retained index costs and inconclusive policy verdict. These local
checks do not approve release or establish zero slowdown.

## Verification and retention

Logs include failed setup/compiles and both full-suite fixture failures, alongside
passing verification. `source-fingerprints.sha256` identifies the implementation
and fixtures. `artifacts.sha256` seals retained files; verify from this directory:

```bash
shasum -a 256 -c artifacts.sha256
```

## Recorded results

Publisher bare-subscribe rows (all raw ranges retained):

```text
100 events baseline: bare subscribe:  median 9 ms  [8 ms .. 42 ms]  (11609 events/s, 86 μs/event)
100 events isolated after: bare subscribe:  median 13 ms  [6 ms .. 19 ms]  (7643 events/s, 131 μs/event)
1000 events baseline: bare subscribe:  median 17 ms  [16 ms .. 31 ms]  (60544 events/s, 17 μs/event)
1000 events isolated after: bare subscribe:  median 19 ms  [18 ms .. 29 ms]  (52051 events/s, 19 μs/event)
5000 events baseline: bare subscribe:  median 43 ms  [42 ms .. 46 ms]  (117534 events/s, 9 μs/event)
5000 events isolated after: bare subscribe:  median 77 ms  [67 ms .. 188 ms]  (64847 events/s, 15 μs/event)
Same-condition control/candidate pair (original publisher, then counter publisher):
100 events control: bare subscribe:  median 11 ms  [5 ms .. 14 ms]  (9185 events/s, 109 μs/event)
100 events candidate: bare subscribe:  median 11 ms  [9 ms .. 15 ms]  (8960 events/s, 112 μs/event)
1000 events control: bare subscribe:  median 38 ms  [27 ms .. 46 ms]  (26248 events/s, 38 μs/event)
1000 events candidate: bare subscribe:  median 24 ms  [19 ms .. 40 ms]  (41827 events/s, 24 μs/event)
5000 events control: bare subscribe:  median 86 ms  [67 ms .. 274 ms]  (58467 events/s, 17 μs/event)
5000 events candidate: bare subscribe:  median 70 ms  [63 ms .. 98 ms]  (71424 events/s, 14 μs/event)
```

Isolated local tail medians and append visibility:

```text
control medians tail/append ms: (120.21900000000001,65.756)
warm medians tail/append ms: (121.89,60.803000000000004)
cold medians tail/append ms: (121.41399999999999,66.99199999999999)
Verified 501 seeded + 7500 concurrently appended events; final visible head 8001.
```

All 654 examples across six Cabal suites, the ten-step example, both Nix package
builds, bundle validations, formatting and structural checks pass. The Nix
package derivations disable test execution; Cabal supplies the runtime tests.
