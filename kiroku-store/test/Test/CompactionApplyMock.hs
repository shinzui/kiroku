module Test.CompactionApplyMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store hiding (id)
import Test.CompactionHelpers (ledgerQuery)
import Test.Hspec

spec :: Spec
spec = describe "compaction apply mock" $
  it "dispatches apply and ledger once each with their original arguments" $ do
    calls <- newIORef []
    let Right op = mkCompactionOperation "mock"
        identity = StoreIdentity UUID.nil
        heads = [StreamHeadWitness (StreamName "mock-1") (StreamVersion 1)]
        selection = CompactionSelection (EventId UUID.nil) (StreamName "mock-1") (StreamVersion 1) (GlobalPosition 1) V.empty
        Right m = mkCompactionManifest (CompactionManifestInput identity op RefuseDeadLetters RefuseCausationDependents heads [selection] Nothing)
        digest = compactionManifestDigest m
        report = sealCompactionReport (CompactionReport digest identity op RefuseDeadLetters RefuseCausationDependents 1 1 1 0 0 0 (GlobalPosition 1) (GlobalPosition 1) (V.fromList heads) digest)
        record = CompactionRecord (CompactionId UUID.nil) report (UTCTime (fromGregorian 2026 10 27) 0) "mock"
        query = ledgerQuery 10
    actual <- runEff $ runApplyMock calls m query record $ (,) <$> applyCompaction m <*> compactionLedger query
    actual `shouldBe` (Right (CompactionAppliedNow record), V.singleton record)
    readIORef calls `shouldReturn` ["ledger", "apply"]

runApplyMock :: (IOE :> es) => IORef [String] -> CompactionManifest -> CompactionLedgerQuery -> CompactionRecord -> Eff (Store : es) a -> Eff es a
runApplyMock calls expected query record = interpret_ $ \case
  ApplyCompaction m -> do
    liftIO $ m `shouldBe` expected
    liftIO $ modifyIORef' calls ("apply" :)
    pure (Right (CompactionAppliedNow record))
  GetCompactionLedger got -> do
    liftIO $ got `shouldBe` query
    liftIO $ modifyIORef' calls ("ledger" :)
    pure (V.singleton record)
  _ -> error "unexpected Store operation in compaction apply mock"
