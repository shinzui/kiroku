---
id: 43
slug: per-subscription-event-type-filtering-through-the-worker-streamly-bridge-and-shibuya-adapter
title: "Per-subscription event-type filtering through the worker, Streamly bridge, and Shibuya adapter"
kind: exec-plan
created_at: 2026-05-29T20:28:45Z
intention: "intention_01kstnhravebaryq7x3e50z6pz"
master_plan: "docs/masterplans/6-subscription-worker-fsm-and-end-to-end-shibuya-integration.md"
---

# Per-subscription event-type filtering through the worker, Streamly bridge, and Shibuya adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku is a PostgreSQL-backed event store (repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, library package
`kiroku-store`). A **subscription** is a long-lived background worker that reads
recorded events in global order — either the whole store (the `$all` stream) or
one category — and calls a user-supplied **handler** once per event, remembering
how far it has progressed in a durable **checkpoint** row
(`kiroku.subscriptions.last_seen`). Today a handler that only cares about, say,
`OrderShipped` events must still be invoked for every `OrderCreated`,
`StockUpdated`, and every other event in the store, and discard the ones it does
not want by hand. There is no way to tell a subscription "only deliver these
event types."

After this change a caller can attach an **event-type filter** to a subscription.
A "filter" here is a small declarative value — not an arbitrary function — that
names the set of `eventType` values the handler should receive. The worker
applies the filter in-memory, before it calls the handler. Events whose type is
not in the set are simply not delivered, but — and this is the property that
makes the feature safe — the subscription's checkpoint still advances past them.
A subscription that wants one rare event type out of millions never stalls and
never re-scans the same non-matching events after a restart.

You can see it working three ways once the plan is complete:

- A native `kiroku-store` subscription configured with
  `eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])` over a stream
  of mixed `A`/`B` events delivers only the `A` events to its handler, and its
  persisted `last_seen` equals the global position of the **last event of any
  type**, not the last `A`.
- A Streamly stream built from such a subscription
  (`Kiroku.Store.Subscription.Stream.subscriptionStream`) yields only the
  matching events; the stream's element type is still `RecordedEvent`,
  unchanged.
- A Shibuya processor wired through `shibuya-kiroku-adapter`'s `kirokuAdapter`,
  configured with the same filter, has its Shibuya handler invoked only for the
  matching types.

The defining correctness property, stated up front because it governs every
milestone: **a filtered-out event must still advance the checkpoint.** The
subscription must never stall on a long run of non-matching events. This mirrors
the Elixir EventStore project (local source at
`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore`), whose subscription FSM
applies an in-memory `selector` and explicitly marks filtered events
acknowledged so the checkpoint advances past them.


## Progress

- [x] Design validated against source. Confirmed against the post-EP-40/41/42
      tree: (a) `RecordedEvent` carries `eventType :: EventType`, `EventType` is
      `newtype EventType Text` deriving `Ord`; (b) the existing `EventFilter` in
      `Kiroku.Store.Types` is correlation/causation-query only — a distinctly
      named `EventTypeFilter` was introduced instead; (c) `processEvents` in
      `Worker.hs` checkpoints at the batch tail (`globalPosition (V.last events)`)
      regardless of which handlers ran — so the no-stall property is free; (d) the
      Streamly bridge copies the caller's `config` and overrides only `handler`,
      so the filter flows through unchanged; (e) the adapter builds its
      `SubscriptionConfigM` from `defaultSubscriptionConfig`. (Done 2026-05-29.)
- [x] M1 — defined `EventTypeFilter (AllEventTypes | OnlyEventTypes !(Set
      EventType))` + `eventTypeMatches` in `Subscription/Types.hs`, added the
      `eventTypeFilter` field to `SubscriptionConfigM` (default `AllEventTypes`)
      and `defaultSubscriptionConfig`, and applied the predicate in
      `processEvents`'s per-event branch (filtered events skip the handler and
      fall through to `go (i+1)` so the batch-tail checkpoint advances past them).
      Acceptance test in `kiroku-store-test` (`Test.EventTypeFilter`). (Done
      2026-05-29: `kiroku-store-test` 0 failures.)
- [x] M2 — surfaced the filter through the Streamly bridge (Haddock note;
      no element-type change — `subscriptionStream` already forwards every config
      field but `handler`) and forwarded it through `shibuya-kiroku-adapter`'s
      `KirokuAdapterConfig` (and EP-42's `KirokuConsumerGroupConfig`, threaded
      into each per-member adapter), re-exporting `EventTypeFilter (..)`. Adapter
      acceptance test added: a `kirokuAdapter` configured with
      `OnlyEventTypes {A}` over a mixed A/B stream delivers only the As to the
      Shibuya handler (positions 1, 3, 5). (Done 2026-05-29:
      `shibuya-kiroku-adapter-test` 17 examples, 0 failures.)
- [x] M3 — tests prove the headline properties: selective delivery +
      checkpoint-past-trailing-filtered; **no-stall** over 1 A / 1000 B / 1 A
      (`last_seen` reaches 1002 with only 2 As delivered); and
      **filter-before-dead-letter** (a handler that dead-letters everything is
      never invoked behind a filter that admits nothing in the stream — zero
      dead-letter rows, checkpoint still advances) — all in `kiroku-store-test`.
      The **consumer-group-plus-filter** case is proven in the adapter suite: a
      size-4 group filtered to `OnlyEventTypes {A}` over 20 streams of `[A, B]`
      delivers exactly the 20 As (`sort` of delivered global positions ==
      `[1,3..39]`, disjoint and complete). (Done 2026-05-29: kiroku-store and
      adapter suites, 0 failures.)


## Surprises & Discoveries

