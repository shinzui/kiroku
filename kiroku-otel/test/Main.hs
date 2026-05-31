-- 'head' is used in the tracing tests immediately after asserting the list has
-- exactly one element, so the partiality is guarded by the preceding assertion.
{-# OPTIONS_GHC -Wno-x-partial #-}

module Main where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Lens ((&), (.~))
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Kiroku.Otel.Subscription (
    attrAttempt,
    attrBatchRows,
    attrCheckpoint,
    attrDeadLetterReason,
    attrEventPos,
    attrGroupMember,
    attrState,
    attrStopReason,
    attrSubName,
    spanCatchup,
    spanDeadLetter,
    spanDeliver,
    spanPaused,
    spanReconnecting,
    spanRetrying,
    spanStopped,
    subscriptionTraceHandler,
 )
import Kiroku.Otel.TraceContext (extractTraceContext, injectTraceContext)
import Kiroku.Store (
    ExpectedVersion (..),
    KirokuStore,
    StreamName (..),
    SubscriptionResult (..),
    SubscriptionTarget (..),
    appendToStream,
    cancel,
    defaultConnectionSettings,
    defaultSubscriptionConfig,
    runStoreIO,
    subscribe,
    wait,
    withStore,
 )
import Kiroku.Store.Observability (
    DeadLetterReason (..),
    KirokuEvent (..),
    SubscriptionDeliveryPhase (..),
    SubscriptionGroupContext (..),
    SubscriptionStopReason (..),
 )
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (
    EventData (..),
    EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamVersion (..),
 )
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import OpenTelemetry.Attributes (Attribute, getAttributeMap, toAttribute)
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core (
    Event (..),
    ImmutableSpan (..),
    SpanContext (..),
    createTracerProvider,
    emptyTracerProviderOptions,
    forceFlushTracerProvider,
    makeTracer,
    traceFlagsFromWord8,
    tracerOptions,
 )
import OpenTelemetry.Trace.Id (
    Base (..),
    baseEncodedToSpanId,
    baseEncodedToTraceId,
 )
import OpenTelemetry.Trace.TraceState qualified as TS
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Test.Hspec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    describe "TraceContext round-trip" $ do
        it "encodes and decodes a SpanContext through metadata" $ do
            let sc = mkTestSpanContext
                ed0 = mkEmptyEventData
                ed1 = injectTraceContext sc ed0
                stub = mkStubRecorded (eventDataMetadata ed1)
            case extractTraceContext stub of
                Just sc' -> do
                    traceId (sc' :: SpanContext) `shouldBe` traceId (sc :: SpanContext)
                    spanId (sc' :: SpanContext) `shouldBe` spanId (sc :: SpanContext)
                    traceFlags (sc' :: SpanContext) `shouldBe` traceFlags (sc :: SpanContext)
                Nothing -> expectationFailure "expected Just SpanContext"

        it "preserves existing metadata keys" $ do
            let baseMeta =
                    Aeson.object
                        [ (Key.fromText (T.pack "tenant"), Aeson.String (T.pack "acme"))
                        ]
                ed0 = mkEmptyEventDataWithMeta (Just baseMeta)
                ed1 = injectTraceContext mkTestSpanContext ed0
            case eventDataMetadata ed1 of
                Just (Aeson.Object o) -> do
                    KM.lookup (Key.fromText (T.pack "tenant")) o
                        `shouldBe` Just (Aeson.String (T.pack "acme"))
                    KM.lookup (Key.fromText (T.pack "traceparent")) o
                        `shouldNotBe` Nothing
                _ -> expectationFailure "metadata is not a JSON object"

    describe "extractTraceContext absence handling" $ do
        it "returns Nothing when metadata is absent" $
            extractTraceContext (mkStubRecorded Nothing) `shouldBe` Nothing

        it "returns Nothing when metadata is empty" $
            extractTraceContext (mkStubRecorded (Just (Aeson.object [])))
                `shouldBe` Nothing

        it "returns Nothing when traceparent is unparseable" $
            extractTraceContext
                ( mkStubRecorded
                    ( Just
                        ( Aeson.object
                            [ (Key.fromText (T.pack "traceparent"), Aeson.String (T.pack "garbage"))
                            ]
                        )
                    )
                )
                `shouldBe` Nothing

    describe "injectTraceContext overwrites prior trace keys" $ do
        it "replaces an existing traceparent value" $ do
            let preexisting =
                    Aeson.object
                        [ (Key.fromText (T.pack "traceparent"), Aeson.String (T.pack "00-aaaa-bbbb-00"))
                        , (Key.fromText (T.pack "tenant"), Aeson.String (T.pack "acme"))
                        ]
                ed0 = mkEmptyEventDataWithMeta (Just preexisting)
                ed1 = injectTraceContext mkTestSpanContext ed0
            case eventDataMetadata ed1 of
                Just (Aeson.Object o) -> do
                    KM.lookup (Key.fromText (T.pack "tenant")) o
                        `shouldBe` Just (Aeson.String (T.pack "acme"))
                    KM.lookup (Key.fromText (T.pack "traceparent")) o
                        `shouldNotBe` Just (Aeson.String (T.pack "00-aaaa-bbbb-00"))
                _ -> expectationFailure "metadata is not a JSON object"

    describe "subscriptionTraceHandler" $ do
        it "catch-up then live yields an ended catchup span and a live deliver span" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 10) NonGroup
                    , KirokuEventSubscriptionDelivered subName 3 DeliveredLive NonGroup
                    ]
            let catchups = spansNamed spanCatchup spans
                delivers = spansNamed spanDeliver spans
            length catchups `shouldBe` 1
            length delivers `shouldBe` 1
            -- the catch-up span carries the subscription name and its caught-up checkpoint
            attrOf attrSubName (head catchups) `shouldBe` Just (toAttribute ("orders" :: Text))
            attrOf attrCheckpoint (head catchups) `shouldBe` Just (i64 10)
            -- the live deliver span carries the batch row count and state="live"
            attrOf attrBatchRows (head delivers) `shouldBe` Just (i64 3)
            attrOf attrState (head delivers) `shouldBe` Just (toAttribute ("live" :: Text))

        it "a catch-up delivery yields a deliver span tagged state=catchup" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionDelivered subName 5 DeliveredCatchUp NonGroup
                    ]
            let delivers = spansNamed spanDeliver spans
            length delivers `shouldBe` 1
            attrOf attrBatchRows (head delivers) `shouldBe` Just (i64 5)
            attrOf attrState (head delivers) `shouldBe` Just (toAttribute ("catchup" :: Text))

        it "a clean stop from live always yields a standalone stopped span" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) NonGroup
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 10) NonGroup
                    , KirokuEventSubscriptionDelivered subName 2 DeliveredLive NonGroup
                    , KirokuEventSubscriptionStopped subName (GlobalPosition 12) StopHandlerRequested NonGroup
                    ]
            let stops = spansNamed spanStopped spans
            length stops `shouldBe` 1
            attrOf attrStopReason (head stops)
                `shouldBe` Just (toAttribute (T.pack (show StopHandlerRequested)))
            attrOf attrCheckpoint (head stops) `shouldBe` Just (i64 12)

        it "pause then resume yields an ended paused span" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionPaused subName (GlobalPosition 5) NonGroup
                    , KirokuEventSubscriptionResumed subName (GlobalPosition 5) NonGroup
                    ]
            -- present in the exported set ⇒ the episode closed and is observable
            length (spansNamed spanPaused spans) `shouldBe` 1

        it "reconnect yields one span with a reconnect.attempt event and attempt=2" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionReconnecting subName 1 NonGroup
                    , KirokuEventSubscriptionReconnecting subName 2 NonGroup
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 7) NonGroup
                    ]
            let reconnects = spansNamed spanReconnecting spans
            length reconnects `shouldBe` 1
            eventNamesOf (head reconnects) `shouldContain` ["reconnect.attempt"]
            attrOf attrAttempt (head reconnects) `shouldBe` Just (i64 2)

        it "retry then dead-letter yields one retrying span with position and reason" $ do
            let reason = DeadLetterPoison "bad event"
            spans <-
                runEvents
                    [ KirokuEventSubscriptionRetrying subName (GlobalPosition 42) 1 NonGroup
                    , KirokuEventSubscriptionRetrying subName (GlobalPosition 42) 2 NonGroup
                    , KirokuEventSubscriptionDeadLettered subName (GlobalPosition 42) reason NonGroup
                    ]
            let retries = spansNamed spanRetrying spans
            length retries `shouldBe` 1
            attrOf attrEventPos (head retries) `shouldBe` Just (i64 42)
            attrOf attrDeadLetterReason (head retries)
                `shouldBe` Just (toAttribute (T.pack (show reason)))
            -- the dead-letter closed the open retry span; no standalone span
            length (spansNamed spanDeadLetter spans) `shouldBe` 0

        it "an immediate dead-letter (no retry) yields a standalone dead_letter span" $ do
            spans <-
                runEvents
                    [KirokuEventSubscriptionDeadLettered subName (GlobalPosition 9) (DeadLetterPoison "x") NonGroup]
            let dls = spansNamed spanDeadLetter spans
            length dls `shouldBe` 1
            attrOf attrEventPos (head dls) `shouldBe` Just (i64 9)

        it "consumer-group members produce separate, correctly tagged spans" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionStarted subName (GlobalPosition 0) (GroupMember 0 2)
                    , KirokuEventSubscriptionStarted subName (GlobalPosition 0) (GroupMember 1 2)
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 4) (GroupMember 0 2)
                    , KirokuEventSubscriptionCaughtUp subName (GlobalPosition 6) (GroupMember 1 2)
                    ]
            let catchups = spansNamed spanCatchup spans
            length catchups `shouldBe` 2
            sort (mapMaybe (attrOf attrGroupMember) catchups)
                `shouldBe` sort [i64 0, i64 1]

        it "stop ends an open pause span so no span leaks" $ do
            spans <-
                runEvents
                    [ KirokuEventSubscriptionPaused subName (GlobalPosition 5) NonGroup
                    , KirokuEventSubscriptionStopped subName (GlobalPosition 5) StopCancelled NonGroup
                    ]
            length (spansNamed spanPaused spans) `shouldBe` 1

    describe "subscriptionTraceHandler end-to-end (real $all worker)" $ do
        it "a real AllStreams worker emits catchup, a live deliver span, and a stopped span" $
            withMigratedTestDatabase $ \connStr -> do
                -- 1. In-memory exporter + provider + tracer + the trace handler.
                (processor, spansRef) <- inMemoryListExporter
                tp <- createTracerProvider [processor] emptyTracerProviderOptions
                let tracer = makeTracer tp "kiroku-otel-e2e" tracerOptions
                handler <- subscriptionTraceHandler tracer
                -- 2. A store whose eventHandler IS the tracer.
                let settings = defaultConnectionSettings connStr & #eventHandler .~ Just handler
                withStore settings $ \store -> do
                    -- 3. Seed some history so the worker has a real catch-up phase.
                    appendStoreEvents store "e2e-catchup" 5
                    -- 4. A Continue handler that counts deliveries, so we can wait
                    --    for the worker to actually go live and deliver live events.
                    delivered <- newTVarIO (0 :: Int)
                    let cfg =
                            defaultSubscriptionConfig (SubscriptionName "otel-e2e") AllStreams $ \_event -> do
                                atomically (modifyTVarCount delivered)
                                pure Continue
                    handle <- subscribe store cfg
                    -- 5. Wait for catch-up to drain the 5 seeded events.
                    waitForCount delivered 5 10_000_000
                    -- 6. Append MORE events now that the worker is live; these flow
                    --    through the publisher's bounded queue into the (Nothing,
                    --    AllStreams) Live branch -> DeliverBatch -> processEvents ->
                    --    KirokuEventSubscriptionDelivered DeliveredLive.
                    appendStoreEvents store "e2e-live" 3
                    waitForCount delivered 8 10_000_000
                    -- 7. Stop the worker (cancel) and wait for the Stopped event.
                    cancel handle
                    _ <- wait handle
                    -- 8. Flush the exporter and read the collected, ended spans.
                    _ <- forceFlushTracerProvider tp Nothing
                    spans <- readIORef spansRef
                    -- 9. Assertions: the two gaps are closed.
                    let catchups = spansNamed spanCatchup spans
                        delivers = spansNamed spanDeliver spans
                        liveDelivers =
                            filter ((== Just (toAttribute ("live" :: Text))) . attrOf attrState) delivers
                        stops = spansNamed spanStopped spans
                    length catchups `shouldSatisfy` (>= 1)
                    -- The gap-1 proof: at least one LIVE deliver span exists.
                    length liveDelivers `shouldSatisfy` (>= 1)
                    -- The gap-2 proof: a terminal stopped span exists.
                    length stops `shouldBe` 1

