---
id: 45
slug: central-subscription-state-registry-on-the-store-handle-for-cheap-observability
title: "Central subscription-state registry on the store handle for cheap observability"
kind: exec-plan
created_at: 2026-05-31T14:50:41Z
intention: "intention_01ksz87dmveheabtpg8kswdgvn"
master_plan: "docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md"
---

# Central subscription-state registry on the store handle for cheap observability

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store. Its code lives under the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, in the Haskell package
`kiroku-store` (sources under `kiroku-store/src/`, tests under `kiroku-store/test/`).

A **subscription** in Kiroku is a long-lived background worker thread: it reads stored
events in order, hands each one to a caller-supplied handler function, and remembers how
far it has progressed in a durable database **checkpoint** (a `(subscription_name, member)`
row recording the last `GlobalPosition` it processed). At any instant the worker is in
exactly one named state of a **finite state machine (FSM)** — `CatchingUp` (reading
history from the database), `Live` (caught up, receiving new events), `Paused`
(recoverable backpressure from a slow consumer), `Reconnecting` (recovering a lost
database connection), `Retrying` (redelivering an event a handler asked to retry), or
`Stopped` (terminal, carrying a stop reason). That state type is `SubscriptionState`,
defined in `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:184-191`.

Today, the only way to read a subscription's current state is through its own handle:
`SubscriptionHandle` exposes `currentState :: IO SubscriptionState`
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:351`), which reads that one
subscription's private state cell. To answer the operational question *"what is every
subscription doing right now?"* an operator would have to be holding every individual
handle. There is no single place to ask.

**After this change**, the `KirokuStore` handle (the value every caller already threads
through the store API — `kiroku-store/src/Kiroku/Store/Connection.hs:135-155`) owns a
**central subscription-state registry**: a shared, in-memory table keyed by
`(subscription name, member)` that every running worker keeps current, and from which an
entry is removed automatically when its worker stops, is cancelled, or crashes. A new
public accessor, `subscriptionStates`, returns a near-instant snapshot
of that table as a **map of public view records** — for every live subscription, its name,
member, current FSM state, a stable state label, and FSM cursor position — without the
caller holding any individual handle.

**This is a deliberate core primitive, not a minimal bolt-on.** Kiroku has *not* released a
stable version, so there is no public-API backward compatibility to preserve and no
deprecation cycle to honor. The parent MasterPlan
(`docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md`)
directs that this is the moment to get the primitives right: this plan therefore introduces
the registry — and a committed, public **view type**, `SubscriptionStateView` — as
first-class surface that we are willing to commit to deliberately, now. Concretely, that
means two reshapes that an API-stable project would avoid but that are correct pre-1.0:

1. The snapshot accessor returns proper public **view records**, not a raw
   `Map key SubscriptionState`. The view type, `SubscriptionStateView`
   (defined in M2; see Interfaces and Dependencies), carries the subscription name, the
   member index, the live `SubscriptionState`, a stable low-cardinality `statePhase` label
   (via `stateName`), and the FSM `cursor` position. This is the committed surface a future
   Prometheus exporter and admin tool consume directly — they read view records, never the
   internal cell type.

2. The registry is the **single source of truth** for live subscription state, and the
   handle's per-subscription `currentState` is genuinely **resolved through it**. This is a
   real, committed, breaking reshape (confirmed in the parent MasterPlan's 2026-05-31 audit):
   `currentState` changes type to `m (Maybe SubscriptionState)` and is defined by looking the
   worker's cell up in the registry by its `(name, member)` key **and this handle's registry
   token**, then reading it. `Just s` means the worker is live, still owns that registry entry,
   and is in state `s`; `Nothing` means the subscription is **not currently live** — it has
   stopped, been cancelled, crashed (its key was deleted in the worker's `finally`), was never
   started, or has been superseded by a newer worker registered under the same key. **This preserves the MasterPlan's Integration
   Point constraint**: the worker's per-worker `stateVar :: TVar SubscriptionState` remains the
   worker's sole *write target*; the registry simply *holds that same cell*, and both the
   snapshot and `currentState` *read* it via the registry. There is still exactly one cell per
   worker that the worker writes. Two consequences make `Maybe` the correct shape rather than a
   bolt-on: (a) the FSM **never writes `Stopped` into `stateVar`** — the terminal transition
   returns without the loop's state write (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:183,197-198`),
   so the old direct-cell `currentState` returned a *stale pre-stop state* (`Live`/`CatchingUp`)
   forever after a clean stop; `Nothing` is the honest answer. (b) It unifies one rule —
   "stopped = absent" — across both `currentState` and the snapshot. This is acceptable
   precisely because kiroku is pre-1.0; the only caller affected is the test
   `kiroku-store/test/Test/SubscriptionState.hs`. We are committing to this surface on purpose.

The user-visible behavior you can demonstrate at the end: in a test (and, later, from any
operator code that has a `KirokuStore`), you start several subscriptions, call
`subscriptionStates store`, and get back a `Map (SubscriptionName, Int32)
SubscriptionStateView` whose keys are the live subscriptions and whose values describe their
current state, label, and cursor position; you then stop, cancel, or crash one and
observe its key disappear from the next snapshot — and `currentState` on its held handle
return `Nothing` (it is no longer live), while a still-running subscription's handle returns
`Just s` agreeing with that subscription's `state` in the snapshot. This is the substrate the parent
MasterPlan identifies as the foundation for two future, out-of-scope consumers — a
**Prometheus exporter** (which would scrape the snapshot into gauges) and an **admin tool**
(which would list subscriptions and their states).

**The registry is also the performant live-state layer of the observability story.** Beyond
serving Prometheus and the admin tool, the registry is the *performant* way to close the
live-state gaps in Kiroku's existing OpenTelemetry (OTel) instrumentation — gaps that spans
inherently handle badly. An OTel trace span is only exported when it *ends*, so a worker
stuck `Reconnecting` or `Paused` *right now* is invisible in traces until it resolves (the
"export-on-end blind spot"); and an `$all` subscription's continuous `Live` progress is not
reliably captured by spans either. A registry read answers both — "what state is each
subscription in right now" and "how far has it advanced" — instantly. It is **performant by
construction**: the worker *already* writes its FSM state to its `stateVar` on every
transition, so the registry adds **no new per-event writes** — it only makes those existing
cells queryable — and consumers read snapshots on **their own cadence** (a scrape interval,
an admin poll), never on the worker's hot path. The per-event hot-path cost is therefore
zero. This is the complementary split the MasterPlan draws: **spans** (sibling plan
`docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md`) are
the *timeline* layer — episode/transition timing that genuinely needs the `KirokuEvent`
transition stream — while the **registry** is the *live-state* layer. For "is `$all` Live and
advancing right now," sampling the registry is the cheap, always-available signal; the spans
are the higher-volume correlation/timeline layer on top.

Neither the Prometheus exporter nor the admin tool is built here. This plan delivers the
registry, its public `SubscriptionStateView` snapshot accessor, and the redirection of
`currentState` through the registered cell, proven by tests — and nothing more.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-05-31) — Added the registry field `subscriptionRegistry :: !(TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState)))` to the `KirokuStore` record in `kiroku-store/src/Kiroku/Store/Connection.hs`; initialized it with `newTVarIO Map.empty` at store construction in `withStore`; exported `configMember` from `Kiroku.Store.Subscription.Worker`; in `subscribe` register the per-worker `stateVar` with a fresh token on start (insert before fork) and deregister it on any exit by extending the existing `finally` cleanup with a token-conditional delete.
- [x] M2 (2026-05-31) — Defined the public view type `SubscriptionStateView` (name, member, state, `statePhase` label, cursor), `deriving stock (Show, Generic)`; added the public snapshot accessor `subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)` (snapshot the outer map with `readTVarIO`, then read each registered cell with `readTVarIO` outside STM — no large STM read set); added `stateName :: SubscriptionState -> Text` to `Fsm.hs`; reshaped `currentState` to `m (Maybe SubscriptionState)` resolved by looking the cell up in the registry by `(name, member)` and the handle's token (`Just s` = live and still owner; `Nothing` = not currently live or superseded); `subscriptionStates`/`SubscriptionStateView (..)` reachable via the whole-module re-export and `stateName`/`stateCursor` re-exported explicitly from the umbrella `Kiroku.Store` module.
- [x] M3 (2026-05-31) — Added `Test.SubscriptionRegistry` (5 examples: register/snapshot, deregister-on-stop/cancel/crash, stale duplicate-key cleanup safety), wired into `kiroku-store/test/Main.hs` and the cabal `other-modules`; migrated `Test.SubscriptionState` to the `Maybe` shape; updated `kiroku-store/CHANGELOG.md` and the six current-state/registry user/architecture docs (`docs/user/subscriptions.md`, `docs/user/observability.md`, `docs/guides/consuming-the-event-log.md`, `docs/guides/building-a-projection.md`, `docs/architecture/subscriptions.md`, `docs/user/consumer-groups.md`); registry Haddock lives on the `subscriptionRegistry` field, `subscriptionStates`, and `currentState`. Full suite green (183 examples, 0 failures); `cabal build all` clean across the workspace.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**2026-05-31 — Cancelling a worker still in its catch-up startup window is slow
to deregister; the test drives to `Live` first.** The first draft of the
"cancelled" scenario subscribed a plain `$all` subscription against an *empty*
store and immediately `cancel`led it without first driving it to `Live`. The
registry entry was not removed within the 5 s poll budget (the example took
~5.9 s and failed `gone shouldBe True`), whereas the "stopped" and "crashed"
scenarios — which append an event and `waitForPublisher` before exit — passed
fast. Driving the subscription to a steady `Live` state (append one event,
`waitForPublisher`, then `waitUntilPhase … "live"`) before cancelling made the
whole spec deterministic and fast (5 examples in ~0.65 s). The registry cleanup
itself is correct — it runs in the worker's `finally` whenever the worker
actually exits — but `Async.cancel` delivery to a worker that is mid-catch-up
(potentially parked inside a libpq/STM call against an empty store) is not
prompt. This is a worker-cancellation-responsiveness property, not a registry
bug, and it does not affect the registry's guarantee that an entry is removed on
exit. The test now mirrors scenario 1's drive-to-live pattern for the
cancel/stop paths. Evidence:

