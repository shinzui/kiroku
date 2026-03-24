module Kiroku.Store.Subscription.Stream (
    subscriptionStream,
)
where

import Control.Concurrent.STM (TBQueue, atomically, newTBQueueIO, readTBQueue, writeTBQueue)
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription (subscribe)
import Kiroku.Store.Subscription.Types (
    SubscriptionConfig,
    SubscriptionConfigM (..),
    SubscriptionHandleM (..),
    SubscriptionResult (..),
 )
import Kiroku.Store.Types (RecordedEvent)
import Numeric.Natural (Natural)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Create a pull-based 'Stream' from a kiroku subscription.

A bounded 'TBQueue' sits between kiroku's push-based handler and the
returned Streamly stream. The handler writes @Just event@ into the queue
and returns 'Continue'. A @Nothing@ sentinel signals end-of-stream.
The stream terminates when it reads @Nothing@.

The @handler@ field in the provided 'SubscriptionConfig' is ignored —
the bridge provides its own handler.

The returned cancel action cancels the underlying subscription and
writes the sentinel so any blocked reader wakes up and terminates.
-}
subscriptionStream ::
    KirokuStore ->
    SubscriptionConfig ->
    -- | TBQueue capacity (buffer size for backpressure)
    Natural ->
    IO (Stream IO RecordedEvent, IO ())
subscriptionStream store config bufferSize = do
    queue <- newTBQueueIO bufferSize

    let bridgeHandler :: RecordedEvent -> IO SubscriptionResult
        bridgeHandler event = do
            atomically $ writeTBQueue queue (Just event)
            pure Continue

    let bridgeConfig =
            config
                { handler = bridgeHandler
                }

    subHandle <- subscribe store bridgeConfig

    let cancelAction = do
            cancel subHandle
            atomically $ writeTBQueue queue Nothing

    let stream = Stream.unfoldrM (step queue) ()

    pure (stream, cancelAction)
  where
    step :: TBQueue (Maybe RecordedEvent) -> () -> IO (Maybe (RecordedEvent, ()))
    step queue () = do
        mEvent <- atomically $ readTBQueue queue
        case mEvent of
            Just event -> pure (Just (event, ()))
            Nothing -> pure Nothing