- The checkpoint-advances-past-filtered property is **already free** in Kiroku
  today. `processEvents` (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`,
  around lines 474–500) saves the checkpoint at the **batch tail** — the
  `globalPosition` of `V.last events` — once it has walked the whole batch,
  regardless of which handler calls happened in between. So a filter that merely
  skips the handler call for a non-matching event, while leaving the batch-tail
  save untouched, advances the cursor past every event in the batch including the
  skipped ones. No separate "mark acknowledged" bookkeeping is needed (unlike
  EventStore, which tracks an explicit `acknowledged_event_numbers` set). Evidence
  is quoted in Context and Orientation.

- There is already an unrelated type named `EventFilter` in
  `kiroku-store/src/Kiroku/Store/Types.hs` (`FilterCorrelation`,
  `FilterCausationDescendants`, `FilterCausationAncestors`). It is for
  correlation/causation *queries* (`FindEvents`), not subscriptions, and each
  constructor maps to a SQL statement. Reusing or extending it would conflate two
  different features. This plan introduces a distinctly named type
  (`EventTypeFilter`) so the two cannot be confused.

- The no-stall property held exactly as predicted: applying the filter in
  `processEvents`'s per-event branch (skip the `handler` call, fall through to
  `go (i+1)`) while leaving the batch-tail `saveCheckpoint` untouched advances the
  cursor past filtered events with no extra bookkeeping. The 1-A/1000-B/1-A test
  reaches `last_seen = 1002` having delivered only the 2 As, and completes in well
  under the timeout.

- EP-40 ordering verified in `kiroku-store` directly (not only at the adapter):
  the filter runs inside `processEvents` *before* the `handler config event` call,
  which is also where EP-40's `Retry`/`DeadLetter` dispositions are resolved. The
  M3 "does not dead-letter a filtered-out type" test pins this — a handler that
  returns `DeadLetter` for every event it sees writes zero dead-letter rows when
  the filter admits nothing in the stream, because the handler is never reached.

- Touching the shared `SubscriptionConfigM` forced an `eventTypeFilter =
  AllEventTypes` line onto every **full record literal** of `SubscriptionConfig`
  across the test/bench suites (those not built via `defaultSubscriptionConfig`):
  21 in `kiroku-store/test/Main.hs`, plus `Test.ConsumerGroup`,
  `Test.PublisherRestartNoRebroadcast` (×3), `Test.CatchupDbErrorNoPrematureSwitch`,
  `Test.SubscriptionPauseResume` (×2), `Test.FailureInjection`,
  `Test.SubscriptionState` (×2), `Test.SubscriptionReconnect`, and the two
  benchmarks (`bench/ShibuyaOverhead.hs` ×3, `bench/Main.hs`). `AllEventTypes`
  reaches all of them for free because the umbrella `Kiroku.Store` re-exports
  `Kiroku.Store.Subscription.Types` (via `Kiroku.Store.Subscription`).
  `Test.SubscriptionRetryDeadLetter` uses `defaultSubscriptionConfig` and needed
  no change.

- **Adapter delivery-path tests landed.** Two tests were added to
  `shibuya-kiroku-adapter/test/Main.hs` (`describe "kirokuAdapter"`): (1) a single
  `kirokuAdapter` filtered to `OnlyEventTypes {A}` over a mixed A/B stream delivers
  only the As to the Shibuya handler (collected `eventType`s all `A`, global
  positions `[1,3,5]`); (2) a size-4 consumer group built with
  `kirokuConsumerGroupProcessors` and the same filter on every member, over 20
  streams of `[A, B]`, delivers exactly the 20 As — `sort` of delivered global
  positions `== [1,3..39]`, proving the filter is honored per member and the union
  is disjoint + complete. (These were briefly deferred mid-session during an editor
  file-read display outage that made it unsafe to author against the Shibuya
  `runApp`/drain harness; once readable, they were written and pass — adapter suite
  17 examples, 0 failures.)


## Decision Log

- Decision: The filter is an **in-memory, worker-side** filter, not a SQL
  pushdown.
  Rationale: The shared `$all` broadcast publisher
  (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`) fans one
  ingest stream out to every subscriber; pushing a per-subscriber type predicate
  into the read SQL would either fragment that shared path or require
  per-subscriber queries. Filtering after the fetch, before the handler, keeps
  the publisher untouched. A future SQL-pushdown optimization is explicitly out
  of scope here; the declarative filter type is chosen so it remains
  introspectable enough to enable that later.
  Date: 2026-05-29.

- Decision: **Filtering only — no transform/mapper.**
  Rationale: A transform does not affect checkpointing, and callers can already
  `fmap` (or `Streamly.Data.Stream.map`) the typed `Stream IO RecordedEvent`
  downstream if they need to reshape events. Adding a mapper would widen the API
  surface without closing a correctness gap. (EventStore offers both `selector`
  and `mapper`; we adopt only the selector concept.)
  Date: 2026-05-29.

- Decision: The filter is a **closed declarative type**,
  `data EventTypeFilter = AllEventTypes | OnlyEventTypes !(Set EventType)`, not an
  opaque `RecordedEvent -> Bool`.
  Rationale: A closed sum stays introspectable (a reader can ask "which types?"),
  is `Eq`/`Show`-able for tests and diagnostics, and keeps the door open to a
  future SQL pushdown that would need to read the set out of the value. An opaque
  predicate forecloses all of that. We deliberately do **not** add an
  `ExceptEventTypes` (exclude) constructor in this plan: the user's stated need is
  an allow-list ("filter by event type"), `OnlyEventTypes Set.empty` already
  expresses "deliver nothing," and an exclude form can be added additively later
  without breaking callers. This is recorded so a future contributor knows the
  omission is intentional, not an oversight.
  Date: 2026-05-29.

- Decision: The plan carries a **soft dependency on EP-41** (the subscription FSM,
  `docs/plans/41-...`) and should prefer to land after it, but does not hard-block
  on it.
  Rationale: The "deliver this event versus skip it but still advance the cursor"
  choice is precisely a delivery transition, and EP-41 makes that an explicit
  `Effect` in a single `step` function — the cleanest home for the no-stall
  invariant. If EP-41 is not yet merged, the filter is implemented directly in the
  current imperative `processEvents`; the Plan of Work spells out both the current
  form and the FSM mapping so neither is ambiguous.
  Date: 2026-05-29.

