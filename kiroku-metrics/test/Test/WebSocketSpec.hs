{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | End-to-end test of the WebSocket endpoints (EP-3): boot a real store with the
collector wired in, start the store-aware server on an OS-assigned port, then
drive both channels over a real socket with the @websockets@ client.

  * @/ws/events@: subscribe, append three events from the test thread, assert
    three @event@ messages arrive in global-position order with the expected
    @eventType@s. After the client disconnects, the publisher's transient
    broadcast subscriber must be cleaned up (count returns to baseline) — proof
    the tail's @finally@ wiring deregisters and that it leaves no trace.
  * @/ws/metrics@: connect, receive a @snapshot@, assert @store.global_position@
    reflects the appended events.
-}
module Test.WebSocketSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM (
    STM,
    TVar,
    atomically,
    check,
    newTVarIO,
    orElse,
    readTVar,
    registerDelay,
    writeTVar,
 )
import Control.Lens ((&), (.~))
import Control.Monad (replicateM, unless)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.IntMap.Strict qualified as IntMap
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

import Kiroku.Metrics (
    MetricsServer (..),
    defaultConfig,
    metricsEventHandler,
    metricsObservationHandler,
    newKirokuMetricsWith,
    startMetricsServerWithStore,
    stopMetricsServer,
 )
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Store (
    EventData (..),
    EventType (..),
    ExpectedVersion (..),
    KirokuStore (..),
    StreamName (..),
    appendToStream,
    defaultConnectionSettings,
    runStoreIO,
    withStore,
 )
