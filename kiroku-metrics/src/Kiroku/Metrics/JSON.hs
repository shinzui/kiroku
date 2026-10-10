{- | JSON HTTP endpoints: @GET /metrics@ (the full snapshot) and
@GET /metrics/\<name\>@ (one subscription's metrics, or 404).
-}
module Kiroku.Metrics.JSON (
    jsonApp,
    jsonResponse,
    errorEnvelope,
    errorResponse,
    storeErrorResponse,
) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Network.HTTP.Types (Status, hContentType, status200, status404, status500, status503)
import Network.Wai (Application, Response, pathInfo, responseLBS)

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Types (MetricsSnapshot (..))
import Kiroku.Store.Error (StoreError (..))

{- | WAI application for the JSON metrics endpoints. Routes @/metrics@ and
@/metrics/\<name\>@; any other path returns a 404 JSON body.
-}
jsonApp :: KirokuMetrics -> Application
jsonApp m req respond = do
    resp <- case pathInfo req of
        ["metrics"] -> do
            snap <- snapshotMetrics m
            pure (jsonResponse status200 (encode snap))
        ["metrics", name] -> do
            snap <- snapshotMetrics m
            pure $ case Map.lookup name snap.subscriptions of
                Just sm -> jsonResponse status200 (encode sm)
                Nothing ->
                    jsonResponse status404 $
                        encode $
                            object
                                [ "error" .= ("subscription not found" :: Text)
                                , "subscription" .= name
                                ]
        _ -> pure (jsonResponse status404 (encode (object ["error" .= ("Not found" :: Text)])))
    respond resp

-- | Build an @application/json@ response with the given status and body.
jsonResponse :: Status -> LBS.ByteString -> Response
jsonResponse status = responseLBS status [(hContentType, "application/json")]

-- | Shared structured error for new inspection routes; legacy errors stay unchanged.
errorEnvelope :: Text -> Text -> Maybe Value -> Value
errorEnvelope code message details =
    object ["error" .= object (["code" .= code, "message" .= message] <> maybe [] (\v -> ["details" .= v]) details)]

-- | Build a JSON error, omitting @details@ when absent.
errorResponse :: Status -> Text -> Text -> Maybe Value -> Response
errorResponse status code message = jsonResponse status . encode . errorEnvelope code message

{- | Sanitize store failures without exposing connection strings or event payloads.
This function handles values only and never catches asynchronous exceptions.
-}
storeErrorResponse :: Text -> StoreError -> Response
storeErrorResponse unavailableCode = \case
    ConnectionError _ -> errorResponse status503 unavailableCode "The event store is unavailable." Nothing
    EventDecodeFailed _ -> errorResponse status500 "event_decode_failed" "An event could not be decoded." Nothing
    _ -> errorResponse status500 "store_error" "The event store operation failed." Nothing
