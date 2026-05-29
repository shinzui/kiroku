{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression tests for EP-40 (MasterPlan 6, child plan 2) — per-event retry
and dead-letter dispositions in @kiroku-store@.

These pin the three behavioral acceptance criteria from the ExecPlan:

  * __dead-letter__: a handler returning 'DeadLetter' for one event records it in
    @kiroku.dead_letters@, advances the checkpoint past it atomically, and keeps
    delivering later events;
  * __bounded retry__: a handler returning 'Retry' for one event sees that same
    event redelivered (the checkpoint does not advance past it) until it
    succeeds;
  * __retry exhaustion__: once the configured 'retryMaxAttempts' is exceeded the
    event is dead-lettered with 'DeadLetterMaxAttempts' and later events
    continue.

All three use an 'AllStreams' subscription (the FSM 'DeliverBatch' delivery
path). Events are appended and the publisher is awaited before subscribing, so
delivery happens during catch-up.
-}
module Test.SubscriptionRetryDeadLetter (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStore)
import Test.Hspec

posOf :: RecordedEvent -> Int64
posOf e = case e ^. #globalPosition of GlobalPosition p -> p

readCheckpoint :: KirokuStore -> Text -> IO (Maybe Int64)
readCheckpoint store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> error ("readCheckpoint failed: " <> show err)
        Right mPos -> pure mPos

readDeadLetters :: KirokuStore -> Text -> IO [SQL.DeadLetterRecord]
readDeadLetters store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.readDeadLettersStmt)
    case result of
        Left err -> error ("readDeadLetters failed: " <> show err)
        Right v -> pure (V.toList v)

-- Append three single-event streams so global positions are 1, 2, 3.
appendThree :: KirokuStore -> IO ()
appendThree store =
    mapM_
        ( \i -> do
            let sn = StreamName ("rdl-" <> T.pack (show (i :: Int)))
            Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent "E" (Aeson.object [])]
            pure ()
        )
        [1 .. 3]

spec :: Spec
spec = describe "subscription dispositions — retry / dead-letter (EP-40)" $ do
    it "dead-letters one event, advances the checkpoint, and keeps delivering" $ do
        withTestStore $ \store -> do
            appendThree store
            waitForPublisher store (GlobalPosition 3)
            delivered <- newIORef ([] :: [Int64])
            let subName = SubscriptionName "rdl-deadletter"
                handler' evt = do
                    let p = posOf evt
                    modifyIORef' delivered (p :)
                    case p of
                        2 -> pure (DeadLetter (DeadLetterPoison "boom"))
                        3 -> pure Stop
                        _ -> pure Continue
                cfg = (defaultSubscriptionConfig subName AllStreams handler'){batchSize = 100}
            handle <- subscribe store cfg
            result <- waitWithTimeout 20_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected a clean stop, got: " <> show e)
                Right (Right ()) -> pure ()
            ds <- reverse <$> readIORef delivered
            -- Each event delivered once; event 2 was dead-lettered (not retried).
            ds `shouldBe` [1, 2, 3]
            dls <- readDeadLetters store "rdl-deadletter"
            map SQL.deadLetterGlobalPosition dls `shouldBe` [2]
            -- Checkpoint advanced to the last processed event (the Stop at 3).
            cp <- readCheckpoint store "rdl-deadletter"
            cp `shouldBe` Just 3

    it "retries one event until it succeeds without advancing past it" $ do
        withTestStore $ \store -> do
            appendThree store
            waitForPublisher store (GlobalPosition 3)
            delivered <- newIORef ([] :: [Int64])
            pos2Count <- newIORef (0 :: Int)
            let subName = SubscriptionName "rdl-retry"
                handler' evt = do
                    let p = posOf evt
                    modifyIORef' delivered (p :)
                    case p of
                        2 -> do
                            c <- atomicModifyIORef' pos2Count (\x -> (x + 1, x + 1))
                            -- Retry the first two deliveries, succeed on the third.
                            if c <= 2 then pure (Retry (RetryDelay 0)) else pure Continue
                        3 -> pure Stop
                        _ -> pure Continue
                cfg = (defaultSubscriptionConfig subName AllStreams handler'){batchSize = 100}
            handle <- subscribe store cfg
            result <- waitWithTimeout 20_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected a clean stop, got: " <> show e)
                Right (Right ()) -> pure ()
            ds <- reverse <$> readIORef delivered
            -- Event 2 delivered three times (two retries + success); 1 and 3 once each.
            length (filter (== 2) ds) `shouldBe` 3
            ds `shouldBe` [1, 2, 2, 2, 3]
            -- No dead letters; the retry succeeded.
            dls <- readDeadLetters store "rdl-retry"
            dls `shouldSatisfy` null
            cp <- readCheckpoint store "rdl-retry"
            cp `shouldBe` Just 3

    it "dead-letters after exhausting the retry budget and continues" $ do
        withTestStore $ \store -> do
            appendThree store
            waitForPublisher store (GlobalPosition 3)
            delivered <- newIORef ([] :: [Int64])
            let subName = SubscriptionName "rdl-exhaust"
                handler' evt = do
                    let p = posOf evt
                    modifyIORef' delivered (p :)
                    case p of
                        2 -> pure (Retry (RetryDelay 0)) -- always retry → exhausts the budget
                        3 -> pure Stop
                        _ -> pure Continue
                cfg =
                    (defaultSubscriptionConfig subName AllStreams handler')
                        { batchSize = 100
                        , retryPolicy = RetryPolicy{retryMaxAttempts = 3}
                        }
            handle <- subscribe store cfg
            result <- waitWithTimeout 20_000_000 handle
            case result of
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected a clean stop, got: " <> show e)
                Right (Right ()) -> pure ()
            ds <- reverse <$> readIORef delivered
            -- Event 2 delivered exactly retryMaxAttempts (3) times, then dead-lettered.
            length (filter (== 2) ds) `shouldBe` 3
            ds `shouldBe` [1, 2, 2, 2, 3]
            dls <- readDeadLetters store "rdl-exhaust"
            map SQL.deadLetterGlobalPosition dls `shouldBe` [2]
            map SQL.deadLetterAttemptCount dls `shouldBe` [3]
            -- Later events still processed; checkpoint advanced to the end.
            cp <- readCheckpoint store "rdl-exhaust"
            cp `shouldBe` Just 3
