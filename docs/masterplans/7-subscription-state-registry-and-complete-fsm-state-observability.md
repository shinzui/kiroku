---
id: 7
slug: subscription-state-registry-and-complete-fsm-state-observability
title: "Subscription-state registry and complete FSM-state observability"
kind: master-plan
created_at: 2026-05-31T14:50:31Z
intention: "intention_01ksz87dmveheabtpg8kswdgvn"
---

# Subscription-state registry and complete FSM-state observability

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kiroku is a PostgreSQL-backed event store (repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, package `kiroku-store`). A **subscription** is a long-lived worker that reads events in order and feeds them to a handler, remembering progress in a durable checkpoint. Under MasterPlan 6 (`docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md`) the worker became an explicit finite state machine (FSM): at any instant it is in exactly one named state — `CatchingUp`, `Live`, `Paused`, `Reconnecting`, `Retrying`, or `Stopped` (`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`). The worker writes its current state into a per-subscription `TVar SubscriptionState` (`stateVar`, created in `kiroku-store/src/Kiroku/Store/Subscription.hs:112`) and announces every transition as a structured `KirokuEvent` (`kiroku-store/src/Kiroku/Store/Observability.hs`).

Two observability surfaces over that FSM are incomplete, and this initiative closes both.

**1. There is no cheap, aggregate snapshot of every subscription's current state.** Each subscription exposes its own state only through its handle's `currentState :: m SubscriptionState` accessor (`Subscription/Types.hs:351`), which reads that subscription's private `stateVar`. To answer "what is *every* subscription doing right now" an operator would have to hold every handle. There is no single queryable place. That aggregate snapshot is precisely the foundation that **Prometheus** support and an **admin tool** both require: a Prometheus scrape needs to read all subscriptions' states and cursor positions on demand to publish gauges; an admin tool needs to list every subscription with its state, member, and position. The registry also fills a blind spot that traces inherently cannot: an OpenTelemetry span is only exported when it *ends* (verified in `hs-opentelemetry`; see MasterPlan 6 / `docs/plans/44-...`), so an in-progress outage — a worker stuck `Reconnecting` right now — is invisible in traces until it resolves, whereas a registry read shows it instantly.

**2. The OpenTelemetry span tracing does not faithfully capture every FSM state.** MasterPlan 6's EP-44 (`docs/plans/44-...`, `kiroku-otel/src/Kiroku/Otel/Subscription.hs`) turned the `KirokuEvent` stream into spans, but two FSM states are not captured: (a) an **AllStreams (`$all`) subscription's entire `Live` phase emits no per-batch event** — the `(Nothing, AllStreams)` live branch (`Worker.hs:227-242`) returns a batch to the FSM `DeliverBatch` effect, whose handler (`Worker.hs:301-305`) calls `processEvents` and emits nothing, while only the two database-driven live loops emit `KirokuEventSubscriptionFetched` (`Worker.hs:471,523`); so a `$all` subscription's trace is one catch-up span and then silence. (b) A clean **`Stopped`** after going live produces no span: `KirokuEventSubscriptionStopped` is always emitted (`Worker.hs:333,335`), but the tracer only stamps the stop reason onto an *open* episode span, and after catch-up none is open, so the terminal state and reason vanish from traces. EP-44's tests fed *synthetic* `KirokuEvent` sequences (including a `Fetched` event) so they proved the tracer's event→span mapping but never proved a real worker emits the events needed for every state.

After this initiative:

- The `KirokuStore` handle exposes a **subscription-state registry** — a `TVar`-backed map keyed by `(subscription name, member)` that every worker keeps current and that is removed when a worker stops, crashes, or is cancelled. Each registered entry carries a per-worker token plus the worker's existing state cell, so cleanup is conditional: an old worker can remove only its own entry and cannot delete a newer replacement registered under the same `(name, member)`. An operator reads it as one cheap, near-instant snapshot (the outer map snapshotted, then each cell read with `readTVarIO`, so each entry is its freshest value and the reader pays no STM retry cost — see the 2026-05-31 audit) without holding individual subscription handles. The registry is also authoritative for the per-handle read: `currentState` becomes `Maybe SubscriptionState`, resolved through the registry by key **and token**, with `Nothing` meaning "not currently live" or "this handle's worker is no longer the active registry owner for that key." This is the substrate for Prometheus gauges and an admin tool, **and it is the performant way to close the live-state gaps in the OpenTelemetry instrumentation itself** — see the next bullet.

- **The registry is the performant live-state layer of the observability story; spans are the timeline layer.** The two are complementary, and the registry is deliberately the *cheap* path for the OTel gaps that spans handle badly. Episode/transition *timing* (when a state was entered or left, for how long) genuinely needs the `KirokuEvent` transition stream, so the span work (child plan 2) stays event-driven for the timeline. But the parts of the OTel gap that spans handle *poorly or not at all* — "what state is each subscription in **right now**" (the export-on-end blind spot: a span is only exported when it ends, so an in-progress `Reconnecting`/`Paused` worker is invisible in traces until it resolves) and continuous **live progress** (`$all` `Live` throughput) — are served by the registry at **zero per-event cost**. This is performant by construction: the worker *already* writes its state to its `stateVar` on every transition, so the registry adds **no new per-event writes**; it only makes those existing cells queryable, and consumers read snapshots on **their own cadence** (a scrape interval, an admin poll), not on the worker's hot path. By contrast the per-batch delivery spans (child plan 2) are the higher-volume, higher-cost path — and, as recorded in `docs/plans/44-...`'s review, the first telemetry dropped under load. So for "is `$all` Live and advancing," sampling the registry's `(state, cursor position)` is the cheap, always-available signal; the per-batch spans are the correlation/timeline layer on top. A future OTel-metrics reader (deferred) and the Prometheus exporter both read the registry, not the span stream, for live state.
- The OpenTelemetry spans **faithfully capture every FSM state for every target** (`$all`, category, consumer group): catch-up *and* live delivery both produce per-batch spans tagged with the driving state, and a stopped worker always produces a terminal span carrying its stop reason — proven by a **database-backed end-to-end test** that runs a real worker against Postgres with the tracer installed and asserts on the exported spans.

