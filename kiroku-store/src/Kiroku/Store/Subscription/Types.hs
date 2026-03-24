module Kiroku.Store.Subscription.Types (
    SubscriptionName (..),
    SubscriptionTarget (..),
    SubscriptionResult (..),
    EventHandler,
    SubscriptionConfig (..),
    SubscriptionHandle (..),
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

-- | Handler callback invoked for each event.
type EventHandler = RecordedEvent -> IO SubscriptionResult

-- | Configuration for starting a subscription.
data SubscriptionConfig = SubscriptionConfig
    { name :: !SubscriptionName
    , target :: !SubscriptionTarget
    , handler :: !EventHandler
    , batchSize :: !Int32
    -- ^ Number of events to fetch per batch during catch-up (default: 100)
    }

-- | Handle returned to the caller for lifecycle management.
data SubscriptionHandle = SubscriptionHandle
    { cancel :: !(IO ())
    -- ^ Cancel the subscription gracefully
    , wait :: !(IO (Either SomeException ()))
    -- ^ Block until the subscription completes or fails
    }
