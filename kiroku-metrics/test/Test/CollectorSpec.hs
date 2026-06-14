{- | Pure unit tests for the metrics collector: feed scripted 'KirokuEvent' and
'Observation' values through the callback wrappers and assert the resulting
snapshot. No store is opened — the two store-level gauges are supplied by fake
STM readers via 'newKirokuMetricsWith'.
-}
module Test.CollectorSpec (spec) where

import Control.Concurrent.STM (STM)
import Control.Exception (SomeException, toException)
import Control.Monad (forM_)
import Data.Map.Strict qualified as Map
import Data.UUID (UUID, fromWords)
import Hasql.Pool (UsageError (..))
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
    ConnectionReadyForUseReason (..),
    ConnectionStatus (..),
    ConnectionTerminationReason (..),
    KirokuEvent (..),
    Observation (..),
    SubscriptionDbPhase (..),
    SubscriptionGroupContext (..),
    SubscriptionStopReason (..),
 )
import Kiroku.Store.Observability (SubscriptionDeliveryPhase (..))
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))

{- | A collector whose fake store readers report the given global position and
active-subscriber count, fed the given scripted events and observations.
-}
runScript ::
    STM GlobalPosition ->
    STM Int ->
    [KirokuEvent] ->
    [Observation] ->
    IO MetricsSnapshot
runScript readPos readSubs events obs = do
    km <- newKirokuMetricsWith readPos readSubs
    forM_ events (metricsEventHandler km Nothing)
    forM_ obs (metricsObservationHandler km Nothing)
    snapshotMetrics km

sub :: SubscriptionName
sub = SubscriptionName "p"

uuidN :: Word -> UUID
uuidN n = fromWords 0 0 0 (fromIntegral n)

-- | A dummy exception for the strict 'SomeException' field of notifier events.
someExc :: SomeException
someExc = toException (userError "test")

-- | A dummy 'UsageError' for the strict field of database-error events.
dbErr :: UsageError
dbErr = AcquisitionTimeoutUsageError

spec :: Spec
spec = describe "Kiroku.Metrics.Collector" $ do
    it "counts notifier reconnect events" $ do
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                [ KirokuEventNotifierReconnecting 1 someExc
                , KirokuEventNotifierReconnecting 2 someExc
                , KirokuEventNotifierReconnected
                ]
                []
        snap.counters.notifierReconnecting `shouldBe` 2
        snap.counters.notifierReconnected `shouldBe` 1

    it "counts publisher pool and loop errors separately" $ do
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                [ KirokuEventPublisherPoolError dbErr
                , KirokuEventPublisherLoopError someExc
                , KirokuEventPublisherLoopError someExc
                ]
                []
        snap.counters.publisherPoolErrors `shouldBe` 1
        snap.counters.publisherLoopErrors `shouldBe` 2

    it "records subscription position and derives lag from the global position" $ do
        snap <-
            runScript
                (pure (GlobalPosition 12))
                (pure 3)
                [KirokuEventSubscriptionStarted sub (GlobalPosition 5) NonGroup]
                []
        snap.store.globalPosition `shouldBe` 12
        snap.store.activeSubscribers `shouldBe` 3
        snap.counters.subscriptionsStarted `shouldBe` 1
        case Map.lookup "p" snap.subscriptions of
            Nothing -> expectationFailure "expected subscription \"p\" in snapshot"
            Just m -> do
                m.lastKnownPosition `shouldBe` 5
                m.lag `shouldBe` 7

    it "advances last-known position monotonically and never reports negative lag" $ do
        snap <-
            runScript
                (pure (GlobalPosition 8))
                (pure 1)
                [ KirokuEventSubscriptionStarted sub (GlobalPosition 5) NonGroup
                , KirokuEventSubscriptionCaughtUp sub (GlobalPosition 10) NonGroup
                ]
                []
        case Map.lookup "p" snap.subscriptions of
            Nothing -> expectationFailure "expected subscription \"p\""
            Just m -> do
                m.lastKnownPosition `shouldBe` 10
                m.lag `shouldBe` 0 -- max 0 (8 - 10)
    it "tallies stop reasons and records the last one per subscription" $ do
        snap <-
            runScript
                (pure (GlobalPosition 20))
                (pure 0)
                [ KirokuEventSubscriptionStarted sub (GlobalPosition 0) NonGroup
                , KirokuEventSubscriptionStopped sub (GlobalPosition 20) StopHandlerRequested NonGroup
                ]
                []
        snap.counters.subscriptionsStoppedHandler `shouldBe` 1
        (Map.lookup "p" snap.subscriptions >>= (.lastStopReason)) `shouldBe` Just "handler"

    it "tallies per-phase database errors and the per-subscription error count" $ do
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                [ KirokuEventSubscriptionDbError sub LoadCheckpoint dbErr NonGroup
                , KirokuEventSubscriptionDbError sub FetchBatch dbErr NonGroup
                , KirokuEventSubscriptionDbError sub FetchBatch dbErr NonGroup
                ]
                []
        snap.counters.subscriptionDbErrorsLoad `shouldBe` 1
        snap.counters.subscriptionDbErrorsFetch `shouldBe` 2
        (Map.lookup "p" snap.subscriptions >>= Just . (.dbErrorCount)) `shouldBe` Just 3

    it "counts delivered batches and sums delivered events" $ do
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                [ KirokuEventSubscriptionDelivered sub 3 DeliveredCatchUp NonGroup
                , KirokuEventSubscriptionDelivered sub 2 DeliveredLive NonGroup
                , KirokuEventSubscriptionFetched sub 2 NonGroup
                ]
                []
        snap.counters.batchesDelivered `shouldBe` 2
        snap.counters.eventsDelivered `shouldBe` 5
        snap.counters.liveFetches `shouldBe` 1

    it "tracks pool connection gauges and cumulative counters from observations" $ do
        let u = uuidN 1
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                []
                [ ConnectionObservation u ConnectingConnectionStatus
                , ConnectionObservation u (ReadyForUseConnectionStatus EstablishedConnectionReadyForUseReason)
                , ConnectionObservation u InUseConnectionStatus
                ]
        snap.store.poolConnecting `shouldBe` 0
        snap.store.poolReady `shouldBe` 0
        snap.store.poolInUse `shouldBe` 1
        snap.store.poolEstablishedTotal `shouldBe` 1
        snap.store.poolTerminatedTotal `shouldBe` 0

    it "removes terminated connections from the gauge and bumps the terminated counter" $ do
        let u = uuidN 2
        snap <-
            runScript
                (pure (GlobalPosition 0))
                (pure 0)
                []
                [ ConnectionObservation u (ReadyForUseConnectionStatus EstablishedConnectionReadyForUseReason)
                , ConnectionObservation u (TerminatedConnectionStatus ReleaseConnectionTerminationReason)
                ]
        snap.store.poolReady `shouldBe` 0
        snap.store.poolInUse `shouldBe` 0
        snap.store.poolEstablishedTotal `shouldBe` 1
        snap.store.poolTerminatedTotal `shouldBe` 1