- Decision: **Filter-before-bridge / filter-before-deliver ordering.** The filter
  runs in the worker before the handler (and therefore before EP-40's ack-coupled
  bridge handler).
  Rationale: A filtered-out event must never reach the bridge, never receive a
  reply, and therefore can never be retried or dead-lettered. This composes with
  EP-40 in exactly one order. M3 proves it with a test that a filtered-out type is
  not dead-lettered even when the handler would dead-letter it.
  Date: 2026-05-29.

- Decision: The new config field is **additive** on the shared
  `SubscriptionConfigM` record, defaulting to the no-op `AllEventTypes` in
  `defaultSubscriptionConfig`.
  Rationale: EP-40 (retry policy) and EP-42 (consumer-group config helper) also
  touch this record and/or the adapter config. Whichever lands second rebases onto
  the merged record. Every existing caller that builds configs via the smart
  constructor inherits the no-op default and is unaffected.
  Date: 2026-05-29.


## Outcomes & Retrospective

Shipped 2026-05-29.

- **`EventTypeFilter` as shipped:** a closed sum
  `data EventTypeFilter = AllEventTypes | OnlyEventTypes !(Set EventType)`
  (`Eq`, `Show`) in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, with
  `eventTypeMatches :: EventTypeFilter -> RecordedEvent -> Bool`
  (`AllEventTypes` matches all; `OnlyEventTypes s` matches `eventType ev ∈ s`).
  No `ExceptEventTypes` (intentional — allow-list only, additive later).
- **Where the predicate is applied:** in the single delivery primitive
  `processEvents` (`Worker.hs`), in the per-event branch, *before* `handler config
  event`. A non-matching event skips the handler and falls through to `go (i+1)`;
  the batch-tail `saveCheckpoint` (unchanged) advances the cursor past it. This is
  upstream of EP-40's disposition logic and EP-40's ack-coupled bridge, so a
  filtered-out event is never delivered, retried, or dead-lettered.
- **Config surface:** `eventTypeFilter :: !EventTypeFilter` added to
  `SubscriptionConfigM` (default `AllEventTypes` in `defaultSubscriptionConfig`);
  forwarded through the Streamly bridge unchanged (element type stays
  `RecordedEvent`); added to `shibuya-kiroku-adapter`'s `KirokuAdapterConfig` and
  EP-42's `KirokuConsumerGroupConfig` (threaded into every per-member adapter),
  with `EventTypeFilter (..)` re-exported from the adapter module.
- **Test results:** `kiroku-store-test` — **0 failures**, including the new
  `Test.EventTypeFilter` (selective delivery; checkpoint past a trailing filtered
  event; no-stall over 1 A / 1000 B / 1 A → `last_seen = 1002`, 2 deliveries;
  filter-before-dead-letter → 0 dead-letter rows, checkpoint advanced).
  `shibuya-kiroku-adapter-test` — **17 examples, 0 failures**, including the new
  single-adapter filter test (delivers only As, positions `[1,3,5]`) and the
  consumer-group+filter test (size-4 group, 20 streams of `[A,B]` → delivered A
  positions `sort == [1,3..39]`, disjoint + complete).
- **Against the Purpose:** a caller can declare `eventTypeFilter = OnlyEventTypes
  {…}` on a native subscription (and, by forwarding, on a Streamly stream or
  Shibuya adapter) and observe only matching deliveries while the checkpoint
  advances past everything else — proven end-to-end at the worker, which is where
  the filter lives.


## Context and Orientation

This section assumes no prior knowledge of the repository. It names every file by
full repository-relative path and defines each term of art the first time it is
used.

### Terms

- **Event type.** The application-level discriminator for an event payload, e.g.
  `"OrderCreated"`. In Kiroku it is the field `eventType` on a recorded event,
  with type `EventType`, a `newtype` wrapper over `Text`. The store stores it but
  does not interpret it.
- **Recorded event.** The value the store hands to a subscription handler, of type
  `RecordedEvent`, defined in `kiroku-store/src/Kiroku/Store/Types.hs`. It carries
  `eventType :: EventType` and `globalPosition :: GlobalPosition` among other
  fields.
- **Global position.** A strictly increasing, gap-free counter shared across all
  streams (`newtype GlobalPosition = GlobalPosition Int64`). It is the cursor a
  subscription uses to remember progress.
- **Checkpoint.** A durable row in `kiroku.subscriptions` holding `last_seen`, the
  highest global position a subscription has processed. On restart the worker
  resumes from `last_seen`. The checkpoint advances by being written via
  `saveCheckpointMemberStmt` (in `kiroku-store/src/Kiroku/Store/SQL.hs`).
- **Selector.** EventStore's name for an in-memory per-event filter
  (`RecordedEvent.t -> any`). When it returns falsy the event is not sent to the
  subscriber but is still marked acknowledged. We reproduce the *behavior*, not
  the function-typed shape (see Decision Log).
- **Broadcast publisher.** The single fan-out component
  (`kiroku-store/src/Kiroku/Store/Subscription/EventPublisher.hs`) that reads
  appended events once and pushes them into each live subscriber's bounded queue.
  It is shared by all `$all` subscribers; this plan does not touch it.
- **Consumer group.** A named subscription split into `N` static members, each
  member receiving the streams whose name hashes to its slot, each with its own
  checkpoint keyed by `(subscription_name, member)`. Defined by `ConsumerGroup`
  in `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`.

### The data is already present: `RecordedEvent` and `EventType`

In `kiroku-store/src/Kiroku/Store/Types.hs`, the event type is a `newtype` over
text:

```haskell
{- | The application-level discriminator for an event payload (e.g.
@"OrderCreated"@). Free-form text; the store does not interpret it.
-}
newtype EventType = EventType Text
    deriving stock (Eq, Ord, Show, Generic)
```

`EventType` already derives `Ord`, which is exactly what we need to put it in a
`Data.Set.Set`. The recorded event carries it directly:

```haskell
data RecordedEvent = RecordedEvent
    { eventId :: !EventId
    , eventType :: !EventType
    -- ^ The application-level type discriminator.
    , streamVersion :: !StreamVersion
    , globalPosition :: !GlobalPosition
    -- ... remaining fields ...
    }
    deriving stock (Eq, Show, Generic)
```

