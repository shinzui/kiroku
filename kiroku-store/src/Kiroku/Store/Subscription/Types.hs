module Kiroku.Store.Subscription.Types (
    SubscriptionName (..),
    SubscriptionTarget (..),
    SubscriptionResult (..),
    OverflowPolicy (..),
    SubscriptionOverflowed (..),
    EventHandlerM,
    EventHandler,
    SubscriptionConfigM (..),
    SubscriptionConfig,
    defaultSubscriptionConfig,
    SubscriptionHandleM (..),
    SubscriptionHandle,

    -- * Consumer groups
    ConsumerGroup (..),
    InvalidConsumerGroup (..),
    ConsumerGroupGuardConflict (..),
) where

import Control.Exception (Exception, SomeException)
import Data.Int (Int32)
import Data.Text (Text)
import Kiroku.Store.Subscription.Fsm (SubscriptionState)
import Kiroku.Store.Types (CategoryName, RecordedEvent)
import Numeric.Natural (Natural)

-- | Unique name for a subscription (e.g., @"inventory-projection"@).
newtype SubscriptionName = SubscriptionName Text
    deriving newtype (Eq, Ord, Show)

-- | Which stream to subscribe to.
data SubscriptionTarget
    = -- | Subscribe to all events in global position order.
      AllStreams
    | -- | Subscribe to events from streams matching a category prefix.
      Category !CategoryName
    deriving stock (Eq, Show)

-- | What the handler returns to control the subscription lifecycle.
data SubscriptionResult
    = -- | Continue processing events.
      Continue
    | -- | Stop the subscription gracefully.
      Stop
    deriving stock (Eq, Show)

{- | What the publisher does when a subscriber's bounded queue is full.

The default 'PauseAndResume' is recoverable and lossless: the publisher
stops pushing to the full subscriber (and signals it), and the worker —
once its slow handler catches up — drains the stale queue and re-reads the
events it missed directly from the database from its checkpoint, so no
event is lost and the checkpoint still advances monotonically. The
fail-fast 'DropSubscription' (terminate with 'SubscriptionOverflowed') and
the lossy 'DropOldest' remain available for consumers that prefer a hard
error or best-effort delivery respectively.
-}
data OverflowPolicy
    = {- | Recoverable backpressure (the default). When the queue is full the
      publisher marks the subscriber 'Kiroku.Store.Subscription.EventPublisher.Paused'
      and stops pushing (it does not drop). The worker observes the pause,
      drains the stale queue, clears the flag, and re-catches-up from its
      checkpoint so every skipped event is delivered. No loss; monotonic
      checkpoint; other subscribers unaffected.
      -}
      PauseAndResume
    | {- | Mark the subscription as overflowed; the worker observes this on
      its next iteration and surfaces 'SubscriptionOverflowed' through
      'wait'. The slow subscriber is terminated; other subscribers are
      unaffected.
      -}
      DropSubscription
    | {- | Drop the oldest queued batch and enqueue the new one. The
      subscription continues but loses events. Choose only when at-least-once
      semantics are not required for this consumer.
      -}
      DropOldest
    deriving stock (Eq, Show)

{- | Raised on a 'SubscriptionHandleM' wait when the publisher dropped the
subscription because its bounded queue overflowed (overflow policy
'DropSubscription'). The 'subscriptionName' identifies the subscription
that overflowed; the consumer is expected to investigate the slow handler
and either fix the slowness or switch to 'DropOldest'.
-}
newtype SubscriptionOverflowed = SubscriptionOverflowed
    { subscriptionName :: SubscriptionName
    }
    deriving stock (Show)
    deriving anyclass (Exception)

-- | Handler callback invoked for each event, parameterized by monad.
type EventHandlerM m = RecordedEvent -> m SubscriptionResult

-- | Handler callback defaulting to 'IO'.
type EventHandler = EventHandlerM IO

