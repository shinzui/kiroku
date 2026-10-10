{-# LANGUAGE ScopedTypeVariables #-}

module Test.CheckpointsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBSC
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Method, ResponseHeaders, Status, status200, status404, status405, status500, status503)
import Network.Socket qualified as Socket
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec hiding (pending)

import Data.UUID qualified as UUID
import Kiroku.Cli.Subscription.Status (SubscriptionStatusRow (..))
import Kiroku.Metrics.Checkpoints
import Kiroku.Metrics.Collector (KirokuMetrics, newKirokuMetrics, newKirokuMetricsWith)
import Kiroku.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Kiroku.Metrics.Cors (allowedOrigin, corsAllowOrigins)
import Kiroku.Metrics.Server
import Kiroku.Store (GlobalPosition (..), SubscriptionCheckpoint (..), SubscriptionCheckpointInventory (..), SubscriptionName (..))
import Kiroku.Store qualified as Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (DecodeFailure (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)

fixture :: SubscriptionCheckpointInventory
fixture = SubscriptionCheckpointInventory (GlobalPosition 17) $ V.fromList [SubscriptionCheckpoint (SubscriptionName "beta") 1 (GlobalPosition 11) date, SubscriptionCheckpoint (SubscriptionName "alpha") 0 (GlobalPosition 7) date]
  where
    date = UTCTime (fromGregorian 2026 9 10) 0

spec :: Spec
spec = describe "Kiroku.Metrics.Checkpoints (/subscription-checkpoints)" $ do
    it "pins exact snake_case keys, preserves row order and round-trips lossless Int64 positions" $ do
        let response = checkpointInventoryResponse fixture
            row name index cp = Aeson.object ["subscription" Aeson..= (name :: Text), "member" Aeson..= (index :: Int32), "checkpoint_position" Aeson..= (cp :: Int64), "updated_at" Aeson..= ("2026-09-10T00:00:00Z" :: Text)]
        Aeson.toJSON response `shouldBe` Aeson.object ["store_position" Aeson..= (17 :: Int64), "checkpoints" Aeson..= [row "beta" 1 11, row "alpha" 0 7]]
        Aeson.eitherDecode (Aeson.encode response) `shouldBe` Right response
        let large = CheckpointInventoryResponse maxBound [CheckpointRow "large" 0 9007199254740993 (UTCTime (fromGregorian 2026 9 10) 0)]
        Aeson.eitherDecode (Aeson.encode large) `shouldBe` Right large
    it "serves an inventory and a structured standalone 404" $
        Warp.testWithApplication (pure (checkpointsApp (pure (Right fixture)))) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/subscription-checkpoints")
            response <- HTTP.httpLbs request manager
            HTTP.responseStatus response `shouldBe` status200
            Aeson.eitherDecode (HTTP.responseBody response) `shouldBe` Right (checkpointInventoryResponse fixture)
            unknown <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/unknown") >>= flip HTTP.httpLbs manager
            HTTP.responseStatus unknown `shouldBe` status404
            Aeson.decode (HTTP.responseBody unknown) `shouldBe` Just (Aeson.object ["error" Aeson..= Aeson.object ["code" Aeson..= ("not_found" :: Text), "message" Aeson..= ("Not found" :: Text)]])

    it "implements HEAD and 405 directly in WAI and calls the provider once per read" $ do
        calls <- newIORef (0 :: Int)
        let app = checkpointsApp (modifyIORef' calls (+ 1) >> pure (Right fixture))
        getResponse <- capture app "GET"
        (headStatus, headHeaders, headBody) <- capture app "HEAD"
        let (getStatus, getHeaders, _) = getResponse
        headStatus `shouldBe` getStatus
        headHeaders `shouldBe` getHeaders
        headBody `shouldBe` ""
        forM_ ["POST", "PUT", "DELETE", "OPTIONS"] $ \method -> do
            (status, headers, body) <- capture app method
            status `shouldBe` status405
            lookup "Allow" headers `shouldBe` Just "GET, HEAD"
            code body `shouldBe` Just "method_not_allowed"
        readIORef calls `shouldReturn` 2

    it "sanitizes typed failures and preserves HEAD error status and headers" $ do
        let failures = [(Store.ConnectionError "postgres://secret", status503, "checkpoint_inventory_unavailable"), (Store.StreamNotFound (Store.StreamName "secret"), status500, "store_error"), (Store.EventDecodeFailed (DecodeFailure (Store.EventId UUID.nil) "secret"), status500, "event_decode_failed")]
        forM_ failures $ \(err, expected, expectedCode) -> do
            let app = checkpointsApp (pure (Left err))
            (status, headers, body) <- capture app "GET"
            status `shouldBe` expected
            code body `shouldBe` Just expectedCode
            body `shouldSatisfy` (not . T.isInfixOf "secret" . T.pack . LBSC.unpack)
            capture app "HEAD" `shouldReturn` (status, headers, "")

    it "does not disguise thrown provider exceptions or cancellation as store errors" $ do
        capture (checkpointsApp (throwIO (userError "provider failed"))) "GET" `shouldThrow` anyIOException
        capture (checkpointsApp (throwIO Async.AsyncCancelled)) "GET" `shouldThrow` (\(_ :: Async.AsyncCancelled) -> True)

    it "keeps a stopped worker durable after its live registry entry disappears" $
        withTestStore $ \store -> do
            append store 3
            let name = Store.SubscriptionName "durable-vs-live"
            handle <- Store.subscribe store (Store.defaultSubscriptionConfig name Store.AllStreams (\_ -> pure Store.Continue))
            awaitLive store name
            Store.cancel handle
            stopped <- timeout 10_000_000 (Store.wait handle)
            stopped `shouldSatisfy` isJust
            states <- Store.subscriptionStates store
            Map.member (name, 0) states `shouldBe` False
            metrics <- newKirokuMetrics store
            let cfg = defaultConfig{port = 0}
            providers <- storeServerProviders cfg metrics store
            withMetricsServerWithProviders cfg metrics [] providers $ \server -> do
                live <- get server.serverPort "/subscriptions"
                HTTP.responseStatus live `shouldBe` status200
                Aeson.decode (HTTP.responseBody live) `shouldBe` Just ([] :: [SubscriptionStatusRow])
                inventory <- getInventory server.serverPort
                inventory.storePosition `shouldBe` 3
                triples inventory `shouldBe` [("durable-vs-live", 0, 3)]

    it "preserves SQL name and numeric member ordering with the captured frontier" $
        withTestStore $ \store -> do
            append store 20
            seed store "zeta" 2 7
            seed store "alpha" 10 3
            seed store "alpha" 2 5
            metrics <- newKirokuMetrics store
            withMetricsServerWithStore defaultConfig{port = 0} metrics store [] $ \server -> do
                inventory <- getInventory server.serverPort
                inventory.storePosition `shouldBe` 20
                triples inventory `shouldBe` [("alpha", 2, 5), ("alpha", 10, 3), ("zeta", 2, 7)]

    it "returns equal quiescent inventories across handles with different live providers" $
        withMigratedTestDatabase $ \connStr ->
            Store.withStore (Store.defaultConnectionSettings connStr) $ \storeA ->
                Store.withStore (Store.defaultConnectionSettings connStr) $ \storeB -> do
                    append storeA 3
                    let name = Store.SubscriptionName "worker-a"
                    handle <- Store.subscribe storeA (Store.defaultSubscriptionConfig name Store.AllStreams (\_ -> pure Store.Continue))
                    awaitLive storeA name
                    seed storeB "worker-b" 0 2
                    metricsA <- newKirokuMetrics storeA
                    metricsB <- newKirokuMetrics storeB
                    let cfg = defaultConfig{port = 0}
                    providersA <- storeServerProviders cfg metricsA storeA
                    providersB <- storeServerProviders cfg metricsB storeB
                    withMetricsServerWithProviders cfg metricsA [] providersA $ \serverA ->
                        withMetricsServerWithProviders cfg metricsB [] providersB $ \serverB -> do
                            liveBodyA <- HTTP.responseBody <$> get serverA.serverPort "/subscriptions"
                            liveBodyB <- HTTP.responseBody <$> get serverB.serverPort "/subscriptions"
                            liveBodyA `shouldNotBe` liveBodyB
                            -- Stop the worker before comparing separate SQL snapshots.
                            Store.cancel handle
                            _ <- Store.wait handle
                            a <- getInventory serverA.serverPort
                            b <- getInventory serverB.serverPort
                            a `shouldBe` b

    it "serves an empty store without changing the legacy unconfigured live response" $
        withTestStore $ \store -> do
            metrics <- newKirokuMetrics store
            withMetricsServerWithStore defaultConfig{port = 0} metrics store [] $ \server -> do
                getInventory server.serverPort `shouldReturn` CheckpointInventoryResponse 0 []
                live <- get server.serverPort "/subscriptions"
                HTTP.responseStatus live `shouldBe` status404
                Aeson.decode (HTTP.responseBody live) `shouldBe` Just (Aeson.object ["error" Aeson..= ("subscription status not configured" :: Text)])

    it "returns structured not-configured errors without shadowing a live name checkpoints" $ do
        metrics <- emptyMetrics
        let live = pure [SubscriptionStatusRow "checkpoints" 0 "live" 7]
        withMetricsServerSubscriptions defaultConfig{port = 0} metrics [] live $ \server -> do
            inventory <- get server.serverPort "/subscription-checkpoints"
            HTTP.responseStatus inventory `shouldBe` status404
            code (HTTP.responseBody inventory) `shouldBe` Just "checkpoint_inventory_not_configured"
            named <- get server.serverPort "/subscriptions/checkpoints"
            HTTP.responseStatus named `shouldBe` status200
            Aeson.decode (HTTP.responseBody named) `shouldBe` Just [SubscriptionStatusRow "checkpoints" 0 "live" 7]
        let app = httpAppWithProviders defaultConfig metrics [] defaultServerProviders
        (status, headers, _) <- capture app "GET"
        capture app "HEAD" `shouldReturn` (status, headers, "")
        (methodStatus, methodHeaders, _) <- capture app "POST"
        methodStatus `shouldBe` status405
        lookup "Allow" methodHeaders `shouldBe` Just "GET, HEAD"

    it "mounts HTTP and the real event WebSocket when the host strips only pathInfo" $
        withTestStore $ \store -> do
            metrics <- newKirokuMetrics store
            providers <- storeServerProviders defaultConfig metrics store
            let composed = combinedAppWithProviders defaultConfig metrics [] providers
                mounted req respond = composed req{Wai.pathInfo = drop 1 (Wai.pathInfo req)} respond
            Warp.testWithApplication (pure mounted) $ \port -> do
                response <- get port "/kiroku/subscription-checkpoints"
                HTTP.responseStatus response `shouldBe` status200
                bounded $ WS.runClient "127.0.0.1" port "/kiroku/ws/events" $ \conn -> do
                    WS.sendTextData conn (Aeson.encode $ Aeson.object ["type" Aeson..= ("subscribe_events" :: Text)])
                    raw <- WS.receiveData conn :: IO LBS.ByteString
                    frameType raw `shouldBe` Just "event_stream_started"

    it "escapes mounted WebSocket segments and retains the raw query string" $ do
        metrics <- emptyMetrics
        observed <- newEmptyMVar
        let ws pending = do
                putMVar observed (WS.requestPath (WS.pendingRequest pending))
                conn <- WS.acceptRequest pending
                WS.sendTextData conn ("ok" :: Text)
            app = combinedAppWithProviders defaultConfig metrics [] defaultServerProviders{webSocketServer = ws}
            mounted req respond = app req{Wai.pathInfo = drop 1 (Wai.pathInfo req)} respond
        Warp.testWithApplication (pure mounted) $ \port -> do
            bounded $ WS.runClient "127.0.0.1" port "/kiroku/ws/a%20b%2Fc?token=a%2Fb" $ \conn -> do
                WS.receiveData conn `shouldReturn` ("ok" :: Text)
            takeMVar observed `shouldReturn` "/ws/a%20b%2Fc?token=a%2Fb"

    it "enforces disabled WebSockets through both legacy and general composition" $ do
        metrics <- emptyMetrics
        calls <- newIORef (0 :: Int)
        let ws pending = modifyIORef' calls (+ 1) >> WS.rejectRequest pending "called"
            cfg = defaultConfig{enableWebSocket = False}
        forM_ [combinedApp cfg metrics [] Nothing ws, combinedAppWithProviders cfg metrics [] defaultServerProviders{webSocketServer = ws}] $ \app ->
            Warp.testWithApplication (pure app) $ \port -> do
                result <- bounded $ try (WS.runClient "127.0.0.1" port "/ws/metrics" (\_ -> pure ()))
                (result :: Either WS.HandshakeException ()) `shouldSatisfy` isLeft
        readIORef calls `shouldReturn` 0

    it "does no checkpoint work on legacy metrics reads and invokes inventory only on demand" $ do
        metrics <- emptyMetrics
        calls <- newIORef (0 :: Int)
        let provider = modifyIORef' calls (+ 1) >> pure (Right fixture)
            providers = defaultServerProviders{checkpointInventory = Just provider}
            app = httpAppWithProviders defaultConfig metrics [] providers
            metricsApp req respond = app req{Wai.pathInfo = ["metrics"]} respond
        forM_ [1 .. 20 :: Int] $ \_ -> do
            (status, _, _) <- capture metricsApp "GET"
            status `shouldBe` status200
        readIORef calls `shouldReturn` 0
        _ <- capture app "GET"
        readIORef calls `shouldReturn` 1

    it "inherits exactly one CORS wrap on the provider composition" $ do
        metrics <- emptyMetrics
        let origin = either (error . show) id (allowedOrigin "https://ops.example.com")
            cfg = defaultConfig{cors = corsAllowOrigins [origin]}
            app = combinedAppWithProviders cfg metrics [] defaultServerProviders{checkpointInventory = Just (pure (Right fixture))}
        Warp.testWithApplication (pure app) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            req <- HTTP.parseRequest (url port "/subscription-checkpoints")
            response <- HTTP.httpLbs req{HTTP.requestHeaders = [("Origin", "https://ops.example.com")]} manager
            HTTP.responseStatus response `shouldBe` status200
            filter ((== "Access-Control-Allow-Origin") . fst) (HTTP.responseHeaders response) `shouldBe` [("Access-Control-Allow-Origin", "https://ops.example.com")]

    it "is immediately ready on ephemeral and fixed ports and releases each socket" $ do
        metrics <- emptyMetrics
        withMetricsServer defaultConfig{port = 0} metrics [] $ \server -> do
            HTTP.responseStatus <$> get server.serverPort "/metrics" `shouldReturn` status200
        (port, socket) <- Warp.openFreePort
        Socket.close socket
        withMetricsServer defaultConfig{port = port} metrics [] $ \server ->
            HTTP.responseStatus <$> get server.serverPort "/metrics" `shouldReturn` status200
        assertPortReleased port

    it "reports an occupied-port failure to acquisition without invoking the callback" $ do
        metrics <- emptyMetrics
        (port, reserved) <- Warp.openFreePort
        Socket.close reserved
        bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \ipv4 ->
            bracket (Socket.socket Socket.AF_INET6 Socket.Stream Socket.defaultProtocol) Socket.close $ \ipv6 -> do
                -- On macOS a loopback listener can coexist with a wildcard listener.
                -- Occupy both wildcard addresses, as the server binds host "*".
                Socket.bind ipv4 (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (0, 0, 0, 0)))
                Socket.listen ipv4 1
                Socket.setSocketOption ipv6 Socket.IPv6Only 1
                Socket.bind ipv6 (Socket.SockAddrInet6 (fromIntegral port) 0 (0, 0, 0, 0) 0)
                Socket.listen ipv6 1
                called <- newIORef False
                result <- bounded $ try $ withMetricsServer defaultConfig{port = port} metrics [] (\_ -> writeIORef called True)
                (result :: Either SomeException ()) `shouldSatisfy` isLeft
                readIORef called `shouldReturn` False

    it "releases the server after callback failure and propagates unexpected termination" $ do
        metrics <- emptyMetrics
        portRef <- newIORef 0
        result <- bounded $ try $ withMetricsServer defaultConfig{port = 0} metrics [] $ \server -> do
            writeIORef portRef server.serverPort
            throwIO (userError "callback failed")
        (result :: Either SomeException ()) `shouldSatisfy` isLeft
        readIORef portRef >>= assertPortReleased
        callbackStopped <- newEmptyMVar
        result2 <- bounded $ try $ withMetricsServer defaultConfig{port = 0} metrics [] $ \server ->
            ( do
                writeIORef portRef server.serverPort
                Async.cancel server.serverThread
                threadDelay 10_000_000
            )
                `finally` putMVar callbackStopped ()
        (result2 :: Either SomeException ()) `shouldSatisfy` isLeft
        bounded (takeMVar callbackStopped)
        readIORef portRef >>= assertPortReleased

    it "cancels acquisition or its returned lifetime without leaking a fixed-port listener" $ do
        metrics <- emptyMetrics
        (port, socket) <- Warp.openFreePort
        Socket.close socket
        -- Exercise the acquisition boundary and the readiness/callback boundary.
        forM_ [0, 100, 1000] $ \delay -> do
            entered <- newEmptyMVar
            thread <- Async.async $ do
                putMVar entered ()
                withMetricsServer defaultConfig{port = port} metrics [] (\_ -> threadDelay 10_000_000)
            takeMVar entered
            threadDelay delay
            bounded (Async.cancel thread)
            assertPortReleased port

emptyMetrics :: IO KirokuMetrics
emptyMetrics = newKirokuMetricsWith (pure (GlobalPosition 0)) (pure 0)

withTestStore :: (Store.KirokuStore -> IO a) -> IO a
withTestStore action = withMigratedTestDatabase $ \connection -> Store.withStore (Store.defaultConnectionSettings connection) action

append :: Store.KirokuStore -> Int -> IO ()
append store count = do
    let ev = Store.EventData Nothing (Store.EventType "E") Aeson.Null Nothing Nothing Nothing
    result <- Store.runStoreIO store $ Store.appendToStream (Store.StreamName "orders-1") Store.NoStream (replicate count ev)
    result `shouldSatisfy` either (const False) (const True)

seed :: Store.KirokuStore -> Text -> Int32 -> Int64 -> IO ()
seed store name index position = do
    result <- Pool.use store.pool $ Session.statement (name, index, position, max 1 (index + 1), "unbound", Nothing) SQL.saveCheckpointMemberStmt
    result `shouldBe` Right ()

awaitLive :: Store.KirokuStore -> Store.SubscriptionName -> IO ()
awaitLive store name = bounded loop
  where
    loop = do
        states <- Store.subscriptionStates store
        case Map.lookup (name, 0) states of
            Just view | view.statePhase == "live" -> pure ()
            _ -> threadDelay 20_000 >> loop

triples :: CheckpointInventoryResponse -> [(Text, Int32, Int64)]
triples response = [(row.subscription, row.member, row.checkpointPosition) | row <- response.checkpoints]

url :: Int -> String -> String
url port path = "http://127.0.0.1:" <> show port <> path

get :: Int -> String -> IO (HTTP.Response LBS.ByteString)
get port path = do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    request <- HTTP.parseRequest (url port path)
    HTTP.httpLbs request manager

getInventory :: Int -> IO CheckpointInventoryResponse
getInventory port = do
    response <- get port "/subscription-checkpoints"
    HTTP.responseStatus response `shouldBe` status200
    either fail pure (Aeson.eitherDecode (HTTP.responseBody response))

code :: LBS.ByteString -> Maybe Text
code bytes = do
    Aeson.Object root <- Aeson.decode bytes
    Aeson.Object err <- KM.lookup "error" root
    Aeson.String value <- KM.lookup "code" err
    pure value

frameType :: LBS.ByteString -> Maybe Text
frameType bytes = do
    Aeson.Object root <- Aeson.decode bytes
    Aeson.String value <- KM.lookup "type" root
    pure value

capture :: Wai.Application -> Method -> IO (Status, ResponseHeaders, LBS.ByteString)
capture app method = do
    result <- newIORef Nothing
    _ <- app Wai.defaultRequest{Wai.requestMethod = method, Wai.pathInfo = checkpointsPath} $ \response -> do
        let (status, headers, stream) = Wai.responseToStream response
        chunks <- newIORef mempty
        stream $ \body -> body (\builder -> modifyIORef' chunks (<> builder)) (pure ())
        bytes <- toLazyByteString <$> readIORef chunks
        writeIORef result (Just (status, headers, bytes))
        pure ResponseReceived
    readIORef result >>= maybe (fail "No WAI response") pure

bounded :: IO a -> IO a
bounded action = timeout 15_000_000 action >>= maybe (fail "Timed out") pure

assertPortReleased :: Int -> IO ()
assertPortReleased port = forM_ addresses $ \(family, address) ->
    bracket (Socket.socket family Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.setSocketOption sock Socket.ReuseAddr 1
        if family == Socket.AF_INET6 then Socket.setSocketOption sock Socket.IPv6Only 1 else pure ()
        Socket.bind sock address
        Socket.listen sock 1
  where
    addresses =
        [ (Socket.AF_INET, Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
        , (Socket.AF_INET, Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (0, 0, 0, 0)))
        , (Socket.AF_INET6, Socket.SockAddrInet6 (fromIntegral port) 0 (0, 0, 0, 0) 0)
        ]
