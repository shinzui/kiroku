---
id: 84
slug: harden-adapter-acknowledgement-liveness-and-expose-retry-policy
title: "Harden adapter acknowledgement liveness and expose retry policy"
kind: exec-plan
created_at: 2026-08-27T21:14:25Z
intention: "intention_01m12ed0r5e61aqa9h1rfgvk4a"
master_plan: "docs/masterplans/12-harden-the-kiroku-event-store-and-subscription-machinery-surfaced-by-the-2026-07-kiroku-review.md"
provenance:
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      verdict: "changes-requested"
      note: "Perf review: pending-ack must be one cell per adapter with a parked watchdog; overhead bench missing"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-09T23:32:21Z
      mode: "update"
      note: "Single pending-ack cell with parked watchdog, overhead bench in steps and acceptance"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T00:37:26Z
      mode: "update"
      note: "Design review: stall watchdog moved into the store worker as handlerStallWarnAfter and KirokuEventSubscriptionHandlerStalled; adapter forwards the field"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-10T01:21:50Z
      mode: "update"
      note: "Design review, second pass: RetryPolicy unchanged; adapter configs adopt BatchSize, StreamBufferSize, and mkConsumerGroup"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-09T16:21:16Z
      mode: "update"
      note: "Audit source at e6ea664; distinguish completed baseline from remaining work, refresh request coverage and performance evidence requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T18:48:29Z
      mode: "update"
      note: "Apply user PostgreSQL 18-only testing scope."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-10T00:17:55Z
      mode: "implement"
      note: "Cascade focused assurance and EP6 cumulative benchmark ownership."
---

# Harden adapter acknowledgement liveness and expose retry policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The 2026-10-09 performance requirement supersedes the original default-enabled warning proposal:
stall diagnostics are opt-in in the store and both adapter configs. Correctness and acknowledgement
handling remain enabled; only advisory tracking is optional, under ADR-11.

`shibuya-kiroku-adapter` is acknowledgement-coupled: after yielding one event, the Kiroku worker
waits inside its handler call until Shibuya finalizes its `AckDecision`. Shibuya Core's
standard runner already catches a synchronous handler exception, substitutes
`AckRetry (RetryDelay 0)`, and separately retries finalization, but raw consumers of
`adapter.source` can still leave the acknowledgement pending forever, and a bare Kiroku subscriber
whose handler blocks has exactly the same silent-liveness problem. The adapter also cannot forward
Kiroku's configurable retry-attempt policy.

After this plan, the store worker itself reports a handler that has held one event longer than a
configured threshold, for every subscriber kind, through a typed
`KirokuEventSubscriptionHandlerStalled` event; the recommended single-processor helper applies the
existing paced exception guard; and both single and consumer-group adapter configuration expose
`RetryPolicy` and forward the stall threshold. Tests distinguish the supported runner's current
non-wedging behavior from the structurally possible raw-source wedge, then prove guarded retry,
the stall event on both the raw adapter path and a bare subscription, and custom dead-letter
counts.


## Progress

- [x] (2026-10-09) Focused verification: pass correctness and existing ADR-5 checks; reserve cumulative append and real-adapter diagnostic cost comparison for EP6 under ADR-11. No new per-child benchmark queue.
- [x] (2026-10-09) Before implementation: select bounded real-acknowledgement and stall enabled/disabled correctness tests, and structural checks that the default has no clock reads, timers or per-event diagnostic writes.
- [x] (2026-10-09) M1: reproduce the resolved Shibuya Core exception/finalization behavior and the raw-source pending-ack case with bounded integration tests.
- [x] (2026-10-09) M2: export `kirokuProcessor` as the recommended guarded single-processor path and correct module/user documentation.
- [x] (2026-10-09) M2: add `handlerStallWarnAfter` to `SubscriptionConfigM` with a single-cell, parked watchdog in the store worker emitting `KirokuEventSubscriptionHandlerStalled`; forward the field from both adapter configs.
- [x] (2026-10-09) M3: expose and thread `retryPolicy` through single and consumer-group configs, adopt plan 82's validated size types on both configs, and prove default and custom delivery counts.
- [x] (2026-10-09) Run adapter and store suites plus existing ADR-5 checks; 504 examples, 20 structural checks and 16 controlled workload cases pass; ADR-13 distills the contract.


