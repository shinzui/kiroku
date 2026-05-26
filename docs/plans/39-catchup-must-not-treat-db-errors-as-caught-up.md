---
id: 39
slug: catchup-must-not-treat-db-errors-as-caught-up
title: "Catch-up must not treat a DB error as 'caught up' (premature live switch / missed events)"
kind: exec-plan
created_at: 2026-05-25T23:30:00Z
---


# Catch-up must not treat a DB error as 'caught up' (premature live switch / missed events)

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

During a subscription's catch-up phase, a transient database error is silently
indistinguishable from "no more events," which can prematurely switch the worker to live
mode at a **stale cursor**. `fetchBatch`
(`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:391-420`) catches a pool/DB error,
emits a `KirokuEventSubscriptionDbError … FetchBatch` observability event, and **returns
`V.empty`** (lines 413-416). `catchUp` (Worker.hs:225-240) then treats the empty batch as
"caught up" and returns `Just cursor` (lines 233-235) — exiting catch-up to live mode at a
position **below the real tail**.

The store's own observability docstring already flags this hazard
(`Subscription/Observability.hs`, `SubscriptionDbPhase.FetchBatch`): *"The worker
substitutes an empty batch; the catch-up loop interprets this as 'no more events' and may
prematurely switch to live mode at a stale cursor."*

Consequences by subscription type:

- **`Category` / consumer-group**: live mode re-queries the DB from the cursor
  (`liveLoopCategoryNotify` for ordinary `Category`, `liveLoopDbDriven` for consumer-group
  members), so it eventually re-reads the skipped range — **self-healing**, but with a
  spurious "caught up" lifecycle event and a window of incorrect state.
- **`AllStreams`**: live mode reads the broadcast queue and only delivers `freshEvents`
  (`> cursor`). Events between the stale cursor and the live point are delivered **only if
  still buffered** in the per-subscriber queue; if the queue overflowed/dropped them, or the
  publisher advanced past them, those events are **missed** — a genuine delivery gap.

After this change, a DB error during catch-up is **retried with bounded backoff** rather
than collapsed into an empty result, so catch-up completes to the true tail before live mode
begins. No transient pool blip can cause a premature live switch or a delivery gap.

Acceptance command:

```bash
cabal test kiroku-store
```

must report `0 failures`, including a fault-injection spec that forces a transient DB error
mid-catch-up and asserts the subscriber still delivers every event up to the tail (no
premature live switch, no missed events). This spec fails before the change.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Root-cause + impact analysis (this document); author-acknowledged in Observability docstring. 2026-05-25.
- [x] Codebase validation pass. Confirmed the `fetchBatch`/`catchUp` root cause against current `Worker.hs`, confirmed `hasql-pool`'s `Pool.use` returns `Either UsageError a`, and corrected the plan's unsupported test-harness and retry-shape assumptions. 2026-05-26.
- [x] M1: make `fetchBatch` distinguish DB error from empty result; `catchUp` and DB-driven live drains retry the same cursor on error with capped backoff. `cabal build all` passed after the change. 2026-05-26T00:20:00Z.
- [x] M2: fault-injection regression test. Added `Test.CatchupDbErrorNoPrematureSwitch`, registered it in the test suite, and verified the focused spec with `cabal test kiroku-store --test-options='--match "catch-up DB error handling"'`. 2026-05-26T00:31:00Z.
- [x] M3: CHANGELOG entry. Added an Unreleased note describing catch-up retry behavior and the `$all` stale-cursor gap it prevents. 2026-05-26T00:34:00Z.
- [x] Final validation. `cabal build all` and full `cabal test kiroku-store` passed; the full store suite reported 164 examples, 0 failures. 2026-05-26T00:37:00Z.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The same error-swallowing exists in `loadCheckpoint` (Worker.hs:202-209, DB error →
  `GlobalPosition 0`) and `saveCheckpoint` (464-470, DB error → logged, continue). Those
  are separately documented (`SubscriptionDbPhase.LoadCheckpoint`/`SaveCheckpoint`) and have
  their own re-process-on-restart implications; this plan scopes to the **catch-up fetch**
  path (the one that can cause a *premature live switch / missed events*), but the fix
  should consider whether `loadCheckpoint` degrading to 0 (silent re-process from the start
  on a transient error) deserves the same treatment (noted for the Decision Log).
