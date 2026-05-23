module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Lens ((^.))
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Effectful (runEff)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Kiroku.Store
import Shibuya.Adapter.Kiroku (KirokuAdapterConfig (..), kirokuAdapter)
import Shibuya.Adapter.Kiroku.Convert (toEnvelope)
import Shibuya.App (
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
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Runner.Metrics (ProcessorState (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Directory (doesFileExist)
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "toEnvelope" $ do
        it "copies W3C trace metadata into Shibuya trace headers" $ do
            let traceparent :: Text
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                tracestate :: Text
                tracestate = "rojo=00f067aa0ba902b7"
                Envelope{traceContext} =
                    toEnvelope
                        ( makeRecordedEvent
                            ( Just $
                                Aeson.object
                                    [ "traceparent" Aeson..= traceparent
                                    , "tracestate" Aeson..= tracestate
                                    , "other" Aeson..= ("preserved" :: Text)
                                    ]
                            )
                        )

            traceContext
                `shouldBe` Just
                    [ ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
                    , ("tracestate", "rojo=00f067aa0ba902b7")
                    ]

        it "omits trace headers when traceparent is absent or not a string" $ do
            let Envelope{traceContext = missingTraceparent} =
                    toEnvelope (makeRecordedEvent (Just (Aeson.object ["tracestate" Aeson..= ("state" :: Text)])))
                Envelope{traceContext = nonStringTraceparent} =
                    toEnvelope (makeRecordedEvent (Just (Aeson.object ["traceparent" Aeson..= Aeson.Number 1])))

            missingTraceparent `shouldBe` Nothing
            nonStringTraceparent `shouldBe` Nothing

    around withTestStore $ do
        describe "kirokuAdapter" $ do
            it "delivers catch-up events through Shibuya pipeline" $ \store -> do
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
                                , consumerGroup = Nothing
                                }

                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
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
                                , consumerGroup = Nothing
                                }

                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk

                    res <- runApp IgnoreFailures 100 [(ProcessorId "live", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ threadDelay 200_000
                            liftIO $ do
                                let events = map (\i -> makeEvent ("Live" <> T.pack (show i)) (Aeson.object [])) [1 .. 5 :: Int]
                                Right _ <- runStoreIO store $ appendToStream (StreamName "shibuya-live-1") NoStream events
                                pure ()
                            liftIO $ waitForCount countVar 5 10_000_000
                            stopApp appHandle

                collected <- readIORef ref
                length collected `shouldBe` 5

            it "runs multiple category subscriptions concurrently" $ \store -> do
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
                                    , consumerGroup = Nothing
                                    }
                    let mkHandler ref' cVar ingested = do
                            liftIO $ do
                                modifyIORef' ref' (envelopePayload ingested :)
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
                                , consumerGroup = Nothing
                                }
                    badAdapter <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "bad-proj"
                                , subscriptionTarget = Category (CategoryName "bad")
                                , batchSize = 100
                                , bufferSize = 256
                                , consumerGroup = Nothing
                                }
                    otherAdapter <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "other-proj"
                                , subscriptionTarget = Category (CategoryName "other")
                                , batchSize = 100
                                , bufferSize = 256
                                , consumerGroup = Nothing
                                }

                    let goodHandler ingested = do
                            liftIO $ do
                                modifyIORef' goodRef (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar goodCount
                                    writeTVar goodCount (c + 1)
                            pure AckOk

                    let badHandler _ingested = do
                            liftIO $ error "handler crash!"

                    let otherHandler ingested = do
                            liftIO $ do
                                modifyIORef' otherRef (envelopePayload ingested :)
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
                                threadDelay 500_000
                            metrics <- getAppMetrics appHandle
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
                                , consumerGroup = Nothing
                                }
                    adapterB <-
                        kirokuAdapter store $
                            KirokuAdapterConfig
                                { subscriptionName = SubscriptionName "shut-b-proj"
                                , subscriptionTarget = Category (CategoryName "shut")
                                , batchSize = 100
                                , bufferSize = 256
                                , consumerGroup = Nothing
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
                            liftIO $ do
                                waitForCount countA 2 10_000_000
                                waitForCount countB 2 10_000_000
                            drained <- stopAppGracefully Shibuya.defaultShutdownConfig appHandle
                            liftIO $ drained `shouldBe` True

        describe "consumer groups" $ do
            it "four-member group delivers a disjoint, complete partition of the stream" $ \store -> do
                -- 20 streams × 2 events = 40 events, global positions 1..40, category "cg".
                let streams = ["cg-" <> T.pack (show i) | i <- [1 .. 20 :: Int]]
                mapM_
                    ( \sn -> do
                        let evs = [makeEvent ("EV" <> T.pack (show k)) (Aeson.object []) | k <- [1 .. 2 :: Int]]
                        Right _ <- runStoreIO store $ appendToStream (StreamName sn) NoStream evs
                        pure ()
                    )
                    streams
                threadDelay 200_000

                -- One IORef + one TVar counter per member.
                refs <- mapM (const (newIORef ([] :: [RecordedEvent]))) [0 .. 3 :: Int]
                cvars <- mapM (const (newTVarIO (0 :: Int))) [0 .. 3 :: Int]

                runEff $ runTracingNoop $ do
                    -- Build one adapter per member index; each carries the same
                    -- subscriptionName and a distinct member of a size-4 group.
                    adapters <-
                        mapM
                            ( \m ->
                                kirokuAdapter store $
                                    KirokuAdapterConfig
                                        { subscriptionName = SubscriptionName "cg-shibuya-group"
                                        , subscriptionTarget = Category (CategoryName "cg")
                                        , batchSize = 100
                                        , bufferSize = 256
                                        , consumerGroup = Just (ConsumerGroup{member = m, size = 4})
                                        }
                            )
                            [0, 1, 2, 3]

                    let mkHandler ref' cvar ingested = do
                            liftIO $ do
                                modifyIORef' ref' (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar cvar
                                    writeTVar cvar (c + 1)
                            pure AckOk

                        processors =
                            [ ( ProcessorId ("cg-member-" <> T.pack (show m))
                              , mkProcessor (adapters !! m) (mkHandler (refs !! m) (cvars !! m))
                              )
                            | m <- [0 .. 3 :: Int]
                            ]

                    res <- runApp IgnoreFailures 100 processors
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForTotal cvars 40 15_000_000
                            stopApp appHandle

                collected <- mapM readIORef refs
                -- Disjoint + complete: the union of every member's delivered global
                -- positions is exactly [1..40] — no event dropped, none delivered twice.
                let allPositions = sort (concatMap (map globalPos) collected)
                allPositions `shouldBe` [1 .. 40]
                -- No member starved: 20 streams over 4 members gives each ≥ 1 stream.
                mapM_ (\c -> length c `shouldSatisfy` (>= 1)) collected

-- Helpers

envelopePayload :: Ingested es RecordedEvent -> RecordedEvent
envelopePayload ing = let Ingested{envelope = env} = ing in env ^. #payload

-- | The raw global position of a recorded event (for disjoint/complete checks).
globalPos :: RecordedEvent -> Int64
globalPos e = case e ^. #globalPosition of GlobalPosition p -> p

-- | Wait until the sum of all TVar counts reaches the target or the timeout fires.
waitForTotal :: [STM.TVar Int] -> Int -> Int -> IO ()
waitForTotal vars target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    result <-
        atomically $
            ( do
                total <- sum <$> mapM readTVar vars
                STM.check (total >= target)
                pure True
            )
                `STM.orElse` ( do
                                t <- readTVar timeoutVar
                                STM.check t
                                pure False
                             )
    unless result $ do
        actual <- atomically $ sum <$> mapM readTVar vars
        expectationFailure ("Timed out waiting for total " <> show target <> ", got " <> show actual)

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
    unless result $ do
        actual <- atomically $ readTVar countVar
        expectationFailure ("Timed out waiting for count " <> show target <> ", got " <> show actual)

makeEvent :: Text -> Value -> EventData
makeEvent typ p =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = p
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

makeRecordedEvent :: Maybe Value -> RecordedEvent
makeRecordedEvent meta =
    RecordedEvent
        { eventId = EventId UUID.nil
        , eventType = EventType "TraceEvent"
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = Aeson.object []
        , metadata = meta
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = UTCTime (fromGregorian 2026 5 16) 0
        }

withTestStore :: (KirokuStore -> IO ()) -> IO ()
withTestStore action = do
    result <- Pg.withCached $ \db -> do
        migrateTestDatabase (Pg.connectionString db)
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings action
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()

migrateTestDatabase :: Text -> IO ()
migrateTestDatabase connStr = do
    migrationPath <- findMigrationSql
    migrationSql <- TIO.readFile migrationPath
    pool <- Pool.acquire poolConfig
    result <- Pool.use pool (Session.script migrationSql)
    Pool.release pool
    case result of
        Left err -> error ("Failed to apply Kiroku migration SQL for test database: " <> show err)
        Right () -> pure ()
  where
    poolConfig =
        Pool.Config.settings
            [ Pool.Config.staticConnectionSettings (Conn.connectionString connStr)
            , Pool.Config.size 1
            ]

findMigrationSql :: IO FilePath
findMigrationSql = go candidates
  where
    candidates =
        [ "kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql"
        , "../kiroku-store-migrations/sql-migrations/2026-05-16-00-00-00-kiroku-bootstrap.sql"
        ]

    go [] = error "Could not locate kiroku-store-migrations bootstrap SQL from test working directory"
    go (path : rest) = do
        exists <- doesFileExist path
        if exists then pure path else go rest