## Surprises & Discoveries

- Implementation (2026-10-09): Mori source confirms the resolved Shibuya 0.10 runner
  uses zero-delay exception retry and separate finalization. `mkProcessor` defaults to
  `Unordered`, `Serial`; the new helper preserves those defaults and applies the existing
  one-second guard. Four real-store acknowledgement cases pass in 2.0347 seconds.
- Enabled diagnostics reuse an active interval timer across fast completed/replaced calls.
  Cancelling and recreating `registerDelay` on every cell change would leave abandoned
  registrations per event. The watchdog owns one outstanding timer and parks after at
  most one residual idle wakeup. No timer or tracking work exists in the disabled arm.
- The adapter needs a direct `time` dependency for its public duration fields. Its existing
  test/application/store bounds (`>=1.12 && <1.15`) are reused. Mori located the API;
  authoritative Hackage metadata and upstream tags report newer 1.16.0.1, but no upgrade
  or compatibility workaround is needed for the already resolved 1.14 API.
- Two fixture assumptions failed and were corrected: the adapter dead-letter helper
  read only member 0, so the size-2 test now reads both member keys; the native quick-first/
  blocked-second test expected a per-event save, but ordinary progress is persisted at the
  batch boundary. The blocked batch correctly retains checkpoint zero. Failure transcripts
  are retained alongside verified outcomes; these are correctness fixture corrections,
  not performance retries.
- Final correctness (2026-10-09): 504 examples pass across all six workspace suites,
  including 13 new store stall cases, seven adapter liveness/policy cases, and one
  metrics JSON/Prometheus counter case. PostgreSQL on PATH is 18.6, GHC 9.12.4,
  Cabal 3.16.1.0; all-component build passes. Strict ADR validation passes 13
  concepts and capability validation passes 21.

- Refresh audit (2026-10-09): source, tests, and changelogs confirm the remaining acceptance
  work is unimplemented; the dated Context audit distinguishes existing baseline from this plan.
- Transfer audit (2026-08-27): Mori-located `mori://shinzui/shibuya/packages/shibuya-core` is at
  the current 0.9 line. Its supervised `processOne` still catches handler exceptions as immediate
  retry decisions and calls `finalizeWithRetry` separately. The standard runner is not the
  unfinalized-ack path described by the July review.
- Transfer audit (2026-08-27): `guardKirokuHandler` and
  `kirokuConsumerGroupProcessors` already provide a one-second paced retry guard; the missing
  ergonomic surface is the equivalent recommended helper for a single `KirokuAdapterConfig`.


## Decision Log

- Decision (2026-10-09): preserve `Maybe NominalDiffTime`, reject nonpositive enabled
  intervals before checkpoint initialization through `InvalidHandlerStallWarnAfter`
  and `SomeSubscriptionStartupFailure`, and document the narrow ADR-8 exception in ADR-13.
  Rationale: zero/negative intervals would permit a warning spin; the planned duration
  API needs a defined refusal without introducing another public wrapper type.
- Decision (2026-10-09): select a tracked ordinary handler once at worker construction;
  use `mask`/`finally` for the cell and scoped `withAsync` cancellation/join for the watchdog.
  Rationale: all delivery phases share the same boundary, while disabled diagnostics have
  no per-event branch. Decode-error callbacks are outside this ordinary-handler boundary.
  [ADR-13](../adr/0013-handler-stall-diagnostics-are-worker-owned-and-advisory.md) records the contract.

- Decision (2026-10-09): required testing for this cohort uses PostgreSQL 18.
  The user explicitly removed PostgreSQL 17 testing; preserve already collected
  PostgreSQL 17 evidence without requiring more trials. ADR-11 and the parent
  MasterPlan carry this scope correction.

- Decision: Apply ADR-11's write-performance constraint to this child's implementation and release
  evidence, including indirect CPU/GC/pool/checkpoint effects where applicable.
  Rationale: The user explicitly prioritizes performance, especially writes. A confirmed regression
  requires correction; unchanged append SQL alone is insufficient evidence.
  Date: 2026-10-09

