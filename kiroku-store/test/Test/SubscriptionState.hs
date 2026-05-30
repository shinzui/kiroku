{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression tests for ExecPlan 41 M4 — observable FSM state and the
no-missed-events / monotonic-checkpoint invariants under the FSM driver.

The first spec reads the worker's current state through the new
'Kiroku.Store.Subscription.Types.currentState' handle accessor: while a handler
blocks on its first catch-up event the worker is observably @CatchingUp@, and
once it has caught up it is observably @Live@.

The second spec proves the FSM driver preserves the core delivery invariant: with
events appended both before and after the subscription starts, every event is
delivered exactly once in strictly increasing 'GlobalPosition' across the
catch-up → live boundary, and the durable checkpoint advances to the last
position (a monotonic, no-gap result).
-}
module Test.SubscriptionState (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.Text qualified as T
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Fsm (SubscriptionState (..))
import Kiroku.Store.Subscription.Types (SubscriptionConfigM (..))
import Test.Helpers (caughtUpEventHandler, makeEvent, waitForPublisher, waitForSubscriptionLive, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

isCatchingUp :: SubscriptionState -> Bool
isCatchingUp CatchingUp{} = True
isCatchingUp _ = False

isLive :: SubscriptionState -> Bool
isLive Live{} = True
isLive _ = False

-- Poll an FSM-state read until the predicate holds or the budget runs out.
waitUntilState :: Int -> IO SubscriptionState -> (SubscriptionState -> Bool) -> IO Bool
waitUntilState budget readSt p
    | budget <= 0 = pure False
    | otherwise = do
        s <- readSt
        if p s
            then pure True
            else threadDelay 20_000 >> waitUntilState (budget - 20_000) readSt p

readCheckpoint :: KirokuStore -> T.Text -> IO (Maybe Int)
readCheckpoint store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> error ("readCheckpoint failed: " <> show err)
        Right mPos -> pure (fmap fromIntegral mPos)

spec :: Spec
spec = describe "subscription FSM — observable state (EP-41 M4)" $ do
    it "reports CatchingUp while blocked in catch-up and Live once caught up" $ do
        caughtUp <- newEmptyMVar
        firstSeen <- newEmptyMVar
        release <- newEmptyMVar
        seen <- newTVarIO (0 :: Int)
        let subName = SubscriptionName "state-readout-test"
            observe = caughtUpEventHandler subName caughtUp Nothing
            handler' _evt = do
                n <- atomically $ do
                    c <- readTVar seen
                    writeTVar seen (c + 1)
                    pure (c + 1)
                if n == 1
                    then putMVar firstSeen () >> takeMVar release
                    else pure ()
                pure Continue
            cfg =
                SubscriptionConfig
                    { name = subName
                    , target = AllStreams
                    , handler = handler'
                    , batchSize = 100
                    , queueCapacity = 16
                    , overflowPolicy = PauseAndResume
                    , consumerGroup = Nothing
                    , consumerGroupGuard = False
                    , retryPolicy = defaultRetryPolicy
                    , eventTypeFilter = AllEventTypes
                    , selector = Nothing
                    }
        withTestStoreSettings (& #eventHandler .~ Just observe) $ \store -> do
            Right _ <- runStoreIO store $ appendToStream (StreamName "st-1") NoStream [makeEvent "A" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "st-2") NoStream [makeEvent "B" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "st-3") NoStream [makeEvent "C" (Aeson.object [])]
            waitForPublisher store (GlobalPosition 3)
            handle <- subscribe store cfg
            -- Worker is now blocked inside the handler on the first catch-up event.
            takeMVar firstSeen
            st <- currentState handle
            st `shouldSatisfy` isCatchingUp
            -- Release: catch-up completes, the worker goes live.
            putMVar release ()
            waitForSubscriptionLive caughtUp
            becameLive <- waitUntilState 5_000_000 (currentState handle) isLive
            becameLive `shouldBe` True
            cancel handle

    it "delivers every event exactly once in order across the catch-up to live boundary" $ do
        delivered <- newIORef ([] :: [GlobalPosition])
        seen <- newTVarIO (0 :: Int)
        let subName = SubscriptionName "no-missed-test"
            handler' evt = do
                modifyIORef' delivered ((evt ^. #globalPosition) :)
                n <- atomically $ do
                    c <- readTVar seen
                    writeTVar seen (c + 1)
                    pure (c + 1)
                if n >= 10 then pure Stop else pure Continue
            cfg =
                SubscriptionConfig
                    { name = subName
                    , target = AllStreams
                    , handler = handler'
                    , batchSize = 100
                    , queueCapacity = 16
                    , overflowPolicy = PauseAndResume
                    , consumerGroup = Nothing
                    , consumerGroupGuard = False
                    , retryPolicy = defaultRetryPolicy
                    , eventTypeFilter = AllEventTypes
                    , selector = Nothing
                    }
        withTestStoreSettings Prelude.id $ \store -> do
            -- Five events before subscribing (delivered during catch-up).
            let appendAt i =
                    runStoreIO store $
                        appendToStream (StreamName ("nm-" <> T.pack (show (i :: Int)))) NoStream [makeEvent "E" (Aeson.object [])]
            mapM_ (\i -> appendAt i >> pure ()) [1 .. 5]
            waitForPublisher store (GlobalPosition 5)
            handle <- subscribe store cfg
            -- Five more after (delivered live).
            mapM_ (\i -> appendAt i >> pure ()) [6 .. 10]
            result <- waitWithTimeout 20_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("subscription failed: " <> show e)
                Right (Right ()) -> pure ()
            ds <- reverse <$> readIORef delivered
            ds `shouldBe` map GlobalPosition [1 .. 10]
            cp <- readCheckpoint store "no-missed-test"
            cp `shouldBe` Just 10
