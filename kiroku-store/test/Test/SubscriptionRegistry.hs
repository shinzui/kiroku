{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Tests for the central subscription-state registry (ExecPlan 45 / EP-1 of
MasterPlan 7).

These prove the registry's observable behaviour against a real migrated
PostgreSQL database:

  * Several live subscriptions (including consumer-group members) appear in the
    'Kiroku.Store.Subscription.subscriptionStates' snapshot with sensible state
    labels, matching keys, and a valid FSM cursor, and a live handle's
    'currentState' agrees with its snapshot entry (the single-source-of-truth
    reshape).
  * A subscription's key disappears from the snapshot when it stops cleanly, is
    cancelled, or crashes — and its held handle's 'currentState' then returns
    'Nothing'.
  * A stale duplicate-key worker's cleanup cannot delete a newer worker's
    replacement entry (the per-worker token defends the active entry).
-}
module Test.SubscriptionRegistry (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Kiroku.Store
import Kiroku.Store.Subscription.Types (SubscriptionConfigM (..))
import Test.Helpers (makeEvent, waitForPublisher, withTestStore)
import Test.Hspec

-- | A plain @$all@ subscription config whose handler never stops.
plainCont :: Text -> SubscriptionConfig
plainCont nm = defaultSubscriptionConfig (SubscriptionName nm) AllStreams (\_ -> pure Continue)

-- | A size-@n@ category-group config for member @m@ whose handler never stops.
groupCont :: Text -> Text -> Int32 -> Int32 -> SubscriptionConfig
groupCont nm cat m n =
    (defaultSubscriptionConfig (SubscriptionName nm) (Category (CategoryName cat)) (\_ -> pure Continue))
        { consumerGroup = Just (ConsumerGroup{member = m, size = n})
        }

-- | Poll the snapshot until the keyed entry reaches the given 'statePhase' label.
waitUntilPhase :: Int -> KirokuStore -> (SubscriptionName, Int32) -> Text -> IO Bool
waitUntilPhase budget store key phase
    | budget <= 0 = pure False
    | otherwise = do
        m <- subscriptionStates store
        case Map.lookup key m of
            Just v | (v ^. #statePhase) == phase -> pure True
            _ -> threadDelay 20_000 >> waitUntilPhase (budget - 20_000) store key phase

-- | Poll the snapshot until the keyed entry is present.
waitUntilPresent :: Int -> KirokuStore -> (SubscriptionName, Int32) -> IO Bool
waitUntilPresent budget store key
    | budget <= 0 = pure False
    | otherwise = do
        m <- subscriptionStates store
        if Map.member key m
            then pure True
            else threadDelay 20_000 >> waitUntilPresent (budget - 20_000) store key

-- | Poll the snapshot until the keyed entry is absent.
waitUntilAbsent :: Int -> KirokuStore -> (SubscriptionName, Int32) -> IO Bool
waitUntilAbsent budget store key
    | budget <= 0 = pure False
    | otherwise = do
        m <- subscriptionStates store
        if Map.member key m
            then threadDelay 20_000 >> waitUntilAbsent (budget - 20_000) store key
            else pure True

spec :: Spec
spec = describe "subscription registry (EP-1 / plan 45)" $ do
    it "registers every live subscription with a sensible state and position" $
        withTestStore $ \store -> do
            let plainName = SubscriptionName "reg-plain"
                groupName = SubscriptionName "reg-group"
            Right _ <- runStoreIO store $ appendToStream (StreamName "reg-1") NoStream [makeEvent "A" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "reg-2") NoStream [makeEvent "B" (Aeson.object [])]
            waitForPublisher store (GlobalPosition 2)
            hPlain <- subscribe store (plainCont "reg-plain")
            hG0 <- subscribe store (groupCont "reg-group" "reg" 0 2)
            hG1 <- subscribe store (groupCont "reg-group" "reg" 1 2)
            okP <- waitUntilPhase 5_000_000 store (plainName, 0) "live"
            ok0 <- waitUntilPhase 5_000_000 store (groupName, 0) "live"
            ok1 <- waitUntilPhase 5_000_000 store (groupName, 1) "live"
            (okP, ok0, ok1) `shouldBe` (True, True, True)
            snap <- subscriptionStates store
            Map.keys snap `shouldMatchList` [(plainName, 0), (groupName, 0), (groupName, 1)]
            for_ (Map.toList snap) $ \((nm, mbr), v) -> do
                (v ^. #subscriptionName) `shouldBe` nm
                (v ^. #member) `shouldBe` mbr
                (v ^. #statePhase) `shouldSatisfy` (`elem` (["catching_up", "live"] :: [Text]))
                let GlobalPosition p = v ^. #cursor
                p `shouldSatisfy` (>= 0)
            -- currentState on a live handle agrees with its snapshot entry.
            Just s <- currentState hPlain
            case Map.lookup (plainName, 0) snap of
                Just v -> stateName s `shouldBe` (v ^. #statePhase)
                Nothing -> expectationFailure "plain subscription missing from snapshot"
            mapM_ cancel [hPlain, hG0, hG1]

    it "removes a subscription's entry when it stops cleanly" $
        withTestStore $ \store -> do
            let nm = SubscriptionName "reg-stop"
            Right _ <- runStoreIO store $ appendToStream (StreamName "stop-1") NoStream [makeEvent "A" (Aeson.object [])]
            waitForPublisher store (GlobalPosition 1)
            handle <- subscribe store (defaultSubscriptionConfig nm AllStreams (\_ -> pure Stop))
            _ <- wait handle
            gone <- waitUntilAbsent 5_000_000 store (nm, 0)
            gone `shouldBe` True
            cs <- currentState handle
            cs `shouldSatisfy` isNothing

    it "removes a subscription's entry when it is cancelled" $
        withTestStore $ \store -> do
            let nm = SubscriptionName "reg-cancel"
            Right _ <- runStoreIO store $ appendToStream (StreamName "cancel-1") NoStream [makeEvent "A" (Aeson.object [])]
            waitForPublisher store (GlobalPosition 1)
            handle <- subscribe store (plainCont "reg-cancel")
            live <- waitUntilPhase 5_000_000 store (nm, 0) "live"
            live `shouldBe` True
            cancel handle
            _ <- wait handle
            gone <- waitUntilAbsent 5_000_000 store (nm, 0)
            gone `shouldBe` True
            cs <- currentState handle
            cs `shouldSatisfy` isNothing

    it "removes a subscription's entry when its handler crashes" $
        withTestStore $ \store -> do
            let nm = SubscriptionName "reg-crash"
            Right _ <- runStoreIO store $ appendToStream (StreamName "crash-1") NoStream [makeEvent "A" (Aeson.object [])]
            waitForPublisher store (GlobalPosition 1)
            handle <- subscribe store (defaultSubscriptionConfig nm AllStreams (\_ -> throwIO (userError "boom")))
            res <- wait handle
            case res of
                Left _ -> pure ()
                Right () -> expectationFailure "expected the crashing handler to fail the worker"
            gone <- waitUntilAbsent 5_000_000 store (nm, 0)
            gone `shouldBe` True
            cs <- currentState handle
            cs `shouldSatisfy` isNothing

    it "stale duplicate-key cleanup does not remove the replacement entry" $
        withTestStore $ \store -> do
            let nm = SubscriptionName "reg-dup"
            h1 <- subscribe store (plainCont "reg-dup")
            present1 <- waitUntilPresent 5_000_000 store (nm, 0)
            present1 `shouldBe` True
            -- A second subscribe with the same (name, member) supersedes h1's
            -- entry in the registry (insert is synchronous, before the fork).
            h2 <- subscribe store (plainCont "reg-dup")
            -- Stopping the first worker must not delete the second's live entry.
            cancel h1
            _ <- wait h1
            snap <- subscriptionStates store
            Map.member (nm, 0) snap `shouldBe` True
            cs1 <- currentState h1
            cs1 `shouldSatisfy` isNothing
            cs2 <- currentState h2
            cs2 `shouldSatisfy` isJust
            cancel h2