So a worker-side filter has everything it needs in hand: it reads
`eventType event` and checks membership in a set.

### The unrelated `EventFilter` — do not reuse it

The same module already exports a type called `EventFilter`. It is **not** for
subscriptions:

```haskell
data EventFilter
    = -- | Match every event whose @correlation_id@ equals the supplied UUID.
      FilterCorrelation !UUID
    | FilterCausationDescendants !EventId
    | FilterCausationAncestors !EventId
    deriving stock (Eq, Show, Generic)
```

Its doc comment says it is "passed to the `Kiroku.Store.Effect.FindEvents`
constructor … Each constructor maps to one SQL statement." It is a
correlation/causation **query** filter. This plan introduces a separate type with
a distinct name (`EventTypeFilter`) so the two are never confused. Do not extend
or reuse `EventFilter`.

### The subscription config: `SubscriptionConfigM`

The shared record lives in
`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`:

```haskell
data SubscriptionConfigM m = SubscriptionConfig
    { name :: !SubscriptionName
    , target :: !SubscriptionTarget
    , handler :: !(EventHandlerM m)
    , batchSize :: !Int32
    , queueCapacity :: !Natural
    , overflowPolicy :: !OverflowPolicy
    , consumerGroup :: !(Maybe ConsumerGroup)
    , consumerGroupGuard :: !Bool
    }
```

with the smart constructor that callers use:

```haskell
defaultSubscriptionConfig ::
    SubscriptionName ->
    SubscriptionTarget ->
    EventHandlerM m ->
    SubscriptionConfigM m
defaultSubscriptionConfig name' target' handler' =
    SubscriptionConfig
        { name = name'
        , target = target'
        , handler = handler'
        , batchSize = 100
        , queueCapacity = 16
        , overflowPolicy = DropSubscription
        , consumerGroup = Nothing
        , consumerGroupGuard = False
        }
```

This plan adds one field, `eventTypeFilter :: !EventTypeFilter`, and one default
line, `eventTypeFilter = AllEventTypes`.

Note: some tests in `kiroku-store/test/Main.hs` build `SubscriptionConfig` with a
**full record literal** (every field listed explicitly, e.g. the `catchup-test`
config) rather than via `defaultSubscriptionConfig`. Adding a non-optional field
to the record will force those literals to be updated. The Plan of Work calls this
out as a required mechanical edit so the build does not break.

### Where the handler is actually called: `processEvents`

The worker is `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`. Its three
live loops (`liveLoop`, `liveLoopCategoryNotify`, `liveLoopDbDriven`) and the
catch-up loop (`catchUp`) all funnel each fetched batch through one function,
`processEvents`. This is the single place the handler is invoked, and the single
place the checkpoint is saved:

```haskell
processEvents pool config events emit posRef = go 0
  where
    go i
        | i >= V.length events = do
            let lastEvent = V.last events
                newPos = globalPosition lastEvent
            writeIORef posRef newPos
            saveCheckpoint pool config newPos emit
            pure (Just newPos)
        | otherwise = do
            let event = events V.! i
                evtPos = globalPosition event
            writeIORef posRef evtPos
            result <- handler config event
            case result of
                Stop -> do
                    -- Save checkpoint up to the event we just processed
                    saveCheckpoint pool config evtPos emit
                    pure Nothing
                Continue -> go (i + 1)
```

Read the control flow carefully, because it is what makes the no-stall property
free. When `go` reaches the end of the batch (`i >= V.length events`), it computes
`newPos` as `globalPosition (V.last events)` — the global position of the **last
event in the batch, of whatever type** — writes that to the in-memory cursor
(`posRef`) and saves it as the checkpoint. It does this **regardless of how many
handler calls happened**. The per-event branch calls `handler config event` for
each event and only checkpoints early (at `evtPos`) if the handler returns `Stop`.

Therefore, if we change the per-event branch so that for a **non-matching** event
we skip the `handler config event` call entirely and fall straight through to
`go (i + 1)` (treating it exactly like a `Continue` that delivered nothing), then:

- The handler is never invoked for filtered-out events.
- The loop still walks to the batch tail and `saveCheckpoint` still fires at
  `globalPosition (V.last events)`.
- The cursor therefore advances past every event in the batch, matching or not.

A long run of non-matching events between two matching ones lands in one or more
batches; each batch's tail checkpoint moves the cursor past all of them. The
subscription cannot stall. This is the mechanism M3 must prove.

### EventStore precedent

`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store/subscriptions/subscription_fsm.ex`
applies the selector in `enqueue_events` and, for filtered events, records them as
acknowledged so the checkpoint advances:

```text
defp enqueue_events(%SubscriptionState{} = data, [event | events]) do
  ...
  data =
    if selected?(event, data) do
      enqueue_event(data, event)            # send to subscriber
    else
      # Filtered event, don't send to subscriber, but track it as ack'd.
      %SubscriptionState{ data
        | acknowledged_event_numbers: MapSet.put(acknowledged_event_numbers, event_number) }
      |> track_sent(event_number)
    end
  data |> track_last_received(event_number) |> enqueue_events(events)
end

defp selected?(event, %SubscriptionState{selector: selector}) when is_function(selector, 1),
  do: selector.(event)
defp selected?(_event, %SubscriptionState{}), do: true
```

The public option is documented in
`/Users/shinzui/Keikaku/hub/event-sourcing/eventstore/lib/event_store.ex`:
"`selector` to define a function to filter each event." Kiroku reproduces the
behavior; because Kiroku checkpoints at the batch tail, it needs no explicit
`acknowledged_event_numbers` set — the tail save subsumes it.

### The Streamly bridge

`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs` turns a push-based
subscription into a pull-based `Stream IO RecordedEvent`. It installs its own
handler that enqueues every event and returns `Continue`:

```haskell
let bridgeHandler :: RecordedEvent -> IO SubscriptionResult
    bridgeHandler event = do
        atomically $ writeTBQueue queue (Just event)
        pure Continue

let bridgeConfig = config { handler = bridgeHandler }
```

