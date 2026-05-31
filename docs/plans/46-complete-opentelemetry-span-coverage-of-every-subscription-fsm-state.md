---
id: 46
slug: complete-opentelemetry-span-coverage-of-every-subscription-fsm-state
title: "Complete OpenTelemetry span coverage of every subscription FSM state"
kind: exec-plan
created_at: 2026-05-31T14:50:41Z
intention: "intention_01ksz87dmveheabtpg8kswdgvn"
master_plan: "docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md"
---

# Complete OpenTelemetry span coverage of every subscription FSM state

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store (repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, package `kiroku-store`). A *subscription* is a long-lived worker that reads events in order, hands each one to a handler, and remembers its progress in a durable *checkpoint*. The worker is an explicit *finite state machine* (FSM): at any instant it is in exactly one named *state* — `CatchingUp`, `Live`, `Paused`, `Reconnecting`, `Retrying`, or `Stopped` (defined in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`). It announces every transition as a structured *operational event* of type `KirokuEvent` (defined in `kiroku-store/src/Kiroku/Store/Observability.hs`), delivered synchronously to an optional callback an operator installs (`eventHandler :: Maybe (KirokuEvent -> IO ())`).

A sister package, `kiroku-otel`, can turn that event stream into *OpenTelemetry spans*. "OpenTelemetry" (OTel) is a vendor-neutral telemetry standard; its core tracing concept is the *span* — one timed operation with a name, a start and end time, key/value *attributes* (tags such as `kiroku.subscription.name = "orders"`), and timestamped *span events* (notes inside the span). Spans appear as horizontal bars on a timeline in tools like Jaeger or Honeycomb. The module `kiroku-otel/src/Kiroku/Otel/Subscription.hs` already builds an `eventHandler` (via `subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())`) that maps the FSM transitions to spans.

**The problem this plan solves.** Two FSM states are not faithfully captured in spans today, so an operator's trace of a real subscription has holes:

1. **An `$all` (AllStreams) subscription's entire `Live` phase emits no per-batch event, so it produces no live spans.** For a non-grouped `$all` subscription, the live branch in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:226-242` is `(Nothing, AllStreams)`: it reads the publisher's bounded queue and returns `BatchFetched fresh`, which the pure FSM (`Kiroku.Store.Subscription.Fsm`) turns into a `DeliverBatch` effect. The `DeliverBatch` effect handler at `Worker.hs:301-305` calls `processEvents` and emits **nothing**. Only the two *database-driven* live loops emit `KirokuEventSubscriptionFetched` — `liveLoopCategoryNotify` at `Worker.hs:471` and `liveLoopDbDriven` at `Worker.hs:523`. So a `$all` subscription's trace shows one catch-up span and then **silence** for the entire time it is live, which is most of its life.

2. **A clean `Stopped` after going live produces no span.** `KirokuEventSubscriptionStopped` is *always* emitted when the worker exits (`Worker.hs:333` for a clean stop, `Worker.hs:335` for a crash/cancel). But the tracer's `Stopped` handler (`kiroku-otel/src/Kiroku/Otel/Subscription.hs:286-298`) only *stamps* the stop reason onto an already-open episode span (`primaryEpisode`) and then closes whatever is open. After catch-up there is no open episode span, so for a healthy worker that catches up, runs live, and stops, the terminal state and its stop reason **vanish** from the trace.

**After this change.** The OTel spans faithfully capture *every* FSM state for *every* target (`$all`, category, consumer group): catch-up *and* live delivery both produce per-batch spans tagged with the driving state, and a stopped worker *always* produces a terminal span carrying its stop reason. The proof is a **database-backed end-to-end test** that runs a real `$all` worker against Postgres with the tracer installed as the subscription `eventHandler` and an in-memory span exporter, drives it through catch-up → live → stop, and asserts the exported spans include the catch-up span, at least one live `kiroku.subscription.deliver` span with `state="live"` (closing gap 1), and a `kiroku.subscription.stopped` span (closing gap 2).

**These are committed core primitives, introduced deliberately pre-stable.** Kiroku has not released a stable version, so there is no public-API compatibility to preserve and no deprecation cycle to honor. The new `KirokuEventSubscriptionDelivered` constructor and the `SubscriptionDeliveryPhase` enum added to the core `KirokuEvent` API (`kiroku-store/src/Kiroku/Store/Observability.hs`) are therefore **permanent, committed additions to the event surface** — designed deliberately now as stable surface this project intends to keep, not a tentative bolt-on hedged against a future back-compat constraint. This mirrors the parent MasterPlan's "this is the moment to get the primitives right" stance: pre-1.0 is exactly when to add a core observability primitive without a deprecation cycle. (The constructor set is, separately, additive at the *type* level — see the additive-contract note in Context and Orientation — so the new constructor surfaces at every exhaustive match as a compile-time warning rather than a silent miss; "additive" there is about safe compilation, not about hedging the design.)

**Where this fits in the observability story: the complementary split with the registry.** This plan delivers the per-batch `kiroku.subscription.deliver` spans, which are the **timeline / correlation layer** — they record *when* each batch was delivered, in which phase, and how big it was, so an operator can correlate delivery against retries, pauses, reconnects, and the terminal stop on one timeline. They are deliberately *not* the primary signal for "is `$all` Live and advancing right now." That live-state / live-progress question is answered by the **subscription-state registry** (sibling plan `docs/plans/45-central-subscription-state-registry-on-the-store-handle-for-cheap-observability.md`), which is the **performant live-state layer**: it exposes each subscription's current state and FSM cursor position as a cheap, point-in-time snapshot read on the consumer's own cadence (a scrape interval, an admin poll) at **zero per-event cost**, because it reuses the worker's existing per-transition `stateVar` writes and adds no new per-event writes. This split is why the per-batch deliver-span *volume* this plan introduces is acceptable: the always-available "is `$all` Live and advancing" signal lives in the registry's `(state, cursor position)`, not in the span stream, so the spans do not have to be the primary live-progress signal and can be sampled or dropped under load without losing the live-state view. The prior tracer plan (`docs/plans/44-...`) recorded in its review that per-batch spans are the *first telemetry dropped under load*; the registry is precisely the layer that covers that case, so dropping deliver spans under load degrades the timeline detail without blinding the operator to current live state.

This plan is child plan 2 (EP-2) of the MasterPlan `docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md`, and it completes the tracer first shipped by `docs/plans/44-opentelemetry-tracing-of-subscription-worker-state-and-span-attributes-end-to-end-through-the-shibuya-adapter.md` (referred to below as "the prior tracer plan"). The prior tracer plan's tests fed *synthetic* `KirokuEvent` sequences, so they proved the event→span mapping but never proved that a real worker emits the events needed for every state — which is exactly why these two gaps went unnoticed.

You can see it working by running `cabal test kiroku-otel` (the new database-backed end-to-end test, plus the updated synthetic unit tests) and `cabal build all`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-05-31) — `Observability.hs`: added `SubscriptionDeliveryPhase` and the additive `KirokuEventSubscriptionDelivered` constructor; exported the phase; updated the module Haddock. `Worker.hs`: emits `KirokuEventSubscriptionDelivered` once per batch from `processEvents`, derived from the driving state. `cabal build kiroku-store` clean; `cabal test kiroku-store` green (183 examples, 0 failures).
- [x] M2 (2026-05-31) — `kiroku-otel/src/Kiroku/Otel/Subscription.hs`: handles `Delivered` by opening/closing a `kiroku.subscription.deliver` span tagged with the phase and row count, with the "live batch ⇒ clear open retries as Ok" logic moved here; `Fetched` is a no-op; the `Stopped` handler always emits a standalone `kiroku.subscription.stopped` span (in addition to closing open episodes); per-key span state striped into a lock-free `IORef (Map SpanKey (IORef OpenState))` (C2) with `withKey`/`dropKey` keeping their call shape (nine `onEvent` arms unchanged). Synthetic tests updated: live-span assertion switched from `Fetched` to `Delivered`, plus a `DeliveredCatchUp` case and a `Stopped`-produces-a-span case. Tracer compiles with **no** `-Wincomplete-patterns` warning; `cabal test kiroku-otel` green (15 examples, 0 failures).
- [x] M3 (2026-05-31) — database-backed end-to-end test added in `kiroku-otel/test/Main.hs`: runs a real `$all` worker with the tracer + in-memory exporter through catch-up → live → stop and asserts the catch-up span, a `deliver` span with `state="live"`, and a `stopped` span all appear. Test-only cabal deps added (`kiroku-test-support`, `ephemeral-pg`, `stm`, plus `lens`/`generic-lens` for the label-based settings update). Docs (`docs/user/opentelemetry.md`) and both CHANGELOGs updated. `cabal test kiroku-otel` green (16 examples, 0 failures); `cabal build all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-05-31 — Live deliver span confirmed end-to-end against a real `$all`
worker.** The DB-backed test (`kiroku-otel/test/Main.hs`,
`subscriptionTraceHandler end-to-end`) seeds 5 events, waits for catch-up to
drain them, appends 3 more while live, waits for the count to reach 8, then
cancels. The exported spans include ≥1 `kiroku.subscription.deliver` span with
`state="live"` and exactly one `kiroku.subscription.stopped` span — proving both
gaps closed on a real worker, not synthetic events. The whole otel suite is
green (16 examples, 0 failures).

**2026-05-31 — `eventHandler` record-update is ambiguous under
`DuplicateRecordFields`; a source-type annotation does not resolve it.** The plan
sketch's `(defaultConnectionSettings connStr){ eventHandler = Just handler }`
failed with `GHC-99339 Ambiguous record update with field 'eventHandler'`
because the field name exists on both `ConnectionSettingsM` and `KirokuStore`.
Annotating the source record (`... :: ConnectionSettings`) did **not** help
(GHC2024 record-update disambiguation does not use the source type here). The fix
matches the rest of the codebase: the generic-lens label update
`defaultConnectionSettings connStr & #eventHandler .~ Just handler`, which pulled
`lens` + `generic-lens` into the test stanza (recorded in the Decision Log).

**2026-05-31 — `AllStreams`/`NoStream` must be imported via their types.** The
plan sketch imported `AllStreams` and `NoStream (..)` as bare names from
`Kiroku.Store`; GHC rejected them (`GHC-35373`) because they are constructors of
`SubscriptionTarget` and `ExpectedVersion`. Imported as
`SubscriptionTarget (..)` / `ExpectedVersion (..)` instead.

