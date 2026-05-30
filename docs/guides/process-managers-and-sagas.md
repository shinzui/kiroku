# Process Managers And Sagas

A [projection](building-a-projection.md) reacts to events by updating a *read
model* — it observes. A **process manager** reacts to events by *issuing new
commands* — it acts. It is the component that drives a multi-step workflow
across several aggregates: when an order is placed, take payment; when payment
succeeds, reserve inventory; when payment fails, cancel the order. This guide
builds one end to end on Kiroku's primitives — subscriptions to react,
`causationId` / `correlationId` to track the workflow, optimistic concurrency to
make the process manager crash-safe, and the causal queries to reconstruct a
run after the fact.

It builds directly on [Subscriptions](../user/subscriptions.md),
[Appending Events](../user/appending-events.md), and
[Causation And Correlation](../user/causation-correlation.md); read those first.

## Process Manager Vs Saga

The terms overlap; the distinction that matters in practice:

- A **process manager** is a small state machine with an identity. It tracks
  *where a workflow is* ("awaiting payment", "reserving inventory") and decides
  the next command from its current state plus the incoming event.
- A **saga** is the failure-handling discipline layered on top: every forward
  step has a **compensating** action, so a workflow that cannot complete is
  *unwound* (refund the payment, release the reservation) rather than left
  half-done. Event stores give you no distributed two-phase commit; a saga is how
  you get eventual consistency with explicit, recorded compensations instead.

In Kiroku both are the same shape: a subscription whose handler reads workflow
state, decides, and appends. This guide builds the process manager first, then
adds saga compensation.

## The Four Building Blocks

| Concern | Primitive |
| --- | --- |
| **React** to events as they happen | A [subscription](../user/subscriptions.md) on the triggering category. |
| **Remember** workflow state durably | The process manager's *own* event stream, e.g. `order-fulfillment-<id>`, written with optimistic concurrency. |
| **Act** by issuing the next command | `appendToStream` / `appendMultiStream` to the target aggregate, carrying `causationId` + `correlationId`. |
| **Trace** the whole run | `correlationId` shared across every event; `findByCorrelation` / `findCausationDescendants` to reconstruct it. |

The defining design choice is the second row: **a process manager is itself an
aggregate.** It does not hold its state only in memory — it records its decisions
as events in its own stream. That stream is what makes it crash-recoverable and
replay-safe, exactly as event-sourced state makes any aggregate recoverable.

## The Workflow We Will Build

Order fulfillment, coordinating three aggregates — `orders-*`, `payments-*`,
`inventory-*` — driven by one process manager stream per order,
`order-fulfillment-*`:

```text
orders-42        OrderPlaced ─────────────┐  correlationId = w
                                          ▼
order-fulfillment-42   FulfillmentStarted │  (PM records: awaiting payment)
                                          │
payments-42      PaymentRequested ◀───────┘  causationId = OrderPlaced.id,  corr = w
                       │
        ┌──────────────┴───────────────┐
        ▼ (success)                     ▼ (failure)
payments-42 PaymentTaken          payments-42 PaymentFailed
        │                                │
        ▼                                ▼
inventory-42 StockReserved        orders-42 OrderCancelled   ◀── compensation
        │                                │
        ▼                                ▼
order-fulfillment-42 Completed    order-fulfillment-42 Aborted
```

The process manager subscribes to the events that drive it (`OrderPlaced`,
`PaymentTaken`, `PaymentFailed`, `StockReserved`), and for each one records a
state event in `order-fulfillment-*` *and* issues the next command.

## Step 1: Subscribe To The Triggers

A process manager is a subscription whose handler issues commands. Run it under
the **effectful** subscription API so the handler can call store operations
(`appendToStream`, reads) directly in the same `Eff` stack — that is the natural
fit when the handler must both read and write the store:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Control.Lens ((^.))
import Effectful (Eff, IOE, (:>))
import Kiroku.Store
import Kiroku.Store.Subscription (SubscriptionResult (..), SubscriptionName (..),
                                  SubscriptionTarget (..), defaultSubscriptionConfig)
import Kiroku.Store.Subscription.Effect (Subscription, withSubscription)

runFulfillmentPM ::
  (IOE :> es, Store :> es, Subscription :> es) => Eff es ()
runFulfillmentPM = do
  let cfg =
        defaultSubscriptionConfig
          (SubscriptionName "order-fulfillment-pm")     -- durable cursor
          AllStreams                                    -- see "Routing" below
          fulfillmentHandler
  withSubscription cfg $ \h -> do
    _ <- wait h
    pure ()
