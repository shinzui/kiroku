module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Exception (SomeException)
import Control.Lens ((^.))
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import EphemeralPg qualified as Pg
import Kiroku.Store
import Kiroku.Store.Subscription.Effect qualified as SubEff
import Kiroku.Store.Subscription.Types (SubscriptionConfigM (..))
import Shibuya.Adapter.Kiroku (KirokuAdapterConfig (..), kirokuAdapter)
import Shibuya.App (
    AppHandle (..),
    ProcessorId (..),
    SupervisionStrategy (..),
    getAppMetrics,
    mkProcessor,
    runApp,
    stopApp,
    stopAppGracefully,
 )
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Runner.Metrics (ProcessorMetrics (..), ProcessorState (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
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
        -- Subscription tests (M7.7)
        -- =================================================================
        describe "subscribe" $ do
            it "catches up from position 0 on a store with existing events" $ \store -> do
                -- Append 10 events
                let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "catchup-1") NoStream events
                -- Give the EventPublisher time to process
                threadDelay 200_000
                -- Subscribe from position 0
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n >= 10
                            then pure Stop
                            else pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "catchup-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 10

            it "receives live events appended after subscription starts" $ \store -> do
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n >= 5
                            then pure Stop
                            else pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "live-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                -- Give subscription time to start
                threadDelay 100_000
                -- Append 5 events
                let events = map (\i -> makeEvent ("Live" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "live-1") NoStream events
                -- Wait for subscription to complete
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 5

            it "persists checkpoint and resumes from saved position" $ \store -> do
                -- Append 10 events
                let events = map (\i -> makeEvent ("CP" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "ckpt-1") NoStream events
                threadDelay 200_000
                -- First subscription: process 5 events then stop
                countRef1 <- newTVarIO (0 :: Int)
                let handler1 _evt = do
                        n <- atomically $ do
                            c <- readTVar countRef1
                            let c' = c + 1
                            writeTVar countRef1 c'
                            pure c'
                        if n >= 5
                            then pure Stop
                            else pure Continue
                let cfg1 =
                        SubscriptionConfig
                            { name = SubscriptionName "ckpt-test"
                            , target = AllStreams
                            , handler = handler1
                            , batchSize = 100
                            }
                h1 <- subscribe store cfg1
                _ <- waitWithTimeout 10_000_000 h1
                -- Second subscription with same name: should resume from position 5
                ref2 <- newIORef ([] :: [RecordedEvent])
                countRef2 <- newTVarIO (0 :: Int)
                let handler2 evt = do
                        modifyIORef' ref2 (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef2
                            let c' = c + 1
                            writeTVar countRef2 c'
                            pure c'
                        if n >= 5
                            then pure Stop
                            else pure Continue
                let cfg2 =
                        SubscriptionConfig
                            { name = SubscriptionName "ckpt-test"
                            , target = AllStreams
                            , handler = handler2
                            , batchSize = 100
                            }
                h2 <- subscribe store cfg2
                _ <- waitWithTimeout 10_000_000 h2
                collected <- readIORef ref2
                -- Should receive events 6–10 only
                length collected `shouldBe` 5

            it "delivers only category-matching events during catch-up" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-2") NoStream [makeEvent "OrderShipped" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "user-1") NoStream [makeEvent "UserRegistered" (Aeson.object [])]
                threadDelay 200_000
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n >= 2
                            then pure Stop
                            else pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "cat-sub-test"
                            , target = Category (CategoryName "order")
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                _ <- waitWithTimeout 10_000_000 handle
                collected <- readIORef ref
                length collected `shouldBe` 2
                -- All events should be order events
                mapM_ (\e -> (e ^. #eventType) `shouldSatisfy` (\(EventType t) -> T.isPrefixOf "Order" t)) collected

            it "cancels a running subscription cleanly" $ \store -> do
                let handler' _evt = pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "cancel-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                -- Give it time to start
                threadDelay 100_000
                cancel handle
                result <- waitWithTimeout 5_000_000 handle
                -- Should exit cleanly (AsyncCancelled or Right ())
                case result of
                    Left _timeout -> expectationFailure "Cancel did not terminate in time"
                    Right (Left _) -> pure () -- AsyncCancelled is expected
                    Right (Right ()) -> pure ()

            it "receives events appended to an initially empty store" $ \store -> do
                ref <- newIORef ([] :: [RecordedEvent])
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        pure Stop
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "empty-store-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                -- Give subscription time to start in live mode
                threadDelay 100_000
                -- Append one event
                Right _ <- runStoreIO store $ appendToStream (StreamName "empty-1") NoStream [makeEvent "First" (Aeson.object [])]
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 1

            it "handles rapid appends without losing events (debouncing)" $ \store -> do
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n >= 50
                            then pure Stop
                            else pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "debounce-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            }
                handle <- subscribe store cfg
                threadDelay 100_000
                -- Append 50 events rapidly to different streams
                mapM_
                    ( \i -> do
                        let sn = StreamName ("rapid-" <> T.pack (show (i :: Int)))
                        Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent ("R" <> T.pack (show i)) (Aeson.object [])]
                        pure ()
                    )
                    [1 .. 50]
                result <- waitWithTimeout 30_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 50

            it "catches up with an Eff-based handler via the effectful API" $ \store -> do
                -- Append 10 events
                let events = map (\i -> makeEvent ("Eff" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "eff-sub-1") NoStream events
                threadDelay 200_000
                -- Subscribe using the effectful API with an Eff-based handler
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                result <- runEff . runErrorNoCallStack @StoreError . runStorePool store . runSubscription store $ do
                    let effHandler :: (IOE :> es) => RecordedEvent -> Eff es SubscriptionResult
                        effHandler evt = do
                            liftIO $ modifyIORef' ref (evt :)
                            n <- liftIO $ atomically $ do
                                c <- readTVar countRef
                                let c' = c + 1
                                writeTVar countRef c'
                                pure c'
                            if n >= 10
                                then pure Stop
                                else pure Continue
                    let cfg =
                            SubscriptionConfig
                                { name = SubscriptionName "eff-catchup-test"
                                , target = AllStreams
                                , handler = effHandler
                                , batchSize = 100
                                }
                    handle <- SubEff.subscribe cfg
                    liftIO $ do
                        r <- waitWithTimeout 10_000_000 handle
                        case r of
                            Left timeout -> expectationFailure timeout
                            Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                            Right (Right ()) -> pure ()
                case result of
                    Left err -> expectationFailure ("Store error: " <> show err)
                    Right () -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 10

        -- =================================================================
        -- Shibuya adapter tests
        -- =================================================================
        describe "Shibuya adapter" $ do
            it "delivers catch-up events through Shibuya pipeline" $ \store -> do
                -- Append 10 events before starting the adapter
                let events = map (\i -> makeEvent ("CU" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "shibuya-catchup-1") NoStream events
                threadDelay 200_000

                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter
                            store
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "shibuya-catchup-test"
                                , subscriptionTarget = AllStreams
                                , batchSize = 100
                                , bufferSize = 256
                                }

                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (ingestedEvent ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk

                    res <- runApp IgnoreFailures 100 [(ProcessorId "catchup", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForCount countVar 10 10_000_000
                            stopApp appHandle

                collected <- readIORef ref
                length collected `shouldBe` 10

            it "delivers live events through Shibuya pipeline" $ \store -> do
                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter
                            store
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "shibuya-live-test"
                                , subscriptionTarget = AllStreams
                                , batchSize = 100
                                , bufferSize = 256
                                }

                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (ingestedEvent ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk

                    res <- runApp IgnoreFailures 100 [(ProcessorId "live", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            -- Give subscription time to start
                            liftIO $ threadDelay 200_000
                            -- Append 5 events while subscription is running
                            liftIO $ do
                                let events = map (\i -> makeEvent ("Live" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                                Right _ <- runStoreIO store $ appendToStream (StreamName "shibuya-live-1") NoStream events
                                pure ()
                            liftIO $ waitForCount countVar 5 10_000_000
                            stopApp appHandle

                collected <- readIORef ref
                length collected `shouldBe` 5

            it "runs multiple category subscriptions concurrently" $ \store -> do
                -- Append events to three categories
                Right _ <- runStoreIO store $ appendToStream (StreamName "orders-s1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "orders-s2") NoStream [makeEvent "OrderShipped" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "payments-s1") NoStream [makeEvent "PaymentReceived" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "inventory-s1") NoStream [makeEvent "StockUpdated" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "inventory-s2") NoStream [makeEvent "StockDepleted" (Aeson.object [])]
                threadDelay 200_000

                ordersRef <- newIORef ([] :: [RecordedEvent])
                paymentsRef <- newIORef ([] :: [RecordedEvent])
                inventoryRef <- newIORef ([] :: [RecordedEvent])
                ordersCount <- newTVarIO (0 :: Int)
                paymentsCount <- newTVarIO (0 :: Int)
                inventoryCount <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    let mkCatAdapter nm cat =
                            kirokuAdapter
                                store
                                KirokuAdapterConfig
                                    { subscriptionName = SubscriptionName nm
                                    , subscriptionTarget = Category (CategoryName cat)
                                    , batchSize = 100
                                    , bufferSize = 256
                                    }
                    let mkHandler ref' cVar ingested = do
                            liftIO $ do
                                modifyIORef' ref' (ingestedEvent ingested :)
                                atomically $ do
                                    c <- readTVar cVar
                                    writeTVar cVar (c + 1)
                            pure AckOk

                    ordersAdapter <- mkCatAdapter "orders-proj" "orders"
                    paymentsAdapter <- mkCatAdapter "payments-proj" "payments"
                    inventoryAdapter <- mkCatAdapter "inventory-proj" "inventory"

                    res <-
                        runApp
                            IgnoreFailures
                            100
                            [ (ProcessorId "orders", mkProcessor ordersAdapter (mkHandler ordersRef ordersCount))
                            , (ProcessorId "payments", mkProcessor paymentsAdapter (mkHandler paymentsRef paymentsCount))
                            , (ProcessorId "inventory", mkProcessor inventoryAdapter (mkHandler inventoryRef inventoryCount))
                            ]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ do
                                waitForCount ordersCount 2 10_000_000
                                waitForCount paymentsCount 1 10_000_000
                                waitForCount inventoryCount 2 10_000_000
                            stopApp appHandle

                ordersCollected <- readIORef ordersRef
                paymentsCollected <- readIORef paymentsRef
                inventoryCollected <- readIORef inventoryRef
                length ordersCollected `shouldBe` 2
                length paymentsCollected `shouldBe` 1
                length inventoryCollected `shouldBe` 2

            it "isolates a failing subscription from healthy ones" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "good-s1") NoStream (map (\i -> makeEvent ("Good" <> T.pack (show i)) (Aeson.object [])) [1 .. 3 :: Int])
                Right _ <- runStoreIO store $ appendToStream (StreamName "bad-s1") NoStream [makeEvent "Bad1" (Aeson.object []), makeEvent "Bad2" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "other-s1") NoStream [makeEvent "Other1" (Aeson.object []), makeEvent "Other2" (Aeson.object [])]
                threadDelay 200_000

                goodRef <- newIORef ([] :: [RecordedEvent])
                otherRef <- newIORef ([] :: [RecordedEvent])
                goodCount <- newTVarIO (0 :: Int)
                otherCount <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    goodAdapter <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "good-proj"
                                , subscriptionTarget = Category (CategoryName "good")
                                , batchSize = 100
                                , bufferSize = 256
                                }
                    badAdapter <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "bad-proj"
                                , subscriptionTarget = Category (CategoryName "bad")
                                , batchSize = 100
                                , bufferSize = 256
                                }
                    otherAdapter <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "other-proj"
                                , subscriptionTarget = Category (CategoryName "other")
                                , batchSize = 100
                                , bufferSize = 256
                                }

                    let goodHandler ingested = do
                            liftIO $ do
                                modifyIORef' goodRef (ingestedEvent ingested :)
                                atomically $ do
                                    c <- readTVar goodCount
                                    writeTVar goodCount (c + 1)
                            pure AckOk

                    let badHandler _ingested = do
                            liftIO $ error "handler crash!"

                    let otherHandler ingested = do
                            liftIO $ do
                                modifyIORef' otherRef (ingestedEvent ingested :)
                                atomically $ do
                                    c <- readTVar otherCount
                                    writeTVar otherCount (c + 1)
                            pure AckOk

                    res <-
                        runApp
                            IgnoreFailures
                            100
                            [ (ProcessorId "good", mkProcessor goodAdapter goodHandler)
                            , (ProcessorId "bad", mkProcessor badAdapter badHandler)
                            , (ProcessorId "other", mkProcessor otherAdapter otherHandler)
                            ]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ do
                                waitForCount goodCount 3 10_000_000
                                waitForCount otherCount 2 10_000_000
                                -- Give some time for the bad processor to fail
                                threadDelay 500_000
                            metrics <- getAppMetrics appHandle
                            -- The bad processor should be in Failed state
                            case Map.lookup (ProcessorId "bad") metrics of
                                Just m -> case m ^. #state of
                                    Failed _ _ -> pure ()
                                    other -> liftIO $ expectationFailure ("Expected Failed state, got: " <> show other)
                                Nothing -> liftIO $ expectationFailure "No metrics for bad processor"
                            stopApp appHandle

                goodCollected <- readIORef goodRef
                otherCollected <- readIORef otherRef
                length goodCollected `shouldBe` 3
                length otherCollected `shouldBe` 2

            it "shuts down all subscriptions coordinately" $ \store -> do
                -- Append events so adapters are actively processing
                Right _ <- runStoreIO store $ appendToStream (StreamName "shut-a") NoStream [makeEvent "A" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "shut-b") NoStream [makeEvent "B" (Aeson.object [])]
                threadDelay 200_000

                countA <- newTVarIO (0 :: Int)
                countB <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapterA <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "shut-a-proj"
                                , subscriptionTarget = Category (CategoryName "shut")
                                , batchSize = 100
                                , bufferSize = 256
                                }
                    adapterB <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "shut-b-proj"
                                , subscriptionTarget = Category (CategoryName "shut")
                                , batchSize = 100
                                , bufferSize = 256
                                }

                    let handlerA _ingested = do
                            liftIO $ atomically $ do
                                c <- readTVar countA
                                writeTVar countA (c + 1)
                            pure AckOk

                    let handlerB _ingested = do
                            liftIO $ atomically $ do
                                c <- readTVar countB
                                writeTVar countB (c + 1)
                            pure AckOk

                    res <-
                        runApp
                            IgnoreFailures
                            100
                            [ (ProcessorId "a", mkProcessor adapterA handlerA)
                            , (ProcessorId "b", mkProcessor adapterB handlerB)
                            ]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            -- Wait for processing to start
                            liftIO $ do
                                waitForCount countA 2 10_000_000
                                waitForCount countB 2 10_000_000
                            -- Graceful shutdown
                            drained <- stopAppGracefully Shibuya.defaultShutdownConfig appHandle
                            liftIO $ drained `shouldBe` True

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

-- | Wait until a TVar counter reaches a target value, with timeout (microseconds).
waitForCount :: STM.TVar Int -> Int -> Int -> IO ()
waitForCount countVar target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    result <-
        atomically $
            ( do
                c <- readTVar countVar
                STM.check (c >= target)
                pure True
            )
                `STM.orElse` ( do
                                t <- readTVar timeoutVar
                                STM.check t
                                pure False
                             )
    unless result $
        do
            actual <- atomically $ readTVar countVar
            expectationFailure ("Timed out waiting for count " <> show target <> ", got " <> show actual)

-- | Extract the RecordedEvent from a Shibuya Ingested value.
ingestedEvent :: Ingested es RecordedEvent -> RecordedEvent
ingestedEvent ing = let Ingested{envelope = env} = ing in env ^. #payload

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

{- | Wait for a subscription with a timeout (in microseconds).
Returns Left on timeout, or the subscription result.
-}
waitWithTimeout :: Int -> SubscriptionHandle -> IO (Either String (Either SomeException ()))
waitWithTimeout micros handle = do
    result <- Async.race (threadDelay micros) (wait handle)
    case result of
        Left () -> do
            cancel handle
            pure (Left "Subscription timed out")
        Right r -> pure (Right r)
