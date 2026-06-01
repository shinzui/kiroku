{-# LANGUAGE OverloadedLabels #-}

{- | Integration test: wire the collector into a real ephemeral
PostgreSQL-backed store, run a live @$all@ subscription, append events, and
assert the snapshot reflects real store activity (not just scripted inputs).

The ordering wrinkle is that 'newKirokuMetrics' needs the 'KirokuStore' but the
callbacks must be installed on 'ConnectionSettings' before 'withStore' creates
it. We resolve it with a @TVar (Maybe KirokuStore)@ the snapshot-time STM
readers consult; it is filled inside 'withStore'. (A 'TVar', not an 'IORef',
because the readers are 'STM'.)
-}
module Test.IntegrationSpec (spec) where

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
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec

import Kiroku.Metrics (
    LifecycleCounters (..),
    MetricsSnapshot (..),
    StoreGauges (..),
    SubscriptionMetrics (..),
    metricsEventHandler,
    metricsObservationHandler,
    newKirokuMetricsWith,
    snapshotMetrics,
 )
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
subName = SubscriptionName "metrics-it"

spec :: Spec
spec = describe "Kiroku.Metrics.Collector (integration)" $ do
    it "observes real store activity: appends, a running subscription, and lag" $
        withMigratedTestDatabase $ \connStr -> do
            -- Deferred store handle for the snapshot-time STM readers.
            storeVar <- newTVarIO Nothing
            km <-
                newKirokuMetricsWith
                    (readPosition storeVar)
                    (readSubscribers storeVar)
            let settings =
                    defaultConnectionSettings connStr
                        & #eventHandler .~ Just (metricsEventHandler km Nothing)
                        & #observationHandler .~ Just (metricsObservationHandler km Nothing)
            withStore settings $ \store -> do
                atomically (writeTVar storeVar (Just store))

                -- Subscribe to $all on an empty store: the worker goes live
                -- immediately, so the 5 events we append next flow through the
                -- live publisher path and advance publisherPosition.
                delivered <- newTVarIO (0 :: Int)
                let cfg =
                        defaultSubscriptionConfig subName AllStreams $ \_event -> do
                            atomically (modifyCount delivered)
                            pure Continue
                handle <- subscribe store cfg

                appendStoreEvents store (StreamName "metrics-it-stream") 5
                waitForCount delivered 5 10_000_000

                cancel handle
                _ <- wait handle

                snap <- snapshotMetrics km
                snap.store.globalPosition `shouldSatisfy` (>= 5)
                snap.counters.subscriptionsStarted `shouldBe` 1
                snap.counters.subscriptionsStoppedCancelled `shouldBe` 1
                snap.counters.eventsDelivered `shouldSatisfy` (>= 5)
                case Map.lookup "metrics-it" snap.subscriptions of
                    Nothing -> expectationFailure "expected subscription \"metrics-it\" in snapshot"
                    Just m -> m.lag `shouldSatisfy` (>= 0)

{- | Snapshot-time reader for the store global position, defaulting to 0 until
the store is filled in.
-}
readPosition :: TVar (Maybe KirokuStore) -> STM GlobalPosition
readPosition storeVar =
    readTVar storeVar >>= maybe (pure (GlobalPosition 0)) (publisherPosition . (.publisher))

-- | Snapshot-time reader for the active-subscriber count.
readSubscribers :: TVar (Maybe KirokuStore) -> STM Int
readSubscribers storeVar =
    readTVar storeVar
        >>= maybe (pure 0) (\s -> IntMap.size <$> readTVar (subscribers s.publisher))

modifyCount :: TVar Int -> STM ()
modifyCount v = readTVar v >>= \c -> writeTVar v (c + 1)

-- | Append @n@ trivial events to a fresh stream via the IO store interpreter.
appendStoreEvents :: KirokuStore -> StreamName -> Int -> IO ()
appendStoreEvents store stream n = do
    let events =
            [ EventData
                { eventId = Nothing
                , eventType = EventType ("E" <> T.pack (show i))
                , payload = Aeson.Null
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

-- | Wait until the counter reaches @target@ or the timeout (micros) fires.
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
