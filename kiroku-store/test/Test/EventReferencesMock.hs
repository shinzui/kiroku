module Test.EventReferencesMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Read (lookupEventReferences)
import Kiroku.Store.Types
import Test.Hspec

spec :: Spec
spec = describe "event references mock" $
  it "returns the configured identity through one Store effect call" $ do
    calls <- newIORef (0 :: Int)
    let expected = Map.singleton (EventId UUID.nil) (EventReferenceInventory mempty 2 3)
    actual <- runEff $ runIdentityMock calls expected (lookupEventReferences [EventId UUID.nil])
    actual `shouldBe` expected
    readIORef calls `shouldReturn` 1

runIdentityMock ::
  (IOE :> es) =>
  IORef Int ->
  Map EventId EventReferenceInventory ->
  Eff (Store : es) a ->
  Eff es a
runIdentityMock calls expected = interpret_ $ \case
  LookupEventReferences ids -> do
    liftIO $ ids `shouldBe` [EventId UUID.nil]
    liftIO $ modifyIORef' calls (+ 1)
    pure expected
  _ -> error "unexpected Store operation in identity mock"
