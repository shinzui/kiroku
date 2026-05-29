---
id: 40
slug: per-event-retry-and-dead-letter-for-kiroku-subscriptions-and-the-shibuya-adapter
title: "Per-event retry / dead-letter for kiroku subscriptions and the shibuya-kiroku-adapter"
kind: exec-plan
created_at: 2026-05-25T23:35:00Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
master_plan: "docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md"
---


# Per-event retry / dead-letter for kiroku subscriptions and the shibuya-kiroku-adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is an event store: appended events are immutable rows in PostgreSQL, and subscriptions remember progress by saving a checkpoint in `kiroku.subscriptions.last_seen`. Today a subscription handler returns only `Continue` or `Stop`, as defined in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. `Continue` means the worker may keep processing and later advance the checkpoint; `Stop` means checkpoint at the current event and exit gracefully. There is no way for a handler to say that one specific event should be retried later, or that one specific event is a poison event that should be recorded in a dead-letter table while later events continue.

This matters most for `shibuya-kiroku-adapter`, which wraps a Kiroku subscription as a Shibuya `Adapter`. Shibuya handlers return `AckDecision` values from `shibuya-core`: `AckOk`, `AckRetry RetryDelay`, `AckDeadLetter DeadLetterReason`, or `AckHalt HaltReason`. The current Kiroku adapter explicitly documents and implements `AckRetry` and `AckDeadLetter` as no-ops in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`; only `AckHalt` cancels the underlying Kiroku subscription. After this work, a Shibuya handler using the Kiroku adapter can return `AckRetry` for a transient failure and see the same event delivered again after the requested delay, or return `AckDeadLetter` and see the event recorded in Kiroku's dead-letter table while the subscription advances past it.

The critical architectural constraint is that the adapter cannot be fixed only by changing `AckHandle.finalize`. `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` currently implements `subscriptionStream` by writing each `RecordedEvent` into a `TBQueue` and immediately returning `Continue` to Kiroku. That means the Kiroku worker is free to checkpoint before the Shibuya handler has processed the event and before `finalize` receives the ack decision. A correct implementation must make the stream bridge ack-coupled: for each event, the Kiroku subscription handler must enqueue an item that includes a one-shot reply variable, then block until the Shibuya `AckHandle.finalize` writes back the per-event Kiroku disposition. Only then may the Kiroku worker checkpoint, retry, dead-letter, or stop.

The final observable outcome is: `cabal test kiroku-store:kiroku-store-test`, `cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test`, and `cabal test kiroku-store-migrations:kiroku-store-migrations-test` pass; the new tests prove that one event can be retried without advancing past it, one event can be dead-lettered and skipped without wedging the subscription, and `AckRetry` / `AckDeadLetter` through the adapter affect Kiroku checkpointing instead of disappearing as no-ops.


## Relationship to MasterPlan 6 and the subscription-worker FSM (read before implementing)

This ExecPlan is **child plan 2 of MasterPlan 6** (`docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md`). It carries a **hard dependency** on child plan 1, `docs/plans/41-explicit-subscription-worker-finite-state-machine-with-recoverable-backpressure-and-live-reconnect.md`, and must not begin until that plan is complete. The reason is that child plan 1 replaces the subscription worker's implicit control flow (the `runWorker` → `catchUp` → live-loop functions plus the `posRef`/`statusVar` mutable cells in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`) with an **explicit finite state machine**: a `SubscriptionState` value (states such as `CatchingUp`, `Live`, `Paused`, `Reconnecting`, `Stopped`) and a single exhaustive transition function (named `step` in child plan 1, in a new module `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`) that the worker drives. A "finite state machine" here means the worker is always in exactly one named state, and `step` is the one place that enumerates every legal move between states.

The per-event dispositions this plan adds are not branches in the old imperative `processEvents`; they are **new states and transitions in that FSM**. Concretely, when this plan's M1 is implemented on top of child plan 1:

- A retry disposition becomes a `Retrying { cursor, attempt, delayUntil }` state (or equivalent FSM context carrying the attempt count and the delay), with a transition that redelivers the *same* event after the delay and increments the attempt, and a transition to dead-letter once the configured maximum attempts is exceeded. The attempt counter lives in FSM state, not in an ad-hoc mutable cell.
- A dead-letter disposition becomes a transition out of event processing whose effect performs the atomic "insert `kiroku.dead_letters` row and advance the checkpoint" SQL and then resumes delivery at the next event.
- `Continue` and `Stop` keep their existing transitions (advance/continue; graceful checkpoint-and-stop into `Stopped`).