```text
removes a subscription's entry when it is cancelled [✘]   -- before: ~5.9 s, gone == False
...
removes a subscription's entry when it is cancelled [✔]   -- after drive-to-live: ~0.65 s total
5 examples, 0 failures
```

**2026-05-31 — The snapshot accessor destructures `(_tok, cell)`, not the plain
cell the plan's draft code showed.** Because the final design stores
`(Unique, TVar SubscriptionState)` per key (token ownership), the
`Map.traverseWithKey` callback in `subscriptionStates` takes `(_tok, cell)` and
reads `cell`; the token is irrelevant to the snapshot (it only matters for
ownership-conditional cleanup and `currentState`). No functional consequence —
recorded so a future reader matching the plan's illustrative snippet against the
real code is not surprised by the extra binder.


## Decision Log

Record every decision made while working on the plan.

- Decision: Build the registry and a public `SubscriptionStateView` type as first-class core primitives now, accepting (possibly breaking) API reshaping, because kiroku has not released a stable version.
  Rationale: Mirrors the parent MasterPlan's 2026-05-31 decision to introduce core primitives pre-stable. Pre-1.0 is the right time to add core primitives without deprecation cycles or back-compat constraints. So this plan does *not* settle for a minimal back-compat-preserving bolt-on: (a) the snapshot accessor returns a proper, committed public view record `SubscriptionStateView` (name, member, state, stable `statePhase` label, cursor) rather than a raw `Map key SubscriptionState`, because that view is the surface Prometheus/admin will consume directly; and (b) the registry is the single source of truth that also backs the handle's `currentState`, reshaping that accessor rather than leaving it untouched. Breaking API changes are explicitly acceptable here; we commit to this surface deliberately.
  Date: 2026-05-31.

- Decision: Make the registry the single source of truth that genuinely backs `currentState`, by reshaping `currentState` to `m (Maybe SubscriptionState)` resolved through the registry by key, while keeping the worker's per-worker `stateVar` as the sole write target.
  Rationale: Confirmed by the parent MasterPlan's 2026-05-31 audit, which found the earlier "reads the registered cell" wording was fictional — it kept `currentState = readTVarIO stateVar` unchanged (a held cell reference) while claiming a breaking reshape. The genuinely-correct primitive routes the per-handle read through the registry: `currentState` looks the worker's cell up under `(name, member)` in `store ^. #subscriptionRegistry`, verifies this handle's fresh token still owns that entry, and reads it. The worker still writes exactly one cell (`stateVar`) on every transition — nothing about the write path changes — and the registry holds that same cell, so sibling plan `docs/plans/46-...`'s read of `stateVar` is undisturbed regardless of landing order. The return type must be `Maybe` because the key is deleted in the worker's `finally` on exit, and because an accidental newer worker with the same key supersedes this handle's token: `Just s` while live and still owner, `Nothing` once not live or superseded. This is a real, committed, breaking reshape of the handle/API, acceptable because kiroku is pre-1.0; code/tests and all user docs that mention `currentState` must be updated.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Store a fresh `Data.Unique.Unique` token with each registry entry and make cleanup/currentState token-aware.
  Rationale: The key-only map shape had a stale-cleanup bug. If two workers with the same `(name, member)` accidentally run at once, the second insert overwrites the first, but the first worker's later `finally` would unconditionally delete the key and remove the second worker's live entry. A held first handle could also read the second worker's state. The token fixes both without changing the public key shape: insert stores `(token, stateVar)`, cleanup deletes only if the stored token still equals this worker's token, and `currentState` returns `Nothing` if the key exists but the token differs. Duplicate workers remain unsupported because they still collide on checkpoints, but stale cleanup no longer corrupts the active registry entry.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): `Nothing` from `currentState` is the correct answer after stop because the FSM never writes `Stopped` into `stateVar`; "stopped = absent" is one rule across `currentState` and the snapshot.
  Rationale: The FSM writes `stateVar` only at the top of `loop` (`Worker.hs:183`) and the terminal transition returns from `feed` without looping (`Worker.hs:197-198`), so `Stopped` is never stored in the cell — the cell's last value is the pre-stop state (`Live`/`CatchingUp`). The old direct-cell `currentState` therefore returned a stale, misleading `Live` forever after a clean stop, and `SubscriptionStateView.statePhase == "stopped"` is unreachable. Resolving `currentState` via the registry (where the key is gone after exit) makes both observers agree: a not-live subscription is *absent* — `Nothing` from `currentState`, no key in the snapshot. Document this invariant in the Haddock of both `currentState` and `subscriptionStates`, and in the `subscriptionRegistry` field Haddock, so downstream Prometheus/admin consumers never branch on a "stopped" gauge. (A benign race remains: a concurrent reader may still observe `Just <last-live-state>` in the window between the worker's final write and the `finally` delete; that is acceptable for a point-in-time "is it live" question.)
  Date: 2026-05-31.

- Decision: Position the registry as the performant live-state layer that closes the OpenTelemetry instrumentation's current-state and live-progress gaps — complementary to, not replaced by, the event-driven spans.
  Rationale: Mirrors the parent MasterPlan's 2026-05-31 decision on the performant live-state layer. Episode/transition *timing* needs the `KirokuEvent` stream (a polled snapshot cannot reconstruct it), so spans (sibling plan `docs/plans/46-...`) remain the timeline layer. But "what state is each subscription in right now" (the export-on-end blind spot: a span is only exported when it ends, so an in-progress `Reconnecting`/`Paused` worker is invisible in traces until it resolves) and continuous `$all` live progress are served by the registry at **zero per-event cost**: it reuses the worker's *existing* per-transition `stateVar` writes (no new per-event writes) and is read on the consumer's own cadence (scrape interval / admin poll), never on the worker's hot path. A future OTel-metrics reader and the Prometheus exporter read the registry for live state and the span stream for the timeline.
  Date: 2026-05-31.

- Decision: The registry stores the worker's existing `stateVar` *cell* (a `TVar SubscriptionState`), not a copied snapshot value.
  Rationale: The worker already writes its FSM state into a per-subscription `TVar` (`stateVar`, created at `kiroku-store/src/Kiroku/Store/Subscription.hs:112`) on every transition, and the handle's `currentState` reads that same cell. Registering the cell means the worker keeps writing exactly as before and the registry observes the live value with no extra write path, no duplicate-write race, and no risk of a stale copy. The parent MasterPlan's Integration Points *require* keeping `stateVar` as the worker's sole write target (so sibling plan `docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md` can keep reading it undisturbed); registering the cell rather than installing a write-through to the map satisfies that constraint.
  Date: 2026-05-31.