**2026-05-31 — The native in-IO append path is `runStoreIO store $ appendToStream
(StreamName ...) NoStream events`.** Confirmed against `kiroku-store`'s own
`Test/SubscriptionPauseResume.hs` and `Test/Causation.hs`; this is the lighter
path the plan preferred over the adapter's Shibuya-tracing wrapper. The e2e test
builds minimal `EventData` records (unique type tag, `Aeson.Null` payload, no
metadata) — recorded in the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Close the `$all`-`Live` tracing gap with a **single centralized per-batch delivery `KirokuEvent`** emitted by the one delivery primitive `processEvents`, for every target — not a narrow `$all`-only `KirokuEventSubscriptionFetched` emission.
  Rationale: The user explicitly chose the "centralized delivery event" approach. `processEvents` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:594-656`) is the *single* place every target delivers a batch — catch-up for `$all`/category/consumer-group via the FSM `DeliverBatch` effect, `$all` live via the same effect, and category/consumer-group live via the two DB-driven loops. Emitting the new event there uniformly captures live delivery for `$all` **and** makes catch-up batch progress traceable, with one delivery signal across all targets. This mirrors MasterPlan 6 EP-2's "one delivery primitive" decision (the prior tracer plan's reasoning that all four ack dispositions behave identically because they share `processEvents`). A narrow `$all`-only `Fetched` would patch only one branch, would not trace catch-up progress, and would scatter the delivery signal across three emit sites.
  Date: 2026-05-31.

- Decision: **Retain** `KirokuEventSubscriptionFetched` in the worker but make the tracer **ignore** it (a no-op match), so the DB-driven live loops — which now emit *both* `Fetched` and `Delivered` per batch — do not produce two spans per batch.
  Rationale: Other behavior and tests rely on `Fetched` (e.g. asserting an idle category does no live fetch; per-subscription live-fetch-rate observability). Removing it would be a breaking, non-additive change to `KirokuEvent` and would regress those uses. The tracer instead keys its per-batch span on the new `Delivered` event only; `Fetched` becomes a no-op pattern (kept for exhaustiveness). This is additive on the worker side and avoids double-emitting spans on the category/consumer-group live path.
  Date: 2026-05-31.

- Decision: Make the tracer **always emit a short standalone `kiroku.subscription.stopped` span** on `KirokuEventSubscriptionStopped`, in addition to preserving the existing behavior of stamping the stop reason on any open episode span and closing all open spans.
  Rationale: `KirokuEventSubscriptionStopped` is always emitted by the worker, but a healthy worker that catches up and runs live has *no* open episode span when it stops, so the terminal state currently vanishes from the trace. A dedicated, always-emitted terminal span guarantees the `Stopped` state — with its `kiroku.subscription.stop_reason` and checkpoint — is always present in the trace.
  Date: 2026-05-31.

- Decision: Tag the new delivery event with a small **phase enum** `SubscriptionDeliveryPhase = DeliveredCatchUp | DeliveredLive` rather than a free `Bool` or `Text`.
  Rationale: The delivery primitive already knows the driving state (`CatchingUp{}` vs `Live`); a typed phase makes the catch-up-vs-live distinction explicit, total, and matchable, and maps cleanly to the span's `kiroku.subscription.state` attribute (`"catchup"` / `"live"`). A `Bool` would be unlabelled at the call site; a `Text` would be unchecked.
  Date: 2026-05-31.

- Decision: Treat the new `KirokuEventSubscriptionDelivered` constructor and the `SubscriptionDeliveryPhase` enum as **committed, permanent core `KirokuEvent` API**, introduced deliberately now because kiroku is pre-stable — not as a tentative or experimental bolt-on.
  Rationale: Kiroku has not released a stable version, so there is no public-API compatibility to preserve and no deprecation cycle to honor; pre-1.0 is exactly the moment to add a core observability primitive correctly. This follows the parent MasterPlan's "this is the moment to get the primitives right" stance and its 2026-05-31 decision to "introduce the registry and a public subscription-state view type as first-class core primitives now ... [and] the `KirokuEvent` delivery constructor (EP-2) is likewise a permanent, committed addition to the event API." The separate "constructor set is additive" property (the tracer's `-Wincomplete-patterns` safety net) is about *safe compilation* when the sum type grows, not about hedging the design — the additions are stable surface the project intends to keep.
  Date: 2026-05-31.

- Decision: Frame the per-batch `kiroku.subscription.deliver` spans as the **timeline / correlation layer**, complementary to the subscription-state **registry** (sibling plan `docs/plans/45-...`) which is the **performant live-state layer**; the deliver spans deliberately do *not* carry the primary live-progress signal.
  Rationale: Parent MasterPlan direction — "the registry is the performant live-state layer of the observability story; spans are the timeline layer," and the two are complementary. The export-on-end constraint makes spans a poor place to read current state (an in-progress worker is invisible until its span ends), and per-batch spans are, per `docs/plans/44-...`'s review, the *first telemetry dropped under load*. The registry answers "is `$all` Live and advancing right now" from its `(state, cursor position)` snapshot at zero per-event cost (reusing the worker's existing `stateVar` writes, read on the consumer's own cadence), so this plan's higher-volume per-batch deliver-span *volume* is acceptable: the live-progress signal lives in the registry, not the span stream, so sampling or dropping deliver spans under load degrades timeline detail without blinding the operator to live state. This plan does not build the registry (EP-1 / sibling plan, referenced by path only); it only frames the spans correctly relative to it. This is why the design here stays event-driven for the timeline while the cheap live-state path is left to the registry.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Keep emitting the per-batch delivery event during **catch-up** (the centralized, every-target design is unchanged), accepting its hot-path cost as a documented opt-in.
  Rationale: The parent MasterPlan's 2026-05-31 pre-commitment audit confirmed the centralized `Delivered` emit puts per-batch tracer work on the catch-up hot path whenever a tracer is installed: each catch-up batch emits `KirokuEventSubscriptionDelivered DeliveredCatchUp`, which the tracer turns into two ops on the *shared* `MVar (Map SpanKey OpenState)` plus a span open/close. The "per-batch deliver spans are the first telemetry dropped under load" note concerns *export volume*, not *emission* — emission still runs on the worker thread regardless of sampling. The user chose to keep catch-up deliver spans: they preserve catch-up batch-progress visibility and the "one centralized delivery signal across all targets" decision, and the cost is opt-in (only with an installed `eventHandler`) and bounded (it is per-batch, not per-event; catch-up batches carry many events). The one real concern — cross-worker contention on the tracer's single shared lock now that every batch on every target emits a span — is **removed structurally by C2** (the striped per-key span state added as M2 Edit 7), rather than merely accepted. So catch-up deliver spans are kept *and* the contention is eliminated; the two compose. (The alternative lever — emit `Delivered` only for `DeliveredLive` — was rejected because it loses catch-up deliver spans and C2 makes it unnecessary.)
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Fold in **C2** — stripe the tracer's per-key span state into a lock-free `IORef (Map SpanKey (IORef OpenState))` instead of one shared `MVar`.
  Rationale: This plan emits a per-batch `Delivered` event on every target in both phases, so every worker would take the tracer's single shared `MVar` once per batch — serializing many simultaneous catch-ups/live deliveries on one lock. C2 gives each `SpanKey` its own `IORef OpenState` (single-writer, so lock-free) behind a read-mostly outer registry mutated only on `Started`/`Stopped`. It fixes both the catch-up hot-path contention (the audit's Finding 5) *and* the pre-existing contention on the DB-driven live loops, is `base`-only (`Data.IORef`; no new dependency, no cabal change), is purely internal (no public API change, no `kiroku-store` change), and keeps `withKey`/`dropKey`'s call shape so the nine `onEvent` arms are unchanged. Behavior is byte-identical (same spans, same attributes), so the existing synthetic tests and the M3 DB-backed test are the equivalence proof. Considered and rejected: C1 (a per-subscription trace handler) — it would need a new per-subscription `eventHandler` injection point in `kiroku-store`, a cross-package API change C2 makes unnecessary. C2 also strengthens the no-deadlock property: it removes all locks from the tracer.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): The audit confirmed the tracer changes introduce **no deadlock**.
  Rationale: Before C2 the tracer used a single `MVar (Map SpanKey OpenState)` with non-nested `withMVar`/`modifyMVar_` and all span IO *outside* the lock, under a single-writer-per-`SpanKey` invariant (each `(name, member)` is emitted by one worker thread) — no lock-ordering inversion. After C2 (M2 Edit 7) the tracer has **no locks at all**: the outer registry is an `IORef` mutated only via non-blocking `atomicModifyIORef'` on `Started`/`Stopped`, and each key's `IORef OpenState` is single-writer, so the per-batch path does no blocking synchronization. Either way `emit` is never called inside an STM transaction on the worker side (`processEvents` reads `driving` in one `atomically`, then emits outside it — `Worker.hs:602-606`). Nothing can deadlock. Recorded so EP-2's core additions can be committed.
  Date: 2026-05-31.

- Decision (impl, 2026-05-31): The e2e test's store-settings update uses the generic-lens label `defaultConnectionSettings connStr & #eventHandler .~ Just handler`, adding `lens` and `generic-lens` to the test stanza.
  Rationale: Plain record-update on `eventHandler` is ambiguous under `DuplicateRecordFields` (the field exists on both `ConnectionSettingsM` and `KirokuStore`) and a source-type annotation does not disambiguate it under GHC2024. The label-based update is how the rest of the codebase mutates these settings (`kiroku-store/test/Test/Helpers.hs`, `shibuya-kiroku-adapter/test/Main.hs`), so it is the consistent fix; it costs two test-only deps already used elsewhere in the repo.
  Date: 2026-05-31.

- Decision (impl, 2026-05-31): The e2e test appends via `runStoreIO store $ appendToStream (StreamName prefix) NoStream events` with minimal hand-built `EventData` (unique type tag, `Aeson.Null` payload, no metadata).
  Rationale: This is the native in-IO append path `kiroku-store`'s own tests use (`Test/SubscriptionPauseResume.hs`, `Test/Causation.hs`), lighter than the adapter's `runEff $ runTracingNoop` wrapper — exactly the path the plan said to prefer. `AllStreams`/`NoStream` are imported through their types (`SubscriptionTarget (..)` / `ExpectedVersion (..)`) because they are constructors, not top-level names.
  Date: 2026-05-31.

