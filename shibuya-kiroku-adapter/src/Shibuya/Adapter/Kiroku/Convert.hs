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
    toIngestedAck,
    toEnvelope,

    -- * Ack-decision translation
    toKirokuResult,
    toKirokuDeadLetterReason,
) where

import Control.Concurrent.STM (atomically, tryPutTMVar)
import Control.Monad (void)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.HashMap.Strict qualified as HashMap
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Effectful (IOE, liftIO, (:>))
import Kiroku.Store.Subscription.Stream (AckItem (..))
import Kiroku.Store.Subscription.Types (
    DeadLetterReason (..),
    RetryDelay (..),
    SubscriptionResult (..),
 )
import Kiroku.Store.Types (
    EventId (..),
    GlobalPosition (..),
    RecordedEvent (..),
 )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ack qualified as Ack
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

{- | Wrap an ack-coupled 'AckItem' (from @kiroku-store@'s 'subscriptionAckStream')
into an 'Ingested' value suitable for Shibuya handlers.

The underlying Kiroku worker is blocked waiting for this item's reply, so the
'AckHandle.finalize' translates the Shibuya 'AckDecision' into a Kiroku
'SubscriptionResult' and writes it back — driving the worker's checkpointing:

* 'AckOk' — reply 'Continue'; the worker checkpoints past the event.
* 'AckRetry' @delay@ — reply 'Retry'; the worker redelivers the same event after
  @delay@, bounded by the subscription's retry policy, then dead-letters it.
* 'AckDeadLetter' @reason@ — reply 'DeadLetter'; the worker records the event in
  @kiroku.dead_letters@ and advances past it.
* 'AckHalt' — cancels the underlying Kiroku subscription (no checkpoint advance,
  so the halting event replays on restart), preserving the prior adapter
  behavior; the blocked worker is interrupted by the cancellation.

'finalize' is idempotent: the reply is written with 'tryPutTMVar' so a second
call is a no-op.

The envelope's @attempt@ is set from the item's redelivery counter so a Shibuya
handler can observe how many times Kiroku has redelivered the event.
-}
toIngestedAck :: (IOE :> es) => IO () -> AckItem -> Ingested es RecordedEvent
toIngestedAck cancelAction (AckItem event attempt reply) =
    Ingested
        { envelope = (toEnvelope event){attempt = Just (Attempt attempt)}
        , ack =
            AckHandle
                { finalize = \case
                    AckHalt _ -> liftIO cancelAction
                    decision ->
                        liftIO $
                            atomically $
                                void $
                                    tryPutTMVar reply (toKirokuResult attempt decision)
                }
        , lease = Nothing
        }

{- | Translate a non-halt Shibuya 'AckDecision' into a Kiroku
'SubscriptionResult'. 'AckHalt' is handled separately (it cancels the
subscription) and maps to 'Continue' here only defensively. The 'Word' is the
event's current redelivery attempt, used to annotate a 'MaxRetriesExceeded'
reason.
-}
toKirokuResult :: Word -> AckDecision -> SubscriptionResult
toKirokuResult attempt = \case
    AckOk -> Continue
    AckRetry (Ack.RetryDelay d) -> Retry (RetryDelay d)
    AckDeadLetter reason -> DeadLetter (toKirokuDeadLetterReason attempt reason)
    AckHalt _ -> Continue

-- | Translate a Shibuya 'Ack.DeadLetterReason' into a Kiroku 'DeadLetterReason'.
toKirokuDeadLetterReason :: Word -> Ack.DeadLetterReason -> DeadLetterReason
toKirokuDeadLetterReason attempt = \case
    Ack.PoisonPill detail -> DeadLetterPoison detail
    Ack.InvalidPayload detail -> DeadLetterInvalid detail
    Ack.MaxRetriesExceeded -> DeadLetterMaxAttempts (fromIntegral attempt)

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
