---
id: 57
slug: harden-shibuya-adapter-ack-contract-and-overflow-policy
title: "Harden shibuya adapter ack contract and overflow policy"
kind: exec-plan
created_at: 2026-06-11T04:32:45Z
master_plan: "docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md"
---

# Harden shibuya adapter ack contract and overflow policy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

> **HARD DEPENDENCY — do not start this plan until EP-1 is Complete.**
> This plan is EP-2 of the master plan at
> `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.
> It hard-depends on EP-1
> (`docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`),
> which changes `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` so that the
> bridge stream *terminates with the worker's outcome*: a clean end when the
> subscription stops gracefully, and a rethrown exception into the stream consumer
> when the worker crashed. Milestone 3 of this plan consumes exactly that surface.
> Before starting, re-read plan 56's "Outcomes & Retrospective" section for the
> final shape it shipped. As authored, plan 56 implements the contract with a
> terminal `TVar (Maybe BridgeTermination)` consulted via STM `orElse` in the
> reader step (not a terminal queue element — a queue write can block when the
> queue is full, which is the very defect plan 56's M1 also fixes). The observable
> behavior this plan consumes is mechanism-independent: a clean stop or
> cancellation ends `adapter.source` without error, and a worker crash rethrows
> the worker's exception to whoever is pulling the stream. Line numbers cited in
> this plan were verified on 2026-06-10, before EP-1 landed; expect small shifts
> in `Stream.hs` and re-verify locations rather than trusting offsets blindly.


## Purpose / Big Picture

The `shibuya-kiroku-adapter` package (in this repository, under
`shibuya-kiroku-adapter/`) connects Kiroku — a PostgreSQL event store whose
subscriptions *push* events at a handler — to Shibuya, a queue-processing
framework that *pulls* messages from an adapter stream and lets application
handlers acknowledge each one. A 2026-06-10 audit found four defects in this
adapter that share one theme: a Shibuya processor backed by Kiroku can stop
consuming events forever while looking perfectly healthy.

After this plan is implemented, all four are closed and the adapter's
acknowledgement contract is hardened end to end:

1. A burst of appended events can no longer kill the subscription. The adapter
   today pins the fail-fast `DropSubscription` overflow policy; any burst larger
   than about 16,000 events while the handler is busy terminates the
   subscription. After this plan the adapter uses Kiroku's lossless
   `PauseAndResume` recovery, and a new `queueCapacity` configuration field makes
   the real backpressure knob visible and testable.
2. A Shibuya handler that throws an exception can no longer wedge the
   subscription forever. Today a thrown handler exception means the
   acknowledgement is never finalized, and the Kiroku worker blocks eternally on
   a reply that will never come — no retry, no dead-letter, no crash, no
   checkpoint movement. After this plan, an exported guard wrapper (applied
   automatically by the consumer-group helper) converts a handler exception into
   a real disposition: the event is retried with a delay and, if it keeps
   failing, dead-lettered by Kiroku's bounded retry policy, and processing
   continues with the next event.
3. When the underlying Kiroku worker crashes, the adapter's stream now ends with
   that error (consuming EP-1's new termination contract) instead of hanging,
   and the adapter's documentation tells the truth about what Shibuya's runners
   do with that error today.
4. `kirokuConsumerGroupProcessors` with `groupSize <= 0` now throws
   `InvalidConsumerGroup` instead of silently returning an empty processor list,
   and a failure while creating member `k`'s adapter shuts down members
   `0..k-1` instead of leaking their live subscriptions. A zero buffer size,
   which would deadlock the bridge permanently, is rejected up front.

To see it working: run the adapter test suite (`cabal test
shibuya-kiroku-adapter-test` from the repository root — it boots its own
ephemeral PostgreSQL, no external services needed) and observe the new
behavioral tests pass: the burst test delivers every event despite a paused
subscriber; the throwing-handler tests show event N being retried then
dead-lettered while event N+1 still gets processed; the group-size tests show
the validation exception and the partial-failure cleanup.

Downstream note: the `keiro` project consumes `kiroku-store` (and this adapter)
by a git SHA pin in its `cabal.project`. After this plan ships, downstream
consumers need a push of this repository plus a pin bump on their side to pick
up the fixes. Planning that bump is out of scope here.


## Progress

- [ ] M1: Add `queueCapacity` field to `KirokuAdapterConfig` and `KirokuConsumerGroupConfig` (default 16) and stop pinning `overflowPolicy = DropSubscription` in `kirokuAdapter` (inherit `PauseAndResume`).
- [ ] M1: Reject zero bridge capacity: `InvalidStreamBufferSize` guard in `Kiroku.Store.Subscription.Stream.subscriptionAckStream`; rewrite the misleading `bufferSize` "backpressure threshold" Haddocks in the adapter.
- [ ] M1: Burst test: gated handler + `queueCapacity = 1` + multi-batch append delivers every event with no `SubscriptionOverflowed` and no processor failure.
- [ ] M1: Bump `shibuya-kiroku-adapter` to 0.4.0.0; update CHANGELOG and stale Haddock/cabal examples that use full `KirokuAdapterConfig` record literals.
- [ ] M2: Implement and export `guardKirokuHandlerWith` / `guardKirokuHandler` in `Shibuya.Adapter.Kiroku` (exception → finalized disposition); raise `effectful-core` lower bound to 2.5 for `catchSync`.
- [ ] M2: Apply the guard automatically inside `kirokuConsumerGroupProcessors`; document the "handlers must not throw" contract loudly in the module Haddock.
- [ ] M2: Tests: transiently-throwing handler recovers via retry (attempt increments, then `AckOk` path checkpoints); persistently-throwing handler is dead-lettered (`kiroku.dead_letters` row exists) and the next event is still processed.
- [ ] M2: Record the two shibuya-core upstream follow-ups (finalize-on-exception in `processOne`; ingester failure propagation in `runSupervised`) in this plan and in the adapter CHANGELOG "known limitations" note.
- [ ] M3: Verify and lock EP-1's termination contract at the adapter boundary: clean shutdown ends `adapter.source` without error; a crashed worker rethrows out of `adapter.source` (test via fault injection mirroring EP-1's technique).
- [ ] M3: Fix stale adapter prose: cabal `description` still claims ack is a no-op; module Haddock "Ack Semantics"/"Backpressure" sections updated for guard wrapper, PauseAndResume, and error-carrying stream end.
- [ ] M4: `kirokuConsumerGroupProcessors` validates `groupSize >= 1` up front (throws `InvalidConsumerGroup`); creation runs through a cleanup-on-partial-failure helper.
- [ ] M4: Tests: `groupSize = 0` and `groupSize = -1` throw `InvalidConsumerGroup` (no `Right []`); injected factory failure at member 2 of 3 shuts down members 0 and 1 exactly once.
- [ ] Final: full `just test` green; Outcomes & Retrospective written; master plan registry row for EP-2 flipped to Complete.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Switch the adapter to Kiroku's default `PauseAndResume` overflow
  policy by deleting the pinned `overflowPolicy = DropSubscription` override, and
  do not expose `overflowPolicy` as adapter configuration.
  Rationale: The ack-coupled worker is *by construction* exactly as fast as the
  Shibuya handler — it blocks per event on a reply variable
  (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`, `bridgeHandler`), so
  "slow consumer" is the adapter's steady state, not an anomaly worth failing
  fast on. Fail-fast has no benefit here: before EP-1 the thrown
  `SubscriptionOverflowed` was swallowed (silent stall); after EP-1 it would
  loudly kill a healthy-but-busy projection that `PauseAndResume` recovers
  losslessly (the worker re-reads missed events from its checkpoint — no event
  loss, monotonic checkpoint). Worse, the worker never reads its overflow status
  during catch-up (`Worker.hs` `nextInput`, `CatchingUp` branch), so overflow
  accumulated during a long catch-up would kill the subscription the instant it
  went live. Exposing `overflowPolicy` would let users reintroduce this exact
  trap, so the adapter stays opinionated; users needing lossy `DropOldest`
  semantics can use `kiroku-store` subscriptions directly.
  Date: 2026-06-10

