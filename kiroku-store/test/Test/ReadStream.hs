{- | Tests for "Kiroku.Store.Read".'readStreamForwardStream' — the
Streamly-shaped sibling of 'readStreamForward'. The streaming wrapper
must yield the same events in the same order as the @Vector@-returning
form, page transparently across the configured @pageSize@, terminate on
empty / nonexistent streams, and honor a non-zero starting cursor.
-}
module Test.ReadStream (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Vector qualified as V
import Kiroku.Store
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = around withTestStore $
    describe "readStreamForwardStream" $ do
        it "matches readStreamForward on a single-page stream" $ \store -> do
            let name = StreamName "rsfs-single-page"
                events = [makeEvent (T.pack ("E" <> show i)) (Aeson.object []) | i <- [1 .. 5 :: Int]]
            Right _ <- runStoreIO store $ appendToStream name NoStream events
            streamed <- runStoreIO store $ Stream.toList (readStreamForwardStream name (StreamVersion 0) 256)
            vectored <- runStoreIO store $ readStreamForward name (StreamVersion 0) 256
            case (streamed, vectored) of
                (Right xs, Right v) -> xs `shouldBe` V.toList v
                _ -> expectationFailure ("Unexpected error: " <> show streamed <> " / " <> show vectored)

        it "folds 1000 events end-to-end with Fold.length across multiple pages" $ \store -> do
            let name = StreamName "rsfs-multi-page"
                total = 1000 :: Int
                events = [makeEvent (T.pack ("E" <> show i)) (Aeson.object []) | i <- [1 .. total]]
            Right _ <- runStoreIO store $ appendToStream name NoStream events
            countResult <-
                runStoreIO store $
                    Stream.fold Fold.length (readStreamForwardStream name (StreamVersion 0) 256)
            countResult `shouldBe` Right total
            allEvents <-
                runStoreIO store $
                    Stream.toList (readStreamForwardStream name (StreamVersion 0) 256)
            case allEvents of
                Right xs -> case NE.nonEmpty xs of
                    Just ne -> do
                        let h = NE.head ne
                            l = NE.last ne
                        (h ^. #streamVersion) `shouldBe` StreamVersion 1
                        (h ^. #eventType) `shouldBe` EventType (T.pack "E1")
                        (l ^. #streamVersion) `shouldBe` StreamVersion (fromIntegral total)
                        (l ^. #eventType) `shouldBe` EventType (T.pack ("E" <> show total))
                    Nothing -> expectationFailure "Expected non-empty events list"
                Left err -> expectationFailure ("Unexpected error: " <> show err)

        it "preserves order and avoids duplicates / gaps when paging at pageSize 2" $ \store -> do
            let name = StreamName "rsfs-page-boundary"
                events = [makeEvent (T.pack ("E" <> show i)) (Aeson.object []) | i <- [1 .. 5 :: Int]]
            Right _ <- runStoreIO store $ appendToStream name NoStream events
            versions <-
                runStoreIO store $
                    Stream.toList $
                        fmap (^. #streamVersion) (readStreamForwardStream name (StreamVersion 0) 2)
            versions
                `shouldBe` Right
                    [ StreamVersion 1
                    , StreamVersion 2
                    , StreamVersion 3
                    , StreamVersion 4
                    , StreamVersion 5
                    ]

        it "terminates immediately on a nonexistent stream" $ \store -> do
            let name = StreamName "rsfs-never-created"
            result <-
                runStoreIO store $
                    Stream.toList (readStreamForwardStream name (StreamVersion 0) 256)
            result `shouldBe` Right []

        it "honors a non-zero starting cursor with exclusivity" $ \store -> do
            let name = StreamName "rsfs-non-zero-cursor"
                events = [makeEvent (T.pack ("E" <> show i)) (Aeson.object []) | i <- [1 .. 5 :: Int]]
            Right _ <- runStoreIO store $ appendToStream name NoStream events
            tailEvents <-
                runStoreIO store $
                    Stream.toList (readStreamForwardStream name (StreamVersion 2) 256)
            case tailEvents of
                Right xs -> do
                    length xs `shouldBe` 3
                    map (^. #streamVersion) xs
                        `shouldBe` [StreamVersion 3, StreamVersion 4, StreamVersion 5]
                Left err -> expectationFailure ("Unexpected error: " <> show err)
