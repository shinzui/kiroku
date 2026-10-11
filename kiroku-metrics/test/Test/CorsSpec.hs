{-# LANGUAGE ScopedTypeVariables #-}

module Test.CorsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), decode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types hiding (hOrigin, hVary)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (Response (ResponseRaw), ResponseReceived (..))
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Test.Hspec

import Kiroku.Metrics
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Metrics.JSON (errorEnvelope, storeErrorResponse)
import Kiroku.Store (StreamName (..), defaultConnectionSettings, withStore)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Settings (DecodeFailure (..))
import Kiroku.Store.Types (EventId (..), GlobalPosition (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)

hOrigin, hVary :: HeaderName
hOrigin = "Origin"
hVary = "Vary"

ops, evil :: ByteString
ops = "https://ops.example.com"
evil = "https://evil.example.com"

policy :: CorsPolicy
policy = corsAllowOrigins [either (error . show) id (allowedOrigin "https://ops.example.com")]

spec :: Spec
spec = do
    describe "Kiroku.Metrics.Cors (configuration)" $ do
        it "defaults to disabled and validates normalized HTTP(S) origins" $ do
            cors defaultConfig `shouldBe` corsDisabled
            corsEnabled corsDisabled `shouldBe` False
            allowedOrigin " HTTPS://OPS.Example.Com:443/ " `shouldBe` allowedOrigin "https://ops.example.com"
            allowedOrigin "http://localhost:80" `shouldBe` allowedOrigin "http://localhost"
            fmap renderAllowedOrigin (allowedOrigin "http://127.0.0.1:5173") `shouldBe` Right "http://127.0.0.1:5173"
            originAllowed policy "HTTPS://OPS.EXAMPLE.COM:443" `shouldBe` True
            originAllowed policy "https://ops.example.com:8443" `shouldBe` False
        it "normalizes IPv6 literals including embedded IPv4" $ do
            allowedOrigin "http://[::1]" `shouldBe` allowedOrigin "http://[0:0:0:0:0:0:0:1]:80"
            allowedOrigin "https://[2001:DB8::1]:8443" `shouldBe` allowedOrigin "https://[2001:db8:0:0:0:0:0:1]:8443"
            allowedOrigin "http://[::ffff:192.0.2.1]" `shouldBe` allowedOrigin "http://[0:0:0:0:0:ffff:c000:201]"
        it "rejects wildcards, opaque origins, malformed authorities, paths and Unicode" $
            forM_ ["*", "null", "", "example.com", "://example.com", "ftp://example.com", "http://", "http:///", "https://a/path", "https://a//", "https://a?x", "https://a#x", "https://a b", "https://a\nb", "https://user@a", "https://*.a", "https://a%2eb", "https://a\\b", "https://é.example", "http://:80", "http://a:", "http://a:-1", "http://a:+80", "http://a:65536", "http://a:999999999999999999999999", "http://a:80:90", "http://-a", "http://a-", "http://a..b", "http://256.1.2.3", "http://01.2.3.4", "http://[:::1]", "http://[::1", "http://[1:2:3:4:5:6:7]", "http://[1:2:3:4:5:6:7:8:9]", "http://[::1]:", "http://[::1]x", "http://[fe80::1%eth0]", "http://::1", "http://[192.0.2.1::]"] $ \input ->
                allowedOrigin input `shouldSatisfy` isLeft
        it "tolerates configuration slash/whitespace but refuses them in request origins" $ do
            allowedOrigin " https://ops.example.com/ " `shouldBe` allowedOrigin "https://ops.example.com"
            forM_ ["https://ops.example.com/", " https://ops.example.com", "https://ops.example.com ", "https://ops.example.com https://evil.example.com", "https://ops.example.com,https://evil.example.com", "\xff"] $ \raw ->
                originAllowed policy raw `shouldBe` False

    describe "Kiroku.Metrics.Cors (middleware, standalone)" $ do
        it "preserves every response byte and header when disabled, including upgrades and preflights" $ do
            let original = Wai.responseLBS status201 [("Vary", "Accept"), ("X-Custom", "yes")] "unchanged"
                app _ respond = respond original
            forM_ [[], [(hOrigin, ops)], [(hOrigin, evil), ("Upgrade", "websocket")], preflight ops "DELETE"] $ \headers -> do
                unwrapped <- capture app "OPTIONS" headers
                wrapped <- capture (corsMiddleware corsDisabled app) "OPTIONS" headers
                wrapped `shouldBe` unwrapped
        it "decorates GET and HEAD and varies allowed, disallowed, absent, malformed and duplicate origins" $ do
            forM_ ["GET", "HEAD"] $ \method -> do
                (_, headers, body) <- capture (corsMiddleware policy baseApp) method [(hOrigin, ops)]
                lookup "Access-Control-Allow-Origin" headers `shouldBe` Just ops
                lookup hVary headers `shouldBe` Just "Origin"
                body `shouldBe` "legacy"
            forM_ [[], [(hOrigin, evil)], [(hOrigin, "null")], [(hOrigin, ops <> "/")], [(hOrigin, ops), (hOrigin, ops)]] $ \headers -> do
                (status, hs, body) <- capture (corsMiddleware policy baseApp) "GET" headers
                status `shouldBe` status200
                body `shouldBe` "legacy"
                grants hs `shouldBe` []
                lookup hVary hs `shouldBe` Just "Origin"
        it "answers GET/HEAD preflights, reflects validated tokens, and varies on all inputs" $ do
            forM_ ["GET", "HEAD"] $ \method -> do
                (status, headers, body) <- capture (corsMiddleware policy baseApp) "OPTIONS" (preflight ops method <> [("Access-Control-Request-Headers", "Authorization, X-Trace")])
                status `shouldBe` status204
                body `shouldBe` ""
                lookup "Access-Control-Allow-Methods" headers `shouldBe` Just "GET, HEAD, OPTIONS"
                lookup "Access-Control-Allow-Headers" headers `shouldBe` Just "Authorization, X-Trace"
                lookup hVary headers `shouldBe` Just "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
        it "rejects unsupported/duplicate methods and malformed requested header tokens" $ do
            (status, _, body) <- capture (corsMiddleware policy baseApp) "OPTIONS" (preflight ops "POST")
            status `shouldBe` status403
            errorCode body `shouldBe` Just (String "cors_method_not_allowed")
            forM_ ["", "X Header", "X:Header", "X-Good,", "X-Good, \xff", "X\r\nInjected"] $ \header -> do
                (s, _, b) <- capture (corsMiddleware policy baseApp) "OPTIONS" (preflight ops "GET" <> [("Access-Control-Request-Headers", header)])
                s `shouldBe` status400
                errorCode b `shouldBe` Just (String "invalid_cors_request")
            (emptyStatus, _, _) <- capture (corsMiddleware policy baseApp) "OPTIONS" (preflight ops "GET" <> [("Access-Control-Request-Headers", ""), ("Access-Control-Request-Headers", "Authorization")])
            emptyStatus `shouldBe` status400
            (s, _, _) <- capture (corsMiddleware policy baseApp) "OPTIONS" (preflight ops "GET" <> [("Access-Control-Request-Method", "HEAD")])
            s `shouldBe` status400
        it "passes plain OPTIONS and disallowed preflights through without grants" $ do
            forM_ [[], [(hOrigin, ops)], preflight evil "GET", [(hOrigin, ops), (hOrigin, ops), ("Access-Control-Request-Method", "GET")]] $ \headers -> do
                (s, hs, body) <- capture (corsMiddleware policy baseApp) "OPTIONS" headers
                s `shouldBe` status200
                body `shouldBe` "legacy"
                if headers == [(hOrigin, ops)] then lookup "Access-Control-Allow-Origin" hs `shouldBe` Just ops else grants hs `shouldBe` []
        it "merges existing Vary case-insensitively and preserves wildcard variation" $ do
            let app headers _ respond = respond (Wai.responseLBS status200 headers "")
            (_, hs, _) <- capture (corsMiddleware policy (app [(hVary, "Accept, origin"), (hVary, "ACCEPT, X-Foo")])) "GET" []
            lookup hVary hs `shouldBe` Just "Accept, origin, X-Foo"
            (_, wildcard, _) <- capture (corsMiddleware policy (app [(hVary, "Accept, *")])) "GET" [(hOrigin, ops)]
            lookup hVary wildcard `shouldBe` Just "*"
        it "owns grants once, adds optional credentials and ignores negative max age" $ do
            let app _ respond = respond (Wai.responseLBS status200 [("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Origin", evil), ("Access-Control-Allow-Credentials", "true")] "")
            (_, hs, _) <- capture (corsMiddleware policy app) "GET" [(hOrigin, ops)]
            grants hs `shouldBe` [("Access-Control-Allow-Origin", ops)]
            (_, denied, _) <- capture (corsMiddleware policy app) "GET" [(hOrigin, evil)]
            grants denied `shouldBe` []
            forM_ [Nothing, Just (-1), Just 0, Just 3600] $ \age -> do
                (_, headers, _) <- capture (corsMiddleware (policy{allowCredentials = True, maxAgeSeconds = age}) baseApp) "OPTIONS" (preflight ops "GET")
                lookup "Access-Control-Allow-Credentials" headers `shouldBe` Just "true"
                lookup "Access-Control-Max-Age" headers `shouldBe` case age of
                    Just n | n >= 0 -> Just (fromStringInt n)
                    _ -> Nothing
        it "refuses malformed/duplicate/disallowed upgrade origins before invoking the inner app" $ do
            calls <- newIORef (0 :: Int)
            let app req respond = modifyIORef' calls (+ 1) >> baseApp req respond
            forM_ [[(hOrigin, evil)], [(hOrigin, "null")], [(hOrigin, ops <> "/")], [(hOrigin, ops), (hOrigin, ops)]] $ \headers -> do
                (s, hs, body) <- capture (corsMiddleware policy app) "GET" (("Upgrade", "websocket") : headers)
                s `shouldBe` status403
                lookup hContentType hs `shouldBe` Just "application/json"
                errorCode body `shouldBe` Just (String "origin_not_allowed")
            readIORef calls `shouldReturn` 0
            forM_ [[], [(hOrigin, ops)]] $ \headers -> do
                _ <- capture (corsMiddleware policy app) "GET" (("Upgrade", "websocket") : headers)
                pure ()
            readIORef calls `shouldReturn` 2
        it "never reuses grants between sequential requests with different origins" $ do
            forM_ [[], [(hOrigin, ops)], [(hOrigin, evil)], [(hOrigin, ops)], []] $ \headers -> do
                (_, hs, _) <- capture (corsMiddleware policy baseApp) "GET" headers
                lookup hVary hs `shouldBe` Just "Origin"
                lookup "Access-Control-Allow-Origin" hs `shouldBe` if headers == [(hOrigin, ops)] then Just ops else Nothing
        it "leaves raw upgrade responses untouched" $ do
            let original = Wai.responseRaw (\_ _ -> pure ()) (Wai.responseLBS status500 [] "fallback")
                app _ respond = respond original
            ref <- newIORef Nothing
            _ <- corsMiddleware policy app (Wai.defaultRequest{Wai.requestHeaders = [("Upgrade", "websocket"), (hOrigin, ops)]}) (\r -> writeIORef ref (Just r) >> pure ResponseReceived)
            response <- readIORef ref
            case response of
                Just (ResponseRaw _ _) -> pure ()
                _ -> expectationFailure "raw response was rewritten"
        it "strips HEAD bodies on a real Warp server while preserving grants and status" $
            Warp.testWithApplication (pure (corsMiddleware policy baseApp)) $ \port -> do
                manager <- HTTP.newManager HTTP.defaultManagerSettings
                get <- networkRequest manager port "GET" [(hOrigin, ops)]
                headResponse <- networkRequest manager port "HEAD" [(hOrigin, ops)]
                HTTP.responseStatus headResponse `shouldBe` HTTP.responseStatus get
                lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders headResponse) `shouldBe` Just ops
                HTTP.responseBody headResponse `shouldBe` ""

    describe "Kiroku.Metrics.JSON (shared inspection errors)" $ do
        it "pins envelope keys and omits optional details" $ do
            errorEnvelope "origin_not_allowed" "Denied." Nothing `shouldBe` object ["error" .= object ["code" .= ("origin_not_allowed" :: Text), "message" .= ("Denied." :: Text)]]
            errorEnvelope "invalid_query_parameter" "Invalid." (Just (object ["parameter" .= ("limit" :: Text)])) `shouldBe` object ["error" .= object ["code" .= ("invalid_query_parameter" :: Text), "message" .= ("Invalid." :: Text), "details" .= object ["parameter" .= ("limit" :: Text)]]]
        it "sanitizes unavailable and other store errors" $ do
            forM_ [(ConnectionError "postgres://secret", status503, "store_unavailable"), (StreamNotFound (StreamName "private"), status500, "store_error"), (EventDecodeFailed (DecodeFailure (EventId UUID.nil) "secret payload"), status500, "event_decode_failed")] $ \(err, expected, code) -> do
                (status, _, body) <- capture (\_ respond -> respond (storeErrorResponse "store_unavailable" err)) "GET" []
                status `shouldBe` expected
                errorCode body `shouldBe` Just (String code)
                body `shouldSatisfy` (not . BS.isInfixOf "secret" . LBS.toStrict)

    describe "Kiroku.Metrics.Cors (real server)" $ do
        it "decorates store-backed metrics, answers preflights and keeps denied bodies unchanged" $
            withInspection policy $ \port -> do
                manager <- HTTP.newManager HTTP.defaultManagerSettings
                allowed <- networkRequest manager port "GET" [(hOrigin, ops)]
                HTTP.responseStatus allowed `shouldBe` status200
                lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders allowed) `shouldBe` Just ops
                denied <- networkRequest manager port "GET" [(hOrigin, evil)]
                HTTP.responseStatus denied `shouldBe` status200
                grants (HTTP.responseHeaders denied) `shouldBe` []
                pre <- networkRequest manager port "OPTIONS" (preflight ops "GET")
                HTTP.responseStatus pre `shouldBe` status204
        it "upgrades allowed and absent origins but refuses an unlisted browser origin" $
            withInspection policy $ \port -> do
                assertSnapshot port [(hOrigin, ops)]
                refused <- wsSnapshot port [(hOrigin, evil)]
                case refused of
                    Left (WS.MalformedResponse _ _) -> pure ()
                    other -> expectationFailure ("expected 403 MalformedResponse, got " <> show other)
                assertSnapshot port []
        it "keeps upgrades open to any origin under the default disabled policy" $
            withInspection corsDisabled $ \port ->
                assertSnapshot port [(hOrigin, evil)]