Because the worker applies the filter **before** calling `handler config event`,
the bridge handler is simply not invoked for filtered-out events. The bridge needs
**no element-type change**: it still enqueues `RecordedEvent`, it just receives
fewer of them. Surfacing the filter through this path is purely a matter of
letting callers set the `eventTypeFilter` field on the `config` they pass to
`subscriptionStream` (the bridge already preserves every other field of `config`
and overrides only `handler`).

### The Shibuya adapter

`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` wraps a Kiroku subscription
as a Shibuya `Adapter`. Its config record `KirokuAdapterConfig` is the
operator-facing surface, and `kirokuAdapter` builds a `SubscriptionConfigM` from
`defaultSubscriptionConfig`:

```haskell
let subConfig =
        (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
            { batchSize = bs
            , queueCapacity = 16
            , overflowPolicy = DropSubscription
            , consumerGroup = cg
            }
```

This plan adds an `eventTypeFilter` field to `KirokuAdapterConfig` and forwards it
into `subConfig` via one more record override. Because filtering happens
worker-side before the bridge, the conversion module
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` and the
adapter's `AckHandle` need **no change**.

### Sibling plans

- `docs/plans/41-explicit-subscription-worker-finite-state-machine-with-recoverable-backpressure-and-live-reconnect.md`
  (EP-41, the FSM). Soft dependency. It introduces
  `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs` with a `SubscriptionState`,
  an `Input`/`Effect` model, and a single `step` function; delivery becomes a
  "deliver this event" `Effect`. Our filter is applied in that delivery
  transition.
- `docs/plans/40-per-event-retry-and-dead-letter-for-kiroku-subscriptions-and-the-shibuya-adapter.md`
  (EP-40, retry/dead-letter). It makes the bridge ack-coupled so handlers can
  return retry/dead-letter dispositions. **Ordering matters:** our filter runs
  before the handler/bridge, so a filtered-out event never reaches the bridge and
  is never retried or dead-lettered. Both plans add a field to
  `SubscriptionConfigM`; the additions are independent and additive.
- `docs/plans/42-wire-kiroku-consumer-groups-into-the-shibuya-partitioned-ordering-policy-model.md`
  (EP-42, consumer-group config helper). Its helper builds one
  `SubscriptionConfigM` per group member. Our filter field must be forwarded into
  each per-member config so a partitioned group can also be type-filtered (the
  same filter on every member).

### Test harnesses

- `kiroku-store-test` (cabal suite name `kiroku-store-test`, main
  `kiroku-store/test/Main.hs`). Shared helpers in
  `kiroku-store/test/Test/Helpers.hs` provide `withTestStore` (ephemeral migrated
  PostgreSQL + `KirokuStore`), `makeEvent typ payload` (an `EventData` with type
  `typ`), `waitForPublisher store (GlobalPosition n)` (block until the publisher
  has ingested through `n`), and `waitWithTimeout micros handle`. Subscriptions
  are started with `subscribe store cfg` and awaited via the handle. New test
  modules must be added to `other-modules` in
  `kiroku-store/kiroku-store.cabal` and invoked from `Main.hs`.
- `shibuya-kiroku-adapter-test` (cabal suite name `shibuya-kiroku-adapter-test`,
  main `shibuya-kiroku-adapter/test/Main.hs`). It builds adapters via
  `kirokuAdapter store KirokuAdapterConfig{..}`, wires them into Shibuya with
  `mkProcessor`/`runApp`, drains with `waitForCount`/`waitForTotal`, and reads the
  delivered payloads with `envelopePayload`. The handler returns `AckOk` (or
  `error "..."` to simulate a crash).

To assert the checkpoint advanced past filtered events, a test reads
`kiroku.subscriptions.last_seen` for the subscription name via a raw `Hasql`
statement (the pattern used throughout `Test/Helpers.hs` and `Test/ConsumerGroup.hs`,
e.g. `preparable "SELECT last_seen FROM subscriptions WHERE subscription_name = $1 AND consumer_group_member = $2" ...`).
Non-group subscriptions use member `0` (see `configMember` in `Worker.hs`).


## Plan of Work

The work is three milestones. M1 lands the type, the config field, and the
worker-side application with one focused acceptance test. M2 threads the filter
through the Streamly bridge and the Shibuya adapter. M3 hardens with the no-stall,
filter-before-dead-letter, and (conditionally) consumer-group tests. Prefer to land
this plan after EP-41; the worker edit below is written for the current imperative
`processEvents`, with an explicit note on how it moves onto EP-41's FSM delivery
transition.

### Milestone M1 — define the filter, add the config field, apply it in the worker

Scope: introduce the filter type, add it to the shared config with a no-op
default, and make `processEvents` skip the handler for non-matching events while
still advancing the checkpoint. At the end of M1, a native `kiroku-store`
subscription honors `OnlyEventTypes` and its checkpoint advances past filtered
events.

Concrete edits:

1. In `kiroku-store/src/Kiroku/Store/Subscription/Types.hs`, define the filter
   type and a tiny predicate, and export both. Place the definition near the top
   of the module (after the imports). Add `import Data.Set (Set)` and
   `import qualified Data.Set as Set`, and import `EventType` and
   `RecordedEvent` from `Kiroku.Store.Types` (the module already imports
   `RecordedEvent`; add `EventType`).

   ```haskell
   {- | A declarative, closed filter over event types for a subscription.

   'AllEventTypes' (the default) delivers every event. @'OnlyEventTypes' s@
   delivers only events whose 'eventType' is in @s@; all other events are
   skipped (the handler is not called) but the subscription checkpoint still
   advances past them, so a highly selective subscription never stalls.

   This is intentionally a closed sum, not an opaque @RecordedEvent -> Bool@,
   so it stays introspectable (and a future SQL pushdown can read the set out
   of it). It is unrelated to 'Kiroku.Store.Types.EventFilter', which filters
   correlation/causation /queries/.
   -}
   data EventTypeFilter
       = AllEventTypes
       | OnlyEventTypes !(Set EventType)
       deriving stock (Eq, Show)

   {- | True when an event should be delivered to the handler under the filter. -}
   eventTypeMatches :: EventTypeFilter -> RecordedEvent -> Bool
   eventTypeMatches AllEventTypes _ = True
   eventTypeMatches (OnlyEventTypes s) ev = eventType ev `Set.member` s
   ```

   Add `EventTypeFilter (..)` and `eventTypeMatches` to the module's export list.

2. In the same module, add the field to `SubscriptionConfigM`:

   ```haskell
   , eventTypeFilter :: !EventTypeFilter
   {- ^ Which event types this subscription delivers. Default
   'AllEventTypes' (deliver everything). When 'OnlyEventTypes', the worker
   skips the handler for non-matching events but still advances the
   checkpoint past them, so the subscription never stalls on a long run of
   filtered-out events. Applied worker-side before the handler/bridge, so a
   filtered-out event is never retried or dead-lettered.
   -}
   ```

   and the default line in `defaultSubscriptionConfig`:

   ```haskell
   , eventTypeFilter = AllEventTypes
   ```

3. In `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, apply the predicate
   in `processEvents`'s per-event branch. Import `eventTypeMatches` and
   `eventTypeFilter` (the module already imports `Kiroku.Store.Subscription.Types`
   unqualified, so both are in scope). Change only the `otherwise` branch:

   ```haskell
   | otherwise = do
       let event = events V.! i
           evtPos = globalPosition event
       writeIORef posRef evtPos
       if eventTypeMatches (eventTypeFilter config) event
           then do
               result <- handler config event
               case result of
                   Stop -> do
                       saveCheckpoint pool config evtPos emit
                       pure Nothing
                   Continue -> go (i + 1)
           else
               -- Filtered out: do not call the handler, but keep walking the
               -- batch so the batch-tail checkpoint advances past this event.
               go (i + 1)
   ```

   The batch-tail branch (`i >= V.length events`) is **unchanged**: it still saves
   `globalPosition (V.last events)`. That is the line that guarantees the cursor
   advances past filtered events. Leave it exactly as it is.

   On EP-41: once `Fsm.hs` exists, this `if`/`then`/`else` moves into the FSM's
   delivery transition. In EP-41's model the per-event step yields a "deliver this
   event to the handler" `Effect` for matching events and **no deliver effect**
   (but the same cursor advance) for non-matching events. The predicate
   `eventTypeMatches (eventTypeFilter config)` is evaluated at that transition; the
   set lives in the FSM context derived from the config. The acceptance behavior is
   identical either way; only the location of the branch differs.