- `AllStreams` is the higher-severity case because, unlike `Category`, its live loop does
  not re-query the DB from the cursor — it depends on the broadcast queue still holding the
  skipped events.
- Validation correction: `kiroku-store/test/Test/FailureInjection.hs` is not currently a
  general fetch-batch fault-injection harness. It only kills the dedicated LISTEN backend
  and proves notifier reconnect behavior. There is no existing hook that can deterministically
  make exactly the catch-up `Pool.use` call return `Left UsageError`; M2 must add a small
  deterministic injection point or refactor an internal catch-up helper so the regression
  can fail before M1 and pass after it.
- Validation correction: `Kiroku.Store.Subscription.Worker` is listed as an exposed module in
  `kiroku-store/kiroku-store.cabal`, but it currently exports only `runWorker`. A focused
  test can still avoid public API churn by extracting a small internal helper and testing it
  through `runWorker`-level behavior, but the plan must not assume private `fetchBatch` or
  `catchUp` can be imported directly without changing exports.
- `ConnectionSettings` exposes `poolSize` and `statementTimeout`, but not
  `hasql-pool`'s `acquisitionTimeout`. The existing F15 note in `Test.FailureInjection`
  is still true: pool-exhaustion tests cannot rely on a sub-second acquisition timeout
  unless this package exposes one or constructs a lower-level pool outside `withStore`.
- The test suite already uses explicit module registration. Any new test module must be
  added to `kiroku-store/kiroku-store.cabal` `kiroku-store-test.other-modules` and imported
  from `kiroku-store/test/Main.hs`.
- A deterministic real-path regression is possible with a process-local
  `withFetchBatchHookForTest` hook in `Kiroku.Store.Subscription.Worker`. The hook lets the
  test inject `Pool.AcquisitionTimeoutUsageError` on the first `$all` catch-up fetch while
  leaving `ConnectionSettings`, `SubscriptionConfig`, and production behavior unchanged.
  Evidence: the focused spec passes and observes exactly one
  `KirokuEventSubscriptionDbError ... FetchBatch ...` plus a single caught-up event at the
  true tail.


## Decision Log

Record every decision made while working on the plan.

- Decision: `fetchBatch` must surface "DB error" distinctly from "empty result," and
  `catchUp` must **retry on error with bounded backoff** rather than exit to live mode.
  Rationale: Catch-up's exit condition is "the category/all has no more events at/after the
  cursor"; a DB error is not evidence of that. Conflating them violates the at-least-once
  contract (an AllStreams subscriber can miss events). Retrying preserves the contract; the
  publisher's 30 s safety poll and the existing reconnect machinery make transient pool
  errors recoverable.
  Date: 2026-05-25

- Decision: "Bounded backoff" means an unbounded number of retry attempts with a bounded
  maximum sleep, not "give up after N attempts." The worker should keep the subscription
  alive and retry the same cursor until the database read succeeds, the handler stops, or
  the worker is cancelled.
  Rationale: Giving up after N attempts would either recreate the same silent caught-up bug
  or crash a subscription during a recoverable database outage. An unbounded retry with a
  capped delay preserves correctness and still avoids a hot loop during an outage.
  Date: 2026-05-26

- Decision: M2 must use deterministic test fault injection, not timing-sensitive pool
  exhaustion or statement-timeout tricks.
  Rationale: `hasql-pool` exposes `UsageError`, but the current store-level test fixture does
  not expose `acquisitionTimeout`, and killing an arbitrary pooled backend does not
  reliably target the catch-up fetch. A regression that depends on timing or pool internals
  will be flaky and may not fail before the fix.
  Date: 2026-05-26

- Decision: leave `loadCheckpoint` behavior unchanged in this plan.
  Rationale: the user-visible defect here is the catch-up `FetchBatch` path, where an
  empty fallback can cause a premature live switch and, for `$all`, a delivery gap.
  Changing `loadCheckpoint` from "emit and start at 0" to "retry/fail startup" would be a
  separate behavior change with restart replay implications and deserves its own scoped
  plan.
  Date: 2026-05-26

