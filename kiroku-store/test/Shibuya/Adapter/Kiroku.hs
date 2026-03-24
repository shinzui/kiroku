module Shibuya.Adapter.Kiroku (
    KirokuAdapterConfig (..),
    kirokuAdapter,
) where

import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO, (:>))
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Kiroku.Store.Subscription.Types (
    SubscriptionConfigM (..),
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
    let subConfig =
            SubscriptionConfig
                { name = subName
                , target = subTarget
                , handler = \_ -> pure Continue
                , batchSize = bs
                }

    (ioStream, cancelAction) <- liftIO $ subscriptionStream store subConfig buf

    let effStream = Stream.morphInner liftIO ioStream
        ingestedStream = fmap (mkIngested cancelAction) effStream

    pure
        Adapter
            { adapterName = "kiroku"
            , source = ingestedStream
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
