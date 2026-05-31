module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Effectful (runEff)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import OpenTelemetry.Attributes (toAttribute)
import Shibuya.Adapter.Kiroku (
    consumerGroupPolicy,
    defaultConsumerGroupConfig,
    defaultKirokuAdapterConfig,
    kirokuAdapter,
    kirokuConsumerGroupProcessors,
 )
import Shibuya.Adapter.Kiroku.Convert (KirokuEnvelopeAttrs, kirokuEnvelopeAttrs, toEnvelope)
import Shibuya.App (
    ProcessorId (..),
    QueueProcessor (..),
    SupervisionStrategy (..),
    getAppMetrics,
    mkProcessor,
    runApp,
    stopApp,
    stopAppGracefully,
 )
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ack qualified as Ack
import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Runner.Metrics (ProcessorState (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Hspec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    describe "toEnvelope" $ do
        it "copies W3C trace metadata into Shibuya trace headers" $ do
            let traceparent :: Text
                traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
                tracestate :: Text
                tracestate = "rojo=00f067aa0ba902b7"
                Envelope{traceContext} =
                    toEnvelope
                        sampleEnvelopeAttrs
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
                    toEnvelope sampleEnvelopeAttrs (makeRecordedEvent (Just (Aeson.object ["tracestate" Aeson..= ("state" :: Text)])))
                Envelope{traceContext = nonStringTraceparent} =
                    toEnvelope sampleEnvelopeAttrs (makeRecordedEvent (Just (Aeson.object ["traceparent" Aeson..= Aeson.Number 1])))

            missingTraceparent `shouldBe` Nothing
            nonStringTraceparent `shouldBe` Nothing

        it "stamps kiroku identity attributes for a non-grouped subscription (EP-5 M2)" $ do
            let attrs = kirokuEnvelopeAttrs "orders-proj" Nothing
                Envelope{attributes} = toEnvelope attrs (makeRecordedEvent Nothing)
            -- makeRecordedEvent: eventType "TraceEvent", globalPosition 1.
            HashMap.lookup "kiroku.subscription.name" attributes
                `shouldBe` Just (toAttribute ("orders-proj" :: Text))
            HashMap.lookup "messaging.system" attributes
                `shouldBe` Just (toAttribute ("kiroku" :: Text))
            HashMap.lookup "messaging.destination.name" attributes
                `shouldBe` Just (toAttribute ("orders-proj" :: Text))
            HashMap.lookup "kiroku.event.type" attributes
                `shouldBe` Just (toAttribute ("TraceEvent" :: Text))
            HashMap.lookup "kiroku.event.global_position" attributes
                `shouldBe` Just (toAttribute (1 :: Int64))
            -- No member key for a non-grouped subscription.
            HashMap.lookup "kiroku.consumer_group.member" attributes `shouldBe` Nothing

        it "stamps the consumer-group member attribute for a grouped subscription (EP-5 M2)" $ do
            let attrs = kirokuEnvelopeAttrs "orders-proj" (Just 2)
                Envelope{attributes} = toEnvelope attrs (makeRecordedEvent Nothing)
            HashMap.lookup "kiroku.subscription.name" attributes
                `shouldBe` Just (toAttribute ("orders-proj" :: Text))
            HashMap.lookup "kiroku.consumer_group.member" attributes
                `shouldBe` Just (toAttribute (2 :: Int64))

    describe "consumer group policy" $ do
        it "accepts Serial member concurrency as (PartitionedInOrder, Serial)" $
            consumerGroupPolicy Serial `shouldBe` Right (PartitionedInOrder, Serial)

        it "rejects Ahead member concurrency with a PolicyError" $
            consumerGroupPolicy (Ahead 4)
                `shouldBe` Left (InvalidPolicyCombo "StrictInOrder requires Serial concurrency")

        it "rejects Async member concurrency with a PolicyError" $
            consumerGroupPolicy (Async 4)
                `shouldBe` Left (InvalidPolicyCombo "StrictInOrder requires Serial concurrency")

    around withTestStore $ do
        describe "kirokuAdapter" $ do
            it "delivers only matching event types when an eventTypeFilter is set (EP-43)" $ \store -> do
                -- A, B, A, B, A on one stream (global positions 1..5). The adapter
                -- is filtered to type A; the Shibuya handler must see only the As.
                let events =
                        [ makeEvent "A" (Aeson.object [])
                        , makeEvent "B" (Aeson.object [])
                        , makeEvent "A" (Aeson.object [])
                        , makeEvent "B" (Aeson.object [])
                        , makeEvent "A" (Aeson.object [])
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName "etf-adapter-1") NoStream events
                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)
                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "etf-adapter") AllStreams
                                & #eventTypeFilter .~ OnlyEventTypes (Set.fromList [EventType "A"])
                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk
                    res <- runApp IgnoreFailures 100 [(ProcessorId "etf", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForCount countVar 3 10_000_000
                            stopApp appHandle

                collected <- readIORef ref
                -- Only the three A events reached the handler; no Bs.
                map (^. #eventType) collected `shouldBe` replicate 3 (EventType "A")
                map globalPos (reverse collected) `shouldBe` [1, 3, 5]

            it "delivers only matching types across a filtered consumer group (EP-43)" $ \store -> do
                -- 20 streams in category "etfg", each [A, B]; A at odd global
                -- positions 1,3,..,39. A size-4 group filtered to type A must
                -- deliver exactly the 20 As, disjoint and complete.
                let streams = [0 .. 19 :: Int]
                mapM_
                    ( \i -> do
                        let sn = StreamName ("etfg-" <> T.pack (show i))
                        Right _ <-
                            runStoreIO store $
                                appendToStream sn NoStream [makeEvent "A" (Aeson.object []), makeEvent "B" (Aeson.object [])]
                        pure ()
                    )
                    streams
                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)
                runEff $ runTracingNoop $ do
                    let cfg =
                            defaultConsumerGroupConfig (SubscriptionName "etfg") (Category (CategoryName "etfg")) 4
                                & #eventTypeFilter .~ OnlyEventTypes (Set.fromList [EventType "A"])
                        handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk
                    res <- kirokuConsumerGroupProcessors store cfg handler
                    case res of
                        Left err -> liftIO $ expectationFailure ("kirokuConsumerGroupProcessors failed: " <> show err)
                        Right processors -> do
                            appRes <- runApp IgnoreFailures 100 processors
                            case appRes of
                                Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                                Right appHandle -> do
                                    liftIO $ waitForCount countVar 20 15_000_000
                                    stopApp appHandle

                collected <- readIORef ref
                -- Every delivered event is an A (filter honored per member)...
                map (^. #eventType) collected `shouldBe` replicate 20 (EventType "A")
                -- ...and the union over members is the complete, disjoint set of A
                -- positions [1,3,..,39] — no A dropped, none delivered twice.
                sort (map globalPos collected) `shouldBe` [1, 3 .. 39]

            it "delivers only events matching an opaque selector (EP-43 follow-up)" $ \store -> do
                -- All one type "A" (so eventTypeFilter cannot distinguish them);
                -- only the payload tag {keep} differs. keep, skip, keep, skip, keep
                -- at positions 1..5. The selector admits only keep=True.
                let keepObj = Aeson.object [("keep", Aeson.Bool True)]
                    skipObj = Aeson.object [("keep", Aeson.Bool False)]
                    events =
                        [ makeEvent "A" keepObj
                        , makeEvent "A" skipObj
                        , makeEvent "A" keepObj
                        , makeEvent "A" skipObj
                        , makeEvent "A" keepObj
                        ]
                Right _ <- runStoreIO store $ appendToStream (StreamName "sel-adapter-1") NoStream events
                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)
                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "sel-adapter") AllStreams
                                & #selector .~ Just (\e -> (e ^. #payload) == keepObj)
                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk
                    res <- runApp IgnoreFailures 100 [(ProcessorId "sel", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForCount countVar 3 10_000_000
                            stopApp appHandle

                collected <- readIORef ref
                -- Only the three keep events reached the handler (positions 1,3,5);
                -- the two skip events were filtered worker-side and never delivered.
                map globalPos (reverse collected) `shouldBe` [1, 3, 5]

            it "delivers catch-up events through Shibuya pipeline" $ \store -> do
                let events = map (\i -> makeEvent ("CU" <> T.pack (show i)) (Aeson.object [])) [1 .. 10 :: Int]
                Right _ <- runStoreIO store $ appendToStream (StreamName "shibuya-catchup-1") NoStream events
                threadDelay 200_000

                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "shibuya-catchup-test") AllStreams

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
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "shibuya-live-test") AllStreams

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
                            kirokuAdapter store $
                                defaultKirokuAdapterConfig (SubscriptionName nm) (Category (CategoryName cat))
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
                            defaultKirokuAdapterConfig (SubscriptionName "good-proj") (Category (CategoryName "good"))
                    badAdapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "bad-proj") (Category (CategoryName "bad"))
                    otherAdapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "other-proj") (Category (CategoryName "other"))

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
                            defaultKirokuAdapterConfig (SubscriptionName "shut-a-proj") (Category (CategoryName "shut"))
                    adapterB <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "shut-b-proj") (Category (CategoryName "shut"))

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

        describe "ack dispositions" $ do
            it "AckRetry redelivers the same event, then AckOk advances (EP-40 M3)" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "ackretry-1") NoStream [makeEvent "R1" (Aeson.object [])]
                threadDelay 200_000

                deliveries <- newIORef (0 :: Int)
                countVar <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "ackretry-proj") AllStreams

                    let handler _ingested = do
                            n <- liftIO $ do
                                modifyIORef' deliveries (+ 1)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                                    pure (c + 1)
                            -- Retry the first delivery, accept the second.
                            pure (if n == 1 then AckRetry (Ack.RetryDelay 0) else AckOk)

                    res <- runApp IgnoreFailures 100 [(ProcessorId "ackretry", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForCount countVar 2 10_000_000
                            stopApp appHandle

                -- The one event was delivered twice (initial + one retry).
                n <- readIORef deliveries
                n `shouldBe` 2
                -- It was not dead-lettered (the retry succeeded).
                dls <- readDeadLetters store "ackretry-proj"
                length dls `shouldBe` 0

            it "AckDeadLetter records the event and the next event continues (EP-40 M3)" $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "ackdl-1") NoStream [makeEvent "D1" (Aeson.object [])]
                Right _ <- runStoreIO store $ appendToStream (StreamName "ackdl-2") NoStream [makeEvent "D2" (Aeson.object [])]
                threadDelay 200_000

                okPayloads <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)

                runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            defaultKirokuAdapterConfig (SubscriptionName "ackdl-proj") AllStreams

                    let handler ingested = do
                            n <- liftIO $ atomically $ do
                                c <- readTVar countVar
                                writeTVar countVar (c + 1)
                                pure (c + 1)
                            -- Dead-letter the first event; accept the second.
                            if n == 1
                                then pure (AckDeadLetter (PoisonPill "poison"))
                                else do
                                    liftIO $ modifyIORef' okPayloads (envelopePayload ingested :)
                                    pure AckOk

                    res <- runApp IgnoreFailures 100 [(ProcessorId "ackdl", mkProcessor adapter handler)]
                    case res of
                        Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                        Right appHandle -> do
                            liftIO $ waitForCount countVar 2 10_000_000
                            stopApp appHandle

                -- The first event (global position 1) is recorded as dead-letter.
                dls <- readDeadLetters store "ackdl-proj"
                map SQL.deadLetterGlobalPosition dls `shouldBe` [1]
                -- The second event was delivered and accepted.
                oks <- readIORef okPayloads
                map globalPos oks `shouldBe` [2]

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
                                    defaultKirokuAdapterConfig (SubscriptionName "cg-shibuya-group") (Category (CategoryName "cg"))
                                        & #consumerGroup .~ Just (ConsumerGroup{member = m, size = 4})
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

        describe "consumer group policy" $ do
            it "rejects an invalid member concurrency before opening any subscription" $ \store -> do
                -- A request the helper cannot honor per member returns Left without
                -- starting any worker. The (unused) store proves no subscription opens.
                result <-
                    runEff $
                        runTracingNoop $
                            kirokuConsumerGroupProcessors
                                store
                                ( defaultConsumerGroupConfig (SubscriptionName "cgp-reject") (Category (CategoryName "cgp-reject")) 4
                                    & #memberConcurrency .~ Async 4
                                )
                                ( \ingested -> do
                                    let _ = envelopePayload ingested
                                    pure AckOk
                                )
                case result of
                    Left err -> err `shouldBe` InvalidPolicyCombo "StrictInOrder requires Serial concurrency"
                    Right _ -> expectationFailure "expected Left PolicyError for Async member concurrency"

            it "one call yields N PartitionedInOrder processors; members partition the stream disjointly" $ \store -> do
                -- 20 streams × 2 events = 40 events, global positions 1..40, category "cgp".
                let streams = ["cgp-" <> T.pack (show i) | i <- [1 .. 20 :: Int]]
                mapM_
                    ( \sn -> do
                        let evs = [makeEvent ("EV" <> T.pack (show k)) (Aeson.object []) | k <- [1 .. 2 :: Int]]
                        Right _ <- runStoreIO store $ appendToStream (StreamName sn) NoStream evs
                        pure ()
                    )
                    streams
                threadDelay 200_000

                -- A single shared handler records every delivery (consumer-group
                -- members all run the same handler). One counter for the whole group.
                ref <- newIORef ([] :: [RecordedEvent])
                countVar <- newTVarIO (0 :: Int)

                let cfg =
                        defaultConsumerGroupConfig
                            (SubscriptionName "cgp-shibuya-group")
                            (Category (CategoryName "cgp"))
                            4

                runEff $ runTracingNoop $ do
                    let handler ingested = do
                            liftIO $ do
                                modifyIORef' ref (envelopePayload ingested :)
                                atomically $ do
                                    c <- readTVar countVar
                                    writeTVar countVar (c + 1)
                            pure AckOk

                    -- One call replaces the manual `mapM mkMemberAdapter [0..3]` wiring.
                    res <- kirokuConsumerGroupProcessors store cfg handler
                    case res of
                        Left err -> liftIO $ expectationFailure ("kirokuConsumerGroupProcessors failed: " <> show err)
                        Right processors -> do
                            -- The group is presented as N processors, each pinned to the
                            -- group-level PartitionedInOrder contract + per-member Serial.
                            liftIO $ length processors `shouldBe` 4
                            let policies = map (\(_, QueueProcessor _ _ ord conc) -> (ord, conc)) processors
                            liftIO $ policies `shouldBe` replicate 4 (PartitionedInOrder, Serial)
                            -- The member index is readable off the ProcessorId.
                            let pids = map (\(ProcessorId p, _) -> p) processors
                            liftIO $
                                pids
                                    `shouldBe` ["cgp-shibuya-group-member-" <> T.pack (show m) | m <- [0 .. 3 :: Int]]

                            appRes <- runApp IgnoreFailures 100 processors
                            case appRes of
                                Left err -> liftIO $ expectationFailure ("runApp failed: " <> show err)
                                Right appHandle -> do
                                    liftIO $ waitForCount countVar 40 15_000_000
                                    stopApp appHandle

                collected <- readIORef ref
                -- Disjoint + complete through the helper: the union of every member's
                -- delivered global positions is exactly [1..40] — no event dropped, none
                -- delivered twice. No duplicates ⇒ the member partitions are disjoint;
                -- ==[1..40] ⇒ the union is the complete source. This is the same
                -- disjoint-complete property MasterPlan 4 used, now asserted through the
                -- single-call helper and the Shibuya pipeline.
                sort (map globalPos collected) `shouldBe` [1 .. 40]
                -- Every one of the 20 originating streams was covered.
                length (nub (map origStreamId collected)) `shouldBe` 20

