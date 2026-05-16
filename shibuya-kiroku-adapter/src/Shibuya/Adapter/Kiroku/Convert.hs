{- | Conversion from Kiroku's 'RecordedEvent' to Shibuya's 'Ingested' and
'Envelope' types.

== Envelope Mapping

@
RecordedEvent field   →  Envelope field
─────────────────────────────────────────
eventId (UUID)        →  messageId (Text)
globalPosition        →  cursor (CursorInt)
createdAt             →  enqueuedAt
metadata.traceparent  →  traceContext
(the event itself)    →  payload
(none)                →  partition = Nothing
@

The adapter preserves W3C trace-context metadata when @metadata@ is a JSON
object containing a string @traceparent@ key. A string @tracestate@ key is
included when present.
-}
module Shibuya.Adapter.Kiroku.Convert (
    -- * Conversion
    toIngested,
    toEnvelope,
) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Effectful (IOE, liftIO, (:>))
import Kiroku.Store.Types (
    EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
 )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

{- | Wrap a 'RecordedEvent' into an 'Ingested' value suitable for Shibuya
handlers.

The 'AckHandle' semantics:

* 'AckOk', 'AckRetry', 'AckDeadLetter' — no-op (checkpoint is managed by
  the Kiroku subscription worker, not by the handler).
* 'AckHalt' — invokes the provided cancel action, stopping the underlying
  Kiroku subscription.
-}
toIngested :: (IOE :> es) => IO () -> RecordedEvent -> Ingested es RecordedEvent
toIngested cancelAction event =
    Ingested
        { envelope = toEnvelope event
        , ack =
            AckHandle
                { finalize = \case
                    AckHalt _ -> liftIO cancelAction
                    _ -> pure ()
                }
        , lease = Nothing
        }

{- | Convert a 'RecordedEvent' to a Shibuya 'Envelope'.

The event's UUID is formatted as text for the 'MessageId', and the
global position is used as an integer 'Cursor' for ordering.
-}
toEnvelope :: RecordedEvent -> Envelope RecordedEvent
toEnvelope event =
    let RecordedEvent{eventId = EventId uuid, globalPosition = GlobalPosition pos, createdAt = ts, metadata = meta} = event
     in Envelope
            { messageId = MessageId (T.pack (UUID.toString uuid))
            , cursor = Just (CursorInt (fromIntegral pos))
            , partition = Nothing
            , enqueuedAt = Just ts
            , traceContext = metadataTraceContext meta
            , attempt = Nothing
            , attributes = HashMap.empty
            , payload = event
            }

metadataTraceContext :: Maybe Value -> Maybe TraceHeaders
metadataTraceContext (Just (Object metadata)) = do
    String traceparent <- KM.lookup (Key.fromString "traceparent") metadata
    let traceparentHeader = ("traceparent", TE.encodeUtf8 traceparent)
        traceHeaders =
            case KM.lookup (Key.fromString "tracestate") metadata of
                Just (String tracestate) -> [traceparentHeader, ("tracestate", TE.encodeUtf8 tracestate)]
                _ -> [traceparentHeader]
    pure traceHeaders
metadataTraceContext _ = Nothing