4. In `kiroku-store/test/Main.hs`, update every **full record literal** for
   `SubscriptionConfig` to add `, eventTypeFilter = AllEventTypes` (the
   `catchup-test`, `live-test`, `ckpt-test`, `transition-no-duplicates`, and any
   sibling literals). Configs built via `defaultSubscriptionConfig` (e.g. in
   `Test/ConsumerGroup.hs`'s `memberConfig`) need no change — they inherit the
   default.

Commands and acceptance: see Concrete Steps. Acceptance is a new test in a new
module `kiroku-store/test/Test/EventTypeFilter.hs` (added to the cabal
`other-modules` and called from `Main.hs`): append a mixed `A`/`B` stream, run a
subscription with `OnlyEventTypes (Set.fromList [EventType "A"])`, assert only `A`
events were delivered, and assert the persisted `last_seen` equals the **last
global position of any event** (not the last `A`).

### Milestone M2 — surface through the Streamly bridge and the Shibuya adapter

Scope: let Streamly and Shibuya callers set the filter. At the end of M2, an
adapter-backed Shibuya handler receives only matching types.

Concrete edits:

1. Streamly bridge (`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`): no
   code change is required — `subscriptionStream` already copies the caller's
   `config` and overrides only `handler`, so the caller's `eventTypeFilter` is
   already preserved and applied by the worker. Confirm this by reading the
   `bridgeConfig` construction (it is `config { handler = bridgeHandler }`). Add a
   sentence to the function's Haddock stating that the filter is honored and that
   the stream element type is unchanged (`RecordedEvent`), because the filter runs
   before the bridge handler.

2. Shibuya adapter (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`):

   - Add an export and import for `EventTypeFilter (..)` from
     `Kiroku.Store.Subscription.Types` (the module already imports several names
     from there).
   - Add the field to `KirokuAdapterConfig`:

     ```haskell
     , eventTypeFilter :: !EventTypeFilter
     {- ^ Which event types this adapter delivers. Default-style usage passes
     'AllEventTypes' (deliver everything). Forwarded into the underlying
     subscription; filtering is worker-side, so 'Convert.hs' and the
     'AckHandle' are unaffected.
     -}
     ```

   - Thread it through `kirokuAdapter`. The function currently pattern-matches the
     config positionally as `KirokuAdapterConfig subName subTarget bs buf cg`; add
     the new field to that match (e.g. `... cg etf`) and forward it into the
     `subConfig` override:

     ```haskell
     let subConfig =
             (defaultSubscriptionConfig subName subTarget (\_ -> pure Continue))
                 { batchSize = bs
                 , queueCapacity = 16
                 , overflowPolicy = DropSubscription
                 , consumerGroup = cg
                 , eventTypeFilter = etf
                 }
     ```

   - Update the module's example Haddock and the "Ack Semantics" prose only if
     needed for clarity (optional). Update every `KirokuAdapterConfig{..}` literal
     in `shibuya-kiroku-adapter/test/Main.hs` to add
     `, eventTypeFilter = AllEventTypes` so the existing suite still compiles.

3. EP-42 integration: when EP-42's consumer-group config helper exists, add the
   `eventTypeFilter` field to that helper's config and forward it into each
   per-member `SubscriptionConfigM` it builds (the same filter on every member).
   If EP-42 has not landed when M2 is implemented, record that as a follow-up in
   Progress and the Decision Log; the single-adapter forwarding above is complete
   and independent.

Acceptance: a new `describe` block in `shibuya-kiroku-adapter/test/Main.hs`:
append a mixed `A`/`B` stream, build an adapter with
`eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])`, run it through
Shibuya, and assert the handler's collected payloads are only `A` events.

### Milestone M3 — no-stall, filter-before-dead-letter, and consumer-group tests

Scope: prove the defining property and the cross-plan orderings. These are tests
only (plus any small helper).

1. **No-stall over a long run of non-matching events** (in
   `kiroku-store/test/Test/EventTypeFilter.hs`). Append, in order, 1 event of type
   `A`, then 1000 events of type `B`, then 1 event of type `A` (global positions
   1..1002). Run a subscription with `OnlyEventTypes (Set.fromList [EventType "A"])`
   that stops after it has seen 2 events. Assert: exactly 2 events delivered, both
   of type `A` (global positions 1 and 1002); and the persisted `last_seen` is
   `1002`, proving the cursor advanced past the 1000 `B`s. Use `batchSize` larger
   than 1002 (or assert across batches) so the run spans the catch-up path. This is
   the headline acceptance of the whole plan.

2. **Filter-before-dead-letter** (placement depends on EP-40). If EP-40 has landed,
   add a test (in `kiroku-store/test/Test/EventTypeFilter.hs` or the adapter suite,
   wherever the dead-letter API is reachable) where the handler returns the
   dead-letter disposition for **every** event it sees, but the subscription is
   filtered to `OnlyEventTypes {A}` over a stream of `B`s. Assert: the handler is
   never invoked for the `B`s, no dead-letter row is written for any `B`, and the
   checkpoint still advances past them. If EP-40 has not landed, record this as a
   pending assertion in Progress and add it when EP-40 merges; the worker edit in
   M1 already guarantees the behavior (filtered events never reach the handler, so
   they cannot be dead-lettered).

3. **Consumer-group-plus-filter** (placement depends on EP-42). If EP-42's helper
   has landed, add a test that runs a size-N group with the same `eventTypeFilter`
   on every member over a mixed-type stream and asserts each member delivers only
   matching types from its partition and the union of delivered matching events is
   complete. If EP-42 has not landed, prove the equivalent with the existing
   per-member adapters (build N adapters by hand, each with the same filter, as
   `shibuya-kiroku-adapter/test/Main.hs` already does for consumer groups) and note
   the helper-based assertion as a follow-up.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` unless noted. The project
