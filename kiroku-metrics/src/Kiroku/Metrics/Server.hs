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
    startMetricsServerWith',
    startMetricsServerWithStore,
    stopMetricsServer,
    withMetricsServer,
    withMetricsServerWithStore,
    withMetricsServerSubscriptions,
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
import Kiroku.Metrics.Subscriptions (SubscriptionStatusProvider, subscriptionsApp)
import Kiroku.Metrics.WebSocket (newWebSocketState, websocketApp)
import Kiroku.Store (KirokuStore)

-- | A running metrics server: the Warp thread and the port it bound.
data MetricsServer = MetricsServer
    { serverThread :: !(Async ())
    , serverPort :: !Int
    }

{- | Start the server with the rejecting WebSocket stub. Use this until EP-3's
real WebSocket app is wired via 'startMetricsServerWith'.
-}
startMetricsServer :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO MetricsServer
startMetricsServer cfg m deps = startMetricsServerWith' cfg m deps Nothing stubWebSocketApp

{- | Start the server with an explicit WebSocket app (the IP-3 seam) and no
subscription-status provider. When @cfg.port == 0@ an OS-assigned free port is
used and reported in 'serverPort'.
-}
startMetricsServerWith ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    WS.ServerApp ->
    IO MetricsServer
startMetricsServerWith cfg m deps = startMetricsServerWith' cfg m deps Nothing

{- | Start the server with an explicit WebSocket app (the IP-3 seam) /and/ an
optional subscription-status provider (the IP-5 seam, EP-5). The provider, when
@Just@, serves @GET /subscriptions@; when @Nothing@, that route returns a
configured-404. All EP-2/EP-3 starters delegate here with @Nothing@.
-}
startMetricsServerWith' ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    Maybe SubscriptionStatusProvider ->
    WS.ServerApp ->
    IO MetricsServer
startMetricsServerWith' cfg m deps mProvider wsApp = do
    let app = combinedApp cfg m deps mProvider wsApp
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

{- | Start the server with the real WebSocket app (EP-3), which streams live
metrics and events out of the given 'KirokuStore'. This is the recommended entry
point once event streaming is wanted: it allocates one shared connection-limiting
state (bounded by @cfg.wsMaxConnections@) and wires
'Kiroku.Metrics.WebSocket.websocketApp'. EP-2's 'startMetricsServer' (stub) is
unchanged for callers who do not want the WebSocket.
-}
startMetricsServerWithStore ::
    MetricsServerConfig ->
    KirokuMetrics ->
    KirokuStore ->
    [DependencyCheck] ->
    IO MetricsServer
startMetricsServerWithStore cfg m store deps = do
    wsState <- newWebSocketState cfg.wsMaxConnections
    startMetricsServerWith cfg m deps (websocketApp cfg m store wsState)

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

{- | Run an action with a running store-aware server (EP-3 WebSocket), tearing
it down afterwards.
-}
withMetricsServerWithStore ::
    MetricsServerConfig ->
    KirokuMetrics ->
    KirokuStore ->
    [DependencyCheck] ->
    (MetricsServer -> IO a) ->
    IO a
withMetricsServerWithStore cfg m store deps =
    bracket (startMetricsServerWithStore cfg m store deps) stopMetricsServer

{- | Run an action with a server that serves @GET /subscriptions@ from the given
provider (EP-5), using the rejecting WebSocket stub. The common case for a worker
that wants remote subscription introspection but not the event-streaming socket.
-}
withMetricsServerSubscriptions ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    SubscriptionStatusProvider ->
    (MetricsServer -> IO a) ->
    IO a
withMetricsServerSubscriptions cfg m deps provider =
    bracket
        (startMetricsServerWith' cfg m deps (Just provider) stubWebSocketApp)
        stopMetricsServer

-- | The combined WAI app: WebSocket upgrades to @wsApp@, everything else to the HTTP router.
combinedApp ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    Maybe SubscriptionStatusProvider ->
    WS.ServerApp ->
    Application
combinedApp cfg m deps mProvider wsApp =
    WaiWS.websocketsOr WS.defaultConnectionOptions wsApp (httpApp cfg m deps mProvider)

{- | The EP-2 WebSocket stub: reject the upgrade with a clear message. EP-3
replaces this with the real event-streaming app.
-}
stubWebSocketApp :: WS.ServerApp
stubWebSocketApp pending = WS.rejectRequest pending "WebSocket endpoint not yet implemented"

-- | HTTP router. Matches @/metrics/prometheus@ before @/metrics/\<name\>@.
httpApp ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    Maybe SubscriptionStatusProvider ->
    Application
httpApp cfg m deps mProvider req respond =
    case pathInfo req of
        ["metrics", "prometheus"] | cfg.enablePrometheus -> prometheusApp m req respond
        ["metrics"] | cfg.enableJSON -> jsonApp m req respond
        ["metrics", _] | cfg.enableJSON -> jsonApp m req respond
        ["subscriptions"] -> subscriptionsRoute
        ["subscriptions", _] -> subscriptionsRoute
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
    subscriptionsRoute = case mProvider of
        Just provider -> subscriptionsApp provider req respond
        Nothing ->
            respond $
                jsonResponse
                    status404
                    (encode (object ["error" .= ("subscription status not configured" :: Text)]))