**This is the moment to get the primitives right.** Kiroku has not yet released a stable version, so there is no public-API compatibility to preserve and no deprecation cycle to honor. This initiative therefore introduces the registry and its public state-view type as deliberate, committed **core primitives** rather than minimal back-compatible bolt-ons: child plan 1 may reshape the `KirokuStore` handle and the observability surface freely — for example, making the registry the single source of truth that also backs the per-handle `currentState` — and the new `KirokuEvent` delivery constructor (child plan 2) is a permanent, committed addition to the event API. We design these as stable surface we are willing to commit to, deliberately, now.

**Explicitly out of scope (but motivated and enabled).** The actual **Prometheus exporter** and the **admin tool** are the registry's intended downstream consumers; they are deliberately *not* built here. They are separate future initiatives that will become their own child plans once specified, and metric emission remains consistent with the project-wide OTel-metrics deferral (MasterPlan 5). This MasterPlan delivers the registry abstraction and proves it through its snapshot accessor and tests, not an exporter or UI. Also out of scope: any change to the FSM's *behavior* (states, transitions, checkpointing), dynamic consumer-group rebalancing, and any `shibuya-core` change.


## Decomposition Strategy

The initiative splits into two work streams by functional concern, each independently verifiable, and they can proceed in parallel because neither depends on the other's code.

**Child plan 1 — the subscription-state registry (`docs/plans/45-...`).** A core abstraction: a `TVar`-backed map on the `KirokuStore` handle that every worker keeps current, with a public snapshot accessor. This is the foundation the user identified as critical for Prometheus support and an admin tool, and it is the right primitive for *point-in-time* state queries. Its acceptance is a test that starts several subscriptions (including consumer-group members), reads the snapshot and sees each one's current state and FSM cursor, confirms an entry disappears when a subscription stops, is cancelled, or crashes, and confirms stale cleanup from an overwritten duplicate key cannot delete the newer entry. It is self-contained in `kiroku-store`.

**Child plan 2 — complete FSM-state span coverage (`docs/plans/46-...`).** Completes the OpenTelemetry tracing that MasterPlan 6's EP-44 began. It adds a single centralized delivery `KirokuEvent` emitted by the one delivery primitive (`processEvents`) so that catch-up *and* live delivery on *every* target produce per-batch spans tagged with the driving state (closing the `$all`-`Live` gap), makes the tracer emit a terminal span on `Stopped`, and adds a database-backed end-to-end test that runs a real worker and asserts every FSM state's span appears. Its acceptance is behavioral: spans for catch-up, live, pause, reconnect, retry, and stop all appear for a real `$all` subscription.

The decomposition follows MASTERPLAN.md's principles. The two streams are different **functional concerns**: a queryable *snapshot* of current state versus an event-driven *timeline* of state transitions. They have different **consumers**: Prometheus/admin read the snapshot; tracing backends read the spans. They are **independently verifiable** (a snapshot test versus a span-export test). Their only **shared touchpoint** is the per-worker `stateVar`/`currentState` (see Integration Points), which neither stream changes the write-semantics of, so there is no code dependency between them.

Alternatives considered and rejected: (a) **One combined plan** — rejected because the two mechanisms (snapshot vs. timeline) have independent acceptance and merging them would couple unrelated observability concerns. (b) **Feeding traces from the registry** (poll the state map to build spans) — rejected because spans are *intervals* (start + end + duration) and a polled snapshot cannot reconstruct transition timing without a poller that would miss fast transitions and add latency; traces require the `KirokuEvent` transition stream, which is why child plan 2 stays event-driven. (c) **Building the Prometheus exporter and admin tool now** — rejected because both are gated on the registry, are under-specified, and metric emission is deferred; they become their own child plans once specified, and adding them here would produce non-self-contained plans. (d) **A narrow `$all`-only `Fetched` emission** instead of a centralized delivery event — rejected (see Decision Log) because the centralized event at the single delivery primitive also makes catch-up batch progress traceable and keeps one uniform delivery signal across all targets, mirroring EP-2's "one delivery primitive" decision in MasterPlan 6.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Central subscription-state registry on the store handle for cheap observability | docs/plans/45-central-subscription-state-registry-on-the-store-handle-for-cheap-observability.md | None | None | Complete |
| 2 | Complete OpenTelemetry span coverage of every subscription FSM state | docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

