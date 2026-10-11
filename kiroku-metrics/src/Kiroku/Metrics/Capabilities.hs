{-# LANGUAGE NoFieldSelectors #-}

-- | Mount-relative discovery, computed from configuration and actual provider wiring.
module Kiroku.Metrics.Capabilities (
    WebSocketChannels (..),
    noWebSocketChannels,
    storeWebSocketChannels,
    ProviderPresence (..),
    RouteAvailability (..),
    Capabilities (..),
    capabilitiesFor,
    kirokuMetricsVersion,
    processLocalRoutes,
    capabilitiesApp,
    capabilitiesPath,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), encode, object, withObject, (.:), (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Network.HTTP.Types (status200, status404, status405)
import Network.Wai (Application, mapResponseHeaders, pathInfo, requestMethod, responseHeaders, responseLBS, responseStatus)

import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Cors qualified as Cors
import Kiroku.Metrics.JSON (errorResponse, jsonResponse)
import Paths_kiroku_metrics qualified as Paths

-- | Declaration by the host choosing the opaque WebSocket application.
data WebSocketChannels = WebSocketChannels
    {metricsChannel :: !Bool, eventsChannel :: !Bool}
    deriving stock (Eq, Show)

noWebSocketChannels, storeWebSocketChannels :: WebSocketChannels
noWebSocketChannels = WebSocketChannels False False
storeWebSocketChannels = WebSocketChannels True True

data ProviderPresence = ProviderPresence
    { hasSubscriptionStatus :: !Bool
    , hasCheckpointInventory :: !Bool
    , hasBrowser :: !Bool
    , hasDeadLetters :: !Bool
    , presentWebSocketChannels :: !WebSocketChannels
    }
    deriving stock (Eq, Show)

data RouteAvailability = RouteAvailability
    { metrics :: !Bool
    , prometheus :: !Bool
    , health :: !Bool
    , subscriptionsLive :: !Bool
    , subscriptionsCheckpoints :: !Bool
    , deadLetters :: !Bool
    , browse :: !Bool
    , websocketMetrics :: !Bool
    , websocketEvents :: !Bool
    }
    deriving stock (Eq, Show)

data Capabilities = Capabilities
    { package :: !Text
    , version :: !Text
    , routes :: !RouteAvailability
    , corsIsEnabled :: !Bool
    , processLocal :: ![Text]
    }
    deriving stock (Eq, Show)

kirokuMetricsVersion :: Text
kirokuMetricsVersion = T.pack (showVersion Paths.version)

-- | These answers describe only the process answering the request.
processLocalRoutes :: [Text]
processLocalRoutes = ["metrics", "prometheus", "health", "subscriptions_live", "websocket_metrics"]

capabilitiesFor :: MetricsServerConfig -> ProviderPresence -> Capabilities
capabilitiesFor cfg presence = Capabilities "kiroku-metrics" kirokuMetricsVersion availability (Cors.corsEnabled cfg.cors) processLocalRoutes
  where
    availability =
        RouteAvailability
            cfg.enableJSON
            cfg.enablePrometheus
            cfg.enableJSON
            presence.hasSubscriptionStatus
            presence.hasCheckpointInventory
            presence.hasDeadLetters
            presence.hasBrowser
            (cfg.enableWebSocket && presence.presentWebSocketChannels.metricsChannel)
            (cfg.enableWebSocket && presence.presentWebSocketChannels.eventsChannel)

instance ToJSON RouteAvailability where
    toJSON r =
        object
            [ "metrics" .= r.metrics
            , "prometheus" .= r.prometheus
            , "health" .= r.health
            , "subscriptions_live" .= r.subscriptionsLive
            , "subscriptions_checkpoints" .= r.subscriptionsCheckpoints
            , "dead_letters" .= r.deadLetters
            , "browse" .= r.browse
            , "websocket_metrics" .= r.websocketMetrics
            , "websocket_events" .= r.websocketEvents
            ]

instance FromJSON RouteAvailability where
    parseJSON = withObject "RouteAvailability" $ \o ->
        RouteAvailability
            <$> o .: "metrics"
            <*> o .: "prometheus"
            <*> o .: "health"
            <*> o .: "subscriptions_live"
            <*> o .: "subscriptions_checkpoints"
            <*> o .: "dead_letters"
            <*> o .: "browse"
            <*> o .: "websocket_metrics"
            <*> o .: "websocket_events"

instance ToJSON Capabilities where
    toJSON c =
        object
            [ "package" .= c.package
            , "version" .= c.version
            , "routes" .= c.routes
            , "cors" .= object ["enabled" .= c.corsIsEnabled]
            , "process_local" .= c.processLocal
            ]

instance FromJSON Capabilities where
    parseJSON = withObject "Capabilities" $ \o -> do
        corsObject <- o .: "cors"
        enabled <- withObject "cors" (.: "enabled") corsObject
        Capabilities <$> o .: "package" <*> o .: "version" <*> o .: "routes" <*> pure enabled <*> o .: "process_local"

capabilitiesPath :: [Text]
capabilitiesPath = ["capabilities"]

-- | No store access; the encoded body is shared by requests to this application.
capabilitiesApp :: Capabilities -> Application
capabilitiesApp caps = \req respond -> do
    let response
            | pathInfo req /= capabilitiesPath = errorResponse status404 "not_found" "Not found" Nothing
            | requestMethod req == "GET" || requestMethod req == "HEAD" = jsonResponse status200 body
            | otherwise =
                mapResponseHeaders (("Allow", "GET, HEAD") :) $
                    errorResponse status405 "method_not_allowed" "Use GET or HEAD." Nothing
    respond $
        if requestMethod req == "HEAD"
            then responseLBS (responseStatus response) (responseHeaders response) ""
            else response
  where
    body = encode caps