uses Cabal; the two relevant test suites are `kiroku-store-test` (in
`kiroku-store/kiroku-store.cabal`) and `shibuya-kiroku-adapter-test` (in
`shibuya-kiroku-adapter/`). The suites bracket an ephemeral PostgreSQL instance
themselves, so no external database setup is needed.

Build the library after the M1 type/field/worker edits:

```bash
cabal build kiroku-store
```

Expected: a clean build. If you see an error like

```text
Worker.hs:494:13: error: [GHC-XXXXX]
    Not in scope: ‘eventTypeMatches’
```

you forgot to export it from `Subscription.Types` or to add it to the import — fix
the export list / import and rebuild.

Add the new test module to `kiroku-store/kiroku-store.cabal` under the
`kiroku-store-test` suite's `other-modules` (alphabetically near the others):

```text
  other-modules:
    ...
    Test.EventTypeFilter
    ...
```

and call `EventTypeFilter.spec` from `kiroku-store/test/Main.hs` alongside the
other specs.

Run the kiroku-store suite (M1 + M3 native tests):

```bash
cabal test kiroku-store-test
```

Expected transcript (abbreviated; the new lines are what prove this plan):

```text
event-type filter
  delivers only matching types and advances the checkpoint past filtered events
  never stalls on a long run of non-matching events (1 A, 1000 B, 1 A)
    last_seen advanced to 1002 with only 2 A events delivered
  does not dead-letter a filtered-out type      # present once EP-40 has landed

Finished in 12.34 seconds
NNN examples, 0 failures
```

Build and run the adapter suite (M2):

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter-test
```

Expected (abbreviated):

```text
kirokuAdapter
  ...
  delivers only matching event types when an eventTypeFilter is set

Finished in N.NN seconds
MMM examples, 0 failures
```

To inspect the checkpoint directly while iterating, the test reads it via a raw
statement; the shape of that query (for reference when writing the helper) is:

```sql
SELECT last_seen
FROM subscriptions
WHERE subscription_name = $1 AND consumer_group_member = $2
```

with member `0` for a non-group subscription.


## Validation and Acceptance

Acceptance is behavioral, phrased as inputs and observable outputs.

1. **Selective delivery (M1).** Given a stream seeded with events of types `A`,
   `B`, `A`, `B`, `A` (global positions 1..5) and a subscription configured with
   `eventTypeFilter = OnlyEventTypes (Set.fromList [EventType "A"])`: the handler is
   invoked exactly three times, each time with an `A` event (positions 1, 3, 5),
   and never with a `B`. After the subscription has processed the batch, the row in
   `kiroku.subscriptions` for this name has `last_seen = 5` (the last global
   position of any event), not `5` "because the last A was at 5" by coincidence —
   re-run the assertion with a trailing `B` (types `A`,`B` only, last event `B` at
   position 2) and confirm `last_seen = 2` while only the `A` at position 1 was
   delivered. This second variant is the unambiguous proof that the checkpoint
   advances past a trailing filtered event.

2. **No-stall over a long non-matching run (M3, headline).** Given 1 `A`, then 1000
   `B`, then 1 `A` (positions 1..1002) and `OnlyEventTypes {A}`: exactly two
   deliveries, both `A` (positions 1 and 1002), and `last_seen = 1002`. The
   subscription completes promptly (well within the 10-second test timeout); it
   does not hang waiting on the `B` run. This is the property the whole plan exists
   to guarantee, and it follows directly from the batch-tail checkpoint in
   `processEvents` (quoted above).

3. **Streamly + Shibuya delivery (M2).** Through `subscriptionStream` the produced
   `Stream IO RecordedEvent` yields only `A` events (element type unchanged).
   Through `kirokuAdapter` with the same filter, the Shibuya handler's collected
   payloads are only `A` events. Concretely, the adapter test appends a mixed
   stream, drains with `waitForCount`, and asserts the collected list contains no
   `B`.

4. **Filter-before-dead-letter (M3, once EP-40 has landed).** A handler that
   dead-letters everything, behind a filter of `OnlyEventTypes {A}` over a stream
   of `B`s: zero handler invocations, zero dead-letter rows for `B`, checkpoint
   advanced past the `B`s. This proves filtered-out events never reach the
   ack-coupled bridge.

A change is "effective beyond compilation" because each test fails on `master`
before the edits (there is no `eventTypeFilter` field, so the test would not even
type-check, and behaviorally a subscription delivers every type) and passes after.


## Idempotence and Recovery

Every edit here is additive and safe to apply repeatedly:

- Adding `EventTypeFilter`, the `eventTypeFilter` field, and the default line is
  idempotent — re-running the edit yields the same source. The default
  `AllEventTypes` makes the field invisible to existing callers, so no migration,
  data change, or behavioral change occurs for subscriptions that do not set it.
- There is no database schema change in this plan (the filter is in-memory). No
  migration to run, nothing to roll back at the database level.
- The worker edit changes only the per-event branch of `processEvents`; the
  batch-tail checkpoint logic is untouched, so checkpoint semantics for unfiltered
  subscriptions are bit-for-bit identical. Recovery after a restart is unchanged:
  the worker resumes from `last_seen`, which — because filtered events advance it —
  is past any filtered run, so no filtered event is re-scanned and re-skipped after
  a restart (it simply is not re-fetched).
- If a test reveals the predicate is mis-placed (e.g. applied after the handler),
  the fix is local to `processEvents` (or the FSM delivery transition) and the
  acceptance tests above catch the regression.


## Interfaces and Dependencies

New and changed interfaces, with full module paths.

In `Kiroku.Store.Subscription.Types`
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs`):

