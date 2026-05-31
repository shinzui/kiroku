{- | Structured operational events emitted by 'Kiroku.Store'.

This module provides the 'KirokuEvent' sum type and its supporting
enumerations. It complements
'Kiroku.Store.Connection.ConnectionSettings.observationHandler' (which
covers @hasql-pool@'s connection-lifecycle events) with events the
package emits itself:

* Notifier reconnection (the dedicated @LISTEN@ connection went bad and
  is being re-established).
* EventPublisher pool errors (the publisher's read query failed and
  will retry on the next tick or 30-second safety poll).
* Per-subscription database errors (checkpoint load, batch fetch,
  checkpoint save).
* Subscription lifecycle (started, caught-up, paused, resumed, reconnecting,
  stopped).
* Subscription batch delivery (one per non-empty batch handed to the
  handler, on every target and in both catch-up and live phases).
* Subscription live fetches (one per DB-driven live-mode fetch).
* Hard-delete issuance (a fail-safe audit signal — see
  @docs\/PRODUCTION-DEPLOYMENT.md@ for the recommended in-band audit
  pattern).

Wire 'Kiroku.Store.Connection.ConnectionSettingsM.eventHandler' to a
callback that forwards to your structured logger or metrics pipeline.
The callback runs synchronously on the emit-site thread (notifier loop,
publisher loop, worker loop, store interpreter); slow callbacks therefore
stall those loops. For callbacks that may block, fan out asynchronously
(write to a 'Control.Concurrent.STM.TBQueue' and drain in a separate
thread).

The constructor set is /additive/: new events are added rather than
existing constructors changed. Pattern matches that do not handle a
new constructor will surface as @-Wincomplete-patterns@ warnings, never
as silent regressions.
-}
module Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionDeliveryPhase (..),
    SubscriptionStopReason (..),
    SubscriptionGroupContext (..),
    DeadLetterReason (..),
) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Hasql.Pool (UsageError)
import Kiroku.Store.Subscription.Fsm (DeadLetterReason (..), SubscriptionStopReason (..))
import Kiroku.Store.Subscription.Types (SubscriptionName)
import Kiroku.Store.Types (GlobalPosition, StreamId, StreamName)