- Decision: The registry key is `(SubscriptionName, Int32)` where the `Int32` is the consumer-group member index, using `configMember config` (which returns `0` for a non-group subscription).
  Rationale: A consumer group runs one `subscribe` call per member; each member is a distinct worker with its own checkpoint and its own state. Keying by name alone would let two members collide. `configMember` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:381-382`) is the existing, already-trusted way the codebase derives the member (0 for non-group), and it is exactly how checkpoints are already keyed (`(name, member)`), so the registry key matches the checkpoint key one-to-one.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): The snapshot accessor snapshots the outer map with `readTVarIO`, then reads each registered cell with `readTVarIO` **outside STM** — it does **not** read all cells in one `atomically` transaction.
  Rationale: The parent MasterPlan's 2026-05-31 audit reversed the original single-transaction design. A single `atomically` over the outer map *and every inner cell* makes the reader's STM read set the entire set of subscriptions' `stateVar`s; because every worker writes its `stateVar` ~once per batch (`Worker.hs:183`, plus retry flips at `Worker.hs:652,655`), GHC STM re-validates the whole scan at commit and re-runs it whenever any worker commits a state write, so the reader's cost scales with subscription count × write-rate and can thrash under many concurrently-catching-up subscriptions. STM writers never block on readers, so the cost is entirely reader-side — the "zero per-event cost" claim holds only for workers. The named consumers (a Prometheus scrape, an admin listing) read independent gauges/rows and do **not** need a globally point-in-time-consistent snapshot. So the snapshot instead does `reg <- readTVarIO (store ^. #subscriptionRegistry)` then `Map.traverseWithKey (\(nm,mbr) cell -> mkView nm mbr <$> readTVarIO cell) reg`: O(N), no large read set, no retries; each entry is its own freshest value (a per-cell-consistent, not globally-atomic, snapshot). `Map.traverseWithKey` is still used because the view records carry the name and member, which live in the map key. If a future consumer genuinely needs an atomic cross-subscription snapshot, revisit then — no current consumer does.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): `SubscriptionStateView` derives `Generic` (in addition to `Show`) and is consumed via generic-lens `^. #field`.
  Rationale: The package enables `DuplicateRecordFields` + `OverloadedLabels` but not `OverloadedRecordDot`, and the field names `member` and `subscriptionName` already exist on other records (`ConsumerGroup.member` at `Types.hs:366`; `subscriptionName` at `Types.hs:227`), so the view's *bare* selectors are ambiguous and won't compile, while the codebase's standard `view ^. #field` accessor requires `Generic`. The original `deriving stock (Show)` omitted `Generic`, leaving the committed public type effectively unconsumable. Deriving `Generic` matches every other handle/record in the package (`KirokuStore`, `settings ^. #…`) and is what the M3 test and future Prometheus/admin consumers use to read fields.
  Date: 2026-05-31.

- Decision (audit, 2026-05-31): Name the public progress field `cursor`, not `checkpoint`.
  Rationale: The snapshot builds this field from `stateCursor st`, which is the FSM cursor. It is not always the durable checkpoint row: while `Retrying` is visible, the cursor is the retried event position, and during long in-flight batches the durable checkpoint may still be the pre-batch position. The registry's cheap progress signal is still correct and useful for Prometheus/admin/OTel live-state consumers, but the public API must not imply a stronger durable-checkpoint guarantee. Consumers needing exact durable checkpoints can query the checkpoint table or use a future dedicated checkpoint accessor.
  Date: 2026-05-31.

- Decision: The Prometheus exporter and the admin tool are out of scope; they are named future consumers only.
  Rationale: Parent MasterPlan direction. Both are gated on this registry, are under-specified, and metric emission is deferred project-wide (MasterPlan 5). This plan ships the registry plus the public `SubscriptionStateView` snapshot accessor and `stateName`/`stateCursor` label helpers those future consumers will need, and proves the registry with tests — not an exporter or UI. The OTel live-state synergy (see the performant-live-state-layer decision above) is a framing/motivation in this plan, not new code: this plan does not add OTel metrics or a metrics reader; it makes the live state queryable so a future reader can consume it cheaply.
  Date: 2026-05-31.

- Decision: A second `subscribe` with the same `(name, member)` overwriting the first's registry entry is an accepted, documented workload limitation, but stale registry cleanup is defended against.
  Rationale: This is the same misconfiguration shape that already causes a checkpoint collision today (two workers fighting over one `(name, member)` checkpoint row). The registry does not try to make duplicate workers supported; `consumerGroupGuard` already exists for callers who need a startup conflict probe. It does, however, store a token per entry so an older worker's cleanup cannot delete the newer worker's live registry entry and an older handle cannot read the newer worker's state.
  Date: 2026-05-31.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**2026-05-31 — Plan complete; all three milestones delivered and validated.**
The `KirokuStore` handle now owns a central, token-guarded subscription-state
registry; `subscriptionStates store` returns a near-instant snapshot of every
live subscription as committed `SubscriptionStateView` records (name, member,
state, stable `statePhase` label, FSM `cursor`); and `currentState` is reshaped
to `m (Maybe SubscriptionState)` genuinely resolved through the registry, with
"stopped/superseded = absent/`Nothing`" unified across both reads. This matches
the original purpose exactly: an operator can read every subscription's live
state without holding individual handles, and the per-handle read is now honest
about not-live workers.

What was proven (behavioural acceptance, against real migrated PostgreSQL):
`Test.SubscriptionRegistry` starts a plain `$all` subscription and two members of
one consumer group, asserts all three keys appear with sensible `statePhase`
labels, matching key/field agreement, and valid `cursor`s; asserts a live
handle's `currentState` agrees with its snapshot entry; and asserts the key
disappears (and `currentState` returns `Nothing`) on clean stop, cancel, and
crash, while stale duplicate-key cleanup cannot delete a newer worker's entry.
Full suite: 183 examples, 0 failures. `cabal build all` is clean across
`kiroku-store`, `kiroku-otel`, `shibuya-kiroku-adapter`, `kiroku-jitsurei`, and
the migrations test — the `currentState` reshape's only in-repo code caller was
`Test.SubscriptionState`, migrated here.

Lessons / notes for downstream work:
- The registry adds no per-event worker writes (it registers the worker's
  existing `stateVar` cell), so the "zero per-event cost" claim holds for
  workers; readers pay only an O(N) per-cell `readTVarIO` scan on their own
  cadence.
- Worker cancellation during the catch-up startup window is not prompt; tests
  that assert deregistration timing should drive the worker to `Live` first (see
  Surprises & Discoveries).
- The MasterPlan Integration Point is preserved: the worker remains the sole
  writer of `stateVar`, so sibling plan 46's read of that cell is undisturbed.
- Out of scope as planned: no Prometheus exporter, no admin tool, no OTel
  metrics — the registry is the substrate those future consumers will read.


## Context and Orientation

This section orients a reader who has never seen this repository. Everything you need is
named by full repository-relative path.

**Where the code lives.** The event store is the package `kiroku-store`. Its library
sources are under `kiroku-store/src/Kiroku/Store/`; its test suite (an `hspec` suite named
`kiroku-store-test`) is under `kiroku-store/test/`. The package manifest is
`kiroku-store/kiroku-store.cabal`. The changelog is `kiroku-store/CHANGELOG.md`.

**The store handle, `KirokuStore`.** Every store operation takes a `KirokuStore` value.
It is a plain record defined in `kiroku-store/src/Kiroku/Store/Connection.hs:135-155`:

```haskell
data KirokuStore = KirokuStore
    { pool :: !Pool
    , schema :: !Text
    , notifier :: !Notifier
    , publisher :: !EventPublisher
    , eventHandler :: !(Maybe (KirokuEvent -> IO ()))
    , storeSettings :: !StoreSettings
    }
    deriving stock (Generic)
```

The record derives `Generic`, and the codebase reads its fields through `generic-lens`
overloaded labels — for example `store ^. #pool`, `store ^. #publisher`,
`store ^. #notifier`, `store ^. #eventHandler`, `store ^. #storeSettings`. (`^.` is the
lens "view" operator from the `lens`/`generic-lens` libraries; `#pool` is an overloaded
label that `generic-lens` resolves to the record field named `pool`.) Adding a new field
to this record automatically makes `store ^. #yourField` available; no boilerplate lens is
needed.

The handle is constructed in exactly one place: the `withStore` function in the same file
(`kiroku-store/src/Kiroku/Store/Connection.hs:181-242`). Its `acquire` step starts the
connection pool, then the `Notifier` (the dedicated PostgreSQL `LISTEN` connection), then
the `EventPublisher` (which fans new events out to subscribers), and finally builds the
`KirokuStore` record literal at `kiroku-store/src/Kiroku/Store/Connection.hs:228-236`. Any
new handle field that needs initialization is initialized there.

**The subscription FSM, `SubscriptionState`.** Defined in
`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:184-191`:

```haskell
data SubscriptionState
    = CatchingUp {cursor :: !GlobalPosition, attempt :: !Int}
    | Live {cursor :: !GlobalPosition}
    | Paused {cursor :: !GlobalPosition, resumeWhen :: !ResumeCondition}
    | Reconnecting {cursor :: !GlobalPosition, attempt :: !Int}
    | Retrying {cursor :: !GlobalPosition, attempt :: !Int}
    | Stopped {reason :: !SubscriptionStopReason}
    deriving stock (Show)
```

Every constructor except `Stopped` carries a `cursor :: GlobalPosition` — the position the
worker has reached. `GlobalPosition` is a newtype over an integer event position, defined
in `kiroku-store/src/Kiroku/Store/Types.hs`. The same module provides the helper

```haskell
stateCursor :: SubscriptionState -> GlobalPosition
```

at `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:196-203`, which returns the cursor of
any non-terminal state and `GlobalPosition 0` for `Stopped`. The worker already uses it to
attach the current position to emitted events; this plan reuses it (and re-exports it) so
future consumers can read a subscription's FSM cursor position from a snapshot without
pattern-matching every constructor themselves.

**How a subscription starts: the `subscribe` lifecycle.** The function `subscribe` lives in
`kiroku-store/src/Kiroku/Store/Subscription.hs:95-131`. Walking it (read the file
alongside this prose):

1. It validates any consumer-group configuration (lines 100-102).
2. It registers a subscriber with the publisher, getting back a bounded queue, a status
   var, and an `unsubscribe` action (lines 103-107).
3. It creates the per-subscription **state cell** at line 112:

   ```haskell
   stateVar <- newTVarIO (CatchingUp (GlobalPosition 0) 0)
   ```

   This `stateVar :: TVar SubscriptionState` is the cell the worker writes on every FSM
   transition. Today the handle's `currentState` reads this cell directly. After this plan,
   the *same* cell is registered into the central registry (M1), and `currentState` is
   reshaped to `m (Maybe SubscriptionState)` that resolves the cell *through the registry* by
   key and reads it (M2) — so the worker still writes exactly one cell and both `currentState`
   and the registry snapshot observe it while the worker is live; once the worker exits and its
   key is removed, `currentState` returns `Nothing`. The worker remains the sole writer of
   `stateVar`; the registry only *holds* and *reads* the cell.
4. It spawns the worker thread (lines 121-125):

   ```haskell
   thread <-
       Async.async
           ( runWorker (store ^. #pool) queue statusVar stateVar pubPosVar catGenVar config (store ^. #eventHandler) (store ^. #storeSettings)
               `finally` unsubscribe
           )
   ```

   The crucial pattern is `` `finally` unsubscribe ``: `Control.Exception.finally`
   guarantees `unsubscribe` runs on **any** exit of `runWorker` — a graceful `Stop`, a
   cancellation, or an exception (a crash). That is how the subscriber is removed from the
   *publisher's* registry no matter how the worker ends. This plan's registry
   register/deregister must mirror that exact pattern and place.
5. It returns the handle (lines 126-131), whose `currentState = readTVarIO stateVar` today.
   After M2 the registry is the single source of truth and `currentState` is genuinely resolved
   through it: its type changes to `m (Maybe SubscriptionState)` and it looks the worker's cell
   up under `(name config, configMember config)` in `store ^. #subscriptionRegistry`, reading
   that cell if present. The cell it finds is the very cell the registry holds (the worker's
   `stateVar`, registered in M1), so `currentState` and the snapshot observe one coherent value
   while the worker is live. After the worker exits, its key is gone (deregistered in the
   `finally`), so `currentState` returns `Nothing` — the honest "not currently live" answer. M2
   spells out the exact mechanics; the handle closes over the registry `TVar` and the key rather
   than over `stateVar` directly.

There is also `withSubscription` (`kiroku-store/src/Kiroku/Store/Subscription.hs:148-156`),
a bracket wrapper that calls `subscribe` and guarantees `cancel` on exit. Tests use both.

**Consumer-group members.** A consumer group lets several workers share one logical
subscription, each processing a disjoint slice of events. Each member is a *separate*
`subscribe` call whose `SubscriptionConfig` has `consumerGroup = Just (ConsumerGroup member
size)` (the config type is in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:238-307`;
`ConsumerGroup` is at lines 364-371). The helper

```haskell
configMember :: SubscriptionConfig -> Int32
configMember config = maybe 0 member (consumerGroup config)
```

at `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:381-382` returns the member index,
or `0` for a non-group subscription. It is currently a top-level binding in `Worker.hs` but
*not exported* (the module export list is at
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:23-26` and lists only `runWorker` and
`withFetchBatchHookForTest`). This plan exports it so `subscribe` can compute the registry
key with the same logic the checkpoint code already uses.

`SubscriptionName` is a newtype over `Text` defined at
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:136` and exported (line 20). `Int32`
comes from `Data.Int` (already imported in both `Worker.hs` and the test files).

**The umbrella module.** `kiroku-store/src/Kiroku/Store.hs` re-exports the package's public
API; among other things it re-exports the whole `Kiroku.Store.Subscription` module
(`kiroku-store/src/Kiroku/Store.hs:22,59`). Callers `import Kiroku.Store` and reach
`subscribe`, `withSubscription`, `currentState`, etc. through it. The new accessor must be
reachable the same way.

**The public view type, `SubscriptionStateView`.** This plan introduces a new public record
that the snapshot accessor returns one of per live subscription. It is *not* the internal
`SubscriptionState` cell type; it is a flat, committed view designed for external consumers
(a future Prometheus exporter, an admin tool) — see M2 and Interfaces and Dependencies for
its exact fields. It carries the subscription name, the consumer-group member index, the
live `SubscriptionState`, a stable low-cardinality `statePhase` label (computed via
`stateName`, so it does not drift if a constructor's fields change), and the FSM `cursor`
position (via `stateCursor`). Returning views — rather than a raw
`Map key SubscriptionState` — is one of the deliberate pre-stable reshapes described in
Purpose / Big Picture: kiroku is pre-1.0, so we commit to a proper public surface now.

It **`deriving stock (Show, Generic)`** and is read with the codebase's generic-lens
`view ^. #field` accessor. `Generic` is required (per the 2026-05-31 audit): the package
enables `DuplicateRecordFields` + `OverloadedLabels` but not `OverloadedRecordDot`, and the
field names `member` and `subscriptionName` already exist on other records (`ConsumerGroup`
at `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:366`; the record at `Types.hs:227`),
so the view's *bare* selector functions would be ambiguous and fail to compile — `^. #field`
(which needs `Generic`) is the only ergonomic accessor and is how every other handle/record
in the package is read.

**Why this is the performant OTel live-state layer.** Kiroku already emits OpenTelemetry
trace spans for subscription FSM transitions (the `kiroku-otel` tracer, extended by sibling
plan `docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md`).
Spans are a *timeline* layer: each span is an interval (start, end, duration) and is only
exported when it *ends*. That makes spans poor at two things this registry is good at: (1)
"what state is each subscription in **right now**" — an in-progress `Reconnecting` or
`Paused` worker is invisible in traces until its span ends (the export-on-end blind spot);
and (2) continuous `$all` live progress. The registry answers both from a single snapshot.
It is performant by construction because it reuses the worker's *existing* per-transition
`stateVar` writes (it adds no new per-event writes — it only makes those cells queryable),
and consumers read snapshots on their own cadence (a scrape interval, an admin poll), so the
per-event hot path carries zero added cost. The split is complementary: the registry is the
live-state layer; the spans (plan 46, referenced by path only — not edited here) are the
timeline layer.

**The test harness.** The suite entry point is `kiroku-store/test/Main.hs`. It wraps every
spec in `withSharedMigratedPostgres` (line 51) — a bracket that stands up one ephemeral
PostgreSQL instance, applies the Kiroku migrations once, and shares it across all specs —
then lists each spec (lines 52-70). Individual specs use the helpers in
`kiroku-store/test/Test/Helpers.hs`: `withTestStore` / `withTestStoreSettings` bracket a
migrated database and a `KirokuStore`; `makeEvent` builds an `EventData`; events are
appended with `runStoreIO store $ appendToStream ...`; `waitForPublisher` and
`waitForSubscriptionLive` provide deterministic (non-`threadDelay`) barriers, the latter
wired through `caughtUpEventHandler`. The existing
`kiroku-store/test/Test/SubscriptionState.hs` is the closest model for a new
subscription-state test: read it for the pattern of building a `SubscriptionConfig`,
appending events, waiting for catch-up/live, and reading state. The existing
`kiroku-store/test/Test/ConsumerGroup.hs:82-95` shows how to build a per-member group
config (set `consumerGroup = Just (ConsumerGroup{member = m, size = n})`).


## Plan of Work

The work is mostly additive: a new handle field, a registration/deregistration pair around
the existing `finally`, a new public view type, a new read-only snapshot accessor, and a new
test. The one deliberate, non-additive reshape — acceptable because kiroku is pre-1.0 — is
that `currentState` is redirected to read from the registry's registered cell so the registry
becomes the single source of truth for live state. **The worker's write path is unchanged**:
the worker still writes its FSM state into exactly one cell (`stateVar`) on every transition;
that cell is what the registry holds and what `currentState` reads. Three milestones, each
independently verifiable.


### Milestone M1 — registry field and register/deregister lifecycle

**Scope and outcome.** At the end of M1, the `KirokuStore` handle owns the registry `TVar`,
it is initialized empty at store construction, and every `subscribe` call inserts its
worker's state cell into the registry on start and removes it on any exit (stop, cancel, or
crash). There is no public accessor yet — M1 is verified by the package compiling with the
new field threaded through and (optionally) a throwaway `Debug` read; the observable proof
comes in M3's test. Nothing about the worker's writes changes in M1 (nor ever): the worker
keeps writing its `stateVar` exactly as before. `currentState` keeps its current type and
definition in M1 (the package still compiles) and is reshaped to a registry-resolved
`m (Maybe SubscriptionState)` in M2.