Anticipated future child plans (not yet authored — they will be added once specified, each gated on EP-1's registry): a **Prometheus exporter** that scrapes the registry snapshot into gauges, and an **admin tool** that lists subscriptions and their states. They are named here so the registry is designed to serve them, but they are out of scope for this MasterPlan's current decomposition.


## Dependency Graph

There are **no hard dependencies** between the two child plans, and **no soft dependencies** either: they can be implemented in parallel or in either order. Child plan 1 (registry) adds a field to the `KirokuStore` handle, registration/deregistration in the `subscribe` lifecycle, and a snapshot accessor. Child plan 2 (span coverage) adds a `KirokuEvent` constructor, emits it from `processEvents`, and extends the `kiroku-otel` tracer plus tests. These edit different files for different purposes.

Their one shared touchpoint is the per-worker `stateVar :: TVar SubscriptionState` and the `currentState` accessor (see Integration Points). Child plan 1 *registers* that existing cell into its central map behind a per-worker token and reads it for the snapshot; child plan 2 *reads* it inside `processEvents` to label the new delivery event's phase (catch-up vs. live). Neither changes how or when the worker *writes* `stateVar`. The only coordination needed is the reconciliation note in Integration Points: child plan 1 must keep the per-worker `stateVar` as the worker's write target (registering the cell, not replacing it with a write-through to the map), so child plan 2's read of `stateVar` is undisturbed regardless of landing order.

Recommended order is therefore **either plan first, or both in parallel**. If a single contributor does them sequentially, doing child plan 1 first is marginally preferable only because its registry snapshot is a convenient place to assert state in child plan 2's end-to-end test (the test can cross-check the registry against the spans), but this is an affordance, not a dependency.


## Integration Points

**The per-worker `stateVar :: TVar SubscriptionState` and `currentState` accessor (`kiroku-store/src/Kiroku/Store/Subscription.hs:112,130`; `.../Subscription/Types.hs:351`).** This is the only artifact both plans touch. Today `subscribe` creates one `stateVar` per subscription, the worker writes its FSM state into it on every transition, and the handle's `currentState` reads it. Child plan 1 (registry) **registers that same cell** into a central `TVar (Map (SubscriptionName, member) (Unique, TVar SubscriptionState))` on the store handle (insert on start, conditional delete in the existing `finally` lifecycle only when the stored token matches this worker), and the snapshot accessor snapshots the outer map and reads each inner cell with `readTVarIO` outside STM (per the 2026-05-31 audit — see Decision Log — replacing the original single-transaction design to remove the reader's retry cost). Child plan 1 also reshapes `currentState` to `Maybe SubscriptionState`, resolved through the registry by key and token (`Nothing` ⟺ not currently live or this handle has been superseded by a newer worker for the same key). Child plan 2 (span coverage) **reads `stateVar`** inside `processEvents` (`Worker.hs:602-605` already reads it as `driving`) to label the new delivery event's phase. Responsibility: child plan 1 owns the registry and its lifecycle; child plan 2 only reads `stateVar`. **Reconciliation:** child plan 1 must keep the per-worker `stateVar` as the worker's write target — register the cell, do not replace it with a write-through to the map — so that child plan 2's read of `stateVar` is undisturbed (the worker still writes `stateVar` exactly as before; only the handle's *read path* moves to a registry lookup of that same cell). With that constraint the two plans compose with no ordering requirement.

**The `KirokuStore` handle record (`kiroku-store/src/Kiroku/Store.hs` and the store-construction site).** Child plan 1 adds one field (the registry `TVar`) and a public snapshot accessor; it must initialize the field where the store is constructed and thread it into `subscribe`. Child plan 2 does not touch the handle. Child plan 1 is solely responsible.

**The `KirokuEvent` type (`kiroku-store/src/Kiroku/Store/Observability.hs`).** Child plan 2 adds one additive constructor (the per-batch delivery event) plus a small phase enum; the constructor set is documented as additive, so the new constructor surfaces at every exhaustive match site (including the `kiroku-otel` tracer) as a `-Wincomplete-patterns` warning rather than a silent miss. Child plan 1 does not touch `KirokuEvent`. Child plan 2 is solely responsible.

