{-# LANGUAGE TypeApplications #-}

module Test.VisibleGlobalHeadPosition (spec) where

import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "visible global head position" $ do
    it "returns zero for an empty migrated store through both public runners" $
        withTestStore $ \store -> do
            runStoreIO store visibleGlobalHeadPosition
                `shouldReturn` Right (GlobalPosition 0)

            resourceResult <-
                runEff
                    . runErrorNoCallStack @StoreError
                    . runKirokuStoreWith store
                    . runStoreResource
                    $ visibleGlobalHeadPosition
            resourceResult `shouldBe` Right (GlobalPosition 0)

    it "returns the greatest appended position" $
        withTestStore $ \store -> do
            appendEvents store (StreamName "visible-head-populated") 3
            runStoreIO store visibleGlobalHeadPosition
                `shouldReturn` Right (GlobalPosition 3)

    it "falls back across hard-deleted tails while the append frontier stays monotonic" $
        withTestStore $ \store -> do
            let first = StreamName "visible-head-first"
                middle = StreamName "visible-head-middle"
                lastStream = StreamName "visible-head-last"
            appendEvents store first 1
            appendEvents store middle 1
            appendEvents store lastStream 1

            Right (Just _) <- runStoreIO store $ hardDeleteStream middle
            assertHeadAndFrontier store 3 3

            Right (Just _) <- runStoreIO store $ hardDeleteStream lastStream
            assertHeadAndFrontier store 1 3

            Right (Just _) <- runStoreIO store $ hardDeleteStream first
            assertHeadAndFrontier store 0 3

    it "keeps logically truncated and soft-deleted events visible in $all" $
        withTestStore $ \store -> do
            let name = StreamName "visible-head-logical-lifecycle"
            appendEvents store name 3

            Right (Just _) <-
                runStoreIO store $
                    setStreamTruncateBefore name (StreamVersion 3)
            runStoreIO store visibleGlobalHeadPosition
                `shouldReturn` Right (GlobalPosition 3)

            Right (Just _) <- runStoreIO store $ softDeleteStream name
            runStoreIO store visibleGlobalHeadPosition
                `shouldReturn` Right (GlobalPosition 3)

    it "does not invoke the event decode hook" $ do
        decodeCalls <- newIORef (0 :: Int)
        let failingHook event = do
                modifyIORef' decodeCalls (+ 1)
                ioError (userError ("unexpected decode of " <> show (event ^. #eventId)))
            tweak settings =
                settings
                    & #storeSettings
                        .~ defaultStoreSettings{decodeHook = Just failingHook}
        withTestStoreSettings tweak $ \store -> do
            appendEvents store (StreamName "visible-head-no-decode") 1

            runStoreIO store visibleGlobalHeadPosition
                `shouldReturn` Right (GlobalPosition 1)
            readIORef decodeCalls `shouldReturn` 0

appendEvents :: KirokuStore -> StreamName -> Int -> IO ()
appendEvents store name count = do
    let events =
            [ makeEvent "VisibleHeadEvent" (Aeson.object [("ordinal", Aeson.Number (fromIntegral ordinal))])
            | ordinal <- [1 .. count]
            ]
    result <- runStoreIO store $ appendToStream name NoStream events
    case result of
        Left err -> expectationFailure ("append failed: " <> show err)
        Right _ -> pure ()

assertHeadAndFrontier :: KirokuStore -> Integer -> Integer -> IO ()
assertHeadAndFrontier store expectedHead expectedFrontier = do
    runStoreIO store visibleGlobalHeadPosition
        `shouldReturn` Right (GlobalPosition (fromIntegral expectedHead))
    result <- runStoreIO store subscriptionCheckpointInventory
    case result of
        Left err -> expectationFailure ("inventory read failed: " <> show err)
        Right inventory ->
            inventory ^. #storePosition
                `shouldBe` GlobalPosition (fromIntegral expectedFrontier)