- Decision: Expose `queueCapacity` (publisher-side batch capacity, default 16)
  as a new field on `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`.
  Rationale: It is the *real* backpressure knob (capacity is `queueCapacity ×
  publisherBatchSize` = 16 × 1000 events by default), it was previously pinned
  invisibly, and tests need `queueCapacity = 1` to exercise pause/resume cheaply
  (the kiroku-store suite does exactly this in
  `kiroku-store/test/Test/SubscriptionPauseResume.hs`). Adding a field to an
  exported record constructor is API-breaking for record-literal users, hence
  the 0.4.0.0 version bump; `defaultKirokuAdapterConfig` /
  `defaultConsumerGroupConfig` shield users who follow the documented pattern.
  Date: 2026-06-10

- Decision: Defend against throwing handlers with an adapter-side wrapper
  (`guardKirokuHandlerWith` / `guardKirokuHandler`) whose default maps any
  synchronous exception to `AckRetry (RetryDelay 1)`, letting Kiroku's bounded
  `RetryPolicy` (default five deliveries) convert persistent failure into a
  `DeadLetterMaxAttempts` dead-letter. A custom `SomeException -> AckDecision`
  variant is provided for handlers that prefer immediate
  `AckDeadLetter (PoisonPill <exception text>)`.
  Rationale: This matches Shibuya's intended semantics most closely: Shibuya's
  supervised runner treats a handler exception as "not finalized", which for a
  conventional broker (e.g. SQS visibility timeout) means *the broker redelivers
  later* — i.e. retry. Kiroku's ack bridge has no redelivery timeout, which is
  why "not finalized" wedges it; retry-with-delay restores the intended
  meaning. Retry-then-dead-letter is strictly better than immediate dead-letter
  as a default: transient failures (a projection database hiccup) recover, and
  persistent failures still terminate via the retry policy. Acknowledged
  trade-off: the eventual dead-letter row carries the attempt count, not the
  exception text; handlers that want forensic text in the dead-letter row
  should use the `guardKirokuHandlerWith` variant or catch and return
  `AckDeadLetter` themselves. Only *synchronous* exceptions are caught
  (`Effectful.Exception.catchSync`); asynchronous cancellation must keep
  killing the handler thread.
  Date: 2026-06-10

