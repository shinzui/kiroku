{-# LANGUAGE OverloadedLabels #-}

{- | End-to-end test of the HTTP endpoints: boot a real store with the collector
wired in, run a live subscription, start the server on an OS-assigned port, and
hit every endpoint with an HTTP client asserting status codes and bodies.
-}
module Test.ServerSpec (spec) where

import Control.Concurrent (threadDelay)
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
import Control.Monad (unless)
import Data.Aeson (Value (..), decode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IntMap.Strict qualified as IntMap
import Data.Scientific (toRealFloat)
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
import Test.Hspec

import Kiroku.Metrics (
    DependencyStatus (..),
    MetricsServer (..),
    defaultConfig,
    metricsEventHandler,
    metricsObservationHandler,
    newKirokuMetricsWith,
    startMetricsServer,
    stopMetricsServer,
 )
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Store (
    EventData (..),
    EventType (..),
    ExpectedVersion (..),
    KirokuStore (..),
    StreamName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    appendToStream,
    cancel,
    defaultConnectionSettings,
    defaultSubscriptionConfig,
    runStoreIO,
    subscribe,
    wait,
    withStore,
 )
import Kiroku.Store.Subscription.EventPublisher (EventPublisher (..), publisherPosition)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)

subName :: SubscriptionName
subName = SubscriptionName "metrics-server-it"

spec :: Spec
spec = describe "Kiroku.Metrics.Server (endpoints)" $ do
    it "serves JSON, Prometheus, and health endpoints over HTTP" $
        withMigratedTestDatabase $ \connStr -> do
            storeVar <- newTVarIO Nothing
            km <- newKirokuMetricsWith (readPosition storeVar) (readSubscribers storeVar)
            let settings =
                    defaultConnectionSettings connStr
                        & #eventHandler .~ Just (metricsEventHandler km Nothing)
                        & #observationHandler .~ Just (metricsObservationHandler km Nothing)
            withStore settings $ \store -> do
                atomically (writeTVar storeVar (Just store))
                delivered <- newTVarIO (0 :: Int)
                let cfg =
                        defaultSubscriptionConfig subName AllStreams $ \_event -> do
                            atomically (modifyCount delivered)
                            pure Continue
                handle <- subscribe store cfg
                appendStoreEvents store (StreamName "metrics-server-stream") 3
                waitForCount delivered 3 10_000_000

                mgr <- newManager defaultManagerSettings

                -- Healthy server (no dependency checks).
                let serverCfg = defaultConfig{port = 0}
                srv <- startMetricsServer serverCfg km []
                threadDelay 200_000
                let base = "http://127.0.0.1:" <> show srv.serverPort

                (sMetrics, bMetrics) <- get mgr (base <> "/metrics")
                sMetrics `shouldBe` 200
                globalPositionOf bMetrics `shouldSatisfy` (>= 3)

                (sOne, _) <- get mgr (base <> "/metrics/metrics-server-it")
                sOne `shouldBe` 200

                (sUnknown, _) <- get mgr (base <> "/metrics/does-not-exist")
                sUnknown `shouldBe` 404

                (sProm, bProm) <- get mgr (base <> "/metrics/prometheus")
                sProm `shouldBe` 200
                bodyText bProm `shouldSatisfy` T.isInfixOf "kiroku_events_appended_total"

                (sLive, _) <- get mgr (base <> "/health/live")
                sLive `shouldBe` 200

                (sReady, _) <- get mgr (base <> "/health/ready")
                sReady `shouldBe` 200

                (sWs, _) <- get mgr (base <> "/ws")
                sWs `shouldBe` 404

                (sNope, _) <- get mgr (base <> "/nope")
                sNope `shouldBe` 404

                stopMetricsServer srv

                -- A failing dependency check flips readiness to 503.
                let failing = pure (DependencyStatus "fake" False Nothing (Just "down"))
                srv2 <- startMetricsServer serverCfg km [failing]
                threadDelay 200_000
                let base2 = "http://127.0.0.1:" <> show srv2.serverPort
                (sReady2, _) <- get mgr (base2 <> "/health/ready")
                sReady2 `shouldBe` 503
                stopMetricsServer srv2

                cancel handle
                _ <- wait handle
                pure ()

-- | GET a URL, returning the status code and the body, without throwing on non-2xx.
get :: Manager -> String -> IO (Int, ByteString)
get mgr url = do
    req <- parseRequest url
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), responseBody resp)

-- | Extract @store.global_position@ from a @/metrics@ JSON body.
globalPositionOf :: ByteString -> Int
globalPositionOf body =
    case decode body of
        Just (Object o)
            | Just (Object store) <- KM.lookup (Key.fromText "store") o
            , Just (Number n) <- KM.lookup (Key.fromText "global_position") store ->
                truncate (toRealFloat n :: Double)
        _ -> -1

bodyText :: ByteString -> T.Text
bodyText = TE.decodeUtf8 . LBS.toStrict

readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
    readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
    readTVar storeVar
        >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))

modifyCount :: TVar Int -> STM ()
modifyCount v = readTVar v >>= \c -> writeTVar v (c + 1)

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

waitForCount :: TVar Int -> Int -> Int -> IO ()
waitForCount countVar target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    ok <-
        atomically $
            (do c <- readTVar countVar; check (c >= target); pure True)
                `orElse` (do t <- readTVar timeoutVar; check t; pure False)
    unless ok $ do
        actual <- atomically (readTVar countVar)
        expectationFailure ("Timed out waiting for " <> show target <> ", got " <> show actual)
