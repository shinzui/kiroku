module Main where

import Control.Lens ((^.))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import EphemeralPg qualified as Pg
import Kiroku.Store
import Test.Hspec

main :: IO ()
main = hspec $ do
    around withTestStore $ do
        describe "appendToStream" $ do
            describe "NoStream" $ do
                it "creates a new stream and appends events" $ \store -> do
                    let event = makeEvent "OrderCreated" (Aeson.object [("orderId", Aeson.String "123")])
                    result <- runStoreIO store $ appendToStream (StreamName "order-123") NoStream [event]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            (r ^. #streamVersion) `shouldBe` StreamVersion 1
                            (r ^. #globalPosition) `shouldBe` GlobalPosition 1

                it "fails when stream already exists" $ \store -> do
                    _ <- runStoreIO store $ appendToStream (StreamName "order-456") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                    result <- runStoreIO store $ appendToStream (StreamName "order-456") NoStream [makeEvent "OrderUpdated" (Aeson.object [])]
                    case result of
                        Left (StreamAlreadyExists _) -> pure ()
                        other -> expectationFailure ("Expected StreamAlreadyExists, got: " <> show other)

            describe "ExactVersion" $ do
                it "appends when version matches" $ \store -> do
                    Right r1 <- runStoreIO store $ appendToStream (StreamName "order-789") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                    (r1 ^. #streamVersion) `shouldBe` StreamVersion 1

                    result <- runStoreIO store $ appendToStream (StreamName "order-789") (ExactVersion (StreamVersion 1)) [makeEvent "OrderUpdated" (Aeson.object [])]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            (r ^. #streamVersion) `shouldBe` StreamVersion 2
                            (r ^. #globalPosition) `shouldBe` GlobalPosition 2

                it "fails on version conflict" $ \store -> do
                    _ <- runStoreIO store $ appendToStream (StreamName "order-conflict") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                    result <- runStoreIO store $ appendToStream (StreamName "order-conflict") (ExactVersion (StreamVersion 0)) [makeEvent "OrderUpdated" (Aeson.object [])]
                    case result of
                        Left (WrongExpectedVersion _ _ _) -> pure ()
                        other -> expectationFailure ("Expected WrongExpectedVersion, got: " <> show other)

            describe "StreamExists" $ do
                it "appends to an existing stream" $ \store -> do
                    _ <- runStoreIO store $ appendToStream (StreamName "stream-exists-test") NoStream [makeEvent "Created" (Aeson.object [])]
                    result <- runStoreIO store $ appendToStream (StreamName "stream-exists-test") StreamExists [makeEvent "Updated" (Aeson.object [])]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> (r ^. #streamVersion) `shouldBe` StreamVersion 2

                it "fails when stream does not exist" $ \store -> do
                    result <- runStoreIO store $ appendToStream (StreamName "nonexistent-stream") StreamExists [makeEvent "Created" (Aeson.object [])]
                    case result of
                        Left (StreamNotFound _) -> pure ()
                        other -> expectationFailure ("Expected StreamNotFound, got: " <> show other)

            describe "AnyVersion" $ do
                it "creates a new stream" $ \store -> do
                    result <- runStoreIO store $ appendToStream (StreamName "any-new") AnyVersion [makeEvent "Created" (Aeson.object [])]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> (r ^. #streamVersion) `shouldBe` StreamVersion 1

                it "appends to an existing stream" $ \store -> do
                    _ <- runStoreIO store $ appendToStream (StreamName "any-existing") AnyVersion [makeEvent "Created" (Aeson.object [])]
                    result <- runStoreIO store $ appendToStream (StreamName "any-existing") AnyVersion [makeEvent "Updated" (Aeson.object [])]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> (r ^. #streamVersion) `shouldBe` StreamVersion 2

            describe "batch append" $ do
                it "appends multiple events with sequential versions" $ \store -> do
                    let events =
                            [ makeEvent "Event1" (Aeson.object [("n", Aeson.Number 1)])
                            , makeEvent "Event2" (Aeson.object [("n", Aeson.Number 2)])
                            , makeEvent "Event3" (Aeson.object [("n", Aeson.Number 3)])
                            ]
                    result <- runStoreIO store $ appendToStream (StreamName "batch-test") NoStream events
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            (r ^. #streamVersion) `shouldBe` StreamVersion 3
                            (r ^. #globalPosition) `shouldBe` GlobalPosition 3

            describe "global position contiguity" $ do
                it "assigns contiguous global positions across streams" $ \store -> do
                    Right r1 <- runStoreIO store $ appendToStream (StreamName "stream-a") NoStream [makeEvent "A" (Aeson.object [])]
                    (r1 ^. #globalPosition) `shouldBe` GlobalPosition 1

                    Right r2 <- runStoreIO store $ appendToStream (StreamName "stream-b") NoStream [makeEvent "B" (Aeson.object [])]
                    (r2 ^. #globalPosition) `shouldBe` GlobalPosition 2

                    Right r3 <- runStoreIO store $ appendToStream (StreamName "stream-c") NoStream [makeEvent "C" (Aeson.object [])]
                    (r3 ^. #globalPosition) `shouldBe` GlobalPosition 3

            describe "duplicate event ID" $ do
                it "rejects duplicate event IDs" $ \store -> do
                    let eid = EventId (case UUID.fromString "01234567-89ab-7def-8012-34567890abcd" of Just u -> u; Nothing -> error "bad uuid")
                    let event1 =
                            EventData
                                { eventId = Just eid
                                , eventType = EventType "Created"
                                , payload = Aeson.object []
                                , metadata = Nothing
                                , causationId = Nothing
                                , correlationId = Nothing
                                }
                    Right _ <- runStoreIO store $ appendToStream (StreamName "dup-test-1") NoStream [event1]

                    let event2 =
                            EventData
                                { eventId = Just eid
                                , eventType = EventType "Created"
                                , payload = Aeson.object []
                                , metadata = Nothing
                                , causationId = Nothing
                                , correlationId = Nothing
                                }
                    result <- runStoreIO store $ appendToStream (StreamName "dup-test-2") NoStream [event2]
                    case result of
                        Left (DuplicateEvent _) -> pure ()
                        other -> expectationFailure ("Expected DuplicateEvent, got: " <> show other)

        describe "readStreamForward" $ do
            it "reads events in forward order (read-your-own-writes)" $ \store -> do
                let events =
                        [ makeEvent "A" (Aeson.object [("n", Aeson.Number 1)])
                        , makeEvent "B" (Aeson.object [("n", Aeson.Number 2)])
                        , makeEvent "C" (Aeson.object [("n", Aeson.Number 3)])
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName "read-fwd") NoStream events
                Right result <- runStoreIO store $ readStreamForward (StreamName "read-fwd") (StreamVersion 0) 100
                V.length result `shouldBe` 3
                (V.head result ^. #eventType) `shouldBe` EventType "A"
                (result V.! 1 ^. #eventType) `shouldBe` EventType "B"
                (result V.! 2 ^. #eventType) `shouldBe` EventType "C"
                (V.head result ^. #streamVersion) `shouldBe` StreamVersion 1
                (result V.! 1 ^. #streamVersion) `shouldBe` StreamVersion 2
                (result V.! 2 ^. #streamVersion) `shouldBe` StreamVersion 3

        describe "readStreamBackward" $ do
            it "reads events in backward order" $ \store -> do
                let events =
                        [ makeEvent "A" (Aeson.object [])
                        , makeEvent "B" (Aeson.object [])
                        , makeEvent "C" (Aeson.object [])
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName "read-bwd") NoStream events
                Right result <- runStoreIO store $ readStreamBackward (StreamName "read-bwd") (StreamVersion 0) 100
                V.length result `shouldBe` 3
                (V.head result ^. #eventType) `shouldBe` EventType "C"
                (result V.! 1 ^. #eventType) `shouldBe` EventType "B"
                (result V.! 2 ^. #eventType) `shouldBe` EventType "A"
                (V.head result ^. #streamVersion) `shouldBe` StreamVersion 3
                (result V.! 1 ^. #streamVersion) `shouldBe` StreamVersion 2
                (result V.! 2 ^. #streamVersion) `shouldBe` StreamVersion 1

        describe "cursor-based pagination" $ do
            it "paginates using stream version as cursor" $ \store -> do
                let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "read-page") NoStream events
                -- Read first page of 2
                Right page1 <- runStoreIO store $ readStreamForward (StreamName "read-page") (StreamVersion 0) 2
                V.length page1 `shouldBe` 2
                let cursor1 = page1 V.! 1 ^. #streamVersion
                cursor1 `shouldBe` StreamVersion 2
                -- Read second page from cursor
                Right page2 <- runStoreIO store $ readStreamForward (StreamName "read-page") cursor1 2
                V.length page2 `shouldBe` 2
                (V.head page2 ^. #streamVersion) `shouldBe` StreamVersion 3
                -- Read third page — only 1 event left
                let cursor2 = page2 V.! 1 ^. #streamVersion
                Right page3 <- runStoreIO store $ readStreamForward (StreamName "read-page") cursor2 2
                V.length page3 `shouldBe` 1
                -- Read past end — empty
                let cursor3 = V.head page3 ^. #streamVersion
                Right page4 <- runStoreIO store $ readStreamForward (StreamName "read-page") cursor3 2
                V.length page4 `shouldBe` 0

        describe "readAllForward" $ do
            it "reads events from $all in global order" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "all-s1") NoStream [makeEvent "X" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "all-s2") NoStream [makeEvent "Y" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "all-s3") NoStream [makeEvent "Z" (Aeson.object [])]
                Right result <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                V.length result `shouldBe` 3
                (V.head result ^. #eventType) `shouldBe` EventType "X"
                (result V.! 1 ^. #eventType) `shouldBe` EventType "Y"
                (result V.! 2 ^. #eventType) `shouldBe` EventType "Z"
                -- Global positions should be contiguous
                (V.head result ^. #globalPosition) `shouldBe` GlobalPosition 1
                (result V.! 1 ^. #globalPosition) `shouldBe` GlobalPosition 2
                (result V.! 2 ^. #globalPosition) `shouldBe` GlobalPosition 3

        describe "readAllBackward" $ do
            it "reads events from $all in reverse order" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "allb-s1") NoStream [makeEvent "X" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "allb-s2") NoStream [makeEvent "Y" (Aeson.object [])]
                Right result <- runStoreIO store $ readAllBackward (GlobalPosition 0) 100
                V.length result `shouldBe` 2
                (V.head result ^. #eventType) `shouldBe` EventType "Y"
                (result V.! 1 ^. #eventType) `shouldBe` EventType "X"

        describe "read empty/nonexistent stream" $ do
            it "returns empty Vector for nonexistent stream" $ \store -> do
                Right result <- runStoreIO store $ readStreamForward (StreamName "no-such-stream") (StreamVersion 0) 100
                V.length result `shouldBe` 0

        describe "getStream" $ do
            it "returns metadata for existing stream" $ \store -> do
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "meta-test")
                            NoStream
                            [ makeEvent "A" (Aeson.object [])
                            , makeEvent "B" (Aeson.object [])
                            ]
                Right info <- runStoreIO store $ getStream (StreamName "meta-test")
                case info of
                    Just si -> do
                        (si ^. #name) `shouldBe` StreamName "meta-test"
                        (si ^. #version) `shouldBe` StreamVersion 2
                    Nothing -> expectationFailure "Expected Just StreamInfo, got Nothing"

            it "returns Nothing for nonexistent stream" $ \store -> do
                Right info <- runStoreIO store $ getStream (StreamName "no-such-stream")
                info `shouldBe` Nothing

        describe "integration: full lifecycle through withStore" $ do
            it "append, read forward, read $all, getStream — all through public API" $ \store -> do
                -- Append events to two streams
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "integ-orders")
                            NoStream
                            [ makeEvent "OrderCreated" (Aeson.object [("id", Aeson.String "1")])
                            , makeEvent "OrderShipped" (Aeson.object [("id", Aeson.String "1")])
                            ]
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "integ-users")
                            NoStream
                            [ makeEvent "UserRegistered" (Aeson.object [("name", Aeson.String "alice")])
                            ]

                -- Read from a named stream
                Right orders <- runStoreIO store $ readStreamForward (StreamName "integ-orders") (StreamVersion 0) 100
                V.length orders `shouldBe` 2
                (V.head orders ^. #eventType) `shouldBe` EventType "OrderCreated"
                (orders V.! 1 ^. #eventType) `shouldBe` EventType "OrderShipped"

                -- Read from $all — should see all 3 events in global order
                Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                V.length allEvents `shouldBe` 3
                (V.head allEvents ^. #globalPosition) `shouldBe` GlobalPosition 1
                (allEvents V.! 2 ^. #globalPosition) `shouldBe` GlobalPosition 3

                -- Query stream metadata
                Right orderInfo <- runStoreIO store $ getStream (StreamName "integ-orders")
                case orderInfo of
                    Just si -> (si ^. #version) `shouldBe` StreamVersion 2
                    Nothing -> expectationFailure "Expected stream info"

                Right noInfo <- runStoreIO store $ getStream (StreamName "nonexistent")
                noInfo `shouldBe` Nothing

        -- =================================================================
        -- Link tests (M5.8)
        -- =================================================================
        describe "linkToStream" $ do
            it "links a single event to a new stream" $ \store -> do
                let event = makeEvent "OrderCreated" (Aeson.object [("id", Aeson.String "1")])
                Right appendR <- runStoreIO store $ appendToStream (StreamName "source-1") NoStream [event]
                -- Read back to get the event ID
                Right events <- runStoreIO store $ readStreamForward (StreamName "source-1") (StreamVersion 0) 100
                let eid = V.head events ^. #eventId
                -- Link it
                Right linkR <- runStoreIO store $ linkToStream (StreamName "linked-1") [eid]
                (linkR ^. #streamVersion) `shouldBe` StreamVersion 1
                -- Read the linked stream
                Right linked <- runStoreIO store $ readStreamForward (StreamName "linked-1") (StreamVersion 0) 100
                V.length linked `shouldBe` 1
                (V.head linked ^. #eventId) `shouldBe` eid
                (V.head linked ^. #originalStreamId) `shouldBe` (appendR ^. #streamId)
                (V.head linked ^. #originalVersion) `shouldBe` StreamVersion 1

            it "links multiple events with sequential versions" $ \store -> do
                let events =
                        [ makeEvent "A" (Aeson.object [])
                        , makeEvent "B" (Aeson.object [])
                        , makeEvent "C" (Aeson.object [])
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName "source-multi") NoStream events
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "source-multi") (StreamVersion 0) 100
                let eids = V.toList (V.map (^. #eventId) srcEvents)
                Right linkR <- runStoreIO store $ linkToStream (StreamName "linked-multi") eids
                (linkR ^. #streamVersion) `shouldBe` StreamVersion 3
                Right linked <- runStoreIO store $ readStreamForward (StreamName "linked-multi") (StreamVersion 0) 100
                V.length linked `shouldBe` 3
                (V.head linked ^. #streamVersion) `shouldBe` StreamVersion 1
                (linked V.! 1 ^. #streamVersion) `shouldBe` StreamVersion 2
                (linked V.! 2 ^. #streamVersion) `shouldBe` StreamVersion 3

            it "links events to an existing stream and bumps version" $ \store -> do
                let events1 = [makeEvent "A" (Aeson.object [])]
                    events2 = [makeEvent "B" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "src-a") NoStream events1
                Right _ <- runStoreIO store $ appendToStream (StreamName "src-b") NoStream events2
                Right evA <- runStoreIO store $ readStreamForward (StreamName "src-a") (StreamVersion 0) 100
                Right evB <- runStoreIO store $ readStreamForward (StreamName "src-b") (StreamVersion 0) 100
                let eidA = V.head evA ^. #eventId
                    eidB = V.head evB ^. #eventId
                -- Link first event
                Right r1 <- runStoreIO store $ linkToStream (StreamName "linked-existing") [eidA]
                (r1 ^. #streamVersion) `shouldBe` StreamVersion 1
                -- Link second event to same stream
                Right r2 <- runStoreIO store $ linkToStream (StreamName "linked-existing") [eidB]
                (r2 ^. #streamVersion) `shouldBe` StreamVersion 2
                -- Read all linked events
                Right linked <- runStoreIO store $ readStreamForward (StreamName "linked-existing") (StreamVersion 0) 100
                V.length linked `shouldBe` 2

            it "linked events still appear in $all at original global positions" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "orig-all") NoStream [makeEvent "X" (Aeson.object [])]
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "orig-all") (StreamVersion 0) 100
                let eid = V.head srcEvents ^. #eventId
                _ <- runStoreIO store $ linkToStream (StreamName "linked-all") [eid]
                -- Read $all — should have exactly 1 event (not duplicated)
                Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                let matchingEvents = V.filter (\e -> (e ^. #eventId) == eid) allEvents
                V.length matchingEvents `shouldBe` 1

            it "rejects linking the same event to the same stream twice" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "src-dup") NoStream [makeEvent "X" (Aeson.object [])]
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "src-dup") (StreamVersion 0) 100
                let eid = V.head srcEvents ^. #eventId
                Right _ <- runStoreIO store $ linkToStream (StreamName "linked-dup") [eid]
                result <- runStoreIO store $ linkToStream (StreamName "linked-dup") [eid]
                case result of
                    Left _ -> pure () -- Expected: some error (PK violation)
                    Right _ -> expectationFailure "Expected error for duplicate link"

        -- =================================================================
        -- Category read tests (M5.8)
        -- =================================================================
        describe "readCategory" $ do
            it "reads events from matching category streams in global position order" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-2") NoStream [makeEvent "OrderShipped" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "user-1") NoStream [makeEvent "UserRegistered" (Aeson.object [])]
                Right result <- runStoreIO store $ readCategory (CategoryName "order") (GlobalPosition 0) 100
                V.length result `shouldBe` 2
                (V.head result ^. #eventType) `shouldBe` EventType "OrderCreated"
                (result V.! 1 ^. #eventType) `shouldBe` EventType "OrderShipped"
                -- Verify global positions are ascending
                (V.head result ^. #globalPosition) `shouldSatisfy` (< (result V.! 1 ^. #globalPosition))

            it "supports pagination with start position and limit" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "cat-1") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "cat-2") NoStream [makeEvent "B" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "cat-3") NoStream [makeEvent "C" (Aeson.object [])]
                -- Read first 2
                Right page1 <- runStoreIO store $ readCategory (CategoryName "cat") (GlobalPosition 0) 2
                V.length page1 `shouldBe` 2
                -- Read from cursor
                let cursor = page1 V.! 1 ^. #globalPosition
                Right page2 <- runStoreIO store $ readCategory (CategoryName "cat") cursor 100
                V.length page2 `shouldBe` 1

            it "returns empty for nonexistent category" $ \store -> do
                Right result <- runStoreIO store $ readCategory (CategoryName "nope") (GlobalPosition 0) 100
                V.length result `shouldBe` 0

            it "includes linked events that originate from category streams" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "evt-1") NoStream [makeEvent "EventA" (Aeson.object [])]
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "evt-1") (StreamVersion 0) 100
                let eid = V.head srcEvents ^. #eventId
                -- Link into a different-category stream
                Right _ <- runStoreIO store $ linkToStream (StreamName "projection-1") [eid]
                -- Category "evt" should still return the event (it originates from evt-1)
                Right result <- runStoreIO store $ readCategory (CategoryName "evt") (GlobalPosition 0) 100
                V.length result `shouldBe` 1
                (V.head result ^. #eventType) `shouldBe` EventType "EventA"

        -- =================================================================
        -- Multi-stream transaction tests (M5.8)
        -- =================================================================
        describe "appendMultiStream" $ do
            it "atomically appends to two streams" $ \store -> do
                let ops =
                        [ (StreamName "multi-a", NoStream, [makeEvent "A" (Aeson.object [])])
                        , (StreamName "multi-b", NoStream, [makeEvent "B" (Aeson.object [])])
                        ]
                Right results <- runStoreIO store $ appendMultiStream ops
                length results `shouldBe` 2
                ((results !! 0) ^. #streamVersion) `shouldBe` StreamVersion 1
                ((results !! 1) ^. #streamVersion) `shouldBe` StreamVersion 1

            it "rolls back all streams on version conflict" $ \store -> do
                -- Create stream multi-c
                Right _ <- runStoreIO store $ appendToStream (StreamName "multi-c") NoStream [makeEvent "C" (Aeson.object [])]
                let ops =
                        [ (StreamName "multi-d", NoStream, [makeEvent "D" (Aeson.object [])])
                        , (StreamName "multi-c", NoStream, [makeEvent "C2" (Aeson.object [])]) -- conflict: already exists
                        ]
                result <- runStoreIO store $ appendMultiStream ops
                case result of
                    Left _ -> do
                        -- Verify multi-d was NOT created (rollback)
                        Right info <- runStoreIO store $ getStream (StreamName "multi-d")
                        info `shouldBe` Nothing
                    Right _ -> expectationFailure "Expected error for version conflict"

            it "appends to three streams with different expected versions" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "tri-1") NoStream [makeEvent "X" (Aeson.object [])]
                let ops =
                        [ (StreamName "tri-1", ExactVersion (StreamVersion 1), [makeEvent "X2" (Aeson.object [])])
                        , (StreamName "tri-2", NoStream, [makeEvent "Y" (Aeson.object [])])
                        , (StreamName "tri-3", AnyVersion, [makeEvent "Z" (Aeson.object [])])
                        ]
                Right results <- runStoreIO store $ appendMultiStream ops
                length results `shouldBe` 3
                ((results !! 0) ^. #streamVersion) `shouldBe` StreamVersion 2
                ((results !! 1) ^. #streamVersion) `shouldBe` StreamVersion 1
                ((results !! 2) ^. #streamVersion) `shouldBe` StreamVersion 1

        -- =================================================================
        -- Soft delete tests (M6.8)
        -- =================================================================
        describe "softDeleteStream" $ do
            it "soft-deletes a stream and getStream shows deletedAt" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "del-1") NoStream [makeEvent "A" (Aeson.object [])]
                Right mId <- runStoreIO store $ softDeleteStream (StreamName "del-1")
                mId `shouldSatisfy` (/= Nothing)
                Right info <- runStoreIO store $ getStream (StreamName "del-1")
                case info of
                    Just si -> (si ^. #deletedAt) `shouldSatisfy` (/= Nothing)
                    Nothing -> expectationFailure "Expected stream info with deletedAt set"

            it "returns empty for reads from a soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "del-read") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "del-read")
                Right fwd <- runStoreIO store $ readStreamForward (StreamName "del-read") (StreamVersion 0) 100
                V.length fwd `shouldBe` 0
                Right bwd <- runStoreIO store $ readStreamBackward (StreamName "del-read") (StreamVersion 0) 100
                V.length bwd `shouldBe` 0

            it "rejects appends to a soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "del-append") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "del-append")
                result <- runStoreIO store $ appendToStream (StreamName "del-append") StreamExists [makeEvent "B" (Aeson.object [])]
                case result of
                    Left (StreamNotFound _) -> pure ()
                    other -> expectationFailure ("Expected StreamNotFound, got: " <> show other)

            it "returns Nothing for nonexistent stream" $ \store -> do
                Right mId <- runStoreIO store $ softDeleteStream (StreamName "no-such")
                mId `shouldBe` Nothing

            it "returns Nothing for already-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "del-twice") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "del-twice")
                Right mId <- runStoreIO store $ softDeleteStream (StreamName "del-twice")
                mId `shouldBe` Nothing

            it "events from soft-deleted stream still appear in $all" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "del-all") NoStream [makeEvent "KeepInAll" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "del-all")
                Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                let matching = V.filter (\e -> (e ^. #eventType) == EventType "KeepInAll") allEvents
                V.length matching `shouldBe` 1

        -- =================================================================
        -- Undelete tests (M6.8)
        -- =================================================================
        describe "undeleteStream" $ do
            it "restores a soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "undel-1") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "undel-1")
                Right mId <- runStoreIO store $ undeleteStream (StreamName "undel-1")
                mId `shouldSatisfy` (/= Nothing)
                Right info <- runStoreIO store $ getStream (StreamName "undel-1")
                case info of
                    Just si -> (si ^. #deletedAt) `shouldBe` Nothing
                    Nothing -> expectationFailure "Expected stream info"

            it "reads work after undelete" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "undel-read") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "undel-read")
                Right _ <- runStoreIO store $ undeleteStream (StreamName "undel-read")
                Right events <- runStoreIO store $ readStreamForward (StreamName "undel-read") (StreamVersion 0) 100
                V.length events `shouldBe` 1

            it "appends work after undelete" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "undel-append") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "undel-append")
                Right _ <- runStoreIO store $ undeleteStream (StreamName "undel-append")
                Right r <- runStoreIO store $ appendToStream (StreamName "undel-append") StreamExists [makeEvent "B" (Aeson.object [])]
                (r ^. #streamVersion) `shouldBe` StreamVersion 2

            it "returns Nothing for non-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "undel-noop") NoStream [makeEvent "A" (Aeson.object [])]
                Right mId <- runStoreIO store $ undeleteStream (StreamName "undel-noop")
                mId `shouldBe` Nothing

        -- =================================================================
        -- Hard delete tests (M6.8)
        -- =================================================================
        describe "hardDeleteStream" $ do
            it "hard-deletes a stream completely" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "hard-1") NoStream [makeEvent "A" (Aeson.object [])]
                Right mId <- runStoreIO store $ hardDeleteStream (StreamName "hard-1")
                mId `shouldSatisfy` (/= Nothing)
                Right info <- runStoreIO store $ getStream (StreamName "hard-1")
                info `shouldBe` Nothing

            it "events from hard-deleted stream no longer appear in $all" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "hard-all") NoStream [makeEvent "HardDelEvent" (Aeson.object [])]
                Right _ <- runStoreIO store $ hardDeleteStream (StreamName "hard-all")
                Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                let matching = V.filter (\e -> (e ^. #eventType) == EventType "HardDelEvent") allEvents
                V.length matching `shouldBe` 0

            it "returns Nothing for nonexistent stream" $ \store -> do
                Right mId <- runStoreIO store $ hardDeleteStream (StreamName "hard-no-such")
                mId `shouldBe` Nothing

    -- =================================================================
    -- Health monitoring tests (M6.8)
    -- =================================================================
    describe "observationHandler" $ do
        it "receives observations during store operations" $ \() -> do
            ref <- newIORef ([] :: [Observation])
            let handler obs = modifyIORef' ref (obs :)
            result <- Pg.withCached $ \db -> do
                let settings =
                        (defaultConnectionSettings (Pg.connectionString db))
                            { observationHandler = Just handler
                            }
                withStore settings $ \store -> do
                    Right _ <- runStoreIO store $ appendToStream (StreamName "obs-test") NoStream [makeEvent "X" (Aeson.object [])]
                    pure ()
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()
            observations <- readIORef ref
            length observations `shouldSatisfy` (> 0)

-- | Create a simple EventData with auto-generated ID.
makeEvent :: Text -> Value -> EventData
makeEvent typ payload =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = payload
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

{- | Bracket that creates an ephemeral PostgreSQL database and provides a
KirokuStore handle. Uses 'withStore' which auto-initializes the schema.
-}
withTestStore :: (KirokuStore -> IO ()) -> IO ()
withTestStore action = do
    result <- Pg.withCached $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings action
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()
