module Test.EventReferences (spec) where

import Control.Concurrent (myThreadId)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, when)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Kiroku.Store
import Kiroku.Store.Effect (maxEventReferenceBatch)
import Test.Helpers
import Test.Hspec

spec :: Spec
spec = describe "event references" $ do
  it "reports home and global memberships with actual global positions" $ withTestStore $ \store -> do
    event <- firstEvent store
    let eid = event ^. #eventId
    Right refs <- runStoreIO store (lookupEventReferences [eid])
    refs
      `shouldBe` Map.singleton
        eid
        ( EventReferenceInventory
            (V.fromList [GlobalMembership (GlobalPosition 1), HomeMembership (StreamName "order-1") (event ^. #originalStreamId) (StreamVersion 1)])
            0
            0
        )

  it "reports all link targets, including a link of a link and soft-deleted targets" $ withTestStore $ \store -> do
    event <- firstEvent store
    let eid = event ^. #eventId
    forM_ [(StreamName "hub"), (StreamName "mirror")] $ \name -> do
      Right _ <- runStoreIO store (linkToStream name [eid])
      pure ()
    Right _ <- runStoreIO store (softDeleteStream (StreamName "hub"))
    Right refs <- runStoreIO store (lookupEventReferences [eid])
    let ms = (refs Map.! eid) ^. #memberships
    V.length ms `shouldBe` 4
    [name | LinkMembership name _ _ <- V.toList ms] `shouldBe` [(StreamName "hub"), (StreamName "mirror")]
    [name | HomeMembership name _ _ <- V.toList ms] `shouldBe` [(StreamName "order-1")]

  it "counts dead letters across subscriptions" $ withTestStore $ \store -> do
    event <- firstEvent store
    insertDeadLetterForEvent store "proj-a" event
    insertDeadLetterForEvent store "proj-b" event
    Right refs <- runStoreIO store (lookupEventReferences [event ^. #eventId])
    (refs Map.! (event ^. #eventId)) ^. #deadLetterCount `shouldBe` 2

  it "excludes requested causation dependents and deduplicates input ids" $ withTestStore $ \store -> do
    event <- firstEvent store
    let eid@(EventId uid) = event ^. #eventId
        dependent = makeEvent "Dependent" (Aeson.object []) & #causationId .~ Just uid
    Right _ <- runStoreIO store (appendToStream (StreamName "caused-1") NoStream [dependent, dependent])
    Right caused <- runStoreIO store (readStreamForward (StreamName "caused-1") (StreamVersion 0) 10)
    Right single <- runStoreIO store (lookupEventReferences [eid])
    (single Map.! eid) ^. #causationDependentCount `shouldBe` 2
    let ids = [eid, caused V.! 0 ^. #eventId]
    Right refs <- runStoreIO store (lookupEventReferences (ids <> ids))
    (refs Map.! eid) ^. #causationDependentCount `shouldBe` 1
    V.length ((refs Map.! eid) ^. #memberships) `shouldBe` 2
    runStoreIO store (runTransaction (lookupEventReferencesTx ids)) `shouldReturn` Right refs

  it "omits unknown ids and agrees with the transaction combinator" $ withTestStore $ \store -> do
    event <- firstEvent store
    let ids = [event ^. #eventId, EventId UUID.nil]
    Right refs <- runStoreIO store (lookupEventReferences ids)
    Map.keys refs `shouldBe` [event ^. #eventId]
    runStoreIO store (runTransaction (lookupEventReferencesTx ids)) `shouldReturn` Right refs

  it "uses no checkout for empty input and one checkout across batches" $ do
    owner <- myThreadId
    checkouts <- newIORef (0 :: Int)
    let tweak settings =
          settings
            { observationHandler = Just $ \case
                ConnectionObservation _ InUseConnectionStatus -> do
                  current <- myThreadId
                  when (current == owner) (modifyIORef' checkouts (+ 1))
                _ -> pure ()
            }
    withTestStoreSettings tweak $ \store -> do
      beforeEmpty <- readIORef checkouts
      runStoreIO store (lookupEventReferences []) `shouldReturn` Right Map.empty
      readIORef checkouts `shouldReturn` beforeEmpty
      -- Last requested event depends on the first: the exclusion must span batches.
      let firstId = UUID.fromWords64 0 1
          events =
            [ makeEvent "Batch" (Aeson.object [])
                & #eventId .~ Just (EventId (UUID.fromWords64 0 (fromIntegral n)))
                & #causationId .~ (if n == maxEventReferenceBatch + 1 then Just firstId else Nothing)
            | n <- [1 .. maxEventReferenceBatch + 1]
            ]
      forM_ (chunks 2000 events) $ \batch -> do
        Right _ <- runStoreIO store (appendToStream (StreamName "batch-1") AnyVersion batch)
        pure ()
      let ids = [EventId (UUID.fromWords64 0 (fromIntegral n)) | n <- [1 .. maxEventReferenceBatch + 1]]
      beforeRead <- readIORef checkouts
      Right refs <- runStoreIO store (lookupEventReferences ids)
      readIORef checkouts `shouldReturn` (beforeRead + 1)
      Map.size refs `shouldBe` maxEventReferenceBatch + 1
      forM_ (Map.elems refs) $ \inventory -> do
        V.length (inventory ^. #memberships) `shouldBe` 2
        inventory ^. #causationDependentCount `shouldBe` 0

firstEvent :: KirokuStore -> IO RecordedEvent
firstEvent store = do
  Right _ <- runStoreIO store (appendToStream (StreamName "order-1") NoStream [makeEvent "Placed" (Aeson.object [])])
  Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
  pure (V.head events)

chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks size values = let (batch, rest) = splitAt size values in batch : chunks size rest
