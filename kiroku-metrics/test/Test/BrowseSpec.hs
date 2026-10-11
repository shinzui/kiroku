{-# LANGUAGE OverloadedLabels #-}

module Test.BrowseSpec (spec) where

import Control.Lens ((^.))
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Kiroku.Metrics hiding (items)
import Kiroku.Store qualified as Store
import Kiroku.Store.Effect (Store (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

spec :: Spec
spec = describe "Kiroku.Metrics.Browse" $ do
    it "validates page limits before construction" $ do
        forM_ [(0, 10), (10, 1), (1, 1001)] $ \(def, cap) -> mkBrowseLimits def cap `shouldBe` Left (InvalidBrowseLimits def cap)
        fmap maxLimit (mkBrowseLimits 1 1000) `shouldBe` Right 1000
    it "rejects malformed queries before invoking the store" $ do
        calls <- newIORef (0 :: Int)
        let browser = StoreBrowser (\_ -> modifyIORef' calls (+ 1) >> pure (Left (Store.ConnectionError "secret"))) defaultBrowseLimits
        Warp.testWithApplication (pure (browseApp browser)) $ \port -> do
            forM_ ["/streams?limit=0", "/streams?limit=1001", "/streams?limit=abc", "/streams?prefix=%00", "/streams?from=%FF", "/events?from=-1", "/events?from=9223372036854775808", "/events?direction=sideways", "/streams/$all/events", "/events/not-a-uuid"] $ \path -> do
                response <- get port path
                HTTP.responseStatus response `shouldBe` status400
            response <- get port "/streams?limit=1"
            HTTP.responseStatus response `shouldBe` status503
            code (HTTP.responseBody response) `shouldBe` Just "store_unavailable"
        readIORef calls `shouldReturn` 1
    it "preserves HEAD status/headers, refuses mutations and sanitizes errors" $ do
        let app = browseApp (StoreBrowser (\_ -> pure (Left (Store.ConnectionError "postgres://secret"))) defaultBrowseLimits)
        (status, headers, responseBody) <- capture app "GET" ["events"]
        status `shouldBe` status503
        code responseBody `shouldBe` Just "store_unavailable"
        capture app "HEAD" ["events"] `shouldReturn` (status, headers, "")
        forM_ ["POST", "PUT", "DELETE", "OPTIONS"] $ \method -> do
            (actual, responseHeaders, _) <- capture app method ["events"]
            actual `shouldBe` status405
            lookup "Allow" responseHeaders `shouldBe` Just "GET, HEAD"
        (disabled, _, disabledBody) <- capture browseNotConfiguredApp "GET" ["streams"]
        disabled `shouldBe` status404
        code disabledBody `shouldBe` Just "store_browsing_not_configured"
    it "serves all browse routes, names and exclusive pages through the shared server" $ withTestStore $ \store -> do
        append store "orders-1" 3
        append store "orders-2" 1
        append store "shipments-1" 1
        metrics <- newKirokuMetrics store
        providers <- storeServerProviders defaultConfig metrics store
        withMetricsServerWithProviders defaultConfig{port = 0} metrics [] providers $ \server -> do
            let fetch = get server.serverPort
            first <- fetch "/streams?category=orders&limit=1"
            field "next_cursor" (body first) `shouldBe` Just (String "orders-1")
            second <- fetch "/streams?category=orders&prefix=orders-&from=orders-1&limit=1"
            map (field "name") (items (body second)) `shouldBe` [Just (String "orders-2")]
            field "next_cursor" (body second) `shouldBe` Nothing
            summary <- fetch "/streams/orders-1"
            field "category" (body summary) `shouldBe` Just (String "orders")
            streamPage <- fetch "/streams/orders-1/events?limit=2"
            map (field "streamVersion") (items (body streamPage)) `shouldBe` [Just (Number 1), Just (Number 2)]
            field "next_cursor" (body streamPage) `shouldBe` Just (Number 2)
            continuation <- fetch "/streams/orders-1/events?from=2&limit=2"
            map (field "streamVersion") (items (body continuation)) `shouldBe` [Just (Number 3)]
            backward <- fetch "/streams/orders-1/events?direction=backward"
            map (field "streamVersion") (items (body backward)) `shouldBe` map (Just . Number) [3, 2, 1]
            cats <- fetch "/categories"
            map (field "name") (items (body cats)) `shouldBe` [Just (String "orders"), Just (String "shipments")]
            categoryEvents <- fetch "/categories/orders/events"
            length (items (body categoryEvents)) `shouldBe` 4
            globals <- fetch "/events?from=3"
            map (field "globalPosition") (items (body globals)) `shouldBe` [Just (Number 4), Just (Number 5)]
            map (field "original_stream_name") (items (body globals)) `shouldBe` [Just (String "orders-2"), Just (String "shipments-1")]
            reverseGlobal <- fetch "/events?direction=backward&limit=2"
            map (field "globalPosition") (items (body reverseGlobal)) `shouldBe` [Just (Number 5), Just (Number 4)]
            Right recorded <- Store.runStoreIO store $ Store.readAllForward (Store.GlobalPosition 0) 10
            let Store.EventId uuid = V.head recorded ^. #eventId
            event <- fetch ("/events/" <> show uuid)
            HTTP.responseStatus event `shouldBe` status200
            field "original_stream_name" (body event) `shouldBe` Just (String "orders-1")
            forM_ ["/streams/missing", "/streams/missing/events", "/events/00000000-0000-0000-0000-000000000000", "/streams/unknown/path"] $ \path -> do
                response <- fetch path
                HTTP.responseStatus response `shouldBe` status404
            -- Summary JSON and legacy endpoints remain independently mounted.
            legacy <- fetch "/nope"
            body legacy `shouldBe` object ["error" .= ("Not found" :: Text)]
    it "keeps prefix-mounted browse routes and CORS active when legacy JSON and WebSockets are disabled" $ do
        metrics <- newKirokuMetricsWith (pure (Store.GlobalPosition 0)) (pure 0)
        let origin = either (error . show) (\value -> value) (allowedOrigin "https://ops.example.com")
            cors = corsAllowOrigins [origin]
            browser = StoreBrowser (\_ -> pure (Left (Store.ConnectionError "secret"))) defaultBrowseLimits
            config = defaultConfig{cors, enableJSON = False, enableWebSocket = False}
            providers = defaultServerProviders{storeBrowsing = Just browser}
            mounted req respond = combinedAppWithProviders config metrics [] providers (req{Wai.pathInfo = drop 1 (Wai.pathInfo req)}) respond
        Warp.testWithApplication (pure mounted) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/inspect/events?from=0")
            response <- HTTP.httpLbs request{HTTP.requestHeaders = [("Origin", "https://ops.example.com")]} manager
            HTTP.responseStatus response `shouldBe` status503
            lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "https://ops.example.com"
            code (HTTP.responseBody response) `shouldBe` Just "store_unavailable"
    it "trims over-fetch before one distinct-name lookup and skips it on empty pages" $ withTestStore $ \store -> do
        append store "orders-1" 2
        append store "orders-2" 1
        Right events <- Store.runStoreIO store $ Store.readAllForward (Store.GlobalPosition 0) 10
        calls <- newIORef ([] :: [[Store.StreamId]])
        let interpreter :: forall a. Eff '[Store, Error Store.StoreError, IOE] a -> Eff '[Error Store.StoreError, IOE] a
            interpreter = interpret_ $ \case
                ReadAllForward (Store.GlobalPosition cursor) limit -> pure $ V.take (fromIntegral limit) $ V.filter (\event -> let Store.GlobalPosition n = event ^. #globalPosition in n > cursor) events
                LookupStreamNames ids -> liftIO (modifyIORef' calls (<> [ids])) >> pure Map.empty
                _ -> error "unexpected browse mock operation"
            browser = StoreBrowser (runEff . runErrorNoCallStack . interpreter) defaultBrowseLimits
        Warp.testWithApplication (pure (browseApp browser)) $ \port -> do
            response <- get port "/events?limit=2"
            map (field "original_stream_name") (items (body response)) `shouldBe` [Just Null, Just Null]
            _ <- get port "/events?from=3"
            pure ()
        readIORef calls `shouldReturn` [[V.head events ^. #originalStreamId]]

withTestStore :: (Store.KirokuStore -> IO ()) -> IO ()
withTestStore action = withMigratedTestDatabase $ \connection -> Store.withStore (Store.defaultConnectionSettings connection) action
append :: Store.KirokuStore -> Text -> Int -> IO ()
append store name count = do
    let event = Store.EventData Nothing (Store.EventType "Created") (object []) Nothing Nothing Nothing
    result <- Store.runStoreIO store $ Store.appendToStream (Store.StreamName name) Store.NoStream (replicate count event)
    result `shouldSatisfy` either (const False) (const True)
get :: Int -> String -> IO (HTTP.Response LBS.ByteString)
get port path = do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
    HTTP.httpLbs request manager
body :: HTTP.Response LBS.ByteString -> Value
body response = maybe (error "Invalid JSON response") (\value -> value) (Aeson.decode (HTTP.responseBody response))
field :: Aeson.Key -> Value -> Maybe Value
field key (Object objectValue) = KM.lookup key objectValue
field _ _ = Nothing
items :: Value -> [Value]
items value = case field "items" value of Just (Array rows) -> V.toList rows; _ -> error "Expected items"
code :: LBS.ByteString -> Maybe Text
code bytes = do
    value <- Aeson.decode bytes
    err <- field "error" value
    String actual <- field "code" err
    pure actual
capture :: Wai.Application -> Method -> [Text] -> IO (Status, ResponseHeaders, LBS.ByteString)
capture app method path = do
    result <- newIORef Nothing
    _ <- app Wai.defaultRequest{Wai.requestMethod = method, Wai.pathInfo = path} $ \response -> do
        let (status, headers, stream) = Wai.responseToStream response
        stream $ \send -> do
            chunks <- newIORef []
            send (\chunk -> modifyIORef' chunks (<> [toLazyByteString chunk])) (pure ())
            bytes <- mconcat <$> readIORef chunks
            modifyIORef' result (const (Just (status, headers, bytes)))
        pure ResponseReceived
    maybe (error "No response") (\value -> pure value) =<< readIORef result
