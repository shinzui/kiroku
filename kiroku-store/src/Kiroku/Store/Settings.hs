{- | Interpreter-level hooks applied to 'EventData' before encoding on
the append path and to 'RecordedEvent' after decoding on the read and
subscription paths.

The hook seam lives inside 'Kiroku.Store.Effect.runStorePool' (and the
subscription publisher\/worker) rather than at the SQL encoder\/decoder
layer so the hook sees the typed value — payload and metadata as
'Data.Aeson.Value', the event type, ids — and can branch on event type
or mutate structured JSON. Plumbing it at the encoder layer would force
hooks to operate on opaque bytes.

Both fields default to 'Nothing'. With the defaults, the helpers below
retain the original event list/vector without traversal. Subscription
decoding adds one batch constructor, with no per-event wrappers.

A typical use case is enriching every appended event with an
OpenTelemetry trace context drawn from the calling thread:

@
storeSettings = 'defaultStoreSettings'
  { 'enrichEvent' = Just $ \\ed -> do
      ctx <- captureCurrentSpan        -- OpenTelemetry, OTLP, whatever
      pure (ed & #metadata %~ injectTraceContext ctx)
  , 'decodeHook' = Just $ \\re ->
      pure (Right (re & #metadata %~ Just . redactPII))
  }
@

Wire the resulting 'StoreSettings' into
'Kiroku.Store.Connection.ConnectionSettings' via its @storeSettings@
field; 'Kiroku.Store.Connection.withStore' copies it onto the
'Kiroku.Store.Connection.KirokuStore' handle for the interpreter to
reach.

Direct callers of 'Kiroku.Store.Transaction.appendToStreamTx' bypass
'runStorePool' and therefore the 'enrichEvent' hook. Use
'Kiroku.Store.Transaction.enrichEventsIO' to opt in to enrichment
manually before constructing the prepared event list.
-}
module Kiroku.Store.Settings (
    StoreSettings (..),
    defaultStoreSettings,
    enrichEvents,
    DecodeFailure (..),
    DecodedEvent (..),
    DecodedBatch (..),
    decodeEvents,
    decodeEvent,
    decodedEventRecorded,
    decodedBatchLength,
    decodedBatchLastEvent,
    filterDecodedBatch,
) where

import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Kiroku.Store.Types (EventData, EventId, RecordedEvent)

{- | A hook could not decode this event. Return it through 'Left'; throwing
from the hook remains a programming error. Default retry exhaustion is surfaced
by SubscriptionUndecodable, carrying this failure.
-}
data DecodeFailure = DecodeFailure
    { decodeFailureEventId :: !EventId
    , decodeFailureReason :: !Text
    }
    deriving stock (Eq, Show, Generic)

-- | A transformed event, or its raw value retained for retry and disposition.
data DecodedEvent
    = Decoded !RecordedEvent
    | Undecodable !RecordedEvent !DecodeFailure
    deriving stock (Eq, Show)

{- | No hook means no traversal or per-event wrappers. Hook results are shared
by all live publisher subscribers, whose retry/disposition is independent.
-}
data DecodedBatch
    = UnchangedBatch !(Vector RecordedEvent)
    | TransformedBatch !(Vector DecodedEvent)
    deriving stock (Eq, Show)

decodedEventRecorded :: DecodedEvent -> RecordedEvent
decodedEventRecorded = \case
    Decoded event -> event
    Undecodable event _ -> event

decodedBatchLength :: DecodedBatch -> Int
decodedBatchLength = \case
    UnchangedBatch events -> V.length events
    TransformedBatch events -> V.length events

decodedBatchLastEvent :: DecodedBatch -> RecordedEvent
decodedBatchLastEvent = \case
    UnchangedBatch events -> V.last events
    TransformedBatch events -> decodedEventRecorded (V.last events)

filterDecodedBatch :: (RecordedEvent -> Bool) -> DecodedBatch -> DecodedBatch
filterDecodedBatch predicate = \case
    UnchangedBatch events -> UnchangedBatch (V.filter predicate events)
    TransformedBatch events -> TransformedBatch (V.filter (predicate . decodedEventRecorded) events)

{- | Interpreter-level hooks for cross-cutting concerns at the
event-data boundary. All fields default to 'Nothing' (no-op).

* 'enrichEvent' fires on the append path before the SQL encoder runs,
  on the typed 'EventData' the caller supplied. Used to inject trace
  contexts, attach tenant ids, or encrypt payloads.

* 'decodeHook' fires on the read and subscription paths after the SQL
  decoder runs, on the typed 'RecordedEvent' about to be surfaced to
  the caller. Used to decrypt payloads, redact PII, or attach derived
  metadata.

When a field is 'Nothing', reads and enrichment return their input directly.
Subscription decoding retains the vector in one batch constructor without
traversal or per-event wrappers.
-}
data StoreSettings = StoreSettings
    { enrichEvent :: !(Maybe (EventData -> IO EventData))
    -- ^ Append-path hook. Runs once per appended event before encoding.
    , decodeHook :: !(Maybe (RecordedEvent -> IO (Either DecodeFailure RecordedEvent)))
    {- ^ Read- and subscription-path hook. Return 'Left' for an undecodable
    event: reads fail with a typed store error, subscriptions use their
    optional undecodable handler or retry and stop by default. Exceptions
    remain programming failures. Runs once per surfaced event; an undecodable
    event's retry re-applies the hook to its original value.
    -}
    }
    deriving stock (Generic)

-- | Defaults to both hooks being 'Nothing' — semantically a no-op.
defaultStoreSettings :: StoreSettings
defaultStoreSettings =
    StoreSettings
        { enrichEvent = Nothing
        , decodeHook = Nothing
        }

{- | Apply 'enrichEvent' to a list of events. When the hook is
'Nothing', returns the list unchanged with no traversal.
-}
enrichEvents :: StoreSettings -> [EventData] -> IO [EventData]
enrichEvents ss xs = case enrichEvent ss of
    Nothing -> pure xs
    Just f -> traverse f xs

{- | Apply 'decodeHook' to a vector of events. When the hook is
'Nothing', retains the vector unchanged without traversal or per-event wrappers.
-}
decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO DecodedBatch
decodeEvents ss xs = case decodeHook ss of
    Nothing -> pure (UnchangedBatch xs)
    Just f -> TransformedBatch <$> V.mapM (applyDecode f) xs

-- | Re-apply the hook to one raw undecodable event on a subscriber retry.
decodeEvent :: StoreSettings -> RecordedEvent -> IO DecodedEvent
decodeEvent ss event = case decodeHook ss of
    Nothing -> pure (Decoded event)
    Just f -> applyDecode f event

applyDecode :: (RecordedEvent -> IO (Either DecodeFailure RecordedEvent)) -> RecordedEvent -> IO DecodedEvent
applyDecode f event = either (Undecodable event) Decoded <$> f event