Child plan 1 is required by MasterPlan 6's Integration Points to make `step` exhaustively pattern-matched (compiled with `-Werror=incomplete-patterns`) and to leave a single documented extension seam. That means extending `SubscriptionResult` with the new constructors in this plan's M1 will produce a **compile error at every site that must handle the new disposition**, which is exactly the safety property you want: you cannot forget to handle retry or dead-letter anywhere. Do **not** fork a parallel state type in this plan; extend child plan 1's `SubscriptionState` and `step`.

This plan also has an **integration dependency** on child plan 4, `docs/plans/43-per-subscription-event-type-filtering-through-the-worker-streamly-bridge-and-shibuya-adapter.md`, on ordering: child plan 4 applies an event-type filter in the worker *before* delivery, and a filtered-out event must never reach this plan's ack-coupled bridge handler — it is skipped and the cursor advances past it, so it is never retried or dead-lettered. When implementing the disposition handling here, keep it strictly after the filter in the FSM delivery transition; do not move disposition handling ahead of the filter. Both plans add an additive field to `SubscriptionConfigM` (this plan a retry policy, child plan 4 an event-type filter); update `defaultSubscriptionConfig` for your field and rebase onto child plan 4's field if it landed first.

This plan also has a **soft / integration dependency** on child plan 3, `docs/plans/42-wire-kiroku-consumer-groups-into-the-shibuya-partitioned-ordering-policy-model.md`, through the shared Streamly bridge `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`. This plan makes that bridge **ack-coupled** (each emitted item carries a one-shot reply variable; the bridge handler blocks until the consumer replies with a `SubscriptionResult`, and only then does the worker checkpoint/retry/dead-letter). Child plan 3's research established that, because Shibuya's runner does **not** route by an envelope partition key (it runs one Shibuya processor per kiroku consumer-group member, so member identity rides the `ProcessorId` rather than the stream item), child plan 3 does **not** need to add a member field to the bridge item. Therefore this plan owns and defines the bridge item type. Define it as approximately `{ event, attempt, reply }` (final names per M0); child plan 3 consumes the per-event stream unchanged. Keep the existing `subscriptionStream` signature working for current users by implementing it in terms of the new ack-coupled primitive and always replying `Continue`.


## Progress

- [x] Problem analysis and layer attribution validated against current source. 2026-05-25.
- [x] Critical review found stale schema paths and an invalid adapter-only-finalize assumption; plan revised to require an ack-coupled stream bridge. 2026-05-26.
- [x] Adopted as child plan 2 of MasterPlan 6; rebased onto the subscription-worker FSM (child plan 1, `docs/plans/41-...`), which is now a hard dependency. 2026-05-29.
- [x] Unblocked: child plan 1 (FSM) is Complete — `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` exists with `SubscriptionState` (CatchingUp/Live/Paused/Reconnecting/Stopped) and an exhaustive `step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])` compiled `-Werror=incomplete-patterns`. 2026-05-29.
- [x] M0: finalized the Kiroku-native API shape — see the four RESOLVED M0 decisions in the Decision Log (disposition constructors + types, in-memory retry policy, single-delivery-primitive mechanics with `Retrying` observability state, `AckHalt`→cancel). 2026-05-29.
- [x] M1: added `Retry`/`DeadLetter` to `SubscriptionResult`, `RetryDelay`/`DeadLetterReason` in `Fsm`, `RetryPolicy` on the config, a surfaced `Retrying` `SubscriptionState`, and bounded-retry + atomic dead-letter-plus-checkpoint in the single delivery primitive `processEvents`. New lifecycle events. `kiroku-store` 172 examples, 0 failures. 2026-05-29.
- [x] M2: added the forward migration `2026-05-26-00-00-00-add-subscription-dead-letters.sql` (`kiroku.dead_letters`), the atomic `insertDeadLetterAndCheckpointStmt`, and `readDeadLettersStmt`; updated `docs/user/schema.md`. 2026-05-29.
- [x] M3: made the Streamly bridge ack-coupled (`subscriptionAckStream`/`AckItem`) and redesigned the adapter so `AckOk`/`AckRetry`/`AckDeadLetter`/`AckHalt` drive Kiroku dispositions via `AckHandle.finalize` before checkpoint advancement. 2026-05-29.
- [x] M4: added `Test.SubscriptionRetryDeadLetter` (3 specs), adapter ack-disposition specs (2), and a `dead_letters` assertion to the migration test; changelog entries across all three packages. All suites pass (kiroku-store 172, adapter 10, migrations 1). 2026-05-29.
- [x] Test-harness fix: `Kiroku.Test.Postgres.migrateTestDatabase` now applies *all* SQL files under `kiroku-store-migrations/sql-migrations` in filename order (was bootstrap-only), so `kiroku-store` and adapter tests see forward migrations like `dead_letters`. 2026-05-29.


