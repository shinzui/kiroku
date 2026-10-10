module Test.HandlerStall (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM qualified as STM
import Control.Exception (fromException)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Maybe (isNothing)
import Data.Time (NominalDiffTime)
import Data.Vector qualified as V
import GHC.Clock (getMonotonicTimeNSec)
import Kiroku.Store
import System.Timeout (timeout)
import Test.Helpers (caughtUpEventHandler, makeEvent, validConsumerGroup, waitForPublisher, waitForSubscriptionLive, withTestStoreSettings)
import Test.Hspec

within :: IO a -> IO a
within action = timeout 5_000_000 action >>= maybe (fail "handler stall test timed out") pure

appendEvents :: KirokuStore -> IO ()
appendEvents store = do
    Right _ <-
        runStoreIO store $
            appendToStream
                (StreamName "stall-events")
                NoStream
                [makeEvent "First" (Aeson.object []), makeEvent "Second" (Aeson.object [])]
    pure ()

checkpoint :: KirokuStore -> IO GlobalPosition
checkpoint store = do
    Right (SubscriptionCheckpointInventory _ rows) <- runStoreIO store subscriptionCheckpointInventory
    case [savedPosition | SubscriptionCheckpoint name _ savedPosition _ <- V.toList rows, name == SubscriptionName "stall-test"] of
        [savedPosition] -> pure savedPosition
        other -> fail ("unexpected checkpoints: " <> show other)

spec :: Spec
spec = describe "handler stall" $ do
    forM_
        [ (AllStreams, Nothing, False)
        , (AllStreams, Nothing, True)
        , (Category (CategoryName "stall"), Nothing, True)
        , (AllStreams, Just (validConsumerGroup 0 1), True)
        , (Category (CategoryName "stall"), Just (validConsumerGroup 0 1), False)
        ]
        $ \(target', group, live) ->
            it ("warns without acknowledging or checkpointing a blocked handler for " <> show (target', group, live)) $ do
                release <- newEmptyMVar
                caughtUp <- newEmptyMVar
                warning <- STM.newEmptyTMVarIO
                count <- STM.newTVarIO (0 :: Int)
                let subName = SubscriptionName "stall-test"
                    observe event = do
                        caughtUpEventHandler subName caughtUp Nothing event
                        case event of
                            KirokuEventSubscriptionHandlerStalled name pos eid elapsed groupContext | name == subName -> STM.atomically $ do
                                STM.modifyTVar' count (+ 1)
                                _ <- STM.tryPutTMVar warning (pos, eid, elapsed, groupContext)
                                pure ()
                            _ -> pure ()
                    tweak settings = settings & #eventHandler .~ Just observe
                    handler event =
                        if event ^. #globalPosition == GlobalPosition 1
                            then takeMVar release >> pure Continue
                            else pure Stop
                withTestStoreSettings tweak $ \store -> do
                    if live then pure () else appendEvents store >> waitForPublisher store (GlobalPosition 2)
                    handle <-
                        subscribe
                            store
                            ( (defaultSubscriptionConfig subName target' handler)
                                { consumerGroup = group
                                , handlerStallWarnAfter = Just 0.05
                                }
                            )
                    if live then waitForSubscriptionLive caughtUp >> appendEvents store else pure ()
                    (pos, eid, elapsed, groupContext) <- within (STM.atomically (STM.readTMVar warning))
                    pos `shouldBe` GlobalPosition 1
                    Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 1)
                    eid `shouldBe` (V.head events ^. #eventId)
                    elapsed `shouldSatisfy` (>= 0.05)
                    groupContext `shouldBe` maybe NonGroup (\_ -> GroupMember 0 1) group
                    checkpoint store `shouldReturn` GlobalPosition 0
                    putMVar release ()
                    within (wait handle) >>= (`shouldSatisfy` either (const False) (const True))
                    checkpoint store `shouldReturn` GlobalPosition 2
                    stoppedCount <- STM.readTVarIO count
                    threadDelay 120_000
                    STM.readTVarIO count `shouldReturn` stoppedCount
                    currentState handle >>= (`shouldSatisfy` isNothing)

    it "warns periodically while pending and joins the watchdog on cancellation" $ do
        blocked <- newEmptyMVar
        warnings <- STM.newTQueueIO
        let observe event = case event of
                KirokuEventSubscriptionHandlerStalled _ pos _ elapsed _ -> do
                    now <- getMonotonicTimeNSec
                    STM.atomically (STM.writeTQueue warnings (pos, elapsed, now))
                _ -> pure ()
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> takeMVar blocked >> pure Stop))
                        { handlerStallWarnAfter = Just 0.05
                        }
                    )
            (_, firstElapsed, firstAt) <- within (STM.atomically (STM.readTQueue warnings))
            (_, secondElapsed, secondAt) <- within (STM.atomically (STM.readTQueue warnings))
            secondElapsed `shouldSatisfy` (> firstElapsed)
            secondAt - firstAt `shouldSatisfy` (>= 45_000_000)
            checkpoint store `shouldReturn` GlobalPosition 0
            within (cancel handle)
            _ <- STM.atomically (STM.flushTQueue warnings)
            threadDelay 120_000
            STM.atomically (STM.isEmptyTQueue warnings) `shouldReturn` True
            currentState handle >>= (`shouldSatisfy` isNothing)

    it "warns for the current invocation after replacing a quick handler" $ do
        release <- newEmptyMVar
        warning <- STM.newEmptyTMVarIO
        let observe event = case event of
                KirokuEventSubscriptionHandlerStalled _ pos _ elapsed _ -> STM.atomically $ do
                    _ <- STM.tryPutTMVar warning (pos, elapsed)
                    pure ()
                _ -> pure ()
            handler event =
                if event ^. #globalPosition == GlobalPosition 1
                    then pure Continue
                    else takeMVar release >> pure Stop
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams handler)
                        { handlerStallWarnAfter = Just 0.05
                        }
                    )
            (pos, elapsed) <- within (STM.atomically (STM.readTMVar warning))
            pos `shouldBe` GlobalPosition 2
            elapsed `shouldSatisfy` (>= 0.05)
            -- Normal progress is persisted at the batch boundary.
            checkpoint store `shouldReturn` GlobalPosition 0
            putMVar release ()
            _ <- within (wait handle)
            pure ()

    it "contains a throwing diagnostic callback and still completes the handler" $ do
        release <- newEmptyMVar
        observed <- STM.newEmptyTMVarIO
        let observe KirokuEventSubscriptionHandlerStalled{} = do
                STM.atomically $ do
                    _ <- STM.tryPutTMVar observed ()
                    pure ()
                ioError (userError "diagnostic callback failed")
            observe _ = pure ()
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> takeMVar release >> pure Stop))
                        { handlerStallWarnAfter = Just 0.05
                        }
                    )
            within (STM.atomically (STM.readTMVar observed))
            putMVar release ()
            within (wait handle) >>= (`shouldSatisfy` either (const False) (const True))
            checkpoint store `shouldReturn` GlobalPosition 1

    it "clears tracking and joins the watchdog when a handler throws" $ do
        release <- newEmptyMVar
        count <- STM.newTVarIO (0 :: Int)
        let observe KirokuEventSubscriptionHandlerStalled{} = STM.atomically (STM.modifyTVar' count (+ 1))
            observe _ = pure ()
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> takeMVar release >> ioError (userError "handler failed")))
                        { handlerStallWarnAfter = Just 0.05
                        }
                    )
            within (STM.atomically (STM.readTVar count >>= STM.check . (> 0)))
            putMVar release ()
            within (wait handle) >>= (`shouldSatisfy` either (const True) (const False))
            stoppedCount <- STM.readTVarIO count
            threadDelay 120_000
            STM.readTVarIO count `shouldReturn` stoppedCount
            checkpoint store `shouldReturn` GlobalPosition 0

    it "emits nothing when the handler completes before the threshold" $ do
        count <- STM.newTVarIO (0 :: Int)
        let observe KirokuEventSubscriptionHandlerStalled{} = STM.atomically (STM.modifyTVar' count (+ 1))
            observe _ = pure ()
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> pure Stop))
                        { handlerStallWarnAfter = Just 0.1
                        }
                    )
            within (wait handle) >>= (`shouldSatisfy` either (const False) (const True))
            threadDelay 150_000
            STM.readTVarIO count `shouldReturn` 0

    it "keeps warnings disabled by default even when a handler is blocked" $ do
        entered <- newEmptyMVar
        release <- newEmptyMVar
        count <- STM.newTVarIO (0 :: Int)
        let observe KirokuEventSubscriptionHandlerStalled{} = STM.atomically (STM.modifyTVar' count (+ 1))
            observe _ = pure ()
        withTestStoreSettings (\s -> s & #eventHandler .~ Just observe) $ \store -> do
            appendEvents store
            waitForPublisher store (GlobalPosition 2)
            let config = defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> putMVar entered () >> takeMVar release >> pure Stop)
            handlerStallWarnAfter config `shouldBe` Nothing
            handle <- subscribe store config
            within (takeMVar entered)
            threadDelay 150_000
            STM.readTVarIO count `shouldReturn` 0
            putMVar release ()
            _ <- within (wait handle)
            pure ()

    forM_ [0, -1 :: NominalDiffTime] $ \threshold ->
        it ("refuses a nonpositive warning interval before checkpoint initialization: " <> show threshold) $
            withTestStoreSettings Prelude.id $ \store -> do
                handle <-
                    subscribe
                        store
                        ( (defaultSubscriptionConfig (SubscriptionName "stall-test") AllStreams (\_ -> pure Stop))
                            { handlerStallWarnAfter = Just threshold
                            }
                        )
                within (wait handle) >>= \case
                    Left err -> do
                        (fromException err :: Maybe InvalidHandlerStallWarnAfter) `shouldBe` Just (InvalidHandlerStallWarnAfter threshold)
                        (fromException err :: Maybe SomeSubscriptionStartupFailure) `shouldSatisfy` (not . isNothing)
                    Right () -> expectationFailure "invalid interval was accepted"
                Right (SubscriptionCheckpointInventory _ rows) <- runStoreIO store subscriptionCheckpointInventory
                V.null rows `shouldBe` True
