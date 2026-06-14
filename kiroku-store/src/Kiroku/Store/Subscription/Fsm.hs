{-# OPTIONS_GHC -Werror=incomplete-patterns #-}

{- | The explicit finite state machine driving a subscription worker.

A subscription worker is, at every instant, in exactly one named
'SubscriptionState'. A single, exhaustively pattern-matched transition
function 'step' names every legal move: given the current state and an
'Input' (a thing that just happened — a batch arrived, a fetch failed, the
queue overflowed, …) it returns the next state and a list of 'Effect's the
/driver/ ('Kiroku.Store.Subscription.Worker.runWorker') must perform.

Keeping the transition table in one pure function has two payoffs:

  * It is the single, documented /extension seam/ for the sibling plan
    @docs\/plans\/40-...@ (per-event retry \/ dead-letter). When that plan adds
    a 'Kiroku.Store.Subscription.Types.SubscriptionResult' constructor it will
    also add a matching 'Input' constructor; because 'step' is exhaustively
    pattern-matched on 'Input' within each driving state and this module is
    compiled with @-Werror=incomplete-patterns@, that addition fails to
    compile until every relevant clause handles it, rather than falling
    through silently.
  * There is exactly one place to read the current state for observability
    (the worker mirrors it into a @TVar@ — see M4).

This module is deliberately a near-leaf in the dependency graph: it depends
only on 'Kiroku.Store.Types' and @hasql-pool@, never on
'Kiroku.Store.Subscription.Types' or 'Kiroku.Store.Observability'. That keeps
the graph acyclic once 'Kiroku.Store.Subscription.Types' grows a handle field
of type 'SubscriptionState'. The terminal-reason enumeration
'SubscriptionStopReason' lives here for the same reason and is re-exported by
'Kiroku.Store.Observability' so the public event API is unchanged.
-}
module Kiroku.Store.Subscription.Fsm (
    -- * State
    SubscriptionState (..),
    ResumeCondition (..),
    stateCursor,
    stateName,

    -- * Terminal reasons
    SubscriptionStopReason (..),

    -- * Per-event dispositions (retry / dead-letter)
    RetryDelay (..),
    retryDelayMicros,
    DeadLetterReason (..),
    deadLetterSummary,
    deadLetterReasonJson,

    -- * Driver alphabet
    Input (..),
    Effect (..),

    -- * Transition function
    step,
) where

import Control.Exception (SomeException)
import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..))

{- | Why a subscription's worker thread stopped.

Defined here (rather than in 'Kiroku.Store.Observability') so the FSM's
'Stopped' state can carry it without 'Kiroku.Store.Subscription.Fsm' having to
import the observability module — which would close a dependency cycle once
'Kiroku.Store.Subscription.Types' references 'SubscriptionState'.
'Kiroku.Store.Observability' re-exports this type, so the @KirokuEvent@ API is
unchanged.
-}
data SubscriptionStopReason
    = {- | The handler returned 'Kiroku.Store.Subscription.Types.Stop' for some
      event. The normal completion path; the checkpoint is saved at that event.
      -}
      StopHandlerRequested
    | {- | The caller invoked @cancel@. No checkpoint advance is guaranteed;
      in-flight events replay on the next restart.
      -}
      StopCancelled
    | {- | The publisher marked the subscription overflowed under
      'Kiroku.Store.Subscription.Types.DropSubscription' and the worker
      surfaced 'Kiroku.Store.Subscription.Types.SubscriptionOverflowed'.
      -}
      StopOverflowed
    | {- | The worker thread died from an uncaught exception (typically a handler
      exception). The 'SomeException' carries the cause.
      -}
      StopWorkerCrashed !SomeException
    deriving stock (Show)

{- | How long to wait before redelivering a retried event.

The handler's @Kiroku.Store.Subscription.Types.Retry@ disposition carries one of
these; the worker sleeps for it before the next redelivery. Mirrors Shibuya's
@Shibuya.Core.Ack.RetryDelay@ shape (a 'NominalDiffTime') so the
@shibuya-kiroku-adapter@ can translate @AckRetry@ without loss, but is a
Kiroku-owned type so @kiroku-store@ does not depend on @shibuya-core@.
-}
newtype RetryDelay = RetryDelay NominalDiffTime
    deriving stock (Eq, Show)