mkEmptyEventData :: EventData
mkEmptyEventData = mkEmptyEventDataWithMeta Nothing

mkEmptyEventDataWithMeta :: Maybe Aeson.Value -> EventData
mkEmptyEventDataWithMeta meta =
    EventData
        { eventId = Nothing
        , eventType = EventType (T.pack "X")
        , payload = Aeson.Null
        , metadata = meta
        , causationId = Nothing
        , correlationId = Nothing
        }

eventDataMetadata :: EventData -> Maybe Aeson.Value
eventDataMetadata EventData{metadata = m} = m

mkStubRecorded :: Maybe Aeson.Value -> RecordedEvent
mkStubRecorded meta =
    RecordedEvent
        { eventId = EventId UUID.nil
        , eventType = EventType (T.pack "X")
        , streamVersion = StreamVersion 1
        , globalPosition = GlobalPosition 1
        , originalStreamId = StreamId 1
        , originalVersion = StreamVersion 1
        , payload = Aeson.Null
        , metadata = meta
        , causationId = Nothing
        , correlationId = Nothing
        , createdAt = read "2026-05-14 00:00:00 UTC"
        }

mkTestSpanContext :: SpanContext
mkTestSpanContext =
    SpanContext
        { traceFlags = traceFlagsFromWord8 0x01
        , isRemote = True
        , traceId =
            either error id (baseEncodedToTraceId Base16 "4bf92f3577b34da6a3ce929d0e0e4736")
        , spanId =
            either error id (baseEncodedToSpanId Base16 "00f067aa0ba902b7")
        , traceState = TS.empty
        }

