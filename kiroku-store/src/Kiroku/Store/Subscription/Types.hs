module Kiroku.Store.Subscription.Types (
    SubscriptionName (..),
    SubscriptionTarget (..),
    SubscriptionResult (..),
    EventHandlerM,
    EventHandler,
    SubscriptionConfigM (..),
    SubscriptionConfig,
    defaultSubscriptionConfig,
    SubscriptionHandleM (..),
    SubscriptionHandle,
) where

import Control.Exception (SomeException)
import Data.Int (Int32)
import Data.Text (Text)
import Kiroku.Store.Types (CategoryName, RecordedEvent)

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