**The `subscribe`/`withSubscription` lifecycle (`kiroku-store/src/Kiroku/Store/Subscription.hs:95-156`).** Child plan 1 adds registry register/deregister around the existing `finally unsubscribe` (which already removes the subscriber from the *publisher's* registry on any exit — the exact pattern and place to mirror). Child plan 2 does not touch this function. Child plan 1 is solely responsible.

**`Worker.hs` is lightly co-edited in non-conflicting regions.** Child plan 1 adds `configMember` to the module's export list (it already exists in the module; the registry uses it to derive the `Int32` member for the key). Child plan 2 edits the body of `processEvents` to emit the new per-batch delivery `KirokuEvent`. These are different regions of the same file (export list vs. one function body) with no semantic overlap; whichever lands second rebases trivially. Neither changes the other's surface.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (registry): M1 (2026-05-31) — added the registry `TVar (Map (SubscriptionName, member) (Unique, TVar SubscriptionState))` to the `KirokuStore` handle; register on `subscribe` with a fresh token and deregister conditionally in the existing `finally` lifecycle only when the token still matches (covering stop, cancel, crash, and stale duplicate-key cleanup).
- [x] EP-1 (registry): M2 (2026-05-31) — public snapshot accessor returning a near-instant view (name, member, state, FSM cursor position) by snapshotting the outer map and reading each cell with `readTVarIO` (no large STM read set; per the audit); reshaped `currentState` to `Maybe SubscriptionState` resolved via the registry by key and token (`Nothing` ⟺ not live or superseded); `SubscriptionStateView` derives `Generic` for `^. #field` access.
- [x] EP-1 (registry): M3 (2026-05-31) — tests: started several subscriptions incl. consumer-group members, asserted the snapshot reflects their states/positions, and asserted entries are removed on stop / cancel / crash plus stale duplicate-key cleanup safety; docs + CHANGELOG. Full suite green (183 examples, 0 failures); `cabal build all` clean.
- [ ] EP-2 (span coverage): M1 — add the additive per-batch delivery `KirokuEvent` (with a catch-up/live phase) and emit it once per batch from the single delivery primitive `processEvents`, for every target.
- [ ] EP-2 (span coverage): M2 — tracer: open/close a per-batch `deliver` span tagged with the driving state (replacing the `Fetched`-keyed span to avoid double-emit), and emit a terminal `stopped` span on `KirokuEventSubscriptionStopped` even when no episode is open.
- [ ] EP-2 (span coverage): M3 — database-backed end-to-end test: run a real `$all` worker with the tracer + in-memory exporter through catch-up → live → stop and assert each FSM state's span appears; update synthetic tests, docs, CHANGELOG.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

**2026-05-31 — EP-1 implemented and complete; the Integration Point held exactly
as designed.** Implementing EP-1 (`docs/plans/45-...`) confirmed the central
coordination assumption: the worker's per-worker `stateVar` remained the sole
write target (the registry *registers* that cell, it does not write-through), so
EP-2's planned read of `stateVar` inside `processEvents` is undisturbed
regardless of landing order. No code dependency between the plans materialized.
The only in-repo caller of the reshaped `currentState` was
`kiroku-store/test/Test/SubscriptionState.hs` (as predicted); `cabal build all`
is clean across `kiroku-otel` and `shibuya-kiroku-adapter`, so the
`m (Maybe SubscriptionState)` reshape and the new `subscriptionRegistry` handle
field did not ripple beyond `kiroku-store`. EP-2 can proceed independently.

**2026-05-31 — Affordance for EP-2's e2e test confirmed available.** EP-1 ships
`subscriptionStates store` returning `Map (SubscriptionName, Int32) SubscriptionStateView`
with a stable `statePhase` label; EP-2's database-backed end-to-end test may, if
convenient, cross-check the registry snapshot against the exported spans (e.g.
assert the `$all` worker is `"live"` in the registry while asserting its
deliver spans appear). This is an affordance, not a dependency.

**2026-05-31 — Worker cancellation during catch-up is not prompt (test-shaping
note, not a defect).** EP-1's registry test found that `cancel`ling a worker
still in its catch-up startup window (empty store, no events) does not
deregister within a 5 s budget, whereas a worker driven to `Live` first
deregisters immediately. The registry cleanup itself is correct (it runs in the
worker's `finally` on any exit); the latency is in `Async.cancel` delivery to a
mid-catch-up worker. Any future test (including EP-2's) that asserts on
deregistration/stop *timing* should drive the worker to `Live` before
stopping/cancelling it.

**2026-05-31 — Pre-commitment API/perf/deadlock audit (before committing the core primitives).**
Audited both child plans against the live code. No deadlock found; several API and
performance issues surfaced. Evidence and conclusions:

- *No deadlock.* The registry is pure STM with no `retry`/`check` (insert, delete, and the
  snapshot are non-blocking `atomically` blocks), so it is optimistic and cannot deadlock.
  The tracer (EP-2) uses a single `MVar (Map SpanKey OpenState)` with non-nested
  `withMVar`/`modifyMVar_` and all span IO outside the lock
  (`kiroku-otel/src/Kiroku/Otel/Subscription.hs:320-336`); `emit` is never called inside an
  STM transaction (`Worker.hs:602-606`). No lock-ordering inversion exists.

- *Snapshot read-set retry cost (EP-1, performance).* `subscriptionStates` reads the outer
  map and every inner `stateVar` in one `atomically` (EP-1 M2). Workers write `stateVar` on
  every loop iteration — ~once per batch (`Worker.hs:183`, plus retry flips at
  `Worker.hs:652,655`). GHC STM re-validates a transaction's entire read set at commit, so any
  of N workers committing a state write while the snapshot scans forces the whole snapshot to
  re-run; the cost scales with N × write-rate and lands entirely on the reader. The
  MasterPlan's "zero per-event cost" claim holds only for the workers (STM writers never block
  on readers) — it never accounted for the reader side. The point-in-time consistency this buys
  is not required by the named consumers (a scrape / admin listing reads independent
  gauges/rows). Candidate fix: read the outer map with `readTVarIO`, then `readTVarIO` each cell
  outside STM (O(N), no large read set). Pending decision (see Decision Log).

- *`currentState` "single source of truth reshape" is fictional (EP-1, API honesty).* EP-1 M2
  instructs *"Keep `currentState = readTVarIO stateVar`"* — nothing changes but a Haddock note —
  yet EP-1's Purpose/Decision Log/CHANGELOG describe a "deliberate, possibly breaking reshape"
  making the registry back `currentState`. There is no behavior change and the registry does
  not back `currentState`; both close over the same cell independently. Routing `currentState`
  through the registry would be harmful: deregistration deletes the key in `finally`, so a held
  handle's `currentState` would stop finding its cell after exit. Pending decision.

- *`SubscriptionStateView` is not consumable as specified (EP-1, API correctness).* The package
  enables `DuplicateRecordFields` + `OverloadedLabels` (not `OverloadedRecordDot`), and the
  field names `member` / `subscriptionName` already exist on other records
  (`Types.hs:366,227`), so the view's bare selectors are ambiguous; and the standard accessor
  `view ^. #field` requires `Generic`, which the view (deriving only `Show`) does not derive.
  Fix: `deriving stock (Show, Generic)` and consume via `^. #field` (matches the whole
  codebase). Clear fix, applied in the cascade.

- *Neither the registry nor `currentState` can observe `Stopped` (EP-1/EP-2, semantics).* The
  FSM writes `stateVar` only at the top of `loop` (`Worker.hs:183`) and the terminal transition
  returns from `feed` without looping (`Worker.hs:197-198`), so `Stopped` is never written into
  `stateVar`. Hence `statePhase == "stopped"` is unreachable and `currentState` after a clean
  stop returns the pre-stop state. This reinforces the complementary split (Stopped lives in
  EP-2's event/span stream) but must be a documented invariant: for the registry, "stopped" =
  key absent.

- *EP-2 moves per-batch tracer work onto the catch-up hot path (performance).* The centralized
  `Delivered` emit fires once per catch-up batch on every target; with a tracer installed each
  becomes 2 ops on the shared tracer MVar + `createSpan`/`endSpan`. The "first dropped under
  load" note concerns export volume, not emission, which still runs on the hot path regardless
  of sampling. **Resolved: keep catch-up deliver spans and fold in C2** (EP-2 M2 Edit 7) —
  stripe the tracer's per-key span state into a lock-free `IORef (Map SpanKey (IORef
  OpenState))` so the per-batch path never serializes workers on one lock. This removes both
  the new catch-up contention and the pre-existing DB-driven-live-loop contention; it is
  `base`-only, internal, and behavior-identical. (Per-batch span *allocation* remains, by
  design — it is dominated by the per-batch checkpoint write `processEvents` already does.)

- *Minor.* The view duplicates the map key (`subscriptionName`/`member`); and `subscribe`
  inserts before `Async.async` with cleanup in the thread's `finally`, a narrow leak window on
  an async exception during `subscribe` itself — but this exactly mirrors the pre-existing
  `unsubscribe` window (`Subscription.hs:103-124`), so it is consistent and low-priority.

**2026-05-31 — hs-opentelemetry 1.0.0.0 upgrade-impact review (does the post-initiative upgrade
threaten this work, and should it be reordered before it?).** Audited the planned upgrade
(`hs-opentelemetry-api` `0.3` → `1.0.0.0`, the version already vendored in the corpus at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`, api/sdk/in-memory/w3c all
`1.0.0.0`) against the exact API surface EP-2 touches. **Conclusion: the upgrade does not
significantly affect this MasterPlan; no reordering is required.** Evidence:

