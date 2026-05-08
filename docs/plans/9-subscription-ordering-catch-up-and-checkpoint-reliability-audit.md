---
id: 9
slug: subscription-ordering-catch-up-and-checkpoint-reliability-audit
title: "Subscription ordering catch-up and checkpoint reliability audit"
kind: exec-plan
created_at: 2026-05-06T20:43:02Z
intention: "intention_01khv3gg6xe91tt2pyqvxw1832"
master_plan: "docs/masterplans/2-focused-event-store-reliability-and-scale-audit.md"
---

# Subscription ordering catch-up and checkpoint reliability audit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan proves that subscriptions preserve the store's ordered `$all` sequence while the store is receiving writes. After it is complete, a maintainer can run tests showing that catch-up, transition to live mode, live delivery, category subscriptions, and checkpoint persistence do not skip or reorder events under write pressure.

The user-visible behavior is that projection workers and consumers can trust subscriptions as an ordered at-least-once feed. Duplicates are allowed only where the public contract says at-least-once replay can happen; gaps and out-of-order delivery are not acceptable.


## Progress

- [x] Audit the publisher, worker, checkpoint SQL, subscription API, and current tests for ordering assumptions. Completed 2026-05-06 after reading `Kiroku.Store.Subscription`, `Subscription.EventPublisher`, `Subscription.Worker`, checkpoint SQL in `SQL.hs`, and the existing `subscribe` examples in `kiroku-store/test/Main.hs`.
- [x] Add tests for catch-up-to-live transition while writes are ongoing. Completed 2026-05-06 with `does not replay catch-up events when switching to all-stream live mode`, which blocks catch-up, appends positions 6 through 10 while the live queue is active, and verifies the handled positions are exactly 1 through 11 after a live stop event.
- [x] Add tests for checkpoint monotonicity and replay boundaries after cancellation, overflow, or handler stop. Completed 2026-05-06 with cancellation-before-save replay, handler `Stop` boundary replay, overflow restart replay, and monotonic checkpoint SQL.
- [x] Add category subscription ordering tests under mixed-category writes. Completed 2026-05-06 with a mixed `invoice-payment`, `invoice-*`, `user-*`, and `order-*` workload proving category `invoice` sees only global positions 1, 3, 5, and 7.
- [x] Land any must-fix subscription code changes. Completed 2026-05-06 by filtering stale all-stream live batches and making checkpoint upserts monotonic.
- [x] Record the final subscription reliability verdict. Completed 2026-05-06 after `cabal test kiroku-store --test-options='--match "subscribe"'` passed 14 subscription examples and `cabal test kiroku-store` passed 101 examples.


## Surprises & Discoveries

- All-stream subscriptions registered their live queue before catch-up. If events were appended while catch-up was blocked, catch-up could process those events from SQL and then live mode could read the same already-processed positions from the queue. The fix filters each live batch to `globalPosition > cursor` before invoking the handler. Evidence: the focused subscription suite includes `does not replay catch-up events when switching to all-stream live mode`, which now passes with exact positions 1 through 11.
  Date: 2026-05-06

- `saveCheckpointSQL` overwrote `subscriptions.last_seen` with the supplied position. That was safe for normal increasing worker flow but fragile if any stale or duplicate batch reached checkpoint saving. The SQL now uses `GREATEST(subscriptions.last_seen, EXCLUDED.last_seen)` so checkpoint persistence is monotonic even under replay-like boundaries.
  Date: 2026-05-06


## Decision Log

- Decision: Treat subscription reliability as ordered at-least-once delivery, not exactly-once delivery.
  Rationale: `Kiroku.Store.Subscription` already documents replay scenarios around cancellation, crash, and checkpoint saving. This audit should reject gaps and reordering while accepting documented duplicates.
  Date: 2026-05-06