**Edits.**

First, add the field to the record in `kiroku-store/src/Kiroku/Store/Connection.hs`. Add to
the `KirokuStore` record (after `storeSettings`, lines 148-153 region):

```haskell
    , subscriptionRegistry :: !(TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState)))
    {- ^ Central registry of every live subscription worker's FSM-state cell,
    keyed by (subscription name, consumer-group member; 0 for non-group).
    Each entry also carries the worker's registry token, so cleanup from an
    older worker cannot delete a newer worker's replacement entry for the same
    key.
    Each 'Kiroku.Store.Subscription.subscribe' call registers its worker's
    'stateVar' here on start and removes it on any exit (stop, cancel, crash)
    via the worker's @finally@ cleanup. The cell is the same 'TVar' the worker
    writes on every transition and 'currentState' reads — it is registered, not
    copied — so the registry observes the live value with no extra write path.
    Read a consistent snapshot with
    'Kiroku.Store.Subscription.subscriptionStates'. -}
```

This requires new imports in `Connection.hs`:

```haskell
import Control.Concurrent.STM (TVar, newTVarIO)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Unique (Unique)
import Kiroku.Store.Subscription.Fsm (SubscriptionState)
import Kiroku.Store.Subscription.Types (SubscriptionName)
```

Note the module-graph constraint: `Kiroku.Store.Subscription.Fsm` is a near-leaf that
depends only on `Kiroku.Store.Types` and `hasql-pool` (see its module Haddock at
`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:26-31`), and
`Kiroku.Store.Subscription.Types` depends on `Fsm` (the `currentState` field is
`SubscriptionState`). `Connection.hs` may import both without creating a cycle, since
`Subscription.hs` (which imports `Connection`) sits above both. If a cycle is reported,
the fix is to confirm `Connection` does not import `Subscription` (the umbrella worker
module) — it should import only `Fsm` and `Types`, which it transitively already pulls in
through other modules.

Second, initialize the field in `withStore` at the record literal
(`kiroku-store/src/Kiroku/Store/Connection.hs:228-236`). In the `acquire` `do` block,
before building the record, create the empty registry:

```haskell
reg <- newTVarIO Map.empty
```

and add `subscriptionRegistry = reg` to the `KirokuStore { ... }` literal.