- *EP-1 (registry) has zero OTel surface.* `kiroku-store` declares no `hs-opentelemetry`
  dependency (`grep` over `kiroku-store/*.cabal` returns nothing); the registry is pure
  `kiroku-store` STM. The upgrade is entirely orthogonal to EP-1.

- *Every function/type EP-2's tracer uses exists in 1.0.0.0 with an unchanged signature.* Verified
  in the 1.0.0.0 source: `createSpan`, `endSpan`, `addAttribute`, `addEvent`, `setStatus`,
  `defaultSpanArguments`, `Span`, `Tracer`, `SpanStatus(..)`, `NewEvent(..)` with
  `newEventAttributes :: AttributeMap` where `type AttributeMap = HashMap Text Attribute`
  (so the tracer's `HashMap.fromList attrs` still typechecks), `Context.empty`, and
  `OpenTelemetry.Attributes (Attribute, ToAttribute(toAttribute))` — the latter now physically
  lives in the split-out `hs-opentelemetry-api-types` package but is still re-exported by
  `hs-opentelemetry-api` (which depends on `==1.0.*` of api-types), so `kiroku-otel`'s import path
  is undisturbed and no new direct dependency is needed.

- *EP-2's new DB-backed e2e test scaffolding is API-stable.* The existing in-memory-exporter setup
  it mirrors (`kiroku-otel/test/Main.hs:53-63,284-288`: `inMemoryListExporter`,
  `createTracerProvider [processor] emptyTracerProviderOptions`, `makeTracer tp _ tracerOptions`,
  `forceFlushTracerProvider`) is present unchanged in 1.0.0.0 (`createTracerProvider :: [SpanProcessor]
  -> TracerProviderOptions -> m TracerProvider`; `inMemoryListExporter :: m (SpanProcessor, IORef
  [ImmutableSpan])`). The unified-SDK-init additions (`withOpenTelemetry`, `OTelSignals`) are
  *additive*; the low-level constructors EP-2 uses are not removed.

- *The 1.0.0.0 behavioral changes that intersect EP-2 are improvements, not breakages, and force
  no design change.* (a) `setStatus` merge semantics were fixed from `max`-on-`Ord` to an explicit
  `mergeStatus` (Ok-final, Unset-ignored, else last-writer-wins); the tracer's only `setStatus`
  uses are `Ok` on success and `Error` on dead-letter, which yield the same observable result under
  both rules, and EP-2's terminal `stopped` span is unaffected. (b) Span-lifecycle enforcement now
  silently skips mutations after `endSpan`; the tracer already orders set-attrs-before-close, and
  EP-2's new deliver/stopped spans follow the same discipline, so this only makes the code more
  robust. (c) The `addAttributes` left-biased-union bug was fixed (new values now win); the tracer
  deliberately uses singular `addAttribute` to dodge exactly that bug (`Subscription.hs:345-351`),
  so post-upgrade that workaround's *rationale* is stale (an optional doc cleanup EP-2 may fold in)
  but nothing breaks. (d) All span mutations are now `atomicModifyIORef'`; the tracer's
  single-writer-per-key `MVar` invariant already avoided the race, so this is free safety.

- *The only mechanical change is the cabal bound.* `kiroku-otel/kiroku-otel.cabal:50-51` pins
  `hs-opentelemetry-api >=0.3 && <0.4` (and `propagator-w3c >=0.1 && <0.2`); the upgrade is a
  version-bound bump plus a clean build, independent of EP-2's code. (Note for the upgrade itself,
  not this plan: `shibuya-kiroku-adapter` carries the same `api >=0.3 && <0.4` bound, and the
  broader 1.0.0.0 has real breaking changes — `propagatorNames`→`propagatorFields`, `TracerOptions`
  newtype→data, `CustomSampler` arity — but none touch `kiroku-otel`: its only propagator use is the
  pure `encode`/`decodeSpanContext` from `OpenTelemetry.Propagator.W3CTraceContext`, both present
  unchanged in w3c `1.0.0.0`.)

**2026-05-31 — Final pre-implementation API/lifecycle audit.**
Re-audited the MasterPlan and both child ExecPlans before implementation. Two additional
API/lifecycle issues were found and cascaded into EP-1:

- *Duplicate-key stale cleanup bug (EP-1, correctness).* The registry originally stored only
  `Map (SubscriptionName, member) (TVar SubscriptionState)` and deleted with unconditional
  `Map.delete key` in the worker's `finally`. If two workers with the same `(name, member)`
  accidentally run at once, the second overwrites the first, but the first worker's later
  cleanup would delete the second worker's live entry. A held handle for the first worker
  could also read the second worker's state because `currentState` was key-only. This is a
  correctness bug, not merely the already-documented checkpoint-collision limitation. Fix:
  store a fresh `Data.Unique.Unique` token with each registered cell, make cleanup delete
  only when the stored token matches this worker, and make `currentState` return `Nothing`
  when the key exists but the token does not match the handle's token.

