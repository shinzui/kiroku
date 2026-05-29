---
id: 6
slug: subscription-worker-fsm-and-end-to-end-shibuya-integration
title: "Subscription-worker FSM and end-to-end Shibuya integration"
kind: master-plan
created_at: 2026-05-29T20:08:27Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
---

# Subscription-worker FSM and end-to-end Shibuya integration

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku is a PostgreSQL-backed event store (repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, package `kiroku-store`). A **subscription** is a long-lived worker that reads events in order — either the global `$all` stream or one category — and feeds them to a handler one at a time, remembering progress in a durable **checkpoint** row (`kiroku.subscriptions.last_seen`). The subscription runtime lives in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, with a centralized broadcaster in `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` and a PostgreSQL `LISTEN`/`NOTIFY` wake source in `kiroku-store/src/Kiroku/Store/Notification.hs`.

Kiroku's design is heavily influenced by the Elixir EventStore project (local source at `/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`). EventStore models each subscription as an **explicit finite state machine** (a "finite state machine" is a value that is always in exactly one named state — for EventStore: `initial`, `request_catch_up`, `catching_up`, `subscribed`, `max_capacity`, `disconnected`, `unsubscribed` — with a transition function that names every legal move between states; see `lib/event_store/subscriptions/subscription_fsm.ex`). Kiroku reproduces EventStore's **behavior** (two phases: catch up against history, then go live on notifications; at-least-once delivery; monotonic checkpoints) but tracks its state **implicitly** through which function happens to be executing (`runWorker` → `catchUp` → one of three live loops) plus two mutable cells (`posRef :: IORef GlobalPosition` for the cursor, `statusVar :: TVar SubscriberStatus` for liveness). There is no value you can read to ask "what state is this subscription in," and no single place that enumerates the legal transitions.

That implicit model leaves three concrete behavioral gaps relative to EventStore, each of which this initiative closes:

1. **Overflow is terminal, not backpressure.** When a subscriber's bounded queue fills, the publisher sets `SubscriberStatus` to `Overflowed` and the worker throws `SubscriptionOverflowed` and dies (overflow policy `DropSubscription`), or silently drops events (`DropOldest`). EventStore instead enters a recoverable `max_capacity` state: it stops sending, waits for the consumer to drain, and resumes. Kiroku has no "paused, waiting to resume" state.
2. **No worker-level reconnect.** Reconnect logic exists only at the `LISTEN`/`NOTIFY` listener layer (`Notification.hs`) and as fetch-retry-with-backoff inside `catchUp`. A worker that loses its database pool while live simply dies and propagates the exception; EventStore transitions `subscribed → disconnected → request_catch_up` and resumes from the last acknowledged position.
3. **Per-event dispositions have nowhere to live, and the Shibuya integration is therefore unfinished.** The handler result type `SubscriptionResult` (in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`) is only `Continue | Stop`. There is no way for a handler to ask that one event be retried later or recorded as a poison event ("dead-lettered") while the subscription advances past it. This most directly hurts `shibuya-kiroku-adapter`, which bridges a Kiroku subscription into the Shibuya queue-processing framework (local source `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`): Shibuya handlers return `AckOk | AckRetry | AckDeadLetter | AckHalt`, but the adapter implements `AckRetry` and `AckDeadLetter` as no-ops because the stream bridge (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`) returns `Continue` and lets the checkpoint advance before the Shibuya handler has even run.

A fourth gap is **per-subscription event-type filtering**, again of a different kind: a missing capability rather than a regression. EventStore lets a subscriber pass a `selector` (a function `RecordedEvent -> Bool`) so it only receives events it cares about; filtered-out events are still marked acknowledged so the checkpoint advances past them and progress never stalls (see `lib/event_store/subscriptions/subscription_fsm.ex`, `enqueue_events`/`selected?`). Kiroku has no equivalent: `SubscriptionConfigM` has no selector field, no read statement filters on `event_type`, and the Streamly bridge exposes no filter, so a handler that only cares about one event type must receive and discard every other type itself — and a caller who filters the resulting `Stream` downstream with `Streamly.Data.Stream.filter` does not control checkpointing at all. (There is an `EventFilter` type in `kiroku-store/src/Kiroku/Store/Types.hs`, but it is only for correlation/causation *queries*, not subscriptions.) `RecordedEvent` already carries `eventType :: EventType`, so the data is present; only the subscription-level filter is missing.

