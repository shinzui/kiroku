module Test.StreamHead (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, replicateM_, void)
import Data.Aeson (Value (Null))
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import System.Timeout (timeout)
import Test.Helpers (makeEvent, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "stream head" $ do
    forM_ [False, True] $ \resource -> describe (if resource then "resource runner" else "direct runner") $ do
        let readHead store name =
                if resource
                    then runEff . runErrorNoCallStack @StoreError . runKirokuStoreWith store . runStoreResource $ getStreamWithHead name
                    else runStoreIO store (getStreamWithHead name)
            check store name version headPosition = do
                Right (Just metadata) <- runStoreIO store (getStream name)
                metadata ^. #version `shouldBe` StreamVersion version
                readHead store name `shouldReturn` Right (Just (metadata, headPosition))
        it "distinguishes absent, empty and reserved $all in empty and populated stores" $ withTestStore $ \store -> do
            readHead store (StreamName "missing") `shouldReturn` Right Nothing
            raw store "INSERT INTO streams(stream_name) VALUES ('empty')"
            check store (StreamName "empty") 0 Nothing
            check store (StreamName "$all") 0 Nothing
            appendOne store (StreamName "origin")
            check store (StreamName "$all") 1 Nothing
        it "captures interleaved heads, logical lifecycle and a fresh identity after hard deletion" $ withTestStore $ \store -> do
            let a = StreamName "a"; b = StreamName "b"
            mapM_ (appendOne store) [a, b, a, b]
            originated <- appendPosition store a
            originated `shouldBe` GlobalPosition 5
            check store a 3 (Just originated)
            appendOne store b
            check store a 3 (Just originated)
            Right (Just _) <- runStoreIO store (setStreamTruncateBefore a (StreamVersion 3))
            check store a 3 (Just originated)
            Right (Just _) <- runStoreIO store (softDeleteStream a)
            check store a 3 (Just originated)
            Right (Just (old, _)) <- readHead store a
            Right (Just _) <- runStoreIO store (hardDeleteStream a)
            readHead store a `shouldReturn` Right Nothing
            raw store "INSERT INTO streams(stream_name) VALUES ('a')"
            check store a 0 Nothing
            Right (Just (fresh, _)) <- readHead store a
            fresh ^. #id `shouldNotBe` (old ^. #id)
            recreated <- appendPosition store a
            recreated `shouldBe` GlobalPosition 7
            check store a 1 (Just recreated)
        it "ignores links while tracking subsequent originated appends" $ withTestStore $ \store -> do
            let mixed = StreamName "mixed"; source = StreamName "source"; linked = StreamName "linked"
            appendOne store mixed
            appendOne store source
            Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
            let eid = (events V.! 1) ^. #eventId
            Right _ <- runStoreIO store (linkToStream linked [eid])
            check store linked 1 Nothing
            Right _ <- runStoreIO store (linkToStream mixed [eid])
            check store mixed 2 (Just ((events V.! 0) ^. #globalPosition))
            next <- appendPosition store mixed
            next `shouldBe` GlobalPosition 3
            check store mixed 3 (Just next)
    it "never invokes the event decode hook" $ do
        calls <- newIORef (0 :: Int)
        let hook _ = modifyIORef' calls (+ 1) >> error "unexpected event decode"
        withTestStoreSettings (\settings -> settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}) $ \store -> do
            expected <- appendPosition store (StreamName "hook")
            Right (Just (_, actual)) <- runStoreIO store (getStreamWithHead (StreamName "hook"))
            actual `shouldBe` Just expected
            readIORef calls `shouldReturn` 0
    it "observes version and head from one snapshot while appends commit" $ withTestStore $ \store -> do
        let name = StreamName "concurrent"
        appendOne store name
        start <- newEmptyMVar
        let writer = takeMVar start >> replicateM_ 100 (appendOne store name)
            reader = replicateM_ 200 $ do
                Right (Just (info, Just (GlobalPosition position))) <- runStoreIO store (getStreamWithHead name)
                info ^. #version `shouldBe` StreamVersion position
        outcome <- timeout 20_000_000 $ Async.withAsync writer $ \worker -> do
            putMVar start ()
            reader
            Async.wait worker
        outcome `shouldBe` Just ()
        Right (Just (info, headPosition)) <- runStoreIO store (getStreamWithHead name)
        info ^. #version `shouldBe` StreamVersion 101
        headPosition `shouldBe` Just (GlobalPosition 101)

appendOne :: KirokuStore -> StreamName -> IO ()
appendOne store name = void (appendPosition store name)

appendPosition :: KirokuStore -> StreamName -> IO GlobalPosition
appendPosition store name = do
    result <- runStoreIO store (appendToStream name AnyVersion [makeEvent "StreamHeadEvent" Null])
    either (fail . show) (pure . (^. #globalPosition)) result

raw :: KirokuStore -> Text -> IO ()
raw store command = Pool.use (store ^. #pool) (Session.script command) >>= either (expectationFailure . show) pure
