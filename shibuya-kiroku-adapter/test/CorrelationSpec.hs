-- | Trace correlation of Shibuya processing spans over a Kiroku subscription.
--
-- Each case appends an event whose metadata carries a known writer
-- @traceparent@, subscribes with a traced Shibuya app whose tracer exports into
-- memory, and inspects the exported Consumer spans: their trace, their parent
-- and their links.
module CorrelationSpec (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, registerDelay)
import Control.Concurrent.STM qualified as STM
import Control.Exception qualified as E
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (readIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Effectful (runEff)
import Kiroku.Store
import OpenTelemetry.Attributes (emptyAttributes)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.Id.Generator (IdGenerator (..))
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku
  ( AdapterTelemetry,
    ConsumerGroupSize,
    KirokuAdapterConfig,
    TraceCorrelation (..),
    defaultAdapterTelemetry,
    defaultConsumerGroupConfig,
    defaultKirokuAdapterConfig,
    kirokuAdapter,
    kirokuConsumerGroupProcessors,
    mkConsumerGroupSize,
  )
import Shibuya.App (ProcessorId (..), QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop)
import Test.Hspec

spec :: SpecWith KirokuStore
spec = describe "trace correlation" $ do
  it "defaults to LinkOnly for single adapters and consumer groups" $ \_ -> do
    defaultKirokuAdapterConfig (SubscriptionName "c") AllStreams ^. #telemetry . #traceCorrelation `shouldBe` LinkOnly
    defaultConsumerGroupConfig (SubscriptionName "c") AllStreams (sizeOf 2) ^. #telemetry . #traceCorrelation `shouldBe` LinkOnly

  it "an adapter built with a ParentAndLink override exposes it" $ \store -> do
    policy <- runEff $ runTracingNoop $ do
      Adapter {shutdown, telemetry} <- kirokuAdapter store (defaultKirokuAdapterConfig (SubscriptionName "corr-override") AllStreams & #telemetry .~ defaultAdapterTelemetry)
      shutdown
      pure (telemetry ^. #traceCorrelation)
    policy `shouldBe` ParentAndLink

  it "every consumer-group member reports the configured policy" $ \store -> do
    forM_ [LinkOnly, ParentAndLink] $ \policy -> do
      let cfg = defaultConsumerGroupConfig (SubscriptionName "corr-group") AllStreams (sizeOf 3) & #telemetry .~ withPolicy policy
      policies <- runEff $ runTracingNoop $ do
        result <- kirokuConsumerGroupProcessors store cfg (\_ -> pure AckOk)
        case result of
          Left err -> liftIO (expectationFailure (show err)) >> pure []
          Right processors ->
            traverse
              ( \(_, processor) -> case processor of
                  QueueProcessor {adapter = Adapter {shutdown, telemetry}} -> shutdown >> pure (telemetry ^. #traceCorrelation)
                  BatchingProcessor {adapter = Adapter {shutdown, telemetry}} -> shutdown >> pure (telemetry ^. #traceCorrelation)
              )
              processors
      policies `shouldBe` replicate 3 policy

  it "LinkOnly (default): the processing span is a linked root" $ \store -> do
    appendTraced store "corrlo-1" (Just writerParent)
    [sp] <- processAll store [("corr-linkonly", defaultKirokuAdapterConfig (SubscriptionName "corr-linkonly") (category "corrlo"))]
    hexTrace (spanContext sp) `shouldNotBe` writerTraceHex
    isNothing (spanParent sp) `shouldBe` True
    linkIds sp `shouldBe` [(writerTraceHex, writerSpanHex)]

  it "ParentAndLink: the processing span is a child of the writer with one link" $ \store -> do
    appendTraced store "corrpal-1" (Just writerParent)
    [sp] <- processAll store [("corr-pal", defaultKirokuAdapterConfig (SubscriptionName "corr-pal") (category "corrpal") & #telemetry .~ defaultAdapterTelemetry)]
    hexTrace (spanContext sp) `shouldBe` writerTraceHex
    fmap hexSpan (spanParent sp) `shouldBe` Just writerSpanHex
    linkIds sp `shouldBe` [(writerTraceHex, writerSpanHex)]

  it "LinkOnly: two subscriptions to one event are two traces linking the same writer span" $ \store -> do
    appendTraced store "corrfan-1" (Just writerParent)
    spans <-
      processAll
        store
        [ ("corr-fan-a", defaultKirokuAdapterConfig (SubscriptionName "corr-fan-a") (category "corrfan")),
          ("corr-fan-b", defaultKirokuAdapterConfig (SubscriptionName "corr-fan-b") (category "corrfan"))
        ]
    case spans of
      [a, b] -> do
        hexTrace (spanContext a) `shouldNotBe` hexTrace (spanContext b)
        mapM_ (\sp -> isNothing (spanParent sp) `shouldBe` True) [a, b]
        mapM_ (\sp -> linkIds sp `shouldBe` [(writerTraceHex, writerSpanHex)]) [a, b]
      other -> expectationFailure ("expected two processing spans, got " <> show (length other))

  forM_ [LinkOnly, ParentAndLink] $ \policy ->
    it (show policy <> ": an event without traceparent yields no link") $ \store -> do
      let cat = if policy == LinkOnly then "corrnolo" else "corrnopal"
      appendTraced store (cat <> "-1") Nothing
      [sp] <- processAll store [("corr-none-" <> cat, defaultKirokuAdapterConfig (SubscriptionName ("corr-none-" <> cat)) (category cat) & #telemetry .~ withPolicy policy)]
      spanLinks sp `shouldBe` []
      isNothing (spanParent sp) `shouldBe` True

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

writerParent :: Text
writerParent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

writerTraceHex :: Text
writerTraceHex = "0af7651916cd43dd8448eb211c80319c"

writerSpanHex :: Text
writerSpanHex = "b7ad6b7169203331"

sizeOf :: Int -> ConsumerGroupSize
sizeOf = either (error . show) Prelude.id . mkConsumerGroupSize . fromIntegral

category :: Text -> SubscriptionTarget
category = Category . CategoryName

withPolicy :: TraceCorrelation -> AdapterTelemetry
withPolicy policy = defaultAdapterTelemetry & #traceCorrelation .~ policy

-- | Append one event to the given stream, with the writer's traceparent in its
-- metadata when supplied.
appendTraced :: KirokuStore -> Text -> Maybe Text -> IO ()
appendTraced store stream traceparent = do
  let metadata = fmap (\tp -> Aeson.object ["traceparent" Aeson..= tp]) traceparent
      event =
        EventData
          { eventId = Nothing,
            eventType = EventType "Correlated",
            payload = Aeson.object [] :: Value,
            metadata = metadata,
            causationId = Nothing,
            correlationId = Nothing
          }
  result <- runStoreIO store $ appendToStream (StreamName stream) NoStream [event]
  either (\err -> expectationFailure ("append failed: " <> show err)) (const (pure ())) result

-- | Run one processor per configuration until each has handled one event, and
-- return the exported Consumer spans.
processAll :: KirokuStore -> [(Text, KirokuAdapterConfig)] -> IO [ConsumerSpan]
processAll store configs = do
  (spanProcessor, spansRef) <- inMemoryListExporter
  handled <- newTVarIO (0 :: Int)
  E.bracket
    (OTel.createTracerProvider [spanProcessor] OTel.emptyTracerProviderOptions {OTel.tracerProviderOptionsIdGenerator = DefaultIdGenerator})
    (\provider -> OTel.shutdownTracerProvider provider (Just 5_000_000))
    $ \provider -> do
      let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "kiroku-correlation" "" "" emptyAttributes) OTel.tracerOptions
      runEff $ runTracing tracer $ do
        processors <-
          traverse
            ( \(name, cfg) -> do
                adapter <- kirokuAdapter store cfg
                pure (ProcessorId name, mkProcessor adapter (\_ -> liftIO (atomically (modifyTVar' handled (+ 1))) >> pure AckOk))
            )
            configs
        result <- runApp defaultAppConfig processors
        case result of
          Left err -> liftIO (expectationFailure (show err))
          Right appHandle -> do
            liftIO $ waitFor handled (length configs) 10_000_000
            stopApp appHandle
  consumerSpans =<< readIORef spansRef

waitFor :: STM.TVar Int -> Int -> Int -> IO ()
waitFor var target timeoutMicros = do
  deadline <- registerDelay timeoutMicros
  reached <-
    atomically $
      ((readTVar var >>= STM.check . (>= target)) >> pure True)
        `STM.orElse` (readTVar deadline >>= STM.check >> pure False)
  if reached then pure () else expectationFailure ("timed out waiting for " <> show target <> " handled events")

data ConsumerSpan = ConsumerSpan
  { spanContext :: OTel.SpanContext,
    spanParent :: Maybe OTel.SpanContext,
    spanLinks :: [OTel.SpanContext]
  }

consumerSpans :: [OTel.ImmutableSpan] -> IO [ConsumerSpan]
consumerSpans exported = traverse describeSpan [sp | sp <- exported, OTel.spanKind sp == OTel.Consumer]
  where
    describeSpan sp = do
      hot <- readIORef (OTel.spanHot sp)
      parent <- traverse OTel.getSpanContext (OTel.spanParent sp)
      pure
        ConsumerSpan
          { spanContext = OTel.spanContext sp,
            spanParent = parent,
            spanLinks = map OTel.frozenLinkContext (toList (appendOnlyBoundedCollectionValues (OTel.hotLinks hot)))
          }

linkIds :: ConsumerSpan -> [(Text, Text)]
linkIds sp = [(hexTrace l, hexSpan l) | l <- spanLinks sp]

hexTrace :: OTel.SpanContext -> Text
hexTrace ctx = OTel.Id.traceIdBaseEncodedText Base16 (OTel.traceId ctx)

hexSpan :: OTel.SpanContext -> Text
hexSpan ctx = OTel.Id.spanIdBaseEncodedText Base16 (OTel.spanId ctx)