- Decision: Place the database-backed end-to-end test in `kiroku-otel`'s test suite (not `kiroku-store`'s), accepting new test-only dependencies on `kiroku-store`, `kiroku-test-support`, and the OTel SDK/in-memory exporter.
  Rationale: The proof must run a *real* subscription (`kiroku-store`) *and* install the tracer (`kiroku-otel`) and read its spans (the in-memory exporter). Only `kiroku-otel`'s test suite can depend on both. The prior tracer plan deliberately avoided a DB-backed test to keep `kiroku-otel` light; this plan reverses that *for the test stanza only* (the library still depends only on `hs-opentelemetry-api` + `kiroku-store`) because the whole point of EP-2 is to prove, against a real worker, that the two gaps are closed — which a synthetic test cannot do.
  Date: 2026-05-31.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**2026-05-31 — Complete and accepted.** All three milestones landed exactly as
designed; no design change was needed (only the three small mechanical
import/record-update adjustments recorded in Surprises & Discoveries). Against the
original purpose:

- **Gap 1 (`$all` Live emits no per-batch span) — closed.** The centralized
  `KirokuEventSubscriptionDelivered` from `processEvents` makes every target's
  live deliveries produce a `kiroku.subscription.deliver` span tagged
  `state="live"`; the DB-backed e2e test proves it on a real `$all` worker.
- **Gap 2 (clean `Stopped` after live produces no span) — closed.** The tracer
  always emits a standalone `kiroku.subscription.stopped` span carrying the stop
  reason and checkpoint; proven both synthetically and end-to-end.
- **C2 folded in.** The per-key span state is now lock-free
  (`IORef (Map SpanKey (IORef OpenState))`), removing both the new catch-up
  contention and the pre-existing DB-driven-live-loop contention, with
  byte-identical behavior (the unchanged synthetic tests are the equivalence
  proof).
- **The committed core primitive shipped.** `KirokuEventSubscriptionDelivered` +
  `SubscriptionDeliveryPhase` are permanent additions to the `KirokuEvent` API;
  `KirokuEventSubscriptionFetched` is retained (now a tracer no-op) so its
  live-fetch-rate signal is undisturbed.

Verification: `cabal test kiroku-store` (183, 0 failures), `cabal test
kiroku-otel` (16, 0 failures incl. the DB-backed e2e test), `cabal build all`
green. No `-Wincomplete-patterns` warning, confirming the additive contract held
at compile time. No gaps outstanding.


## Context and Orientation

Read this section in full before editing. It assumes no prior knowledge of the repository.

**Repository layout relevant to this plan.** The repository root is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Three packages matter:

- `kiroku-store` — the event store and subscription runtime. You will *edit* two files here and *read* several others. Key files:
  - `kiroku-store/src/Kiroku/Store/Observability.hs` — defines `KirokuEvent` (the operational-event sum type) and its supporting enums `SubscriptionDbPhase`, `SubscriptionGroupContext`. **You add a constructor and a phase enum here.**
  - `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` — the worker loop and the single delivery primitive `processEvents`. **You add one emit call here.**
  - `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` — the `SubscriptionState` type (`CatchingUp`, `Live`, `Paused`, `Reconnecting`, `Retrying`, `Stopped`), the `Effect`/`Input` types, and `step`. Read only.
  - `kiroku-store/src/Kiroku/Store/Subscription/Types.hs` — `SubscriptionName`, `SubscriptionConfigM`/`SubscriptionConfig`, `defaultSubscriptionConfig`, the per-event handler result `SubscriptionResult` (`Continue`, `Stop`, `Retry`, `DeadLetter`), the `currentState` handle accessor, `Target` (`AllStreams`/`Category`). Read only.
  - `kiroku-store/src/Kiroku/Store/Subscription.hs` — `subscribe`/`withSubscription`. Read only.
  - `kiroku-store/src/Kiroku/Store/Connection.hs` — `ConnectionSettingsM`/`ConnectionSettings`, `defaultConnectionSettings`, the `KirokuStore` handle record, and `withStore`. The `eventHandler` field is where the tracer is installed. Read only.
  - `kiroku-store/src/Kiroku/Store.hs` — the umbrella module re-exporting the store API (`appendToStream`, `withStore`, `subscribe`, etc.). Read only.
- `kiroku-otel` — the opt-in OpenTelemetry package. You will *edit* its tracer module, *edit* its test, and *edit* its cabal test stanza. Key files: `kiroku-otel/src/Kiroku/Otel/Subscription.hs`, `kiroku-otel/test/Main.hs`, `kiroku-otel/kiroku-otel.cabal`.
- `kiroku-test-support` — a shared test-only package exposing the Postgres harness. Key file: `kiroku-test-support/src/Kiroku/Test/Postgres.hs`, exposing `withSharedMigratedPostgres :: IO a -> IO a` and `withMigratedTestDatabase :: (Text -> IO a) -> IO a`. The cabal package is `kiroku-test-support` (module `Kiroku.Test.Postgres`).

**The FSM states in one sentence each.** `CatchingUp` — reading historical events straight from the database until it reaches the publisher's last-published position. `Live` — caught up; receiving new events (for `$all` from an in-process bounded queue the publisher pushes to; for category/consumer-group by re-querying on a notification). `Paused` — recoverable backpressure: the subscriber's bounded queue filled, so delivery paused. `Reconnecting` — a live DB fetch lost the pool; backing off and re-catching-up. `Retrying` — a handler asked to redeliver a single poison event. `Stopped` — terminal: the handler returned `Stop`, the worker was cancelled, the queue overflowed, or the worker thread crashed.

**The `eventHandler` callback (the integration seam).** `ConnectionSettingsM.eventHandler :: Maybe (KirokuEvent -> m ())` (`kiroku-store/src/Kiroku/Store/Connection.hs:90`) is the optional operator callback. When `withStore` acquires the store it captures this into the `KirokuStore` handle's `eventHandler :: Maybe (KirokuEvent -> IO ())` field (`Connection.hs:140`, captured at `Connection.hs:221,234`), and `subscribe` threads it into the worker (`Kiroku.Store.Subscription.subscribe` passes `store ^. #eventHandler` to `runWorker`). The worker's local `emit evt = for_ mHandler ($ evt)` (`Worker.hs:154`) invokes it for every event. **The callback runs synchronously on the worker's emit-site thread**, so it must be fast; the tracer is safe because opening/ending spans is in-memory and only *export* may block, which the SDK's batch span processor does on a background thread. The tracer is installed by setting `eventHandler = Just handler` where `handler <- subscriptionTraceHandler tracer`.

**The single delivery primitive `processEvents`.** Read `Worker.hs:594-656`. `processEvents pool config stateVar events emit posRef :: IO (Maybe GlobalPosition)` is THE one place every target delivers a batch to the handler, resolving each event's disposition (`Continue`/`Stop`/`Retry`/`DeadLetter`). It is called from three sites: the FSM `DeliverBatch` effect handler (`Worker.hs:301-305`, which covers catch-up for *every* target and `$all` live), `liveLoopCategoryNotify` (`Worker.hs:475`), and `liveLoopDbDriven` (`Worker.hs:527`). At entry it reads `driving <- atomically (readTVar stateVar)` (`Worker.hs:605`) — `driving` is the FSM state the driver wrote for this batch, i.e. `CatchingUp{}` during catch-up or `Live` during live delivery. It binds `subName = name config` (`Worker.hs:608`) and `groupCtx = groupCtxOf config` (`Worker.hs:609`). Batches are always non-empty here (the live branches filter to non-empty and the loop does `V.last events`), so `V.length events >= 1`.

**The `KirokuEvent` type and its additive contract (read `Observability.hs`).** `KirokuEvent` is a sum type whose constructors each carry a `SubscriptionName`, often a `GlobalPosition`, and a trailing `SubscriptionGroupContext` (`NonGroup` or `GroupMember member size`). The constructors relevant here:

```haskell
KirokuEventSubscriptionStarted  !SubscriptionName !GlobalPosition !SubscriptionGroupContext
KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition !SubscriptionGroupContext
KirokuEventSubscriptionStopped  !SubscriptionName !GlobalPosition !SubscriptionStopReason !SubscriptionGroupContext
KirokuEventSubscriptionFetched  !SubscriptionName !Int !SubscriptionGroupContext  -- Int = row count of one DB-driven live fetch
```

The module Haddock (`Observability.hs:30-33`) states the constructor set is **additive**: new constructors are added, never changed, so any exhaustive pattern match (notably the tracer's `\case` in `Kiroku.Otel.Subscription`) surfaces a new constructor as a `-Wincomplete-patterns` warning at compile time, never a silent miss. This is the property that makes adding `KirokuEventSubscriptionDelivered` safe: the tracer is compiled with `-Wall` and will flag the unhandled constructor until you handle it. Note carefully that "additive" here describes the *compile-time safety* of growing the sum type — it is **not** a hedge against design commitment. `KirokuEventSubscriptionDelivered` and `SubscriptionDeliveryPhase` are **committed, permanent core API**: kiroku has not released a stable version, so they are introduced deliberately now with no back-compat constraint and no deprecation cycle (this is the parent MasterPlan's "get the primitives right pre-stable" stance — see its Vision & Scope and Decision Log). You are adding stable observability surface the project intends to keep, not an experimental constructor that might be removed.

