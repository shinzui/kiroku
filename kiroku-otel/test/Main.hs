module Main where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Kiroku.Otel.TraceContext (extractTraceContext, injectTraceContext)
import Kiroku.Store.Types (
    EventData (..),
    EventId (..),
    EventType (..),
    GlobalPosition (..),
    RecordedEvent (..),
    StreamId (..),
    StreamVersion (..),
 )
import OpenTelemetry.Trace.Core (
    SpanContext (..),
    traceFlagsFromWord8,
 )
import OpenTelemetry.Trace.Id (
    Base (..),
    baseEncodedToSpanId,
    baseEncodedToTraceId,
 )
import OpenTelemetry.Trace.TraceState qualified as TS
import Test.Hspec

main :: IO ()
main = hspec $ do
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
