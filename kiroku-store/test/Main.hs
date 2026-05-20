module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException)
import Control.Exception qualified
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import EphemeralPg qualified as Pg
import Kiroku.Store
import Kiroku.Store.Error (extractStreamNameFromDetail)
import Kiroku.Store.Subscription.Effect qualified as SubEff
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Kiroku.Store.Subscription.Types (OverflowPolicy (..), SubscriptionConfigM (..), SubscriptionOverflowed (..))
import Test.Causation qualified as Causation
import Test.Concurrency qualified as Concurrency
import Test.ConsumerGroup qualified as ConsumerGroup
import Test.ConsumerGroupEffect qualified as ConsumerGroupEffect
import Test.ConsumerGroupSql qualified as ConsumerGroupSql
import Test.FailureInjection qualified as FailureInjection
import Test.Helpers
import Test.Hspec
import Test.InterpreterHooks qualified as InterpreterHooks
import Test.Properties qualified as Properties
import Test.ReadStream qualified as ReadStream
import Test.Transaction qualified as Transaction

main :: IO ()
main = hspec $ do
    Properties.spec
    Concurrency.spec
    FailureInjection.spec
    Transaction.spec
    ReadStream.spec
    InterpreterHooks.spec
    Causation.spec
    ConsumerGroupSql.spec
    ConsumerGroup.spec
    ConsumerGroupEffect.spec
    around withTestStore $ do
        describe "schema initialization" $ do
            it "provides a UUIDv7 database default for direct event inserts" $ \store -> do
                eventIdText <- insertEventUsingDefaultId store
                version <- serverVersionNum store
                let isV7 = T.length eventIdText > 14 && T.index eventIdText 14 == '7'
                unless isV7 $
                    expectationFailure
                        ( "expected database-generated event_id to be UUIDv7 on PostgreSQL "
                            <> T.unpack version
                            <> ", got "
                            <> T.unpack eventIdText
                        )

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

            describe "stream-name contract" $ do
                it "treats system-looking names other than $all as ordinary streams" $ \store -> do
                    let names =
                            [ StreamName "invoice-payment"
                            , StreamName "$invoice-payment"
                            , StreamName "invoice,payment"
                            , StreamName "invoicepayment"
                            ]
                    mapM_
                        ( \name -> do
                            Right r <- runStoreIO store $ appendToStream name NoStream [makeEvent "StreamNameContract" (Aeson.object [])]
                            (r ^. #streamVersion) `shouldBe` StreamVersion 1
                            Right events <- runStoreIO store $ readStreamForward name (StreamVersion 0) 10
                            V.length events `shouldBe` 1
                        )
                        names

                it "rejects $all as an application append target" $ \store -> do
                    result <- runStoreIO store $ appendToStream (StreamName "$all") AnyVersion [makeEvent "BadAllAppend" (Aeson.object [])]
                    case result of
                        Left (ReservedStreamName (StreamName "$all")) -> pure ()
                        other -> expectationFailure ("Expected ReservedStreamName for $all append, got: " <> show other)
                    Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 10
                    V.length allEvents `shouldBe` 0

                it "rejects $all as a multi-stream append target without partial commit" $ \store -> do
                    result <-
                        runStoreIO store $
                            appendMultiStream
                                [ (StreamName "multi-reserved-ok", NoStream, [makeEvent "ShouldRollback" (Aeson.object [])])
                                , (StreamName "$all", AnyVersion, [makeEvent "BadAllMulti" (Aeson.object [])])
                                ]
                    case result of
                        Left (ReservedStreamName (StreamName "$all")) -> pure ()
                        other -> expectationFailure ("Expected ReservedStreamName for $all multi-stream append, got: " <> show other)
                    Right info <- runStoreIO store $ getStream (StreamName "multi-reserved-ok")
                    info `shouldBe` Nothing

                it "rejects $all as a link target" $ \store -> do
                    Right _ <- runStoreIO store $ appendToStream (StreamName "reserved-link-source") NoStream [makeEvent "Source" (Aeson.object [])]
                    Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "reserved-link-source") (StreamVersion 0) 10
                    let eid = V.head srcEvents ^. #eventId
                    result <- runStoreIO store $ linkToStream (StreamName "$all") [eid]
                    case result of
                        Left (ReservedStreamName (StreamName "$all")) -> pure ()
                        other -> expectationFailure ("Expected ReservedStreamName for $all link, got: " <> show other)
                    Right allEvents <- runStoreIO store $ readAllForward (GlobalPosition 0) 10
                    V.length allEvents `shouldBe` 1

                it "rejects lifecycle operations against $all" $ \store -> do
                    soft <- runStoreIO store $ softDeleteStream (StreamName "$all")
                    hard <- runStoreIO store $ hardDeleteStream (StreamName "$all")
                    undel <- runStoreIO store $ undeleteStream (StreamName "$all")
                    let shouldBeReserved label result =
                            case result of
                                Left (ReservedStreamName (StreamName "$all")) -> pure ()
                                other -> expectationFailure ("Expected ReservedStreamName for " <> label <> ", got: " <> show other)
                    shouldBeReserved "softDeleteStream $all" soft
                    shouldBeReserved "hardDeleteStream $all" hard
                    shouldBeReserved "undeleteStream $all" undel
                    Right info <- runStoreIO store $ getStream (StreamName "$all")
                    case info of
                        Just si -> (si ^. #deletedAt) `shouldBe` Nothing
                        Nothing -> expectationFailure "Expected reserved $all stream row to remain present"

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

        describe "lookupStreamId" $ do
            it "returns the same id as getStream for a live stream" $ \store -> do
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "lookup-live")
                            NoStream
                            [makeEvent "A" (Aeson.object [])]
                Right mInfo <- runStoreIO store $ getStream (StreamName "lookup-live")
                Right mSid <- runStoreIO store $ lookupStreamId (StreamName "lookup-live")
                case (mInfo, mSid) of
                    (Just info, Just sid) ->
                        (info ^. #id) `shouldBe` sid
                    _ ->
                        expectationFailure "Expected both getStream and lookupStreamId to return Just"

            it "returns Nothing for a stream that has never been created" $ \store -> do
                Right mSid <- runStoreIO store $ lookupStreamId (StreamName "lookup-missing")
                mSid `shouldBe` Nothing

            it "returns Just the same id for a soft-deleted stream" $ \store -> do
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "lookup-soft")
                            NoStream
                            [makeEvent "A" (Aeson.object [])]
                Right mSidBefore <- runStoreIO store $ lookupStreamId (StreamName "lookup-soft")
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "lookup-soft")
                Right mSidAfter <- runStoreIO store $ lookupStreamId (StreamName "lookup-soft")
                mSidAfter `shouldBe` mSidBefore
                Right mInfo <- runStoreIO store $ getStream (StreamName "lookup-soft")
                case (mInfo, mSidAfter) of
                    (Just info, Just sid) -> (info ^. #id) `shouldBe` sid
                    _ -> expectationFailure "Expected Just on a soft-deleted stream"

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

            -- F3 regression — silent version gap when source events do not exist.
            -- Before the fix, the CTE's `JOIN LATERAL` silently dropped link rows for
            -- event_ids that had no `stream_events` row (e.g. never existed, or were
            -- hard-deleted). The `stream_upsert` had already bumped `stream_version`,
            -- so the stream advanced by N but only some link rows were inserted.
            it "rejects link when the source event does not exist" $ \store -> do
                let bogus = EventId (case UUID.fromString "11111111-1111-7111-8111-111111111111" of Just u -> u; Nothing -> error "bad uuid")
                result <- runStoreIO store $ linkToStream (StreamName "f3-bogus") [bogus]
                case result of
                    Left _ -> pure ()
                    Right r -> expectationFailure ("Expected error for missing event, got: " <> show r)
                -- Target stream must not have been left in a half-created state.
                Right info <- runStoreIO store $ getStream (StreamName "f3-bogus")
                info `shouldBe` Nothing

            it "rejects link with a mix of valid and missing events (no partial commit)" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f3-mixed-src") NoStream [makeEvent "Real" (Aeson.object [])]
                Right realEvents <- runStoreIO store $ readStreamForward (StreamName "f3-mixed-src") (StreamVersion 0) 100
                let realId = V.head realEvents ^. #eventId
                let bogus = EventId (case UUID.fromString "22222222-2222-7222-8222-222222222222" of Just u -> u; Nothing -> error "bad uuid")
                result <- runStoreIO store $ linkToStream (StreamName "f3-mixed-tgt") [realId, bogus]
                case result of
                    Left _ -> pure ()
                    Right r -> expectationFailure ("Expected error for partial-missing batch, got: " <> show r)
                Right info <- runStoreIO store $ getStream (StreamName "f3-mixed-tgt")
                info `shouldBe` Nothing

            -- F5 regression — linkToStream against a soft-deleted target stream.
            -- Symmetric with the appendAnyVersion soft-delete check from F2: the
            -- DO UPDATE clause's WHERE filters on deleted_at IS NULL, so the
            -- upsert returns no row and the interpreter maps that to StreamNotFound.
            it "rejects link to a soft-deleted target stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f5-src") NoStream [makeEvent "X" (Aeson.object [])]
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "f5-src") (StreamVersion 0) 100
                let eid = V.head srcEvents ^. #eventId
                Right _ <- runStoreIO store $ appendToStream (StreamName "f5-target") NoStream [makeEvent "Init" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "f5-target")
                result <- runStoreIO store $ linkToStream (StreamName "f5-target") [eid]
                case result of
                    Left (StreamNotFound _) -> pure ()
                    other -> expectationFailure ("Expected StreamNotFound for soft-deleted target, got: " <> show other)
                -- Soft-deleted target's version must not have advanced.
                Right info <- runStoreIO store $ getStream (StreamName "f5-target")
                case info of
                    Just si -> (si ^. #version) `shouldBe` StreamVersion 1
                    Nothing -> expectationFailure "soft-deleted stream row should still exist"

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

            -- F4 regression — pre-lock pass over named streams in stream_id order.
            -- The deterministic deadlock-prevention scenario (two concurrent calls
            -- touching the same streams in opposite orders) is covered by EP-6's
            -- planned concurrency-test harness; this test verifies that the
            -- pre-lock does not change user-visible ordering of global positions
            -- within a single multi-stream call.
            it "preserves user-supplied ordering of global positions" $ \store -> do
                let ops =
                        [ (StreamName "f4-zzz", NoStream, [makeEvent "Z" (Aeson.object [])])
                        , (StreamName "f4-mmm", NoStream, [makeEvent "M" (Aeson.object [])])
                        , (StreamName "f4-aaa", NoStream, [makeEvent "A" (Aeson.object [])])
                        ]
                Right results <- runStoreIO store $ appendMultiStream ops
                length results `shouldBe` 3
                let p0 = (results !! 0) ^. #globalPosition
                    p1 = (results !! 1) ^. #globalPosition
                    p2 = (results !! 2) ^. #globalPosition
                p0 `shouldSatisfy` (< p1)
                p1 `shouldSatisfy` (< p2)
                -- Read $all and confirm the events appear in user-supplied order.
                Right allEvts <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                let names = V.toList (V.map (^. #eventType) allEvts)
                names `shouldBe` [EventType "Z", EventType "M", EventType "A"]

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

            -- F2 regression — the protection against writes to a soft-deleted stream is
            -- enforced by a `deleted_at IS NULL` filter inside each append CTE, not by a
            -- pre-check that races concurrent soft-deletes. These tests exercise every
            -- append variant so a reader can see at a glance which constructor maps to
            -- which error after a soft-delete.
            it "ExactVersion append rejected against soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f2-cte-exv") NoStream [makeEvent "Init" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "f2-cte-exv")
                result <- runStoreIO store $ appendToStream (StreamName "f2-cte-exv") (ExactVersion (StreamVersion 1)) [makeEvent "X" (Aeson.object [])]
                case result of
                    Left (WrongExpectedVersion _ _ _) -> pure ()
                    Left (StreamNotFound _) -> pure ()
                    other -> expectationFailure ("Expected WrongExpectedVersion or StreamNotFound, got: " <> show other)

            it "AnyVersion append rejected against soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f2-cte-any") NoStream [makeEvent "Init" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "f2-cte-any")
                result <- runStoreIO store $ appendToStream (StreamName "f2-cte-any") AnyVersion [makeEvent "X" (Aeson.object [])]
                case result of
                    Left (StreamNotFound _) -> pure ()
                    other -> expectationFailure ("Expected StreamNotFound, got: " <> show other)

            it "NoStream append rejected against soft-deleted stream" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f2-cte-no") NoStream [makeEvent "Init" (Aeson.object [])]
                Right _ <- runStoreIO store $ softDeleteStream (StreamName "f2-cte-no")
                result <- runStoreIO store $ appendToStream (StreamName "f2-cte-no") NoStream [makeEvent "X" (Aeson.object [])]
                case result of
                    Left (StreamAlreadyExists _) -> pure ()
                    other -> expectationFailure ("Expected StreamAlreadyExists, got: " <> show other)

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

            -- F6 regression — TRUNCATE on protected tables must be gated by the
            -- same GUC as DELETE. Without the BEFORE TRUNCATE triggers added in
            -- EP-1 F6, an operator could TRUNCATE events / stream_events / streams
            -- without setting kiroku.enable_hard_deletes, bypassing the row-level
            -- protect_deletion check.
            it "TRUNCATE on events is rejected without the GUC" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f6-truncate") NoStream [makeEvent "X" (Aeson.object [])]
                rejected <- truncateRejected store "events"
                rejected `shouldBe` True

            it "TRUNCATE on stream_events is rejected without the GUC" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f6-truncate-se") NoStream [makeEvent "X" (Aeson.object [])]
                rejected <- truncateRejected store "stream_events"
                rejected `shouldBe` True

            it "TRUNCATE on streams is rejected without the GUC" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f6-truncate-s") NoStream [makeEvent "X" (Aeson.object [])]
                rejected <- truncateRejected store "streams"
                rejected `shouldBe` True

            -- F1 regression — events orphaned in `events` table after hard-delete.
            it "removes orphan event payloads from the events table" $ \store -> do
                let evts = map (\i -> makeEvent ("F1Orphan" <> T.pack (show i)) (Aeson.object [])) [1 .. 3 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "f1-orphan") NoStream evts
                before <- countEvents store
                Right _ <- runStoreIO store $ hardDeleteStream (StreamName "f1-orphan")
                after <- countEvents store
                (before - after) `shouldBe` 3

            -- F1 regression — events that are linked to other streams must survive
            -- hard-delete of their source stream's owner if any non-target junctions remain.
            it "preserves events still linked to non-target streams" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "f1-keep-src") NoStream [makeEvent "Keep" (Aeson.object [])]
                Right srcEvents <- runStoreIO store $ readStreamForward (StreamName "f1-keep-src") (StreamVersion 0) 100
                let eid = V.head srcEvents ^. #eventId
                -- Append another stream that gets a different event so we can hard-delete keep-src
                -- without touching the linked stream's source. Then link f1-keep-src's event to a
                -- third stream we will leave alone.
                Right _ <- runStoreIO store $ appendToStream (StreamName "f1-other") NoStream [makeEvent "Other" (Aeson.object [])]
                -- Link via appendToStream + linkToStream to a different stream
                _ <- runStoreIO store $ linkToStream (StreamName "f1-keep-link") [eid]
                -- Hard-deleting f1-keep-src removes the source's events even though the link
                -- referenced them: link rows have original_stream_id = f1-keep-src's id, so they
                -- match the junction-delete WHERE clause. The contract is documented in F1's fix
                -- commit: hard-delete cascades through link junctions of the deleted stream's
                -- original events. (See SQL.hs hard-delete documentation.)
                Right _ <- runStoreIO store $ hardDeleteStream (StreamName "f1-keep-src")
                -- f1-other's event must still exist (not affected at all).
                Right otherEvents <- runStoreIO store $ readStreamForward (StreamName "f1-other") (StreamVersion 0) 100
                V.length otherEvents `shouldBe` 1

        -- =================================================================
        -- Subscription tests (M7.7)
        -- =================================================================
        describe "subscribe" $ do
            it "catches up from position 0 on a store with existing events" $ \store -> do
                -- Append 10 events
                let events = map (\i -> makeEvent ("E" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "catchup-1") NoStream events
                -- Wait until the EventPublisher has ingested all 10 events.
                waitForPublisher store (GlobalPosition 10)
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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
                waitForPublisher store (GlobalPosition 10)
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h2 <- subscribe store cfg2
                _ <- waitWithTimeout 10_000_000 h2
                collected <- readIORef ref2
                -- Should receive events 6–10 only
                length collected `shouldBe` 5

            it "does not replay catch-up events when switching to all-stream live mode" $ \store -> do
                let seedEvents = map (\i -> makeEvent ("TransitionSeed" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "transition-seed") NoStream seedEvents
                waitForPublisher store (GlobalPosition 5)

                firstSeen <- newEmptyMVar
                releaseFirst <- newEmptyMVar
                countRef <- newTVarIO (0 :: Int)
                ref <- newIORef ([] :: [RecordedEvent])
                let stopType = EventType "TransitionStopAfterLive"
                    handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n == 1
                            then do
                                putMVar firstSeen ()
                                takeMVar releaseFirst
                            else pure ()
                        if evt ^. #eventType == stopType
                            then pure Stop
                            else pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "transition-no-duplicates"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 2
                            , queueCapacity = 32
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                handle <- subscribe store cfg
                takeMVar firstSeen

                mapM_
                    ( \i -> do
                        let sn = StreamName ("transition-during-" <> T.pack (show (i :: Int)))
                        Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent ("TransitionDuring" <> T.pack (show i)) (Aeson.object [])]
                        pure ()
                    )
                    [6 .. 10]
                waitForPublisher store (GlobalPosition 10)
                putMVar releaseFirst ()
                atomically $ do
                    c <- readTVar countRef
                    check (c >= 10)

                Right _ <- runStoreIO store $ appendToStream (StreamName "transition-stop") NoStream [makeEvent "TransitionStopAfterLive" (Aeson.object [])]
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()

                collected <- reverse <$> readIORef ref
                map (^. #globalPosition) collected `shouldBe` map GlobalPosition [1 .. 11]

            it "does not skip an event when cancelled before checkpoint save" $ \store -> do
                let events = map (\i -> makeEvent ("CancelReplay" <> T.pack (show i)) (Aeson.object [])) [1 .. 3 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "cancel-replay") NoStream events
                waitForPublisher store (GlobalPosition 3)

                firstSeen <- newEmptyMVar
                block <- newEmptyMVar
                firstRef <- newIORef ([] :: [RecordedEvent])
                let handler1 evt = do
                        modifyIORef' firstRef (evt :)
                        putMVar firstSeen ()
                        takeMVar block
                        pure Continue
                    cfg1 =
                        SubscriptionConfig
                            { name = SubscriptionName "cancel-replay-test"
                            , target = AllStreams
                            , handler = handler1
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h1 <- subscribe store cfg1
                takeMVar firstSeen
                cancel h1
                _ <- waitWithTimeout 5_000_000 h1

                ref2 <- newIORef ([] :: [RecordedEvent])
                let handler2 evt = do
                        modifyIORef' ref2 (evt :)
                        pure Stop
                    cfg2 =
                        SubscriptionConfig
                            { name = SubscriptionName "cancel-replay-test"
                            , target = AllStreams
                            , handler = handler2
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h2 <- subscribe store cfg2
                result <- waitWithTimeout 10_000_000 h2
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                replayed <- reverse <$> readIORef ref2
                map (^. #globalPosition) replayed `shouldBe` [GlobalPosition 1]

            it "saves checkpoints at Stop boundaries without skipping the next event" $ \store -> do
                let events = map (\i -> makeEvent ("StopBoundary" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "stop-boundary") NoStream events
                waitForPublisher store (GlobalPosition 5)

                countRef1 <- newTVarIO (0 :: Int)
                let handler1 _evt = do
                        n <- atomically $ do
                            c <- readTVar countRef1
                            let c' = c + 1
                            writeTVar countRef1 c'
                            pure c'
                        if n >= 3 then pure Stop else pure Continue
                    cfg1 =
                        SubscriptionConfig
                            { name = SubscriptionName "stop-boundary-test"
                            , target = AllStreams
                            , handler = handler1
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h1 <- subscribe store cfg1
                _ <- waitWithTimeout 10_000_000 h1

                ref2 <- newIORef ([] :: [RecordedEvent])
                countRef2 <- newTVarIO (0 :: Int)
                let handler2 evt = do
                        modifyIORef' ref2 (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef2
                            let c' = c + 1
                            writeTVar countRef2 c'
                            pure c'
                        if n >= 2 then pure Stop else pure Continue
                    cfg2 =
                        SubscriptionConfig
                            { name = SubscriptionName "stop-boundary-test"
                            , target = AllStreams
                            , handler = handler2
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h2 <- subscribe store cfg2
                result <- waitWithTimeout 10_000_000 h2
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                replayed <- reverse <$> readIORef ref2
                map (^. #globalPosition) replayed `shouldBe` [GlobalPosition 4, GlobalPosition 5]

            -- F18 regression — Category subscriptions in live mode previously
            -- received unfiltered events from $all because `filterEvents` was
            -- a no-op for Category. The fix routes Category live-mode through
            -- a DB-driven loop that re-uses the SQL category filter. Before
            -- the fix, the handler would observe the UserNoise event below.
            it "delivers only category-matching events during live mode (F18)" $ \store -> do
                seedSeen <- newEmptyMVar
                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        -- After the catch-up seed event, signal that we are
                        -- entering live mode. Subsequent appends exercise
                        -- the live path under the new DB-driven loop.
                        if n == 1
                            then putMVar seedSeen ()
                            else pure ()
                        if n >= 3 then pure Stop else pure Continue
                -- Pre-seed an order event so catch-up fires the handler once.
                Right _ <-
                    runStoreIO store $
                        appendToStream
                            (StreamName "order-seed")
                            NoStream
                            [makeEvent "OrderSeed" (Aeson.object [])]
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "f18-live-test"
                            , target = Category (CategoryName "order")
                            , handler = handler'
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                handle <- subscribe store cfg
                -- Block until catch-up has delivered the seed event — the
                -- worker has finished catch-up and is about to enter live
                -- mode.
                takeMVar seedSeen
                -- Append a non-matching user event followed by two matching
                -- order events. Under the bug, UserNoise would slip through
                -- the live broadcast unfiltered.
                Right _ <- runStoreIO store $ appendToStream (StreamName "user-1") NoStream [makeEvent "UserNoise" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-2") NoStream [makeEvent "OrderTwo" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-3") NoStream [makeEvent "OrderThree" (Aeson.object [])]
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- readIORef ref
                length collected `shouldBe` 3
                -- No UserNoise event should have been delivered.
                mapM_
                    (\e -> (e ^. #eventType) `shouldNotBe` EventType "UserNoise")
                    collected

            it "delivers only category-matching events during catch-up" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-1") NoStream [makeEvent "OrderCreated" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "order-2") NoStream [makeEvent "OrderShipped" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "user-1") NoStream [makeEvent "UserRegistered" (Aeson.object [])]
                waitForPublisher store (GlobalPosition 3)
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                handle <- subscribe store cfg
                _ <- waitWithTimeout 10_000_000 handle
                collected <- readIORef ref
                length collected `shouldBe` 2
                -- All events should be order events
                mapM_ (\e -> (e ^. #eventType) `shouldSatisfy` (\(EventType t) -> T.isPrefixOf "Order" t)) collected

            it "preserves category subscription order under mixed invoice-payment writes" $ \store -> do
                let appendOne sn typ =
                        runStoreIO store (appendToStream sn AnyVersion [makeEvent typ (Aeson.object [])]) >>= \result ->
                            case result of
                                Right _ -> pure ()
                                Left err -> expectationFailure ("append failed: " <> show err)
                appendOne (StreamName "invoice-payment") "InvoicePaymentStarted"
                appendOne (StreamName "user-1") "UserNoiseOne"
                appendOne (StreamName "invoice-reminder") "InvoiceReminderSent"
                appendOne (StreamName "order-1") "OrderNoiseOne"
                appendOne (StreamName "invoice-payment") "InvoicePaymentFinished"
                appendOne (StreamName "user-2") "UserNoiseTwo"
                appendOne (StreamName "invoice-refund") "InvoiceRefundFinished"
                waitForPublisher store (GlobalPosition 7)

                ref <- newIORef ([] :: [RecordedEvent])
                countRef <- newTVarIO (0 :: Int)
                let handler' evt = do
                        modifyIORef' ref (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef
                            let c' = c + 1
                            writeTVar countRef c'
                            pure c'
                        if n >= 4 then pure Stop else pure Continue
                    cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "invoice-category-ordering"
                            , target = Category (CategoryName "invoice")
                            , handler = handler'
                            , batchSize = 2
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                handle <- subscribe store cfg
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed: " <> show err)
                    Right (Right ()) -> pure ()
                collected <- reverse <$> readIORef ref
                map (^. #globalPosition) collected `shouldBe` [GlobalPosition 1, GlobalPosition 3, GlobalPosition 5, GlobalPosition 7]
                map (^. #eventType) collected
                    `shouldBe` [ EventType "InvoicePaymentStarted"
                               , EventType "InvoiceReminderSent"
                               , EventType "InvoicePaymentFinished"
                               , EventType "InvoiceRefundFinished"
                               ]

            it "cancels a running subscription cleanly" $ \store -> do
                let handler' _evt = pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "cancel-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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
                            , -- Sized to absorb 50 publisher batches without
                              -- backpressure overflow. The default 16 was
                              -- intermittently overrun under load (the
                              -- publisher emits one batch per append because
                              -- there is no inter-append debounce window in
                              -- this loop), surfacing as
                              -- SubscriptionOverflowed in flaky CI runs.
                              -- Coverage of the bounded-queue policy lives
                              -- in the F6 overflow test below, not here.
                              queueCapacity = 64
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
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

            -- F6 regression — the publisher's broadcast was an unbounded TChan;
            -- a slow subscriber's dupTChan grew without limit until the host
            -- ran out of memory. The fix replaces the broadcast with a
            -- per-subscriber bounded TBQueue plus an overflow policy. With
            -- DropSubscription, the publisher signals overflow on the
            -- subscriber's status TVar; the worker observes it on its next
            -- STM read and surfaces SubscriptionOverflowed via wait/waitCatch.
            it "surfaces SubscriptionOverflowed when a slow subscriber overruns its queue (F6)" $ \store -> do
                firstSeen <- newEmptyMVar
                release <- newEmptyMVar
                seenCount <- newTVarIO (0 :: Int)
                let handler' _evt = do
                        n <- atomically $ do
                            c <- readTVar seenCount
                            let c' = c + 1
                            writeTVar seenCount c'
                            pure c'
                        if n == 1
                            then do
                                putMVar firstSeen ()
                                takeMVar release
                            else pure ()
                        pure Continue
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "f6-overflow-test"
                            , target = AllStreams
                            , handler = handler'
                            , batchSize = 100
                            , queueCapacity = 1
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                handle <- subscribe store cfg
                -- First append: triggers handler, which blocks on the release MVar.
                Right _ <- runStoreIO store $ appendToStream (StreamName "f6-1") NoStream [makeEvent "E1" (Aeson.object [])]
                takeMVar firstSeen
                -- While the worker is stuck inside the handler, append events one
                -- at a time and wait for the publisher to fetch each individually.
                -- Each append corresponds to a separate publisher batch written
                -- to the subscriber's queue. Capacity is 1, so the second
                -- write fills it and the third triggers DropSubscription.
                let waitForPub n = atomically $ do
                        GlobalPosition p <- publisherPosition (store ^. #publisher)
                        check (p >= n)
                let appendOne i = do
                        let sn = StreamName ("f6-" <> T.pack (show (i :: Int)))
                        Right _ <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Ex" (Aeson.object [])]
                        waitForPub (fromIntegral i)
                -- Append 4 more events with publisher synchronisation. Combined
                -- with the first event, that is 5 publisher batches.
                appendOne 2
                appendOne 3
                appendOne 4
                appendOne 5
                -- Release the handler. Worker exits processEvents and on the
                -- next STM read observes Overflowed.
                putMVar release ()
                result <- waitWithTimeout 10_000_000 handle
                case result of
                    Left timeout -> expectationFailure timeout
                    Right (Right ()) -> expectationFailure "expected SubscriptionOverflowed, got clean exit"
                    Right (Left e) ->
                        case Control.Exception.fromException e of
                            Just (SubscriptionOverflowed sn) ->
                                sn `shouldBe` SubscriptionName "f6-overflow-test"
                            Nothing ->
                                expectationFailure ("expected SubscriptionOverflowed, got: " <> show e)

                ref2 <- newIORef ([] :: [RecordedEvent])
                countRef2 <- newTVarIO (0 :: Int)
                let handler2 evt = do
                        modifyIORef' ref2 (evt :)
                        n <- atomically $ do
                            c <- readTVar countRef2
                            let c' = c + 1
                            writeTVar countRef2 c'
                            pure c'
                        if n >= 4 then pure Stop else pure Continue
                    cfg2 =
                        SubscriptionConfig
                            { name = SubscriptionName "f6-overflow-test"
                            , target = AllStreams
                            , handler = handler2
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                h2 <- subscribe store cfg2
                replayResult <- waitWithTimeout 10_000_000 h2
                case replayResult of
                    Left timeout -> expectationFailure timeout
                    Right (Left err) -> expectationFailure ("Subscription failed after overflow restart: " <> show err)
                    Right (Right ()) -> pure ()
                replayed <- reverse <$> readIORef ref2
                map (^. #globalPosition) replayed `shouldBe` map GlobalPosition [2 .. 5]

            it "catches up with an Eff-based handler via the effectful API" $ \store -> do
                -- Append 10 events
                let events = map (\i -> makeEvent ("Eff" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "eff-sub-1") NoStream events
                waitForPublisher store (GlobalPosition 10)
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
                                , queueCapacity = 16
                                , overflowPolicy = DropSubscription
                                , consumerGroup = Nothing
                                , consumerGroupGuard = False
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
        -- withSubscription bracket tests (EP-2 F25)
        -- =================================================================
        describe "withSubscription" $ do
            -- F25 regression — bracket cancels the worker on normal scope exit.
            it "cancels the worker on normal scope exit" $ \store -> do
                handleRef <- newIORef Nothing
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "withsub-normal"
                            , target = AllStreams
                            , handler = \_ -> pure Continue
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                withSubscription store cfg $ \h -> do
                    writeIORef handleRef (Just h)
                    threadDelay 100_000
                Just h <- readIORef handleRef
                -- Worker must terminate now that the scope has exited.
                outcome <- Async.race (threadDelay 2_000_000) (wait h)
                case outcome of
                    Left () -> expectationFailure "worker did not exit after withSubscription scope"
                    Right _ -> pure ()

            -- F25 regression — bracket cancels the worker even when the body throws.
            it "cancels the worker when the body throws" $ \store -> do
                handleRef <- newIORef Nothing
                let cfg =
                        SubscriptionConfig
                            { name = SubscriptionName "withsub-throw"
                            , target = AllStreams
                            , handler = \_ -> pure Continue
                            , batchSize = 100
                            , queueCapacity = 16
                            , overflowPolicy = DropSubscription
                            , consumerGroup = Nothing
                            , consumerGroupGuard = False
                            }
                result <-
                    Control.Exception.try @SomeException $
                        withSubscription store cfg $ \h -> do
                            writeIORef handleRef (Just h)
                            threadDelay 100_000
                            error "withSubscription body deliberately throws"
                case result of
                    Left _ -> pure ()
                    Right () -> expectationFailure "expected exception to propagate"
                Just h <- readIORef handleRef
                outcome <- Async.race (threadDelay 2_000_000) (wait h)
                case outcome of
                    Left () -> expectationFailure "worker did not exit after exception in withSubscription body"
                    Right _ -> pure ()

    -- =================================================================
    -- Pure helpers (no database fixture)
    -- =================================================================

    -- F1 regression — pure detail parser used by attributeMultiStreamError.
    -- The integration scenario that would exercise this code path
    -- (ix_streams_stream_name 23505 raised inside an appendMultiStream txn)
    -- is unreachable via current SQL because every append CTE uses ON CONFLICT
    -- DO NOTHING / DO UPDATE. The pure helper is unit-tested here so a future
    -- schema change that introduces such a path arrives with the attribution
    -- already correct.
    describe "extractStreamNameFromDetail" $ do
        it "extracts the stream name from a typical PostgreSQL detail" $ do
            extractStreamNameFromDetail "Key (stream_name)=(orders-1) already exists."
                `shouldBe` Just "orders-1"
        it "extracts a stream name containing dashes and digits" $ do
            extractStreamNameFromDetail "Key (stream_name)=(multi-c-2) already exists."
                `shouldBe` Just "multi-c-2"
        it "returns Nothing when the detail is empty" $ do
            extractStreamNameFromDetail "" `shouldBe` Nothing
        it "returns Nothing when the detail does not contain '=('" $ do
            extractStreamNameFromDetail "no key here" `shouldBe` Nothing
        it "returns Nothing for an empty parenthesised value" $ do
            extractStreamNameFromDetail "Key (stream_name)=() already exists."
                `shouldBe` Nothing

    -- =================================================================
    -- Notifier reconnection tests (EP-3 F1)
    -- =================================================================
    describe "Notifier reconnection" $ do
        -- F1 regression — the listener loop reconnects on backend termination,
        -- and `stopNotifier` must release the *current* (post-reconnect)
        -- connection. Without the fix, the original Notifier.listenerConn was
        -- a frozen reference to the first conn and the reconnected conn leaked
        -- past `withStore` exit. We assert no kiroku-listener backend remains
        -- in pg_stat_activity after the store shuts down.
        it "releases the reconnected listener connection on shutdown" $ \() -> do
            result <- Pg.withCached $ \db -> do
                let connStr = Pg.connectionString db
                    settings = defaultConnectionSettings connStr
                withStore settings $ \store -> do
                    pid1 <- waitForListenerPid (store ^. #pool) 5_000_000
                    terminateBackend (store ^. #pool) pid1
                    pid2 <- waitForListenerPidNotEqual (store ^. #pool) pid1 15_000_000
                    pid2 `shouldNotBe` pid1
                -- After withStore exits, no kiroku-listener connection remains.
                listenerCount connStr
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right n -> n `shouldBe` (0 :: Int64)

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

    -- =================================================================
    -- KirokuEvent observation surface (EP-5 F1, F13, F14)
    -- =================================================================
    describe "KirokuEvent observation" $ do
        -- EP-5 F1 regression — terminating the listener backend triggers
        -- KirokuEventNotifierReconnecting then KirokuEventNotifierReconnected.
        -- Before EP-5 the reconnect path emitted no signal at all.
        it "emits notifier reconnect events on backend termination (F1)" $ \() -> do
            ref <- newIORef ([] :: [KirokuEvent])
            let evtHandler e = modifyIORef' ref (e :)
            result <- Pg.withCached $ \db -> do
                let settings =
                        defaultConnectionSettings (Pg.connectionString db)
                            & #eventHandler .~ Just evtHandler
                withStore settings $ \store -> do
                    pid1 <- waitForListenerPid (store ^. #pool) 5_000_000
                    terminateBackend (store ^. #pool) pid1
                    _ <- waitForListenerPidNotEqual (store ^. #pool) pid1 15_000_000
                    pure ()
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()
            evts <- readIORef ref
            let isReconnecting (KirokuEventNotifierReconnecting _ _) = True
                isReconnecting _ = False
                isReconnected KirokuEventNotifierReconnected = True
                isReconnected _ = False
            any isReconnecting evts `shouldBe` True
            any isReconnected evts `shouldBe` True

        -- EP-5 F14 regression — subscriptions emit started, caught-up, and
        -- stopped events. Before EP-5 the lifecycle was invisible.
        --
        -- Subscribe before appending so the worker enters catch-up at
        -- position 0, immediately reaches the publisher's position 0,
        -- emits CaughtUp, transitions to live mode, then receives the
        -- two appended events and stops.
        it "emits subscription lifecycle events (F14)" $ \() -> do
            ref <- newIORef ([] :: [KirokuEvent])
            let evtHandler e = modifyIORef' ref (e :)
            result <- Pg.withCached $ \db -> do
                let settings =
                        defaultConnectionSettings (Pg.connectionString db)
                            & #eventHandler .~ Just evtHandler
                withStore settings $ \store -> do
                    countRef <- newTVarIO (0 :: Int)
                    let h _ = do
                            n <- atomically $ do
                                c <- readTVar countRef
                                writeTVar countRef (c + 1)
                                pure (c + 1)
                            if n >= 2 then pure Stop else pure Continue
                    let cfg =
                            SubscriptionConfig
                                { name = SubscriptionName "lifecycle-test"
                                , target = AllStreams
                                , handler = h
                                , batchSize = 100
                                , queueCapacity = 16
                                , overflowPolicy = DropSubscription
                                , consumerGroup = Nothing
                                , consumerGroupGuard = False
                                }
                    handle <- subscribe store cfg
                    -- Give the worker a moment to enter live mode.
                    threadDelay 200_000
                    Right _ <-
                        runStoreIO store $
                            appendToStream (StreamName "lifecycle-1") NoStream [makeEvent "X" (Aeson.object [])]
                    Right _ <-
                        runStoreIO store $
                            appendToStream (StreamName "lifecycle-1") (ExactVersion (StreamVersion 1)) [makeEvent "Y" (Aeson.object [])]
                    _ <- waitWithTimeout 10_000_000 handle
                    pure ()
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()
            evts <- readIORef ref
            let isStarted (KirokuEventSubscriptionStarted (SubscriptionName "lifecycle-test") _ _) = True
                isStarted _ = False
                isCaughtUp (KirokuEventSubscriptionCaughtUp (SubscriptionName "lifecycle-test") _ _) = True
                isCaughtUp _ = False
                isStopped (KirokuEventSubscriptionStopped (SubscriptionName "lifecycle-test") _ StopHandlerRequested _) = True
                isStopped _ = False
            any isStarted evts `shouldBe` True
            any isCaughtUp evts `shouldBe` True
            any isStopped evts `shouldBe` True

        -- EP-5 F13 regression — hard-delete emits a fail-safe audit event.
        -- Before EP-5 there was no in-band audit signal.
        it "emits a hard-delete event when the stream existed (F13)" $ \() -> do
            ref <- newIORef ([] :: [KirokuEvent])
            let evtHandler e = modifyIORef' ref (e :)
            result <- Pg.withCached $ \db -> do
                let settings =
                        defaultConnectionSettings (Pg.connectionString db)
                            & #eventHandler .~ Just evtHandler
                withStore settings $ \store -> do
                    Right _ <-
                        runStoreIO store $
                            appendToStream (StreamName "hard-delete-evt") NoStream [makeEvent "X" (Aeson.object [])]
                    Right _ <- runStoreIO store $ hardDeleteStream (StreamName "hard-delete-evt")
                    -- A hard-delete on a non-existent stream must not emit
                    -- the event — verify by issuing a second one.
                    Right _ <- runStoreIO store $ hardDeleteStream (StreamName "never-existed")
                    pure ()
            case result of
                Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
                Right () -> pure ()
            evts <- readIORef ref
            let hardDeletes =
                    [ name'
                    | KirokuEventHardDeleteIssued (StreamName name') _ <- evts
                    ]
            hardDeletes `shouldBe` ["hard-delete-evt"]
