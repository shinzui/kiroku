module Test.VisibleGlobalHeadPositionMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Read (visibleGlobalHeadPosition)
import Kiroku.Store.Types (GlobalPosition (..))
import Test.Hspec

spec :: Spec
spec = describe "visible global head position mock" $
    it "returns the configured position through one Store effect call" $ do
        calls <- newIORef (0 :: Int)
        let expected = GlobalPosition 23
        actual <- runEff $ runVisibleHeadMock calls expected visibleGlobalHeadPosition
        actual `shouldBe` expected
        readIORef calls `shouldReturn` 1

runVisibleHeadMock ::
    (IOE :> es) =>
    IORef Int ->
    GlobalPosition ->
    Eff (Store : es) a ->
    Eff es a
runVisibleHeadMock calls expected = interpret_ $ \case
    GetVisibleGlobalHeadPosition -> do
        liftIO $ modifyIORef' calls (+ 1)
        pure expected
    _ -> error "unexpected Store operation in visible-head mock"
