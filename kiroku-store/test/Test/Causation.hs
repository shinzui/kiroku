{- | Tests for "Kiroku.Store.Causation" — the causation- and
correlation-walking helpers.

Three groups of tests exercise the three exported functions:

  * 'findCausationDescendants' over a 5-deep chain @A -> B -> C -> D -> E@
    spread across three streams, plus single-element and empty cases.
  * 'findCausationAncestors' over the same chain, asserting leaf-first
    depth ordering.
  * 'findByCorrelation' fanning in across multiple streams, plus a noise
    correlation and an empty case.
-}
module Test.Causation (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4
import Data.Vector (Vector)
import Data.Vector qualified as V
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = around withTestStore $ do
    describe "findCausationDescendants" $ do
        it "returns the seed event and every descendant in global-position order" $ \store -> do
            uuids@[uA, uB, uC, uD, uE] <- replicateUuids 5
            appendChain store uuids
            Right found <- runStoreIO store $ findCausationDescendants (EventId uA)
            eventIds found `shouldBe` map EventId uuids
            globalPositionsStrictlyIncreasing found `shouldBe` True

        it "on an eventId with no descendants returns a vector of length 1 (the seed only)" $ \store -> do
            uId <- UUIDv4.nextRandom
            let ev = mkEventWithIds "Solo" (Just uId) Nothing Nothing
            Right _ <- runStoreIO store $ appendToStream (StreamName "solo-stream") NoStream [ev]
            Right found <- runStoreIO store $ findCausationDescendants (EventId uId)
            V.length found `shouldBe` 1
            (V.head found ^. #eventId) `shouldBe` EventId uId

        it "on a non-existent eventId returns an empty vector" $ \store -> do
            -- Make sure the store has *some* events so we know we're not
            -- silently returning the whole table.
            let ev = makeEvent "Other" Aeson.Null
            Right _ <- runStoreIO store $ appendToStream (StreamName "other-stream") NoStream [ev]
            Right found <- runStoreIO store $ findCausationDescendants (EventId UUID.nil)
            V.null found `shouldBe` True

    describe "findCausationAncestors" $ do
        it "walks from a leaf back to the root, leaf first" $ \store -> do
            uuids@[uA, uB, uC, uD, uE] <- replicateUuids 5
            appendChain store uuids
            Right found <- runStoreIO store $ findCausationAncestors (EventId uE)
            eventIds found `shouldBe` map EventId [uE, uD, uC, uB, uA]

    describe "findByCorrelation" $ do
        it "returns every event with the given correlation across multiple streams in global-position order" $ \store -> do
            cMain <- UUIDv4.nextRandom
            cOther <- UUIDv4.nextRandom
            -- 7 events with correlation = cMain across 4 streams.
            let mkEv :: Int -> EventData
                mkEv i =
                    mkEventWithIds
                        (mkName "Main" i)
                        Nothing
                        Nothing
                        (Just cMain)
                mainPlan =
                    [ ("saga-a", NoStream, [mkEv 1, mkEv 2])
                    , ("saga-b", NoStream, [mkEv 3])
                    , ("saga-c", NoStream, [mkEv 4, mkEv 5, mkEv 6])
                    , ("saga-d", NoStream, [mkEv 7])
                    ]
            mapM_
                ( \(sn, ev, evts) -> do
                    Right _ <- runStoreIO store $ appendToStream (StreamName sn) ev evts
                    pure ()
                )
                mainPlan
            -- Noise: one event with no correlation.
            Right _ <- runStoreIO store $ appendToStream (StreamName "noise-stream") NoStream [makeEvent "Noise" Aeson.Null]
            -- A separate correlation set we should not see.
            let mkOther :: Int -> EventData
                mkOther i =
                    mkEventWithIds
                        (mkName "Other" i)
                        Nothing
                        Nothing
                        (Just cOther)
            Right _ <- runStoreIO store $ appendToStream (StreamName "other-saga") NoStream [mkOther i | i <- [1 .. 5 :: Int]]

            Right found <- runStoreIO store $ findByCorrelation cMain
            V.length found `shouldBe` 7
            all (\e -> e ^. #correlationId == Just cMain) found `shouldBe` True
            globalPositionsStrictlyIncreasing found `shouldBe` True

        it "on an unknown correlation returns an empty vector" $ \store -> do
            -- Insert *something* so we're not just observing an empty store.
            let noise = mkEventWithIds "Noise" Nothing Nothing (Just UUID.nil)
            Right _ <-
                runStoreIO store $
                    appendToStream (StreamName "noise-stream") NoStream [noise]
            unknown <- UUIDv4.nextRandom
            Right found <- runStoreIO store $ findByCorrelation unknown
            V.null found `shouldBe` True

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

replicateUuids :: Int -> IO [UUID]
replicateUuids n = mapM (const UUIDv4.nextRandom) [1 .. n]

{- | Build an 'EventData' from explicit event-id, causation-id, and
correlation-id arguments. Wraps the field updates in a typed binding so
'DuplicateRecordFields' does not complain about ambiguous record
updates ('eventId', 'causationId', and 'correlationId' all appear on
both 'EventData' and 'RecordedEvent').
-}
mkEventWithIds :: Text -> Maybe UUID -> Maybe UUID -> Maybe UUID -> EventData
mkEventWithIds typ mEid mCause mCorr =
    EventData
        { eventId = fmap EventId mEid
        , eventType = EventType typ
        , payload = Aeson.Null
        , metadata = Nothing
        , causationId = mCause
        , correlationId = mCorr
        }

{- | Append a 5-event causation chain @A -> B -> C -> D -> E@ across three
streams (@pm-trigger@, @pm-cmd@, @pm-result@). Each event's
@causationId@ points at the previous event's @eventId@.

Expects exactly five UUIDs; calls 'error' on any other length so the
caller's signature stays simple.
-}
appendChain :: KirokuStore -> [UUID] -> IO ()
appendChain store [uA, uB, uC, uD, uE] = do
    let evA = mkEventWithIds "A" (Just uA) Nothing Nothing
        evB = mkEventWithIds "B" (Just uB) (Just uA) Nothing
        evC = mkEventWithIds "C" (Just uC) (Just uB) Nothing
        evD = mkEventWithIds "D" (Just uD) (Just uC) Nothing
        evE = mkEventWithIds "E" (Just uE) (Just uD) Nothing
    Right _ <- runStoreIO store $ appendToStream (StreamName "pm-trigger") NoStream [evA]
    Right _ <- runStoreIO store $ appendToStream (StreamName "pm-cmd") NoStream [evB]
    Right _ <- runStoreIO store $ appendToStream (StreamName "pm-cmd") AnyVersion [evC]
    Right _ <- runStoreIO store $ appendToStream (StreamName "pm-result") NoStream [evD]
    Right _ <- runStoreIO store $ appendToStream (StreamName "pm-result") AnyVersion [evE]
    pure ()
appendChain _ _ = error "appendChain: expected exactly 5 UUIDs"

eventIds :: Vector RecordedEvent -> [EventId]
eventIds = V.toList . V.map (^. #eventId)

globalPositionsStrictlyIncreasing :: Vector RecordedEvent -> Bool
globalPositionsStrictlyIncreasing v =
    let ps = V.toList (V.map (\e -> let GlobalPosition p = e ^. #globalPosition in p) v)
     in and (zipWith (<) ps (drop 1 ps))

mkName :: String -> Int -> Text
mkName tag i = T.pack (tag <> "-" <> show i)