A fifth concern is partitioning, but of a different kind: it is not a regression against EventStore, it is an unfinished integration. Kiroku already has **consumer groups** — a named subscription split into N static members, each member receiving the streams whose name hashes to its slot, each with its own checkpoint keyed `(subscription_name, consumer_group_member)`. That work shipped under `docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`. Shibuya independently has its own partitioning vocabulary in `shibuya-core/src/Shibuya/Policy.hs`: an `Ordering` (`StrictInOrder | PartitionedInOrder | Unordered`) and a `Concurrency` mode (`Serial | Ahead Int | Async Int`), validated so that `StrictInOrder` requires `Serial`. The Kiroku adapter only passes a `consumerGroup` field through; it never connects kiroku's member partitioning to Shibuya's `PartitionedInOrder` policy, so an operator who wants a parallel group must hand-build N adapters wired to N processors instead of declaring one partitioned subscription.

After this initiative is complete:

- A subscription worker is always in exactly one named state, readable for observability, with a single documented transition table. A consumer that falls behind is **paused and resumed** rather than killed (configurably), and a worker that loses its database connection while live **reconnects and resumes from its checkpoint** rather than dying.
- A handler — native, Streamly-bridged, or Shibuya — can return a **retry** disposition for one event (the same event is redelivered, bounded, before the checkpoint advances) or a **dead-letter** disposition (the event is recorded in a new `kiroku.dead_letters` table and the checkpoint advances atomically past it). A Shibuya handler returning `AckRetry`/`AckDeadLetter` produces exactly these effects instead of disappearing as a no-op.
- The Shibuya adapter exposes a kiroku consumer group as a **single partitioned subscription** that maps onto Shibuya's `PartitionedInOrder` ordering, so the policy a Shibuya operator declares and kiroku's actual per-member partitioning agree, observably, end to end.
- A subscription can declare an **event-type filter** so its handler — native, Streamly-bridged, or Shibuya — receives only events of the chosen types, while the checkpoint still advances past the filtered-out events so the subscription never stalls. The filter is applied in the worker before delivery, so it composes with the bridge and adapter without changing the stream's element type.

