{- | The shared inspection composition. Store-backed behavior enters through
provider closures; HTTP and WebSocket dispatch share a mount-relative path and
one outer CORS policy. Legacy starters retain their signatures.
-}
module Kiroku.Metrics.Server (
    MetricsServer (..),
    ServerProviders (..),
    defaultServerProviders,
    storeServerProviders,
    startMetricsServerWithProviders,
    withMetricsServerWithProviders,
    combinedAppWithProviders,
    httpAppWithProviders,
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

import Control.Concurrent.Async (Async, asyncWithUnmask, cancel, race, wait, waitCatchSTM)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, orElse, putTMVar, readTMVar)
import Control.Exception (bracket, finally, mask, onException, throwIO)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Network.HTTP.Types (status200, status404, status503)
import Network.HTTP.Types.URI (encodePathSegments)
import Network.Socket qualified as Socket
import Network.Wai (Application, pathInfo, rawPathInfo)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS

import Kiroku.Metrics.Browse (StoreBrowser, browseApp, browseNotConfiguredApp, storeBrowser)
import Kiroku.Metrics.Checkpoints (CheckpointInventoryProvider, checkpointsApp, checkpointsNotConfiguredApp, storeCheckpointInventory)
import Kiroku.Metrics.Collector (KirokuMetrics)
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Cors (corsMiddleware)
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
import Kiroku.Metrics.Subscriptions (SubscriptionStatusProvider, storeSubscriptionStatus, subscriptionsApp)
import Kiroku.Metrics.WebSocket (newWebSocketState, websocketApp)
import Kiroku.Store (KirokuStore)

-- | A running metrics server: the Warp thread and the port it bound.
data MetricsServer = MetricsServer
    { serverThread :: !(Async ())
    , serverPort :: !Int
    }

-- | Optional data sources for the shared inspection application.
data ServerProviders = ServerProviders
    { webSocketServer :: !WS.ServerApp
    , subscriptionStatus :: !(Maybe SubscriptionStatusProvider)
    , checkpointInventory :: !(Maybe CheckpointInventoryProvider)
    , storeBrowsing :: !(Maybe StoreBrowser)
    -- ^ Backs the stream, category and event inspection routes.
    }

-- | Reject upgrades and leave all optional providers unconfigured.
defaultServerProviders :: ServerProviders
defaultServerProviders = ServerProviders stubWebSocketApp Nothing Nothing Nothing

{- | Build every store-backed provider, including the process-local live registry.
Bind this action first, then use 'withMetricsServerWithProviders'.
-}
storeServerProviders :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> IO ServerProviders
storeServerProviders cfg m store = do
    wsState <- newWebSocketState cfg.wsMaxConnections
    pure $ ServerProviders (websocketApp cfg m store wsState) (Just (storeSubscriptionStatus store)) (Just (storeCheckpointInventory store)) (Just (storeBrowser store))

{- | Return only after Warp is ready; bind/setup failures are rethrown.
Ephemeral sockets are explicitly closed on every exit, including cancellation.
-}
startMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> IO MetricsServer
startMetricsServerWithProviders cfg m deps providers = mask $ \restore -> do
    ready <- newEmptyTMVarIO
    let app = combinedAppWithProviders cfg m deps providers
        settings port = Warp.setBeforeMainLoop (atomically $ putTMVar ready ()) $ Warp.setHost "*" $ Warp.setPort port Warp.defaultSettings
        await thread port = do
            result <- restore (atomically $ (Left <$> waitCatchSTM thread) `orElse` (Right <$> readTMVar ready)) `onException` cancel thread
            case result of
                Left (Left err) -> throwIO err
                Left (Right ()) -> fail "Metrics server terminated before readiness."
                Right () -> pure (MetricsServer thread port)
    if cfg.port == 0
        then do
            (port, sock) <- Warp.openFreePort
            thread <- asyncWithUnmask (\unmask -> unmask (Warp.runSettingsSocket (settings port) sock app) `finally` Socket.close sock) `onException` Socket.close sock
            await thread port
        else do
            thread <- asyncWithUnmask (\unmask -> unmask $ Warp.runSettings (settings cfg.port) app)
            await thread cfg.port

{- | Supervise the callback and the server together, then release both.
Unexpected server termination cancels the callback and is rethrown to the owner.
-}
withMetricsServerWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> (MetricsServer -> IO a) -> IO a
withMetricsServerWithProviders cfg m deps providers action =
    withRunningServer (startMetricsServerWithProviders cfg m deps providers) action

withRunningServer :: IO MetricsServer -> (MetricsServer -> IO a) -> IO a
withRunningServer acquire action = bracket acquire stopMetricsServer $ \server -> do
    result <- race (wait server.serverThread) (action server)
    either (\() -> fail "Metrics server terminated unexpectedly.") pure result