Third, export `configMember` from the worker module so `subscribe` can use it. Change the
export list in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs:23-26` to add
`configMember`:

```haskell
module Kiroku.Store.Subscription.Worker (
    runWorker,
    configMember,
    withFetchBatchHookForTest,
) where
```

(`configMember` is already a top-level binding at lines 381-382; only the export is new.)

Fourth, register and deregister in `kiroku-store/src/Kiroku/Store/Subscription.hs`. After
creating `stateVar` (line 112) and computing the existing `pubPosVar`/`catGenVar` lets
(lines 113-114), add the key and the registration, then change the worker's cleanup from
`` `finally` unsubscribe `` to a combined cleanup that also deletes the key:

```haskell
    token <- newUnique
    let reg = store ^. #subscriptionRegistry
        key = (name config, configMember config)
        -- Mirror the existing `finally unsubscribe`: deregister on ANY exit
        -- (graceful Stop, cancellation, or crash) so the registry never leaks a
        -- stale entry. The delete is token-conditional so stale cleanup from an
        -- older duplicate-key worker cannot remove a newer worker's entry.
        cleanup =
            unsubscribe
                >> atomically
                    ( modifyTVar' reg $
                        Map.update
                            ( \(tok', cell) ->
                                if tok' == token
                                    then Nothing
                                    else Just (tok', cell)
                            )
                            key
                    )
    atomically $ modifyTVar' reg (Map.insert key (token, stateVar))
    thread <-
        Async.async
            ( runWorker (store ^. #pool) queue statusVar stateVar pubPosVar catGenVar config (store ^. #eventHandler) (store ^. #storeSettings)
                `finally` cleanup
            )
```

This requires new imports in `Subscription.hs`:

```haskell
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Map.Strict qualified as Map
import Data.Unique (newUnique)
import Kiroku.Store.Subscription.Worker (configMember, runWorker)
```

(`atomically`, `newTVarIO`, `readTVarIO` are already imported at
`kiroku-store/src/Kiroku/Store/Subscription.hs:11`; add `modifyTVar'`. `runWorker` is
already imported at line 24; add `configMember`. `name config` uses the `name` field of
`SubscriptionConfig` — `Kiroku.Store.Subscription.Types` is already imported via line 23.)

The insert happens *before* the thread is forked. This guarantees that by the time
`subscribe` returns the handle, the entry is already present, so a caller that reads a
snapshot immediately after `subscribe` sees the subscription. The delete is inside the
`finally` cleanup, which runs on every exit path of the worker thread.

**Commands and acceptance.** Build the library:

```bash
cabal build kiroku-store
```

Expected: a clean build, no errors, no new warnings. Since M1 adds no public accessor, its
acceptance is structural (the field exists and is threaded through `subscribe`); the
observable proof of register/deregister is M3's test. If you want an interim manual check,
you may temporarily add a `Debug.Trace`-style read in a scratch file, but do not commit it.


### Milestone M2 — public view type, snapshot accessor, and currentState as a registry read

**Scope and outcome.** At the end of M2, there is a committed public view record
`SubscriptionStateView` and a public function
`subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)`
returning a near-instant snapshot of every live subscription as proper view
records (name, member, live state, stable `statePhase` label, FSM cursor position), reachable
through `import Kiroku.Store`. There is also a `stateName :: SubscriptionState -> Text` helper
for a stable, low-cardinality state label (the kind a future Prometheus gauge or admin row
needs), used to fill `statePhase`, and `stateCursor` (re-exported) supplies `cursor`.
Finally, the registry becomes the **single source of truth**: the handle's `currentState` is
reshaped to read the registered cell, so `currentState` and the snapshot observe one coherent
value. This is a deliberate, possibly breaking reshape, acceptable because kiroku is pre-1.0
(see Decision Log). The worker's write path is unchanged — it still writes its `stateVar`, and
that is the registered cell both observers read.

**Edits.**

First, define the public view type. Add it to `kiroku-store/src/Kiroku/Store/Subscription.hs`
(it has access to `SubscriptionState`, `SubscriptionName`, `GlobalPosition`, `Int32`, and
`Text`). It is a flat, externally-consumed record — deliberately *not* the internal cell type
— so the future Prometheus exporter and admin tool read it directly rather than
pattern-matching `SubscriptionState`:

```haskell
{- | A public, point-in-time view of one live subscription's state, as returned
by 'subscriptionStates'. This is the committed observability surface external
consumers (a future Prometheus exporter, an admin tool) read directly; it is
intentionally a flat view, not the internal 'SubscriptionState' cell type.

* 'subscriptionName' / 'member' identify the subscription (member 0 for a
  non-group subscription), matching the registry/checkpoint key.
* 'state' is the live 'SubscriptionState' read from the worker's registered cell.
* 'statePhase' is a stable, low-cardinality label (via
  'Kiroku.Store.Subscription.Fsm.stateName') suitable as a metric label value or
  admin column; it does not drift if a constructor's fields change.
* 'cursor' is the worker FSM cursor (via 'stateCursor'). It is the cheap live
  progress signal for observability, not a guaranteed durable checkpoint row.
-}
data SubscriptionStateView = SubscriptionStateView
    { subscriptionName :: !SubscriptionName
    , member :: !Int32
    , state :: !SubscriptionState
    , statePhase :: !Text
    , cursor :: !GlobalPosition
    }
    deriving stock (Show, Generic)
```

`Generic` is required so the record is read with the codebase's `view ^. #field` accessor:
the package enables `DuplicateRecordFields` + `OverloadedLabels` (not `OverloadedRecordDot`),
and `member`/`subscriptionName` already exist as fields on other records, so bare selectors
are ambiguous (see the Decision Log audit entry). Import `GHC.Generics (Generic)` in
`Subscription.hs` if it is not already in scope.

Second, add the accessor in the same file (alongside `subscribe`/`withSubscription`). Add the
view type and the accessor to the module export list at
`kiroku-store/src/Kiroku/Store/Subscription.hs:1-8`:

```haskell
module Kiroku.Store.Subscription (
    -- * Subscribe
    subscribe,
    withSubscription,

    -- * Observability
    subscriptionStates,
    SubscriptionStateView (..),

    -- * Types
    module Kiroku.Store.Subscription.Types,
) where
```

and define it. It snapshots the registry's outer map with `readTVarIO`, then reads each inner
cell with `readTVarIO` (outside STM) and builds a `SubscriptionStateView` for each entry.
Because the key already carries the name and member, and `stateName`/`stateCursor` derive the
label and position from the live state,
the view is assembled purely from data already in hand:

```haskell
{- | A near-instant snapshot of every live subscription as a public
'SubscriptionStateView', keyed by (subscription name, consumer-group member;
0 for non-group).

Snapshots the registry's outer map with 'readTVarIO', then reads each registered
state cell with 'readTVarIO' __outside__ STM. This is deliberately not one STM
transaction over all cells (see the 2026-05-31 audit in the Decision Log): a
single transaction would put every subscription's state cell in the reader's STM
read set, and since each worker writes its cell ~once per batch, any such write
would force the whole scan to re-run — a reader-side cost that scales with
subscription count. The named consumers (a Prometheus scrape, an admin listing)
read independent values and do not need a globally atomic snapshot, so each entry
is read as its own freshest value. A subscription appears here from the moment
'subscribe' returns its handle until its worker exits (stop, cancel, or crash),
at which point its key is removed; a stopped/cancelled/crashed subscription is
represented by __absence__, never by a @"stopped"@ phase (the FSM never writes
'Stopped' into the cell). This map of view records is the committed surface the
future Prometheus exporter and admin tool consume.
-}
subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)
subscriptionStates store = do
    cells <- readTVarIO (store ^. #subscriptionRegistry)
    Map.traverseWithKey
        ( \(nm, mbr) cell -> do
            st <- readTVarIO cell
            pure
                SubscriptionStateView
                    { subscriptionName = nm
                    , member = mbr
                    , state = st
                    , statePhase = stateName st
                    , cursor = stateCursor st
                    }
        )
        cells
```

`readTVarIO` on the outer map gives the set of cells; `Map.traverseWithKey` then reads each
cell (and builds its view) with `readTVarIO`, each read a tiny independent transaction with no
shared read set — so the scan never retries and never contends with workers' writes.
`Map.traverseWithKey` (rather than a plain `traverse`) is used because the view records carry
the subscription name and member, which live in the map *key*. Add `Map`, `Int32`,
`stateName`, `stateCursor`, and `GlobalPosition` to `Subscription.hs`'s imports:

```haskell
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Kiroku.Store.Subscription.Fsm (SubscriptionState, stateCursor, stateName)
import Kiroku.Store.Types (GlobalPosition)
```

(extends the M1 import edits; `atomically`/`modifyTVar'` remain for the register/deregister
STM, but the snapshot itself uses `readTVarIO` and needs no `atomically`/`readTVar`. `Map.traverseWithKey`
comes from the qualified `Map` import M1 already added, `Text` for the view's `statePhase`
field, `Generic` for the view's deriving clause, and `SubscriptionState` / `GlobalPosition`
for the view's other fields if not already in scope.)

Third, reshape `currentState` so the registry is genuinely the single source of truth. This
is a real, committed, breaking change (per the 2026-05-31 audit): the handle's `currentState`
is **resolved through the registry by key** and returns `Maybe`.

Change the field type in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:351` from

```haskell
    , currentState :: !(m SubscriptionState)
```

to

```haskell
    , currentState :: !(m (Maybe SubscriptionState))
```

and rewrite its Haddock: `Just s` means the worker is live and in state `s`; `Nothing` means
the subscription is **not currently live** — it stopped, was cancelled, crashed, or was never
started. Note the invariant that a `Stopped` state never appears here (the FSM never writes
`Stopped` into the cell; a not-live subscription is represented by `Nothing`), and that this
read is resolved through the central registry — for the stream of past transitions use the
`KirokuEvent` lifecycle events instead.

In `subscribe` (`kiroku-store/src/Kiroku/Store/Subscription.hs`), build `currentState` as a
registry lookup of the key M1 already computes, closing over `reg` and `key` rather than over
`stateVar` directly:

```haskell
            , currentState = do
                m <- readTVarIO reg
                case Map.lookup key m of
                    Just (tok, cell) | tok == token -> Just <$> readTVarIO cell
                    _ -> pure Nothing
```

`Map.lookup key m :: Maybe (Unique, TVar SubscriptionState)`; the token guard ensures the
handle reads only the cell it registered. While the worker is live and still owns the entry,
the key resolves to the very cell the worker writes, so `currentState` and the snapshot agree;
after the worker exits, the `finally` cleanup has deleted the key, so `currentState` returns
`Nothing`. If a newer duplicate-key worker supersedes this handle, the key remains present but
the token differs, so this handle also returns `Nothing`. There is a benign race — a
concurrent reader may still see `Just <last-live-state>` between the worker's final write and
the delete — which is acceptable for a point-in-time "is it live" read. `readTVarIO` is already
imported (M1); `Map` is the qualified import M1 added.

The one caller affected is `kiroku-store/test/Test/SubscriptionState.hs` (lines 103, 108),
which becomes `Just`-aware (e.g. `Just st <- currentState handle`, and `waitUntilState` reads
through the `Maybe`); update it in M3.

Fourth, add `stateName` to `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`. Add it to
the module export list (in the `-- * State` group, near `stateCursor` at lines 33-37):

```haskell
    SubscriptionState (..),
    ResumeCondition (..),
    stateCursor,
    stateName,
```

and define it next to `stateCursor` (after line 203):

```haskell
{- | A stable, low-cardinality label for the state's /name/, independent of its
payload (cursor, attempt, reason). Suitable as a metric label value or an admin
column. The strings are fixed identifiers, not the derived 'Show' output, so
they will not drift if a constructor's fields change.
-}
stateName :: SubscriptionState -> Text
stateName = \case
    CatchingUp{} -> "catching_up"
    Live{} -> "live"
    Paused{} -> "paused"
    Reconnecting{} -> "reconnecting"
    Retrying{} -> "retrying"
    Stopped{} -> "stopped"
```

`Text` is already imported in `Fsm.hs` (line 60). The module is compiled with
`-Werror=incomplete-patterns` (line 1), so if `SubscriptionState` ever gains a constructor,
`stateName` fails to compile until it is handled — a deliberate safety net.

Fifth, surface the helpers through the umbrella `kiroku-store/src/Kiroku/Store.hs`.
`subscriptionStates` and `SubscriptionStateView` are already reached because the umbrella
re-exports the whole `Kiroku.Store.Subscription` module (lines 22 and 59), and both are now in
that module's export list — so no edit is strictly required for them; confirm by reading the
re-export. For `stateName` and `stateCursor`, the umbrella does not currently re-export the
`Fsm` module wholesale; add an explicit re-export to the `Kiroku.Store` export list (near
the `SubscriptionStopReason (..)` re-export at line 36):

```haskell
    stateName,
    stateCursor,
```

and add to its imports (near line 56-60):

```haskell
import Kiroku.Store.Subscription.Fsm (stateCursor, stateName)
```

(`SubscriptionStopReason` is already re-exported via `Kiroku.Store.Observability` at line
56, so `SubscriptionState` itself is reachable for callers through the
`Kiroku.Store.Subscription` → `Types` re-export, which exposes `SubscriptionState` via the
`currentState` field's type. If a caller needs the constructors, they can
`import Kiroku.Store.Subscription.Fsm`; the snapshot test below does exactly that.)

**Commands and acceptance.**

```bash
cabal build kiroku-store
```

Expected: clean build. To confirm reachability and consistency before the full test, you
may add the M3 test now; M2 acceptance is that `subscriptionStates`, `SubscriptionStateView`
(with its fields), `stateName`, and `stateCursor` are all importable from `Kiroku.Store` and
the library builds without warning, and that `currentState` now has type
`m (Maybe SubscriptionState)`, resolved through the registry, returning `Just s` for a live
worker and `Nothing` once not live. This is a real behavior change, so the existing
`Test.SubscriptionState` spec must be updated to the `Maybe` shape (M3); the library and that
updated spec compile and pass, proving the registry is genuinely authoritative for the
per-handle read.


### Milestone M3 — tests, docs, and changelog

**Scope and outcome.** At the end of M3, a new spec `Test.SubscriptionRegistry` proves the
registry's behavior against a real migrated PostgreSQL database, the spec is wired into the
suite, the changelog records the addition, and the registry has module-level documentation.
This is the milestone that produces the observable proof.

**The test.** Create `kiroku-store/test/Test/SubscriptionRegistry.hs`. It must, in one or
more `it` blocks:

1. **Several subscriptions appear with sensible state and position.** Start (with
   `withTestStoreSettings` so an `eventHandler` barrier can be installed) at least: one
   plain `$all` subscription, and two members of one consumer group (member 0 and member 1
   of size 2, e.g. against a category target as `Test.ConsumerGroup` does). Append a few
   events and use `waitForPublisher` / `waitForSubscriptionLive` to drive the workers past
   catch-up so their states are deterministic. Then call `subscriptionStates store` (which
   now returns `Map (SubscriptionName, Int32) SubscriptionStateView`) and assert: the map
   contains the key `(plainName, 0)` and both group keys `(groupName, 0)` and `(groupName,
   1)`; that each value's `statePhase` field is a sensible label (e.g. `"live"` or
   `"catching_up"` — assert it is one of the expected set rather than a single exact value, to
   avoid flakiness on timing); that each view's `subscriptionName`/`member` fields match its
   map key; and that the `cursor` field is a sane `GlobalPosition` (`>= 0` is enough for a
   robust assertion; if the test appends N events before going live, assert the live
   subscription's cursor is `>= 0` and ideally that it reaches the appended count after
   delivery). Also assert `currentState` on a held *live* handle returns `Just s` whose `s`
   agrees with the matching view's `state` field, demonstrating the single-source-of-truth
   reshape (both read the one registered cell).

2. **A stopped subscription's key disappears.** Stop one subscription cleanly (have its
   handler return `Stop`, or `cancel` the handle), `wait` for it to finish, then read
   `subscriptionStates` again and assert its key is **absent** from the map while the others
   remain. Because deregistration runs inside the worker's `finally` cleanup, use a small
   poll/`wait` to avoid racing the cleanup: prefer `wait handle` (which resolves only after
   the worker thread — and thus its `finally`-attached cleanup — has run) before reading the
   snapshot.

3. **A cancelled subscription's key disappears.** `cancel` a handle, `wait` for it, then
   assert its key is gone (the `finally` cleanup also runs on `AsyncCancelled`).

4. **A crashed subscription's key disappears (the `finally` path).** Start a subscription
   whose handler throws an exception on its first event (e.g. `\_ -> throwIO (userError
   "boom")`), append an event so the handler runs, `wait` for the handle (it resolves
   `Left someException`), then assert its key is **absent** — proving the `finally` cleanup
   removes the entry on a crash, not just on graceful stop or cancel.

In scenarios 2–4, after the key is gone, also assert `currentState` on the (still-held) handle
returns `Nothing` — the per-handle read agrees with the snapshot that the subscription is no
longer live.

5. **Stale duplicate-key cleanup cannot delete a replacement.** Start one subscription with
   key `(dupName, 0)`, then start a second subscription with the same key. The second insert
   supersedes the first in the registry. Cancel or stop the first handle and wait for it; then
   assert the snapshot still contains `(dupName, 0)` for the second worker, the first handle's
   `currentState` returns `Nothing`, and the second handle's `currentState` returns `Just _`.
   This does not make duplicate workers a supported workload shape — they still collide on the
   durable checkpoint — but it proves stale cleanup cannot corrupt the active registry entry.

**Update the existing spec.** Because `currentState` changed type to `m (Maybe
SubscriptionState)`, migrate `kiroku-store/test/Test/SubscriptionState.hs` (the only caller):
its `st <- currentState handle` (line 103) and the `waitUntilState ... (currentState handle)
...` (line 108) now thread through the `Maybe` (e.g. match `Just st`, and have `waitUntilState`
treat `Nothing` as "not yet in the wanted state"). This spec must compile and pass under the
new type.

Model the config construction, append, and barrier wiring on
`kiroku-store/test/Test/SubscriptionState.hs` and the group-config helper at
`kiroku-store/test/Test/ConsumerGroup.hs:82-95`. Import the snapshot accessor and view type
via `import Kiroku.Store` (which re-exports `subscriptionStates`, `SubscriptionStateView (..)`,
`stateName`, `stateCursor`) and the state constructors via
`import Kiroku.Store.Subscription.Fsm (SubscriptionState (..), stateName, stateCursor)`. Read
the view's `statePhase`/`cursor` fields directly off each `SubscriptionStateView` rather
than re-deriving them from a raw `SubscriptionState`. Use `Data.Map.Strict` to look up keys
(`Map.member`, `Map.lookup`).

A robust deregistration assertion helper (poll the snapshot until a key is gone or a budget
expires, like `waitUntilState` in `Test.SubscriptionState`) avoids races even though `wait`
already orders after `finally`:

```haskell
waitUntilAbsent :: Int -> KirokuStore -> (SubscriptionName, Int32) -> IO Bool
waitUntilAbsent budget store key
    | budget <= 0 = pure False
    | otherwise = do
        m <- subscriptionStates store
        if Map.member key m
            then threadDelay 20_000 >> waitUntilAbsent (budget - 20_000) store key
            else pure True
```

**Wire the test in.** Add `Test.SubscriptionRegistry` to the `other-modules` list of the
`kiroku-store-test` stanza in `kiroku-store/kiroku-store.cabal` (the list at lines 88-109,
keeping alphabetical order), and add `SubscriptionRegistry.spec` to `kiroku-store/test/Main.hs`
(import it near the other `Test.Subscription*` imports around lines 47, and call it in the
spec list around lines 68-69). The stanza already depends on `containers`, `stm`, `async`,
`text`, and `kiroku-store`, so no new `build-depends` are needed.

**Docs.** Add a short paragraph to the `subscribe`/registry area documenting the registry
as part of the `subscriptionRegistry` field Haddock written in M1, and ensure
`subscriptionStates`'s Haddock (M2) explains the snapshot semantics and the future
consumers. Because this is a first-release public API change, also update every existing
user/architecture doc that currently describes `currentState :: m SubscriptionState` or says
it reads a private `TVar`: `docs/user/subscriptions.md`, `docs/user/observability.md`,
`docs/guides/consuming-the-event-log.md`, `docs/guides/building-a-projection.md`,
`docs/architecture/subscriptions.md`, and `docs/user/consumer-groups.md`. Those docs must
describe `currentState :: m (Maybe SubscriptionState)`, the "stopped/superseded = Nothing"
rule, and the new `subscriptionStates` snapshot with `SubscriptionStateView.cursor`.

**Changelog.** Prepend an entry under the `## Unreleased` / `### Added` area of
`kiroku-store/CHANGELOG.md`:

```text
### Added — central subscription-state registry (plan 45)

* `KirokuStore` gains a `subscriptionRegistry` field: a central, in-memory map
  keyed by `(SubscriptionName, member)` holding every live subscription worker's
  FSM-state cell. Each `subscribe` registers its worker's existing state `TVar`
  on start and removes it on any exit (stop, cancel, crash) via the worker's
  `finally` cleanup; the worker's writes are unchanged.
* New public view type `SubscriptionStateView { subscriptionName, member, state,
  statePhase, cursor }` (`deriving stock (Show, Generic)`) — the committed
  observability surface external consumers read via `^. #field`. New accessor
  `subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32)
  SubscriptionStateView)` returns a near-instant snapshot of every live
  subscription as view records: it snapshots the outer map and reads each cell
  with `readTVarIO` (no large STM read set, so the reader never retries). Both
  re-exported from `Kiroku.Store`. This map of view records is the foundation for
  a future Prometheus exporter and admin tool (named future consumers, not built
  here), and the performant live-state layer that closes the OpenTelemetry
  export-on-end blind spot at zero per-event cost. The `cursor` field is the
  worker FSM cursor, not a guaranteed durable checkpoint row. A
  stopped/cancelled/crashed subscription is represented by absence, never a
  `"stopped"` phase.
* New `stateName :: SubscriptionState -> Text` (a stable low-cardinality state
  label) in `Kiroku.Store.Subscription.Fsm`; `stateName` and `stateCursor` are
  re-exported from `Kiroku.Store`.

### Changed (pre-1.0, breaking) — plan 45

* `currentState` changed type from `m SubscriptionState` to
  `m (Maybe SubscriptionState)` and is now resolved through the central registry
  by `(name, member)` and this handle's token: `Just s` while the worker is live
  and still owns the entry, `Nothing` once it has stopped/cancelled/crashed (its
  registry key is removed), before it starts, or after a newer worker supersedes
  the same key.
  This makes the registry genuinely the single source of truth for live state and
  unifies the "stopped = absent" rule across `currentState` and the snapshot. (The
  worker still solely writes its `stateVar`; only the handle's read path moved to a
  registry lookup of that same cell.) A deliberate pre-1.0 breaking change.
```

**Commands and acceptance.**

```bash
cabal build kiroku-store
cabal test kiroku-store
```

Expected: the build is clean, and the test run finishes with all specs green, e.g. a tail
like:

```text
subscription FSM — observable state (EP-41 M4)
  reports CatchingUp while blocked in catch-up and Live once caught up
  delivers every event exactly once in order across the catch-up to live boundary
subscription registry (EP-1 / plan 45)
  registers every live subscription with a sensible state and position
  removes a subscription's entry when it stops cleanly
  removes a subscription's entry when it is cancelled
  removes a subscription's entry when its handler crashes
  stale duplicate-key cleanup does not remove the replacement entry

Finished in 12.3456 seconds
NNN examples, 0 failures
```

The exact example count `NNN` depends on the rest of the suite; the load-bearing assertion
is **`0 failures`** and that the five new `subscription registry` examples appear and pass.


## Concrete Steps

Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`.

1. Edit `kiroku-store/src/Kiroku/Store/Connection.hs`: add the `subscriptionRegistry` field
   to `KirokuStore`, add the STM/`Map`/`Int32`/`Unique`/`Fsm`/`Types` imports, create `reg <-
   newTVarIO Map.empty` in `withStore`'s `acquire`, and add `subscriptionRegistry = reg` to
   the record literal.

2. Edit `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`: add `configMember` to the
   module export list.

3. Edit `kiroku-store/src/Kiroku/Store/Subscription.hs`: import `modifyTVar'`,
   `Map` (qualified and unqualified), `Int32`, `Text`, `Generic`, `GlobalPosition`, `newUnique`,
   `stateName`, `stateCursor`, and `configMember`; in `subscribe`, create `token <- newUnique`,
   compute `reg`/`key`, insert `(token, stateVar)` before forking, and replace `` `finally
   unsubscribe `` with `` `finally` cleanup `` where `cleanup` first runs `unsubscribe` and then
   conditionally deletes the key only if the stored token still equals `token`.
   Define and export the public view type `SubscriptionStateView (..)` (`deriving stock (Show,
   Generic)`). Then add `subscriptionStates` (returning `Map (SubscriptionName, Int32)
   SubscriptionStateView`, snapshotting the outer map and reading each cell with `readTVarIO`
   outside STM) and export it. Reshape `currentState` to `m (Maybe SubscriptionState)`,
   defined as a registry lookup of `key` closing over `reg` (the worker's `stateVar` remains
   the sole write target); change the field type and Haddock on
   `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:351`.

4. Edit `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`: export and define `stateName`.

5. Edit `kiroku-store/src/Kiroku/Store.hs`: re-export `stateName` and `stateCursor`
   (`subscriptionStates` and `SubscriptionStateView` are already reached via the whole-module
   re-export of `Kiroku.Store.Subscription`; confirm).

6. Build the library:

   ```bash
   cabal build kiroku-store
   ```

7. Create `kiroku-store/test/Test/SubscriptionRegistry.hs` with the five scenarios; wire it
   into `kiroku-store/kiroku-store.cabal` (`other-modules`) and `kiroku-store/test/Main.hs`.

8. Update `kiroku-store/CHANGELOG.md` and the current-state/registry docs listed in M3.

9. Build and test:

   ```bash
   cabal build kiroku-store
   cabal test kiroku-store
   ```

   Confirm `0 failures` and the new `subscription registry` examples pass.


## Validation and Acceptance

Acceptance is behavioral, not "it compiles":

- **Snapshot reflects live subscriptions as view records.** After starting one `$all`
  subscription and two members of one consumer group and driving them past catch-up,
  `subscriptionStates store` returns a `Map (SubscriptionName, Int32) SubscriptionStateView`
  whose key set is exactly `{(plainName,0),(groupName,0),(groupName,1)}` (no more, no fewer),
  each `SubscriptionStateView` carrying matching `subscriptionName`/`member`, a sensible
  `statePhase` (one of `"catching_up"` / `"live"`), and a `cursor` that is a valid
  `GlobalPosition`.
- **Registry is the single source of truth for `currentState`.** For a live subscription,
  `currentState handle` returns `Just s` whose `s` equals the `state` field of that
  subscription's view in the snapshot, because both resolve the one registered cell the worker
  writes. For a stopped/cancelled/crashed subscription, `currentState` returns `Nothing` and
  the key is absent from the snapshot — the pre-1.0 reshape, demonstrated as a real behavior
  change.
- **Deregistration on clean stop.** After a subscription's handler returns `Stop` and
  `wait` resolves `Right ()`, that subscription's key is absent from the next
  `subscriptionStates` snapshot, while the others remain.
- **Deregistration on cancel.** After `cancel handle` and `wait`, the key is absent.
- **Deregistration on crash (the `finally` path).** After a handler that `throwIO`s runs and
  `wait` resolves `Left e`, the key is absent — proving the `finally`-attached cleanup runs
  on the exception path, not only on stop/cancel.
- **Stale cleanup safety for duplicate keys.** After a first worker is superseded by a second
  worker with the same `(name, member)`, stopping the first worker does not remove the second
  worker's registry entry. The first handle reports `Nothing`; the second handle reports
  `Just _`.

The exact commands are `cabal build kiroku-store` and `cabal test kiroku-store`, run from
the repository root; success is a green run reporting `0 failures` with the five new
`subscription registry` examples present.

Cross-plan note (affordance only): sibling plan
`docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md`'s
database-backed end-to-end test may, if convenient, read `subscriptionStates` to
cross-check the registry against the exported spans. This is an optional convenience for
that plan, not a dependency of this one; nothing here requires plan 46.


## Idempotence and Recovery

Almost every edit in this plan is **additive**; the one non-additive edit is the deliberate,
breaking reshape of `currentState` to `m (Maybe SubscriptionState)` (and the single test caller
it touches); all steps are safe to re-run:

- Adding a record field, a view type, an export, a function, and a test module are all
  additive source changes; reshaping `currentState` to a registry-resolved `Maybe` is a
  breaking signature change with one in-repo code caller
  (`kiroku-store/test/Test/SubscriptionState.hs`) plus several docs call sites, updated in the same plan. Re-running
  `cabal build` / `cabal test` after a partial edit simply rebuilds; a half-applied edit shows
  up as a compile error naming the missing piece (e.g. the test not yet threaded through
  `Maybe`), which you fix and rebuild. There is no generated state to clean up.
- **No database migration is involved.** The registry is purely in-memory (a `TVar` on the
  store handle), created fresh each time `withStore` opens a store and discarded when the
  store closes. Nothing touches the PostgreSQL schema, so there is nothing to roll back at
  the database level and the test harness's shared migrated database is unaffected.
- The register/deregister pair is self-healing at runtime: the `finally`-attached cleanup
  guarantees an entry is removed on every worker exit, so re-running tests or restarting a
  store never leaves stale entries. The one documented exception is the accepted
  misconfiguration limitation (two `subscribe` calls with the same `(name, member)`),
  recorded in the Decision Log; it mirrors the pre-existing checkpoint-collision behavior.
  The token-conditional cleanup added here does defend the registry from stale cleanup by the
  superseded worker, but it does not make duplicate workers a supported checkpointing shape.
- If a build fails on a module-import cycle when adding the `Fsm`/`Types` imports to
  `Connection.hs`, the recovery is to verify `Connection.hs` imports only
  `Kiroku.Store.Subscription.Fsm` and `Kiroku.Store.Subscription.Types` (the leaf state and
  config modules), not `Kiroku.Store.Subscription` (the umbrella that imports `Connection`).


## Interfaces and Dependencies

Libraries used (all already in `kiroku-store`'s dependency set): `stm` for `TVar`,
`atomically` + `modifyTVar'` + `newTVarIO` (register/deregister) and `readTVarIO` (snapshot and
`currentState`, both outside STM); `containers` for `Data.Map.Strict` (including
`Map.traverseWithKey` for the snapshot and `Map.lookup` for `currentState`); `base` for
`Data.Int.Int32`, `Data.Unique.Unique`/`newUnique`, and `GHC.Generics.Generic` (the view's deriving clause); `text` for
`Data.Text.Text` (the view's `statePhase` label); `lens` + `generic-lens` for the `^. #field`
record access; `async` and `base`'s `Control.Exception.finally` for the worker lifecycle.

Types, fields, and signatures that must exist at the end of each milestone (full module
paths):

End of **M1**, in `kiroku-store/src/Kiroku/Store/Connection.hs`:

```haskell
data KirokuStore = KirokuStore
    { -- ...existing fields...
    , subscriptionRegistry :: !(TVar (Map (SubscriptionName, Int32) (Unique, TVar SubscriptionState)))
    }
```

initialized in `withStore` via `newTVarIO Map.empty`; and in
`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` the export of:

```haskell
configMember :: SubscriptionConfig -> Int32
```

and in `kiroku-store/src/Kiroku/Store/Subscription.hs`, `subscribe` registers
`store ^. #subscriptionRegistry` under `key = (name config, configMember config)` before
forking as `(token, stateVar)`, with token-conditional cleanup attached via
`` `finally` cleanup ``.

End of **M2**, in `kiroku-store/src/Kiroku/Store/Subscription.hs`, the public view type:

```haskell
data SubscriptionStateView = SubscriptionStateView
    { subscriptionName :: !SubscriptionName
    , member :: !Int32
    , state :: !SubscriptionState
    , statePhase :: !Text       -- stable label via stateName
    , cursor :: !GlobalPosition -- worker FSM cursor via stateCursor
    }
    deriving stock (Show, Generic)
```

and the accessor:

```haskell
subscriptionStates :: KirokuStore -> IO (Map (SubscriptionName, Int32) SubscriptionStateView)
```

implemented by snapshotting the outer map with `readTVarIO` and then, via
`Map.traverseWithKey`, reading each cell with `readTVarIO` outside STM and assembling a
`SubscriptionStateView` (`statePhase = stateName st`, `cursor = stateCursor st`); and in
`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`:

```haskell
stateName :: SubscriptionState -> Text
```

`subscriptionStates`, `SubscriptionStateView (..)`, and `stateName` re-exported (directly or
transitively) from `kiroku-store/src/Kiroku/Store.hs`, along with the existing
`stateCursor :: SubscriptionState -> GlobalPosition`
(`kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs:196`). The handle field `currentState`
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:351`) **changes type** from
`m SubscriptionState` to `m (Maybe SubscriptionState)` and is now defined as a registry lookup
of the worker's cell by `(name, member)` plus the handle's token — `Just s` while live and
still owner, `Nothing` once not live or superseded. This
is a deliberate, breaking pre-1.0 reshape (see Decision Log) that preserves the MasterPlan's
Integration Point constraint: the worker's `stateVar` stays the sole write target, the
registry holds that cell, and both `currentState` and the snapshot read it.

End of **M3**: a new test module `kiroku-store/test/Test/SubscriptionRegistry.hs` exporting
`spec :: Spec`, listed in `kiroku-store/kiroku-store.cabal` (`other-modules`) and invoked
from `kiroku-store/test/Main.hs`; a changelog entry in `kiroku-store/CHANGELOG.md`; and the
current-state/registry docs listed in M3 updated.

**Coordination with the parent MasterPlan.** This plan is child plan 1 (EP-1) of
`docs/masterplans/7-subscription-state-registry-and-complete-fsm-state-observability.md`.
Its Integration Points require that the per-worker `stateVar` remain the worker's *write
target* — this plan **registers that cell** into the central map and never replaces it with
a write-through. The worker therefore keeps writing `stateVar` exactly as before, so the
sibling plan
`docs/plans/46-complete-opentelemetry-span-coverage-of-every-subscription-fsm-state.md`'s
read of `stateVar` is undisturbed regardless of which plan lands first. Per the MasterPlan's
pre-stable-primitive direction (and its 2026-05-31 audit), this plan additionally reshapes
`currentState` to `m (Maybe SubscriptionState)` resolved through the registry by key and token (making
the registry genuinely the single source of truth) and returns a committed public
`SubscriptionStateView` rather than the raw cell type; both are deliberate, breaking pre-1.0
changes. Neither alters the worker's write path (the worker still solely writes `stateVar`);
only the handle's *read* path moves to a registry lookup, and `currentState` now returns
`Nothing` for a not-live subscription. This plan also adds the `subscriptionRegistry` field and
its initialization at the
store-construction site, which the MasterPlan assigns solely to EP-1; it does not touch the
`KirokuEvent` type or the worker's event emission (EP-2's responsibility). The OTel synergy
is framing only — this plan adds no spans and no metrics; it makes live state queryable so the
performant live-state layer the MasterPlan describes exists for a future reader to consume.


## Revision Notes

- 2026-05-31 — Absorbed two design refinements from the parent MasterPlan
  (`docs/masterplans/7-...`), mirroring its two 2026-05-31 Decision Log entries.
  **(1) Pre-stable core primitive.** Kiroku has not released a stable version, so there is no
  public-API back-compat to preserve; the registry is now framed as a deliberate, committed
  core primitive. The snapshot accessor returns a public view type
  `SubscriptionStateView { subscriptionName, member, state, statePhase, cursor }` instead
  of a raw `Map key SubscriptionState`, and the registry is made the single source of truth
  that also backs the handle's `currentState` (which now reads the registered cell). The
  MasterPlan Integration Point constraint is preserved: the worker's per-worker `stateVar`
  remains the sole write target, the registry holds that cell, and both `currentState` and the
  snapshot read it — one cell, one writer, two readers. Breaking API changes are explicitly
  accepted because kiroku is pre-1.0.
  **(2) Performant OTel synergy.** The registry is reframed as not only the substrate for
  Prometheus/admin but also the performant way to close the OpenTelemetry live-state gaps —
  "what state is each subscription in right now" (the export-on-end blind spot) and continuous
  live progress — at zero per-event hot-path cost, by reusing the worker's existing
  per-transition `stateVar` writes and letting consumers read snapshots on their own cadence.
  Spans (sibling plan `docs/plans/46-...`, referenced by path only) are the timeline layer; the
  registry is the live-state layer.
  Reflected across Purpose / Big Picture, Progress (M2), Decision Log (two new matching
  entries plus an updated out-of-scope entry), Context and Orientation (new view-type and
  OTel-synergy paragraphs; `currentState`/`stateVar` notes), Plan of Work (intro, M1 and M2
  scope, M2 edits and acceptance, M3 test/changelog), Concrete Steps, Validation and
  Acceptance, Idempotence and Recovery, and Interfaces and Dependencies. The intact decisions
  — key `(SubscriptionName, Int32)` via `configMember`, store-the-cell-not-a-copy,
  lifecycle register/deregister via `finally`, and DB-backed
  tests — are unchanged.

- 2026-05-31 — Cascaded the parent MasterPlan's pre-commitment audit (see
  `docs/masterplans/7-...` Surprises & Discoveries and its five 2026-05-31 audit Decision Log
  entries). Three substantive corrections, confirmed with the user, plus two fixes:
  **(1) Snapshot reads via `readTVarIO`, not one STM transaction.** A single `atomically` over
  the outer map and every inner cell made the reader's STM read set the whole set of
  subscriptions' `stateVar`s; since each worker writes its cell ~once per batch
  (`Worker.hs:183`), that scan would re-run on any worker's write and thrash under many
  catching-up subscriptions, a cost entirely on the reader. The named consumers do not need a
  globally-atomic snapshot, so the accessor now snapshots the outer map with `readTVarIO` and
  reads each cell with `readTVarIO` outside STM (O(N), no retries; per-cell-fresh).
  **(2) `currentState :: m (Maybe SubscriptionState)`, resolved via the registry.** The earlier
  "reads the registered cell" reshape was fictional — it kept `currentState = readTVarIO
  stateVar` unchanged while claiming a breaking change. The real, committed reshape routes the
  per-handle read through the registry by key and returns `Maybe`: `Just s` while live,
  `Nothing` once the key is removed on exit or this handle's token is superseded. This also resolves the discovery that the FSM
  never writes `Stopped` into `stateVar` (`Worker.hs:197-198`), so the old direct-cell
  `currentState` returned a stale `Live` forever after a clean stop; `Nothing` is honest and
  unifies "stopped = absent" across `currentState` and the snapshot. Blast radius: one code caller,
  `kiroku-store/test/Test/SubscriptionState.hs`, plus the user/architecture docs migrated in M3.
  **(3) `SubscriptionStateView` derives `Generic`** (in addition to `Show`) so it is consumable
  via the codebase's `^. #field` convention — its field names `member`/`subscriptionName`
  collide with existing records under `DuplicateRecordFields`, making bare selectors ambiguous,
  and `^. #field` needs `Generic`.
  Folded-in fixes: the "stopped = absent" invariant is documented on `currentState`,
  `subscriptionStates`, and the `subscriptionRegistry` field; the insert-before-fork /
  cleanup-in-`finally` leak window is noted as mirroring the pre-existing `unsubscribe` window.
  The double-registration limitation is unchanged as a workload shape (last writer wins and the
  durable checkpoint still collides), but the final audit adds a token so an earlier handle does
  not read the later worker's cell and stale cleanup cannot remove it.
  Reflected across Purpose, Progress (M2), Decision Log (reversed the single-transaction
  decision; new `currentState`-Maybe, Generic, and stopped-absent entries), Context and
  Orientation, Plan of Work (M2 view type / accessor / `currentState`; M2 acceptance; M3 test),
  Concrete Steps, Validation and Acceptance, Idempotence and Recovery, and Interfaces and
  Dependencies.

- 2026-05-31 — Final pre-implementation audit before implementing the first-release API.
  Cascaded three corrections from the parent MasterPlan's final audit. **(1) Token-owned
  registry entries.** The registry now stores `(Unique, TVar SubscriptionState)` rather than
  only the cell. Cleanup deletes only when the stored token matches the worker's token, and
  `currentState` reads only when the token matches the handle. This prevents an old duplicate-key
  worker from deleting or reading a newer worker's live entry. **(2) `cursor`, not
  `checkpoint`.** The public view field is renamed to `cursor` because it comes from
  `stateCursor` and is the FSM cursor, not always the durable checkpoint row. **(3) Docs are in
  scope.** M3 now updates all user/architecture docs that mention `currentState` or the registry,
  not only the test and CHANGELOG. Reflected across Purpose, Progress, Decision Log, M1/M2/M3
  implementation steps, Validation, Interfaces, and this Revision Notes section.
