module Kiroku.Store.Subscription (
    -- * Subscribe
    subscribe,

    -- * Types
    module Kiroku.Store.Subscription.Types,
) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Generics.Labels ()
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Subscription.Worker (runWorker)

{- | Start a subscription. Returns a handle for cancellation and waiting.

The subscription spawns a worker thread that:
1. Reads the checkpoint from the database (or starts from position 0).
2. Catches up by querying the database directly until reaching the
   EventPublisher's current position.
3. Switches to live mode, reading events from the EventPublisher's
   broadcast channel.
-}
subscribe :: (MonadIO m) => KirokuStore -> SubscriptionConfig -> m SubscriptionHandle
subscribe store config = liftIO $ do
    liveChan <- atomically $ Pub.subscribePublisher (store ^. #publisher)
    let pubPosVar = Pub.lastPublished (store ^. #publisher)
    thread <-
        Async.async $
            runWorker (store ^. #pool) (store ^. #schema) liveChan pubPosVar config
    pure
        SubscriptionHandle
            { cancel = Async.cancel thread
            , wait = Async.waitCatch thread
            }