## Surprises & Discoveries

- The original plan named `kiroku-store/sql/schema.sql`, but the current repository no longer has that path. The canonical runtime schema is documented in `docs/user/schema.md` as living in `kiroku-store-migrations/sql-migrations`; the only checked-in migration today is `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql`. Runtime SQL statements live in `kiroku-store/src/Kiroku/Store/SQL.hs`.
- The original plan's line references for `processEvents` were stale. In the current tree, `processEvents` is in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` around lines 474-500. It writes `posRef`, calls `handler config event`, checkpoints on `Stop`, and processes the next event on `Continue`.
- The original plan's adapter milestone was incomplete. `toIngested` in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` can see `AckRetry` and `AckDeadLetter`, but by then `subscriptionStream` has already returned `Continue` for the event. The bridge in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` must become ack-coupled or be replaced by an adapter-local bridge with the same property.
- Shibuya itself does not need a core change. `shibuya-core/src/Shibuya/Core/Ack.hs` defines all four ack decisions, and `shibuya-core/src/Shibuya/Runner/Processor.hs` calls `ingested.ack.finalize decision` after every handler result. The queue-specific mechanics belong in adapters.
- The `shibuya-pgmq-adapter` precedent is useful for semantics but not directly reusable code. Its `mkAckHandle` deletes on `AckOk`, changes visibility timeout on `AckRetry`, writes to a DLQ and deletes on `AckDeadLetter`, and changes visibility timeout on `AckHalt`. Kiroku is not a queue, so its equivalent mechanics are checkpoint, delay-and-redeliver-before-checkpoint, insert dead-letter plus checkpoint, and stop/cancel.

