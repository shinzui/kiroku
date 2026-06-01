{- | The combined metrics web server.

Builds a single WAI 'Application' with 'WaiWS.websocketsOr': WebSocket upgrades
go to a 'WS.ServerApp' seam, everything else to the HTTP router. EP-2 supplies a
rejecting stub for the seam ('stubWebSocketApp'); EP-3 replaces it with the real
event-streaming app via 'startMetricsServerWith' without changing this module.

The server takes 'KirokuMetrics' plus a list of 'DependencyCheck's and a
'WS.ServerApp' — it does /not/ take the 'KirokuStore' directly. Everything
store-specific is captured in caller-built closures ('postgresPing' over the
pool, and EP-3's WebSocket app over the store), keeping the server store-agnostic.
-}
module Kiroku.Metrics.Server (
    MetricsServer (..),
    startMetricsServer,
    startMetricsServerWith,
    stopMetricsServer,
    withMetricsServer,
    combinedApp,
    httpApp,
    stubWebSocketApp,
) where

import Control.Concurrent.Async (Async, async, cancel)
import Control.Exception (bracket)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Network.HTTP.Types (status200, status404, status503)
import Network.Wai (Application, pathInfo)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS

import Kiroku.Metrics.Collector (KirokuMetrics)
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Health (
    DependencyCheck,
    LivenessStatus (..),
    ReadinessStatus (..),
    checkDetailedHealth,
    checkLiveness,
    checkReadiness,
 )
import Kiroku.Metrics.JSON (jsonApp, jsonResponse)
import Kiroku.Metrics.Prometheus (prometheusApp)

-- | A running metrics server: the Warp thread and the port it bound.
data MetricsServer = MetricsServer
    { serverThread :: !(Async ())
    , serverPort :: !Int
    }

{- | Start the server with the rejecting WebSocket stub. Use this until EP-3's
real WebSocket app is wired via 'startMetricsServerWith'.
-}
startMetricsServer :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO MetricsServer
startMetricsServer cfg m deps = startMetricsServerWith cfg m deps stubWebSocketApp

{- | Start the server with an explicit WebSocket app (the IP-3 seam). When
@cfg.port == 0@ an OS-assigned free port is used and reported in
'serverPort'.
-}
startMetricsServerWith ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    WS.ServerApp ->
    IO MetricsServer
startMetricsServerWith cfg m deps wsApp = do
    let app = combinedApp cfg m deps wsApp
    if cfg.port == 0
        then do
            (actualPort, sock) <- Warp.openFreePort
            let settings = Warp.setPort actualPort Warp.defaultSettings
            thread <- async (Warp.runSettingsSocket settings sock app)
            pure (MetricsServer thread actualPort)
        else do
            let settings = Warp.setHost "*" (Warp.setPort cfg.port Warp.defaultSettings)
            thread <- async (Warp.runSettings settings app)
            pure (MetricsServer thread cfg.port)

-- | Stop the server by cancelling its Warp thread.
stopMetricsServer :: MetricsServer -> IO ()
stopMetricsServer server = cancel server.serverThread

-- | Run an action with a running server, tearing it down afterwards.
withMetricsServer ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    (MetricsServer -> IO a) ->
    IO a
withMetricsServer cfg m deps =
    bracket (startMetricsServer cfg m deps) stopMetricsServer

-- | The combined WAI app: WebSocket upgrades to @wsApp@, everything else to the HTTP router.
combinedApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> Application
combinedApp cfg m deps wsApp =
    WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps)

{- | The EP-2 WebSocket stub: reject the upgrade with a clear message. EP-3
replaces this with the real event-streaming app.
-}
stubWebSocketApp :: WS.ServerApp
stubWebSocketApp pending = WS.rejectRequest pending "WebSocket endpoint not yet implemented"

-- | HTTP router. Matches @/metrics/prometheus@ before @/metrics/\<name\>@.
httpApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> Application
httpApp cfg m deps req respond =
    case pathInfo req of
        ["metrics", "prometheus"] | cfg.enablePrometheus -> prometheusApp m req respond
        ["metrics"] | cfg.enableJSON -> jsonApp m req respond
        ["metrics", _] | cfg.enableJSON -> jsonApp m req respond
        ["health"] | cfg.enableJSON -> do
            (readiness, snap) <- checkDetailedHealth cfg m deps
            respond $
                jsonResponse
                    (statusFor readiness.ready)
                    (encode (object ["status" .= readiness, "metrics" .= snap]))
        ["health", "live"] | cfg.enableJSON -> do
            liveness <- checkLiveness cfg m
            respond (jsonResponse (statusFor liveness.alive) (encode liveness))
        ["health", "ready"] | cfg.enableJSON -> do
            readiness <- checkReadiness cfg m deps
            respond (jsonResponse (statusFor readiness.ready) (encode readiness))
        ["ws"]
            | cfg.enableWebSocket ->
                respond $
                    jsonResponse
                        status404
                        (encode (object ["error" .= ("WebSocket endpoint - use ws:// protocol" :: Text)]))
        _ ->
            respond (jsonResponse status404 (encode (object ["error" .= ("Not found" :: Text)])))
  where
    statusFor ok = if ok then status200 else status503