- Decision: Reject the watchdog alternative (the bridge converting "consumer
  abandoned the reply" into a `Retry` after a timeout).
  Rationale: A timeout cannot distinguish "handler threw and abandoned the
  reply" from "handler is legitimately slow", so any chosen value either fires
  spuriously on slow handlers — breaking the ack-coupling invariant that
  exactly the handler's decision drives the checkpoint, and risking a redelivery
  racing a still-running handler — or is so long it barely mitigates the wedge.
  The wrapper is precise (it converts exactly the exception event, synchronously,
  with the exception text in hand) and lives in the layer that owns the Shibuya
  handler. The bridge also belongs to EP-1's blast radius, which this plan
  should not re-enter. The watchdog idea is noted as a possible future
  defense-in-depth for non-Shibuya `subscriptionAckStream` consumers, but is not
  implemented here.
  Date: 2026-06-10

- Decision: The proper upstream fixes live in shibuya-core (a different
  repository, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) and are
  explicitly *not* implemented by this plan. Two follow-ups are recorded:
  (1) `Shibuya.Runner.Supervised.processOne` catches a handler exception
  (`shibuya-core/src/Shibuya/Runner/Supervised.hs`, the `catchAny` around the
  handler call, lines 420–431 at audit time) and moves on *without* calling
  `ingested.ack.finalize` — `runSupervised` should finalize a disposition (or at
  minimum expose a hook) on the exception path. (2) `runIngesterAndProcessor`
  runs the ingester under `UIO.withAsync` and discards the handle (line 253 at
  audit time), so an adapter stream that *terminates with an error* — exactly
  what EP-1 makes the kiroku bridge do — kills the ingester async silently; the
  `finally` only signals stream-done, the processor drains and exits cleanly,
  and supervision never sees the failure. Until (2) lands upstream, the error
  surfaced by this plan is visible when folding `adapter.source` directly and
  via the standalone `runWithMetrics` runner (which runs the ingester in the
  calling thread), but is swallowed by `runSupervised`/`runApp`.
  Rationale: this MasterPlan coordinates kiroku-repo work only; the adapter-side
  defenses here are correct regardless of when upstream lands.
  Date: 2026-06-10

- Decision: Keep the `bufferSize` parameter (on the adapter configs and on
  `subscriptionAckStream`) instead of dropping it; add a typed
  `InvalidStreamBufferSize` guard at the root (`subscriptionAckStream`) and
  rewrite the misleading docs.
  Rationale: With the ack-coupled bridge the queue depth never exceeds 1 (the
  worker blocks per event), so the knob is inert for this adapter — but dropping
  it breaks the signatures of both `subscriptionStream` and
  `subscriptionAckStream` plus two exported config records, for zero behavioral
  gain. The dangerous value is exactly 0 (`newTBQueueIO 0` makes the bridge
  handler's `writeTBQueue` block forever — a permanent, silent deadlock with no
  validation today), so a `>= 1` guard plus honest documentation ("capacity of
  the bridge queue; with the ack-coupled bridge effective depth is at most 1")
  removes the trap. Removal can be reconsidered at the next major version.
  Date: 2026-06-10

- Decision: Validate `groupSize >= 1` inside `kirokuConsumerGroupProcessors` by
  throwing `Kiroku.Store.Subscription.Types.InvalidConsumerGroup 0 n` (member 0
  is the first member that would have been created), rather than widening the
  function's `Either PolicyError` result type.
  Rationale: `subscribe` itself already *throws* `InvalidConsumerGroup` for bad
  group shapes (`kiroku-store/src/Kiroku/Store/Subscription.hs`, the guard at
  the top of `subscribe`) — the helper's bug is precisely that `[0 .. n-1]` is
  empty for `n <= 0` so `subscribe` never runs and the documented enforcement
  never fires. Throwing the same exception type up front matches the documented
  contract ("enforced … throwing InvalidConsumerGroup"), keeps `Left PolicyError`
  reserved for Shibuya policy errors, and is a programmer-error signal, which in
  this codebase is conventionally an exception.
  Date: 2026-06-10

- Decision: Make the partial-failure cleanup testable by routing member-adapter
  creation through an exported, factory-parameterized helper
  (`kirokuConsumerGroupProcessorsWith`), with the public
  `kirokuConsumerGroupProcessors` passing the real `kirokuAdapter` factory.
  Rationale: Inducing a *mid-group* adapter-creation failure against a real
  store is awkward (the realistic failure modes either hit member 0 or need
  heavyweight fault injection). A factory parameter lets the test inject stub
  adapters whose `shutdown` records into an `IORef` and a factory that throws at
  member 2, asserting members 0 and 1 are shut down — a precise test of the
  bracket logic with no loss of production fidelity.
  Date: 2026-06-10

- Decision: Single version bump `shibuya-kiroku-adapter` 0.3.0.0 → 0.4.0.0,
  applied in M1 and shared by all four milestones; `kiroku-store` gets a minor
  bump for the new `InvalidStreamBufferSize` export and guard (coordinate the
  exact number with whatever EP-1 shipped).
  Rationale: M1 already breaks record-literal construction of the config types
  (new `queueCapacity` field), so later milestones' additive exports ride the
  same major bump. Downstream consumers (keiro) take both via one git-pin bump.
  Date: 2026-06-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section is self-contained; you do not need to have read any other plan to
implement this one, but EP-1 (plan 56) must already be merged.

### The two systems and the bridge between them

**Kiroku** is the event store implemented in this repository under
`kiroku-store/`. Applications append immutable events to streams in PostgreSQL;
a *subscription* is a background worker thread that delivers events, in global
order, to a handler function, remembering its progress in a *checkpoint* (a row
in the `kiroku.subscriptions` table holding the last processed global
position). Delivery is push-based: the worker calls your handler.

**Shibuya** is a queue-processing framework in a *different repository* (on this
machine: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; this plan
changes nothing there, but you will read its source to understand the
contract). Shibuya is pull-based: an `Adapter` exposes a Streamly stream of
`Ingested` messages; a supervised processor pulls each message, runs the
application's `Handler` (type `Ingested es msg -> Eff es AckDecision`), and
then calls `ingested.ack.finalize decision` — the adapter-provided callback
that commits the decision. The `AckDecision` type
(`shibuya-core/src/Shibuya/Core/Ack.hs`) has four constructors: `AckOk`
(processed), `AckRetry delay` (redeliver later), `AckDeadLetter reason` (park
it), `AckHalt reason` (stop the processor).

**The adapter** (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`, with
conversions in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`)
turns Kiroku's push into Shibuya's pull using the *ack-coupled bridge*
`subscriptionAckStream` from
`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`. The bridge installs its
own Kiroku handler (`bridgeHandler`): for each event it creates a one-shot
reply variable (a `TMVar SubscriptionResult`), pushes an `AckItem` (event +
attempt counter + reply variable) onto a bounded STM queue (`TBQueue`), and
then **blocks** in `atomically (takeTMVar reply)` until someone fills the
reply. The adapter wraps each pulled `AckItem` into an `Ingested` whose
`finalize` translates the Shibuya `AckDecision` into a Kiroku
`SubscriptionResult` and fills the reply (`Convert.hs`, `toIngestedAck`,
idempotent via `tryPutTMVar`). Only then does the Kiroku worker checkpoint,
retry, or dead-letter. This coupling is what gives a Shibuya handler authority
over Kiroku's checkpoint — and it is also why every defect below is a wedge or
a kill rather than a graceful degradation.

Other vocabulary used below:

- *Global position*: monotonically increasing, gap-free sequence number over
  all events in the store; checkpoints are global positions.
- *Catch-up vs live*: a subscription worker first reads history from the
  database in batches ("catch-up") until it reaches the publisher's position,
  then switches to "live" mode, where (for `AllStreams` non-group
  subscriptions) it reads batches that the in-process *event publisher* pushes
  into a per-subscriber bounded queue.
- *Overflow policy* (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`,
  `OverflowPolicy`): what the publisher does when a subscriber's live queue is
  full. `PauseAndResume` (kiroku's default) marks the subscriber paused, stops
  pushing, and the worker later drains the stale queue and re-reads what it
  missed from its checkpoint — lossless. `DropSubscription` flips the
  subscriber's status to `Overflowed`; the worker observes that and throws
  `SubscriptionOverflowed`, terminating the subscription. `DropOldest` drops
  batches (lossy).
- *Consumer group*: one logical subscription split across N members; each
  originating stream hashes to exactly one member. `kirokuConsumerGroupProcessors`
  creates all N member adapters and Shibuya processors in one call.
- *Dead letter*: an event the subscription gives up on, recorded in the
  `kiroku.dead_letters` table with a reason; the checkpoint advances past it.

### EP-1's contract (consumed, not implemented, here)

Before EP-1, the bridge stream ended only when the cancel action wrote a
`Nothing` sentinel into the queue; if the Kiroku worker *died* (crash or
overflow), nothing ever woke the stream consumer — the Shibuya processor just
stopped receiving events, silently. EP-1 changes
`Kiroku.Store.Subscription.Stream` so the bridge queue carries a terminal
element on *every* worker exit path: a clean stop ends the stream normally and
a worker crash rethrows the worker's exception into whoever is pulling the
stream. The master plan's "Integration Points" section is the authoritative
statement of that contract; plan 56's Outcomes section documents the exact
final shape (sentinel type, any helper/test hooks). This plan's Milestone 3
wires that outcome to the Shibuya side and tests it at the adapter boundary.

### The four audit findings (all verified 2026-06-10)

**A — HIGH: pinned fail-fast overflow policy.** In
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`, `kirokuAdapter` builds
its subscription config with `queueCapacity = 16` and `overflowPolicy =
DropSubscription` (the `subConfig` record around lines 264–272). The publisher
enqueues batches of up to 1000 events (`publisherBatchSize` in
`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`), so 16 batches
≈ 16,000 events of headroom. Because the ack-coupled worker blocks per event on
the Shibuya handler, the consumer is *always* exactly handler-speed; any append
burst beyond the headroom while the handler is busy flips the subscriber to
`Overflowed`, and the worker throws `SubscriptionOverflowed`
(`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, the `StopOverflowed ->
throwIO …` arm in `runEffects`). Before EP-1 that death was silent; after EP-1
it is loud — either way the projection stops. Aggravation: the worker only
reads its overflow status in the *live* `AllStreams` branch of `nextInput`
(`Worker.hs` lines 228–244); the `CatchingUp` branch (lines 216–227) never
looks, so overflow accumulated during a long catch-up kills the subscription
the moment it goes live — precisely the situation `PauseAndResume` recovers
from losslessly. Fix: inherit kiroku's `PauseAndResume` default and expose
`queueCapacity`.

**B — HIGH, cross-repo contract gap: a throwing handler wedges the
subscription.** Shibuya's supervised runner
(`shibuya-core/src/Shibuya/Runner/Supervised.hs`, `processOne`) wraps the
handler call in `catchAny` (lines 420–431 at audit time): on an exception it
records the error on the trace span and *moves on without ever calling
`ingested.ack.finalize`*. For most brokers that merely delays redelivery; for
this adapter, the Kiroku worker is blocked in `atomically (takeTMVar reply)`
inside `bridgeHandler` and the reply will now never be filled. The whole
subscription wedges permanently: no retry, no dead-letter, no crash, no
checkpoint movement — and the processor happily continues with other messages
it will never receive. Fix defensively in this repo with a handler guard
(Milestone 2); record the upstream finalize-on-exception fix as a follow-up in
shibuya-core (see Decision Log).

**C — LOW: `kirokuConsumerGroupProcessors` group-size and leak defects.** In
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`, the helper maps adapter
creation over `[0 .. n - 1]` (line 453 at audit time). For `n <= 0` the list is
empty: the function returns `Right []`, `subscribe` never runs, and the
documented `InvalidConsumerGroup` enforcement (which lives at the top of
`subscribe` in `kiroku-store/src/Kiroku/Store/Subscription.hs`) never fires —
the caller gets zero processors and no error. Separately, if member `k`'s
`kirokuAdapter` call throws mid-`mapM` (each call opens a real subscription via
`subscriptionAckStream`), members `0..k-1` already hold live subscriptions that
nothing ever cancels — a thread-and-connection leak. Fix: validate up front and
create members under cleanup-on-partial-failure (Milestone 4).

**D — INFO/LOW: `bufferSize` is dead config with a deadly edge.** The adapter's
`bufferSize` field (documented at `Shibuya/Adapter/Kiroku.hs` lines 169–170 as
the "backpressure threshold") is the `TBQueue` capacity passed to
`subscriptionAckStream`, which calls `newTBQueueIO bufferSize`
(`Stream.hs` line 141 at audit time). Because the worker blocks per event, the
queue depth never exceeds 1 — every value `>= 1` behaves identically, so the
"backpressure" claim is false (the ack coupling itself is the backpressure).
And `bufferSize = 0` is accepted without validation: `bridgeHandler`'s
`writeTBQueue` on a zero-capacity queue blocks forever — a permanent, silent
deadlock. Fix: typed `>= 1` guard at the root plus honest docs (Milestone 1).

### What Shibuya does with a stream error today (verified, shapes Milestone 3)

`shibuya-core/src/Shibuya/Runner/Ingester.hs` does not catch stream
exceptions — they propagate out of `runIngesterWithMetrics`. In the supervised
path (`Supervised.hs`, `runIngesterAndProcessor`), the ingester runs under
`UIO.withAsync ingesterWithSignal $ \_ -> …` with the async handle discarded;
its `finally` only sets the stream-done flag. So when the adapter stream ends
with an error, the ingester async dies, the processor drains and exits
*cleanly*, and supervision records success. In the standalone path
(`runWithMetrics`), the ingester runs in the calling thread, so the error
propagates to the caller. Consequence: this plan can and does guarantee
"`adapter.source` terminates with the worker's error", and that error is
observable by any direct consumer and by `runWithMetrics`; making
`runSupervised` honor it is upstream follow-up (2) in the Decision Log.

### Build and test mechanics for this repository

Everything runs from the repository root. `just build` is `cabal build all`;
`just test` is `cabal test all`. The adapter package builds with `cabal build
shibuya-kiroku-adapter` and its single hspec suite
(`shibuya-kiroku-adapter/test/Main.hs`) runs with `cabal test
shibuya-kiroku-adapter-test`. The suite uses
`Kiroku.Test.Postgres.withSharedMigratedPostgres` (from `kiroku-test-support`,
backed by `ephemeral-pg`) to boot and migrate a throwaway PostgreSQL, so no
external database is needed. The bridge guard in M1 also touches
`kiroku-store`, whose suite runs with `cabal test kiroku-store`.


## Plan of Work

The work is four milestones, each independently verifiable, ordered so the
behavioral fixes that do not depend on EP-1's new surface land first (M1, M2,
M4 only require EP-1 to be merged for serialization reasons; M3 actively
consumes EP-1's termination contract). Implement them in order; M4 may be done
any time after M1.

### Milestone 1 — Lossless overflow: `PauseAndResume`, exposed `queueCapacity`, honest `bufferSize`

Scope: finding A and finding D. At the end of this milestone, no append burst
can terminate an adapter-backed subscription; the publisher-side capacity knob
is real configuration; a zero bridge capacity is rejected loudly; and the
package version is 0.4.0.0.

In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

- Add a `queueCapacity :: !Natural` field to `KirokuAdapterConfig` and to
  `KirokuConsumerGroupConfig`, documented as: the maximum number of publisher
  *batches* (up to 1000 events each) buffered for this subscriber before the
  publisher pauses it; on pause, kiroku recovers losslessly by re-reading from
  the checkpoint once the handler catches up. Set it to 16 in
  `defaultKirokuAdapterConfig` and `defaultConsumerGroupConfig`, and forward it
  from the group config into each member's `KirokuAdapterConfig`.
- In `kirokuAdapter`'s `subConfig`, replace the pinned `queueCapacity = 16,
  overflowPolicy = DropSubscription` with `queueCapacity` from the config and
  *no* `overflowPolicy` override (the smart constructor
  `defaultSubscriptionConfig` already defaults to `PauseAndResume`; rely on it
  and say so in a comment, mirroring the existing comment style about
  inheriting future defaults).
- Rewrite the `bufferSize` Haddocks on both config records and the module-level
  "Backpressure" section: backpressure comes from the ack coupling itself (the
  worker blocks per event until `finalize`); `bufferSize` is merely the bridge
  `TBQueue` capacity, effective depth at most 1, must be `>= 1`, and
  `queueCapacity` is the knob that matters for burst absorption. Update the
  module example and `defaultKirokuAdapterConfig` Haddock accordingly.

In `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` (small, post-EP-1
edit — re-read the file first, EP-1 has restructured it):

- Define and export `newtype InvalidStreamBufferSize = InvalidStreamBufferSize
  Natural` with `Show` and `Exception` instances, documented as thrown by the
  bridge constructors when the requested capacity is zero (which would deadlock
  the bridge handler permanently).
- At the top of `subscriptionAckStream`, `when (bufferSize < 1) $ throwIO
  (InvalidStreamBufferSize bufferSize)`. (`subscriptionStream` delegates, so
  one guard covers both.) Correct the parameter's Haddock the same way as the
  adapter's.

Bump `shibuya-kiroku-adapter.cabal` to `version: 0.4.0.0`, fix the stale
`description` while you are in the file (it still says ack semantics are
"no-op … and trigger subscription cancellation for AckHalt", which has been
false since the ack-coupled bridge landed — but you may defer the prose rewrite
to M3 where the rest of the documentation is overhauled; the version bump
happens here). Add CHANGELOG entries. Bump `kiroku-store`'s version per the
Decision Log.

Tests (in `shibuya-kiroku-adapter/test/Main.hs`):

- Burst/pause-resume test: create an adapter with `queueCapacity = 1` and a
  handler gated on a `TVar` (blocks until released, counting events into an
  `IORef`). Append on the order of 40 events one at a time (separate appends
  force multiple publisher batches, exactly how
  `kiroku-store/test/Test/SubscriptionPauseResume.hs` triggers pause with
  capacity 1) while the handler is blocked on the first event, then release the
  gate. Assert every appended event is processed within the test timeout and
  the processor never enters a failed state. Before this milestone this test
  fails: the subscriber overflows, the worker throws `SubscriptionOverflowed`,
  and the count stalls.
- Bridge-guard test (may live in `kiroku-store`'s suite instead, wherever EP-1
  put bridge tests): `subscriptionAckStream store cfg 0` throws
  `InvalidStreamBufferSize 0`.

Acceptance: `cabal test shibuya-kiroku-adapter-test` and `cabal test
kiroku-store` pass; the burst test demonstrably fails when the
`overflowPolicy`/`queueCapacity` change is reverted (verify once by stashing
the source change, run the test, observe the failure, unstash).

### Milestone 2 — A throwing handler finalizes a disposition instead of wedging the subscription

Scope: finding B, adapter side. At the end of this milestone the adapter
exports a guard that converts handler exceptions into finalized dispositions,
the consumer-group helper applies it automatically, the module documentation
states the contract loudly, and tests demonstrate both the retry and the
dead-letter outcome.

In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` (or a small new
module if you prefer; keep exports on `Shibuya.Adapter.Kiroku`):

- Implement and export:

  ```haskell
  -- | Map any synchronous exception from the wrapped handler to an
  -- 'AckDecision', so the decision is still finalized and the kiroku
  -- worker is never abandoned mid-ack. Asynchronous exceptions
  -- (cancellation) still propagate.
  guardKirokuHandlerWith ::
      (SomeException -> AckDecision) ->
      Handler es msg ->
      Handler es msg

  -- | 'guardKirokuHandlerWith' with the recommended default:
  -- @AckRetry (RetryDelay 1)@ — kiroku redelivers the event after one
  -- second, and its bounded 'RetryPolicy' dead-letters it with
  -- 'DeadLetterMaxAttempts' if it keeps failing.
  guardKirokuHandler :: Handler es msg -> Handler es msg
  ```

  Implementation: `guardKirokuHandlerWith f h = \ingested -> h ingested
  `catchSync` (pure . f)` using `Effectful.Exception.catchSync` (no effect
  constraints needed). Raise the library's `effectful-core` lower bound to
  `>= 2.5` in `shibuya-kiroku-adapter.cabal` (`catchSync` appeared when
  `Effectful.Exception` was rebased on `Control.Exception` in 2.5; the repo
  currently resolves 2.6.1.0 — check `dist-newstyle/cache/plan.json` if in
  doubt).
- In `kirokuConsumerGroupProcessors`, wrap the user handler with
  `guardKirokuHandler` before constructing each `QueueProcessor`. Note in its
  Haddock that the guard is applied; double-wrapping by a cautious caller is
  harmless (the outer guard simply never fires).
- Module Haddock: add a prominent "Handler exceptions" subsection to the "Ack
  Semantics" section stating the contract: a Shibuya handler used with this
  adapter must not let exceptions escape — Shibuya's supervised runner catches
  handler exceptions without finalizing the ack, and with this adapter an
  unfinalized ack blocks the kiroku worker forever (no retry, no dead-letter,
  no checkpoint movement). Direct `mkProcessor` users must wrap their handler
  in `guardKirokuHandler` (or handle exceptions themselves);
  `kirokuConsumerGroupProcessors` does it automatically. Reference the upstream
  shibuya-core follow-up so a future reader knows why the defense exists.

Tests (adapter suite; both run the full Shibuya pipeline via `runApp` or
`mkProcessor`, mirroring the existing EP-40 ack-disposition tests around the
"ack dispositions" describe block):

- Retry disposition: a guarded handler that throws on the first delivery of
  event N and returns `AckOk` on redelivery (track deliveries per event id in
  an `IORef`; assert the observed `envelope.attempt` increments). Assert event
  N is eventually processed, the checkpoint advances (subsequent events
  arrive), and nothing is dead-lettered.
- Dead-letter disposition: a guarded handler that *always* throws for event N
  and returns `AckOk` otherwise. Assert event N lands in `kiroku.dead_letters`
  with the max-attempts reason (query via hasql as the existing dead-letter
  test does), the checkpoint advances past N, and event N+1 is processed.
- Wedge regression framing: before this milestone, the dead-letter scenario
  (an unguarded throwing handler under `runApp`) never processes event N+1 and
  the test times out — that is the wedge. Do not keep a permanently-failing
  test; instead assert the *guarded* behavior, and note the pre-fix behavior in
  this plan's Surprises section after observing it once.

Acceptance: `cabal test shibuya-kiroku-adapter-test` passes; the two
disposition tests fail (time out / no dead-letter row) if the guard wrap in
`kirokuConsumerGroupProcessors` is removed or the test handler is left
unguarded — demonstrating the defense is load-bearing.

### Milestone 3 — Worker death is visible at the Shibuya boundary, and the docs tell the truth

Scope: consume EP-1's termination contract; documentation overhaul. This
milestone is the reason for the hard dependency: do not start it before EP-1 is
Complete, and re-read plan 56's Outcomes section first.

Work:

- Confirm by reading the post-EP-1
  `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` that
  `subscriptionAckStream`'s stream now (a) ends cleanly when the subscription
  stops or is cancelled and (b) rethrows the worker's exception to the puller
  when the worker crashed. The adapter needs no structural change for the
  rethrow to propagate — `kirokuAdapter` merely `Stream.morphInner liftIO`s the
  bridge stream — but this milestone *locks* the behavior with adapter-level
  tests so a future adapter refactor cannot silently swallow it.
- Tests (adapter suite):
  - Clean end: create an adapter, run `adapter.shutdown`, and assert folding
    `adapter.source` terminates without error (this generalizes the existing
    coordinated-shutdown test to the stream boundary).
  - Error end: induce a worker crash and assert that folding `adapter.source`
    (directly, with `Stream.fold` — not through `runApp`, see below) throws the
    worker's exception within the test timeout. Use the same fault-injection
    technique EP-1's own tests use (read them; plan 56's Outcomes section names
    the hook). A candidate that needs no new hooks, *if* EP-1 made
    checkpoint-load failure fatal rather than retried: break the schema in the
    test database (e.g. drop/rename the `kiroku.subscriptions` table via a
    hasql session, as other tests in this suite already run raw sessions)
    before creating the adapter, so the worker's checkpoint load fails and the
    crash propagates through the bridge. If EP-1 chose retry semantics for that
    path, mirror whatever crash EP-1's tests inject instead. Record the chosen
    mechanism in this plan when done.
  - Why not assert through `runApp`: shibuya-core's supervised runner currently
    discards the ingester async's failure (verified; see Context and the
    Decision Log follow-up (2)), so the supervised processor exits cleanly even
    when the stream errs. Asserting at the `adapter.source` boundary tests what
    this repository owns. Optionally add a second assertion through
    `Shibuya.Runner.Supervised.runWithMetrics` (exported; runs the ingester in
    the calling thread, so the error reaches the caller) to prove a Shibuya
    runner *can* see it.
- Documentation overhaul in `shibuya-kiroku-adapter` (finishing what M1/M2
  started): the cabal `description` (rewrite the stale "ack semantics are
  no-op" paragraph to describe the ack-coupled bridge, the guard wrapper, and
  `PauseAndResume`); the module Haddock paragraphs on `kirokuAdapter` (the
  numbered list still says "a no-op 'AckHandle'"); the "Backpressure" section
  (already rewritten in M1 — verify consistency); and a new sentence on
  `kirokuAdapter` documenting that `source` terminates with the worker's
  exception when the subscription dies, plus the current shibuya-core
  supervision caveat. Update CHANGELOG.

Acceptance: both new boundary tests pass; reverting to the pre-EP-1
`kiroku-store` pin (or stubbing the sentinel away) makes the error-end test
hang/fail, demonstrating the dependency is real. `grep -i "no-op"
shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` returns nothing.

### Milestone 4 — Consumer-group helper: validate group size, clean up on partial failure

Scope: finding C. At the end of this milestone an invalid `groupSize` fails
loudly before any subscription opens, and a mid-group creation failure leaks no
member subscriptions.

In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`:

- Restructure `kirokuConsumerGroupProcessors` as a thin wrapper over a new
  exported `kirokuConsumerGroupProcessorsWith`, which takes the member-adapter
  factory as its first argument:

  ```haskell
  kirokuConsumerGroupProcessorsWith ::
      (Int32 -> Eff es (Adapter es RecordedEvent)) ->
      KirokuConsumerGroupConfig ->
      Handler es RecordedEvent ->
      Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])
  ```

  Haddock it as the factory-parameterized core, exposed primarily for tests;
  the public function passes `\m -> kirokuAdapter store (memberConfig m)` where
  `memberConfig` builds the per-member `KirokuAdapterConfig` exactly as today
  (now also forwarding `queueCapacity` from M1).
- Up-front validation, before the policy check or any factory call: `when (n <
  1) $ throwIO (InvalidConsumerGroup 0 n)` (import from
  `Kiroku.Store.Subscription.Types`; member 0 stands for the first member that
  would have been created — document this). Update the `groupSize` field
  Haddock and the function Haddock: the invariant is now enforced *here*, not
  merely "downstream by subscribe", and `groupSize >= 1` is no longer a mere
  documented precondition.
- Cleanup on partial failure: replace the `mapM` over `[0 .. n - 1]` with a
  recursive helper that threads the list of already-created adapters; wrap each
  factory call in `Effectful.Exception.onException` (or equivalent
  `catch`-and-rethrow) whose cleanup runs `shutdown` on every already-created
  adapter (most-recent first) before rethrowing. Once all members are created,
  ownership passes to the caller exactly as today (their processors/`runApp`
  manage shutdown). Mind that `shutdown` is `Eff es ()`; no unlifting tricks
  are needed since everything stays in `Eff es`.

Tests (adapter suite):

- `groupSize = 0` and `groupSize = -1`: `kirokuConsumerGroupProcessors` throws
  `InvalidConsumerGroup` (use `shouldThrow` with a predicate on the carried
  size); it must *not* return `Right []` — that was the bug.
- Policy-rejection ordering is preserved: an `Ahead` member concurrency still
  yields `Left (InvalidPolicyCombo …)` with no factory call (extend the
  existing "rejects an invalid member concurrency before opening any
  subscription" test to also cover the new `…With` variant with a factory that
  fails the test if called).
- Partial-failure cleanup: call `kirokuConsumerGroupProcessorsWith` with
  `groupSize = 3` and a stub factory: members 0 and 1 return dummy `Adapter`s
  (`source = Stream.nil`, `shutdown` appends the member index to an `IORef`),
  member 2 throws a sentinel exception. Assert the call rethrows the sentinel
  and the `IORef` holds exactly `[1, 0]` (each earlier member shut down exactly
  once, most-recent first).
- Real-store regression: the existing four-member group tests still pass
  unchanged through the refactored path.

Acceptance: `cabal test shibuya-kiroku-adapter-test` passes; deleting the
validation or the cleanup makes the corresponding new test fail.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`). The adapter suite
boots its own ephemeral PostgreSQL; no services need to be started.

