{-# LANGUAGE OverloadedStrings #-}

module Test.PublisherRestartNoRebroadcast (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Kiroku.Store
import Kiroku.Store.Subscription.Types (OverflowPolicy (..), SubscriptionConfigM (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Test.Helpers (caughtUpEventHandler, makeEvent, waitForPublisher, waitForSubscriptionLive, waitWithTimeout)
import Test.Hspec

spec :: Spec
spec =
    describe "publisher restart tail initialization" $ do
        it "does not rebroadcast restart history into a blocked all-stream subscriber" $
            withMigratedTestDatabase $ \connStr -> do
                let settings = defaultConnectionSettings connStr
                withStore settings $ \store ->
                    appendBatch store "tail-init-overflow-seed" "TailInitSeed" 1001

                firstSeen <- newEmptyMVar
                releaseFirst <- newEmptyMVar
                caughtUp <- newEmptyMVar
                blockedFirst <- newTVarIO True
                ref <- newIORef ([] :: [GlobalPosition])

                let subName = SubscriptionName "tail-init-no-rebroadcast"
                    stopType = EventType "TailInitStop"
                    handler' evt = do
                        modifyIORef' ref ((evt ^. #globalPosition) :)
                        shouldBlock <- atomically $ do
                            block <- readTVar blockedFirst
                            when block (writeTVar blockedFirst False)
                            pure block
                        when shouldBlock $ do
                            putMVar firstSeen ()
                            takeMVar releaseFirst
                        if evt ^. #eventType == stopType
                            then pure Stop
                            else pure Continue
                    cfg =
                        SubscriptionConfig
                            { name = subName
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 10
                            , queueCapacity = 1
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            , retryPolicy = defaultRetryPolicy
                            , eventTypeFilter = AllEventTypes
                            }
                    liveSettings =
                        settings
                            & #eventHandler .~ Just (caughtUpEventHandler subName caughtUp Nothing)

                withStore liveSettings $ \store -> do
                    handle <- subscribe store cfg
                    takeMVar firstSeen

                    Right _ <-
                        runStoreIO store $
                            appendToStream
                                (StreamName "tail-init-overflow-live")
                                NoStream
                                [makeEvent "TailInitDuringCatchUp" (Aeson.object [])]
                    waitForPublisher store (GlobalPosition 1002)

                    putMVar releaseFirst ()
                    waitForSubscriptionLive caughtUp

                    Right _ <-
                        runStoreIO store $
                            appendToStream
                                (StreamName "tail-init-overflow-stop")
                                NoStream
                                [makeEvent "TailInitStop" (Aeson.object [])]

                    result <- waitWithTimeout 10_000_000 handle
                    case result of
                        Left timeout -> expectationFailure timeout
                        Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                        Right (Right ()) -> pure ()

                collected <- reverse <$> readIORef ref
                collected `shouldBe` map GlobalPosition [1 .. 1003]

        it "delivers a live event appended after a restarted subscriber catches up" $
            withMigratedTestDatabase $ \connStr -> do
                let settings = defaultConnectionSettings connStr
                    subName = SubscriptionName "tail-init-live-after-catchup"
                withStore settings $ \store ->
                    appendBatch store "tail-init-live-seed" "TailInitLiveSeed" 3

                caughtUp <- newEmptyMVar
                ref <- newIORef ([] :: [GlobalPosition])
                let cfg =
                        SubscriptionConfig
                            { name = subName
                            , target = AllStreams
                            , handler = \evt -> do
                                modifyIORef' ref ((evt ^. #globalPosition) :)
                                if evt ^. #globalPosition == GlobalPosition 4
                                    then pure Stop
                                    else pure Continue
                            , batchSize = 10
                            , queueCapacity = 1
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            , retryPolicy = defaultRetryPolicy
                            , eventTypeFilter = AllEventTypes
                            }
                    liveSettings =
                        settings
                            & #eventHandler .~ Just (caughtUpEventHandler subName caughtUp Nothing)

                withStore liveSettings $ \store -> do
                    handle <- subscribe store cfg
                    waitForSubscriptionLive caughtUp
                    Right _ <-
                        runStoreIO store $
                            appendToStream
                                (StreamName "tail-init-live-after-catchup")
                                NoStream
                                [makeEvent "TailInitLiveAfterCatchUp" (Aeson.object [])]
                    result <- waitWithTimeout 10_000_000 handle
                    case result of
                        Left timeout -> expectationFailure timeout
                        Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                        Right (Right ()) -> pure ()

                collected <- reverse <$> readIORef ref
                collected `shouldBe` map GlobalPosition [1 .. 4]

        it "keeps per-subscription checkpoints independent from the publisher tail" $
            withMigratedTestDatabase $ \connStr -> do
                let settings = defaultConnectionSettings connStr
                withStore settings $ \store ->
                    appendBatch store "tail-init-checkpoint-seed" "TailInitCheckpointSeed" 10

                withStore settings $ \store -> do
                    runUntil store (SubscriptionName "tail-init-sub-a") 3
                        `shouldReturn` map GlobalPosition [1 .. 3]
                    runUntil store (SubscriptionName "tail-init-sub-b") 7
                        `shouldReturn` map GlobalPosition [1 .. 7]

                withStore settings $ \store -> do
                    runUntil store (SubscriptionName "tail-init-sub-a") 7
                        `shouldReturn` map GlobalPosition [4 .. 10]
                    runUntil store (SubscriptionName "tail-init-sub-b") 3
                        `shouldReturn` map GlobalPosition [8 .. 10]

appendBatch :: KirokuStore -> T.Text -> T.Text -> Int -> IO ()
appendBatch store streamName typePrefix count = do
    let events =
            [ makeEvent (typePrefix <> T.pack (show i)) (Aeson.object [])
            | i <- [1 .. count]
            ]
    result <- runStoreIO store $ appendToStream (StreamName streamName) NoStream events
    case result of
        Left err -> expectationFailure ("append failed: " <> show err)
        Right _ -> pure ()

runUntil :: KirokuStore -> SubscriptionName -> Int -> IO [GlobalPosition]
runUntil store subName targetCount = do
    ref <- newIORef ([] :: [GlobalPosition])
    countRef <- newTVarIO (0 :: Int)
    let handler' evt = do
            modifyIORef' ref ((evt ^. #globalPosition) :)
            n <- atomically $ do
                count <- readTVar countRef
                let count' = count + 1
                writeTVar countRef count'
                pure count'
            if n >= targetCount
                then pure Stop
                else pure Continue
        cfg =
            SubscriptionConfig
                { name = subName
                , target = AllStreams
                , handler = handler'
                , batchSize = 10
                , queueCapacity = 1
                , overflowPolicy = DropSubscription
                , consumerGroup = Nothing
                , consumerGroupGuard = False
                , retryPolicy = defaultRetryPolicy
                , eventTypeFilter = AllEventTypes
                }
    handle <- subscribe store cfg
    result <- waitWithTimeout 10_000_000 handle
    case result of
        Left timeout -> expectationFailure timeout
        Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
        Right (Right ()) -> pure ()
    reverse <$> readIORef ref
