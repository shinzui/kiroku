{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression test for ExecPlan 41 M3 — worker-level live reconnect.

Before M3, a live database fetch error in the Category / consumer-group live
loops was retried in place, forever and invisibly. M3 lifts recovery into the
FSM: a live-mode 'Hasql.Pool.UsageError' drives the worker into the
'Kiroku.Store.Subscription.Fsm.Reconnecting' state — it emits
'Kiroku.Store.Observability.KirokuEventSubscriptionReconnecting', backs off, and
re-catches-up from its checkpoint — instead of silently spinning. The
subscription survives the fault and resumes from where it left off.

This spec uses a __Category__ subscription, not AllStreams: AllStreams live
delivery is fed by the shared publisher (which owns its own reconnect), so the
AllStreams worker performs no live-mode fetch and has nothing to reconnect. The
Category worker fetches in live mode, so 'withFetchBatchHookForTest' can inject
failures there. The hook fails the first @K@ fetches that occur __after__ the
subscription has caught up (a 'TVar' flag the @eventHandler@ sets on
'KirokuEventSubscriptionCaughtUp'), then falls through to the real database.

Asserted: at least one 'KirokuEventSubscriptionReconnecting' fired; @wait@ did
not surface the injected error (the worker recovered rather than died); every
appended event was delivered in increasing position; the checkpoint advanced to
the last position.
-}
module Test.SubscriptionReconnect (spec) where

import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
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
import Kiroku.Store.Subscription.Types qualified as SubTypes
import Kiroku.Store.Subscription.Worker (withFetchBatchHookForTest)
import Test.Helpers (makeEvent, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

readCheckpoint :: KirokuStore -> T.Text -> IO (Maybe Int)
readCheckpoint store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> error ("readCheckpoint failed: " <> show err)
        Right mPos -> pure (fmap fromIntegral mPos)

spec :: Spec
spec = describe "subscription FSM — worker-level live reconnect (EP-41 M3)" $ do
    it "reconnects and resumes after transient live-mode database errors" $ do
        evtRef <- newIORef ([] :: [KirokuEvent])
        deliveredRef <- newIORef ([] :: [GlobalPosition])
        caughtUpFlag <- newTVarIO False
        failsLeft <- newTVarIO (2 :: Int)
        seenCount <- newTVarIO (0 :: Int)

        let subName = SubscriptionName "reconnect-test"
            observe evt = do
                modifyIORef' evtRef (evt :)
                case evt of
                    KirokuEventSubscriptionCaughtUp n _ _
                        | n == subName -> atomically (writeTVar caughtUpFlag True)
                    _ -> pure ()
            -- Fail the first K fetches that happen after catch-up, then fall
            -- through to the real database. Catch-up fetches (flag still False)
            -- are never failed, so the fault is purely a live-mode event.
            injectHook config _cursor
                | SubTypes.name config == subName = do
                    cu <- readTVarIO caughtUpFlag
                    if not cu
                        then pure Nothing
                        else atomically $ do
                            n <- readTVar failsLeft
                            if n > 0
                                then do
                                    writeTVar failsLeft (n - 1)
                                    pure (Just (Left Pool.AcquisitionTimeoutUsageError))
                                else pure Nothing
                | otherwise = pure Nothing
            handler' evt = do
                modifyIORef' deliveredRef ((evt ^. #globalPosition) :)
                n <- atomically $ do
                    c <- readTVar seenCount
                    writeTVar seenCount (c + 1)
                    pure (c + 1)
                if n >= 3 then pure Stop else pure Continue
            cfg =
                SubscriptionConfig
                    { name = subName
                    , target = Category (CategoryName "rc")
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
            withFetchBatchHookForTest injectHook $ do
                -- Empty store: the worker catches up instantly (no fetch), sets the
                -- flag, then its first live-mode fetch is the one the hook fails —
                -- so the fault lands squarely in live mode.
                handle <- subscribe store cfg
                -- Wait until catch-up has completed and the reconnect failures have
                -- been consumed, so the appends below are served by the real DB.
                atomically $ do
                    cu <- readTVar caughtUpFlag
                    check cu
                    n <- readTVar failsLeft
                    check (n == 0)
                Right _ <- runStoreIO store $ appendToStream (StreamName "rc-1") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "rc-2") NoStream [makeEvent "B" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "rc-3") NoStream [makeEvent "C" (Aeson.object [])]
                result <- waitWithTimeout 20_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left e) -> expectationFailure ("worker did not survive the fault: " <> show e)
                    Right (Right ()) -> pure ()

            delivered <- reverse <$> readIORef deliveredRef
            delivered `shouldBe` map GlobalPosition [1 .. 3]
            cp <- readCheckpoint store "reconnect-test"
            cp `shouldBe` Just 3
            evts <- readIORef evtRef
            let isReconnecting (KirokuEventSubscriptionReconnecting n _ _) = n == subName
                isReconnecting _ = False
            any isReconnecting evts `shouldBe` True
