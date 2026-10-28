module Test.CompactionPreviewMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store hiding (id)
import Test.Hspec

spec :: Spec
spec = describe "compaction preview mock" $
  it "dispatches the sealed manifest exactly once and returns the configured result" $ do
    calls <- newIORef (0 :: Int)
    let Right op = mkCompactionOperation "mock"
        identity = StoreIdentity UUID.nil
        heads = [StreamHeadWitness (StreamName "mock-1") (StreamVersion 1)]
        selection = CompactionSelection (EventId UUID.nil) (StreamName "mock-1") (StreamVersion 1) (GlobalPosition 1) V.empty
        Right m = mkCompactionManifest (CompactionManifestInput identity op RefuseDeadLetters RefuseCausationDependents heads [selection] Nothing)
        digest = compactionManifestDigest m
        report = sealCompactionReport (CompactionReport digest identity op RefuseDeadLetters RefuseCausationDependents 1 1 1 0 0 0 (GlobalPosition 1) (GlobalPosition 1) (V.fromList heads) digest)
        result = Right (CompactionPreviewReady report)
    actual <- runEff $ runPreviewMock calls m result (previewCompaction m)
    actual `shouldBe` result
    readIORef calls `shouldReturn` 1

runPreviewMock :: (IOE :> es) => IORef Int -> CompactionManifest -> Either (NonEmpty CompactionRefusal) CompactionPreview -> Eff (Store : es) a -> Eff es a
runPreviewMock calls expected result = interpret_ $ \case
  PreviewCompaction m -> do
    liftIO $ m `shouldBe` expected
    liftIO $ modifyIORef' calls (+ 1)
    pure result
  _ -> error "unexpected Store operation in preview mock"