**The tracer's span model (read `kiroku-otel/src/Kiroku/Otel/Subscription.hs`).** `subscriptionTraceHandler tracer` allocates a per-key registry and returns `onEvent tracer cell`. A `SpanKey = (Text, Maybe Int32)` identifies one worker by `(subscription name, member)` so two consumer-group members never collide. `OpenState` holds the spans currently open for a key: a `catchup`, a `reconnect`, a `pause`, and a `Map Int64 Span` of per-poison-event `retries`. *Today* the registry is one shared `MVar (Map SpanKey OpenState)`, and the helpers `withKey`/`dropKey` take that one lock per event; **M2 Edit 7 stripes this** into `IORef (Map SpanKey (IORef OpenState))` — an outer registry read lock-free on the hot path and mutated (via `atomicModifyIORef'`) only when a key is first seen or removed, with each key's own single-writer `IORef OpenState` holding its spans — so the per-batch span work this plan adds never serializes workers on one lock. Either way `withKey cell key f` (read the key's `OpenState`, run `f` with no shared lock held, write the cell back) and `dropKey cell key f` (read-and-remove the key, run the finalizer) keep span syscalls off any shared lock; this is safe because each key is single-writer (one worker thread). `openSpan tracer name attrs` creates a root span (`createSpan tracer Context.empty name defaultSpanArguments`) and sets attributes via `setAttrs` (the singular `addAttribute`, an insert, because the bulk `addAttributes` is a left-biased union that would silently drop an update). `closeSpan` / `closeSpanWith` end a span; `spanEvent` adds a timestamped span event.

Today the tracer maps events to spans like this (the parts you will change are flagged):
- `Started` → open `kiroku.subscription.catchup` (`Subscription.hs:184-192`).
- `CaughtUp` → close the open catch-up or reconnect span; **clear open retries as Ok** (`Subscription.hs:193-201`).
- `Fetched name rows grp` → open and immediately close `kiroku.subscription.fetch` with `kiroku.batch.rows`, state `"live"`, then **clear open retries as Ok** (`Subscription.hs:202-211`). **← you replace this with a no-op; the `deliver` span and the retry-clearing move to the new `Delivered` handler.**
- `Paused`/`Resumed` → open/close `kiroku.subscription.paused` (`Subscription.hs:212-224`).
- `Reconnecting` → open `kiroku.subscription.reconnecting` (attempt 1) or add a `reconnect.attempt` span event (`Subscription.hs:225-237`).
- `Retrying`/`DeadLettered` → per-poison-event `kiroku.subscription.retrying` span, or a standalone `kiroku.subscription.dead_letter` (`Subscription.hs:238-273`).
- `DbError` → span event on an open episode, or standalone `kiroku.subscription.db_error` (`Subscription.hs:274-285`).
- `Stopped` → stamp the stop reason on `primaryEpisode`, then close all open spans for the key and drop the key (`Subscription.hs:286-298`). **← you add an always-emitted `kiroku.subscription.stopped` span here.**

The span-name constants live at `Subscription.hs:403-410` and the attribute-key constants at `Subscription.hs:414-427`. The exports list (`Subscription.hs:78-103`) re-exports the span-name and attribute-key constants for tests.

**The export-on-end constraint (the reason the model uses short spans).** A span is exported to the backend only when it *ends* — the SDK's span processors fire `onEnd`, never on a snapshot of an in-flight span (verified in `hs-opentelemetry`: `endSpan` → `tracerProviderOnEnd` → `spanProcessorOnEnd`, with no partial export; documented at `Subscription.hs:22-59`). Consequences for this plan: (1) the per-batch `deliver` span must open *and close* immediately so it exports continuously during `Live`; (2) the in-memory exporter used in tests only ever receives *ended* spans, so any test assertion that a span "appears" is also proof that it ended; (3) the always-emitted `stopped` span must be opened and closed within the `Stopped` handler so it actually exports.

**Why the deliver spans need not carry the live-progress signal (the registry split).** The same export-on-end constraint is *also* why spans are a poor place to read "what state is each subscription in **right now**": an in-progress `Reconnecting`/`Paused`/`Live` worker is invisible in the span backend until its episode span ends. The parent MasterPlan resolves this by positioning the **subscription-state registry** (sibling plan `docs/plans/45-central-subscription-state-registry-on-the-store-handle-for-cheap-observability.md`) as the **performant live-state layer**: a `TVar`-backed snapshot of every subscription's current state and cursor position, read on the consumer's own cadence at **zero per-event cost** (it reuses the worker's existing per-transition `stateVar` writes and adds no new per-event writes). The spans this plan adds are the complementary **timeline / correlation layer**. For this plan that distinction is load-bearing in one specific way: the per-batch `kiroku.subscription.deliver` spans are a *higher-volume* signal (one span per batch, for every target, in both phases), and — as the prior tracer plan `docs/plans/44-...` recorded in its review — per-batch spans are the *first telemetry dropped under load*. That volume is acceptable here precisely because the cheap, always-available "is `$all` Live and advancing" signal lives in the registry's `(state, cursor position)`, not in the span stream: the deliver spans do not have to be the primary live-progress signal, so sampling or dropping them under load degrades timeline detail without blinding the operator to current live state. You do not implement the registry in this plan (it is EP-1 / a sibling plan, referenced by path only); you only frame the deliver spans correctly as the timeline layer that the registry complements.

**Build and test commands.** This is a Haskell project built with Cabal. From the repository root:

```bash
cabal build kiroku-store
cabal build kiroku-otel
cabal test kiroku-otel
cabal build all
```

If a command fails with a missing-tool error, prefix it with the project's dev shell (look for a `flake.nix` or `justfile` in the root and follow the convention the other packages' CI uses). Do not search `/nix/store`.


## Plan of Work

The work is three milestones. M1 adds the delivery event and emits it from the one delivery primitive. M2 changes the tracer to key its per-batch span on the new event, make `Fetched` a no-op, and always emit a terminal span — plus the synthetic unit tests. M3 adds the database-backed end-to-end test that is the real proof, plus docs and the CHANGELOG. M1 must land before M2 (the tracer matches the new constructor) and before M3 (the test depends on the new spans).


### Milestone 1 — add the delivery event and emit it from `processEvents`

**Scope.** Add a phase enum and one additive `KirokuEvent` constructor in `kiroku-store/src/Kiroku/Store/Observability.hs`, and emit the new event once per batch from `processEvents` in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, derived from the driving FSM state.

**What exists at the end.** Every batch delivered by a worker — catch-up for any target, `$all` live, and category/consumer-group live — emits exactly one `KirokuEventSubscriptionDelivered` carrying the subscription name, the batch row count, the delivery phase (`DeliveredCatchUp` or `DeliveredLive`), and the group context. `kiroku-store` builds; existing tests still pass (the change is additive; `Fetched` is untouched).

**Edit 1 — `Observability.hs`: the phase enum.** Add, near the other supporting enums (after `SubscriptionDbPhase` or near `SubscriptionGroupContext`):

```haskell
{- | Which FSM phase a 'KirokuEventSubscriptionDelivered' batch was delivered in:
the worker was either still catching up from history ('DeliveredCatchUp') or
already live ('DeliveredLive'). Derived from the driving 'SubscriptionState' the
worker wrote before the batch (see 'Kiroku.Store.Subscription.Worker.processEvents').
-}
data SubscriptionDeliveryPhase
    = -- | The batch was delivered while the worker was in 'CatchingUp'.
      DeliveredCatchUp
    | -- | The batch was delivered while the worker was 'Live'.
      DeliveredLive
    deriving stock (Eq, Show)
```

**Edit 2 — `Observability.hs`: the new constructor.** Add, as a new constructor of `KirokuEvent` (placement is anywhere in the sum; put it after `KirokuEventSubscriptionFetched` for readability), with full Haddock:

```haskell
    | {- | A subscription's worker delivered one non-empty batch of events to
      the handler through the single delivery primitive
      'Kiroku.Store.Subscription.Worker.processEvents'. Emitted once per batch on
      __every__ delivery path — catch-up for every target, @AllStreams@ live, and
      the @Category@\/consumer-group DB-driven live loops — so it is a uniform
      per-batch delivery signal. The 'Int' is the batch row count (always @>= 1@).
      The 'SubscriptionDeliveryPhase' says whether the worker was catching up or
      live when it delivered. The trailing 'SubscriptionGroupContext' identifies
      the consumer-group member (if any).

      This is distinct from 'KirokuEventSubscriptionFetched', which only the
      DB-driven live loops emit (per /fetch/, including empty fetches) and which
      this constructor does /not/ replace. A DB-driven live batch therefore emits
      both 'KirokuEventSubscriptionFetched' (the fetch) and
      'KirokuEventSubscriptionDelivered' (the delivery).
      -}
      KirokuEventSubscriptionDelivered !SubscriptionName !Int !SubscriptionDeliveryPhase !SubscriptionGroupContext
```

**Edit 3 — `Observability.hs`: exports.** Add `SubscriptionDeliveryPhase (..)` to the module export list (`Observability.hs:35-41`):

```haskell
module Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionDeliveryPhase (..),
    SubscriptionStopReason (..),
    SubscriptionGroupContext (..),
    DeadLetterReason (..),
) where
```

**Edit 4 — `Observability.hs`: Haddock bullet list.** Update the module Haddock's bullet list (`Observability.hs:9-20`) to mention the new event. Add a bullet such as:

```text
* Subscription batch delivery (one per non-empty batch handed to the
  handler, on every target and in both catch-up and live phases).
```

and keep the "constructor set is /additive/" paragraph as-is — it already documents exactly the property this constructor relies on.

**Edit 5 — `Worker.hs`: import the phase.** Extend the import of `Kiroku.Store.Observability` (`Worker.hs:49-54`) to bring in `SubscriptionDeliveryPhase (..)`:

```haskell
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionDeliveryPhase (..),
    SubscriptionGroupContext (..),
    SubscriptionStopReason (..),
 )
```

**Edit 6 — `Worker.hs`: emit the delivery event once per batch in `processEvents`.** Read `processEvents` (`Worker.hs:594-656`). It currently is:

```haskell
processEvents pool config stateVar events emit posRef = do
    driving <- atomically (readTVar stateVar)
    go driving 0
  where
    subName = name config
    groupCtx = groupCtxOf config
    ...
```

Emit the new event exactly once, right after reading `driving` and before the `go` loop, deriving the phase from `driving`. The batch is non-empty so `V.length events >= 1`:

```haskell
processEvents pool config stateVar events emit posRef = do
    -- The state the driver wrote for this batch (CatchingUp / Live); restored
    -- after each retry so the observable state does not stick on 'Retrying'.
    driving <- atomically (readTVar stateVar)
    -- Emit one centralized per-batch delivery event for *every* target and both
    -- phases. This is the single delivery primitive, so this one emit uniformly
    -- covers catch-up for every target, AllStreams live, and the DB-driven live
    -- loops (which still also emit KirokuEventSubscriptionFetched per fetch).
    let phase = case driving of
            CatchingUp{} -> DeliveredCatchUp
            _ -> DeliveredLive
    emit (KirokuEventSubscriptionDelivered subName (V.length events) phase groupCtx)
    go driving 0
  where
    ...
