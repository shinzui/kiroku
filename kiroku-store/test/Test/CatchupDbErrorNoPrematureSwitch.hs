module Test.CatchupDbErrorNoPrematureSwitch (spec) where

import Control.Concurrent.MVar (newEmptyMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List qualified as List
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Kiroku.Store
import Kiroku.Store.Subscription.Types qualified as SubTypes
import Kiroku.Store.Subscription.Worker (withFetchBatchHookForTest)
import Test.Helpers (
    caughtUpEventHandler,
    makeEvent,
    waitForPublisher,
    waitForSubscriptionLive,
    withTestStoreSettings,
 )
import Test.Hspec

spec :: Spec
spec =
    describe "catch-up DB error handling" $
        it "retries a transient fetch error instead of switching to live mode at a stale cursor" $ \() -> do
            deliveredRef <- newIORef ([] :: [GlobalPosition])
            failedOnce <- newIORef False
            eventRef <- newIORef ([] :: [KirokuEvent])
            seenCount <- newTVarIO (0 :: Int)
            caughtUp <- newEmptyMVar

            let subName = SubscriptionName "catchup-db-error-no-gap"
                targetTail = GlobalPosition 3
                handler' evt = do
                    modifyIORef' deliveredRef ((evt ^. #globalPosition) :)
                    atomically $ do
                        n <- readTVar seenCount
                        writeTVar seenCount (n + 1)
                    pure Continue
                cfg =
                    SubscriptionConfig
                        { name = subName
                        , target = AllStreams
                        , handler = handler'
                        , batchSize = 100
                        , queueCapacity = 16
                        , overflowPolicy = DropSubscription
                        , consumerGroup = Nothing
                        , consumerGroupGuard = False
                        , retryPolicy = defaultRetryPolicy
                        , eventTypeFilter = AllEventTypes
                        , selector = Nothing
                        }
                observe evt = do
                    modifyIORef' eventRef (evt :)
                    caughtUpEventHandler subName caughtUp Nothing evt
                injectOnce config cursor
                    | SubTypes.name config == subName && cursor == GlobalPosition 0 = do
                        alreadyFailed <- readIORef failedOnce
                        if alreadyFailed
                            then pure Nothing
                            else do
                                writeIORef failedOnce True
                                pure (Just (Left Pool.AcquisitionTimeoutUsageError))
                    | otherwise = pure Nothing

            withTestStoreSettings (& #eventHandler .~ Just observe) $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "catchup-db-error-1") NoStream [makeEvent "One" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "catchup-db-error-2") NoStream [makeEvent "Two" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "catchup-db-error-3") NoStream [makeEvent "Three" (Aeson.object [])]
                waitForPublisher store targetTail

                withFetchBatchHookForTest injectOnce $ do
                    handle <- subscribe store cfg
                    waitForSubscriptionLive caughtUp
                    atomically $ do
                        n <- readTVar seenCount
                        check (n >= 3)
                    cancel handle

            delivered <- readIORef deliveredRef
            List.sort delivered `shouldBe` [GlobalPosition 1, GlobalPosition 2, GlobalPosition 3]

            observed <- readIORef eventRef
            let isFetchDbError = \case
                    KirokuEventSubscriptionDbError n FetchBatch Pool.AcquisitionTimeoutUsageError _
                        | n == subName -> True
                    _ -> False
                caughtUpPositions =
                    [ pos
                    | KirokuEventSubscriptionCaughtUp n pos _ <- observed
                    , n == subName
                    ]

            any isFetchDbError observed `shouldBe` True
            V.fromList caughtUpPositions `shouldBe` V.singleton targetTail