- *`checkpoint` field name was too strong (EP-1, API honesty).* `SubscriptionStateView`
  planned to expose `checkpoint = stateCursor st`. That value is the FSM state's cursor, not
  a guaranteed durable database checkpoint. In particular, while `Retrying` is visible the
  cursor is the retried event position, and during long in-flight batches the durable
  checkpoint may still be the pre-batch position. The registry still provides the cheap
  progress signal needed by Prometheus/admin/OTel live-state consumers, but the public field
  should be named `cursor` and documented as the worker FSM cursor. Consumers that need an
  exact durable checkpoint can query the checkpoint table or a future dedicated checkpoint
  view.

- *Documentation blast radius (EP-1 and EP-2).* The `currentState` reshape and span-name
  change affect user and architecture docs beyond tests and CHANGELOG entries. EP-1 now
  explicitly updates the current-state docs (`docs/user/subscriptions.md`,
  `docs/user/observability.md`, `docs/guides/consuming-the-event-log.md`,
  `docs/guides/building-a-projection.md`, `docs/architecture/subscriptions.md`,
  `docs/user/consumer-groups.md`). EP-2 already updates `docs/user/opentelemetry.md`; it
  also needs `docs/user/observability.md` and `kiroku-otel/CHANGELOG.md` to stop presenting
  `kiroku.subscription.fetch` as the traced per-batch span.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Decompose into two parallel child plans — a subscription-state registry (EP-1) and complete FSM-state span coverage (EP-2).
  Rationale: They are different functional concerns (a queryable snapshot vs. an event-driven timeline) with different consumers and independent acceptance, and they share only the read of the per-worker `stateVar`. See Decomposition Strategy.
  Date: 2026-05-31.

- Decision: Build the registry now as a core abstraction; treat the Prometheus exporter and the admin tool as named future consumers, not part of this MasterPlan.
  Rationale: User direction — the registry "is going to be very important for adding Prometheus support and an admin tool." Those consumers are gated on the registry and are under-specified; metric emission is deferred (MasterPlan 5). Building the foundation now (with a snapshot accessor + tests) lets them be added later as self-contained child plans without re-deriving the registry.
  Date: 2026-05-31.

- Decision: The span-coverage fixes consume the `KirokuEvent` transition stream, not the registry.
  Rationale: Spans are intervals (start + end + duration); a polled state snapshot cannot reconstruct transition timing without a poller that misses fast transitions and adds latency. The registry serves point-in-time queries; tracing needs the event stream. This is also why the two plans have no code dependency.
  Date: 2026-05-31.

- Decision: Close the `$all`-`Live` tracing gap with a single centralized per-batch delivery `KirokuEvent` emitted by `processEvents` for every target, rather than a narrow `$all`-only `Fetched` emission.
  Rationale: User selection ("Centralized delivery event"). The single delivery primitive `processEvents` is the one place every target (catch-up and `$all` live) delivers, so emitting there uniformly captures live delivery for `$all` *and* makes catch-up batch progress traceable, with one delivery signal across all targets — mirroring EP-2's "one delivery primitive" decision in MasterPlan 6. The tracer switches its per-batch span to key on this delivery event (replacing the `Fetched`-keyed span) to avoid double-emitting for the database-driven live loops, which still emit `Fetched`.
  Date: 2026-05-31.

- Decision: Position the registry as the performant live-state layer that closes the OpenTelemetry instrumentation's current-state and live-progress gaps — complementary to, not replaced by, the event-driven spans.
  Rationale: User direction — the registry should also support the OTel gaps in a performant way. Episode/transition *timing* needs the `KirokuEvent` stream (a snapshot can't reconstruct it), so spans remain the timeline layer. But "what state is it in right now" (the export-on-end blind spot) and continuous live progress are served by the registry at **zero per-event cost**: it reuses the worker's existing per-transition `stateVar` writes (no new writes) and is read on the consumer's own cadence. Per-batch deliver spans are the higher-cost timeline/correlation layer and the first telemetry dropped under load (per `docs/plans/44-...`'s review), so the registry is the cheap, always-available state/progress signal. A future OTel-metrics reader and the Prometheus exporter read the registry for live state and the span stream for the timeline.
  Date: 2026-05-31.