```

`CatchingUp`, `Live`, etc. are constructors of `SubscriptionState` already imported from `Kiroku.Store.Subscription.Fsm` (`Worker.hs:59-65`). Matching `CatchingUp{}` then `_` is total and treats every non-catch-up driving state (in practice only `Live` reaches `processEvents`) as live; do not enumerate the others, because only `CatchingUp` and `Live` are ever the driving state at a delivery (a `Retrying`/`Paused`/`Reconnecting`/`Stopped` state is never the value written before a `DeliverBatch`).

**Acceptance for M1.** `cabal build kiroku-store` compiles with no new warnings. `cabal test kiroku-store` still passes (the existing suite does not assert on the new event, and `Fetched` is unchanged). The tracer in `kiroku-otel` will *not* yet compile against the new constructor — that is expected and is fixed in M2; build `kiroku-store` alone for M1.

```bash
cabal build kiroku-store
cabal test kiroku-store
```


### Milestone 2 — tracer: deliver span, `Fetched` no-op, always-emit stopped span; synthetic tests

**Scope.** Change `kiroku-otel/src/Kiroku/Otel/Subscription.hs` to (a) handle `KirokuEventSubscriptionDelivered` by opening and immediately closing a `kiroku.subscription.deliver` span tagged with the phase and row count, and move the retry-clearing logic here; (b) make `KirokuEventSubscriptionFetched` a no-op (still matched, for exhaustiveness); (c) always emit a standalone `kiroku.subscription.stopped` span in the `Stopped` handler; (d) replace the single shared `MVar (Map SpanKey OpenState)` with a striped, lock-free per-key registry (`IORef (Map SpanKey (IORef OpenState))`) so the now-per-batch span work never serializes workers on one lock (C2, from the 2026-05-31 audit). Update the synthetic unit tests in `kiroku-otel/test/Main.hs`.

**What exists at the end.** The tracer compiles against the new constructor with no `-Wincomplete-patterns` warning, produces one `deliver` span per delivered batch tagged `state="catchup"` or `state="live"`, produces no double span for the DB-driven live path, always produces a terminal `stopped` span, and holds each worker's span state in its own lock-free `IORef` so no worker blocks another on the per-batch path. The synthetic unit tests assert the span behavior (byte-identical to before the striping); the DB-backed M3 test exercises the live hot path.

**Edit 1 — span-name constants (`Subscription.hs:401-410`).** Replace `spanFetch` with `spanDeliver` and add `spanStopped`. The constant block becomes:

```haskell
spanCatchup, spanDeliver, spanPaused, spanReconnecting, spanRetrying, spanDeadLetter, spanDbError, spanStopped :: Text
spanCatchup = "kiroku.subscription.catchup"
spanDeliver = "kiroku.subscription.deliver"
spanPaused = "kiroku.subscription.paused"
spanReconnecting = "kiroku.subscription.reconnecting"
spanRetrying = "kiroku.subscription.retrying"
spanDeadLetter = "kiroku.subscription.dead_letter"
spanDbError = "kiroku.subscription.db_error"
spanStopped = "kiroku.subscription.stopped"
```

**Edit 2 — exports (`Subscription.hs:82-90`).** In the "Span names" export group, replace `spanFetch` with `spanDeliver` and add `spanStopped`:

```haskell
    -- * Span names
    spanCatchup,
    spanDeliver,
    spanPaused,
    spanReconnecting,
    spanRetrying,
    spanDeadLetter,
    spanDbError,
    spanStopped,
```

The attribute-key exports are unchanged; `attrBatchRows`, `attrState`, `attrStopReason`, `attrCheckpoint` already exist and are reused.

**Edit 3 — `Delivered` handler (in the `onEvent` `\case`).** Add a new match arm. Place it where the old `Fetched` arm was (`Subscription.hs:202-211`). It opens and immediately closes the deliver span and folds in the retry-clearing logic that used to live in the `Fetched` arm — but only when the phase is live (a live batch means the worker advanced past any retried event; a catch-up batch does not interact with the live retry map):

```haskell
    KirokuEventSubscriptionDelivered name count phase grp ->
        withKey cell (keyOf name grp) $ \st -> do
            let stateText = case phase of
                    DeliveredCatchUp -> "catchup" :: Text
                    DeliveredLive -> "live"
            sp <-
                openSpan tracer spanDeliver $
                    baseAttrs name grp
                        ++ [(attrState, toAttribute stateText), (attrBatchRows, intAttr count)]
            closeSpan sp
            case phase of
                -- A live batch means the worker advanced past any retried event,
                -- so any still-open retry span succeeded: close them as Ok.
                DeliveredLive -> do
                    mapM_ (\rsp -> setStatus rsp Ok >> closeSpan rsp) (Map.elems (retries st))
                    pure st{retries = Map.empty}
                DeliveredCatchUp -> pure st
```

Import `SubscriptionDeliveryPhase (..)` from `Kiroku.Store.Observability` (extend the existing import at `Subscription.hs:114-117`):

```haskell
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDeliveryPhase (..),
    SubscriptionGroupContext (..),
 )
```

**Edit 4 — `Fetched` becomes a no-op.** Replace the entire old `KirokuEventSubscriptionFetched` arm (`Subscription.hs:202-211`) with a no-op match kept for exhaustiveness. Group it with the other non-traced operational events at the bottom of the `\case`:

```haskell
    -- Fetched is now a no-op: the DB-driven live loops emit both Fetched and
    -- Delivered per batch, and the deliver span (above) is keyed on Delivered so
    -- the live path does not produce two spans per batch. Matched for exhaustiveness.
    KirokuEventSubscriptionFetched{} -> pure ()
```

**Edit 5 — `Stopped` always emits a terminal span.** Change the `Stopped` arm (`Subscription.hs:286-298`) to additionally open-and-close a standalone `kiroku.subscription.stopped` span carrying the stop reason, the checkpoint, and the base attrs — in addition to (and before/after, order does not matter) stamping the reason on `primaryEpisode` and closing all open spans. Note `dropKey` runs its finalizer outside the lock, so doing span IO here is fine; the new standalone span needs the base attrs, so compute them from `name`/`grp`:

```haskell
    KirokuEventSubscriptionStopped name pos reason grp ->
        dropKey cell (keyOf name grp) $ \st -> do
            let stopAttrs =
                    [ (attrStopReason, toAttribute (T.pack (show reason)))
                    , (attrCheckpoint, posAttr pos)
                    ]
            -- Always emit a short standalone terminal span so the Stopped state is
            -- present in the trace even for a healthy worker that stops from Live
            -- with no open episode span.
            term <- openSpan tracer spanStopped (baseAttrs name grp ++ stopAttrs)
            closeSpan term
            -- Also record the stop reason on the most relevant open episode (if any),
            -- then end every open span so none leaks when the worker stops.
            mapM_ (`setAttrs` stopAttrs) (primaryEpisode st)
            mapM_ closeSpan (catchup st)
            mapM_ closeSpan (reconnect st)
            mapM_ closeSpan (pause st)
            mapM_ closeSpan (Map.elems (retries st))
