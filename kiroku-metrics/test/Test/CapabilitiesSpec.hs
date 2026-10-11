module Test.CapabilitiesSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Method, ResponseHeaders, Status, status200, status404, status405)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

-- The umbrella import also checks that record labels have no export collisions.
import Kiroku.Metrics hiding (InspectOptions (..), InspectRuntime (..))
import Kiroku.Store qualified as Store
import Kiroku.Test.Postgres (withMigratedTestDatabase)

none, allPresent :: ProviderPresence
none = ProviderPresence False False False False noWebSocketChannels
allPresent = ProviderPresence True True True True storeWebSocketChannels

spec :: Spec
spec = describe "Kiroku.Metrics.Capabilities" $ do
    it "pins every wire key, includes Prometheus as process-local, and round-trips" $ do
        let caps = capabilitiesFor defaultConfig allPresent
            keys = ["metrics", "prometheus", "health", "subscriptions_live", "subscriptions_checkpoints", "dead_letters", "browse", "websocket_metrics", "websocket_events"]
        A.toJSON caps
            `shouldBe` A.object
                [ "package" A..= ("kiroku-metrics" :: Text)
                , "version" A..= kirokuMetricsVersion
                , "routes" A..= A.object [key A..= True | key <- keys]
                , "cors" A..= A.object ["enabled" A..= False]
                , "process_local" A..= (["metrics", "prometheus", "health", "subscriptions_live", "websocket_metrics"] :: [Text])
                ]
        A.eitherDecode (A.encode caps) `shouldBe` Right caps
        kirokuMetricsVersion `shouldSatisfy` (T.isInfixOf ".")
    it "derives availability from wiring and switches without invoking any provider" $ do
        let plain = capabilitiesFor defaultConfig none
            off = capabilitiesFor defaultConfig{enableJSON = False, enablePrometheus = False, enableWebSocket = False} allPresent
        plain.routes `shouldBe` RouteAvailability True True True False False False False False False
        off.routes `shouldBe` RouteAvailability False False False True True True True False False
        origin <- either (fail . show) pure (allowedOrigin "http://a")
        (capabilitiesFor defaultConfig{cors = corsAllowOrigins [origin]} none).corsIsEnabled `shouldBe` True
        let providers =
                defaultServerProviders
                    { subscriptionStatus = Just (fail "Discovery invoked live provider")
                    , checkpointInventory = Just (fail "Discovery invoked checkpoint provider")
                    , storeBrowsing = Just (StoreBrowser (\_ -> fail "Discovery invoked browse provider") defaultBrowseLimits)
                    , deadLetters = Just (\_ -> fail "Discovery invoked dead-letter provider")
                    }
        m <- emptyMetrics
        Warp.testWithApplication (pure (httpAppWithProviders defaultConfig m [] providers)) $ \port -> do
            caps <- getCaps port
            caps.routes.subscriptionsLive `shouldBe` True
            caps.routes.subscriptionsCheckpoints `shouldBe` True
            caps.routes.browse `shouldBe` True
            caps.routes.deadLetters `shouldBe` True
    it "implements GET, bodyless HEAD, exact path and 405 in direct WAI" $ do
        let app = capabilitiesApp (capabilitiesFor defaultConfig none)
        (s, h, b) <- capture app "GET" ["capabilities"]
        s `shouldBe` status200
        capture app "HEAD" ["capabilities"] `shouldReturn` (s, h, "")
        b `shouldBe` A.encode (capabilitiesFor defaultConfig none)
        forM_ ["POST", "PUT", "DELETE", "OPTIONS"] $ \method -> do
            (status, headers, _) <- capture app method ["capabilities"]
            status `shouldBe` status405
            lookup "Allow" headers `shouldBe` Just "GET, HEAD"
        (unknown, unknownHeaders, _) <- capture app "GET" ["capabilities", "x"]
        unknown `shouldBe` status404
        capture app "HEAD" ["capabilities", "x"] `shouldReturn` (unknown, unknownHeaders, "")
    it "reports plain/stub servers honestly and remains reachable with every switch off" $ do
        m <- emptyMetrics
        forM_ [defaultConfig{port = 0}, defaultConfig{port = 0, enableJSON = False, enablePrometheus = False, enableWebSocket = False}] $ \cfg ->
            withMetricsServer cfg m [] $ \server -> do
                caps <- getCaps server.serverPort
                caps `shouldBe` capabilitiesFor cfg none
    it "reports all store providers and the legacy store starter's absent live registry" $
        withMigratedTestDatabase $ \url -> Store.withStore (Store.defaultConnectionSettings url) $ \store -> do
            m <- emptyMetrics
            let cfg = defaultConfig{port = 0}
            providers <- storeServerProviders cfg m store
            withMetricsServerWithProviders cfg m [] providers $ \server -> do
                getCaps server.serverPort `shouldReturn` capabilitiesFor cfg allPresent
                forM_ ["/metrics", "/metrics/prometheus", "/health", "/subscriptions", "/subscription-checkpoints", "/streams", "/subscriptions/missing/dead-letters"] $ \path ->
                    HTTP.responseStatus <$> get server.serverPort path `shouldReturn` status200
                forM_ ["/ws/metrics", "/ws/events"] $ \path ->
                    bounded (WS.runClient "127.0.0.1" server.serverPort path (\conn -> WS.sendClose conn ("done" :: Text)))
            withMetricsServerWithStore cfg m store [] $ \server -> do
                caps <- getCaps server.serverPort
                caps.routes.subscriptionsLive `shouldBe` False
                caps.routes.websocketMetrics `shouldBe` True
                caps.routes.websocketEvents `shouldBe` True
    it "honours custom declarations, refuses disabled upgrades and keeps legacy opaque apps conservative" $ do
        m <- emptyMetrics
        let ws connectionRequest = WS.acceptRequest connectionRequest >>= \conn -> WS.sendTextData conn ("ok" :: Text)
            providers = defaultServerProviders{webSocketServer = ws, webSocketChannels = WebSocketChannels False True}
        forM_ [True, False] $ \enabled -> do
            let cfg = defaultConfig{port = 0, enableWebSocket = enabled}
            withMetricsServerWithProviders cfg m [] providers $ \server -> do
                caps <- getCaps server.serverPort
                caps.routes.websocketEvents `shouldBe` enabled
                result <- bounded (try (WS.runClient "127.0.0.1" server.serverPort "/ws/events" (\conn -> WS.receiveData conn :: IO Text)) :: IO (Either SomeException Text))
                if enabled then either (fail . show) (`shouldBe` "ok") result else result `shouldSatisfy` isLeft
        let cfg = defaultConfig{port = 0}
        Warp.testWithApplication (pure (combinedApp cfg m [] Nothing ws)) $ \port -> do
            caps <- getCaps port
            caps.routes.websocketEvents `shouldBe` False
    it "serves discovery behind a mount prefix and preserves the configured CORS policy" $ do
        m <- emptyMetrics
        origin <- either (fail . show) pure (allowedOrigin "http://a")
        let cfg = defaultConfig{cors = corsAllowOrigins [origin]}
            mounted req = combinedAppWithProviders cfg m [] defaultServerProviders req{Wai.pathInfo = drop 1 (Wai.pathInfo req)}
        Warp.testWithApplication (pure mounted) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            req <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/kiroku/capabilities")
            response <- HTTP.httpLbs req{HTTP.requestHeaders = [("Origin", "http://a")]} manager
            HTTP.responseStatus response `shouldBe` status200
            lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "http://a"
            A.eitherDecode (HTTP.responseBody response) `shouldBe` Right (capabilitiesFor cfg none)