-- Subscription-tracing helpers ------------------------------------------------

-- | A fixed subscription name used across the tracing tests.
subName :: SubscriptionName
subName = SubscriptionName "orders"

{- | Drive a synthetic 'KirokuEvent' sequence through a fresh
'subscriptionTraceHandler' wired to an in-memory span exporter, and return the
exported (ended) spans. Because the in-memory exporter only ever receives ended
spans, a span appearing in the result is proof its episode closed.
-}
runEvents :: [KirokuEvent] -> IO [ImmutableSpan]
runEvents evs = do
    (processor, ref) <- inMemoryListExporter
    tp <- createTracerProvider [processor] emptyTracerProviderOptions
    let tracer = makeTracer tp "kiroku-otel-test" tracerOptions
    handler <- subscriptionTraceHandler tracer
    mapM_ handler evs
    _ <- forceFlushTracerProvider tp Nothing
    readIORef ref

-- | The spans with the given name.
spansNamed :: Text -> [ImmutableSpan] -> [ImmutableSpan]
spansNamed n = filter ((== n) . spanName)

-- | Look up an attribute on a span.
attrOf :: Text -> ImmutableSpan -> Maybe Attribute
attrOf k s = HashMap.lookup k (getAttributeMap (spanAttributes s))

-- | The names of the span events recorded on a span.
eventNamesOf :: ImmutableSpan -> [Text]
eventNamesOf s = map eventName (toList (appendOnlyBoundedCollectionValues (spanEvents s)))