- Decision: Keep the all-stream catch-up/live fix in `Worker.liveLoop` instead of changing publisher registration order.
  Rationale: The publisher queue is intentionally registered before the worker starts so live notifications are not missed. Filtering stale live batches by the worker's durable cursor preserves that design while preventing duplicate handler calls and backward checkpoint attempts.
  Date: 2026-05-06

- Decision: Make checkpoint monotonicity a SQL invariant.
  Rationale: The worker should normally save increasing positions, but the `subscriptions` table is the durable boundary. Using `GREATEST` at the upsert prevents a lower retry or stale batch from moving persisted progress backward.
  Date: 2026-05-06


## Outcomes & Retrospective

EP-3 is complete. Subscriptions now have regression coverage for all-stream catch-up/live transition under concurrent writes, cancellation before checkpoint save, handler `Stop` checkpoint boundaries, overflow restart replay, and mixed-category `invoice` subscriptions that include the `invoice-payment` stream name. The implementation change in `Kiroku.Store.Subscription.Worker.liveLoop` prevents already-processed all-stream positions from being delivered again when the worker switches from SQL catch-up to live queue consumption. The SQL checkpoint upsert now refuses to move durable progress backward.

The final delivery-contract verdict is positive with one targeted fix: subscriptions preserve increasing global positions and no gaps for the tested all-stream scenarios; category subscriptions preserve increasing matching positions and ignore non-matching categories; checkpoint restart behavior replays rather than skips after cancellation and overflow. Validation passed with 14 focused `subscribe` examples and the full 101-example `kiroku-store` suite on 2026-05-06.


## Context and Orientation

Subscriptions are implemented under `kiroku-store/src/Kiroku/Store/Subscription/`. The public entrypoint `Kiroku.Store.Subscription.subscribe` registers a bounded subscriber queue with the central `EventPublisher`, starts `Worker.runWorker`, and returns a `SubscriptionHandle` with `cancel` and `wait`. `withSubscription` is the bracketed lifecycle helper.

`Kiroku.Store.Subscription.EventPublisher` owns one background thread. It listens for ticks from `Kiroku.Store.Notification`, reads new events from `$all` with `SQL.readAllForwardStmt`, broadcasts `Vector RecordedEvent` batches to subscribers, and stores `lastPublished :: TVar GlobalPosition`. It debounces multiple NOTIFY ticks and also wakes every 30 seconds as a safety poll.

`Kiroku.Store.Subscription.Worker` has two phases. In catch-up, it reads the persisted checkpoint from `subscriptions.last_seen`, then fetches batches from the database until its cursor reaches `lastPublished`. In live mode, `AllStreams` subscriptions read from the publisher's bounded queue. `Category` subscriptions bypass the queue and re-query the database with `SQL.readCategoryForwardStmt` whenever `lastPublished` advances. Checkpoints are saved with `SQL.saveCheckpointStmt` after a full batch is processed, or at the current event if the handler returns `Stop`.

Current reliability context from previous work is recorded in `docs/masterplans/1-production-readiness-review-of-kiroku-store.md` and `docs/plans/3-subscription-system-robustness-audit.md`. Prior fixes added bounded subscriber queues, category live-mode database filtering, listener reconnection observability, and deterministic subscription wait helpers such as `waitForPublisher`, `waitForSubscriptionLive`, and `caughtUpEventHandler` in `kiroku-store/test/Test/Helpers.hs`.


## Plan of Work

Milestone 1 is a read-only audit. Inspect `Subscription.hs`, `Subscription/EventPublisher.hs`, `Subscription/Worker.hs`, `Subscription/Types.hs`, `SQL.getCheckpointStmt`, `SQL.saveCheckpointStmt`, and subscription tests in `kiroku-store/test/Main.hs`. For each phase, state the ordering invariant: events are handled in increasing `GlobalPosition`, checkpoints never move backward, switching from catch-up to live mode cannot skip a position, and category subscriptions preserve increasing global positions for only matching categories.