- The shared test harness applied only the bootstrap migration. `Kiroku.Test.Postgres.migrateTestDatabase` read a single hard-coded bootstrap SQL path, so `kiroku-store` and `shibuya-kiroku-adapter` test databases were built from the bootstrap only — any forward migration (like `dead_letters`) was invisible to them, even though the dedicated `kiroku-store-migrations` codd test applies the full set. Fixed by making the harness list and concatenate every `*.sql` under `kiroku-store-migrations/sql-migrations` in filename order (the bootstrap's `SET search_path` carries into later files; the new migration is `kiroku.`-qualified anyway). This is a general improvement that benefits every future forward migration.

- `embedDir` (file-embed, used by `kiroku-store-migrations`) does not trigger recompilation when a *new* file is added to the embedded directory — GHC's recompilation checker only tracks files that existed at the previous compile. The migration test failed spuriously until the `Kiroku.Store.Migrations` library object was rebuilt from clean. Real builds from clean are unaffected; this is only an incremental-build gotcha to note for the next person who adds a migration.

- Both `kiroku-store` (via re-export) and `shibuya-core` export a type named `RetryDelay` and a type named `DeadLetterReason`. In the adapter and its tests, `shibuya-core`'s `RetryDelay` must be qualified (e.g. `Ack.RetryDelay`) to disambiguate from the Kiroku one. The dead-letter constructor names do not collide (`PoisonPill`/`InvalidPayload`/`MaxRetriesExceeded` vs `DeadLetterPoison`/`DeadLetterInvalid`/`DeadLetterMaxAttempts`/`DeadLetterOther`).


## Decision Log

- Decision: Do not change `shibuya-core`.
  Rationale: Current Shibuya core already models handler intent with `AckDecision` and calls adapter-owned `AckHandle.finalize`; Kiroku-specific retry/dead-letter mechanics belong in `kiroku-store` and `shibuya-kiroku-adapter`.
  Date: 2026-05-25.

- Decision: Treat an adapter-only `finalize` mapping as invalid unless the Kiroku stream bridge is made ack-coupled.
  Rationale: Current `subscriptionStream` returns `Continue` immediately after enqueueing the event. That can advance the Kiroku checkpoint before `finalize` sees the Shibuya decision, making retry/dead-letter impossible to implement correctly from `finalize` alone.
  Date: 2026-05-26.

- Decision: Ship schema changes as a new timestamped forward migration under `kiroku-store-migrations/sql-migrations/`; do not edit the existing bootstrap migration.
  Rationale: `docs/user/schema-migrations.md` says codd migrations are forward-only and migration files must not be edited after release. Plan 40 must follow the current migration model, not older plans that referenced `kiroku-store/sql/schema.sql`.
  Date: 2026-05-26.

- Decision (open): Kiroku-native handler result shape. The preferred direction is to extend `SubscriptionResult` with Kiroku-owned constructors such as `Retry RetryDelay` and `DeadLetter DeadLetterReason`, where the Kiroku types do not depend on `shibuya-core`. Keep `Continue` and `Stop` for backward source compatibility where possible, then update exhaustive pattern matches and docs. M0 must confirm names, exported modules, and whether retry delay is `NominalDiffTime`, microseconds, or a small newtype.

- Decision (open): Retry bounds and attempt reporting. The preferred direction is to add a `retryPolicy` field to `SubscriptionConfigM` with defaults such as max attempts and an optional cap, track attempts in the worker for the current event, delay before redelivery, and dead-letter on exhaustion. M0 must decide whether attempts are in-memory only or persisted. In-memory attempts are simpler but reset on process restart; persistent attempts require more schema and are a larger behavioral commitment.

- Decision (open): Dead-letter reason representation. The preferred direction is to store a Kiroku-owned JSONB reason, plus a text summary for operator queries. The adapter can convert Shibuya `DeadLetterReason` into this Kiroku representation without introducing a dependency from `kiroku-store` to `shibuya-core`.

- Decision: Adopt this plan as child plan 2 of MasterPlan 6 and rebase its mechanics onto the subscription-worker FSM from child plan 1 (`docs/plans/41-...`).
  Rationale: MasterPlan 6 introduces an explicit `SubscriptionState` FSM in `kiroku-store`. Retry-with-bounded-attempts is naturally a `Retrying` state holding the attempt count as FSM context, and dead-letter-then-advance is a transition with an atomic SQL effect. Implementing dispositions against the current implicit control flow and then re-expressing them on the FSM would be duplicate work; sequencing the FSM first (hard dependency) avoids it. The FSM's exhaustive transition function also guarantees the new constructors are handled everywhere at compile time.
  Date: 2026-05-29.

- Decision: This plan owns the ack-coupled Streamly bridge item type; child plan 3 (`docs/plans/42-...`) does not extend it with member identity.
  Rationale: Child plan 3's research found that Shibuya's runner does not route by an envelope partition key (`Envelope.partition` is only an OpenTelemetry attribute and `Concurrency Async n` is unkeyed fan-out); it therefore runs one Shibuya processor per kiroku consumer-group member, so member identity rides the `ProcessorId`, not the stream item. The bridge item is thus `{ event, attempt, reply }` (final names per M0), defined here and consumed unchanged by child plan 3.
  Date: 2026-05-29.

- Decision (M0, RESOLVED): Kiroku-native handler result shape and supporting types.
  `SubscriptionResult` gains two constructors: `Retry !RetryDelay` (redeliver the same
  event after a delay) and `DeadLetter !DeadLetterReason` (record the event and advance
  past it). `RetryDelay` is a `newtype RetryDelay = RetryDelay NominalDiffTime` with a
  `retryDelayMicros :: RetryDelay -> Int` helper for `threadDelay`. `DeadLetterReason` is a
  Kiroku-owned sum: `DeadLetterPoison !Text | DeadLetterInvalid !Text |
  DeadLetterMaxAttempts !Int | DeadLetterOther !Text !Value`, with `deadLetterSummary ::
  DeadLetterReason -> Text` (the `reason_summary` column) and `deadLetterReasonJson ::
  DeadLetterReason -> Value` (the `reason` JSONB column). Both `RetryDelay` and
  `DeadLetterReason` are defined in `Kiroku.Store.Subscription.Fsm` (the dependency-graph
  leaf), re-exported from `Kiroku.Store.Subscription.Types` for the public API and from
  `Kiroku.Store.Observability` for the new lifecycle event. This mirrors how EP-1 placed
  `SubscriptionStopReason` in `Fsm` to keep the module graph acyclic (`Subscription.Types`
  imports `Fsm`, so the disposition types cannot live in `Subscription.Types`).
  Date: 2026-05-29.

- Decision (M0, RESOLVED): Retry bounds and attempt reporting are in-memory.
  Add `retryPolicy :: !RetryPolicy` to `SubscriptionConfigM` where `data RetryPolicy =
  RetryPolicy { retryMaxAttempts :: !Int }`, default `defaultRetryPolicy = RetryPolicy 5`.
  Attempts are tracked in-memory by the worker's delivery primitive for the current event;
  on process restart a redelivered-but-uncheckpointed event simply starts again from
  attempt 0 (acceptable under at-least-once). The delay per redelivery comes from the
  handler's `Retry RetryDelay` (mirroring Shibuya's per-decision `AckRetry RetryDelay`),
  so `RetryPolicy` only carries the bound. On exhaustion the event is dead-lettered with
  `DeadLetterMaxAttempts n`. The ack-coupled bridge reports the attempt to the Shibuya
  envelope (`attempt :: Maybe Attempt`) by tracking consecutive redeliveries of the same
  `event_id` in the bridge.
  Date: 2026-05-29.