- Decision: add `withFetchBatchHookForTest` to `Kiroku.Store.Subscription.Worker` as a
  clearly named internal test hook rather than exposing new knobs on `ConnectionSettings`
  or `SubscriptionConfig`.
  Rationale: the regression must force exactly the catch-up `fetchBatch` call to return a
  `Pool.UsageError`; timing-sensitive pool exhaustion and listener-kill tests cannot do
  that reliably. Keeping the hook inside `Worker` avoids changing the store configuration
  surface used by production callers.
  Date: 2026-05-26


## Outcomes & Retrospective

Completed on 2026-05-26. `fetchBatch` now returns
`Either Pool.UsageError (Vector RecordedEvent)` and emits the existing
`KirokuEventSubscriptionDbError ... FetchBatch ...` event before returning `Left`.
`catchUp`, `liveLoopCategoryNotify`, and `liveLoopDbDriven` retry a failed fetch at the
same cursor with an unbounded attempt count and a capped delay, and live DB-driven loops no
longer emit `KirokuEventSubscriptionFetched ... 0` for failed reads.

The regression test `Test.CatchupDbErrorNoPrematureSwitch` pre-populates three `$all`
events, injects one transient `Pool.AcquisitionTimeoutUsageError` on the first catch-up
fetch, and asserts that the subscriber delivers all three positions, emits a DB-error event
for `FetchBatch`, and emits exactly one caught-up event at `GlobalPosition 3`. The focused
validation passed:

```text
catch-up DB error handling
  retries a transient fetch error instead of switching to live mode at a stale cursor [✔]

Finished in 0.2341 seconds
1 example, 0 failures
```

The full required validation also passed:

```text
Finished in 29.0480 seconds
164 examples, 0 failures
```

The `loadCheckpoint` fallback remains unchanged and should be handled separately if the
project wants startup checkpoint reads to retry instead of reprocessing from zero.


## Context and Orientation

- `catchUp` (Worker.hs:225-240): loops fetching batches until `cursor >= pubPos` or an empty
  batch; an empty batch returns `Just cursor` (exit to live).
- `fetchBatch` (Worker.hs:391-420): selects the read statement by `(consumerGroup, target)`;
  on `Left err` it emits `KirokuEventSubscriptionDbError … FetchBatch` and returns `V.empty`
  (the bug); on `Right` it runs `decodeEvents`.
- The phase split after catch-up (Worker.hs:101-135): `Just finalPos` → live
  (`liveLoop` for ordinary `AllStreams`; `liveLoopCategoryNotify` for ordinary `Category`;
  `liveLoopDbDriven` for consumer-group members).
- Fault injection: `kiroku-store/test/Test/FailureInjection.hs` is only a pattern for
  integration-style failure tests today; it does not provide a reusable `fetchBatch`
  injector. Add a deterministic injection point as part of M2 rather than depending on
  backend timing.
- Observability: `KirokuEventSubscriptionDbError`, `SubscriptionDbPhase` in
  `Subscription/Observability.hs` — the new retry path should keep emitting the DB-error
  event (operators still need the signal). Update the docstrings that currently say the
  worker "continues running with safe defaults" and "substitutes an empty batch"; those
  comments are intentionally describing the bug and will become stale after M1.
- `hasql-pool`: local source/docs confirm `Pool.use :: Pool -> Session a -> IO (Either
  UsageError a)`, and `UsageError` has `ConnectionUsageError`, `SessionUsageError`, and
  `AcquisitionTimeoutUsageError`. Keep using this type directly for the internal
  fetch-result shape.


## Plan of Work

### M1 — Distinguish DB error from empty; retry in catch-up

Change `fetchBatch` to return `Either Pool.UsageError (Vector RecordedEvent)` instead of
mapping a `Left` to `V.empty`. Keep the `KirokuEventSubscriptionDbError ... FetchBatch`
emission at the single place that handles `Left`; callers should not double-emit the same
error. In `catchUp`:

- empty `Right` vector → genuinely caught up → `Just cursor` (unchanged).
- `Left err` → emit the DB-error event, sleep a bounded backoff, and **retry the same
  cursor** (do not exit to live). Do not cap attempts; cap only the sleep interval. The
  retry loop stops only when the fetch succeeds, the handler returns `Stop` after a later
  successful fetch, or the worker is cancelled.

Add one small helper for retry timing, for example `fetchRetryDelayMicros attempt` with an
exponential sequence capped at the existing 30-second safety-poll interval. Reset the
attempt counter after any successful fetch. Import `threadDelay` from `Control.Concurrent`
or use the repository's existing delay style.

