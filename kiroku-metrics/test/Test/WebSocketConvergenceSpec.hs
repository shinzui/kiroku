{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.WebSocketConvergenceSpec (spec) where

import Control.Concurrent.Async (cancel, withAsync)
import Control.Concurrent.STM
import Control.Exception (MaskingState (..), SomeException, bracket, bracket_, getMaskingState, throwIO, try)
import Control.Lens ((&), (.~))
import Control.Monad (replicateM, replicateM_)
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.IntMap.Strict qualified as IntMap
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Data.Word (Word64)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

import Kiroku.Metrics (
    MetricsServer (..),
    MetricsServerConfig (..),
    defaultConfig,
    newKirokuMetricsWith,
    snapshotMetrics,
    startMetricsServerWithStore,
    stopMetricsServer,
 )
import Kiroku.Metrics.WebSocket
import Kiroku.Store hiding (cancel, id)
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Test.Postgres (withMigratedTestDatabase)

spec :: Spec
spec = do
    describe "Kiroku.Metrics.WebSocket (frames)" $ do
        it "preserves every existing server frame" $ do
            toJSON Pong `shouldBe` object ["type" .= ("pong" :: Text)]
            toJSON Goodbye `shouldBe` object ["type" .= ("goodbye" :: Text)]
            toJSON (EventStreamStarted 7) `shouldBe` object ["type" .= ("event_stream_started" :: Text), "from_position" .= (7 :: Int)]
            toJSON (ErrorMsg "x") `shouldBe` object ["type" .= ("error" :: Text), "message" .= ("x" :: Text)]
            toJSON (Event (object ["k" .= (1 :: Int)])) `shouldBe` object ["type" .= ("event" :: Text), "event" .= object ["k" .= (1 :: Int)]]
            km <- newKirokuMetricsWith (pure (GlobalPosition 0)) (pure 0)
            snap <- snapshotMetrics km
            look ["type"] (toJSON (Snapshot snap)) `shouldBe` Just (String "snapshot")
            look ["metrics"] (toJSON (Snapshot snap)) `shouldBe` Just (toJSON snap)
        it "pins coded errors and all four code spellings" $ do
            toJSON (CodedError "replay_failed" "boom") `shouldBe` object ["type" .= ("error" :: Text), "code" .= ("replay_failed" :: Text), "message" .= ("boom" :: Text)]
            [errorCodeReplayFailed, errorCodeCategoryReadFailed, errorCodeEventStreamOverflowed, errorCodeLiveDecodeFailed] `shouldBe` ["replay_failed", "category_read_failed", "event_stream_overflowed", "live_decode_failed"]
        it "accepts every old client frame and unsubscribe_metrics" $ do
            let parse raw = eitherDecode raw :: Either String ClientMessage
            map parse ["{\"type\":\"ping\"}", "{\"type\":\"subscribe_metrics\"}", "{\"type\":\"unsubscribe_events\"}", "{\"type\":\"unsubscribe_metrics\"}", "{\"type\":\"subscribe_events\"}", "{\"type\":\"subscribe_events\",\"from_position\":7,\"category\":\"orders\"}"] `shouldBe` map Right [Ping, SubscribeMetrics, UnsubscribeEvents, UnsubscribeMetrics, SubscribeEvents Nothing Nothing, SubscribeEvents (Just 7) (Just "orders")]
        it "adds exactly original_stream_name and preserves all old event fields" $ do
            let event = fixture 9
                original = objectFields (recordedEventToJSON event)
                resolved = objectFields (recordedEventToJSONResolved (Map.singleton (StreamId 9) (StreamName "orders-7")) event)
            KM.delete "original_stream_name" resolved `shouldBe` original
            length (KM.keys resolved) `shouldBe` 12
            KM.lookup "original_stream_name" resolved `shouldBe` Just (String "orders-7")
            look ["original_stream_name"] (recordedEventToJSONResolved Map.empty event) `shouldBe` Just Null
        it "detects only counter changes, including modular wraparound" $ do
            overflowNotice 0 0 `shouldBe` Nothing
            overflowNotice 3 3 `shouldBe` Nothing
            assertNotice 0 2 "2 undelivered"
            assertNotice 2 5 "3 undelivered"
            assertNotice maxBound 1 "2 undelivered"

    describe "Kiroku.Metrics.WebSocket (bounded delivery)" $ do
        it "resolves one cold batch, no warm or empty batches, and bounds FIFO retention" $ do
            cache <- newStreamNameCache
            calls <- newIORef ([] :: [[StreamId]])
            let lookupBatch ids = do
                    atomicModifyIORef' calls (\xs -> (xs <> [ids], ()))
                    pure (Map.fromList [(sid, streamName sid) | sid <- ids])
                events = V.fromList (map fixture [1 .. 5000])
            names <- resolveEventNames cache lookupBatch events
            Map.size names `shouldBe` 5000
            Map.lookup (StreamId 1) names `shouldBe` Just (StreamName "stream-1")
            Map.lookup (StreamId 5000) names `shouldBe` Just (StreamName "stream-5000")
            streamNameCacheSize cache `shouldReturn` (4096, 4096)
            _ <- resolveEventNames cache lookupBatch (V.fromList [fixture 5000, fixture 5000])
            _ <- resolveEventNames cache lookupBatch V.empty
            length <$> readIORef calls `shouldReturn` 1
            _ <- resolveEventNames cache lookupBatch (V.singleton (fixture 1))
            length <$> readIORef calls `shouldReturn` 2
            streamNameCacheSize cache `shouldReturn` (4096, 4096)
        it "does not retain misses and propagates cancellation from a name lookup" $ do
            cache <- newStreamNameCache
            resolveEventNames cache (const (pure Map.empty)) (V.singleton (fixture 1)) `shouldReturn` Map.empty
            streamNameCacheSize cache `shouldReturn` (0, 0)
            entered <- newEmptyTMVarIO
            withAsync (resolveEventNames cache (\_ -> atomically (putTMVar entered ()) >> atomically retry) (V.singleton (fixture 1))) $ \worker -> do
                bounded (atomically (takeTMVar entered))
                cancel worker
            streamNameCacheSize cache `shouldReturn` (0, 0)
        it "delivers unchanged and transformed batches without false overflow notices" $ do
            sub <- fakeSubscription
            cache <- newStreamNameCache
            frames <- newTVarIO []
            atomically $ do
                writeTBQueue sub.subscriptionQueue (UnchangedBatch (V.singleton (fixture 1)))
                writeTBQueue sub.subscriptionQueue (TransformedBatch (V.singleton (Decoded (fixture 2))))
            withAsync (broadcastEventsWith (capture frames) cache (pure . Map.fromList . map (\sid -> (sid, streamName sid))) sub (const True)) $ \_ -> do
                bounded (atomically (readTVar frames >>= \xs -> check (length xs == 2)))
            xs <- readTVarIO frames
            map framePosition xs `shouldBe` [Just 1, Just 2]
        it "never sends partial data and terminates on an applicable typed decode failure" $ do
            sub <- fakeSubscription
            cache <- newStreamNameCache
            frames <- newTVarIO []
            let failed = fixture 2
            atomically (writeTBQueue sub.subscriptionQueue (TransformedBatch (V.fromList [Decoded (fixture 1), Undecodable failed (DecodeFailure failed.eventId "secret payload")])))
            bounded (broadcastEventsWith (capture frames) cache (\_ -> fail "must not look up partial batch") sub (const True))
            readTVarIO frames `shouldReturn` [CodedError errorCodeLiveDecodeFailed "live event decoding failed"]
        it "filters typed failures below the covered replay boundary" $ do
            sub <- fakeSubscription
            cache <- newStreamNameCache
            frames <- newTVarIO []
            let old = fixture 1
            atomically (writeTBQueue sub.subscriptionQueue (TransformedBatch (V.fromList [Undecodable old (DecodeFailure old.eventId "old failure"), Decoded (fixture 2)])))
            withAsync (broadcastEventsWith (capture frames) cache (const (pure Map.empty)) sub (\e -> e.globalPosition > GlobalPosition 1)) $ \_ ->
                bounded (atomically (readTVar frames >>= \xs -> check (length xs == 1)))
            map framePosition <$> readTVarIO frames `shouldReturn` [Just 2]
        it "signals real publisher loss before survivors and recovers from the pre-notice cursor" $ withBareStore $ \store ->
            bracket (atomically (Pub.subscribePublisherWith store.publisher 1 DropOldest)) Pub.unsubscribe $ \sub -> do
                cache <- newStreamNameCache
                frames <- newTVarIO []
                entered <- newEmptyTMVarIO
                release <- newEmptyTMVarIO
                let writer msg = do
                        case msg of
                            Event ev | look ["globalPosition"] ev == Just (toJSON (1 :: Int)) -> atomically (putTMVar entered ()) >> atomically (takeTMVar release)
                            _ -> pure ()
                        capture frames msg
                    lookupBatch ids = either (error . show) id <$> runStoreIO store (lookupStreamNames ids)
                withAsync (broadcastEventsWith writer cache lookupBatch sub (const True)) $ \_ -> do
                    appendEvents store "loss-1" 1
                    bounded (atomically (takeTMVar entered))
                    appendEvents store "loss-2" 1
                    waitPosition store 2
                    appendEvents store "loss-3" 1
                    waitPosition store 3
                    readTVarIO sub.subscriptionDropped `shouldReturn` 1
                    atomically (putTMVar release ())
                    bounded (atomically (readTVar frames >>= \xs -> check (length xs == 3)))
                xs <- readTVarIO frames
                map framePosition xs `shouldBe` [Just 1, Nothing, Just 3]
                case xs of
                    [_, CodedError code _, _] -> code `shouldBe` errorCodeEventStreamOverflowed
                    _ -> expectationFailure (show xs)
                Right recovered <- runStoreIO store (readAllForward (GlobalPosition 1) 10)
                map (.globalPosition) (V.toList recovered) `shouldBe` [GlobalPosition 2, GlobalPosition 3]
                sort (nub ([p | Just p <- map framePosition xs] <> map (\e -> let GlobalPosition p = e.globalPosition in p) (V.toList recovered))) `shouldBe` [1, 2, 3]
        it "coalesces defensive status overflow and a drop notice in the same delivery" $ do
            sub <- fakeSubscription
            cache <- newStreamNameCache
            frames <- newTVarIO []
            atomically $ do
                writeTVar sub.subscriptionStatus Pub.Overflowed
                writeTVar sub.subscriptionDropped 1
                writeTBQueue sub.subscriptionQueue (UnchangedBatch (V.singleton (fixture 1)))
                writeTBQueue sub.subscriptionQueue (UnchangedBatch (V.singleton (fixture 2)))
            withAsync (broadcastEventsWith (capture frames) cache (const (pure Map.empty)) sub (const True)) $ \_ ->
                bounded (atomically (readTVar frames >>= \xs -> check (length xs == 3)))
            map framePosition <$> readTVarIO frames `shouldReturn` [Nothing, Just 1, Just 2]

    describe "Kiroku.Metrics.WebSocket (worker lifecycle)" $ do
        it "keeps one unmasked worker through repeated start/stop and joins on exit" $ do
            active <- newTVarIO (0 :: Int)
            masking <- newTVarIO Nothing
            let worker = bracket_ (atomically (modifyTVar' active (+ 1))) (atomically (modifyTVar' active (subtract 1))) $ do
                    state <- getMaskingState
                    atomically (writeTVar masking (Just state))
                    atomically retry
            withWorkerSlot $ \start stop -> do
                replicateM_ 5 $ do
                    replicateM_ 3 (start worker)
                    bounded (atomically (readTVar active >>= check . (== 1)))
                    bounded (atomically (readTVar masking >>= check . (== Just Unmasked)))
                    stop >> stop
                    readTVarIO active `shouldReturn` 0
                start worker
                bounded (atomically (readTVar active >>= check . (== 1)))
            readTVarIO active `shouldReturn` 0
        it "joins a worker when the connection is cancelled during worker startup" $ do
            active <- newTVarIO (0 :: Int)
            let worker = bracket_ (atomically (modifyTVar' active (+ 1))) (atomically (modifyTVar' active (subtract 1))) (atomically retry)
            withAsync (withWorkerSlot $ \start _ -> start worker >> atomically retry) $ \owner -> do
                bounded (atomically (readTVar active >>= check . (== 1)))
                cancel owner
            readTVarIO active `shouldReturn` 0
        it "propagates unexpected worker failure to the owner" $ do
            result <- try (bounded (withWorkerSlot $ \start _ -> start (throwIO (userError "worker failed")) >> atomically retry)) :: IO (Either SomeException ())
            result `shouldSatisfy` either (T.isInfixOf "worker failed" . T.pack . show) (const False)

    describe "Kiroku.Metrics.WebSocket (convergence, real server)" $ do
        it "stops metrics pushes, resumes them and preserves ping" $ withServer id $ \_ srv -> client srv "/ws/metrics" $ \conn -> do
            _ <- waitForType conn "snapshot"
            _ <- waitForType conn "snapshot"
            replicateM_ 3 (command conn "unsubscribe_metrics")
            -- Ping is an ordering barrier: the receive loop has completed cancellation.
            command conn "ping"
            _ <- waitForType conn "pong"
            timeout 700_000 (WS.receiveData conn :: IO LBS.ByteString) `shouldReturn` Nothing
            replicateM_ 3 (command conn "subscribe_metrics")
            replicateM_ 4 (waitForType conn "snapshot")
            command conn "ping"
            _ <- waitForType conn "pong"
            pure ()
        it "labels live events on both new and warm streams" $ withServer id $ \store srv -> do
            names <- client srv "/ws/events" $ \conn -> do
                command conn "subscribe_events"
                _ <- waitForType conn "event_stream_started"
                appendEvents store "conv-live-1" 2
                appendEvents store "conv-live-2" 1
                replicateM 3 (readEventField conn "original_stream_name")
            names `shouldBe` map (Just . String) ["conv-live-1", "conv-live-1", "conv-live-2"]
            waitSubscriberCount store 0
        it "labels replay and category events" $ withServer id $ \store srv -> do
            appendEvents store "convcat-1" 2
            waitPosition store 2
            replayed <- client srv "/ws/events" $ \conn -> do
                sendJSON conn (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int)])
                _ <- waitForType conn "event_stream_started"
                replicateM 2 (readEventField conn "original_stream_name")
            replayed `shouldBe` replicate 2 (Just (String "convcat-1"))
            names <- client srv "/ws/events" $ \conn -> do
                sendJSON conn (object ["type" .= ("subscribe_events" :: Text), "category" .= ("convcat" :: Text)])
                _ <- waitForType conn "event_stream_started"
                appendEvents store "convcat-2" 1
                readEventField conn "original_stream_name"
            names `shouldBe` Just (String "convcat-2")
            waitSubscriberCount store 0
        it "codes and sanitizes a replay failure and ends its tail" $ withServer id $ \store srv -> do
            appendEvents store "conv-fail-1" 1
            waitPosition store 1
            Pool.use store.pool (Session.script "ALTER TABLE events RENAME TO events_hidden") `shouldReturn` Right ()
            client srv "/ws/events" $ \conn -> do
                sendJSON conn (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int)])
                err <- waitForType conn "error"
                look ["code"] err `shouldBe` Just (String "replay_failed")
                look ["message"] err `shouldBe` Just (String "replay error: history unavailable")
                timeout 300_000 (WS.receiveData conn :: IO LBS.ByteString) `shouldReturn` Nothing
            waitSubscriberCount store 0
        it "codes a category failure without appending to the renamed table" $ withServer id $ \store srv -> do
            appendEvents store "convcat-1" 1
            waitPosition store 1
            Pool.use store.pool (Session.script "ALTER TABLE events RENAME TO events_hidden") `shouldReturn` Right ()
            client srv "/ws/events" $ \conn -> do
                sendJSON conn (object ["type" .= ("subscribe_events" :: Text), "from_position" .= (0 :: Int), "category" .= ("convcat" :: Text)])
                err <- waitForType conn "error"
                look ["code"] err `shouldBe` Just (String "category_read_failed")
                look ["message"] err `shouldBe` Just (String "category read error: events unavailable")
                timeout 300_000 (WS.receiveData conn :: IO LBS.ByteString) `shouldReturn` Nothing
            waitSubscriberCount store 0
        it "codes typed live decode failures without leaking hook details" $ withServer (\settings -> settings & #storeSettings . #decodeHook .~ Just (\e -> pure (Left (DecodeFailure e.eventId "secret")))) $ \store srv -> do
            client srv "/ws/events" $ \conn -> do
                command conn "subscribe_events"
                _ <- waitForType conn "event_stream_started"
                appendEvents store "conv-decode" 1
                err <- waitForType conn "error"
                look ["code"] err `shouldBe` Just (String "live_decode_failed")
                look ["message"] err `shouldBe` Just (String "live event decoding failed")
            waitSubscriberCount store 0

fixture :: Int64 -> RecordedEvent
fixture n = RecordedEvent (EventId UUID.nil) (EventType "E") (StreamVersion 1) (GlobalPosition n) (StreamId n) (StreamVersion 1) (object []) Nothing Nothing Nothing (UTCTime (fromGregorian 2026 10 10) 0)

streamName :: StreamId -> StreamName
streamName (StreamId n) = StreamName ("stream-" <> T.pack (show n))

assertNotice :: Word64 -> Word64 -> Text -> Expectation
assertNotice previous current text = case overflowNotice previous current of
    Just (CodedError code msg) -> do
        code `shouldBe` errorCodeEventStreamOverflowed
        msg `shouldSatisfy` T.isInfixOf text
    other -> expectationFailure (show other)

fakeSubscription :: IO Pub.PublisherSubscription
fakeSubscription = Pub.PublisherSubscription <$> newTBQueueIO 16 <*> newTVarIO Pub.Active <*> newTVarIO 0 <*> pure (pure ())

capture :: TVar [ServerMessage] -> ServerMessage -> IO ()
capture frames msg = atomically (modifyTVar' frames (<> [msg]))

framePosition :: ServerMessage -> Maybe Int64
framePosition (Event ev) = case look ["globalPosition"] ev of
    Just (Number n) -> Just (round n)
    _ -> Nothing
framePosition _ = Nothing

bounded :: IO a -> IO a
bounded action = timeout 15_000_000 action >>= maybe (fail "convergence timeout") pure

withBareStore :: (KirokuStore -> IO a) -> IO a
withBareStore action = withMigratedTestDatabase $ \conn -> withStore (defaultConnectionSettings conn) action

withServer :: (ConnectionSettings -> ConnectionSettings) -> (KirokuStore -> MetricsServer -> IO a) -> IO a
withServer tweak action = withMigratedTestDatabase $ \conn -> do
    var <- newTVarIO Nothing
    km <-
        newKirokuMetricsWith
            (readTVar var >>= maybe (pure (GlobalPosition 0)) (Pub.publisherPosition . (.publisher)))
            (readTVar var >>= maybe (pure 0) (fmap IntMap.size . readTVar . Pub.subscribers . (.publisher)))
    withStore (tweak (defaultConnectionSettings conn)) $ \store -> do
        atomically (writeTVar var (Just store))
        bracket (startMetricsServerWithStore (defaultConfig{port = 0, wsPushIntervalUs = 200_000}) km store []) stopMetricsServer (action store)

client :: MetricsServer -> String -> (WS.Connection -> IO a) -> IO a
client srv path = bounded . WS.runClient "127.0.0.1" srv.serverPort path

sendJSON :: WS.Connection -> Value -> IO ()
sendJSON conn = WS.sendTextData conn . encode

command :: WS.Connection -> Text -> IO ()
command conn name = sendJSON conn (object ["type" .= name])

waitForType :: WS.Connection -> Text -> IO Value
waitForType conn name = do
    raw <- WS.receiveData conn :: IO LBS.ByteString
    value <- either fail pure (eitherDecode raw)
    if look ["type"] value == Just (String name) then pure value else waitForType conn name

readEventField :: WS.Connection -> Text -> IO (Maybe Value)
readEventField conn key = look ["event", key] <$> waitForType conn "event"

look :: [Text] -> Value -> Maybe Value
look [] value = Just value
look (key : keys) (Object fields) = KM.lookup (Key.fromText key) fields >>= look keys
look _ _ = Nothing

appendEvents :: KirokuStore -> Text -> Int -> IO ()
appendEvents store name count = do
    result <- runStoreIO store (appendToStream (StreamName name) NoStream [EventData Nothing (EventType ("E" <> T.pack (show n))) (object []) Nothing Nothing Nothing | n <- [1 .. count]])
    either (fail . show) (const (pure ())) result

waitPosition :: KirokuStore -> Int64 -> IO ()
waitPosition store target = bounded (atomically (Pub.publisherPosition store.publisher >>= check . (>= GlobalPosition target)))

waitSubscriberCount :: KirokuStore -> Int -> IO ()
waitSubscriberCount store count = bounded (atomically (readTVar (Pub.subscribers store.publisher) >>= check . (== count) . IntMap.size))

objectFields :: Value -> KM.KeyMap Value
objectFields (Object fields) = fields
objectFields other = error ("expected object: " <> show other)