-- | Configuration for starting a subscription, parameterized by monad.
data SubscriptionConfigM m = SubscriptionConfig
    { name :: !SubscriptionName
    , target :: !SubscriptionTarget
    , handler :: !(EventHandlerM m)
    , batchSize :: !Int32
    -- ^ Number of events to fetch per batch during catch-up (default: 100)
    , queueCapacity :: !Natural
    {- ^ Maximum number of /batches/ the publisher may enqueue for this
    subscriber before applying 'overflowPolicy'. Each batch is up to
    'EventPublisher.publisherBatchSize' events, so the effective event
    capacity is @queueCapacity * publisherBatchSize@. Default: 16
    batches (~16,000 events at the default publisher batch size).
    -}
    , overflowPolicy :: !OverflowPolicy
    {- ^ What the publisher does when this subscriber's queue is full.
    Default: 'PauseAndResume' — a slow subscriber is paused and then
    recovers losslessly (re-reading missed events from its checkpoint)
    rather than being terminated or silently growing the publisher's
    fan-out memory.
    -}
    , consumerGroup :: !(Maybe ConsumerGroup)
    {- ^ 'Nothing' (the default) = ordinary single-consumer subscription.
    'Just cg' = this worker is member 'member cg' of a group of size
    'size cg'. The invariant @size >= 1@ and @0 <= member < size@ is
    enforced once at 'Kiroku.Store.Subscription.subscribe' time, which
    throws 'InvalidConsumerGroup' on violation.
    -}
    , consumerGroupGuard :: !Bool
    {- ^ When 'True' (default 'False'), the worker performs a one-shot
    PostgreSQL advisory-lock conflict check at startup so two processes
    cannot both run the same @(name, member)@ at once. See the worker's
    @guardMember@ for the exact semantics and its documented limitation
    (a startup detection probe, not a lifetime-held lock). Ignored when
    'consumerGroup' is 'Nothing'.
    -}
    }

-- | Configuration defaulting to 'IO'.
type SubscriptionConfig = SubscriptionConfigM IO

{- | Build a 'SubscriptionConfig' with the recommended defaults.

The catch-up batch size defaults to 100 events per database fetch — large
enough to amortise round-trip overhead on typical projection workloads,
small enough that a single slow handler call does not stall the worker
for long. Override the 'batchSize' field on the returned record if a
different value suits the workload.

@
let cfg = defaultSubscriptionConfig "my-projection" AllStreams handler
withSubscription store cfg $ \\h -> wait h
@
-}
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
        , overflowPolicy = PauseAndResume
        , consumerGroup = Nothing
        , consumerGroupGuard = False
        }

-- | Handle returned to the caller for lifecycle management, parameterized by monad.
data SubscriptionHandleM m = SubscriptionHandle
    { cancel :: !(m ())
    -- ^ Cancel the subscription gracefully
    , wait :: !(m (Either SomeException ()))
    -- ^ Block until the subscription completes or fails
    , currentState :: !(m SubscriptionState)
    {- ^ Read the worker's current FSM state
    ('Kiroku.Store.Subscription.Fsm.SubscriptionState') as of this instant:
    @CatchingUp@, @Live@, @Paused@ (recoverable backpressure), @Reconnecting@,
    or @Stopped@. A point-in-time observability read backed by a @TVar@ the
    worker writes on every transition; for the stream of past transitions use
    the @KirokuEvent@ lifecycle events instead.
    -}
    }

-- | Handle defaulting to 'IO'.
type SubscriptionHandle = SubscriptionHandleM IO

-- | Static consumer-group membership for a subscription.
data ConsumerGroup = ConsumerGroup
    { member :: !Int32
    -- ^ 0-based member index; must satisfy @0 <= member < size@.
    , size :: !Int32
    -- ^ total members in the group; must be @>= 1@.
    }
    deriving stock (Eq, Show)

{- | Thrown by 'Kiroku.Store.Subscription.subscribe' when a 'ConsumerGroup'
violates @size >= 1@ or @0 <= member < size@. Carries the offending values for
diagnostics.
-}
data InvalidConsumerGroup = InvalidConsumerGroup
    { invalidMember :: !Int32
    , invalidSize :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)

{- | Thrown at subscription startup when 'consumerGroupGuard' is 'True' and
another holder currently holds the advisory lock for this @(name, member)@.
Indicates two processes are configured as the same group member. This is a
startup /detection/ probe, not a lifetime-held lock — see the worker's
@guardMember@.
-}
data ConsumerGroupGuardConflict = ConsumerGroupGuardConflict
    { conflictName :: !SubscriptionName
    , conflictMember :: !Int32
    }
    deriving stock (Show)
    deriving anyclass (Exception)