Keep the live-mode DB-driven `fetchBatch` callers behaving sensibly. A DB error in
`liveLoopCategoryNotify` or `liveLoopDbDriven` should retry the same cursor and should not
emit `KirokuEventSubscriptionFetched ... 0`, because no successful fetch occurred. The
ordinary non-group `AllStreams` `liveLoop` reads from the publisher queue and does not call
`fetchBatch`; no change is needed there. Decide the `loadCheckpoint` question (Decision
Log).

Acceptance: `cabal build all` clean; existing suite green.

### M2 — Fault-injection regression test

Add `kiroku-store/test/Test/CatchupDbErrorNoPrematureSwitch.hs`. Register it in
`kiroku-store/kiroku-store.cabal` under the `kiroku-store-test` `other-modules` list and
import/run it from `kiroku-store/test/Main.hs`.

Do not rely on `statementTimeout`, pool exhaustion, or killing an arbitrary backend to hit
the catch-up `fetchBatch` call. First add a deterministic test seam, choosing the smallest
internal change that does not alter the public store API. Two acceptable shapes are:

1. Factor the fetch/drain loop so a test can supply a fetch function that returns
   `Left Pool.UsageError` once and `Right events` afterwards, then exercise the same retry
   decision code used by `catchUp`.
2. Add a clearly internal worker-test hook carried only inside `Worker.hs` (not
   `ConnectionSettings` or `SubscriptionConfig`) and keep `runWorker`'s public behavior
   unchanged.

The behavioral test should then cover the real subscription path:

1. Pre-populate N events across the `$all` stream.
2. Subscribe (AllStreams) with a handler that records delivered positions, while injecting a
   **transient** `fetchBatch` failure on the first catch-up call (then succeed).
3. Assert: the subscriber delivers **all** N events (no gap), does not emit a
   `SubscriptionCaughtUp` at a stale position before the tail, and emits
   `KirokuEventSubscriptionDbError ... FetchBatch ...` for the transient failure.

This spec fails before M1 (the injected error collapses catch-up early, and under
AllStreams the early range can be missed) and passes after.

### M3 — CHANGELOG

`## Unreleased` entry in `kiroku-store/CHANGELOG.md`: catch-up now retries on transient DB
errors instead of treating them as "caught up."


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
cabal build all
cabal test kiroku-store
```

Prove the spec: with M1 reverted (DB error → empty), confirm the new spec fails (missed
events / premature switch), then restore.


## Validation and Acceptance

- `cabal test kiroku-store` green including the new fault-injection spec.
- The spec demonstrates no premature live switch and no missed events under a transient
  catch-up DB error; it fails with the old swallow-to-empty behavior.
- All existing subscription + failure-injection specs still pass.


## Idempotence and Recovery

Source-only change; no schema/migration. Re-running build/test is safe (ephemeral
PostgreSQL per run). When working in a dirty tree, revert only the files changed for this
plan; do not use broad checkout commands that could discard unrelated user work.


## Interfaces and Dependencies

- Changes the internal `fetchBatch` signature (error-visible) and the `catchUp` /
  live-loop call sites; no public store API change. Keeps the existing
  `KirokuEventSubscriptionDbError` observability event.
- Independent of plans 37, 38, and 40.


## Revision Notes

- 2026-05-25 — Created. No rei `intention` linked (rei worker disabled during the
  originating incident). Source: kiroku subscription review; the hazard is already noted in
  `Subscription/Observability.hs`'s `SubscriptionDbPhase.FetchBatch` docstring.
- 2026-05-26 — Validation update. Checked the plan against current `Worker.hs`,
  `Subscription.hs`, `EventPublisher.hs`, `Observability.hs`, `Connection.hs`, the
  `kiroku-store-test` harness, and local `hasql-pool` docs/source via `mori`. Corrected
  the retry policy to unbounded attempts with capped delay, replaced the inaccurate
  fault-injection-harness assumption with a deterministic test-seam requirement, and added
  module-registration, observability-docstring, and dirty-worktree recovery guidance.
- 2026-05-26 — Implementation complete. Added error-visible `fetchBatch`, capped retry
  behavior for catch-up and DB-driven live loops, a deterministic fetch-batch test hook, a
  real-path regression spec, updated observability text, and a changelog entry.