-- | Start with the rejecting WebSocket stub and no optional providers.
startMetricsServer :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO MetricsServer
startMetricsServer cfg m deps = startMetricsServerWithProviders cfg m deps defaultServerProviders

-- | Start with a caller-supplied WebSocket app and no optional providers.
startMetricsServerWith :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> WS.ServerApp -> IO MetricsServer
startMetricsServerWith cfg m deps = startMetricsServerWith' cfg m deps Nothing

-- | Legacy binding of a WebSocket app and optional live status provider.
startMetricsServerWith' :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> Maybe SubscriptionStatusProvider -> WS.ServerApp -> IO MetricsServer
startMetricsServerWith' cfg m deps mProvider wsApp =
    startMetricsServerWithProviders cfg m deps defaultServerProviders{webSocketServer = wsApp, subscriptionStatus = mProvider}

{- | Serve the real WebSocket and durable inventory; the legacy live route stays
unconfigured. New hosts wanting every provider use 'storeServerProviders'.
-}
startMetricsServerWithStore :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> [DependencyCheck] -> IO MetricsServer
startMetricsServerWithStore cfg m store deps = do
    providers <- storeServerProviders cfg m store
    startMetricsServerWithProviders cfg m deps providers{subscriptionStatus = Nothing}

stopMetricsServer :: MetricsServer -> IO ()
stopMetricsServer server = cancel server.serverThread

withMetricsServer :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> (MetricsServer -> IO a) -> IO a
withMetricsServer cfg m deps = withMetricsServerWithProviders cfg m deps defaultServerProviders

withMetricsServerWithStore :: MetricsServerConfig -> KirokuMetrics -> KirokuStore -> [DependencyCheck] -> (MetricsServer -> IO a) -> IO a
withMetricsServerWithStore cfg m store deps = withRunningServer (startMetricsServerWithStore cfg m store deps)

withMetricsServerSubscriptions :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> SubscriptionStatusProvider -> (MetricsServer -> IO a) -> IO a
withMetricsServerSubscriptions cfg m deps provider =
    withMetricsServerWithProviders cfg m deps defaultServerProviders{subscriptionStatus = Just provider}

-- | Legacy composition binding. CORS is applied once by the general composition.
combinedApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> Maybe SubscriptionStatusProvider -> WS.ServerApp -> Application
combinedApp cfg m deps mProvider wsApp =
    combinedAppWithProviders cfg m deps defaultServerProviders{webSocketServer = wsApp, subscriptionStatus = mProvider}

{- | Mountable composition. Respect the WebSocket switch before upgrade dispatch.
Normalize only the dispatch copy's raw path; keep its original query string.
-}
combinedAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
combinedAppWithProviders cfg m deps providers = corsMiddleware cfg.cors dispatch
  where
    http = httpAppWithProviders cfg m deps providers
    dispatch req respond
        | cfg.enableWebSocket =
            let relativePath = LBS.toStrict $ toLazyByteString $ encodePathSegments (pathInfo req)
             in WaiWS.websocketsOr WS.defaultConnectionOptions providers.webSocketServer http (req{rawPathInfo = relativePath}) respond
        | otherwise = http req respond

stubWebSocketApp :: WS.ServerApp
stubWebSocketApp pending = WS.rejectRequest pending "WebSocket endpoint not yet implemented"

-- | Legacy unwrapped HTTP binding.
httpApp :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> Maybe SubscriptionStatusProvider -> Application
httpApp cfg m deps mProvider = httpAppWithProviders cfg m deps defaultServerProviders{subscriptionStatus = mProvider}

-- | Unwrapped HTTP router, matching paths relative to the host's mount.
httpAppWithProviders :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> ServerProviders -> Application
httpAppWithProviders cfg m deps providers req respond =
    case pathInfo req of
        ["metrics", "prometheus"] | cfg.enablePrometheus -> prometheusApp m req respond
        ["metrics"] | cfg.enableJSON -> jsonApp m req respond
        ["metrics", _] | cfg.enableJSON -> jsonApp m req respond
        prefix : _ | prefix `elem` ["streams", "categories", "events"] -> browseRoute
        ["subscription-checkpoints"] -> checkpointsRoute
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
    browseRoute = maybe browseNotConfiguredApp browseApp providers.storeBrowsing req respond
    checkpointsRoute = case providers.checkpointInventory of
        Just provider -> checkpointsApp provider req respond
        Nothing -> checkpointsNotConfiguredApp req respond
    subscriptionsRoute = case providers.subscriptionStatus of
        Just provider -> subscriptionsApp provider req respond
        Nothing ->
            respond $
                jsonResponse
                    status404
                    (encode (object ["error" .= ("subscription status not configured" :: Text)]))