{- | A structured operational event emitted by 'Kiroku.Store' itself.

Events are emitted synchronously from the originating thread; consumer
callbacks should be fast or fan out to an asynchronous worker. See the
module Haddock for context.
-}
data KirokuEvent
    = {- | The dedicated @LISTEN@ connection encountered a non-async
      exception and the listener loop is about to attempt reconnection.
      The 'Int' is the consecutive failure count starting at @1@; it
      drives the exponential-backoff delay (capped at 30 seconds) and
      is useful as a metric label for sustained-outage alerting.
      -}
      KirokuEventNotifierReconnecting !Int !SomeException
    | {- | The listener loop successfully re-established the @LISTEN@
      connection. Pairs with the most recent
      'KirokuEventNotifierReconnecting'; the failure counter resets to
      @0@ on observing this event.
      -}
      KirokuEventNotifierReconnected
    | {- | The 'Kiroku.Store.Subscription.EventPublisher.EventPublisher'
      read query returned a 'UsageError'. The publisher will retry on
      the next notification tick or the 30-second safety poll. Sustained
      emissions indicate either pool exhaustion (the publisher shares
      the application pool) or a persistent server error.
      -}
      KirokuEventPublisherPoolError !UsageError
    | {- | A subscription's worker thread encountered a 'UsageError' in
      the database phase identified by 'SubscriptionDbPhase'. The
      worker may continue with a documented fallback for checkpoint
      load/save phases, while fetch-batch errors are retried at the same
      cursor. The event is the operator's structured signal that this
      happened. The trailing 'SubscriptionGroupContext' identifies which
      consumer-group member (if any) emitted it.
      -}
      KirokuEventSubscriptionDbError !SubscriptionName !SubscriptionDbPhase !UsageError !SubscriptionGroupContext
    | {- | A subscription's worker thread has just started; the worker
      will begin from the recorded 'GlobalPosition' (zero if no
      checkpoint exists or 'KirokuEventSubscriptionDbError' fired in
      the @LoadCheckpoint@ phase). The trailing 'SubscriptionGroupContext'
      identifies which consumer-group member (if any) started.
      -}
      KirokuEventSubscriptionStarted !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | {- | The subscription has reached the EventPublisher's
      @lastPublished@ position and is switching from catch-up to
      live mode at the indicated 'GlobalPosition'. Fires at most
      once per worker run. The trailing 'SubscriptionGroupContext'
      identifies which consumer-group member (if any) caught up.
      -}
      KirokuEventSubscriptionCaughtUp !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | {- | The subscription's worker has stopped at the indicated
      'GlobalPosition'. The 'SubscriptionStopReason' discriminates
      normal completion (handler returned 'Stop') from cancellation,
      overflow, and worker-thread crashes. The trailing
      'SubscriptionGroupContext' identifies which consumer-group member
      (if any) stopped.
      -}
      KirokuEventSubscriptionStopped !SubscriptionName !GlobalPosition !SubscriptionStopReason !SubscriptionGroupContext
    | {- | A subscription's worker hit recoverable backpressure: its bounded
      queue filled under the 'Kiroku.Store.Subscription.Types.PauseAndResume'
      overflow policy, so the worker paused delivery at the indicated
      'GlobalPosition'. Pairs with a subsequent
      'KirokuEventSubscriptionResumed'. The trailing 'SubscriptionGroupContext'
      identifies which consumer-group member (if any) paused.
      -}
      KirokuEventSubscriptionPaused !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | {- | A subscription's worker resumed after a pause: it drained the stale
      queue and re-catches-up from its checkpoint (the indicated
      'GlobalPosition') so every event skipped while paused is re-read from the
      database. Pairs with a preceding 'KirokuEventSubscriptionPaused'.
      -}
      KirokuEventSubscriptionResumed !SubscriptionName !GlobalPosition !SubscriptionGroupContext
    | {- | A subscription's worker lost its database connection while live (a
      'UsageError' on a live-mode fetch) and is reconnecting: it backs off and
      re-catches-up from its checkpoint rather than dying. The 'Int' is the
      consecutive reconnect-attempt count starting at @1@; it drives the
      capped backoff and is a useful sustained-outage metric label. Emitted by
      Category and consumer-group subscriptions (AllStreams live delivery is fed
      by the publisher, which owns its own reconnect). The trailing
      'SubscriptionGroupContext' identifies the consumer-group member (if any).
      -}
      KirokuEventSubscriptionReconnecting !SubscriptionName !Int !SubscriptionGroupContext
    | {- | A live DB-driven subscription loop
      ('Kiroku.Store.Subscription.Worker') issued one category/partition fetch
      in live mode, returning the given row count ('Int'). Emitted by the
      @Category@ NOTIFY-driven loop and the consumer-group loop on every live
      fetch (not on the catch-up path). Lets operators observe the
      per-subscription live-fetch rate and lets tests assert that an idle
      category does no work. The trailing 'SubscriptionGroupContext' identifies
      the consumer-group member (if any).
      -}
      KirokuEventSubscriptionFetched !SubscriptionName !Int !SubscriptionGroupContext
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
    | {- | A subscription handler returned
      'Kiroku.Store.Subscription.Types.Retry' for the event at the indicated
      'GlobalPosition' and the worker is about to redeliver it. The 'Int' is the
      redelivery attempt count starting at @1@ (so @1@ is the first redelivery
      after the initial delivery). Bounded by the subscription's
      'Kiroku.Store.Subscription.Types.RetryPolicy'; exhaustion produces a
      'KirokuEventSubscriptionDeadLettered' with
      'Kiroku.Store.Subscription.Types.DeadLetterMaxAttempts'. The trailing
      'SubscriptionGroupContext' identifies the consumer-group member (if any).
      -}
      KirokuEventSubscriptionRetrying !SubscriptionName !GlobalPosition !Int !SubscriptionGroupContext
    | {- | The worker recorded the event at the indicated 'GlobalPosition' in
      @kiroku.dead_letters@ with the given 'DeadLetterReason' and atomically
      advanced the checkpoint past it. Emitted when a handler returns
      'Kiroku.Store.Subscription.Types.DeadLetter' or when retry attempts are
      exhausted. The trailing 'SubscriptionGroupContext' identifies the
      consumer-group member (if any).
      -}
      KirokuEventSubscriptionDeadLettered !SubscriptionName !GlobalPosition !DeadLetterReason !SubscriptionGroupContext
    | {- | A hard-delete transaction completed successfully. Operators
      relying on a fail-safe audit log can capture this event;
      compliance-grade audit should still record an application-level
      event /before/ calling
      'Kiroku.Store.Lifecycle.hardDeleteStream' (see
      @docs\/PRODUCTION-DEPLOYMENT.md@). Not emitted when the named
      stream did not exist.
      -}
      KirokuEventHardDeleteIssued !StreamName !StreamId
    deriving stock (Show)

-- | Which database phase a 'KirokuEventSubscriptionDbError' fired in.
data SubscriptionDbPhase
    = {- | 'Kiroku.Store.Subscription.Worker' failed to read the saved
      checkpoint at subscription startup. The worker continues with
      'Kiroku.Store.Types.GlobalPosition' @0@; on a fresh subscription
      this is correct, on an existing subscription it silently
      re-processes events.
      -}
      LoadCheckpoint
    | {- | The worker's catch-up or category-live database fetch
      returned an error. The worker retries the same cursor with capped
      backoff instead of treating the error as an empty result.
      -}
      FetchBatch
    | {- | The worker's @saveCheckpoint@ statement failed. The
      subscription continues running but the next restart with the
      same name re-processes events the handler has already seen.
      -}
      SaveCheckpoint
    deriving stock (Eq, Show)

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

{- | Consumer-group context attached to subscription lifecycle events. A plain
(non-grouped) subscription reports 'NonGroup'; a member of a group reports
@GroupMember member size@ so operators can attribute a lifecycle event to a
specific @(member, size)@.
-}
data SubscriptionGroupContext
    = -- | Ordinary, non-grouped subscription.
      NonGroup
    | -- | Member of a group: @GroupMember member size@.
      GroupMember !Int32 !Int32
    deriving stock (Eq, Show)
