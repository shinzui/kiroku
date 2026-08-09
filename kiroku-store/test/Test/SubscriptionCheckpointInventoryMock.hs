module Test.SubscriptionCheckpointInventoryMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Subscription (subscriptionCheckpointInventory)
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Spec
spec = describe "SubscriptionCheckpointInventory mock interpreter" $ do
    it "returns a public inventory through one Store effect call" $ do
        calls <- newIORef (0 :: Int)
        let updatedAt = UTCTime (fromGregorian 2026 8 9) 0
            expected =
                SubscriptionCheckpointInventory
                    (GlobalPosition 17)
                    ( V.singleton $
                        SubscriptionCheckpoint
                            (SubscriptionName "mock")
                            3
                            (GlobalPosition 11)
                            updatedAt
                    )
        actual <- runEff $ runInventoryMock calls expected subscriptionCheckpointInventory
        actual `shouldBe` expected
        readIORef calls `shouldReturn` 1

runInventoryMock ::
    (IOE :> es) =>
    IORef Int ->
    SubscriptionCheckpointInventory ->
    Eff (Store : es) a ->
    Eff es a
runInventoryMock calls expected = interpret_ $ \case
    GetSubscriptionCheckpointInventory -> do
        liftIO $ modifyIORef' calls (+ 1)
        pure expected
    _ -> error "unexpected Store operation in inventory mock"