baseApp :: Wai.Application
baseApp _ respond = respond (Wai.responseLBS status200 [("X-Legacy", "kept")] "legacy")

preflight :: ByteString -> ByteString -> RequestHeaders
preflight origin method = [(hOrigin, origin), ("Access-Control-Request-Method", method)]

grants :: ResponseHeaders -> ResponseHeaders
grants = filter (\(name, _) -> "access-control-" `BS.isPrefixOf` CI.foldedCase name)

capture :: Wai.Application -> Method -> RequestHeaders -> IO (Status, ResponseHeaders, LBS.ByteString)
capture app method headers = do
    ref <- newIORef Nothing
    _ <- app (Wai.defaultRequest{Wai.requestMethod = method, Wai.requestHeaders = headers}) $ \response -> do
        let (status, hs, stream) = Wai.responseToStream response
        chunks <- newIORef mempty
        stream $ \body -> body (\builder -> modifyIORef' chunks (<> builder)) (pure ())
        bytes <- toLazyByteString <$> readIORef chunks
        writeIORef ref (Just (status, hs, bytes))
        pure ResponseReceived
    readIORef ref >>= maybe (fail "application did not respond") pure

errorCode :: LBS.ByteString -> Maybe Value
errorCode bytes = do
    Object root <- decode bytes
    Object err <- KM.lookup "error" root
    KM.lookup "code" err

networkRequest :: HTTP.Manager -> Int -> Method -> RequestHeaders -> IO (HTTP.Response LBS.ByteString)
networkRequest manager port method headers = do
    request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/metrics")
    HTTP.httpLbs (request{HTTP.method = method, HTTP.requestHeaders = headers}) manager

withInspection :: CorsPolicy -> (Int -> IO a) -> IO a
withInspection cors action = withMigratedTestDatabase $ \connStr -> do
    metrics <- newKirokuMetricsWith (pure (GlobalPosition 0)) (pure 0)
    withStore (defaultConnectionSettings connStr) $ \store ->
        withMetricsServerWithStore (defaultConfig{Config.port = 0, Config.cors = cors}) metrics store [] $ \server -> do
            threadDelay 300_000
            action server.serverPort

wsSnapshot :: Int -> RequestHeaders -> IO (Either WS.HandshakeException (Maybe Value))
wsSnapshot port headers = do
    result <- timeout 15_000_000 $
        try $
            WS.runClientWith "127.0.0.1" port "/ws/metrics" WS.defaultConnectionOptions headers $ \conn -> do
                raw <- WS.receiveData conn :: IO LBS.ByteString
                pure $ do
                    Object fields <- decode raw
                    KM.lookup "type" fields
    maybe (fail "WebSocket snapshot timed out") pure result

fromStringInt :: Int -> ByteString
fromStringInt = BS.pack . show

assertSnapshot :: Int -> RequestHeaders -> Expectation
assertSnapshot port headers = do
    result <- wsSnapshot port headers
    case result of
        Right value -> value `shouldBe` Just (String "snapshot")
        Left err -> expectationFailure (show err)