1. Confirm EP-1 is complete and absorb its final contract:

   ```bash
   grep -n "Status" docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md
   ```

   The registry row for EP-1 must read Complete. Then read
   `docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`
   (Outcomes & Retrospective) and the current
   `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` end to end. Note the
   sentinel shape and the fault-injection technique its tests use; update this
   plan's M3 if they differ from the assumptions recorded here.

2. Baseline: everything green before you touch anything.

   ```bash
   cabal build shibuya-kiroku-adapter
   cabal test shibuya-kiroku-adapter-test --test-show-details=direct
   ```

   Expected tail of the test output (counts will differ as tests are added):

   ```text
   27 examples, 0 failures
   Test suite shibuya-kiroku-adapter-test: PASS
   ```

3. Implement Milestone 1 (edits listed in Plan of Work), then:

   ```bash
   cabal build shibuya-kiroku-adapter kiroku-store
   cabal test kiroku-store --test-show-details=direct
   cabal test shibuya-kiroku-adapter-test --test-show-details=direct
   ```

   One-time negative check: `git stash` the `Kiroku.hs` policy change, rerun
   the adapter suite, observe the burst test fail (timeout or
   `SubscriptionOverflowed` in output), `git stash pop`. Commit (Conventional
   Commits), e.g.:

   ```text
   feat(shibuya-kiroku-adapter)!: default to PauseAndResume and expose queueCapacity

   Overflow can no longer terminate an adapter-backed subscription; the
   publisher pauses it and kiroku recovers losslessly from the checkpoint.
   BREAKING CHANGE: KirokuAdapterConfig/KirokuConsumerGroupConfig gain a
   queueCapacity field; subscriptionAckStream rejects bufferSize 0.
   ```