import Kiroku.Store.Subscription.EventPublisher (EventPublisher (..), publisherPosition)
import Kiroku.Store.Types (GlobalPosition (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)

spec :: Spec
spec = describe "Kiroku.Metrics.WebSocket (endpoints)" $ do
    it "streams appended events over /ws/events and a snapshot over /ws/metrics" $
        withMigratedTestDatabase $ \connStr -> do
            storeVar <- newTVarIO Nothing
            km <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
            let settings =
                    defaultConnectionSettings connStr
                        & #eventHandler .~ Just (metricsEventHandler km Nothing)
                        & #observationHandler .~ Just (metricsObservationHandler km Nothing)
            withStore settings $ \store -> do
                atomically (writeTVar storeVar (Just store))
                let serverCfg = defaultConfig{port = 0}
                srv <- startMetricsServerWithStore serverCfg km store []
                threadDelay 300_000
                let port = srv.serverPort
                    stream = StreamName "ws-events-stream"

                -- /ws/events: subscribe, then append three events and read them back.
                received <-
                    requireJust "ws/events client timed out" $
                        timeout 15_000_000 $
                            WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
                                sendJSON conn (object ["type" .= ("subscribe_events" :: Text)])
                                _ <- waitForType conn "event_stream_started"
                                appendThread <- async (appendStoreEvents store stream 3)
                                evs <- replicateM 3 (readEventType conn)
                                wait appendThread
                                pure evs
                received `shouldBe` ["E1", "E2", "E3"]

                -- The tail uses the public broadcast and unsubscribes on disconnect;
                -- the publisher's subscriber count must return to baseline (0).
                waitForSubscriberCount store 0 5_000_000

                -- /ws/metrics: the snapshot reflects the three appended events.
                gpos <-
                    requireJust "ws/metrics client timed out" $
                        timeout 15_000_000 $
                            WS.runClient "127.0.0.1" port "/ws/metrics" $ \conn -> do
                                snap <- waitForType conn "snapshot"
                                pure (globalPositionOf snap)
                gpos `shouldSatisfy` (>= 3)

                stopMetricsServer srv

    it "replays history from a position then continues live without duplicating the boundary" $
        withMigratedTestDatabase $ \connStr -> do
            storeVar <- newTVarIO Nothing
            km <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
            let settings =
                    defaultConnectionSettings connStr
                        & #eventHandler .~ Just (metricsEventHandler km Nothing)
                        & #observationHandler .~ Just (metricsObservationHandler km Nothing)
            withStore settings $ \store -> do
                atomically (writeTVar storeVar (Just store))
                let serverCfg = defaultConfig{port = 0}
                srv <- startMetricsServerWithStore serverCfg km store []
                threadDelay 300_000
                let port = srv.serverPort

                -- Two events exist before the client connects (stream A); they must
                -- be replayed. The live event lands on a second stream (B) so the
                -- @NoStream@ append helper does not conflict.
                appendStoreEvents store (StreamName "ws-replay-a") 2
                received <-
                    requireJust "ws/events replay client timed out" $
                        timeout 15_000_000 $
                            WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
                                sendJSON
                                    conn
                                    (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int)])
                                _ <- waitForType conn "event_stream_started"
                                -- Two replayed (A's E1,E2), then one appended live
                                -- (B's E1) — three in global-position order, with no
                                -- duplicate at the replay/live boundary.
                                replayed <- replicateM 2 (readEventType conn)
                                liveThread <- async (appendStoreEvents store (StreamName "ws-replay-b") 1)
                                live <- readEventType conn
                                wait liveThread
                                pure (replayed <> [live])
                received `shouldBe` ["E1", "E2", "E1"]

                stopMetricsServer srv

-- | Fail the example with a message if the timed action returned 'Nothing'.
requireJust :: String -> IO (Maybe a) -> IO a
requireJust msg act = act >>= maybe (expectationFailure msg >> error msg) pure

sendJSON :: WS.Connection -> Value -> IO ()
sendJSON conn = WS.sendTextData conn . encode

recvValue :: WS.Connection -> IO Value
recvValue conn = do
    raw <- WS.receiveData conn :: IO LBS.ByteString
    case decode raw of
        Just v -> pure v
        Nothing -> expectationFailure ("undecodable frame: " <> show raw) >> error "undecodable"

-- | Read server messages until one with the given @"type"@ arrives; return it.
waitForType :: WS.Connection -> Text -> IO Value
waitForType conn want = go
  where
    go = do
        v <- recvValue conn
        if look ["type"] v == Just (String want) then pure v else go

-- | Read until an @event@ message, returning its @event.eventType@.
readEventType :: WS.Connection -> IO Text
readEventType conn = do
    v <- waitForType conn "event"
    case look ["event", "eventType"] v of
        Just (String t) -> pure t
        other -> expectationFailure ("event without eventType: " <> show other) >> error "no eventType"

-- | Navigate nested object keys.
look :: [Text] -> Value -> Maybe Value
look [] v = Just v
look (k : ks) (Object o) = KM.lookup (Key.fromText k) o >>= look ks
look _ _ = Nothing

-- | Extract @metrics.store.global_position@ from a @snapshot@ message.
globalPositionOf :: Value -> Int
globalPositionOf v =
    case look ["metrics", "store", "global_position"] v of
        Just (Number n) -> truncate (toRealFloat n :: Double)
        _ -> -1

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
    readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
    readTVar storeVar
        >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))

-- | Block until the publisher's subscriber count reaches @target@ or time out.
waitForSubscriberCount :: KirokuStore -> Int -> Int -> IO ()
waitForSubscriberCount store target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    ok <-
        atomically $
            ( do
                c <- IntMap.size <$> readTVar (subscribers store.publisher)
                check (c == target)
                pure True
            )
                `orElse` (readTVar timeoutVar >>= \t -> check t >> pure False)
    unless ok $ do
        actual <- atomically (IntMap.size <$> readTVar (subscribers store.publisher))
        expectationFailure
            ("subscriber count did not reach " <> show target <> "; still " <> show actual)

appendStoreEvents :: KirokuStore -> StreamName -> Int -> IO ()
appendStoreEvents store stream n = do
    let events =
            [ EventData
                { eventId = Nothing
                , eventType = EventType ("E" <> T.pack (show i))
                , payload = Null
                , metadata = Nothing
                , causationId = Nothing
                , correlationId = Nothing
                }
            | i <- [1 .. n]
            ]
    result <- runStoreIO store (appendToStream stream NoStream events)
    case result of
        Right _ -> pure ()
        Left err -> expectationFailure ("appendStoreEvents failed: " <> show err)