{- | The retry delay in microseconds, clamped at @0@, suitable for
'Control.Concurrent.threadDelay'. Fractional seconds are rounded.
-}
retryDelayMicros :: RetryDelay -> Int
retryDelayMicros (RetryDelay d) = max 0 (round (realToFrac d * 1_000_000 :: Double))

{- | Why an event was dead-lettered (recorded in @kiroku.dead_letters@ while the
subscription advances past it). Kiroku-owned so @kiroku-store@ stays independent
of @shibuya-core@; the adapter converts Shibuya's @DeadLetterReason@ into one of
these. 'deadLetterSummary' produces the @reason_summary@ text column and
'deadLetterReasonJson' the structured @reason@ JSONB column.
-}
data DeadLetterReason
    = -- | Permanently unprocessable; the 'Text' is operator-facing detail.
      DeadLetterPoison !Text
    | -- | The event payload failed validation/parsing; the 'Text' is the detail.
      DeadLetterInvalid !Text
    | -- | The bounded retry budget was exhausted after the given number of total deliveries.
      DeadLetterMaxAttempts !Int
    | -- | A custom reason: a summary plus structured JSON detail.
      DeadLetterOther !Text !Value
    deriving stock (Eq, Show)

-- | The short operator-facing summary stored in @dead_letters.reason_summary@.
deadLetterSummary :: DeadLetterReason -> Text
deadLetterSummary = \case
    DeadLetterPoison detail -> "poison: " <> detail
    DeadLetterInvalid detail -> "invalid payload: " <> detail
    DeadLetterMaxAttempts n -> "max retry attempts exceeded (" <> T.pack (show n) <> ")"
    DeadLetterOther summary _ -> summary

-- | The structured JSON detail stored in @dead_letters.reason@ (JSONB).
deadLetterReasonJson :: DeadLetterReason -> Value
deadLetterReasonJson = \case
    DeadLetterPoison detail -> object ["kind" .= ("poison" :: Text), "detail" .= detail]
    DeadLetterInvalid detail -> object ["kind" .= ("invalid_payload" :: Text), "detail" .= detail]
    DeadLetterMaxAttempts n -> object ["kind" .= ("max_attempts_exceeded" :: Text), "attempts" .= n]
    DeadLetterOther summary detail -> object ["kind" .= ("other" :: Text), "summary" .= summary, "detail" .= detail]

{- | What unblocks a 'Paused' worker.

In M1 there is one resume condition: the bounded queue has drained enough that
the publisher cleared the subscriber's @Paused@ flag. The constructor is named
rather than a bare unit so a future backpressure source (e.g. an explicit
resume signal) can be added without changing the 'SubscriptionState' shape.
-}
data ResumeCondition
    = -- | Resume once the consumer drains its bounded queue.
      ResumeOnDrain
    deriving stock (Eq, Show)

{- | The named state a subscription worker is in.

  * 'CatchingUp' — reading history directly from PostgreSQL in batches from
    @cursor@ until it reaches the publisher's last-published position.
    @attempt@ counts consecutive failed catch-up fetches and drives the
    capped exponential backoff; it resets to 0 on any successful fetch.
  * 'Live' — caught up; receiving new events (from the publisher's bounded
    queue for AllStreams, or by re-querying for Category / consumer-group
    members).
  * 'Paused' — recoverable backpressure: a slow consumer filled its bounded
    queue, so the worker stopped pulling and waits for 'resumeWhen' (added in
    M2; in M1 this state is defined but never entered).
  * 'Reconnecting' — recovering from a lost database connection while live;
    backs off and re-enters 'CatchingUp' from @cursor@ (added in M3; in M1
    defined but never entered).
  * 'Retrying' — a handler returned
    'Kiroku.Store.Subscription.Types.Retry' for the event at @cursor@; the
    worker is redelivering it (@attempt@ counts redeliveries so far) and has not
    advanced the checkpoint past it. Added by the sibling retry\/dead-letter plan
    (@docs\/plans\/40-...@). It is a /surfaced observability state/: the worker's
    delivery primitive writes it into the observable state @TVar@ while a
    redelivery is pending and restores the prior driving state afterward, so it is
    visible through @currentState@ but is never itself a driving state fed back to
    'step' (the @Retrying@ clause in 'step' is therefore defensive).
  * 'Stopped' — terminal, carrying the 'SubscriptionStopReason'.
-}
data SubscriptionState
    = CatchingUp {cursor :: !GlobalPosition, attempt :: !Int}
    | Live {cursor :: !GlobalPosition}
    | Paused {cursor :: !GlobalPosition, resumeWhen :: !ResumeCondition}
    | Reconnecting {cursor :: !GlobalPosition, attempt :: !Int}
    | Retrying {cursor :: !GlobalPosition, attempt :: !Int}
    | Stopped {reason :: !SubscriptionStopReason}
    deriving stock (Show)