- Decision: Require direct controlled performance evidence for real-adapter acknowledgement and watchdog enabled/disabled workloads.
  Rationale: The 2026-10-09 audit found that the named overhead benchmark measures primarily
  catch-up and uses a synthetic adapter; it cannot establish the broader performance claims.
  This applies ADR-5 without changing the planned public API. The later user-approved scope
  reserves this controlled comparison for EP6 rather than an additional per-child queue.
  Date: 2026-10-09

- Decision: Preserve the structural acknowledgement wait and make its watchdog observability-only.
  Rationale: Auto-finalization races a slow correct handler and can turn a later `AckOk` into an
  unnecessary redelivery. A warning closes silent-liveness diagnostics without changing delivery
  semantics.
  Date: 2026-08-27
  Location moved on 2026-09-09: the watchdog lives in the store worker; the observability-only
  rule is unchanged.

- Decision: Export `kirokuProcessor` rather than changing `kirokuAdapter` to own a handler.
  Rationale: An adapter is a source and does not receive the handler that a processor will run.
  The helper can compose `mkProcessor` with `guardKirokuHandler` while retaining the low-level raw
  adapter for advanced users.
  Date: 2026-08-27

- Decision: Add `retryPolicy` directly to both exported configuration records and default it to
  `defaultRetryPolicy`.
  Rationale: Both APIs already direct callers to extensible `default*Config` constructors. The
  policy is a Kiroku subscription concern and should pass through without an adapter-specific
  duplicate type.
  Date: 2026-08-27

- Decision: Track the pending acknowledgement in one mutable cell per adapter, clear it inside the
  finalizer's existing STM transaction, and park the watchdog on STM until an item is pending.
  Rationale: The bridge is acknowledgement-coupled, so at most one event is outstanding per
  adapter; a map or a polling thread would add allocation and wake-ups to every event for no
  information. Fixed by the 2026-09-09 performance review under
  [ADR-5](../adr/0005-three-tier-performance-regression-gates.md).
  Date: 2026-09-09
  Superseded later on 2026-09-09: the cell is one per worker, not one per adapter; the budget is
  unchanged.

- Decision: Implement the stall watchdog in the store worker around the handler call in
  `processEvents`, configured by `handlerStallWarnAfter` on `SubscriptionConfigM`, and have the
  adapter only forward that field.
  Rationale: A pending acknowledgement is a handler that has held one event too long, and a bare
  `subscribe` handler that blocks has the same problem. One worker-level cell and event serve
  every subscriber kind, and the store's observability vocabulary stays free of adapter-specific
  constructors. The single-cell, parked-thread budget from the performance review is unchanged;
  it moves one level down.
  Date: 2026-09-09


## Outcomes & Retrospective

EP4 is Complete. The ordinary handler watchdog is store-owned, scoped and opt-in;
`Nothing` selects the original handler without per-event diagnostic work. Enabled
warnings identify the pending invocation and preserve acknowledgements, checkpoints
and state. Completion, exception and cancellation clear tracking and end the watchdog.
The single helper preserves Shibuya defaults with one-second guarded retries; both
adapter configs forward total attempt limits and warning intervals to every member.

All 504 workspace examples pass: 373 store, 45 adapter, 23 metrics, 17 OpenTelemetry,
24 migration and 22 CLI. The all-component build passes. Existing `just perf-check`
passes 20 structural checks and 16 controlled workload cases (116.73 seconds for the
workload gate). Strict ADR validation passes 13 concepts; capabilities pass 21.
PostgreSQL is 18.6, GHC 9.12.4, Cabal 3.16.1.0, aarch64 macOS, Cabal O1.
Retained evidence is in
`kiroku-store/bench/results/ep4-acknowledgement-liveness/README.md`.

Two initial fixture assertions failed and were corrected without changing production
behavior: group dead-letter reads require both member keys, and normal native progress
saves at the batch boundary. Failure logs are retained. The existing category-append
control remains noisy (44.4 ± 48 ms), so favorable controlled ratios do not establish
cohort performance neutrality. No new remote experiment or per-child benchmark queue
ran. Cumulative default and opt-in costs remain EP6 concerns under ADR-11, with the
original-control policy, adverse samples and uncertainty preserved. No release occurred.