**Explicitly out of scope.** Dynamic consumer-group rebalancing (runtime member reassignment / live group resizing) is not part of this initiative; kiroku's static `(member, size)` model is retained, consistent with the decision recorded in MasterPlan 4. No changes are made to `shibuya-core`; all Shibuya-specific translation stays in `shibuya-kiroku-adapter`, consistent with EP-40's existing decision log. A per-subscription **transform/mapper** (EventStore's `mapper`) is excluded; child plan 4 adds filtering only, because a transform does not affect checkpointing and callers can already `fmap` the typed `Stream IO RecordedEvent` downstream. OpenTelemetry metric emission for the new states is deferred (see the project-wide OTel deferral; the `kiroku-otel` package already adapts `KirokuEvent` and will pick up new constructors without core changes).


## Decomposition Strategy

The initiative splits into four work streams by functional concern, each independently verifiable, sequenced so that no stream reworks another's output.

**Child plan 1 — the finite state machine (`docs/plans/41-...`).** This is the foundation. It introduces an explicit `SubscriptionState` value and a transition function in `kiroku-store`, re-expressing today's implicit phases (catch-up, live, stopped) as named states and adding the two missing recoverable states (paused/backpressured, reconnecting). It changes no public handler API and adds no per-event dispositions; its acceptance is that existing subscription behavior is preserved while the new paused/reconnect behaviors become observable and testable. It is first because the other two streams attach new behavior to states, and building them on the current implicit control flow would mean implementing the same logic twice.

**Child plan 2 — per-event retry and dead-letter (`docs/plans/40-...`, the existing EP-40, adopted and rebased).** This extends `SubscriptionResult` with retry and dead-letter constructors, adds a retry policy and the `kiroku.dead_letters` table, makes the Streamly bridge ack-coupled, and redesigns the Shibuya adapter so `AckRetry`/`AckDeadLetter` drive real Kiroku dispositions before the checkpoint advances. EP-40 already exists with substantial design work (its M0 decision log); rather than discard it, this MasterPlan adopts it as child plan 2 and rebases its mechanics so the new dispositions become **transitions and a `Retrying` state in the child-plan-1 FSM** instead of branches in the old imperative `processEvents`. It hard-depends on child plan 1 because retry-with-bounded-attempts is naturally a state (attempt counter as FSM context) and dead-letter-then-advance is a transition out of event processing.

**Child plan 3 — consumer-group ↔ Shibuya policy partitioning (`docs/plans/42-...`).** This connects kiroku's existing static consumer-group partitioning (delivered by MasterPlan 4) to Shibuya's `Ordering`/`Concurrency` policy, so the Shibuya adapter can present a whole group as one `PartitionedInOrder` subscription rather than requiring manual N-adapter fan-out, and so the declared policy and kiroku's real partitioning are reconciled and asserted. It is adapter-and-config work in `shibuya-kiroku-adapter` plus minor `kiroku-store` ergonomics; it must not change `shibuya-core`.

**Child plan 4 — per-subscription event-type filtering (`docs/plans/43-...`).** This adds an event-type filter to `SubscriptionConfigM`, applied **in the worker before delivery** (the decision recorded by the user: an in-memory worker-side filter, not SQL pushdown, so the shared `$all` broadcast publisher in `kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs` is untouched), and surfaces it through the Streamly bridge and the Shibuya adapter. Its defining correctness property mirrors EventStore: a filtered-out event must still **advance the checkpoint** (the worker moves its cursor past it) so a highly selective subscription never stalls. Because the filter is applied before the handler/bridge sees the event, it changes no stream element type and composes with the other plans. It carries a soft dependency on child plan 1 because "deliver this event versus skip it but still advance the cursor" is precisely a delivery transition in the FSM, and that is the clean home for the no-stall invariant. Filtering only — no transform/mapper (see Vision & Scope).

Alternatives considered and rejected: (a) a single mega-ExecPlan — rejected because it would exceed five milestones across `kiroku-store`, `kiroku-store-migrations`, and `shibuya-kiroku-adapter`, the threshold MASTERPLAN.md sets for preferring a MasterPlan. (b) Doing retry/dead-letter (EP-40) first on the current imperative loop and FSM-ifying afterward — rejected because it would implement disposition handling twice and throw the first version away; sequencing the FSM first avoids the rework. (c) Folding partitioning into the adapter changes of child plan 2 — rejected because partitioning has no dependency on dead-letter mechanics and is independently verifiable; merging them would couple two unrelated behaviors and unbalance the plans.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Explicit subscription-worker finite state machine with recoverable backpressure and live reconnect | docs/plans/41-explicit-subscription-worker-finite-state-machine-with-recoverable-backpressure-and-live-reconnect.md | None | None | Complete |
| 2 | Per-event retry / dead-letter for kiroku subscriptions and the shibuya-kiroku-adapter | docs/plans/40-per-event-retry-and-dead-letter-for-kiroku-subscriptions-and-the-shibuya-adapter.md | EP-1 | EP-3 | In Progress |
| 3 | Wire kiroku consumer groups into the Shibuya partitioned-ordering policy model | docs/plans/42-wire-kiroku-consumer-groups-into-the-shibuya-partitioned-ordering-policy-model.md | None | EP-1 | Not Started |
| 4 | Per-subscription event-type filtering through the worker, Streamly bridge, and Shibuya adapter | docs/plans/43-per-subscription-event-type-filtering-through-the-worker-streamly-bridge-and-shibuya-adapter.md | None | EP-1 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

Child plan 1 (FSM) is the root. It has no dependencies and should be implemented first. It defines the `SubscriptionState` type, the transition function, and the per-worker reconnect/pause behavior that the other plans extend.

Child plan 2 (EP-40, retry/dead-letter) **hard-depends** on child plan 1. The hard dependency is real in the MASTERPLAN.md sense — child plan 2's code would not make sense without child plan 1's artifacts. Bounded retry is "redeliver the same event, counting attempts, until success or a maximum, then dead-letter": in the FSM this is a `Retrying` state holding the attempt count as context, with transitions back to event processing or onward to dead-letter. Dead-letter-then-advance is a transition that performs an atomic SQL write and moves the cursor. Implementing these against the current implicit control flow would mean writing disposition handling once now and rewriting it onto the FSM later. Child plan 2 also carries a **soft dependency** on child plan 3 (see Integration Points): both touch the Shibuya adapter's bridge, and the dead-letter table is keyed by consumer-group member, so the two plans must agree on the per-member shape even though neither blocks the other's start.

Child plan 3 (partitioning) has **no hard dependency** and is largely independent: its core work — mapping a kiroku consumer group onto Shibuya's `Ordering`/`Concurrency` policy in the adapter via a helper that emits one policy-pinned Shibuya processor per member — does not require the FSM and does not change the Streamly bridge (see Integration Points). It carries a weak **soft dependency** on child plan 1 only for landing order: the cleanest place to surface per-member state for the policy-reconciliation tests is the FSM's observable state, and finalizing child plan 3 after child plan 1 lets those tests assert against named states rather than implicit phases.

Child plan 4 (event-type filtering) has **no hard dependency** and carries a **soft dependency** on child plan 1: the filter is applied in the FSM's delivery transition, and the "skip but still advance the cursor" invariant lives most naturally there, so finalizing it after child plan 1 avoids implementing the skip logic against the implicit control flow and then moving it onto the FSM. It is otherwise independent of child plans 2 and 3 and can proceed in parallel with them; the only coupling is that it edits the shared `SubscriptionConfigM` record and the shared adapter config, which is an additive integration point (see below).

Recommended order is 1 → (2, 3, and 4 in parallel), with a single reconciliation checkpoint on the shared `SubscriptionConfigM` and Streamly bridge before any of 2, 3, or 4 finalizes: confirm that child plan 4's filter is applied *before* child plan 2's ack-coupled bridge handler (so retry/dead-letter only ever apply to delivered events), that child plan 3 does not introduce a bridge item type competing with child plan 2's ack-coupled item, and that all config-field additions land on the one `SubscriptionConfigM` record without conflicting defaults.


## Integration Points

**`SubscriptionResult` and the FSM transition function (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, `.../Worker.hs`).** Child plan 1 defines `SubscriptionState` and the transition function and keeps `SubscriptionResult` as `Continue | Stop`. Child plan 2 extends `SubscriptionResult` with retry and dead-letter constructors and adds the matching FSM states/transitions. Child plan 1 is responsible for defining the transition function in a way that is exhaustively pattern-matched, so that child plan 2 adding a constructor produces a compile error at every site that must handle it (rather than a silent fallthrough). Child plan 1 must leave a documented extension seam (a single `step :: SubscriptionState -> Input -> (SubscriptionState, Effect)`-style function) that child plan 2 extends; child plan 2 must not fork a parallel state type.

**The `SubscriptionConfigM` record (`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`).** Child plan 2 adds a retry-policy field; child plan 4 adds an event-type-filter field. Both are additive and both must update `defaultSubscriptionConfig` so existing callers (which build configs via the smart constructor) inherit a no-op default — `Continue`-style retry disabled and "no filter / all event types" respectively. There is no ordering constraint between the two additions, but the reconciliation checkpoint must confirm the merged record compiles with both fields and that neither plan removes or renames the fields the other relies on. Each plan is responsible for its own field and its own default; whichever lands second rebases onto the merged record rather than reverting the first.

**Filter-before-delivery ordering (child plan 4 relative to child plan 2).** Child plan 4 applies the event-type filter in the worker *before* the event reaches the handler. Child plan 2 makes the handler path (via the ack-coupled Streamly bridge) able to return retry/dead-letter dispositions. These must compose in one order only: **filter first, then deliver to the (possibly ack-coupled) handler.** A filtered-out event must never reach the bridge, never receive a reply, and never be retried or dead-lettered — the worker simply advances its cursor past it. Child plan 4 is responsible for placing the filter at the point in the FSM delivery transition that precedes the handler effect; child plan 2 must not move disposition handling ahead of the filter. The reconciliation checkpoint verifies this ordering with a test: a filtered-out event type is never delivered even when the handler would dead-letter it.

**The Streamly bridge `Stream.hs` (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`).** Child plan 2 makes it **ack-coupled** (each emitted item carries a one-shot reply variable; the bridge handler blocks until the consumer replies with a `SubscriptionResult`, and only then does the worker checkpoint/retry/dead-letter). Child plan 2 is the sole owner of the bridge item type and defines it as approximately `{ event, attempt, reply }` (names finalized in EP-40's M0). Child plan 3 originally looked like it would need to add **per-member identity** to this item, but its research established that Shibuya's runner does **not** route by an envelope partition key — `Envelope.partition` is only an OpenTelemetry attribute and `Concurrency (Async n)` is unkeyed fan-out (see `shibuya-core/src/Shibuya/Runner/Supervised.hs`). Child plan 3 therefore runs **one Shibuya processor per kiroku consumer-group member**, so member identity rides the `ProcessorId` (`"<name>-member-<m>"`), not the stream item. The reconciliation outcome is: child plan 3 does **not** extend the bridge item; it consumes child plan 2's per-event stream unchanged. The reconciliation checkpoint named in the Dependency Graph is satisfied by confirming, before either plan finalizes, that child plan 3 does not introduce a competing bridge item type and that child plan 2's ack-coupled item is the only one.

**The `kiroku.dead_letters` table (`kiroku-store-migrations/sql-migrations/`).** Child plan 2 defines this table with a `consumer_group_member` column (default 0) so that a dead-letter row is attributable to the member that produced it. Child plan 3 does not modify the schema but relies on dead-letters being per-member when it presents a group through the adapter. Child plan 2 is responsible; child plan 3 consumes.

**The Shibuya adapter config `KirokuAdapterConfig` (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`).** Child plan 2 changes how the adapter's `AckHandle.finalize` maps `AckDecision` to a Kiroku disposition. Child plan 3 changes how the adapter presents a consumer group (the `consumerGroup` field and any new policy field). Child plan 4 adds an event-type-filter field to `KirokuAdapterConfig` (and to the consumer-group config that child plan 3 introduces) that it forwards into the underlying `SubscriptionConfigM`; because filtering happens worker-side before the bridge, child plan 4 needs no change to `Convert.hs` or the ack handle. All three edit `kirokuAdapter`. Child plan 3 owns the config-shape/policy changes, child plan 2 owns the ack-handle changes, child plan 4 owns the filter field. They edit adjacent code in the same function, so the reconciliation checkpoint must confirm all sets of edits compose (the ack handle, the member-aware presentation, and the forwarded filter coexist on the same adapter and `Ingested` value).


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (FSM): M1 — define `SubscriptionState` and an exhaustive transition function; re-express today's catch-up/live/stopped phases as named states with no behavior change. (Done 2026-05-29: `Fsm.hs` + driver refactor of `Worker.runWorker`; `164 examples, 0 failures`; all downstream packages link.)
- [x] EP-1 (FSM): M2 — recoverable backpressure: replace terminal `Overflowed` with a `Paused` state that resumes when the consumer drains (configurable). (Done 2026-05-29: `PauseAndResume` policy + default, publisher `Paused` status, `Paused`→re-catch-up recovery, `Paused`/`Resumed` events; `166 examples, 0 failures`.)
- [x] EP-1 (FSM): M3 — worker-level `Reconnecting` state: a live worker that loses its pool re-enters catch-up from its checkpoint instead of dying. (Done 2026-05-29: Category/consumer-group live loops bubble fetch errors → `Reconnecting` → re-catch-up; `KirokuEventSubscriptionReconnecting`; Category-subscription reconnect test; `167 examples, 0 failures`. AllStreams live is publisher-fed and has no worker fetch — see EP-41 Decision Log.)
- [x] EP-1 (FSM): M4 — observability + tests: expose current state; regression tests for no-missed-events, monotonic checkpoints, pause/resume, reconnect. (Done 2026-05-29: `currentState` handle accessor + state `TVar`; Paused/Resumed/Reconnecting events; arch doc + CHANGELOG updates; `Test/SubscriptionState.hs`; `169 examples, 0 failures`.)
- [ ] EP-2 (retry/DL): M0 — finalize Kiroku-native disposition API, retry policy, dead-letter reason, attempt reporting (rebased onto the FSM).
- [ ] EP-2 (retry/DL): M1 — add retry/dead-letter dispositions as FSM states/transitions in `kiroku-store`.
- [ ] EP-2 (retry/DL): M2 — `kiroku.dead_letters` forward migration + SQL statements.
- [ ] EP-2 (retry/DL): M3 — ack-coupled Streamly bridge + Shibuya adapter `AckRetry`/`AckDeadLetter` mapping.
- [ ] EP-2 (retry/DL): M4 — tests, docs, changelogs across the three packages.
- [ ] EP-3 (partitioning): M1 — map a kiroku `ConsumerGroup` onto Shibuya `Ordering`/`Concurrency`; reject invalid combinations early.
- [ ] EP-3 (partitioning): M2 — adapter presents a whole group as one `PartitionedInOrder` source (member-aware bridge), no manual N-adapter wiring.
- [ ] EP-3 (partitioning): M3 — end-to-end test: a size-N group through the adapter delivers a disjoint, per-stream-ordered partition per member whose union is complete.
- [ ] EP-4 (filtering): M1 — add an event-type-filter field to `SubscriptionConfigM` (default: all types) and apply it in the FSM delivery transition; filtered-out events advance the checkpoint without delivery.
- [ ] EP-4 (filtering): M2 — surface the filter through the Streamly bridge and the Shibuya adapter config (forwarded; no bridge/element-type change).
- [ ] EP-4 (filtering): M3 — tests: a selective subscription delivers only matching types, never stalls on a long run of non-matching events (checkpoint advances), and a filtered-out event is not dead-lettered even when the handler would.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Consumer groups already exist. The partitioning work (child plan 3) was initially scoped as "kiroku uses consumer groups, the Shibuya adapter is not plugged into that yet." Research confirmed kiroku's consumer-group *runtime* shipped under MasterPlan 4 (`docs/masterplans/4-consumer-group-support-for-partitioned-subscriptions.md`); the adapter already passes a `consumerGroup` field through (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`). The remaining gap is purely the **policy reconciliation** between kiroku's static member partitioning and Shibuya's `Ordering`/`Concurrency` model — not building consumer groups. Child plan 3 is scoped accordingly and references MasterPlan 4 as completed prior art rather than re-deriving it.

- EP-1 (FSM) shipped (2026-05-29). The artifacts the other child plans depend on are now in place, with three findings that affect them:
  - **The extension seam EP-2 must use** is `step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])` in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`, compiled `-Werror=incomplete-patterns`. EP-2 adds its retry/dead-letter `SubscriptionResult` constructors and matching `Input` constructors (and a `Retrying` state) **in place** here; the per-event handler result is surfaced to `step` via the driver's `DeliverBatch` interpretation in `Worker.runWorker` (today `processEvents` collapses `Continue`/`Stop` and the driver feeds `HandlerStopped` — EP-2 restructures that delivery point to emit its new inputs). Do not fork a parallel state type.
  - **`SubscriptionStopReason` moved** from `Kiroku.Store.Observability` into `Kiroku.Store.Subscription.Fsm` (re-exported from `Observability`, so the `KirokuEvent` API is unchanged) to keep the module graph acyclic now that `Subscription.Types.SubscriptionHandleM` carries a `currentState :: m SubscriptionState` field. EP-2/EP-4, which also edit `Subscription.Types`, inherit this layout.
  - **The default `OverflowPolicy` is now `PauseAndResume`** (was `DropSubscription`), and `EventPublisher.SubscriberStatus` gained a `Paused` value. EP-4's filter field and EP-2's retry-policy field both land on the same `SubscriptionConfigM`/`defaultSubscriptionConfig`; whichever rebases must preserve the `PauseAndResume` default. The Shibuya adapter already overrides `overflowPolicy = DropSubscription` explicitly, so EP-3 is unaffected by the default change.
  - **Reconnect (`Reconnecting`) applies only to fetching subscriptions** (Category / consumer-group): AllStreams live delivery is publisher-fed and performs no worker fetch. EP-3, which presents a consumer group as one partitioned subscription, gets observable per-member `Reconnecting`/`CatchingUp`/`Live` states for its policy-reconciliation tests (its soft dependency on EP-1).

- Shibuya does not route by partition key, which forces the adapter shape and removes a presumed bridge dependency. Child plan 3's research read `shibuya-core/src/Shibuya/Runner/Supervised.hs` and found that the runner collapses `Concurrency` to a single integer and runs `parMapM` over one inbox: `Async n` is **unkeyed** fan-out with no per-partition affinity, and `Envelope.partition` is used only as an OpenTelemetry attribute. Consequently a single Shibuya processor cannot honor kiroku's per-stream ordering, and the adapter must run **one Shibuya processor per kiroku member** (each member's own processor is `StrictInOrder` + `Serial`; the group is labelled `PartitionedInOrder`). This is why child plan 3 needs no change to the Streamly bridge and why child plan 2 solely owns the ack-coupled bridge item (`{ event, attempt, reply }`). Evidence: `validatePolicy StrictInOrder (Async _)` returns `Left (InvalidPolicyCombo ...)` in `shibuya-core/src/Shibuya/Policy.hs`, and `processUntilDrained`'s `maxConc` handling in `Runner/Supervised.hs`.


## Decision Log

- Decision: Decompose into three child plans (FSM foundation; retry/dead-letter; partitioning), with the FSM first.
  Rationale: Functional-concern split with independent verifiability; sequencing the FSM first prevents implementing disposition handling twice. See Decomposition Strategy.
  Date: 2026-05-29.

- Decision: The subscription-worker FSM is a faithful EventStore-style machine that adds the two missing recoverable states (paused backpressure, live reconnect), not merely a formalization of current behavior.
  Rationale: User direction. These two states close real behavioral gaps (terminal overflow; worker dies on live DB loss) rather than only renaming today's phases.
  Date: 2026-05-29.

- Decision: Adopt existing EP-40 (`docs/plans/40-...`) as child plan 2 in place, rather than superseding it with a fresh plan.
  Rationale: User direction. EP-40 carries substantial validated design work (M0 decision log, ack-coupled-bridge analysis). It is updated to add the MasterPlan parent and to rebase its mechanics onto child plan 1's FSM; nothing is discarded.
  Date: 2026-05-29.

- Decision: Partitioning (child plan 3) is adapter-only with kiroku's static `(member, size)` membership; no dynamic rebalancing and no `shibuya-core` changes.
  Rationale: User direction, consistent with MasterPlan 4's static-membership decision and EP-40's "do not change shibuya-core" decision.
  Date: 2026-05-29.

- Decision: Child plan 2 hard-depends on child plan 1; child plan 3 soft-depends on child plan 1 and integration-depends on child plan 2 via the shared Streamly bridge.
  Rationale: Retry-with-attempts and dead-letter-then-advance are naturally FSM states/transitions; the ack-coupled bridge (EP-40) and the member-aware bridge (EP-3) edit the same item type and must agree. See Dependency Graph and Integration Points.
  Date: 2026-05-29.

- Decision: Add child plan 4 — per-subscription event-type filtering — as an in-memory, worker-side filter applied before delivery, filtering only (no transform/mapper).
  Rationale: User identified type filtering as another missing capability; research confirmed kiroku has none today (no selector field, no SQL type predicate, no bridge filter), while EventStore supports it via an in-memory `selector` that still advances the checkpoint past filtered events. The user chose an in-memory worker-side filter over SQL pushdown to keep the shared `$all` broadcast publisher untouched, and filtering-only over including a mapper because a transform does not affect checkpointing and callers can `fmap` the typed stream downstream.
  Date: 2026-05-29.

- Decision: Child plan 4 soft-depends on child plan 1 and must apply its filter before child plan 2's handler/bridge (filter-then-deliver), and is otherwise independent of child plans 2 and 3.
  Rationale: "Skip but still advance the cursor" is an FSM delivery-transition invariant (cleanest on child plan 1); a filtered-out event must never reach the ack-coupled bridge, so it can never be retried or dead-lettered. See Dependency Graph and Integration Points.
  Date: 2026-05-29.


## Outcomes & Retrospective

Pending. At completion, summarize: the final `SubscriptionState` enumeration and transition table; the pause/resume and reconnect behaviors as shipped; the disposition API and dead-letter schema; the adapter's policy mapping for consumer groups; the event-type-filter API and its checkpoint-advances-past-filtered behavior; and the exact test results across `kiroku-store`, `kiroku-store-migrations`, and `shibuya-kiroku-adapter`.


## Revision Notes

- 2026-05-29 — Initial creation: three child plans (EP-1 FSM, EP-2 retry/dead-letter adopting existing EP-40, EP-3 partitioning).
- 2026-05-29 — Added child plan 4 (`docs/plans/43-...`), per-subscription event-type filtering, after the user identified type filtering as another missing capability. Research confirmed kiroku has no subscription-level filtering today and that EventStore's in-memory `selector` advances the checkpoint past filtered events. Updated Vision & Scope (new outcome bullet; mapper excluded), Decomposition Strategy (three → four work streams), Exec-Plan Registry (row 4), Dependency Graph (EP-4 soft-deps EP-1; filter-before-deliver vs EP-2), Integration Points (shared `SubscriptionConfigM`; filter-before-delivery ordering; adapter config forwarding), Progress (EP-4 milestones), and the Decision Log. Reason: keep all subscription-runtime work coordinated under one MasterPlan so the shared config record, FSM delivery transition, bridge, and adapter changes are reconciled rather than colliding.
