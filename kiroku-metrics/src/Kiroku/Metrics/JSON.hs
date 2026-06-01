{- | JSON HTTP endpoints: @GET /metrics@ (the full snapshot) and
@GET /metrics/\<name\>@ (one subscription's metrics, or 404).
-}
module Kiroku.Metrics.JSON (
    jsonApp,
    jsonResponse,
) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Network.HTTP.Types (Status, hContentType, status200, status404)
import Network.Wai (Application, Response, pathInfo, responseLBS)

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Types (MetricsSnapshot (..))

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
