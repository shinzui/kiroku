module Test.StoreIdentityMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Read (storeIdentity)
import Kiroku.Store.Types (StoreIdentity (..))
import Test.Hspec

spec :: Spec
spec = describe "store identity mock" $
  it "returns the configured identity through one Store effect call" $ do
    calls <- newIORef (0 :: Int)
    let expected = StoreIdentity UUID.nil
    actual <- runEff $ runIdentityMock calls expected storeIdentity
    actual `shouldBe` expected
    readIORef calls `shouldReturn` 1

runIdentityMock ::
  (IOE :> es) =>
  IORef Int ->
  StoreIdentity ->
  Eff (Store : es) a ->
  Eff es a
runIdentityMock calls expected = interpret_ $ \case
  GetStoreIdentity -> do
    liftIO $ modifyIORef' calls (+ 1)
    pure expected
  _ -> error "unexpected Store operation in identity mock"
