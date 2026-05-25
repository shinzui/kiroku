{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Regression tests for ExecPlan 37 — the live DB-driven subscription loops must
not busy-spin when idle while the store's global @$all@ position advances for
/other/ categories or partitions.

Two paths are covered:

  * Non-group @Category@ subscription
    ('Kiroku.Store.Subscription.Worker.liveLoopCategoryNotify'): an idle category
    blocks on its own per-category NOTIFY generation and does __zero__ database
    fetches while a different category receives sustained traffic. A real append
    to the subscribed category still wakes it (liveness).
  * Consumer-group member
    ('Kiroku.Store.Subscription.Worker.liveLoopDbDriven', corrected gate): an idle
    member gates on the /last observed global position/ rather than its
    per-partition cursor, so it wakes at most once per global advance — a bounded
    number of fetches — instead of the unbounded spin the original cursor-gate
    produced.

The deterministic signal is the additive
'Kiroku.Store.Observability.KirokuEventSubscriptionFetched' event, emitted once
per live DB-driven fetch. The store's @eventHandler@ counts those whose
'SubscriptionName' matches the subscriber under test; the subscription's own
handler counts deliveries. (@pg_stat_statements@ is not available in this suite —
see the plan's Decision Log.)

To confirm these specs actually pin the regression: temporarily restore the old
cursor-gated 'liveLoopDbDriven' body and route @(Nothing, Category{})@ back through
it — both idle fetch counts then explode and the assertions fail.
-}
module Test.CategoryIdleNoSpin (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as T
import Kiroku.Store
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfigM (..))
import Test.Helpers (caughtUpEventHandler, makeEvent, waitForPublisher, waitForSubscriptionLive, withTestStoreSettings)
import Test.Hspec

-- | Poll an @IO Bool@ predicate until it holds or the microsecond budget runs out.
waitUntil :: Int -> IO Bool -> IO ()
waitUntil budget act
    | budget <= 0 = pure ()
    | otherwise = do
        ok <- act
        if ok
            then pure ()
            else do
                threadDelay 20_000
                waitUntil (budget - 20_000) act

-- | Append one event to each named stream, failing the test on a store error.
appendEach :: KirokuStore -> [T.Text] -> T.Text -> IO ()
appendEach store names typ =
    mapM_
        ( \sn -> do
            r <- runStoreIO store $ appendToStream (StreamName sn) NoStream [makeEvent typ (Aeson.object [])]
            either (error . ("append failed: " <>) . show) (const (pure ())) r
        )
        names

spec :: Spec
spec = describe "live loops do not busy-spin while idle (plan 37)" $ do
    it "an idle Category subscriber does zero fetches while another category is active, then wakes on its own event" $ do
        let subName = SubscriptionName "alpha-sub"
        deliveredVar <- newTVarIO (0 :: Int)
        fetchVar <- newTVarIO (0 :: Int)
        liveBarrier <- newEmptyMVar
        let countFetch evt = case evt of
                KirokuEventSubscriptionFetched n _ _
                    | n == subName -> atomically (modifyTVar' fetchVar (+ 1))
                _ -> pure ()
            obsHandler = caughtUpEventHandler subName liveBarrier (Just countFetch)
        withTestStoreSettings (\s -> s & #eventHandler .~ Just obsHandler) $ \store -> do
            let deliver _evt = do
                    atomically (modifyTVar' deliveredVar (+ 1))
                    pure Continue
                cfg = defaultSubscriptionConfig subName (Category (CategoryName "alpha")) deliver
            bracket (subscribe store cfg) cancel $ \_handle -> do
                -- Wait until the worker reaches live mode and completes its initial
                -- post-catch-up drain (one empty fetch), so the baseline is settled.
                waitForSubscriptionLive liveBarrier
                waitUntil 5_000_000 ((>= 1) <$> readTVarIO fetchVar)
                base <- readTVarIO fetchVar

                -- Drive a DIFFERENT category hard: the global tail races far ahead of
                -- alpha's cursor. Under the old gate alpha woke per global tick and
                -- spun one empty fetch each time; under the fix it never wakes (its
                -- category generation is untouched).
                let betaCount = 20 :: Int
                    betaStreams = ["beta-" <> T.pack (show i) | i <- [1 .. betaCount]]
                appendEach store betaStreams "Beta"
                waitForPublisher store (GlobalPosition (fromIntegral betaCount))
                -- Give a (hypothetical) spinning worker ample time to accumulate fetches.
                threadDelay 500_000

                afterIdle <- readTVarIO fetchVar
                deliveredIdle <- readTVarIO deliveredVar
                (afterIdle - base) `shouldBe` 0
                deliveredIdle `shouldBe` 0

                -- Liveness: a real append to alpha must wake the worker and deliver.
                appendEach store ["alpha-1"] "Alpha"
                waitUntil 5_000_000 ((>= 1) <$> readTVarIO deliveredVar)
                deliveredFinal <- readTVarIO deliveredVar
                deliveredFinal `shouldBe` 1

    it "an idle consumer-group member does not spin while a different category advances the global position" $ do
        let subName = SubscriptionName "grp-sub"
        deliveredVar <- newTVarIO (0 :: Int)
        fetchVar <- newTVarIO (0 :: Int)
        liveBarrier <- newEmptyMVar
        let countFetch evt = case evt of
                KirokuEventSubscriptionFetched n _ _
                    | n == subName -> atomically (modifyTVar' fetchVar (+ 1))
                _ -> pure ()
            obsHandler = caughtUpEventHandler subName liveBarrier (Just countFetch)
        withTestStoreSettings (\s -> s & #eventHandler .~ Just obsHandler) $ \store -> do
            let deliver _evt = do
                    atomically (modifyTVar' deliveredVar (+ 1))
                    pure Continue
                -- Member 0 of 3 over category "grp" — which receives NO events, so
                -- this member's partition fetch is always empty. The flood lands in
                -- a different category, advancing only the global position.
                cfg =
                    (defaultSubscriptionConfig subName (Category (CategoryName "grp")) deliver)
                        { consumerGroup = Just ConsumerGroup{member = 0, size = 3}
                        }
            bracket (subscribe store cfg) cancel $ \_handle -> do
                waitForSubscriptionLive liveBarrier

                -- The corrected group loop gates BEFORE draining, so on an empty
                -- store it blocks with zero fetches until the global position moves.
                let floodCount = 20 :: Int
                    floodStreams = ["flood-" <> T.pack (show i) | i <- [1 .. floodCount]]
                appendEach store floodStreams "Flood"
                waitForPublisher store (GlobalPosition (fromIntegral floodCount))
                threadDelay 500_000

                afterIdle <- readTVarIO fetchVar
                deliveredIdle <- readTVarIO deliveredVar
                -- The corrected gate wakes at most once per observed global position
                -- (<= floodCount), bounded — NOT the unbounded busy-spin of the old
                -- cursor gate, which racks up thousands of empty fetches in 500ms.
                afterIdle `shouldSatisfy` (< 50)
                deliveredIdle `shouldBe` 0