Milestone 2 adds catch-up/live transition tests under writes. Create a subscription that starts behind a backlog, blocks the handler at a known position with `MVar` or `STM`, appends more events while catch-up is running, then releases the handler. Assert that the collected positions are increasing, contain no gaps for `AllStreams`, and include the concurrently written events after the backlog.

Milestone 3 adds checkpoint boundary tests. Cover handler `Stop`, cancellation before checkpoint save if it can be made deterministic, and overflow under `DropSubscription` if practical. The expected behavior is replay, not loss: restarting a subscription with the same `SubscriptionName` should deliver events from the last durable checkpoint forward. Checkpoints must never advance past an event the handler did not process.

Milestone 4 adds category ordering pressure. Run multiple categories, including `invoice-payment`'s `invoice` category if EP-2 has landed that workload, append interleaved events across categories, and assert that a `Category (CategoryName "invoice")` subscription sees only matching events in increasing global order.

Milestone 5 lands fixes and records the verdict. Any fix in `EventPublisher` or `Worker` must include a failing regression test and must preserve the documented at-least-once contract in `Subscription.hs`.


## Concrete Steps

Run the baseline suite:

    cabal test kiroku-store

Read the subscription implementation:

    sed -n '1,220p' kiroku-store/src/Kiroku/Store/Subscription.hs
    sed -n '1,260p' kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs
    sed -n '1,340p' kiroku-store/src/Kiroku/Store/Subscription/Worker.hs
    sed -n '1,220p' kiroku-store/src/Kiroku/Store/Subscription/Types.hs
    rg -n "subscribe|checkpoint|caughtUp|waitForPublisher|Subscription" kiroku-store/test

Add subscription ordering tests in `kiroku-store/test/Main.hs` unless a new module becomes clearer. Reuse `Test.Helpers.waitForPublisher`, `waitForSubscriptionLive`, and `caughtUpEventHandler` instead of sleeps.

Run focused validation:

    cabal test kiroku-store --test-options='--match "subscription"'
    cabal test kiroku-store

If subscription code changes affect throughput or queue behavior, coordinate with EP-4 before changing benchmark baselines.


## Validation and Acceptance

Acceptance requires tests that collect handled `GlobalPosition` values and assert they are strictly increasing. For `AllStreams`, the collected positions must be gap-free over the range the subscription is expected to process. For category subscriptions, positions may have gaps relative to `$all` because non-matching categories are skipped, but the observed matching positions must be increasing and must correspond only to streams in the category.

Checkpoint acceptance requires restart evidence. After a subscription stops or is cancelled at a controlled point, a new subscription with the same name must resume from the last saved checkpoint. It may replay already handled events when the checkpoint was not saved; it must not skip unhandled events.


## Idempotence and Recovery

Subscription tests should use fresh `withTestStore` databases and deterministic synchronization. If a test relies on wall-clock sleeps, treat it as incomplete until it is rewritten with `MVar`, `STM`, publisher position checks, or event-handler barriers.

If a subscription test hangs, always use `waitWithTimeout` or `Async.race` and cancel the handle in the timeout path so the test suite can recover.


## Interfaces and Dependencies

Use `Kiroku.Store.Subscription.subscribe`, `withSubscription`, `SubscriptionConfig`, `defaultSubscriptionConfig`, `SubscriptionName`, `AllStreams`, `Category`, `Continue`, and `Stop`. Use `Kiroku.Store.Read.readAllForward` and `readCategory` to validate database state after subscription runs.

Coordinate with EP-1 at `docs/plans/8-high-write-append-ordering-and-atomicity-audit.md` for high-write append scenarios and EP-2 at `docs/plans/7-hot-system-stream-and-invoice-payment-workload-audit.md` for `invoice-payment` category naming. Coordinate with EP-4 at `docs/plans/10-large-store-read-path-and-index-performance-audit.md` for any performance impact from category live-mode queries.