ADR-13 records worker ownership, timer reuse and consumer finalization; ADR-8 now
explicitly documents nonpositive raw-duration refusal as its narrow configuration
exception. The config and event/counter additions are source-breaking and belong in
EP6's version selection. Timer reuse avoids an abandoned registration per quick event;
one existing timer can wake after completion before the enabled watchdog parks.


## Context and Orientation

Source audit (2026-10-09, `e6ea664`): implementation remains Not Started. The adapter now has
masked group-acquisition cleanup, and the ack-stream bridge closes its subscription-to-monitor
ownership window and joins the monitor on shutdown. The adapter 0.5.1.3 changelog and
[BUG-4](../bug-reports/partial-consumer-group-acquisition-strands-members.md) record that completed
work. Existing tests cover first-wins acknowledgements, AckHalt replay, cancellation before
checkpoint persistence, guarded exceptions, and partial-construction cleanup. Preserve and reuse
those tests; they do not prove the remaining raw-unfinalized stall warning or custom retry policy.
`kirokuProcessor`, both policy fields, and the store stall event remain absent.

The checked-in adapter now requires `shibuya-core >=0.10 && <0.11`; the historical references to
0.9 below describe the transfer baseline. Mori-located source at
`mori://shinzui/shibuya/packages/shibuya-core`, in `Shibuya.Internal.Runner.Supervised.processOne`,
still substitutes `AckRetry (RetryDelay 0)` after a synchronous handler exception and calls
`finalizeWithRetry` separately. Recheck the resolved source at implementation time.

The final adapter API consumed completed plans 81 and 82 for validated group/batch/buffer types;
acknowledgement characterization can be prepared earlier. The independent lifetime-guard field
belongs to [plan 92](92-expose-the-lifetime-member-guard-in-the-shibuya-adapter.md), implementing
IR-17 after plan 93 implements IR-15. Preserve those fields if they land first.

The current `kiroku-shibuya-overhead` benchmark builds a synthetic adapter over
`subscriptionStream` with no-op normal finalization, not the production `kirokuAdapter`, and
preloads its events. Opt-in stall tracking adds clock/STM work plus watchdog scheduling
and timer bookkeeping on the healthy path. Direct real-adapter and enabled/disabled measurements
are release-stage concerns; no performance-neutrality claim follows from the existing benchmark.

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` defines `KirokuAdapterConfig`,
`KirokuConsumerGroupConfig`, defaults, `kirokuAdapter`, `guardKirokuHandler`, and the
consumer-group processor factory. `kirokuAdapter` builds a store `SubscriptionConfig` but leaves
its `retryPolicy` at the Kiroku default. The group factory forwards most fields into one adapter
per member and automatically wraps its handler with `guardKirokuHandler`.

`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` implements `subscriptionAckStream`. Its
bridge handler writes an `AckItem` containing an empty `TMVar` and blocks on `takeTMVar`; that
handler is the `handler config event` call inside `processEvents` in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, so while an acknowledgement is pending the
worker is blocked inside its own delivery primitive. In
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`, `toIngestedAck` creates an
idempotent first-wins finalizer with `tryPutTMVar`. If a consumer reads `adapter.source` and never
finalizes, the worker remains blocked and can still appear `Live`. A bare `subscribe` caller whose
handler blocks is indistinguishable from the store's point of view, which is why the watchdog
belongs around the handler call rather than in the adapter.

The standard Shibuya runner dependency was located and read via Mori at
`mori://shinzui/shibuya/packages/shibuya-core`. Its current `processOne` and
`finalizeWithRetry` paths prevent an ordinary synchronous handler exception from abandoning the
ack, although the substituted zero-delay retry can be much faster than the adapter's one-second
guard.

`Kiroku.Store.Subscription.Types.RetryPolicy` counts total deliveries before dead-lettering.
`AckRetry (RetryDelay d)` chooses the delay before the next attempt; the two settings are
orthogonal. ADR-13 now records this adapter boundary, shared worker ownership, and enabled timer behavior.

