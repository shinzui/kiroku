{-# LANGUAGE OverloadedLabels #-}

module Test.DeadLettersSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Lens ((^.))
import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBSC
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID qualified as UUID
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Metrics.Collector (newKirokuMetrics, newKirokuMetricsWith)
import Kiroku.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Kiroku.Metrics.Cors (allowedOrigin, corsAllowOrigins)
import Kiroku.Metrics.DeadLetters
import Kiroku.Metrics.Server
import Kiroku.Store qualified as Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import System.Timeout (timeout)
import Test.Hspec

fixture :: Store.SubscriptionDeadLetterPage
fixture = Store.SubscriptionDeadLetterPage (V.singleton (Store.SubscriptionDeadLetter 7 (Store.SubscriptionName "orders") 9 (Store.GlobalPosition 9007199254740993) (Store.EventId UUID.nil) (object ["kind" .= ("poison" :: Text), "detail" .= ("unknown SKU" :: Text)]) "poison: unknown SKU" 1 (UTCTime (fromGregorian 2026 9 10) 0))) (Just (Store.SubscriptionDeadLetterCursor (Store.GlobalPosition 9007199254740993) 7))

spec :: Spec
spec = describe "DeadLetters" $ do
    it "pins exact snake_case keys, preserves reason JSON and round-trips lossless positions" $ do
        let response = deadLetterPageResponse fixture
            item = object ["dead_letter_id" .= (7 :: Int), "subscription" .= ("orders" :: Text), "member" .= (9 :: Int), "global_position" .= (9007199254740993 :: Integer), "event_id" .= UUID.nil, "reason" .= object ["kind" .= ("poison" :: Text), "detail" .= ("unknown SKU" :: Text)], "reason_summary" .= ("poison: unknown SKU" :: Text), "attempt_count" .= (1 :: Int), "created_at" .= ("2026-09-10T00:00:00Z" :: Text)]
        Aeson.toJSON response `shouldBe` object ["items" .= [item], "next_cursor" .= ("9007199254740993:7" :: Text)]
        Aeson.eitherDecode (Aeson.encode response) `shouldBe` Right response
        Aeson.toJSON (deadLetterPageResponse (Store.SubscriptionDeadLetterPage V.empty Nothing)) `shouldBe` object ["items" .= ([] :: [Value])]
    it "validates decimal cursor components without signed or overflow narrowing" $ do
        forM_ ["", "1", "1:", ":1", "1:2:3", "-1:2", "1:-2", "1.5:2", "18446744073709551616:1", "9223372036854775808:1", "1:18446744073709551616", "+1:2", "１:2"] $ \raw -> parseDeadLetterCursor raw `shouldBe` Nothing
        forM_ [Store.SubscriptionDeadLetterCursor (Store.GlobalPosition 0) 0, Store.SubscriptionDeadLetterCursor (Store.GlobalPosition maxBound) maxBound] $ \cursor -> parseDeadLetterCursor (renderDeadLetterCursor cursor) `shouldBe` Just cursor
    it "passes the complete query once and uses the documented defaults" $ do
        calls <- newIORef []
        let provider query = modifyIORef' calls (<> [query]) >> pure (Right fixture)
        void $ capture (deadLettersApp provider) "GET" ["subscriptions", "orders", "dead-letters"] [("member", Just "9"), ("from", Just "4211:7"), ("limit", Just "5")]
        void $ capture (deadLettersApp provider) "GET" ["subscriptions", "orders", "dead-letters"] []
        recorded <- readIORef calls
        recorded `shouldBe` [Store.SubscriptionDeadLetterQuery (Store.SubscriptionName "orders") (Just 9) (Just (Store.SubscriptionDeadLetterCursor (Store.GlobalPosition 4211) 7)) (either (error . show) (\v -> v) (Store.mkSubscriptionDeadLetterLimit 5)), Store.defaultSubscriptionDeadLetterQuery (Store.SubscriptionName "orders")]
    it "rejects invalid, duplicate, missing and malformed UTF-8 values before calling a provider" $ do
        calls <- newIORef (0 :: Int)
        let app = deadLettersApp (\_ -> modifyIORef' calls (+ 1) >> pure (Right fixture))
        forM_ [[("limit", Just raw)] | raw <- ["0", "1001", "abc", "", "-1", "18446744073709551616"]] $ \query -> invalidRequest calls app query
        forM_ [[("member", Just "2147483648")], [("member", Just "-1")], [("from", Just "1:9223372036854775808")], [("limit", Nothing)], [("limit", Just "2"), ("limit", Just "3")], [("member", Just "\255")]] $ invalidRequest calls app
        readIORef calls `shouldReturn` 0
        (status, _, _) <- capture app "GET" ["subscriptions", "orders", "dead-letters"] [("unknown", Nothing)]
        status `shouldBe` status200
    it "implements HEAD and 405 in WAI, including unavailable and unconfigured responses" $ do
        calls <- newIORef (0 :: Int)
        let app = deadLettersApp (\_ -> modifyIORef' calls (+ 1) >> pure (Right fixture))
        (status, headers, _) <- capture app "GET" route []
        capture app "HEAD" route [] `shouldReturn` (status, headers, "")
        forM_ ["POST", "PUT", "DELETE", "OPTIONS"] $ \method -> do
            (actual, hs, body) <- capture app method route []
            actual `shouldBe` status405
            lookup "Allow" hs `shouldBe` Just "GET, HEAD"
            code body `shouldBe` Just "method_not_allowed"
        readIORef calls `shouldReturn` 2
        (missing, _, body) <- capture deadLettersNotConfiguredApp "GET" route []
        missing `shouldBe` status404
        code body `shouldBe` Just "dead_letters_not_configured"
    it "sanitizes typed store failures and preserves HEAD error headers" $ do
        forM_ [(Store.ConnectionError "postgres://secret", status503, "dead_letters_unavailable"), (Store.StreamNotFound (Store.StreamName "secret"), status500, "store_error"), (Store.EventDecodeFailed (Store.DecodeFailure (Store.EventId UUID.nil) "secret"), status500, "event_decode_failed")] $ \(err, expected, expectedCode) -> do
            let app = deadLettersApp (\_ -> pure (Left err))
            (status, headers, body) <- capture app "GET" route []
            status `shouldBe` expected
            code body `shouldBe` Just expectedCode
            body `shouldSatisfy` (not . T.isInfixOf "secret" . T.pack . LBSC.unpack)
            capture app "HEAD" route [] `shouldReturn` (status, headers, "")
    it "propagates thrown provider exceptions and serves structured unknown-path errors" $ do
        result <- try @SomeException $ capture (deadLettersApp (\_ -> throwIO (userError "failure"))) "GET" route []
        result `shouldSatisfy` either (const True) (const False)
        (status, _, body) <- capture (deadLettersApp (\_ -> error "must not run")) "GET" ["unknown"] []
        status `shouldBe` status404
        code body `shouldBe` Just "not_found"
    it "serves real pages, member filters and legacy behavior from the store-aware server" $ withTestStore $ \store -> do
        let event = Store.EventData Nothing (Store.EventType "Created") (object []) Nothing Nothing Nothing
        Right _ <- Store.runStoreIO store $ Store.appendToStream (Store.StreamName "orders-1") Store.NoStream (replicate 5 event)
        Right events <- Store.runStoreIO store $ Store.readAllForward (Store.GlobalPosition 0) 10
        forM_ (V.toList events) $ \recorded -> seed store "paged/name" 0 recorded
        seed store "other" 0 (V.head events)
        handle <- Store.subscribe store $ Store.defaultSubscriptionConfig (Store.SubscriptionName "worker") Store.AllStreams $ \recorded -> pure $ case recorded ^. #globalPosition of
            Store.GlobalPosition 2 -> Store.DeadLetter (Store.DeadLetterPoison "unknown SKU")
            Store.GlobalPosition 5 -> Store.Stop
            _ -> Store.Continue
        stopped <- timeout 10_000_000 (Store.wait handle)
        case stopped of
            Just (Right ()) -> pure ()
            other -> Store.cancel handle >> expectationFailure (show other)
        metrics <- newKirokuMetrics store
        withMetricsServerWithStore defaultConfig{port = 0} metrics store [] $ \server -> do
            workerPage <- get server.serverPort "/subscriptions/worker/dead-letters" >>= decodePage
            map (.globalPosition) workerPage.items `shouldBe` [2]
            map (.reason) workerPage.items `shouldBe` [object ["kind" .= ("poison" :: Text), "detail" .= ("unknown SKU" :: Text)]]
            putStrLn ("Dead-letter worker response: " <> LBSC.unpack (Aeson.encode workerPage))
            first <- get server.serverPort "/subscriptions/paged%2Fname/dead-letters?limit=2"
            p1 <- decodePage first
            map (.globalPosition) p1.items `shouldBe` [5, 4]
            p2 <- get server.serverPort ("/subscriptions/paged%2Fname/dead-letters?limit=2&from=" <> maybe "" T.unpack p1.nextCursor) >>= decodePage
            p3 <- get server.serverPort ("/subscriptions/paged%2Fname/dead-letters?limit=2&from=" <> maybe "" T.unpack p2.nextCursor) >>= decodePage
            map (.globalPosition) p2.items `shouldBe` [3, 2]
            map (.globalPosition) p3.items `shouldBe` [1]
            p3.nextCursor `shouldBe` Nothing
            empty <- get server.serverPort "/subscriptions/never/dead-letters" >>= decodePage
            empty `shouldBe` DeadLetterPageResponse [] Nothing
            filtered <- get server.serverPort "/subscriptions/paged%2Fname/dead-letters?member=9" >>= decodePage
            filtered `shouldBe` DeadLetterPageResponse [] Nothing
            old <- get server.serverPort "/subscriptions"
            Aeson.decode (HTTP.responseBody old) `shouldBe` Just (object ["error" .= ("subscription status not configured" :: Text)])
            unknown <- get server.serverPort "/nope"
            Aeson.decode (HTTP.responseBody unknown) `shouldBe` Just (object ["error" .= ("Not found" :: Text)])
        providers <- storeServerProviders defaultConfig metrics store
        withMetricsServerWithProviders defaultConfig{port = 0} metrics [] providers $ \server -> do
            live <- get server.serverPort "/subscriptions"
            HTTP.responseStatus live `shouldBe` status200
            void $ get server.serverPort "/subscriptions/paged%2Fname/dead-letters" >>= decodePage
    it "inherits mount-relative routing and CORS with legacy switches disabled" $ do
        metrics <- newKirokuMetricsWith (pure (Store.GlobalPosition 0)) (pure 0)
        let origin = either (error . show) (\v -> v) (allowedOrigin "https://ops.example.com")
            config = defaultConfig{cors = corsAllowOrigins [origin], enableJSON = False, enableWebSocket = False}
            providers = defaultServerProviders{deadLetters = Just (\_ -> pure (Right fixture))}
            mounted req respond = combinedAppWithProviders config metrics [] providers (req{Wai.pathInfo = drop 1 (Wai.pathInfo req)}) respond
        Warp.testWithApplication (pure mounted) $ \port -> do
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/inspect/subscriptions/orders/dead-letters")
            response <- HTTP.httpLbs request{HTTP.requestHeaders = [("Origin", "https://ops.example.com")]} manager
            HTTP.responseStatus response `shouldBe` status200
            lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response) `shouldBe` Just "https://ops.example.com"

route :: [Text]
route = ["subscriptions", "orders", "dead-letters"]
invalidRequest :: IORef Int -> Wai.Application -> Query -> IO ()
invalidRequest calls app query = do
    priorCalls <- readIORef calls
    (status, _, body) <- capture app "GET" route query
    status `shouldBe` status400
    code body `shouldBe` Just "invalid_query_parameter"
    readIORef calls `shouldReturn` priorCalls
code :: LBS.ByteString -> Maybe Text
code body = case Aeson.decode body of Just (Object fields) | Just (Object err) <- KM.lookup "error" fields, Just (String value) <- KM.lookup "code" err -> Just value; _ -> Nothing
capture :: Wai.Application -> Method -> [Text] -> Query -> IO (Status, ResponseHeaders, LBS.ByteString)
capture app method path query = do
    result <- newIORef Nothing
    _ <- app Wai.defaultRequest{Wai.requestMethod = method, Wai.pathInfo = path, Wai.queryString = query} $ \response -> do
        let (status, headers, stream) = Wai.responseToStream response
        stream $ \send -> do
            chunks <- newIORef []
            send (\chunk -> modifyIORef' chunks (<> [toLazyByteString chunk])) (pure ())
            bytes <- mconcat <$> readIORef chunks
            writeIORef result (Just (status, headers, bytes))
        pure ResponseReceived
    maybe (fail "No response") pure =<< readIORef result
withTestStore :: (Store.KirokuStore -> IO ()) -> IO ()
withTestStore action = withMigratedTestDatabase $ \connection -> Store.withStore (Store.defaultConnectionSettings connection) action
get :: Int -> String -> IO (HTTP.Response LBS.ByteString)
get port path = do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
    HTTP.httpLbs request manager
decodePage :: HTTP.Response LBS.ByteString -> IO DeadLetterPageResponse
decodePage response = do
    HTTP.responseStatus response `shouldBe` status200
    either fail pure (Aeson.eitherDecode (HTTP.responseBody response))
seed :: Store.KirokuStore -> Text -> Int32 -> Store.RecordedEvent -> IO ()
seed store name member recorded = do
    let Store.EventId eid = recorded ^. #eventId
        Store.GlobalPosition position = recorded ^. #globalPosition
        params = SQL.DeadLetterParams name member "unbound" Nothing (member + 1) position eid (object ["kind" .= ("poison" :: Text), "detail" .= ("unknown SKU" :: Text)]) "poison: unknown SKU" 1
    Pool.use (store ^. #pool) (Session.statement params SQL.insertDeadLetterAndCheckpointStmt) >>= either (fail . show) pure
