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
take a 'pure' fast path that allocates nothing extra; no traversal of
the events list or vector occurs.

A typical use case is enriching every appended event with an
OpenTelemetry trace context drawn from the calling thread:

@
storeSettings = 'defaultStoreSettings'
  { 'enrichEvent' = Just $ \\ed -> do
      ctx <- captureCurrentSpan        -- OpenTelemetry, OTLP, whatever
      pure (ed & #metadata %~ injectTraceContext ctx)
  , 'decodeHook' = Just $ \\re ->
      pure (re & #metadata %~ Just . redactPII)
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
    decodeEvents,
) where

import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Kiroku.Store.Types (EventData, RecordedEvent)

{- | Interpreter-level hooks for cross-cutting concerns at the
event-data boundary. All fields default to 'Nothing' (no-op).

* 'enrichEvent' fires on the append path before the SQL encoder runs,
  on the typed 'EventData' the caller supplied. Used to inject trace
  contexts, attach tenant ids, or encrypt payloads.

* 'decodeHook' fires on the read and subscription paths after the SQL
  decoder runs, on the typed 'RecordedEvent' about to be surfaced to
  the caller. Used to decrypt payloads, redact PII, or attach derived
  metadata.

When a field is 'Nothing', the interpreter takes a @pure@ fast path
that does not allocate or traverse.
-}
data StoreSettings = StoreSettings
    { enrichEvent :: !(Maybe (EventData -> IO EventData))
    -- ^ Append-path hook. Runs once per appended event before encoding.
    , decodeHook :: !(Maybe (RecordedEvent -> IO RecordedEvent))
    -- ^ Read- and subscription-path hook. Runs once per surfaced event.
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
'Nothing', returns the vector unchanged with no traversal.
-}
decodeEvents :: StoreSettings -> Vector RecordedEvent -> IO (Vector RecordedEvent)
decodeEvents ss xs = case decodeHook ss of
    Nothing -> pure xs
    Just f -> V.mapM f xs