- Decision (M0, RESOLVED): Disposition mechanics live in the worker's single delivery
  primitive (`processEvents`), with `Retrying` added to the FSM `SubscriptionState` for
  observability — rather than threading whole-batch vectors through new FSM `Input`
  constructors. EP-1's `step` is exhaustive on `SubscriptionState`, so adding the
  `Retrying` constructor forces a compile error in `step` and `stateCursor` (the safety the
  MasterPlan valued), and adding the `SubscriptionResult` constructors forces a compile
  error at every `case`-on-`SubscriptionResult` site (`processEvents`, the bridge, the
  adapter, the tests). `processEvents` is the one delivery primitive shared by all three
  delivery paths (the FSM `DeliverBatch` effect for catch-up/AllStreams-live, and the
  Category / consumer-group live loops); implementing dispositions there once avoids
  duplicating bounded-retry logic across the FSM path and the imperative live loops. The
  worker writes `Retrying` into the observable state `TVar` and emits
  `KirokuEventSubscriptionRetrying` while a redelivery is pending, restoring the prior
  driving state afterward. This deviates from the MasterPlan Integration Point that
  envisioned new FSM `Input` constructors driving `step`; the deviation is recorded in the
  MasterPlan Surprises & Discoveries. The atomic "insert dead-letter + advance checkpoint"
  is a single CTE statement.
  Date: 2026-05-29.

- Decision (M0, RESOLVED): `AckHalt` keeps the current adapter behavior — it cancels the
  underlying Kiroku subscription (no checkpoint advance, so the halting event replays on
  restart) rather than mapping to Kiroku `Stop` (which would checkpoint at and advance past
  the halting event). Halting semantically means "stop without acknowledging this event,"
  which cancellation models faithfully and which preserves the existing adapter contract.
  Date: 2026-05-29.


## Outcomes & Retrospective

Shipped 2026-05-29.

- **Handler result constructors.** `SubscriptionResult = Continue | Stop | Retry !RetryDelay | DeadLetter !DeadLetterReason`. `newtype RetryDelay = RetryDelay NominalDiffTime` (with `retryDelayMicros`). `DeadLetterReason = DeadLetterPoison !Text | DeadLetterInvalid !Text | DeadLetterMaxAttempts !Int | DeadLetterOther !Text !Value`, with `deadLetterSummary` (→ `reason_summary`) and `deadLetterReasonJson` (→ `reason` JSONB). All defined in `Kiroku.Store.Subscription.Fsm`, re-exported from `Subscription.Types` and `Observability`.
- **Retry policy.** `newtype RetryPolicy = RetryPolicy { retryMaxAttempts :: Int }`, `defaultRetryPolicy = RetryPolicy 5`, added to `SubscriptionConfigM` (default inherited via `defaultSubscriptionConfig`). Attempts are in-memory and 1-based; the per-redelivery delay comes from each `Retry RetryDelay`. On exhaustion the worker dead-letters with `DeadLetterMaxAttempts`.
- **FSM.** Added a surfaced `Retrying { cursor, attempt }` `SubscriptionState` (visible via `currentState`; `step`/`stateCursor` handle it exhaustively). Disposition mechanics live in the single delivery primitive `processEvents` (used by the FSM `DeliverBatch` effect and both live loops), not in new FSM `Input` constructors — see the M0 decision and the MasterPlan Surprises for the deviation rationale.
- **Dead-letter schema.** `kiroku.dead_letters` (forward migration `2026-05-26-00-00-00-add-subscription-dead-letters.sql`), per consumer-group member, FK to `kiroku.events`. The atomic "insert dead-letter + advance checkpoint" is the single-statement CTE `SQL.insertDeadLetterAndCheckpointStmt`; if the insert fails the checkpoint does not advance.
- **Adapter / bridge.** New ack-coupled `subscriptionAckStream` emits `AckItem { ackEvent, ackAttempt, ackReply }`; the worker blocks until the reply is filled. The adapter's `AckHandle.finalize` maps `AckOk→Continue`, `AckRetry delay→Retry`, `AckDeadLetter reason→DeadLetter` (reason translated to Kiroku-native), `AckHalt→cancel` (unchanged). `subscriptionStream` is reimplemented on the primitive (always replies `Continue`); its behavior is unchanged.
- **Migration behavior.** codd applies the new forward migration after the bootstrap and is idempotent on re-run. The shared test harness (`Kiroku.Test.Postgres`) was updated to apply all migration files in order so non-codd test databases also get `dead_letters`.
- **Test results.** `kiroku-store`: 172 examples, 0 failures (incl. dead-letter-advances-and-continues, retry-until-success, retry-exhaustion-dead-letters). `shibuya-kiroku-adapter`: 10 examples, 0 failures (incl. AckRetry-then-AckOk delivers twice; AckDeadLetter records and continues). `kiroku-store-migrations`: 1 example, 0 failures (asserts `kiroku.dead_letters` exists).


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. `mori show --full` identifies it as `shinzui/kiroku` with packages `kiroku-store`, `shibuya-kiroku-adapter`, and `kiroku-otel`. The Shibuya dependency is registered as `shinzui/shibuya` at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; its PGMQ adapter precedent is registered separately at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.

