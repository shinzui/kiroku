-- | Configuration for the Kiroku metrics web server.
module Kiroku.Metrics.Config (
    MetricsServerConfig (..),
    defaultConfig,
) where

import Data.Int (Int64)

{- | Configuration for the metrics web server. The @ws*@ fields are consumed by
the WebSocket endpoint (EP-3); they exist here so that plan needs no config
change. @readinessMaxLag@ is the Kiroku analogue of Marten's @maxEventLag@; it
defaults higher than Marten's 100 because Kiroku's lag is an /upper bound/ (see
the collector's lag limitation).
-}
data MetricsServerConfig = MetricsServerConfig
    { port :: !Int
    -- ^ Port to listen on (default: 9091).
    , enableJSON :: !Bool
    -- ^ Enable the JSON metrics and health endpoints (default: True).
    , enablePrometheus :: !Bool
    -- ^ Enable the Prometheus text-exposition endpoint (default: True).
    , enableWebSocket :: !Bool
    -- ^ Enable the WebSocket upgrade path (default: True; EP-3 makes it functional).
    , wsPushIntervalUs :: !Int
    -- ^ WebSocket live-push interval in microseconds (default: 1_000_000 = 1s).
    , wsMaxConnections :: !Int
    -- ^ Maximum concurrent WebSocket connections (default: 100).
    , readinessMaxLag :: !Int64
    -- ^ A subscription lagging beyond this fails readiness (default: 10_000).
    , livenessTimeoutUs :: !Int
    -- ^ Timeout for the liveness snapshot in microseconds (default: 1_000_000 = 1s).
    }
    deriving stock (Eq, Show)

-- | Default configuration: port 9091, all endpoints enabled.
defaultConfig :: MetricsServerConfig
defaultConfig =
    MetricsServerConfig
        { port = 9091
        , enableJSON = True
        , enablePrometheus = True
        , enableWebSocket = True
        , wsPushIntervalUs = 1_000_000
        , wsMaxConnections = 100
        , readinessMaxLag = 10_000
        , livenessTimeoutUs = 1_000_000
        }
