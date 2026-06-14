{- | Tests for 'Kiroku.Store.Read.lookupStreamNames' and 'lookupStreamName'
(plan 36). These resolve the surrogate 'RecordedEvent.originalStreamId' carried
by fan-in reads back to a human-readable 'StreamName', without every read having
to return the name (which a benchmark showed costs ~13% on @$all@ pages).
-}
module Test.StreamNameLookup (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, waitForPublisher, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "lookupStreamNames / lookupStreamName" $ do
    around withTestStore $ do
        it "resolves originalStreamId back to the source stream for $all reads" $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "orders-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "shipments-1") NoStream [makeEvent "ShipmentDispatched" (Aeson.object [])]
            Right evs <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            Right names <- runStoreIO store $ lookupStreamNames (map (^. #originalStreamId) (V.toList evs))
            let nameOf typ =
                    case V.find ((== EventType typ) . (^. #eventType)) evs of
                        Just e -> Map.lookup (e ^. #originalStreamId) names
                        Nothing -> Nothing
            nameOf "OrderCreated" `shouldBe` Just (StreamName "orders-1")
            nameOf "ShipmentDispatched" `shouldBe` Just (StreamName "shipments-1")

        it "omits ids that name no existing stream" $ \store -> do
            Right names <- runStoreIO store $ lookupStreamNames [StreamId 999999]
            Map.size names `shouldBe` 0

        it "returns an empty map for an empty id list" $ \store -> do
            Right names <- runStoreIO store $ lookupStreamNames []
            Map.null names `shouldBe` True

        it "lookupStreamName resolves a single id, and Nothing for an unknown one" $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "widgets-7") NoStream [makeEvent "WidgetMade" (Aeson.object [])]
            Right (Just sid) <- runStoreIO store $ lookupStreamId (StreamName "widgets-7")
            Right found <- runStoreIO store $ lookupStreamName sid
            found `shouldBe` Just (StreamName "widgets-7")
            Right missing <- runStoreIO store $ lookupStreamName (StreamId 888888)
            missing `shouldBe` Nothing

    it "short-circuits empty input without a pool checkout" $ do
        ref <- newIORef (0 :: Int)
        let handler (ConnectionObservation _ InUseConnectionStatus) =
                modifyIORef' ref (+ 1)
            handler _ =
                pure ()
        withTestStoreSettings (\settings -> settings{observationHandler = Just handler}) $ \store -> do
            Right appendResult <-
                runStoreIO store $
                    appendToStream (StreamName "lookup-count-1") NoStream [makeEvent "LookupCounted" (Aeson.object [])]
            waitForPublisher store (appendResult ^. #globalPosition)
            Right (Just sid) <- runStoreIO store $ lookupStreamId (StreamName "lookup-count-1")

            beforeEmpty <- readIORef ref
            Right emptyNames <- runStoreIO store $ lookupStreamNames []
            afterEmpty <- readIORef ref
            emptyNames `shouldBe` Map.empty
            afterEmpty - beforeEmpty `shouldBe` 0

            beforeReal <- readIORef ref
            Right names <- runStoreIO store $ lookupStreamNames [sid]
            afterReal <- readIORef ref
            names `shouldBe` Map.singleton sid (StreamName "lookup-count-1")
            afterReal - beforeReal `shouldBe` 1
