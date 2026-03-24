module Shibuya.Adapter.Kiroku (
    KirokuAdapterConfig (..),
    kirokuAdapter,
) where

import Control.Concurrent.STM (TBQueue, atomically, newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO, (:>))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription (subscribe)
import Kiroku.Store.Subscription.Types (
    SubscriptionConfigM (..),
    SubscriptionHandleM (..),
    SubscriptionName,
    SubscriptionResult (..),
    SubscriptionTarget,
 )
import Kiroku.Store.Types (
    EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
 )
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

data KirokuAdapterConfig = KirokuAdapterConfig
    { subscriptionName :: !SubscriptionName
    , subscriptionTarget :: !SubscriptionTarget
    , batchSize :: !Int32
    , bufferSize :: !Natural
    }

kirokuAdapter ::
    (IOE :> es) =>
    KirokuStore ->
    KirokuAdapterConfig ->
    Eff es (Adapter es RecordedEvent)
kirokuAdapter store (KirokuAdapterConfig subName subTarget bs buf) = do
    queue <- liftIO $ newTBQueueIO buf

    let bridgeHandler :: RecordedEvent -> IO SubscriptionResult
        bridgeHandler event = do
            atomically $ writeTBQueue queue (Just event)
            pure Continue

    let subConfig =
            SubscriptionConfig
                { name = subName
                , target = subTarget
                , handler = bridgeHandler
                , batchSize = bs
                }

    subHandle <- liftIO $ subscribe store subConfig

    let cancelAction :: IO ()
        cancelAction = do
            cancel subHandle
            atomically $ writeTBQueue queue Nothing

    let step () = do
            mEvent <- liftIO $ atomically $ readTBQueue queue
            case mEvent of
                Just event -> pure (Just (mkIngested cancelAction event, ()))
                Nothing -> pure Nothing

    let effStream = Stream.unfoldrM step ()

    pure
        Adapter
            { adapterName = "kiroku"
            , source = effStream
            , shutdown = liftIO cancelAction
            }

mkIngested :: (IOE :> es) => IO () -> RecordedEvent -> Ingested es RecordedEvent
mkIngested cancelAction event =
    Ingested
        { envelope = mkEnvelope event
        , ack =
            AckHandle
                { finalize = \case
                    AckHalt _ -> liftIO cancelAction
                    _ -> pure ()
                }
        , lease = Nothing
        }

mkEnvelope :: RecordedEvent -> Envelope RecordedEvent
mkEnvelope event =
    let EventId uuid = event ^. #eventId
        GlobalPosition pos = event ^. #globalPosition
     in Envelope
            { messageId = MessageId (T.pack (UUID.toString uuid))
            , cursor = Just (CursorInt (fromIntegral pos))
            , partition = Nothing
            , enqueuedAt = Just (event ^. #createdAt)
            , traceContext = Nothing
            , payload = event
            }