Kiroku subscription types live in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. `SubscriptionResult` currently has only `Continue` and `Stop`. `SubscriptionConfigM` contains the handler, batch size, queue capacity, overflow policy, and optional consumer group information. Existing callers build configs with `defaultSubscriptionConfig`, so adding a new field is safest if the default constructor is updated and adapter code continues to override only the fields it needs.

Kiroku subscription execution lives in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. `processEvents` receives a vector of `RecordedEvent`, calls the configured handler once per event, and uses `saveCheckpoint` to persist progress in `kiroku.subscriptions`. `saveCheckpoint` uses `SQL.saveCheckpointMemberStmt` from `kiroku-store/src/Kiroku/Store/SQL.hs`, keyed by `(subscription_name, consumer_group_member)`. Dead-lettering must insert the dead-letter row and save the checkpoint for that event atomically. A single SQL statement with common table expressions is acceptable; a small `hasql-transaction` transaction is also acceptable if error reporting remains as clear as the existing `saveCheckpoint` path.

The pull-stream bridge lives in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`. Its current `subscriptionStream` ignores the caller's handler, installs a bridge handler, writes `Just event` into a `TBQueue`, and returns `Continue`. This behavior is correct for plain streaming but insufficient for Shibuya ack semantics. Either change `subscriptionStream` to a more general ack-coupled primitive while preserving the old API, or add a new function such as `subscriptionAckStream` that yields an event plus an ack reply action. Preserve the existing `subscriptionStream` semantics for current users by implementing it in terms of the new primitive and always replying `Continue`.

The Kiroku adapter lives in `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` and `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`. `Kiroku.hs` creates a subscription stream and maps each `RecordedEvent` through `toIngested`. `Convert.hs` builds the `Envelope` and the `AckHandle`. Today `toEnvelope` sets `attempt = Nothing`; after retry support, the adapter should set `attempt = Just (Attempt n)` if the chosen Kiroku stream item exposes the current attempt. Check the exact `Attempt` type exported by Shibuya before coding.

Schema migrations are owned by `kiroku-store-migrations`. The current docs say the package embeds SQL files from `kiroku-store-migrations/sql-migrations`, runs them through codd, and uses `CODD_SCHEMAS=kiroku`. Add a new timestamped migration file for `kiroku.dead_letters`; update `docs/user/schema.md` to document the table; update `docs/user/schema-migrations.md` only if the migration workflow itself changes.


## Plan of Work

### M0 — Close the design decisions before coding

Read the exact source files named above and confirm the exported API surface. Decide the names and types for the new Kiroku disposition constructors, retry policy, dead-letter reason, and attempt count. Record the decisions in the Decision Log before editing code. The outcome of M0 is a small API sketch in prose that a contributor can implement without guessing.

The API should remain Kiroku-native. Do not import `Shibuya.Core.Ack` into `kiroku-store`. The adapter is the translation layer from `AckRetry RetryDelay` and `AckDeadLetter DeadLetterReason` into Kiroku's own retry and dead-letter types.

### M1 — Add per-event disposition in `kiroku-store`

Extend `SubscriptionResult` in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`. Keep `Continue` and `Stop`; add retry and dead-letter constructors using the M0 names. Add any retry policy field to `SubscriptionConfigM` and update `defaultSubscriptionConfig`. Because child plan 1 (`docs/plans/41-...`) made the worker's transition function `step` exhaustively pattern-matched under `-Werror=incomplete-patterns`, adding the new constructors will produce a compile error at every site that must handle them — work through each one. The sites to expect are the FSM transition function in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, the effect handlers in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, the bridge in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`, the tests, and the adapter compile surface.

Express the new outcomes as **FSM states and transitions**, not as branches in an imperative loop (see the "Relationship to MasterPlan 6" section above). `Continue` keeps its transition (deliver next event / advance). `Stop` keeps its transition into `Stopped` with a graceful checkpoint at the current event. Retry adds a `Retrying` state (carrying the attempt count and the delay deadline as FSM context): its transition does not advance the checkpoint past the event; after the delay it re-enters delivery of the *same* event with an incremented attempt, and once the configured maximum attempts is exceeded it transitions to the dead-letter path with an explicit max-retries-exceeded reason instead of looping forever. Dead-letter adds a transition whose effect atomically inserts into `kiroku.dead_letters` and checkpoints at the event's global position, then resumes delivery at the next event. If child plan 1 named the states or the transition function differently, follow the names actually present in `Fsm.hs` and record the correction in this plan's Progress section.

