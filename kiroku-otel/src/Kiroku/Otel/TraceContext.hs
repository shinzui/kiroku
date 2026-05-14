{- | W3C trace-context helpers that read and write @traceparent@ /
@tracestate@ header strings inside Kiroku event metadata.

The on-the-wire JSON shape inside the event's @metadata@ JSONB column is:

> {
>   "traceparent": "00-<32-hex traceId>-<16-hex spanId>-<2-hex flags>",
>   "tracestate":  "<vendor entries, optional>"
> }

Other keys in @metadata@ are preserved by 'injectTraceContext'.
-}
module Kiroku.Otel.TraceContext (
    injectTraceContext,
    extractTraceContext,
) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO (unsafePerformIO)
import Kiroku.Store.Types (EventData (..), RecordedEvent (..))
import OpenTelemetry.Propagator.W3CTraceContext (decodeSpanContext, encodeSpanContext)
import OpenTelemetry.Trace.Core (SpanContext, wrapSpanContext)

{- | Encode a 'SpanContext' as W3C @traceparent@ / @tracestate@ strings and
merge them into the @metadata@ JSON object of an 'EventData'. Existing
keys in @metadata@ are preserved; existing @traceparent@ / @tracestate@
keys (if any) are overwritten — the W3C spec mandates exactly one of
each value per propagation.

If the input @metadata@ is 'Nothing', or is a non-object JSON value,
the helper starts from an empty object before merging.

This function is pure: it uses 'unsafePerformIO' to call
'encodeSpanContext', which is observably pure on the frozen span
returned by 'wrapSpanContext' (no shared mutable state, no exceptions).
The \"unsafe\" annotation is mandatory to bridge the propagator's
@IO@-typed encoder to the pure interface this module exposes.
-}
{-# NOINLINE injectTraceContext #-}
injectTraceContext :: SpanContext -> EventData -> EventData
injectTraceContext sc ed =
    case ed of
        EventData{metadata = oldMeta} ->
            ed{metadata = Just (Object (mergeTraceContext sc oldMeta))} :: EventData

{- | Pull a 'SpanContext' back out of a 'RecordedEvent'\'s @metadata@.
Returns 'Nothing' when @metadata@ is absent, is not a JSON object,
lacks a @traceparent@ key, or contains a @traceparent@ value that fails
W3C parsing. Never throws.
-}
extractTraceContext :: RecordedEvent -> Maybe SpanContext
extractTraceContext re = case re of
    RecordedEvent{metadata = Just (Object o)} -> decodeFromObject o
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

mergeTraceContext :: SpanContext -> Maybe Value -> KeyMap Value
mergeTraceContext sc mMeta =
    let (tp, ts) = unsafePerformIO (encodeSpanContext (wrapSpanContext sc))
        tpText = TE.decodeUtf8 tp
        tsText = TE.decodeUtf8 ts
        existing = case mMeta of
            Just (Object o) -> o
            _ -> KM.empty
        withTp = KM.insert (Key.fromText (T.pack "traceparent")) (String tpText) existing
     in if T.null tsText
            then withTp
            else KM.insert (Key.fromText (T.pack "tracestate")) (String tsText) withTp

decodeFromObject :: KeyMap Value -> Maybe SpanContext
decodeFromObject o = do
    String tpText <- KM.lookup (Key.fromText (T.pack "traceparent")) o
    let tpBs :: ByteString
        tpBs = TE.encodeUtf8 tpText
        tsBs = case KM.lookup (Key.fromText (T.pack "tracestate")) o of
            Just (String tsText) -> Just (TE.encodeUtf8 tsText)
            _ -> Nothing
    decodeSpanContext (Just tpBs) tsBs
