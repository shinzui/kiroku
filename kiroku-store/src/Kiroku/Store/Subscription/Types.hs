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
) where

import Control.Exception (Exception, SomeException)
import Data.Int (Int32)
import Data.Text (Text)
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

The default 'DropSubscription' chooses production safety over best-effort
delivery: the slow subscriber is shut down and the consumer learns
explicitly via a 'SubscriptionOverflowed' exception on
'Kiroku.Store.Subscription.Types.SubscriptionHandleM' wait. The
alternative ('DropOldest') quietly trades correctness for liveness and
should only be chosen for telemetry-style subscriptions where missing
events is acceptable.
-}
data OverflowPolicy
    = {- | Mark the subscription as overflowed; the worker observes this on
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
    Default: 'DropSubscription' — slow subscribers are terminated with a
    structured error rather than silently growing the publisher's
    fan-out memory or losing events.
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
        , overflowPolicy = DropSubscription
        }

-- | Handle returned to the caller for lifecycle management, parameterized by monad.
data SubscriptionHandleM m = SubscriptionHandle
    { cancel :: !(m ())
    -- ^ Cancel the subscription gracefully
    , wait :: !(m (Either SomeException ()))
    -- ^ Block until the subscription completes or fails
    }

-- | Handle defaulting to 'IO'.
type SubscriptionHandle = SubscriptionHandleM IO
