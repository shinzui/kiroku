{-# LANGUAGE OverloadedStrings #-}

module Test.StartupFailureSurfacing (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, fromException)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (replicateM_)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict qualified as Map
import Hasql.Pool qualified as Pool
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Store.Subscription.Worker (withLoadCheckpointHookForTest)
import Test.Helpers (waitWithTimeout, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "startup failure surfacing" $ do
    it "fails subscription startup loudly when checkpoint load fails" $ do
        handlerCalled <- newTVarIO False
        observedRef <- newIORef ([] :: [KirokuEvent])
        let subName = SubscriptionName "load-checkpoint-fails-loudly"
            cfg =
                defaultSubscriptionConfig subName AllStreams $ \_ -> do
                    atomically (writeTVar handlerCalled True)
                    pure Continue
            observe evt = modifyIORef' observedRef (evt :)
            injectLoadFailure _ = pure (Just (Left Pool.AcquisitionTimeoutUsageError))
            tweak settings = settings & #eventHandler .~ Just observe

        withTestStoreSettings tweak $ \store ->
            withLoadCheckpointHookForTest injectLoadFailure $ do
                handle <- subscribe store cfg
                result <- waitWithTimeout 5_000_000 handle
                case result of
                    Right (Left e)
                        | Just Pool.AcquisitionTimeoutUsageError <- fromException e -> pure ()
                    Left timeout -> expectationFailure timeout
                    Right other -> expectationFailure ("expected checkpoint load failure, got: " <> show other)

        wasCalled <- readTVarIO handlerCalled
        wasCalled `shouldBe` False
        observed <- reverse <$> readIORef observedRef
        any (isLoadCheckpointError subName) observed `shouldBe` True
        any (isCrashedStop subName) observed `shouldBe` True

    it "leaves no publisher or subscription registry entries after a subscribe/cancel storm" $
        withTestStore $ \store -> do
            let cfg = defaultSubscriptionConfig (SubscriptionName "subscribe-cancel-storm") AllStreams (\_ -> pure Continue)
            -- 200 iterations gives async exceptions many chances to land in the
            -- pre-fork window without making the test expensive on normal runs.
            replicateM_ 200 $ do
                pending <- Async.async (subscribe store cfg)
                Async.cancel pending
                outcome <- Async.waitCatch pending
                case outcome of
                    Right handle -> cancel handle >> (() <$ wait handle)
                    Left (_ :: SomeException) -> pure ()

            subs <- readTVarIO (Pub.subscribers (store ^. #publisher))
            reg <- readTVarIO (store ^. #subscriptionRegistry)
            IntMap.null subs `shouldBe` True
            Map.null reg `shouldBe` True

isLoadCheckpointError :: SubscriptionName -> KirokuEvent -> Bool
isLoadCheckpointError expected = \case
    KirokuEventSubscriptionDbError actual LoadCheckpoint Pool.AcquisitionTimeoutUsageError _
        | actual == expected -> True
    _ -> False

isCrashedStop :: SubscriptionName -> KirokuEvent -> Bool
isCrashedStop expected = \case
    KirokuEventSubscriptionStopped actual _ (StopWorkerCrashed e) _
        | actual == expected
        , Just Pool.AcquisitionTimeoutUsageError <- fromException e ->
            True
    _ -> False
