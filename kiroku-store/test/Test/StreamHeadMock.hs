module Test.StreamHeadMock (spec) where

import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Time.Clock (getCurrentTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store
import Test.Hspec

spec :: Spec
spec = describe "stream head mock" $ it "sends exactly one dedicated constructor and preserves all nested-Maybe outcomes" $ do
    now <- getCurrentTime
    let name = StreamName "mock"
        info = StreamInfo (StreamId 42) name (StreamVersion 3) now Nothing (StreamVersion 0)
    forM_ [Nothing, Just (info, Nothing), Just (info, Just (GlobalPosition 5))] $ \expected -> do
        calls <- newIORef (0 :: Int)
        actual <- runEff $ runMock calls name expected (getStreamWithHead name)
        actual `shouldBe` expected
        readIORef calls `shouldReturn` 1

runMock :: (IOE :> es) => IORef Int -> StreamName -> Maybe (StreamInfo, Maybe GlobalPosition) -> Eff (Store : es) a -> Eff es a
runMock calls name expected = interpret_ $ \case
    GetStreamWithHead actual -> do
        liftIO $ actual `shouldBe` name
        liftIO $ modifyIORef' calls (+ 1)
        pure expected
    _ -> error "unexpected Store operation in stream-head mock"