[ADR-5](../adr/0005-three-tier-performance-regression-gates.md) makes `just perf-check`
authoritative for performance evidence, and the `kiroku-shibuya-overhead` benchmark in
`kiroku-store/bench/ShibuyaOverhead.hs` measures the adapter layer against `subscriptionStream`
on the same store, which is supplementary catch-up/framework evidence; its synthetic adapter does not exercise
the production acknowledgement bridge this plan configures.


## Plan of Work

### Milestone 1 — pin the two acknowledgement paths

In `shibuya-kiroku-adapter/test/Main.hs`, add a real-store test using `kirokuAdapter`,
`mkProcessor`, and `runApp` with a handler that throws synchronously on its first call. Assert the
current Shibuya Core behavior: the event is immediately redelivered, finalization occurs, and the
next event is eventually processed. Record actual attempts and timing in Surprises & Discoveries.

Add a separate raw-source test that reads one `Ingested` from `adapter.source` and intentionally
does not call its finalizer. Prove a second event is not delivered within a bounded window while
the subscription remains registered. This test owns the actual pending-ack hazard; do not conflate
it with the standard runner test.

### Milestone 2 — make the safe surface and stalled state visible

Export `kirokuProcessor` from `Shibuya.Adapter.Kiroku` with the same policy/concurrency arguments
required by the current `Shibuya.App.mkProcessor`, but always wrap the supplied handler in
`guardKirokuHandler`. Change single-adapter examples and `docs/user/shibuya-adapter.md` to use it.
Keep direct `kirokuAdapter` and `mkProcessor` use documented as advanced: Shibuya's standard runner
finalizes exceptions, while custom/raw consumers must finalize every item.

Add `handlerStallWarnAfter :: Maybe NominalDiffTime` to `SubscriptionConfigM` in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, defaulting to `Nothing` (disabled) in
`defaultSubscriptionConfig`. In `Worker.hs`, give each worker with diagnostics enabled one
`TVar (Maybe StalledDelivery)`
holding the event position and id and a monotonic start time. The selected handler wrapper writes the cell
immediately before the ordinary handler and clears it in `finally`, in the same code path
for every target and both phases. Start one watchdog thread per enabled worker alongside the existing
worker body so cancellation covers it; it blocks on the cell with STM `retry` while empty, then
waits with `registerDelay`, reuses its timer across quick calls, and if the current delivery has reached the threshold emits
`KirokuEventSubscriptionHandlerStalled` through the worker's event handler with the elapsed time,
at most once per threshold interval. It never finalizes, never touches the checkpoint, and never
polls while idle. When the setting is `Nothing`, allocate no tracking cell, start no thread or timer, and perform
no per-delivery clock read or tracking STM write. Select the ordinary handler path at worker
construction so disabled diagnostics add no per-event tracking work.

In the adapter, add `handlerStallWarnAfter` to `KirokuAdapterConfig` and
`KirokuConsumerGroupConfig` with the same `Nothing` default, and forward it into the store
`SubscriptionConfig` for the single adapter and for every group member. The adapter adds no
watchdog and no observability constructor of its own.

Set an explicit threshold in the raw-source test and expect `KirokuEventSubscriptionHandlerStalled`, add a store-side test
under `kiroku-store/test` in which a bare `subscribe` handler blocks past a short threshold and the
event is emitted once, and add shutdown plus finalize-before-threshold tests proving no event and
no leaked thread. Add a guarded helper test in which a one-shot exception is retried after
approximately one second and processing continues.

### Milestone 3 — expose retry policy

Add `retryPolicy :: RetryPolicy` to both configs and both defaults, change `batchSize` on both
configs to plan 82's `BatchSize` and `bufferSize` on `KirokuAdapterConfig` to `StreamBufferSize`
with the current default values, and forward all three unchanged. Thread the policy through
`kirokuAdapter` into `Sub.retryPolicy` and through the group factory to each member. Document that
`retryMaxAttempts` is total deliveries, while each `AckRetry` decides delay.

Extend the ack-disposition tests: the default still delivers five times before dead-lettering; a
single adapter configured for two attempts delivers exactly twice; a size-2 group forwards the
same policy to each member. Use zero-delay explicit decisions for counting tests and the guarded
one-second path only for the exception test.


## Concrete Steps

