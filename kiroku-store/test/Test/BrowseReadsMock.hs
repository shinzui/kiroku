module Test.BrowseReadsMock (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Read
import Kiroku.Store.Types
import Test.Hspec

spec :: Spec
spec = describe "browse reads mock" $ it "dispatches each public wrapper exactly once with its parameters" $ do
    calls <- newIORef ([] :: [String])
    let page = either (error . show) (\size -> size) (mkBrowsePageSize 7)
        runner = interpret_ $ \case
            ListStreams category prefix cursor size -> do
                liftIO $ (category, prefix, cursor, size) `shouldBe` (Just (CategoryName "orders"), Just "orders-", Just (StreamName "orders-1"), page)
                liftIO $ modifyIORef' calls (<> ["streams"])
                pure V.empty
            ListCategories cursor size -> do
                liftIO $ (cursor, size) `shouldBe` (Just (CategoryName "orders"), page)
                liftIO $ modifyIORef' calls (<> ["categories"])
                pure V.empty
            GetEvent eid -> do
                liftIO $ eid `shouldBe` EventId UUID.nil
                liftIO $ modifyIORef' calls (<> ["event"])
                pure Nothing
            _ -> error "unexpected browse mock operation"
    _ <- runEff $ runner $ do
        _ <- listStreams (Just (CategoryName "orders")) (Just "orders-") (Just (StreamName "orders-1")) page
        _ <- listCategories (Just (CategoryName "orders")) page
        getEvent (EventId UUID.nil)
    readIORef calls `shouldReturn` ["streams", "categories", "event"]