### M2 — Add dead-letter storage and read support

Add a new forward migration under `kiroku-store-migrations/sql-migrations/`, for example `2026-05-26-00-00-00-add-subscription-dead-letters.sql` if that timestamp is still unused. The table should live in the `kiroku` schema and reference the immutable event by `event_id` and global position rather than duplicating the full payload. A concrete starting schema is:

```sql
CREATE TABLE IF NOT EXISTS kiroku.dead_letters (
    dead_letter_id BIGSERIAL PRIMARY KEY,
    subscription_name TEXT NOT NULL,
    consumer_group_member INT NOT NULL DEFAULT 0,
    global_position BIGINT NOT NULL,
    event_id UUID NOT NULL REFERENCES kiroku.events(event_id),
    reason JSONB NOT NULL,
    reason_summary TEXT NOT NULL,
    attempt_count INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (subscription_name, consumer_group_member, global_position, event_id)
);

CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_created_at
    ON kiroku.dead_letters (subscription_name, consumer_group_member, created_at);
```

If M0 chooses a different reason representation, update the SQL accordingly before implementation. Add statements to `kiroku-store/src/Kiroku/Store/SQL.hs` for inserting a dead-letter and for reading dead letters by subscription/member. A replay API is useful but not required for this plan; do not expand scope unless tests need it.

### M3 — Make the Shibuya adapter ack-coupled

Replace the current adapter path where `subscriptionStream` emits a bare `RecordedEvent` and `toIngested` receives only `cancelAction`. The new bridge must keep the Kiroku handler blocked until the Shibuya ack decision is finalized. One practical shape is a stream item containing the event, current attempt, and a one-shot `TMVar` or `MVar` reply. The Kiroku bridge handler writes the item to the queue, waits for the reply, and returns the replied `SubscriptionResult`. The `AckHandle.finalize` writes the translated result into the reply variable exactly once.

Map Shibuya decisions as follows. `AckOk` replies `Continue`. `AckRetry delay` replies the Kiroku retry disposition using the requested delay. `AckDeadLetter reason` replies the Kiroku dead-letter disposition with a Kiroku-native reason converted from Shibuya's reason. `AckHalt reason` should preserve current behavior by cancelling or stopping; choose `Stop` if graceful checkpoint-at-current-event semantics are desired, and use cancellation only if the existing "stop processor now" behavior must be preserved. Record this choice in the Decision Log because it affects whether an `AckHalt` event is considered processed.

### M4 — Tests, docs, and changelogs

Add `kiroku-store` tests near the existing subscription tests in `kiroku-store/test/Main.hs` or split focused tests into a new module if that matches the surrounding structure. Cover at least: a handler returns dead-letter for event 2, event 2 appears in `kiroku.dead_letters`, the checkpoint advances, and event 3 is delivered; a handler returns retry twice and then continue, and the same event is delivered three times without a checkpoint advance before success; retry exhaustion dead-letters and later events continue.

Add `shibuya-kiroku-adapter` tests proving end-to-end mapping. The test should run an adapter-backed Shibuya handler that returns `AckRetry` for the first delivery and `AckOk` for the second, then assert the same Kiroku event was delivered twice. Add a second test where the handler returns `AckDeadLetter`, then assert the event is in `kiroku.dead_letters` and the next event is processed. The PGMQ adapter tests are a semantic precedent, but do not copy queue visibility-timeout assertions because Kiroku does not use visibility timeouts.

Update `docs/user/schema.md` with the new `kiroku.dead_letters` table. Add changelog entries to `kiroku-store/CHANGELOG.md`, `kiroku-store-migrations/CHANGELOG.md`, and the adapter changelog if one exists. If there is no adapter changelog, add the package note in the nearest existing changelog convention rather than creating a new release process.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, start with source verification:

```bash
mori show --full
mori registry show shinzui/shibuya --full
sed -n '1,180p' kiroku-store/src/Kiroku/Store/Subscription/Types.hs
sed -n '450,535p' kiroku-store/src/Kiroku/Store/Subscription/Worker.hs
sed -n '1,110p' kiroku-store/src/Kiroku/Store/Subscription/Stream.hs
sed -n '1,120p' shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs
```

After each implementation milestone, build the affected package:

```bash
cabal build kiroku-store
cabal build shibuya-kiroku-adapter
cabal build kiroku-store-migrations
```

Run the final validation commands:

