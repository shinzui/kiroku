{- | Conversion from Kiroku's 'RecordedEvent' to Shibuya's 'Ingested' and
'Envelope' types.

== Envelope Mapping

@
RecordedEvent field   →  Envelope field
─────────────────────────────────────────
eventId (UUID)        →  messageId (Text)
globalPosition        →  cursor (CursorInt)
createdAt             →  enqueuedAt
(the event itself)    →  payload
(none)                →  partition = Nothing
(none)                →  traceContext = Nothing
@

A production adapter could populate @traceContext@ from the event's
@metadata@ field if it carries W3C trace headers.
-}
module Shibuya.Adapter.Kiroku.Convert (
    -- * Conversion
    toIngested,
    toEnvelope,
) where

import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
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
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))

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
    let RecordedEvent{eventId = EventId uuid, globalPosition = GlobalPosition pos, createdAt = ts} = event
     in Envelope
            { messageId = MessageId (T.pack (UUID.toString uuid))
            , cursor = Just (CursorInt (fromIntegral pos))
            , partition = Nothing
            , enqueuedAt = Just ts
            , traceContext = Nothing
            , attempt = Nothing
            , attributes = HashMap.empty
            , payload = event
            }