```

Interpret the `Subscription` effect with `runSubscription store` (re-exported
from `Kiroku.Store`); the `Effect`-module `subscribe` / `withSubscription` are
imported explicitly because they are deliberately *not* re-exported, to avoid
clashing with the `MonadIO` versions (see
[The Effectful API](../user/subscriptions.md#the-effectful-api)).

The handler dispatches on event type and delegates to one step per trigger:

```haskell
fulfillmentHandler ::
  (Store :> es) => RecordedEvent -> Eff es SubscriptionResult
fulfillmentHandler event =
  case event ^. #eventType of
    EventType "OrderPlaced"  -> onOrderPlaced event  >> pure Continue
    EventType "PaymentTaken" -> onPaymentTaken event >> pure Continue
    EventType "PaymentFailed"-> onPaymentFailed event >> pure Continue
    EventType "StockReserved"-> onStockReserved event >> pure Continue
    _                        -> pure Continue          -- not a trigger; advance
```

## Step 2: Make Each Reaction Idempotent

The hard part of a process manager is not the happy path — it is that the
subscription is **at-least-once**, so every trigger can be delivered more than
once (a crash before the checkpoint saved, a paused-and-resumed worker; see
[Delivery Semantics](../user/subscriptions.md#delivery-semantics)). If
`OnOrderPlaced` issues `PaymentRequested` every time it runs, a single replay
charges the customer twice. A process manager **must not double-issue commands
on replay.** Two techniques, used together, give you that:

### Technique A — Gate on the process manager's own state stream

Before acting, read the process manager's state stream and act only if it has
not already taken this step. The state stream's version doubles as the concurrency
token: write the state-advancing event with `ExactVersion`, so two concurrent
reactions cannot both advance it.

```haskell
import Data.Vector qualified as V

-- React to OrderPlaced exactly once per order.
onOrderPlaced :: (Store :> es) => RecordedEvent -> Eff es ()
onOrderPlaced placed = do
  let oid       = orderIdOf placed                        -- e.g. "42"
      pmStream  = StreamName ("order-fulfillment-" <> oid)
  existing <- readStreamForward pmStream (StreamVersion 0) 1
  if not (V.null existing)
    then pure ()                                          -- already started; replay → no-op
    else do
      let EventId placedUuid = placed ^. #eventId
          corr               = placed ^. #correlationId   -- inherit or seed below
      -- 1. record PM state: this order is now "awaiting payment"
      _ <- appendToStream pmStream NoStream
             [ EventData
                 { eventId       = Nothing
                 , eventType     = EventType "FulfillmentStarted"
                 , payload       = ...
                 , metadata      = Nothing
                 , causationId   = Just placedUuid
                 , correlationId = corr
                 } ]
      -- 2. issue the command to the payments aggregate
      _ <- appendToStream (StreamName ("payments-" <> oid)) NoStream
             [ EventData
                 { eventId       = Nothing
                 , eventType     = EventType "PaymentRequested"
                 , payload       = ...
                 , metadata      = Nothing
                 , causationId   = Just placedUuid       -- caused by OrderPlaced
                 , correlationId = corr                  -- same workflow id
                 } ]
      pure ()