Select bounded real-adapter acknowledgement tests, using actual finalization. Default diagnostics to `Nothing`; verify structurally that this path creates no
tracking cell, watchdog, timer, per-delivery clock read, or tracking STM write. EP6 compares the default
with the original control and measures enabled diagnostics separately as opt-in. Record its cost without
charging it to default callers or weakening acknowledgement/checkpoint semantics.

Complete plans 81 and 82 before landing the final adapter API. Define the direct production-adapter
and enabled/disabled watchdog controls described in Validation and Acceptance before coding;
record the selected correctness/structural checks here; reserve benchmark commands for EP6.

Run from the Kiroku repository root:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter-test \
  --test-show-details=direct \
  --test-options='--match "acknowledgement liveness"'
cabal test shibuya-kiroku-adapter-test \
  --test-show-details=direct \
  --test-options='--match "retry policy"'
cabal test kiroku-store:kiroku-store-test \
  --test-show-details=direct \
  --test-options='--match "handler stall"'
```

The focused transcripts must contain examples equivalent to:

```text
acknowledgement liveness
  standard Shibuya handler exceptions are finalized [OK]
  guarded single processor retries with pacing and continues [OK]
  raw unfinalized acknowledgement surfaces as a handler-stall event [OK]
retry policy
  preserves five-delivery default [OK]
  honors two total deliveries for one adapter [OK]
  forwards policy to every consumer-group member [OK]
handler stall
  emits once when a bare subscribe handler blocks past the threshold [OK]
  emits nothing when the handler finishes before the threshold or the worker stops [OK]
```

Then run:

```bash
cabal test shibuya-kiroku-adapter-test --test-show-details=direct
cabal test kiroku-store:kiroku-store-test --test-show-details=direct
```

Run existing correctness and ADR-5 checks. Additional overhead measurements are
reserved for the focused cumulative EP6 release experiment.


## Validation and Acceptance

Focused implementation acceptance (user direction, 2026-10-09):
[ADR-11](../adr/0011-subscription-hardening-protects-write-performance-and-keeps-stall-diagnostics-opt-in.md)
requires correctness and existing structural/controlled checks now. Keep append
SQL/round trips and ordinary checkpoint frequency unchanged. Keep stall tracking
`Nothing` by default with no diagnostic clock reads, timers or per-event writes.
Test real acknowledgement finalization, catch-up/confirmed live delivery, retry
counts, cancellation and enabled/disabled stall behavior. Record the explicit
opt-in timer/wakeup cost as a release measurement concern. The synthetic
`kiroku-shibuya-overhead` cannot prove real adapter cost; running it before/after
is optional evidence rather than required acceptance.

Do not launch another per-child benchmark queue or require a full workload
matrix. EP6 owns a focused cumulative comparison against original `e6ea664`,
including real acknowledgements and opt-in diagnostic costs as applicable, within
the user's one-hour whole-experiment ceiling. Retain inconclusive/adverse results
and the original policy; confirmed event-append regressions still block release.

The standard current Shibuya pipeline must never be claimed to wedge on a synchronous handler
exception; its regression test must demonstrate finalization. The new `kirokuProcessor` path must
turn the same exception into a paced retry and continue. A deliberately unfinalized raw-source
item must produce `KirokuEventSubscriptionHandlerStalled` from the store worker within its
configured threshold while remaining unfinalized, a blocking bare `subscribe` handler must produce
the same event, and finalization, handler completion, or worker shutdown must stop future
emissions.

Changing `retryMaxAttempts` to two must yield exactly two deliveries and then one dead-letter row
on both the single and group paths. Defaults remain five. Full adapter and relevant store suites
must pass, and user documentation must explain raw-source responsibility, stall-event semantics,
and the difference between attempt policy and delay. Existing ADR-5 checks must pass; cumulative real-adapter/opt-in costs remain EP6 work.


## Idempotence and Recovery

All tests use isolated databases and are repeatable. Warning emission is advisory and periodic;
it never writes an acknowledgement or checkpoint. Finalization remains first-wins and idempotent.
Watchdog shutdown must be safe to call repeatedly and must not outlive the worker it belongs to.

Existing callers using `defaultKirokuAdapterConfig` or `defaultConsumerGroupConfig` inherit the
new fields, with stall warnings disabled; enabling them requires an explicit duration such as
`Just 60`. Update all warning tests to set a duration explicitly and add a default-disabled test. Full record literals require a source update and therefore affect the eventual PVP
release decision in plan 85. If stall events are too noisy, callers may tune the duration or set
`Nothing` without changing delivery semantics.


## Interfaces and Dependencies

`Shibuya.Adapter.Kiroku` exports `kirokuProcessor` with the exact current `mkProcessor` policy and
concurrency shape, plus these record fields on both relevant configs, each forwarded unchanged to
the store:

```haskell
retryPolicy :: RetryPolicy
handlerStallWarnAfter :: Maybe NominalDiffTime
```

`Kiroku.Store.Subscription.Types.SubscriptionConfigM` gains the same
`handlerStallWarnAfter :: Maybe NominalDiffTime` field, and
`Kiroku.Store.Observability.KirokuEvent` gains:

```haskell
KirokuEventSubscriptionHandlerStalled
    :: SubscriptionName
    -> GlobalPosition
    -> EventId
    -> NominalDiffTime
    -> SubscriptionGroupContext
    -> KirokuEvent