4. Implement Milestone 2, rerun the adapter suite as above, run the negative
   check (drop the guard wrap, watch the disposition tests fail, restore),
   commit (`feat(shibuya-kiroku-adapter): finalize a disposition when a handler
   throws`).

5. Implement Milestone 3, rerun the adapter suite, commit
   (`feat(shibuya-kiroku-adapter): surface worker death through the adapter
   stream` plus `docs(shibuya-kiroku-adapter): …` if split).

6. Implement Milestone 4, rerun the adapter suite, commit
   (`fix(shibuya-kiroku-adapter): validate group size and clean up partial
   consumer-group creation`).

7. Full sweep and bookkeeping:

   ```bash
   just test
   ```

   Expected: every suite reports `PASS`. Then update this plan's Progress,
   Surprises & Discoveries, and Outcomes sections; flip EP-2's row to Complete
   and tick the three EP-2 checklist items in
   `docs/masterplans/9-audit-remediation-subscription-reliability-and-store-correctness-and-performance.md`.

After each stopping point, update the Progress checklist in this file —
including splitting any half-done item into "done" and "remaining" halves.


## Validation and Acceptance

The change is accepted when all of the following behaviors are demonstrable
via `cabal test shibuya-kiroku-adapter-test --test-show-details=direct`:

- **Burst survival (M1).** With `queueCapacity = 1` and a handler gated shut,
  appending ~40 events one at a time and then opening the gate results in all
  ~40 events processed and a healthy processor. Pre-change behavior (one-time
  negative check): the count stalls and the subscription dies with
  `SubscriptionOverflowed`.