- Decision: Introduce the registry and a public subscription-state view type as first-class core primitives now, accepting API reshaping, because kiroku has not released a stable version.
  Rationale: User direction — pre-1.0 is the right time to add core primitives without deprecation cycles or back-compat constraints. EP-1 may reshape the `KirokuStore` handle and observability surface freely (a committed public snapshot/view type; the registry as the single source of truth that also backs `currentState`) to get the primitive right, rather than a minimal back-compat-preserving bolt-on. The `KirokuEvent` delivery constructor (EP-2) is likewise a permanent, committed addition to the event API. These are treated as stable surface designed deliberately now.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): The registry snapshot reads each cell with `readTVarIO` (outer map snapshot + per-cell read **outside** STM), not one `atomically` over all cells.
  Rationale: The audit found the single-transaction design gives the reader an unbounded retry cost — its read set is every subscription's `stateVar`, and any worker's per-batch state write (`Worker.hs:183`) invalidates the whole scan, so cost scales with subscription count × write-rate and lands entirely on the reader. The MasterPlan's "zero per-event cost" holds only for workers (STM writers never block readers). The named consumers (Prometheus scrape, admin listing) read independent gauges/rows and do not need a globally point-in-time-consistent snapshot, so per-cell `readTVarIO` (O(N), no large read set, no retries; each entry its freshest value) is the correct trade. EP-1's snapshot accessor and its "single STM transaction" decision are updated to match.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): `currentState` becomes `m (Maybe SubscriptionState)`, resolved by looking the worker's cell up in the registry by `(name, member)` and this handle's registry token; `Nothing` means "not currently live" or "superseded."
  Rationale: The audit found EP-1's "single source of truth reshape" of `currentState` was fictional — the instruction kept `currentState = readTVarIO stateVar` unchanged while the CHANGELOG claimed a breaking reshape. The genuinely-correct primitive routes the per-handle read through the registry and returns `Maybe`: `Just s` while the worker is live and still owns the registry entry, `Nothing` after stop/cancel/crash (the key is deleted in the worker's `finally`), before start, or after a newer worker supersedes the same key. This makes the registry actually authoritative, makes the breaking CHANGELOG entry true, and unifies the rule "stopped = absent" across `currentState` and the snapshot. It resolves the related finding that the FSM never writes `Stopped` into `stateVar` (terminal transition skips the write at `Worker.hs:197-198`), so the old `currentState` returned a stale pre-stop state forever; `Maybe`/`Nothing` is honest. Blast radius includes `kiroku-store/test/Test/SubscriptionState.hs` and the user/architecture docs that mention the old non-`Maybe` accessor.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Guard each registry entry with a fresh `Data.Unique.Unique` token and make cleanup/currentState token-aware.
  Rationale: A key-only registry makes duplicate `(subscription name, member)` workers worse than the pre-existing checkpoint collision: the older worker's `finally` can delete a newer worker's live registry entry, and the older handle can read the newer worker's state. A fresh token keeps the public map keyed by `(name, member)` while making ownership explicit. Insert stores `(token, stateVar)`. Cleanup deletes only if the current entry still has that token. The held handle's `currentState` reads only if the key's token still matches; if another worker superseded it, the old handle returns `Nothing`. Duplicate workers are still unsupported as a workload shape, but stale cleanup can no longer corrupt the active registry entry.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Rename `SubscriptionStateView.checkpoint` to `cursor` and document it as the worker FSM cursor, not the exact durable checkpoint.
  Rationale: The planned `checkpoint = stateCursor st` field overstated what the registry can know without a database read or an additional checkpoint tracker. `stateCursor` is the FSM cursor: it is excellent for cheap live progress and state inspection, but it is not always the durable checkpoint row, especially while retrying or while a long batch is in flight. Naming the field `cursor` makes the API honest for first release while preserving the future Prometheus/admin use case. Exact durable checkpoint reads can be added later as a separate accessor if needed.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Treat the currentState/span API changes as documentation-wide public-surface changes, not just test and changelog edits.
  Rationale: `currentState` appears in user guides, architecture docs, observability docs, and projection guides; `kiroku.subscription.fetch` appears in OTel and observability docs. Because this is the last major pre-release API change, the plans must update those docs during implementation so first-version users see the committed API shape (`Maybe SubscriptionState`, registry snapshot, `cursor`, `kiroku.subscription.deliver`, and `kiroku.subscription.stopped`) consistently.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): `SubscriptionStateView` derives `Generic` and is consumed via generic-lens `^. #field`; the audit's other small fixes are folded in.
  Rationale: The package enables `DuplicateRecordFields` + `OverloadedLabels` but not `OverloadedRecordDot`, and the field names `member`/`subscriptionName` already exist on other records (`Types.hs:366,227`), so the view's bare selectors are ambiguous and `^. #field` requires `Generic` — which EP-1's `deriving stock (Show)` omitted. Deriving `Generic` matches the codebase convention (`KirokuStore`, `settings ^. #…`). Also folded in: the "stopped = absent" invariant is documented on both `currentState` and `subscriptionStates`; and the insert-before-fork / cleanup-in-`finally` leak window is named as mirroring the pre-existing `unsubscribe` window (`Subscription.hs:103-124`).
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): EP-2 keeps emitting the per-batch delivery event during catch-up (centralized, every target) **and folds in C2** — striping the tracer's per-key span state into a lock-free `IORef (Map SpanKey (IORef OpenState))` — to remove the resulting contention structurally rather than merely accept it.
  Rationale: The audit noted the centralized `Delivered` emit puts per-batch span work on the catch-up hot path whenever a tracer is installed, and — because the tracer used one shared `MVar` — would serialize all workers on that single lock once per batch. Rather than drop catch-up spans (the cheaper-but-lossy lever), the user chose to keep them and fix the root: C2 gives each `SpanKey` its own single-writer `IORef OpenState` behind a read-mostly outer registry mutated only on `Started`/`Stopped`, so the per-batch path is lock-free and contention-free. C2 also fixes the *pre-existing* contention on the DB-driven live loops. It is `base`-only (no new dependency, no cabal change), internal (no public API change, no `kiroku-store` change), and behavior-identical (the nine `onEvent` arms and all span output are unchanged), so it ships green against the existing tests. Considered and rejected: C1 (per-subscription trace handler) needs a new injection point in `kiroku-store`'s API; C2 makes it unnecessary. EP-2 M2 gains "Edit 7 — striped per-key span state" for this.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): The audit confirmed there is **no deadlock** in either plan; recorded so the core primitives can be committed.
  Rationale: The registry is pure STM with no `retry`/`check` (optimistic, lock-free); the tracer uses a single non-nested `MVar` with all span IO outside the lock and a single-writer-per-key invariant; `emit` never runs inside an STM transaction. No lock-ordering inversion exists. Evidence in Surprises & Discoveries (2026-05-31 audit entry).
  Date: 2026-05-31.