```bash
cabal test kiroku-store:kiroku-store-test
cabal test shibuya-kiroku-adapter:shibuya-kiroku-adapter-test
cabal test kiroku-store-migrations:kiroku-store-migrations-test
```

Expected success is that each test suite ends with `PASS` and reports zero failures. If a test name differs in the local `.cabal` file, use the exact suite name listed there and record that correction in this plan's Progress section.


## Validation and Acceptance

The Kiroku-level acceptance criterion is behavioral, not just compilation. A subscription handler can return a retry disposition for one event and observe that the worker redelivers that same event before checkpointing past it. The retry is bounded; once the configured maximum is exceeded, the worker records a dead letter and continues rather than spinning forever.

The dead-letter acceptance criterion is atomicity. When a handler dead-letters an event, the same database operation or transaction records `kiroku.dead_letters` and advances `kiroku.subscriptions.last_seen` to that event's global position. A process crash must not leave an event neither deliverable nor recorded as dead-lettered. If the dead-letter insert fails, the checkpoint must not advance.

The adapter acceptance criterion is that Shibuya ack decisions affect Kiroku. A handler returning `AckRetry` gets the same Kiroku event again. A handler returning `AckDeadLetter` records the event in `kiroku.dead_letters` and later events continue. These tests fail against the current implementation because `AckRetry` and `AckDeadLetter` are no-ops.

The migration acceptance criterion is that `kiroku-store-migrations:kiroku-store-migrations-test` applies embedded codd migrations to an empty PostgreSQL database, observes `kiroku.dead_letters` in the `kiroku` schema, opens `kiroku-store`, writes and reads an event, and runs migrations again without reapplying or failing.


## Idempotence and Recovery

All source edits are ordinary Git changes. The schema change is additive and forward-only: it creates a new table and indexes but does not mutate existing event data. Re-running tests is safe because the test suite uses ephemeral PostgreSQL databases. Re-running codd migrations is safe after the first successful run because codd records applied migrations.

Do not edit `kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql` for this plan. If the new migration is applied locally and then the branch is abandoned, the database keeps the extra table; recovery for a local development database is to drop and recreate the local database. Production rollback requires a separate forward migration or database restore, consistent with `docs/user/schema-migrations.md`.

If implementation stalls in the adapter bridge, preserve the existing `subscriptionStream` API and add a new internal ack-coupled bridge instead of breaking current stream users. If the new public Kiroku handler result causes too much source breakage, record the breakage in Surprises & Discoveries and consider adding a compatibility helper rather than weakening the semantics.


## Interfaces and Dependencies

`kiroku-store` owns the new subscription disposition API, retry policy, dead-letter reason type, dead-letter SQL statements, and worker mechanics. It must not depend on `shibuya-core`.

`kiroku-store-migrations` owns the new `kiroku.dead_letters` table and migration tests. The current migration package uses codd with `CODD_SCHEMAS=kiroku` and `runKirokuMigrationsNoCheck` in tests.

`shibuya-kiroku-adapter` owns translation from Shibuya `AckDecision` to Kiroku-native dispositions. It depends on both `kiroku-store` and `shibuya-core`, so it is the correct place to convert Shibuya `RetryDelay`, `DeadLetterReason`, and `HaltReason`.

The local Shibuya source used to validate this plan is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The local PGMQ adapter source used as a semantic precedent is `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.


## Revision Notes

- 2026-05-25 — Created by another team. The initial version correctly identified that `AckRetry` and `AckDeadLetter` are no-ops in the current Kiroku adapter, but it assumed old schema paths and understated the adapter bridge problem.
- 2026-05-26 — Critical validation against current Kiroku and Shibuya source. Rewrote the plan to remove stale `kiroku-store/sql/schema.sql` instructions, use the current codd migration package, update worker/source references, and require an ack-coupled stream bridge so Shibuya ack decisions can affect Kiroku checkpointing before it is too late.
- 2026-05-29 — Adopted into MasterPlan 6 (`docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md`) as child plan 2. Added `master_plan` and `intention` frontmatter. Added a "Relationship to MasterPlan 6 and the subscription-worker FSM" section establishing a hard dependency on child plan 1 (`docs/plans/41-...`). Rebased M1 so retry and dead-letter are expressed as FSM states/transitions (`Retrying` state, dead-letter transition) in the new `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` rather than as branches in the imperative `processEvents`. Recorded that this plan owns the ack-coupled bridge item type and that child plan 3 (`docs/plans/42-...`) does not add member identity to it, because Shibuya's runner does not route by envelope partition key (member identity rides the `ProcessorId`). Reason: coordinate the three subscription work streams so disposition handling is implemented once, on the FSM, and the shared Streamly bridge has a single agreed shape.