- **Zero-capacity rejection (M1).** `subscriptionAckStream store cfg 0` throws
  `InvalidStreamBufferSize 0` instead of accepting a configuration that would
  deadlock the first delivery forever.
- **Throwing handler, transient (M2).** A guarded handler that throws on event
  N's first delivery and succeeds on redelivery: event N is redelivered with an
  incremented `envelope.attempt`, is processed, the checkpoint advances, no
  dead-letter row appears.
- **Throwing handler, persistent (M2).** A guarded handler that always throws
  on event N: a `kiroku.dead_letters` row appears for event N with the
  max-attempts reason, and event N+1 is processed. Before this plan, the
  equivalent unguarded scenario wedges the processor forever — event N+1 never
  arrives and the checkpoint never moves.
- **Stream termination (M3).** After `shutdown`, folding `adapter.source`
  completes cleanly. After an induced worker crash, folding `adapter.source`
  throws the worker's exception within the test timeout instead of hanging.
- **Group hygiene (M4).** `groupSize <= 0` throws `InvalidConsumerGroup` (never
  `Right []`); an injected creation failure at member 2 of 3 shuts down members
  0 and 1 exactly once; existing four-member partition tests pass unchanged.

Interpreting results: hspec prints `N examples, 0 failures` and cabal prints
`Test suite shibuya-kiroku-adapter-test: PASS` on success. A wedge regression
manifests as an hspec timeout failure on the disposition or burst tests — treat
any timeout in this suite as a real failure, not flakiness, and investigate.


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; all of it is idempotent
and safely re-runnable. No migrations, no destructive operations: the test
databases are ephemeral (created and destroyed by `ephemeral-pg` per run), so a
crashed test run leaves nothing to clean up beyond possibly a stray postgres
process from a hard kill (rerunning the suite provisions a fresh instance).