- Decision (2026-05-31): Do **not** reorder the hs-opentelemetry `0.3` → `1.0.0.0` upgrade before this initiative; keep the upgrade as a follow-on after the plan lands.
  Rationale: User asked to confirm the post-initiative upgrade "does not significantly affect this work" before committing, and to reorder (upgrade first) only if it does. The 2026-05-31 upgrade-impact review (see Surprises & Discoveries) found it does not: EP-1 has no OTel surface at all (`kiroku-store` declares no `hs-opentelemetry` dependency); every API EP-2's tracer and e2e test use (`createSpan`/`endSpan`/`addAttribute`/`addEvent`/`setStatus`/`defaultSpanArguments`/`NewEvent`/`SpanStatus`/`Context.empty`/`OpenTelemetry.Attributes`/`inMemoryListExporter`/`createTracerProvider`/`makeTracer`/`forceFlushTracerProvider`) exists in `1.0.0.0` with an unchanged signature; and the intersecting behavioral changes (`setStatus` merge fix, post-`endSpan` mutation enforcement, the `addAttributes` overwrite fix, atomic span mutations) are improvements that force no design change. The upgrade reduces to a cabal-bound bump (`kiroku-otel.cabal:50-51`) plus a clean build. EP-2 may optionally fold in one doc cleanup post-upgrade: the `setAttrs` comment (`Subscription.hs:345-351`) justifying singular `addAttribute` over bulk `addAttributes` becomes stale once the `addAttributes` left-bias bug is fixed in `1.0.0.0`. Order remains "either plan first, or both in parallel," with the upgrade afterward.
  Date: 2026-05-31.

- Decision: This initiative grew out of MasterPlan 6 / EP-44; EP-2 here completes the span coverage EP-44 began.
  Rationale: EP-44 shipped the `KirokuEvent`→span tracer but its tests used synthetic event sequences and so masked that a real `$all` worker emits nothing in `Live` and that a clean `Stopped` produces no span. EP-2 fixes the worker's event emission and the tracer, and adds the database-backed end-to-end test that would have caught the gaps. EP-44 / MasterPlan 6 are referenced rather than reopened.
  Date: 2026-05-31.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-05-31 — Pre-commitment audit of the core API, performance, and deadlock safety (user
  request: "audit the plan before we commit to a core API, ensure no performance problems or
  deadlocks we overlooked"). Findings and evidence are in Surprises & Discoveries; the resulting
  decisions are in the Decision Log (five new 2026-05-31 "audit" entries). Outcome: **no
  deadlock** (recorded). Five corrective decisions, confirmed with the user, were cascaded into
  EP-1 (`docs/plans/45-...`) and noted in EP-2 (`docs/plans/46-...`): (1) the snapshot reads each
  cell with `readTVarIO` outside STM instead of one transaction over all cells, removing the
  reader's read-set retry cost; (2) `currentState` becomes `m (Maybe SubscriptionState)` resolved
  through the registry by key (`Nothing` ⟺ not currently live), making the registry genuinely
  authoritative and the previously-fictional "breaking reshape" real and honest; (3)
  `SubscriptionStateView` derives `Generic` so it is consumable via the codebase's `^. #field`
  convention; (4) the "stopped = absent" invariant (the FSM never writes `Stopped` into
  `stateVar`) is documented on both `currentState` and the snapshot; (5) EP-2 keeps catch-up
  deliver spans **and folds in C2** — striping the tracer's per-key span state into a lock-free
  `IORef (Map SpanKey (IORef OpenState))` (EP-2 M2 Edit 7) so the now-per-batch span work never
  serializes workers on one lock, fixing both the new catch-up contention and the pre-existing
  DB-driven-live-loop contention (`base`-only, internal, behavior-identical). The
  duplicate-key workload limitation is unchanged, but a later final audit adds token ownership
  so stale cleanup cannot delete a newer replacement entry.
  Reflected across Vision & Scope, Decomposition is unaffected, Integration Points, Dependency
  Graph (the reconciliation note), Progress (EP-1 M2), Surprises & Discoveries, and Decision Log;
  EP-1 and EP-2 updated in cascade with matching Decision Log entries and revision notes.

- 2026-05-31 — hs-opentelemetry 1.0.0.0 upgrade-impact review (user request: confirm the
  post-initiative `0.3` → `1.0.0.0` upgrade "does not significantly affect this work," and reorder
  the upgrade *before* the plan only if it does). Audited the 1.0.0.0 source already vendored in the
  corpus against EP-2's exact API surface. **Outcome: no significant impact; no reordering.** EP-1
  is OTel-free; every tracer and e2e-test API EP-2 uses is present in 1.0.0.0 with an unchanged
  signature; the intersecting behavioral changes (`setStatus` merge fix, post-end mutation
  enforcement, `addAttributes` overwrite fix, atomic mutations) are improvements requiring no design
  change; the upgrade reduces to a cabal-bound bump plus a clean build. Recorded as a Surprises &
  Discoveries entry (evidence) and a Decision Log entry (the no-reorder decision). No change to the
  decomposition, dependency graph, integration points, or child plans; EP-2 carries one optional
  post-upgrade doc cleanup (the now-stale `addAttributes`-avoidance comment in `setAttrs`).

- 2026-05-31 — Final pre-implementation audit before first-release API commitment. Found and
  cascaded two EP-1 API/lifecycle corrections plus a docs blast-radius correction: (1) the registry
  now stores `(Unique, TVar SubscriptionState)` so cleanup is token-conditional and an old handle
  returns `Nothing` if superseded, preventing stale duplicate-key cleanup from deleting a newer live
  entry; (2) `SubscriptionStateView.checkpoint` is renamed to `cursor` because `stateCursor` is the
  FSM cursor, not always the durable checkpoint row; (3) EP-1 and EP-2 now explicitly update all
  user/architecture docs touched by `currentState`, registry, and span-name changes, not only tests
  and changelogs. Reflected across Vision & Scope, Dependency Graph, Integration Points, Progress,
  Surprises & Discoveries, Decision Log, and child plans 45/46.