```

The `NoStream` precondition on `FulfillmentStarted` is itself a guard: if a
concurrent delivery already created the process manager stream, the second append
fails with `StreamAlreadyExists` and you treat that as "already handled." For
later steps that advance an *existing* state stream, read the current version and
write with `ExactVersion v`; a losing racer gets `WrongExpectedVersion`,
re-reads, and sees the step is done. See
[Optimistic Concurrency](../user/appending-events.md#optimistic-concurrency-expectedversion).

### Technique B — Deterministic command ids

Even with the state gate, the *command append* and the *state append* are two
separate calls, and a crash between them replays the trigger. Make the command
append idempotent on its own by deriving a **deterministic `eventId`** for it
from the trigger — a UUIDv5 of `(triggerEventId, "PaymentRequested")`, say — so a
replay re-issues the *same* id and the store rejects the duplicate:

```haskell
-- a retry re-derives the same eventId; the duplicate is rejected, not re-charged
let cmdId = deterministicUuid (placed ^. #eventId) "PaymentRequested"
appendToStream paymentStream AnyVersion
  [ cmd { eventId = Just (EventId cmdId) } ]
  -- second time: DuplicateEvent → treat as success
```

On replay one of two things happens: the previous attempt did not commit (the
retry succeeds), or it did (the retry surfaces `DuplicateEvent`, which you treat
as success). This is the same idempotency mechanism as
[idempotent retries on append](../user/appending-events.md#idempotent-retries),
applied to commands. Use **both** techniques: the state gate keeps the workflow
logic clean, and deterministic ids close the crash-between-two-appends window.

## Step 3: Carry Causation And Correlation

Every event a process manager appends should record *why* it happened. This is
not bookkeeping — it is what lets you reconstruct, audit, and debug a workflow
later (Step 5).

- **`correlationId`** — one id shared by *every* event in the workflow. Seed it
  on the first event of the workflow (often the originating command/event) and
  **inherit it unchanged** on every reaction. A common convention is to seed it
  from the originating event's own id when the trigger has none:

  ```haskell
  let corr = case placed ^. #correlationId of
               Just w  -> Just w                          -- already in a workflow
               Nothing -> let EventId u = placed ^. #eventId in Just u
  ```

- **`causationId`** — the raw `UUID` of the single event that *directly* caused
  this one. Set it to the trigger's `eventId` on every reaction:

  ```haskell
  let EventId triggerUuid = trigger ^. #eventId
  -- ... causationId = Just triggerUuid
  ```

Note `causationId` and `correlationId` are raw `UUID`s in `EventData`, while a
`RecordedEvent` carries `eventId :: EventId` — unwrap the `EventId` newtype when
you copy it into a cause. See
[Causation And Correlation](../user/causation-correlation.md#the-causal-model).

## Step 4: Issue Coupled Commands Atomically

When a single reaction must advance the process manager state *and* command
another aggregate, and you want them to be all-or-nothing within Kiroku, use
`appendMultiStream` — it writes to several streams in one transaction, pre-locking
them in deterministic `stream_id` order so concurrent multi-stream reactions
cannot deadlock:

```haskell
-- advance PM state AND command inventory in one atomic step
_ <- appendMultiStream
       [ (pmStream,            ExactVersion v, [stockReservingEvent])
       , (StreamName invStream, AnyVersion,    [reserveStockCommand]) ]
```

Either both land or neither does. Use this when a partially-applied reaction
would leave the workflow inconsistent. When the extra write is to a *non-event*
table (a scheduler row, an external-call audit), use
[`runTransactionAppending`](../user/appending-events.md#transactional-appends)
instead, which threads a continuation into the same transaction.

A caveat for command-issuing process managers: appending a command to a *target*
aggregate stream and advancing your *own* state stream in the same
`appendMultiStream` couples the two aggregates' consistency. That is sometimes
what you want and sometimes too strong — often it is cleaner to advance PM state
first, then issue the command as a separate idempotent append (Technique B), so a
failure to command the target does not roll back the recorded decision. Choose
per step; the default for cross-aggregate workflows is *separate appends made
idempotent*, reserving `appendMultiStream` for writes that are genuinely one
fact.

## Step 5: Reconstruct A Run

Because every event carries the workflow's `correlationId` and a `causationId`
chain, you can reconstruct any run without having stored a workflow log yourself:

```haskell
-- the complete timeline of one workflow, across every stream it touched,
-- in global-position order
timeline <- findByCorrelation workflowUuid

-- everything that flowed from the originating event (the causal tree)
downstream <- findCausationDescendants (placed ^. #eventId)

-- "why did this OrderCancelled happen?" — the chain that produced it
why <- findCausationAncestors (cancelled ^. #eventId)
```

`findByCorrelation` is the saga's audit log; `findCausationDescendants` answers
"what did this command set in motion?"; `findCausationAncestors` answers "what
led here?". All three are fan-in reads returning only `originalStreamId` — resolve
names in one round trip with `lookupStreamNames` if you need them for display. See
[Causation And Correlation](../user/causation-correlation.md).

## Adding Saga Compensation

A process manager becomes a saga when each forward step has a recorded
**compensation** for the failure path. In the example, `PaymentFailed` is the
trigger that unwinds an in-flight order:

```haskell
onPaymentFailed :: (Store :> es) => RecordedEvent -> Eff es ()
onPaymentFailed failed = do
  let oid      = orderIdOf failed
      pmStream = StreamName ("order-fulfillment-" <> oid)
  st <- readStreamForward pmStream (StreamVersion 0) 1000
  -- only compensate if we are actually mid-fulfillment and not already aborted
  case fulfillmentState st of
    AwaitingPayment v -> do
      let EventId cause = failed ^. #eventId
          corr          = failed ^. #correlationId
      -- compensation: cancel the order, and record the PM as aborted, atomically
      _ <- appendMultiStream
             [ (StreamName ("orders-" <> oid), AnyVersion,
                 [orderCancelledCmd cause corr])
             , (pmStream, ExactVersion v,
                 [fulfillmentAbortedEvent cause corr]) ]
      pure ()
    _ -> pure ()        -- already terminal or never started → no-op (idempotent)
```

The compensation rules that keep a saga correct:

- **Compensations are themselves events**, appended like any forward step,
  carrying `causationId` / `correlationId`. They are auditable and replay-safe.
- **Only compensate steps that actually happened.** Gate on the process manager
  state stream (`fulfillmentState`) so a `PaymentFailed` for an order that was
  never started, or already aborted, is a no-op. This is the same idempotency
  discipline as the forward path.
- **Compensation is forward recovery, not rollback.** You do not "undo" the
  payment-request event — it is immutable history. You append a *new* event
  (`OrderCancelled`, `StockReleased`) that returns the system to a consistent
  state. Event sourcing has no `DELETE`; it has compensation.

## Timeouts And Scheduling

Many sagas need "if payment has not completed within 30 minutes, cancel." Kiroku
has **no built-in timers or delayed delivery** — be explicit about this in your
design. The standard pattern is an external scheduler that appends a timeout
*event* the process manager already knows how to react to:

1. When the process manager enters `AwaitingPayment`, record the deadline (in the
   `FulfillmentStarted` payload, or a side table written via
   `runTransactionAppending`).
2. A periodic job (cron, a polling worker) scans for workflows past their
   deadline and appends a `PaymentTimedOut` event to the relevant stream.
3. The process manager handles `PaymentTimedOut` exactly like `PaymentFailed` —
   same gated, idempotent compensation.

Modeling the timeout as a real appended event keeps the entire workflow — including
*why* it was cancelled — inside the log and reconstructable with the causal
queries. Do not try to drive timeouts from the subscription itself; it only
wakes on appends.

## Routing: One Process Manager, Many Instances

The handler above subscribes to `AllStreams` and routes by deriving the workflow
id (`orderIdOf`) from each event. That is the simplest deployment: one worker,
all workflow instances multiplexed through it, per-instance state isolated by the
`order-fulfillment-<id>` stream. It scales to a high event rate because each
reaction is a few indexed appends.

When one worker cannot keep up, the scaling story has a sharp edge worth stating:
a [consumer group](../user/consumer-groups.md) partitions by **originating
`stream_id`**, but a process manager's triggers arrive on *several* streams
(`orders-42`, `payments-42`, `inventory-42`) that hash to *different* members.
The events for one workflow would therefore be split across members, breaking the
"one worker owns one workflow instance" property the state gate relies on. Options,
in order of preference:

- **Keep a single process-manager worker** and scale by making each reaction
  cheap. This is sufficient for most workflows.
- **Subscribe by a single triggering category** (e.g. a `Category "orders"`
  subscription that reacts only to order-level events) when the workflow's
  decisions can all be driven from one aggregate's stream — then a consumer group
  *does* co-partition correctly, because every trigger for a given order shares
  the `orders-<id>` stream.
- **Funnel triggers into a per-workflow inbox stream** with
  [`linkToStream`](../user/linking.md) — link every relevant event into
  `fulfillment-inbox-<id>` and subscribe a group to that category, so each
  workflow's events share one stream id and one member. This costs an extra link
  per event but restores clean per-instance partitioning.

Whichever you choose, the idempotency discipline (state gate + deterministic
command ids) is what keeps the workflow correct under replay — it does not depend
on the routing.

## Testing A Process Manager

A process manager is a deterministic function from a trigger sequence to a set of
appended commands, which makes it testable without mocks: against an ephemeral
PostgreSQL, append the trigger events, run the handler (directly, or via a
subscription until it catches up), and assert on the resulting streams —
`findByCorrelation` returns the whole run for a single, shape-agnostic assertion.
Test the replay case explicitly: deliver the same trigger twice and assert the
command stream did not grow. The repository's subscription tests
(`kiroku-store/test/Test/ConsumerGroup.hs`,
`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs`) show the seed-run-assert
mechanics to model on.

## See Also

- [Building A Projection](building-a-projection.md) — the companion pattern:
  react to events by updating a *read model* rather than issuing commands.
- [Consuming The Event Log](consuming-the-event-log.md) — the subscription
  mechanics a process manager reacts through: catch-up, filtering, the effectful
  API, retry/dead-letter, and scaling/routing.
- [Appending Events](../user/appending-events.md) — `ExpectedVersion`, idempotent
  retries, `appendMultiStream`, and transactional appends — the write side of
  every reaction.
- [Causation And Correlation](../user/causation-correlation.md) — set and walk the
  `causationId` / `correlationId` links that tie a workflow together.
- [Subscriptions](../user/subscriptions.md) — the delivery semantics, retry/
  dead-letter dispositions, and effectful API the handler runs in.
- [Linking Events](../user/linking.md) — build a per-workflow inbox stream for
  clean consumer-group routing.
- [Consumer Groups](../user/consumer-groups.md) — and the partitioning caveat that
  shapes how a process manager scales.