Milestones are independently committable; if a later milestone goes wrong,
`git revert` its commit without disturbing the earlier ones. The only ordering
constraints: M1's version bump and config field are assumed by M2/M4's edits to
the same file, and M3 must not start before EP-1 is Complete. If M3's
fault-injection candidate (broken-schema checkpoint load) turns out not to
crash the worker under EP-1's final semantics, do not force it — switch to
EP-1's own injection hook and record the substitution in the Decision Log.

The negative checks ("stash the fix, watch the test fail") are read-only with
respect to the final tree; if a stash pop conflicts, `git checkout -- <file>`
and re-apply the milestone edit from this plan's Plan of Work.


## Interfaces and Dependencies

Hard plan dependency: EP-1,
`docs/plans/56-eliminate-silent-subscription-stalls-in-worker-publisher-and-stream-bridge.md`
(Complete before M3; merged before any of this plan ships, per the master
plan's wave ordering). This plan consumes its bridge-termination contract and
must re-verify the final sentinel shape from plan 56's Outcomes section.

Packages and modules touched:

- `shibuya-kiroku-adapter` (this repo) — all four milestones.
  `Shibuya.Adapter.Kiroku` gains: `queueCapacity` fields on
  `KirokuAdapterConfig` and `KirokuConsumerGroupConfig`;
  `guardKirokuHandlerWith :: (SomeException -> AckDecision) -> Handler es msg
  -> Handler es msg`; `guardKirokuHandler :: Handler es msg -> Handler es msg`;
  `kirokuConsumerGroupProcessorsWith :: (Int32 -> Eff es (Adapter es
  RecordedEvent)) -> KirokuConsumerGroupConfig -> Handler es RecordedEvent ->
  Eff es (Either PolicyError [(ProcessorId, QueueProcessor es)])`.
  `Shibuya.Adapter.Kiroku.Convert` is unchanged (its `finalize` is already
  idempotent via `tryPutTMVar`, which the guard relies on only trivially —
  the guard returns a decision, `processOne` finalizes once). Version
  0.3.0.0 → 0.4.0.0. Dependency bound change: `effectful-core >= 2.5 && < 2.7`
  (for `Effectful.Exception.catchSync`; resolved version in this repo is
  2.6.1.0).
- `kiroku-store` (this repo) — M1 only: `Kiroku.Store.Subscription.Stream`
  gains `InvalidStreamBufferSize` (exported, `Exception` instance) and the
  `>= 1` guard in `subscriptionAckStream`. Minor version bump coordinated with
  EP-1's. No other kiroku-store module changes in this plan.
- `shibuya-core` (different repository,
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) — read-only.
  Consulted modules: `Shibuya.Runner.Supervised` (the skipped finalize and the
  discarded ingester async), `Shibuya.Runner.Ingester`, `Shibuya.Core.Ack`,
  `Shibuya.Core.AckHandle`, `Shibuya.Handler`. Two upstream follow-ups recorded
  in the Decision Log; neither is implemented here.
- Test-only: `kiroku-test-support` (`Kiroku.Test.Postgres`), `ephemeral-pg`,
  `hspec`, `hasql` — all already in
  `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`'s test-suite stanza.

Types relied on across the boundary (all existing): kiroku's
`SubscriptionResult` (`Continue`/`Retry`/`DeadLetter`/`Stop`), `OverflowPolicy`
(`PauseAndResume` default), `SubscriptionOverflowed`, `InvalidConsumerGroup`,
`RetryPolicy`/`DeadLetterMaxAttempts`, and `AckItem`; Shibuya's `AckDecision`,
`AckHandle.finalize`, `Handler`, `Adapter` (`source`, `shutdown`),
`QueueProcessor`, and `PolicyError`.

Downstream: keiro consumes kiroku by git SHA pin; after release, downstream
pin bumps are required for these fixes to reach consumers (out of scope here).


---

*Revision note (2026-06-11).* Updated the hard-dependency callout's description of
EP-1's bridge-termination mechanism: docs/plans/56 (authored after this plan's first
draft) chose a terminal `TVar (Maybe BridgeTermination)` consulted via STM `orElse`,
not the terminal queue element the master plan's Integration Points sketched
provisionally. The behavioral contract this plan consumes (clean end on stop/cancel,
rethrow on worker crash) is unchanged; only the mechanism description was corrected.