```

**Edit 6 — module Haddock.** Update the span-model Haddock (`Subscription.hs:45-54`) so the per-batch bullet names `kiroku.subscription.deliver` (not `fetch`), notes it carries `kiroku.subscription.state` of `"catchup"` or `"live"` and `kiroku.batch.rows`, and that it is emitted on every target and both phases; and add a bullet (or extend the Stop description) noting that `kiroku.subscription.stopped` is always emitted on `Stopped`, carrying the stop reason and checkpoint. Note that `Fetched` is intentionally not traced (the deliver span subsumes it) to avoid double spans on the DB-driven live path.

**Edit 7 — striped per-key span state (C2: remove the shared-MVar contention).** Today
`subscriptionTraceHandler` allocates **one** `MVar (Map SpanKey OpenState)` shared by every
worker (`Subscription.hs:151-154`), and `withKey`/`dropKey` (`Subscription.hs:320-336`) take
that one lock on every event. Because this plan now emits a per-batch `Delivered` event on
*every* target and in *both* phases (catch-up and live), every worker would grab that single
lock once per batch — so many subscriptions catching up or running live at once serialize on
one MVar. This edit removes that contention (it fixes both the catch-up hot-path cost from the
parent MasterPlan's 2026-05-31 audit *and* the pre-existing contention on the DB-driven live
loops) by giving each `SpanKey` its **own** state cell. It is **purely internal**: no public
API changes, no `kiroku-store` change, and the nine `onEvent` `\case` arms are **unchanged**
because `withKey`/`dropKey` keep their call shape.

The design exploits the invariant the module already documents: each `SpanKey` is
**single-writer** (one worker thread emits all of that key's events, synchronously). So the
outer map is a read-mostly registry of cells, mutated only when a key is first seen (`Started`)
or removed (`Stopped`); each key's own `IORef OpenState` is touched only by its single worker
thread and needs no lock. Everything is `base`-only (`Data.IORef`); no new dependency.

Change the imports (`Subscription.hs:106`): **remove** the `Control.Concurrent.MVar` import and
**add**

```haskell
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
```

Introduce the cell-registry type alias and change the allocator
(`Subscription.hs:151-157`):

```haskell
-- A per-key span-state registry. The outer 'IORef' is read-mostly — mutated only
-- when a key is first seen ('Started') or removed ('Stopped'), via
-- 'atomicModifyIORef''. Each key's inner 'IORef OpenState' is single-writer (one
-- worker thread emits that key's events), so the per-batch hot path reads the outer
-- map lock-free and mutates only the key's own cell — no shared lock, no
-- cross-worker contention.
type SpanCells = IORef (Map SpanKey (IORef OpenState))

subscriptionTraceHandler :: Tracer -> IO (KirokuEvent -> IO ())
subscriptionTraceHandler tracer = do
    cells <- newIORef Map.empty
    pure (onEvent tracer cells)
```

Change `onEvent`'s type to take `SpanCells`, keeping its parameter named `cell` so the nine
arms are untouched (`Subscription.hs:182`):

```haskell
onEvent :: Tracer -> SpanCells -> KirokuEvent -> IO ()
onEvent tracer cell = \case
    -- ...all nine existing arms unchanged: they call `withKey cell ...` / `dropKey cell ...`...
```

Rewrite `withKey`/`dropKey` (`Subscription.hs:320-336`) — same signatures (so call sites are
identical), new lock-free bodies, plus a small `cellFor` helper:

```haskell
{- | The 'IORef' holding a key's 'OpenState', creating an empty cell on the key's
first touch (its @Started@ event). The outer registry is read lock-free on the hot
path; it is written (via 'atomicModifyIORef'') only to insert a new key's cell. The
inner cell is single-writer, so reads/writes of it need no lock. -}
cellFor :: SpanCells -> SpanKey -> IO (IORef OpenState)
cellFor cells key = do
    m <- readIORef cells
    case Map.lookup key m of
        Just ref -> pure ref
        Nothing -> do
            fresh <- newIORef emptyOpenState
            atomicModifyIORef' cells $ \m' ->
                case Map.lookup key m' of
                    Just ref -> (m', ref)                       -- another key inserted meanwhile; reuse
                    Nothing -> (Map.insert key fresh m', fresh)

{- | Run a state-update against a key's own cell. The span IO in @f@ runs on the
key's single-writer 'IORef' with no shared lock held, so workers never serialize on
span work. -}
withKey :: SpanCells -> SpanKey -> (OpenState -> IO OpenState) -> IO ()
withKey cells key f = do
    ref <- cellFor cells key
    st <- readIORef ref
    st' <- f st
    writeIORef ref st'

{- | Run a finalizer against a key's 'OpenState', then drop the key from the outer
registry. @Stopped@ is a key's last event, so nothing touches the cell afterward. -}
dropKey :: SpanCells -> SpanKey -> (OpenState -> IO ()) -> IO ()
dropKey cells key f = do
    mref <- atomicModifyIORef' cells $ \m -> (Map.delete key m, Map.lookup key m)
    st <- maybe (pure emptyOpenState) readIORef mref
    f st
```

Why this is correct and contention-free: for any one key, its `Started → … → Stopped` events
run on a single thread in order, so its inner `IORef` is always alive while that worker uses it
and is never read/written by another thread; the only cross-thread structure is the outer map,
which is read lock-free on the hot path and mutated only on the rare `Started`/`Stopped` via
`atomicModifyIORef'`. There are **no locks** (so nothing to deadlock) and the per-batch path
does **no** blocking synchronization. Behavior is byte-identical to the MVar version — the same
spans with the same attributes — so the existing synthetic tests (Edit 8) and the M3
database-backed test pass unchanged; they are the proof of equivalence. Note C2 removes the
cross-worker *contention*, not the per-batch span *allocation* (each delivered batch still opens
and closes one in-memory deliver span; that is intended and is dominated by the per-batch
checkpoint write `processEvents` already performs).

**Edit 8 — synthetic unit tests (`kiroku-otel/test/Main.hs`).** The current tests feed a `Fetched` event to assert the live span (`Main.hs:142-157`). Update them:

- **Imports (`Main.hs:19-34`):** replace `spanFetch` with `spanDeliver`, add `spanStopped`. Add `SubscriptionDeliveryPhase (..)` to the `Kiroku.Store.Observability` import (`Main.hs:36-41`). `attrState` is already not imported — add `attrState` to the `Kiroku.Otel.Subscription` import list so the catch-up/live phase can be asserted. `StopHandlerRequested`/`StopCancelled` come from `SubscriptionStopReason (..)`, already imported.
- **Replace the "catch-up then live" test (`Main.hs:142-157`)** to drive `Delivered` instead of `Fetched`. The live batch now arrives as a `DeliveredLive` event:

  ```haskell
        it "catch-up then live yields an ended catchup span and a live deliver span" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 10) NonGroup
                    , KirokuEventSubscriptionDelivered subName 3 DeliveredLive NonGroup
                    ]
            let catchups = spansNamed spanCatchup spans
                delivers = spansNamed spanDeliver spans
            length catchups `shouldBe` 1
            length delivers `shouldBe` 1
            attrOf attrSubName (head catchups) `shouldBe` Just (toAttribute ("orders" :: Text))
            attrOf attrCheckpoint (head catchups) `shouldBe` Just (i64 10)
            attrOf attrBatchRows (head delivers) `shouldBe` Just (i64 3)
            attrOf attrState (head delivers) `shouldBe` Just (toAttribute ("live" :: Text))
  ```

- **Add a catch-up-phase deliver test:**

  ```haskell
        it "a catch-up delivery yields a deliver span tagged state=catchup" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionDelivered subName 5 DeliveredCatchUp NonGroup
                    ]
            let delivers = spansNamed spanDeliver spans
            length delivers `shouldBe` 1
            attrOf attrBatchRows (head delivers) `shouldBe` Just (i64 5)
            attrOf attrState (head delivers) `shouldBe` Just (toAttribute ("catchup" :: Text))
  ```

- **Add a `Stopped`-produces-a-span test** (the gap-2 unit-level proof; the DB-backed proof is M3):

  ```haskell
        it "a clean stop from live always yields a standalone stopped span" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 10) NonGroup
                    , KirokuEventSubscriptionDelivered subName 2 DeliveredLive NonGroup
                    , KirokuEventSubscriptionStopped subName (GlobalPosition 12) StopHandlerRequested NonGroup
                    ]
            let stops = spansNamed spanStopped spans
            length stops `shouldBe` 1
            attrOf attrStopReason (head stops)
                `shouldBe` Just (toAttribute (T.pack (show StopHandlerRequested)))
            attrOf attrCheckpoint (head stops) `shouldBe` Just (i64 12)
  ```

  Import `attrStopReason` from `Kiroku.Otel.Subscription` (add to the import list at `Main.hs:19-34`).

- **The existing "stop ends an open pause span so no span leaks" test (`Main.hs:217-223`)** still holds (the pause span is closed by `Stopped`); it will now *also* see a `spanStopped` span, but it only asserts on `spanPaused`, so it needs no change. Leave it as-is.

The Pause/Reconnect/Retry/DeadLetter/consumer-group tests are unaffected by this milestone — they do not touch `Fetched` — and stay as-is.

**Acceptance for M2.** `cabal build kiroku-otel` compiles with no `-Wincomplete-patterns` warning (proving the additive constructor is handled). The C2 striping (Edit 7) is behavior-preserving, so it ships *green*: `cabal test kiroku-otel` passes with the existing span assertions unchanged — the same spans with the same attributes are produced whether the state lives in one shared `MVar` or per-key `IORef`s, which is exactly the equivalence the existing and new synthetic tests prove. `cabal test kiroku-otel` passes, including the updated and new synthetic tests:

```bash
cabal build kiroku-otel
cabal test kiroku-otel
```

Expected: the suite reports `0 failures` (the example count grows by the two added tests — see Validation).


### Milestone 3 — database-backed end-to-end test, docs, CHANGELOG

**Scope.** Add a database-backed end-to-end test to `kiroku-otel/test/Main.hs` that runs a *real* `$all` subscription worker with the tracer installed and an in-memory span exporter, drives it through catch-up → live → stop, and asserts the exported spans include the catch-up span, at least one `kiroku.subscription.deliver` span with `state="live"` (proving the `$all` Live gap is closed), and a `kiroku.subscription.stopped` span (proving the Stopped gap is closed). Add the test-only cabal dependencies. Update docs and the CHANGELOG. This is the real proof EP-2 exists to deliver; the synthetic tests (M2) cover Pause/Reconnect/Retry, while M3 specifically targets the two gaps — `$all` Live and Stopped.

**What exists at the end.** `cabal test kiroku-otel` stands up an ephemeral Postgres, runs a genuine worker, and demonstrates on real spans that a `$all` subscription now produces live `deliver` spans and a terminal `stopped` span. `cabal build all` is green.

**Edit 1 — cabal test dependencies (`kiroku-otel/kiroku-otel.cabal`, the `test-suite kiroku-otel-test` stanza, `kiroku-otel.cabal:59-79`).** The existing test stanza already depends on `kiroku-store`, `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-in-memory`, `hspec`, `containers`, `text`, etc. Add the dependencies needed to stand up a real store against the shared migrated Postgres harness, mirroring `shibuya-kiroku-adapter`'s test stanza (`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` test-suite: `kiroku-test-support`, `hasql-pool`, `ephemeral-pg`):

```cabal
  build-depends:
    , aeson                                >=2.1  && <2.3
    , base                                 >=4.18 && <5
    , bytestring                           >=0.11 && <0.13
    , containers                           >=0.6  && <0.8
    , ephemeral-pg                         >=0.2  && <0.3
    , hs-opentelemetry-api
    , hs-opentelemetry-exporter-in-memory
    , hs-opentelemetry-sdk
    , hspec                                >=2.10 && <2.12
    , kiroku-otel
    , kiroku-store                         ^>=0.1
    , kiroku-test-support
    , stm                                  >=2.5  && <2.6
    , text                                 >=2.0  && <2.2
    , time                                 >=1.12 && <1.15
    , unordered-containers                 >=0.2  && <0.3
    , uuid                                 >=1.3  && <1.4
```

`ephemeral-pg` is required transitively by `kiroku-test-support`'s harness; declaring it follows the sibling adapter's stanza. `stm` is needed for the `TVar` counter / `registerDelay` wait used to detect that live events were delivered. If the solver reports a redundant constraint, drop the redundant line — the harness package may already pull `ephemeral-pg` in, exactly as the adapter test does (which lists it explicitly). Verify with `cabal build kiroku-otel`.

Note the in-memory exporter and SDK are already pinned in `cabal.project` from the same git tag as `hs-opentelemetry-api` (the prior tracer plan added two `source-repository-package` stanzas, subdirs `sdk` and `exporters/in-memory`); no `cabal.project` change is needed here.

**Edit 2 — the end-to-end test (`kiroku-otel/test/Main.hs`).** The current `main` is `hspec $ do ...` (pure; no DB). Wrap it with the shared Postgres harness so the new DB-backed describe block can acquire a database, exactly as `shibuya-kiroku-adapter/test/Main.hs:60` does (`main = withSharedMigratedPostgres $ hspec $ do ...`). The pure TraceContext and synthetic-handler tests do not use the database, so wrapping `main` is harmless to them.

Add these imports to `kiroku-otel/test/Main.hs`:

```haskell
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad (unless)
import Kiroku.Store (
    NoStream (..),
    StreamName (..),
    appendToStream,
    defaultConnectionSettings,
    subscribe,
    withStore,
 )
import Kiroku.Store.Subscription (cancel, wait)
import Kiroku.Store.Subscription.Types (
    SubscriptionResult (..),
    defaultSubscriptionConfig,
 )
import Kiroku.Store.Types (Target (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
```

Adjust each import to the actual export points discovered while implementing — the umbrella `Kiroku.Store` re-exports `appendToStream`, `withStore`, `defaultConnectionSettings`, `subscribe`, and the subscription/types modules; confirm `NoStream`, `StreamName`, `Target (AllStreams)`, `SubscriptionResult (Continue)`, `defaultSubscriptionConfig`, `cancel`, `wait` are reachable (they are used by `shibuya-kiroku-adapter`'s test and `kiroku-store`'s own tests, which are reference call sites). The append API used by the adapter test is `runStoreIO store $ appendToStream (StreamName "...") NoStream events`; for a tracer test that does not need the effectful wrapper, use whichever direct append entry point `kiroku-store`'s own tests use (search `kiroku-store/test` for `appendToStream` to find the exact in-IO call shape and `EventData` builder). If the simplest path is the effectful `runStoreIO`/`runEff` wrapper the adapter test uses, replicate that; the test only needs events on disk, by any supported means.

Change `main` to:

```haskell
main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    -- ... existing describe blocks unchanged ...
    describe "subscriptionTraceHandler end-to-end (real $all worker)" $ do
        it "a real AllStreams worker emits catchup, a live deliver span, and a stopped span" $
            withMigratedTestDatabase $ \connStr -> do
                -- 1. In-memory exporter + provider + tracer + the trace handler.
                (processor, spansRef) <- inMemoryListExporter
                tp <- createTracerProvider [processor] emptyTracerProviderOptions
                let tracer = makeTracer tp "kiroku-otel-e2e" tracerOptions
                handler <- subscriptionTraceHandler tracer
                -- 2. A store whose eventHandler IS the tracer.
                let settings = (defaultConnectionSettings connStr) { eventHandler = Just handler }
                withStore settings $ \store -> do
                    -- 3. Seed some history so the worker has a real catch-up phase.
                    _ <- appendStoreEvents store "e2e-catchup" 5
                    -- 4. A Continue handler that counts deliveries, so we can wait
                    --    for the worker to actually go live and deliver live events.
                    delivered <- newTVarIO (0 :: Int)
                    let cfg =
                            defaultSubscriptionConfig (SubscriptionName "otel-e2e") AllStreams $ \_event -> do
                                atomically (modifyTVarCount delivered)
                                pure Continue
                    handle <- subscribe store cfg
                    -- 5. Wait for catch-up to drain the 5 seeded events.
                    waitForCount delivered 5 10_000_000
                    -- 6. Append MORE events now that the worker is live; these flow
                    --    through the publisher's bounded queue into the (Nothing,
                    --    AllStreams) Live branch -> DeliverBatch -> processEvents ->
                    --    KirokuEventSubscriptionDelivered DeliveredLive.
                    _ <- appendStoreEvents store "e2e-live" 3
                    waitForCount delivered 8 10_000_000
                    -- 7. Stop the worker (cancel) and wait for the Stopped event.
                    cancel handle
                    _ <- wait handle
                    -- 8. Flush the exporter and read the collected, ended spans.
                    _ <- forceFlushTracerProvider tp Nothing
                    spans <- readIORef spansRef
                    -- 9. Assertions: the two gaps are closed.
                    let catchups = spansNamed spanCatchup spans
                        delivers = spansNamed spanDeliver spans
                        liveDelivers =
                            filter ((== Just (toAttribute ("live" :: Text))) . attrOf attrState) delivers
                        stops = spansNamed spanStopped spans
                    length catchups `shouldSatisfy` (>= 1)
                    -- The gap-1 proof: at least one LIVE deliver span exists.
                    length liveDelivers `shouldSatisfy` (>= 1)
                    -- The gap-2 proof: a terminal stopped span exists.
                    length stops `shouldBe` 1
```

with these test helpers (place near the other helpers at the bottom of `Main.hs`):

```haskell
-- Increment a TVar Int counter by one within STM.
modifyTVarCount :: TVar Int -> STM.STM ()
modifyTVarCount v = readTVar v >>= \c -> writeTVar v (c + 1)

-- Append n trivial events to a fresh stream and return the store unchanged.
-- Uses whatever direct append entry point kiroku-store's own tests use; see the
-- note above. Each event is a minimal EventData with a unique type tag.
appendStoreEvents :: KirokuStore -> Text -> Int -> IO ()
appendStoreEvents store streamPrefix n =
    -- IMPLEMENTATION NOTE: mirror kiroku-store/test's append call. The shape is
    -- runStoreIO store (appendToStream (StreamName streamPrefix) NoStream events)
    -- (or the effectful runEff/runStoreIO wrapper the adapter test uses), where
    -- events = [ EventData { eventType = EventType ("E" <> T.pack (show i)), ... }
    --          | i <- [1 .. n] ].
    error "fill in per the kiroku-store append call shape discovered during impl"

-- Wait until the TVar reaches target or the timeout (micros) fires; fail on timeout.
waitForCount :: TVar Int -> Int -> Int -> IO ()
waitForCount countVar target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    ok <- atomically $
        (do c <- readTVar countVar; STM.check (c >= target); pure True)
            `STM.orElse` (do t <- readTVar timeoutVar; STM.check t; pure False)
    unless ok $ do
        actual <- atomically (readTVar countVar)
        expectationFailure ("Timed out waiting for " <> show target <> ", got " <> show actual)
```

`waitForCount` is copied verbatim from `shibuya-kiroku-adapter/test/Main.hs:745-762`; reuse that exact implementation. During implementation, replace the `appendStoreEvents` body with the real append call by reading a `kiroku-store/test` file to find the exact in-IO append shape and `EventData` constructor field set (the adapter test uses `runStoreIO store $ appendToStream (StreamName ...) NoStream events` inside `runEff $ runTracingNoop`, but `kiroku-store`'s own tests append without the Shibuya tracing effect — prefer that lighter path). Record the chosen append shape in the Decision Log.

**Why this forces a live deliver span.** The seeded events (step 3) are caught up during `CatchingUp`, producing `DeliveredCatchUp` deliver spans and the `catchup` episode span. After the worker reaches the publisher's last-published position it goes `Live` and emits `CaughtUp`. The events appended in step 6 are published to the subscriber's bounded queue; the `(Nothing, AllStreams)` live branch (`Worker.hs:226-242`) reads them and returns `BatchFetched fresh`, the FSM emits a `DeliverBatch` effect, the effect handler calls `processEvents` (`Worker.hs:301-305`), and `processEvents` — with `driving = Live` — emits `KirokuEventSubscriptionDelivered ... DeliveredLive`, which the tracer turns into a `deliver` span with `state="live"`. That span is the direct evidence the `$all` Live gap is closed. Cancelling the handle (step 7) makes the worker exit and emit `KirokuEventSubscriptionStopped`, which the tracer always turns into a `stopped` span — the evidence for gap 2.

**Reading spans from the in-memory exporter.** `inMemoryListExporter :: IO (Processor, IORef [ImmutableSpan])` (already used at `Main.hs:283`) returns a processor and a ref. After `forceFlushTracerProvider tp Nothing`, `readIORef spansRef` yields the list of *ended* `ImmutableSpan`s. Filter by `spanName` (the existing `spansNamed` helper) and read attributes with the existing `attrOf` helper (which looks up `getAttributeMap (spanAttributes s)`). These helpers already exist in `Main.hs:291-305`; reuse them.

**Edit 3 — docs.** Update `docs/user/opentelemetry.md` (the prior tracer plan added a "Tracing Subscription State" section with a span table and attribute keys): rename the per-batch span from `kiroku.subscription.fetch` to `kiroku.subscription.deliver`, note it carries `kiroku.subscription.state` of `"catchup"` or `"live"` and is emitted for *every* target in both phases (so a `$all` subscription's live phase is now traced), and add the always-emitted `kiroku.subscription.stopped` terminal span (carrying `kiroku.subscription.stop_reason` and `kiroku.checkpoint.global_position`). Note that `kiroku.subscription.fetched` is no longer the span trigger (the worker still emits `KirokuEventSubscriptionFetched` for the live-fetch-rate signal, but the tracer ignores it to avoid double spans). Keep the attribute names exactly as in code.

**Edit 4 — CHANGELOG.** Add an entry to `kiroku-store/CHANGELOG.md` (new additive `KirokuEventSubscriptionDelivered` event + `SubscriptionDeliveryPhase`, emitted once per batch from `processEvents`) and to `kiroku-otel/CHANGELOG.md` (tracer now keys the per-batch span on the delivery event as `kiroku.subscription.deliver` tagged with the phase, ignores `Fetched`, always emits a `kiroku.subscription.stopped` terminal span, and stripes per-key span state into lock-free per-key `IORef`s so the per-batch span work no longer serializes workers on one shared lock; database-backed end-to-end test added).

**Acceptance for M3.** `cabal test kiroku-otel` passes including the new DB-backed test, and `cabal build all` is green:

```bash
cabal test kiroku-otel
cabal build all
```

Expected `cabal test kiroku-otel` transcript tail (example count is the existing TraceContext + synthetic tests plus M2's two additions plus M3's one DB test; the precise number is whatever the suite reports — assert on `0 failures`, not the exact count):

```text
Finished in N.NNNN seconds
NN examples, 0 failures
```


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

1. M1 — edit `kiroku-store/src/Kiroku/Store/Observability.hs` (phase enum, new constructor, export, Haddock) and `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (import the phase; emit `KirokuEventSubscriptionDelivered` in `processEvents`). Build and test the store alone:

    ```bash
    cabal build kiroku-store
    cabal test kiroku-store
    ```

    Expected: compiles with no new warnings; the existing store suite reports `0 failures`.

2. M2 — edit `kiroku-otel/src/Kiroku/Otel/Subscription.hs` (constants, exports, `Delivered` arm, `Fetched` no-op, `Stopped` always-emit span, Haddock) and `kiroku-otel/test/Main.hs` (switch live assertions to `Delivered`, add catch-up and stopped cases). Build and test:

    ```bash
    cabal build kiroku-otel
    cabal test kiroku-otel
    ```

    Expected: no `-Wincomplete-patterns` warning; `0 failures`.

3. M3 — add the test-only deps to `kiroku-otel/kiroku-otel.cabal`, wrap `main` with `withSharedMigratedPostgres`, add the DB-backed end-to-end test and its helpers (filling in the append shape from a `kiroku-store/test` reference). Update `docs/user/opentelemetry.md`, `kiroku-store/CHANGELOG.md`, `kiroku-otel/CHANGELOG.md`. Then:

    ```bash
    cabal test kiroku-otel
    cabal build all
    ```

    Expected: `0 failures`; `cabal build all` green.

Update this section with the actual transcripts as you go.


## Validation and Acceptance

The feature is accepted when:

- `cabal test kiroku-store` passes — the additive `KirokuEventSubscriptionDelivered` event and its emission from `processEvents` do not regress the existing store behavior, and `KirokuEventSubscriptionFetched` is unchanged.
- `cabal test kiroku-otel` passes, including:
  - the updated synthetic test proving a `DeliveredLive` event yields one `kiroku.subscription.deliver` span with `kiroku.subscription.state = "live"` and `kiroku.batch.rows`;
  - the new synthetic test proving a `DeliveredCatchUp` event yields a `deliver` span tagged `state="catchup"`;
  - the new synthetic test proving a clean stop from live yields exactly one standalone `kiroku.subscription.stopped` span carrying the stop reason and checkpoint;
  - the **database-backed end-to-end test** that runs a real `$all` worker and asserts the exported spans include a `catchup` span, at least one `deliver` span with `state="live"` (the `$all` Live gap closed), and a `stopped` span (the Stopped gap closed). Because the in-memory exporter only receives *ended* spans, every "span appears" assertion is also proof the span ended.
- `cabal build all` is green (the tracer handles the new constructor with no `-Wincomplete-patterns` warning, proving the additive contract held at compile time).
- `docs/user/opentelemetry.md` reflects the `deliver` span (with the `state` attribute and both phases), the always-emitted `stopped` span, and the `Fetched`-not-traced note; both CHANGELOGs are updated.

The observable, beyond-compilation proof is the M3 transcript: a real worker against a real Postgres produces live `$all` spans and a terminal span, which is exactly the behavior the prior tracer plan's synthetic tests could not demonstrate.


## Idempotence and Recovery

All edits are additive and re-runnable. `kiroku-store` gains one `KirokuEvent` constructor and one enum (no removal, no change to existing constructors — `KirokuEventSubscriptionFetched` stays), one emit call in `processEvents`, and an export and Haddock update. `kiroku-otel` gains one new span-name constant (`spanDeliver` replaces `spanFetch`; `spanStopped` is new), a new `Delivered` match arm, a `Fetched` no-op arm, an extended `Stopped` arm, test changes, and test-only cabal deps. No database migration and no schema change are involved (the tracer is entirely in-memory, worker-thread-side; the DB-backed test only appends events and reads them back). Re-running the build/test commands is safe and repeatable; the end-to-end test acquires a fresh ephemeral database per run via `withMigratedTestDatabase`.

If the OTel API or harness signatures differ from those assumed here, adjust the calls (the design is unchanged) and record the difference in Surprises & Discoveries. If the exact append-call shape in the end-to-end test differs from the sketch, use whatever `kiroku-store`'s own tests use and record it in the Decision Log. If a cabal dependency line is redundant (the harness already pulls it in), drop the redundant line — partial edits still compile because every change is additive.


## Interfaces and Dependencies

**New, `kiroku-store` (`kiroku-store/src/Kiroku/Store/Observability.hs`):**

```haskell
-- Exported via Kiroku.Store.Observability (SubscriptionDeliveryPhase (..))
data SubscriptionDeliveryPhase
    = DeliveredCatchUp
    | DeliveredLive
    deriving stock (Eq, Show)

-- New additive constructor of KirokuEvent:
KirokuEventSubscriptionDelivered
    :: SubscriptionName
    -> Int                       -- ^ batch row count (>= 1)
    -> SubscriptionDeliveryPhase
    -> SubscriptionGroupContext
    -> KirokuEvent
```

**Edited, `kiroku-store` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`):** `processEvents` (signature unchanged) emits one `KirokuEventSubscriptionDelivered subName (V.length events) phase groupCtx` per batch, with `phase = case driving of CatchingUp{} -> DeliveredCatchUp; _ -> DeliveredLive`. `KirokuEventSubscriptionFetched` emissions in `liveLoopCategoryNotify` (`Worker.hs:471`) and `liveLoopDbDriven` (`Worker.hs:523`) are **retained** unchanged.

**Edited, `kiroku-otel` (`kiroku-otel/src/Kiroku/Otel/Subscription.hs`):**
- New span-name constants/exports: `spanDeliver :: Text = "kiroku.subscription.deliver"` (replacing `spanFetch`), `spanStopped :: Text = "kiroku.subscription.stopped"` (new). Attribute keys unchanged (`attrState`, `attrBatchRows`, `attrStopReason`, `attrCheckpoint`, `attrSubName`, etc.).
- `onEvent` gains a `KirokuEventSubscriptionDelivered name count phase grp` arm (opens+closes a `deliver` span tagged `state` from the phase and `attrBatchRows`; clears open retries as Ok on `DeliveredLive`).
- `KirokuEventSubscriptionFetched{} -> pure ()` (no-op, matched for exhaustiveness).
- `KirokuEventSubscriptionStopped` arm always opens+closes a standalone `spanStopped` span carrying `attrStopReason` + `attrCheckpoint` + base attrs, in addition to the existing stamp-and-close-open-spans behavior.
- C2 (Edit 7): the internal per-key span state changes from `MVar (Map SpanKey OpenState)` to `IORef (Map SpanKey (IORef OpenState))`; `subscriptionTraceHandler`/`onEvent`/`withKey`/`dropKey` are retyped to it and a small `cellFor` helper is added; the `Control.Concurrent.MVar` import is replaced by `Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)`. This is internal only — `SpanKey`, `OpenState`, the span-name/attribute exports, and the nine `onEvent` arms are unchanged.
- The library still depends only on `hs-opentelemetry-api` and `kiroku-store` — **no new library dependency** (C2 is `base`-only via `Data.IORef`; no `stm` or cabal change), and no `hs-opentelemetry` dependency added to `kiroku-store`. The change is purely read-side.

**Edited, `kiroku-otel` test (`kiroku-otel/test/Main.hs`, `kiroku-otel/kiroku-otel.cabal`):** `main` wrapped with `Kiroku.Test.Postgres.withSharedMigratedPostgres`. New DB-backed describe block using `withMigratedTestDatabase`, `Kiroku.Store.withStore` with `eventHandler = Just handler`, `subscribe`/`cancel`/`wait`, `appendToStream`, `defaultSubscriptionConfig name AllStreams handler` returning `Continue`. New test-stanza `build-depends`: `kiroku-test-support`, `ephemeral-pg`, `stm` (plus the already-present `kiroku-store`, `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-in-memory`, `hs-opentelemetry-api`).

**Read-only, unchanged:** `Kiroku.Store.Subscription.Fsm` (`SubscriptionState`), `Kiroku.Store.Subscription.Types` (`SubscriptionName`, `defaultSubscriptionConfig`, `SubscriptionResult`, `Target`), `Kiroku.Store.Connection` (`ConnectionSettingsM.eventHandler`, `defaultConnectionSettings`, `withStore`, `KirokuStore`), `Kiroku.Test.Postgres` (the harness).

**Parent MasterPlan:** `docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md` (this is its child plan 2 / EP-2; honor its Integration Points — this plan only *reads* `stateVar` inside `processEvents` and adds the `KirokuEvent` constructor, both of which the MasterPlan assigns to EP-2). **Prior tracer plan being completed:** `docs/plans/44-opentelemetry-tracing-of-subscription-worker-state-and-span-attributes-end-to-end-through-the-shibuya-adapter.md` (read its Surprises about export-on-end and its span model; this plan reuses that model and its in-memory-exporter test harness).


## Revision Notes

- 2026-05-31 — Pre-commitment audit cascade (parent MasterPlan `docs/masterplans/7-...`,
  2026-05-31). The audit confirmed **no deadlock** in the tracer and surfaced that the
  centralized per-batch delivery event puts span work on the catch-up hot path (and, with the
  single shared tracer `MVar`, serializes all workers) whenever a tracer is installed. The user
  chose to **keep catch-up deliver spans** and to **fold in C2** to remove the contention
  structurally. **The span-coverage design (the two gaps, the centralized delivery event, the
  tracer's deliver/stopped spans, the DB-backed test) is unchanged**; the one added change is
  C2, an internal performance fix: M2 gains **Edit 7 — striped per-key span state**, replacing
  the single shared `MVar (Map SpanKey OpenState)` with a lock-free
  `IORef (Map SpanKey (IORef OpenState))` (each `SpanKey` single-writer), `base`-only with no
  new dependency, no public API change, and `withKey`/`dropKey` kept call-compatible so the nine
  `onEvent` arms are untouched. Behavior is byte-identical (existing tests are the equivalence
  proof). Reflected in Progress (M2), Scope/What-exists, Context (span model), Decision Log
  (new C2 entry; updated catch-up and no-deadlock entries), M2 acceptance, Interfaces and
  Dependencies, and both CHANGELOG notes. Cross-plan: sibling plan `docs/plans/45-...` reshaped
  `currentState` to `m (Maybe SubscriptionState)`, but this plan does not use `currentState`
  (its end-to-end test drives `subscribe`/`cancel`/`wait` and reads spans) and its read of
  `stateVar` inside `processEvents` is undisturbed — so no change on that account.

- 2026-05-31 — Absorbed two framing refinements from the parent MasterPlan (`docs/masterplans/7-...`); **the design is unchanged** (all three milestones, the centralized-delivery-event approach, the tracer changes, and the database-backed end-to-end test are exactly as before). (1) **Pre-stable core primitive:** Purpose/Big Picture and Context and Orientation now frame `KirokuEventSubscriptionDelivered` and `SubscriptionDeliveryPhase` as committed, permanent additions to the core `KirokuEvent` API — introduced deliberately now because kiroku is pre-stable, with no back-compat constraint or deprecation cycle — and clarify that the separate "additive constructor set" property is about compile-time safety, not design hedging. (2) **Performant OTel synergy / complementary split:** Purpose, Context, and a new Decision Log entry now frame the per-batch `kiroku.subscription.deliver` spans as the timeline / correlation layer, with the subscription-state registry (sibling plan `docs/plans/45-...`, referenced by path only) as the performant live-state layer read at zero per-event cost; this sharpens why the per-batch deliver-span volume is acceptable (the cheap "is `$all` Live and advancing" signal lives in the registry's state + cursor position, not the span stream) and cross-references `docs/plans/44-...`'s note that per-batch spans are the first telemetry dropped under load. Two matching Decision Log entries (dated 2026-05-31) were added.
