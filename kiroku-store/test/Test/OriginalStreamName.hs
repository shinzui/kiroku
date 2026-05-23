{- | Tests for the 'originalStreamName' field on 'RecordedEvent' (added in
@docs\/plans\/36-add-originalstreamname-to-recordedevent.md@). The field must
report the stream an event was first appended to across /fan-in/ reads — reads
that mix events from many streams — namely the global @$all@ stream and
category reads. For an event read back from a /linked/ stream it must report
the /source/ stream the event was first appended to, not the link target,
matching the existing 'originalStreamId' / 'originalVersion' semantics.
-}
module Test.OriginalStreamName (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Vector (Vector)
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

-- | The @originalStreamName@ of the first event of the given type, if present.
originForType :: Vector RecordedEvent -> EventType -> Maybe StreamName
originForType evs typ =
    fmap (^. #originalStreamName) (V.find ((== typ) . (^. #eventType)) evs)

spec :: Spec
spec = around withTestStore $
    describe "RecordedEvent.originalStreamName" $ do
        it "reports the originating stream for $all reads" $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "orders-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "shipments-1") NoStream [makeEvent "ShipmentDispatched" (Aeson.object [])]
            Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
            originForType allEvents (EventType "OrderCreated") `shouldBe` Just (StreamName "orders-1")
            originForType allEvents (EventType "ShipmentDispatched") `shouldBe` Just (StreamName "shipments-1")

        it "reports the originating stream for category reads" $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "orders-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "shipments-1") NoStream [makeEvent "ShipmentDispatched" (Aeson.object [])]
            Right catEvents <- runStoreIO store $ readCategory (CategoryName "orders") (GlobalPosition 0) 100
            map (^. #originalStreamName) (V.toList catEvents) `shouldBe` [StreamName "orders-1"]

        it "reports the source stream (not the target) for linked events" $ \store -> do
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "orders-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
            -- appendToStream returns AppendResult (no event id), so read the event
            -- back from its source stream to learn its EventId before linking.
            Right sourced <- runStoreIO store $ readStreamForward (StreamName "orders-1") (StreamVersion 0) 100
            let eid = V.head sourced ^. #eventId
            Right _ <- runStoreIO store $ linkToStream (StreamName "audit-1") [eid]
            Right linked <- runStoreIO store $ readStreamForward (StreamName "audit-1") (StreamVersion 0) 100
            map (^. #originalStreamName) (V.toList linked) `shouldBe` [StreamName "orders-1"]
