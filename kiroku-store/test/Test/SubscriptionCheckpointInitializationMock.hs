module Test.SubscriptionCheckpointInitializationMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Subscription (initializeSubscriptionCheckpoint)
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Spec
spec = describe "subscription checkpoint initialization mock interpreter" $ do
    it "carries the closed policy and typed result through one Store effect call" $ do
        calls <- newIORef (0 :: Int)
        let name = SubscriptionName "mock-initialization"
            key = SubscriptionCheckpointKey name 4
            expected = Right (InitializedCheckpoint FromCurrentHead key (GlobalPosition 23))
        actual <-
            runEff $
                runInitializationMock calls name 4 FromCurrentHead expected $
                    initializeSubscriptionCheckpoint name 4 FromCurrentHead
        actual `shouldBe` expected
        readIORef calls `shouldReturn` 1

runInitializationMock ::
    (IOE :> es) =>
    IORef Int ->
    SubscriptionName ->
    Int ->
    MissingCheckpointPolicy ->
    Either SubscriptionCheckpointMissing CheckpointInitialization ->
    Eff (Store : es) a ->
    Eff es a
runInitializationMock calls expectedName expectedMember expectedPolicy expected = interpret_ $ \case
    InitializeSubscriptionCheckpoint actualName actualMember actualPolicy -> do
        liftIO $ do
            actualName `shouldBe` expectedName
            fromIntegral actualMember `shouldBe` expectedMember
            actualPolicy `shouldBe` expectedPolicy
            modifyIORef' calls (+ 1)
        pure expected
    _ -> error "unexpected Store operation in checkpoint initialization mock"
