{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression tests for ExecPlan 41 M2 — recoverable backpressure.

Before M2, a slow AllStreams consumer that filled its bounded queue was
__terminal__: the publisher marked it @Overflowed@ and the worker threw
'Kiroku.Store.Subscription.Types.SubscriptionOverflowed' and died (overflow
policy 'Kiroku.Store.Subscription.Types.DropSubscription'). M2 adds the
recoverable 'Kiroku.Store.Subscription.Types.PauseAndResume' policy (now the
default): when the queue fills the publisher /pauses/ delivery rather than
killing the subscriber, and the worker — once its slow handler catches up —
drains the stale queue and re-reads the events it missed directly from the
database from its checkpoint. No event is lost and the checkpoint advances
monotonically.

The first spec proves the recovery: a handler that blocks long enough to fill a
@queueCapacity = 1@ subscriber while five events are appended still delivers all
five in order, stops cleanly (not via 'SubscriptionOverflowed'), advances the
checkpoint to the last position, and emits a
'Kiroku.Store.Observability.KirokuEventSubscriptionPaused' followed by a
'Kiroku.Store.Observability.KirokuEventSubscriptionResumed'.

The second spec proves the fail-fast path is preserved: the identical scenario
under 'DropSubscription' still surfaces 'SubscriptionOverflowed' on @wait@.

To confirm the first spec actually pins the new behavior: temporarily set its
@overflowPolicy@ to 'DropSubscription' and it fails with
@Left (SubscriptionOverflowed ...)@ where it expected @Right ()@.
-}
module Test.SubscriptionPauseResume (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception qualified
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
import Kiroku.Store.Subscription.Types (OverflowPolicy (..), SubscriptionConfigM (..), SubscriptionOverflowed (..))
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

-- Read the durable checkpoint (@kiroku.subscriptions.last_seen@) for a non-group
-- subscription (member 0), or 'Nothing' if no row exists yet.
readCheckpoint :: KirokuStore -> T.Text -> IO (Maybe Int)
readCheckpoint store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> error ("readCheckpoint failed: " <> show err)
        Right mPos -> pure (fmap fromIntegral mPos)

spec :: Spec
spec = describe "subscription FSM — recoverable backpressure (EP-41 M2)" $ do
    it "pauses a slow AllStreams consumer and resumes, delivering all events" $ do
        evtRef <- newIORef ([] :: [KirokuEvent])
        let evtHandler e = modifyIORef' evtRef (e :)
        withTestStoreSettings (& #eventHandler .~ Just evtHandler) $ \store -> do
            firstSeen <- newEmptyMVar
            release <- newEmptyMVar
            delivered <- newIORef ([] :: [GlobalPosition])
            seenCount <- newTVarIO (0 :: Int)
            let handler' evt = do
                    modifyIORef' delivered ((evt ^. #globalPosition) :)
                    n <- atomically $ do
                        c <- readTVar seenCount
                        writeTVar seenCount (c + 1)
                        pure (c + 1)
                    if n == 1
                        then putMVar firstSeen () >> takeMVar release
                        else pure ()
                    -- Stop once all five have been seen, so `wait` resolves Right ().
                    if n >= 5 then pure Stop else pure Continue
            let cfg =
                    SubscriptionConfig
                        { name = SubscriptionName "pause-resume-test"
                        , target = AllStreams
                        , handler = handler'
                        , batchSize = 100
                        , queueCapacity = 1
                        , overflowPolicy = PauseAndResume
                        , consumerGroup = Nothing
                        , consumerGroupGuard = False
                        , retryPolicy = defaultRetryPolicy
                        , eventTypeFilter = AllEventTypes
                        }
            handle <- subscribe store cfg
            -- First append: the worker reads it from the queue and the handler
            -- blocks inside it on `release`, so the worker stops draining.
            Right _ <- runStoreIO store $ appendToStream (StreamName "pr-1") NoStream [makeEvent "E1" (Aeson.object [])]
            takeMVar firstSeen
            -- With the worker stuck, append four more one at a time. Capacity is 1,
            -- so the second of these fills the queue and the publisher pauses the
            -- subscriber for the rest (skipping, not dropping).
            let appendOne i = do
                    let sn = StreamName ("pr-" <> T.pack (show (i :: Int)))
                    Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Ex" (Aeson.object [])]
                    waitForPublisher store (GlobalPosition (fromIntegral i))
            appendOne 2
            appendOne 3
            appendOne 4
            appendOne 5
            -- Release the slow handler; the worker drains, resumes, re-catches-up
            -- from its checkpoint, and delivers the skipped events.
            putMVar release ()
            result <- waitWithTimeout 15_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected a clean stop, got: " <> show e)
                Right (Right ()) -> pure ()
            ds <- reverse <$> readIORef delivered
            ds `shouldBe` map GlobalPosition [1 .. 5]
            cp <- readCheckpoint store "pause-resume-test"
            cp `shouldBe` Just 5
            evts <- readIORef evtRef
            let isPaused (KirokuEventSubscriptionPaused (SubscriptionName "pause-resume-test") _ _) = True
                isPaused _ = False
                isResumed (KirokuEventSubscriptionResumed (SubscriptionName "pause-resume-test") _ _) = True
                isResumed _ = False
            any isPaused evts `shouldBe` True
            any isResumed evts `shouldBe` True

    it "still fails fast under DropSubscription" $ do
        withTestStoreSettings Prelude.id $ \store -> do
            firstSeen <- newEmptyMVar
            release <- newEmptyMVar
            seenCount <- newTVarIO (0 :: Int)
            let handler' _evt = do
                    n <- atomically $ do
                        c <- readTVar seenCount
                        writeTVar seenCount (c + 1)
                        pure (c + 1)
                    if n == 1
                        then putMVar firstSeen () >> takeMVar release
                        else pure ()
                    pure Continue
            let cfg =
                    SubscriptionConfig
                        { name = SubscriptionName "dropsub-overflow-test"
                        , target = AllStreams
                        , handler = handler'
                        , batchSize = 100
                        , queueCapacity = 1
                        , overflowPolicy = DropSubscription
                        , consumerGroup = Nothing
                        , consumerGroupGuard = False
                        , retryPolicy = defaultRetryPolicy
                        , eventTypeFilter = AllEventTypes
                        }
            handle <- subscribe store cfg
            Right _ <- runStoreIO store $ appendToStream (StreamName "ds-1") NoStream [makeEvent "E1" (Aeson.object [])]
            takeMVar firstSeen
            let appendOne i = do
                    let sn = StreamName ("ds-" <> T.pack (show (i :: Int)))
                    Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Ex" (Aeson.object [])]
                    waitForPublisher store (GlobalPosition (fromIntegral i))
            appendOne 2
            appendOne 3
            appendOne 4
            appendOne 5
            putMVar release ()
            result <- waitWithTimeout 15_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Right ()) -> expectationFailure "expected SubscriptionOverflowed, got a clean stop"
                Right (Left e) ->
                    case Control.Exception.fromException e of
                        Just (SubscriptionOverflowed sn) -> sn `shouldBe` SubscriptionName "dropsub-overflow-test"
                        Nothing -> expectationFailure ("expected SubscriptionOverflowed, got: " <> show e)