```

`InvalidHandlerStallWarnAfter` joins the existing startup-failure family for nonpositive intervals.

Use `GHC.Clock.getMonotonicTimeNSec` from `base` for the start time; do not introduce wall-clock
ordering into tests. The Shibuya API source of truth is
`mori://shinzui/shibuya/packages/shibuya-core`. Plan 83 adds its own observability constructor and a
`StopUndecodable` stop reason; `RetryPolicy` is unchanged and is forwarded as is, and both
observability constructors must survive exhaustive matches. Plan 82 replaces `Int32` batch sizes
and `Natural` buffer sizes with validated `BatchSize` and `StreamBufferSize`, and plan 81 replaces
the `ConsumerGroup` constructor with `mkConsumerGroup`; both adapter configs adopt those types and
the group factory builds members through the constructor. Plans 82 and 83 also edit `Worker.hs`;
keep the stall cell writes in the selected handler wrapper around the ordinary call.

Revision note (2026-09-09): Performance review under ADR-5. Fixed the pending-ack record to one
cell per adapter cleared in the finalizer's existing STM transaction with a parked, non-polling
watchdog, and added the `kiroku-shibuya-overhead` before/after run to the concrete steps and
acceptance.

Revision note (2026-09-09): Design review. Moved the stall watchdog from the adapter into the store
worker as `handlerStallWarnAfter` plus `KirokuEventSubscriptionHandlerStalled`, so bare
subscriptions, the ack stream, and the adapter share one event and the store's vocabulary carries
no adapter-specific constructor; the adapter now forwards the field. The per-adapter cell decision
from the morning performance review is marked superseded. Title and file name are retained for
reference stability.

Revision note (2026-09-09): Design review, second pass. `RetryPolicy` is unchanged after plan 83's
revision; both adapter configs adopt plan 82's validated `BatchSize` and `StreamBufferSize` and
plan 81's `mkConsumerGroup`.

Revision note (2026-10-09): Audited current source, tests, migrations, and related records at
`e6ea664`; retained unfinished milestones, documented existing baseline and actual request
coverage, and refreshed integration/performance context. This is a documentation update, not
implementation or new runtime-test evidence.

Revision note (2026-10-09, write-performance requirement): Applied ADR-11 and blocking write-path
acceptance, with per-child ownership and evidence requirements. The user explicitly prioritizes
write performance. Implementation and benchmark gates remain open.

Revision note (2026-10-09): Cascade user-approved focused implementation assurance and EP6 cumulative performance ownership from the MasterPlan; remove obsolete mandatory per-child benchmark matrices.

Revision note (2026-10-09, EP4 implementation): real acknowledgement characterization and
store diagnostics are implemented. Reuse a timer across short invocations, preserve Shibuya's
resolved defaults, and define nonpositive-duration refusal through the common exception family.
Correctness and local ADR-5 verification pass; cumulative timing remains EP6 work.

Revision note (2026-10-09, EP4 completion): all milestones and focused local acceptance pass;
retain full workspace and existing gate evidence, document fixture corrections and measurement
limits, and mark the child Complete. Cumulative timing and publication remain EP6 work.
