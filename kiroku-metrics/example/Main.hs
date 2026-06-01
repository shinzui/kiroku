{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | A self-verifying runnable demo of @kiroku-metrics@ (EP-4).

Boots an ephemeral, migrated PostgreSQL, opens a store with the metrics collector
wired into its callbacks /before/ @withStore@, starts the combined HTTP+WebSocket
server, appends a few events, then checks its own endpoints over real HTTP and a
real WebSocket. Prints a step transcript and exits non-zero if any check fails, so
running it is a test that the documented behavior holds:

@
cabal run kiroku-metrics-example
@
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (.~))
import Control.Monad (unless)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IntMap.Strict qualified as IntMap
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (
    Manager,
    defaultManagerSettings,
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
 )
import Network.HTTP.Types (statusCode)
import Network.WebSockets qualified as WS
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

import Kiroku.Metrics (
    MetricsServer (..),
    MetricsSnapshot (..),
    StoreGauges (..),
    defaultConfig,
    metricsEventHandler,
    metricsObservationHandler,
    newKirokuMetricsWith,
    postgresPing,
    snapshotMetrics,
    withMetricsServerWithStore,
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

main :: IO ()
main = withMigratedTestDatabase $ \connStr -> do
    step "[1/6] ephemeral postgres ready"

    -- The collector must observe events from the first append, so its callbacks
    -- go on ConnectionSettings BEFORE withStore. But snapshots read store-level
    -- gauges from the live handle — so the collector is built from STM readers
    -- over a TVar that holds the store once it is open (the deferral pattern).
    storeVar <- newTVarIO Nothing
    metrics <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
    let settings =
            defaultConnectionSettings connStr
                & #eventHandler .~ Just (metricsEventHandler metrics Nothing)
                & #observationHandler .~ Just (metricsObservationHandler metrics Nothing)

    withStore settings $ \store -> do
        atomically (writeTVar storeVar (Just store))
        withMetricsServerWithStore (defaultConfig{port = 0}) metrics store [postgresPing store] $ \srv -> do
            threadDelay 300_000
            let port = srv.serverPort
                base = "http://127.0.0.1:" <> show port
            step ("[2/6] store + collector + metrics server on port " <> show port)

            appendEvents store (StreamName "orders-1") ["OrderCreated", "OrderPaid", "OrderShipped"]
            step "[3/6] appended 3 events to orders-1"

            mgr <- newManager defaultManagerSettings

            (sMetrics, bMetrics) <- httpGet mgr (base <> "/metrics")
            check "GET /metrics is 200" (sMetrics == 200)
            let gpos = globalPositionOf bMetrics
            check ("GET /metrics store.global_position >= 3 (got " <> show gpos <> ")") (gpos >= 3)

            (sProm, bProm) <- httpGet mgr (base <> "/metrics/prometheus")
            check "GET /metrics/prometheus is 200" (sProm == 200)
            check
                "Prometheus body contains kiroku_events_appended_total"
                (T.isInfixOf "kiroku_events_appended_total" (bodyText bProm))

            (sLive, _) <- httpGet mgr (base <> "/health/live")
            check "GET /health/live is 200" (sLive == 200)
            (sReady, _) <- httpGet mgr (base <> "/health/ready")
            check "GET /health/ready is 200" (sReady == 200)
            step "[4/6] HTTP /metrics, /prometheus, /health/live, /health/ready all OK"

            -- WebSocket: subscribe to the live event tail, then append one more
            -- event and assert it arrives over the socket as a JSON event message.
            evType <-
                requireJust "WebSocket /ws/events round-trip timed out" $
                    timeout 15_000_000 $
                        WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
                            WS.sendTextData conn (encode (object ["type" .= ("subscribe_events" :: Text)]))
                            _ <- waitForType conn "event_stream_started"
                            appendThread <- async (appendEvents store (StreamName "orders-2") ["OrderRefunded"])
                            ev <- waitForType conn "event"
                            wait appendThread
                            pure (eventTypeOf ev)
            check ("WebSocket event eventType == OrderRefunded (got " <> T.unpack evType <> ")") (evType == "OrderRefunded")
            step ("[5/6] WebSocket /ws/events received event eventType=" <> T.unpack evType)

            snap <- snapshotMetrics metrics
            step ("[6/6] kiroku-metrics-example: all checks passed (snapshot global position = " <> show snap.store.globalPosition <> ")")

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | Print a transcript step.
step :: String -> IO ()
step = putStrLn

-- | Assert a condition; on failure print to stderr and exit non-zero.
check :: String -> Bool -> IO ()
check label ok =
    unless ok $ do
        hPutStrLn stderr ("kiroku-metrics-example: FAILED: " <> label)
        exitFailure

-- | Require a timed action to have produced a result; else fail the example.
requireJust :: String -> IO (Maybe a) -> IO a
requireJust label act =
    act >>= \case
        Just a -> pure a
        Nothing -> do
            hPutStrLn stderr ("kiroku-metrics-example: FAILED: " <> label)
            exitFailure

-- | GET a URL, returning the status code and the body (no throwing on non-2xx).
httpGet :: Manager -> String -> IO (Int, ByteString)
httpGet mgr url = do
    req <- parseRequest url
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), responseBody resp)

-- | Read server messages until one with the given @"type"@ arrives; return it.
waitForType :: WS.Connection -> Text -> IO Value
waitForType conn want = go
  where
    go = do
        raw <- WS.receiveData conn :: IO ByteString
        case decode raw of
            Just v | lookKey ["type"] v == Just (String want) -> pure v
            _ -> go

-- | Extract @event.eventType@ from an @event@ message ("" if absent).
eventTypeOf :: Value -> Text
eventTypeOf v = case lookKey ["event", "eventType"] v of
    Just (String t) -> t
    _ -> ""

-- | Extract @store.global_position@ from a @/metrics@ JSON body.
globalPositionOf :: ByteString -> Int
globalPositionOf body = case decode body of
    Just v | Just (Number n) <- lookKey ["store", "global_position"] v -> truncate (toRealFloat n :: Double)
    _ -> -1

-- | Navigate nested object keys.
lookKey :: [Text] -> Value -> Maybe Value
lookKey [] v = Just v
lookKey (k : ks) (Object o) = KM.lookup (Key.fromText k) o >>= lookKey ks
lookKey _ _ = Nothing

bodyText :: ByteString -> Text
bodyText = TE.decodeUtf8 . LBS.toStrict

appendEvents :: KirokuStore -> StreamName -> [Text] -> IO ()
appendEvents store stream types = do
    let events =
            [ EventData
                { eventId = Nothing
                , eventType = EventType t
                , payload = Null
                , metadata = Nothing
                , causationId = Nothing
                , correlationId = Nothing
                }
            | t <- types
            ]
    result <- runStoreIO store (appendToStream stream NoStream events)
    case result of
        Right _ -> pure ()
        Left err -> do
            hPutStrLn stderr ("kiroku-metrics-example: append failed: " <> show err)
            exitFailure

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
    readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
    readTVar storeVar >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))