```haskell
data EventTypeFilter
    = AllEventTypes
    | OnlyEventTypes !(Data.Set.Set Kiroku.Store.Types.EventType)
    deriving stock (Eq, Show)

eventTypeMatches :: EventTypeFilter -> Kiroku.Store.Types.RecordedEvent -> Bool

-- added field on the existing record:
--   eventTypeFilter :: !EventTypeFilter   (default AllEventTypes in
--   defaultSubscriptionConfig)
```

Both `EventTypeFilter (..)` and `eventTypeMatches` are added to the module's export
list. `Data.Set` (from `containers`, already a dependency of `kiroku-store`) and
`Kiroku.Store.Types.EventType` are the only new imports.

In `Kiroku.Store.Subscription.Worker`
(`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`): no signature changes;
`processEvents` gains the `eventTypeMatches (eventTypeFilter config) event` guard in
its per-event branch. The batch-tail checkpoint is unchanged.

In `Kiroku.Store.Subscription.Stream`
(`kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`): no signature change;
`subscriptionStream` already forwards every config field except `handler`, so the
filter flows through unchanged. Documentation note only.

In `Shibuya.Adapter.Kiroku`
(`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`):

```haskell
data KirokuAdapterConfig = KirokuAdapterConfig
    { -- ...existing fields...
    , eventTypeFilter :: !EventTypeFilter
    }

-- kirokuAdapter forwards eventTypeFilter into the SubscriptionConfigM it builds
-- from defaultSubscriptionConfig.
```

`EventTypeFilter (..)` is re-exported from this module (alongside the existing
`ConsumerGroup (..)` re-export) so adapter callers need not import
`kiroku-store`'s subscription module directly.

Dependencies and agreements with sibling plans:

- **EP-41 (`docs/plans/41-...`), soft dependency.** Prefer to land after it. The
  predicate moves from `processEvents` into the FSM delivery transition in
  `kiroku-store/src/Kiroku/Store/Subscription/Fsm.hs`: matching events yield the
  deliver `Effect`, non-matching events yield no deliver effect but the same cursor
  advance. Behavior is identical; only the branch's home changes.
- **EP-40 (`docs/plans/40-...`), ordering agreement.** Filter runs before the
  handler/bridge. A filtered-out event never reaches EP-40's ack-coupled bridge and
  is never retried or dead-lettered. Both plans add a field to `SubscriptionConfigM`
  (EP-40 a retry policy, this plan `eventTypeFilter`); the additions are
  independent, and whichever lands second rebases onto the merged record. M3's
  filter-before-dead-letter test enforces the ordering.
- **EP-42 (`docs/plans/42-...`), forwarding agreement.** EP-42's consumer-group
  config helper must forward `eventTypeFilter` into each per-member
  `SubscriptionConfigM` it builds (the same filter on every member), and its adapter
  config must carry the field. If EP-42 lands after this plan, that forwarding is
  EP-42's responsibility; this plan's single-adapter forwarding is complete on its
  own.
- No `shibuya-core` changes. No database migration. `containers` (`Data.Set`) is the
  only library leaned on that was not already in use; it is an existing dependency.


## Revision Notes

- 2026-05-29 — Initial authoring from the skeleton. Filled every section with
  source-grounded content: quoted `RecordedEvent`/`EventType`, the unrelated
  `EventFilter`, `SubscriptionConfigM`/`defaultSubscriptionConfig`, and
  `processEvents` (batch-tail checkpoint); specified the `EventTypeFilter` type and
  `eventTypeMatches`; placed the predicate in the per-event branch of
  `processEvents` with the FSM mapping for EP-41; defined three milestones with real
  cabal suite names (`kiroku-store-test`, `shibuya-kiroku-adapter-test`) and
  expected transcripts; and recorded the settled decisions (in-memory worker-side,
  filtering-only, closed declarative type, soft-dep on EP-41, filter-before-bridge
  ordering). Reason: turn the coordinated MasterPlan 6 child-plan-4 design into a
  self-contained, executable plan.
- 2026-05-29 — Implemented. M1 (type + config field + worker predicate), the
  Streamly/adapter forwarding (M2), and the test coverage (M3) all landed.
  `kiroku-store-test` grew `Test.EventTypeFilter` (selective delivery,
  checkpoint-past-trailing-filtered, no-stall, filter-before-dead-letter), 0
  failures; `shibuya-kiroku-adapter-test` grew a single-adapter filter test and a
  consumer-group+filter test → 17 examples, 0 failures. All milestones done; no
  deferrals.