{- | The cursor of a non-terminal state, or 'GlobalPosition' @0@ for 'Stopped'.
Used by the driver to attach the current position to emitted events.
-}
stateCursor :: SubscriptionState -> GlobalPosition
stateCursor = \case
    CatchingUp c _ -> c
    Live c -> c
    Paused c _ -> c
    Reconnecting c _ -> c
    Retrying c _ -> c
    Stopped _ -> GlobalPosition 0

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

{- | A thing that just happened, fed to 'step' to compute the next state.

The set is closed in M1; the sibling retry\/dead-letter plan extends it. Adding
a constructor here forces a compile error in every driving-state clause of
'step' that does not yet handle it (this module is @-Werror=incomplete-patterns@).
-}
data Input
    = -- | A non-empty history\/live batch arrived.
      BatchFetched !(Vector RecordedEvent)
    | -- | A fetch returned no rows (catch-up is complete).
      FetchEmpty
    | -- | A fetch hit a database error.
      FetchFailed !Pool.UsageError
    | -- | The cursor reached the publisher position; switch to live.
      CaughtUp
    | -- | The handler returned 'Stop' at this position.
      HandlerStopped !GlobalPosition
    | {- | The bounded queue filled under the fail-fast 'DropSubscription' policy
      (terminal).
      -}
      QueueOverflowed
    | {- | The bounded queue filled under the recoverable 'PauseAndResume' policy:
      pause rather than terminate.
      -}
      QueueBackpressured
    | -- | The worker drained the stale queue and is ready to recover (re-catch-up).
      QueueDrained
    | -- | The worker lost its database pool while live.
      ConnectionLost !Pool.UsageError
    | -- | The caller cancelled the worker.
      Cancelled
    deriving stock (Show)

{- | A side effect the driver must perform after a transition.

Some constructors (e.g. 'FetchHistory', 'RunLive') describe work the driver
already performs by inspecting the next state; they exist so the effect list is
a complete description of the transition for future drivers and for readers.
-}
data Effect
    = -- | Read a catch-up batch from the given cursor.
      FetchHistory !GlobalPosition
    | -- | Obtain the next live batch via the active live strategy.
      RunLive
    | -- | Call the handler per event, checkpointing at the batch tail.
      DeliverBatch !(Vector RecordedEvent)
    | {- | Persist the checkpoint at this position. (Named 'Checkpoint' rather
      than @SaveCheckpoint@ to avoid clashing with the
      'Kiroku.Store.Observability.SubscriptionDbPhase' constructor of that name.)
      -}
      Checkpoint !GlobalPosition
    | -- | Block until the consumer drains the queue.
      WaitForDrain
    | -- | Sleep for the backoff schedule of this attempt number.
      Backoff !Int
    | -- | Emit @KirokuEventSubscriptionCaughtUp@.
      EmitCaughtUp
    | -- | Emit @KirokuEventSubscriptionPaused@ (M4).
      EmitPaused
    | -- | Emit @KirokuEventSubscriptionResumed@ (M4).
      EmitResumed
    | -- | Emit @KirokuEventSubscriptionReconnecting@ with this attempt (M4).
      EmitReconnecting !Int
    | -- | Terminal: stop the driver with this reason (return or rethrow).
      Halt !SubscriptionStopReason
    deriving stock (Show)

-- The last event's position in a batch, falling back to the given cursor when
-- the batch is empty (the driver never feeds 'step' an empty 'BatchFetched',
-- so the fallback is defensive).
lastPos :: GlobalPosition -> Vector RecordedEvent -> GlobalPosition
lastPos fallback evs
    | V.null evs = fallback
    | otherwise = globalPosition (V.last evs)

