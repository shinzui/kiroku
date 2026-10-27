-- | Configuration for the Kiroku metrics web server.
module Kiroku.Metrics.Config
  ( MetricsServerConfig (..),
    defaultConfig,
  )
where

import Data.Int (Int64)
import Numeric.Natural (Natural)

import Kiroku.Metrics.Cors (CorsPolicy, corsDisabled)

-- | Configuration for the metrics web server. The @ws*@ fields are consumed by
-- the WebSocket endpoint (EP-3); they exist here so that plan needs no config
-- change. @readinessMaxLag@ is the Kiroku analogue of Marten's @maxEventLag@; it
-- defaults higher than Marten's 100 because Kiroku's lag is an /upper bound/ (see
-- the collector's lag limitation).
data MetricsServerConfig = MetricsServerConfig
  { -- | Port to listen on (default: 9091).
    port :: !Int,
    -- | Enable the JSON metrics and health endpoints (default: True).
    enableJSON :: !Bool,
    -- | Enable the Prometheus text-exposition endpoint (default: True).
    enablePrometheus :: !Bool,
    -- | Enable the WebSocket upgrade path (default: True; EP-3 makes it functional).
    enableWebSocket :: !Bool,
    -- | WebSocket live-push interval in microseconds (default: 1_000_000 = 1s).
    wsPushIntervalUs :: !Int,
    -- | Maximum concurrent WebSocket connections (default: 100).
    wsMaxConnections :: !Int,
    -- | Per-connection broadcast queue capacity, in batches, for the event
    --     stream tail (default: 256). Additive field introduced by EP-3; under
    --     'Kiroku.Store.Subscription.Types.DropOldest' a slow client drops the
    --     oldest undelivered batches rather than stalling the publisher.
    wsEventQueueCap :: !Natural,
    -- | A subscription lagging beyond this fails readiness (default: 10_000).
    readinessMaxLag :: !Int64,
    -- | Timeout for the liveness snapshot in microseconds (default: 1_000_000 = 1s).
    livenessTimeoutUs :: !Int,
    -- | Explicit browser origins; disabled by default for HTTP and WebSocket alike.
    cors :: !CorsPolicy
  }
  deriving stock (Eq, Show)

-- | Default configuration: port 9091, all endpoints enabled.
defaultConfig :: MetricsServerConfig
defaultConfig =
  MetricsServerConfig
    { port = 9091,
      enableJSON = True,
      enablePrometheus = True,
      enableWebSocket = True,
      wsPushIntervalUs = 1_000_000,
      wsMaxConnections = 100,
      wsEventQueueCap = 256,
      readinessMaxLag = 10_000,
      livenessTimeoutUs = 1_000_000,
      cors = corsDisabled
    }
