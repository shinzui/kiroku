module Test.BrowseReads (spec) where

import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, void)
import Data.Aeson qualified as Aeson
import Data.Char (chr)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore, withTestStoreSettings)
import Test.Hspec

page :: Int -> BrowsePageSize
page n = either (error . show) (\p -> p) (mkBrowsePageSize n)

names :: V.Vector StreamInfo -> [Text]
names = map (\s -> let StreamName n = s ^. #name in n) . V.toList

seed :: KirokuStore -> [Text] -> IO ()
seed store = mapM_ $ \name -> do
    result <- runStoreIO store $ appendToStream (StreamName name) NoStream [makeEvent "Created" (Aeson.object [])]
    result `shouldSatisfy` either (const False) (const True)

spec :: Spec
spec = describe "browse reads" $ do
    it "validates bounded page sizes" $ do
        forM_ [minBound, -1, 0, 1002, maxBound] $ \n -> mkBrowsePageSize n `shouldBe` Left (InvalidBrowsePageSize n)
        forM_ [1, 1000, 1001] $ \n -> fmap browsePageSizeValue (mkBrowsePageSize n) `shouldBe` Right (fromIntegral n)
    around withTestStore $ do
        it "excludes only the reserved all row and pages in UTF-8 byte order" $ \store -> do
            runStoreIO store (listStreams Nothing Nothing Nothing (page 10)) `shouldReturn` Right V.empty
            let values = ["orders-2", "orders", "orders-1", "$all-x", "singleton", "é-1", "Z-1", "-empty-category"]
            seed store values
            Right first <- runStoreIO store $ listStreams Nothing Nothing Nothing (page 3)
            names first `shouldBe` take 3 (sort values)
            Right rest <- runStoreIO store $ listStreams Nothing Nothing (Just (StreamName (last (names first)))) (page 100)
            names first <> names rest `shouldBe` sort values
            runStoreIO store (listStreams Nothing Nothing (Just (StreamName (last (sort values)))) (page 10)) `shouldReturn` Right V.empty
        it "intersects exact categories, literal prefixes and exclusive cursors" $ \store -> do
            let maxScalar = T.singleton (chr 0x10ffff)
                values = ["orders", "orders-1", "orders-2", "orders:other-1", "orders_-1", "orders%-1", "$all-x", "-a", "é-a", "é-a", maxScalar, maxScalar <> "-a", "\xD7FF-a", "\xE000-a"]
            seed store values
            forM_ [Nothing, Just (CategoryName "orders"), Just (CategoryName ""), Just (CategoryName "$all"), Just (CategoryName "not-a-category"), Just (CategoryName maxScalar)] $ \category ->
                forM_ [Nothing, Just "", Just "orders", Just "orders-", Just "orders%", Just "orders_", Just "absent", Just "é", Just maxScalar, Just "\xD7FF"] $ \prefix ->
                    forM_ [Nothing, Just (StreamName "orders"), Just (StreamName "orders-1"), Just (StreamName "zzz")] $ \cursor -> do
                        let expected = sort [v | v <- values, maybe True (== categoryName (StreamName v)) category, maybe True (`T.isPrefixOf` v) prefix, maybe True (\(StreamName c) -> v > c) cursor]
                        Right actual <- runStoreIO store $ listStreams category prefix cursor (page 100)
                        names actual `shouldBe` expected
        it "enumerates distinct categories including bare and empty categories" $ \store -> do
            seed store ["orders", "orders-1", "orders-2", "$all-x", "-a", "singleton"]
            Right first <- runStoreIO store $ listCategories Nothing (page 2)
            V.toList first `shouldBe` [CategoryName "", CategoryName "$all"]
            Right rest <- runStoreIO store $ listCategories (Just (V.last first)) (page 10)
            V.toList rest `shouldBe` [CategoryName "orders", CategoryName "singleton"]
        it "keeps soft-deleted summaries and removes hard-deleted summaries" $ \store -> do
            seed store ["orders-soft", "orders-hard"]
            void $ runStoreIO store $ softDeleteStream (StreamName "orders-soft")
            void $ runStoreIO store $ setStreamTruncateBefore (StreamName "orders-soft") (StreamVersion 1)
            void $ runStoreIO store $ hardDeleteStream (StreamName "orders-hard")
            Right rows <- runStoreIO store $ listStreams Nothing Nothing Nothing (page 10)
            names rows `shouldBe` ["orders-soft"]
            (V.head rows ^. #deletedAt) `shouldSatisfy` maybe False (const True)
        it "returns the canonical global row once even when linked, then nothing after hard deletion" $ \store -> do
            seed store ["orders-1"]
            Right events <- runStoreIO store $ readAllForward (GlobalPosition 0) 10
            let event = V.head events
            Right _ <- runStoreIO store $ linkToStream (StreamName "links-1") [event ^. #eventId]
            runStoreIO store (getEvent (event ^. #eventId)) `shouldReturn` Right (Just event)
            runStoreIO store (getEvent (EventId UUID.nil)) `shouldReturn` Right Nothing
            Right _ <- runStoreIO store $ hardDeleteStream (StreamName "orders-1")
            runStoreIO store (getEvent (event ^. #eventId)) `shouldReturn` Right Nothing
    it "applies the configured decode hook to event lookup" $ do
        let marker = Aeson.object ["decoded" Aeson..= True]
            hook event = pure (Right (event & #metadata .~ Just marker))
        withTestStoreSettings (\settings -> settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}) $ \store -> do
            seed store ["orders-1"]
            Right events <- runStoreIO store $ readAllForward (GlobalPosition 0) 10
            Right (Just event) <- runStoreIO store $ getEvent (V.head events ^. #eventId)
            (event ^. #metadata) `shouldBe` Just marker

    it "propagates typed decode failure from event lookup" $ do
        let hook event = pure (Left (DecodeFailure (event ^. #eventId) "failure"))
        withTestStoreSettings (\settings -> settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}) $ \store -> do
            seed store ["orders-1"]
            Right rows <- runStoreIO store $ readStreamForward (StreamName "missing") (StreamVersion 0) 1
            rows `shouldBe` V.empty
            -- Use the append-provided id to avoid decoding a fixture through the failing hook.
            let event = makeEvent "Created" (Aeson.object []) & #eventId .~ Just (EventId UUID.nil)
            Right _ <- runStoreIO store $ appendToStream (StreamName "orders-2") NoStream [event]
            runStoreIO store (getEvent (EventId UUID.nil)) `shouldReturn` Left (EventDecodeFailed (DecodeFailure (EventId UUID.nil) "failure"))