{- | The single transition function. Given the current state and an input,
return the next state and the effects to perform.

Exhaustively pattern-matched on 'Input' within the two /driving/ states
('CatchingUp', 'Live') so that extending 'Input' (the retry\/dead-letter
sibling plan) forces a compile error here. The recoverable states 'Paused' and
'Reconnecting' carry their M2\/M3 transitions plus defensive self-loops; the
terminal 'Stopped' state ignores further input.
-}
step :: SubscriptionState -> Input -> (SubscriptionState, [Effect])
step st input = case st of
    CatchingUp c n -> case input of
        BatchFetched evs -> (CatchingUp (lastPos c evs) 0, [DeliverBatch evs])
        FetchEmpty -> (Live c, [EmitCaughtUp])
        FetchFailed _ -> (CatchingUp c (n + 1), [Backoff n])
        CaughtUp -> (Live c, [EmitCaughtUp])
        HandlerStopped _ -> (Stopped StopHandlerRequested, [Halt StopHandlerRequested])
        QueueOverflowed -> (Stopped StopOverflowed, [Halt StopOverflowed])
        QueueBackpressured -> (CatchingUp c n, []) -- defensive: catch-up reads the DB, not the queue
        QueueDrained -> (CatchingUp c n, [])
        ConnectionLost _ -> (Reconnecting c 1, [EmitReconnecting 1, Backoff 1])
        Cancelled -> (Stopped StopCancelled, [Halt StopCancelled])
    Live c -> case input of
        BatchFetched evs -> (Live (lastPos c evs), [DeliverBatch evs])
        FetchEmpty -> (Live c, [RunLive])
        FetchFailed _ -> (Reconnecting c 1, [EmitReconnecting 1, Backoff 1])
        CaughtUp -> (Live c, [])
        HandlerStopped _ -> (Stopped StopHandlerRequested, [Halt StopHandlerRequested])
        QueueOverflowed -> (Stopped StopOverflowed, [Halt StopOverflowed])
        QueueBackpressured -> (Paused c ResumeOnDrain, [EmitPaused])
        QueueDrained -> (Live c, [RunLive])
        ConnectionLost _ -> (Reconnecting c 1, [EmitReconnecting 1, Backoff 1])
        Cancelled -> (Stopped StopCancelled, [Halt StopCancelled])
    Paused c rc -> case input of
        -- The worker drained the stale queue and cleared the pause flag; recover
        -- by re-catching-up from the checkpoint so any events the publisher
        -- skipped while full are re-read from the database. No loss; the live
        -- queue's stale filter drops the now-superseded queued entries on return.
        QueueDrained -> (CatchingUp c 0, [EmitResumed])
        Cancelled -> (Stopped StopCancelled, [Halt StopCancelled])
        HandlerStopped _ -> (Stopped StopHandlerRequested, [Halt StopHandlerRequested])
        _ -> (Paused c rc, [])
    Reconnecting c n -> case input of
        BatchFetched evs -> (CatchingUp (lastPos c evs) 0, [DeliverBatch evs])
        FetchEmpty -> (Live c, [])
        FetchFailed _ -> (Reconnecting c (n + 1), [EmitReconnecting (n + 1), Backoff (n + 1)])
        ConnectionLost _ -> (Reconnecting c (n + 1), [EmitReconnecting (n + 1), Backoff (n + 1)])
        CaughtUp -> (CatchingUp c 0, [])
        HandlerStopped _ -> (Stopped StopHandlerRequested, [Halt StopHandlerRequested])
        Cancelled -> (Stopped StopCancelled, [Halt StopCancelled])
        QueueOverflowed -> (Reconnecting c n, [])
        QueueBackpressured -> (Reconnecting c n, [])
        QueueDrained -> (Reconnecting c n, [])
    -- 'Retrying' is a surfaced observability state managed inside the worker's
    -- delivery primitive (it sets the observable @TVar@ to 'Retrying' while a
    -- redelivery is pending and restores the prior driving state afterward); it
    -- is never a driving state fed back to 'step'. This clause is therefore
    -- defensive — only cancellation / a handler stop could plausibly race in, and
    -- both terminate; anything else returns to 'Live' at the same cursor.
    Retrying c _ -> case input of
        Cancelled -> (Stopped StopCancelled, [Halt StopCancelled])
        HandlerStopped _ -> (Stopped StopHandlerRequested, [Halt StopHandlerRequested])
        _ -> (Live c, [])
    Stopped r -> (Stopped r, [])