-- Helpers

envelopePayload :: Ingested es RecordedEvent -> RecordedEvent
envelopePayload ing = let Ingested{envelope = env} = ing in env ^. #payload

-- | Read the dead letters recorded for a non-group subscription (member 0).
readDeadLetters :: KirokuStore -> Text -> IO [SQL.DeadLetterRecord]
readDeadLetters store subName = do
    result <- Pool.use (store ^. #pool) (Session.statement (subName, 0 :: Int32) SQL.readDeadLettersStmt)
    case result of
        Left err -> error ("readDeadLetters failed: " <> show err)
        Right v -> pure (toList v)

-- | The raw global position of a recorded event (for disjoint/complete checks).
globalPos :: RecordedEvent -> Int64
globalPos e = case e ^. #globalPosition of GlobalPosition p -> p

-- | The originating stream's surrogate id (for stream-coverage checks).
origStreamId :: RecordedEvent -> Int64
origStreamId e = case e ^. #originalStreamId of StreamId p -> p

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

{- | A throwaway attribute source for the trace-header tests, whose assertions
do not depend on the kiroku identity attributes.
-}
sampleEnvelopeAttrs :: KirokuEnvelopeAttrs
sampleEnvelopeAttrs = kirokuEnvelopeAttrs "test-sub" Nothing

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
withTestStore action =
    withMigratedTestDatabase $ \connStr ->
        withStore (defaultConnectionSettings connStr) action
