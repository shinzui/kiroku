module Test.HistoryRetentionMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.HistoryRetention
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Spec
spec = describe "history retention mock" $ do
    it "dispatches every closed lease operation exactly once" $ do
        calls <- newIORef ([] :: [Text])
        actual <- runEff $ runMock calls $ do
            acquired <- acquireHistoryRetentionLease sampleRequest
            renewed <- renewHistoryRetentionLease sampleHandle sampleDuration
            released <- releaseHistoryRetentionLease sampleHandle
            inventory <- historyRetentionLeaseInventory sampleQuery
            pruned <- pruneHistoryRetentionLeases sampleTime
            pure (acquired, renewed, released, inventory, pruned)
        actual
            `shouldBe` ( sampleLease
                       , Right sampleLease
                       , HistoryRetentionReleased sampleLease
                       , Vector.singleton sampleLease
                       , HistoryRetentionPruneResult 2 3
                       )
        readIORef calls
            `shouldReturn` ["acquire", "renew", "release", "inventory", "prune"]

runMock :: (IOE :> es) => IORef [Text] -> Eff (Store : es) a -> Eff es a
runMock calls = interpret_ $ \case
    AcquireHistoryRetentionLease request -> do
        liftIO $ request `shouldBe` sampleRequest
        record calls "acquire"
        pure sampleLease
    RenewHistoryRetentionLease handle duration -> do
        liftIO $ (handle, duration) `shouldBe` (sampleHandle, sampleDuration)
        record calls "renew"
        pure (Right sampleLease)
    ReleaseHistoryRetentionLease handle -> do
        liftIO $ handle `shouldBe` sampleHandle
        record calls "release"
        pure (HistoryRetentionReleased sampleLease)
    GetHistoryRetentionLeaseInventory query -> do
        liftIO $ query `shouldBe` sampleQuery
        record calls "inventory"
        pure (Vector.singleton sampleLease)
    PruneHistoryRetentionLeases cutoff -> do
        liftIO $ cutoff `shouldBe` sampleTime
        record calls "prune"
        pure (HistoryRetentionPruneResult 2 3)
    _ -> error "unexpected Store operation in history retention mock"

record :: (IOE :> es) => IORef [Text] -> Text -> Eff es ()
record calls name = liftIO $ modifyIORef' calls (<> [name])

sampleRequest :: HistoryRetentionLeaseRequest
sampleRequest =
    HistoryRetentionLeaseRequest sampleOwner sampleReason sampleDuration

sampleHandle :: HistoryRetentionLeaseHandle
sampleHandle = HistoryRetentionLeaseHandle sampleId sampleOwner

sampleLease :: HistoryRetentionLease
sampleLease =
    HistoryRetentionLease
        sampleId
        sampleOwner
        sampleReason
        (GlobalPosition 17)
        sampleTime
        sampleTime
        sampleExpiry
        Nothing
        HistoryRetentionLeaseActive

sampleId :: HistoryRetentionLeaseId
sampleId = HistoryRetentionLeaseId UUID.nil

sampleOwner :: HistoryRetentionLeaseOwner
sampleOwner = either (error . show) (\value -> value) (mkHistoryRetentionLeaseOwner "mock-owner")

sampleReason :: HistoryRetentionLeaseReason
sampleReason = either (error . show) (\value -> value) (mkHistoryRetentionLeaseReason "mock-reason")

sampleDuration :: HistoryRetentionLeaseDuration
sampleDuration = either (error . show) (\value -> value) (mkHistoryRetentionLeaseDuration (secondsToDiffTime 60))

sampleQuery :: HistoryRetentionInventoryQuery
sampleQuery =
    HistoryRetentionInventoryQuery $
        either (error . show) (\value -> value) (mkHistoryRetentionInventoryLimit 10)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 8 13) 0

sampleExpiry :: UTCTime
sampleExpiry = UTCTime (fromGregorian 2026 8 13) (secondsToDiffTime 60)