-- | An 'Int64'-valued attribute (the encoding the tracer uses for counts/positions).
i64 :: Int64 -> Attribute
i64 = toAttribute

-- End-to-end (real worker) helpers --------------------------------------------

-- | Increment a 'TVar' 'Int' counter by one within STM.
modifyTVarCount :: TVar Int -> STM.STM ()
modifyTVarCount v = readTVar v >>= \c -> writeTVar v (c + 1)

{- | Append @n@ trivial events to a fresh stream via the native in-IO store
interpreter ('runStoreIO' + 'appendToStream'), mirroring @kiroku-store@'s own
tests. Each event is a minimal 'EventData' with a unique type tag.
-}
appendStoreEvents :: KirokuStore -> Text -> Int -> IO ()
appendStoreEvents store streamPrefix n = do
    let events =
            [ EventData
                { eventId = Nothing
                , eventType = EventType ("E" <> T.pack (show i))
                , payload = Aeson.Null
                , metadata = Nothing
                , causationId = Nothing
                , correlationId = Nothing
                }
            | i <- [1 .. n]
            ]
    result <- runStoreIO store (appendToStream (StreamName streamPrefix) NoStream events)
    case result of
        Right _ -> pure ()
        Left err -> expectationFailure ("appendStoreEvents failed: " <> show err)

-- | Wait until the 'TVar' reaches @target@ or the timeout (micros) fires; fail on timeout.
waitForCount :: TVar Int -> Int -> Int -> IO ()
waitForCount countVar target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    ok <-
        atomically $
            (do c <- readTVar countVar; STM.check (c >= target); pure True)
                `STM.orElse` (do t <- readTVar timeoutVar; STM.check t; pure False)
    unless ok $ do
        actual <- atomically (readTVar countVar)
        expectationFailure ("Timed out waiting for " <> show target <> ", got " <> show actual)
