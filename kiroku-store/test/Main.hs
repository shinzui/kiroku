{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.UUID qualified as UUID
import EphemeralPg qualified as Pg
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Kiroku.Store
import Test.Hspec

main :: IO ()
main = hspec $ do
    around withTestStore $ do
        describe "appendToStream" $ do
            describe "NoStream" $ do
                it "creates a new stream and appends events" $ \store -> do
                    let event = makeEvent "OrderCreated" (Aeson.object [("orderId", Aeson.String "123")])
                    result <- appendToStream store (StreamName "order-123") NoStream [event]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            r.streamVersion `shouldBe` StreamVersion 1
                            r.globalPosition `shouldBe` GlobalPosition 1

                it "fails when stream already exists" $ \store -> do
                    let event = makeEvent "OrderCreated" (Aeson.object [])
                    _ <- appendToStream store (StreamName "order-456") NoStream [event]
                    let event2 = makeEvent "OrderUpdated" (Aeson.object [])
                    result <- appendToStream store (StreamName "order-456") NoStream [event2]
                    case result of
                        Left (StreamAlreadyExists _) -> pure ()
                        other -> expectationFailure ("Expected StreamAlreadyExists, got: " <> show other)

            describe "ExactVersion" $ do
                it "appends when version matches" $ \store -> do
                    let event1 = makeEvent "OrderCreated" (Aeson.object [])
                    Right r1 <- appendToStream store (StreamName "order-789") NoStream [event1]
                    r1.streamVersion `shouldBe` StreamVersion 1

                    let event2 = makeEvent "OrderUpdated" (Aeson.object [])
                    result <- appendToStream store (StreamName "order-789") (ExactVersion (StreamVersion 1)) [event2]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            r.streamVersion `shouldBe` StreamVersion 2
                            r.globalPosition `shouldBe` GlobalPosition 2

                it "fails on version conflict" $ \store -> do
                    let event1 = makeEvent "OrderCreated" (Aeson.object [])
                    _ <- appendToStream store (StreamName "order-conflict") NoStream [event1]

                    let event2 = makeEvent "OrderUpdated" (Aeson.object [])
                    result <- appendToStream store (StreamName "order-conflict") (ExactVersion (StreamVersion 0)) [event2]
                    case result of
                        Left (WrongExpectedVersion _ _ _) -> pure ()
                        other -> expectationFailure ("Expected WrongExpectedVersion, got: " <> show other)

            describe "StreamExists" $ do
                it "appends to an existing stream" $ \store -> do
                    let event1 = makeEvent "Created" (Aeson.object [])
                    _ <- appendToStream store (StreamName "stream-exists-test") NoStream [event1]

                    let event2 = makeEvent "Updated" (Aeson.object [])
                    result <- appendToStream store (StreamName "stream-exists-test") StreamExists [event2]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> r.streamVersion `shouldBe` StreamVersion 2

                it "fails when stream does not exist" $ \store -> do
                    let event = makeEvent "Created" (Aeson.object [])
                    result <- appendToStream store (StreamName "nonexistent-stream") StreamExists [event]
                    case result of
                        Left (StreamNotFound _) -> pure ()
                        other -> expectationFailure ("Expected StreamNotFound, got: " <> show other)

            describe "AnyVersion" $ do
                it "creates a new stream" $ \store -> do
                    let event = makeEvent "Created" (Aeson.object [])
                    result <- appendToStream store (StreamName "any-new") AnyVersion [event]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> r.streamVersion `shouldBe` StreamVersion 1

                it "appends to an existing stream" $ \store -> do
                    let event1 = makeEvent "Created" (Aeson.object [])
                    _ <- appendToStream store (StreamName "any-existing") AnyVersion [event1]

                    let event2 = makeEvent "Updated" (Aeson.object [])
                    result <- appendToStream store (StreamName "any-existing") AnyVersion [event2]
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> r.streamVersion `shouldBe` StreamVersion 2

            describe "batch append" $ do
                it "appends multiple events with sequential versions" $ \store -> do
                    let events =
                            [ makeEvent "Event1" (Aeson.object [("n", Aeson.Number 1)])
                            , makeEvent "Event2" (Aeson.object [("n", Aeson.Number 2)])
                            , makeEvent "Event3" (Aeson.object [("n", Aeson.Number 3)])
                            ]
                    result <- appendToStream store (StreamName "batch-test") NoStream events
                    case result of
                        Left err -> expectationFailure ("Expected success, got: " <> show err)
                        Right r -> do
                            r.streamVersion `shouldBe` StreamVersion 3
                            r.globalPosition `shouldBe` GlobalPosition 3

            describe "global position contiguity" $ do
                it "assigns contiguous global positions across streams" $ \store -> do
                    let event1 = makeEvent "A" (Aeson.object [])
                    Right r1 <- appendToStream store (StreamName "stream-a") NoStream [event1]
                    r1.globalPosition `shouldBe` GlobalPosition 1

                    let event2 = makeEvent "B" (Aeson.object [])
                    Right r2 <- appendToStream store (StreamName "stream-b") NoStream [event2]
                    r2.globalPosition `shouldBe` GlobalPosition 2

                    let event3 = makeEvent "C" (Aeson.object [])
                    Right r3 <- appendToStream store (StreamName "stream-c") NoStream [event3]
                    r3.globalPosition `shouldBe` GlobalPosition 3

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
                    Right _ <- appendToStream store (StreamName "dup-test-1") NoStream [event1]

                    let event2 =
                            EventData
                                { eventId = Just eid
                                , eventType = EventType "Created"
                                , payload = Aeson.object []
                                , metadata = Nothing
                                , causationId = Nothing
                                , correlationId = Nothing
                                }
                    result <- appendToStream store (StreamName "dup-test-2") NoStream [event2]
                    case result of
                        Left (DuplicateEvent _) -> pure ()
                        other -> expectationFailure ("Expected DuplicateEvent, got: " <> show other)

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

{- | Bracket that creates an ephemeral PostgreSQL database, initializes the
schema, and provides a KirokuStore handle.
-}
withTestStore :: (KirokuStore -> IO ()) -> IO ()
withTestStore action = do
    result <- Pg.withCached $ \db -> do
        let poolConfig =
                Pool.Config.settings
                    [ Pool.Config.staticConnectionSettings (Pg.connectionSettings db)
                    , Pool.Config.size 4
                    ]
        pool <- Pool.acquire poolConfig
        -- Initialize the schema
        initializeSchema pool "public"
        let store = KirokuStore{pool = pool, schema = "public"}
        action store
        Pool.release pool
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()