emptyMetrics :: IO KirokuMetrics
emptyMetrics = newKirokuMetricsWith (pure (Store.GlobalPosition 0)) (pure 0)

get :: Int -> String -> IO (HTTP.Response LBS.ByteString)
get port path = do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    req <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
    HTTP.httpLbs req manager

getCaps :: Int -> IO Capabilities
getCaps port = do
    response <- get port "/capabilities"
    HTTP.responseStatus response `shouldBe` status200
    either fail pure (A.eitherDecode (HTTP.responseBody response))

capture :: Wai.Application -> Method -> [Text] -> IO (Status, ResponseHeaders, LBS.ByteString)
capture app method path = do
    result <- newIORef Nothing
    _ <- app Wai.defaultRequest{Wai.requestMethod = method, Wai.pathInfo = path} $ \response -> do
        let (status, headers, stream) = Wai.responseToStream response
        chunks <- newIORef mempty
        stream $ \body -> body (\builder -> modifyIORef' chunks (<> builder)) (pure ())
        bytes <- toLazyByteString <$> readIORef chunks
        writeIORef result (Just (status, headers, bytes))
        pure ResponseReceived
    readIORef result >>= maybe (fail "No response") pure

bounded :: IO a -> IO a
bounded action = timeout 15_000_000 action >>= maybe (fail "Timed out") pure
