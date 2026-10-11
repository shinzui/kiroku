{-# LANGUAGE ScopedTypeVariables #-}

module Test.StandaloneSpec (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (forM_, void)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBSC
import Data.Either (isLeft, isRight)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (RequestHeaders, status200)
import Network.Socket qualified as Socket
import Network.Wai.Handler.Warp qualified as Warp
import Network.WebSockets qualified as WS
import Options.Applicative qualified as O
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (hGetLine)
import System.Posix.Signals (sigINT, sigTERM, signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Hspec

import Kiroku.Metrics
import Kiroku.Store qualified as Store
import Kiroku.Test.Postgres (withMigratedTestDatabase)

spec :: Spec
spec = do
    describe "Kiroku.Metrics.Standalone (options)" $ do
        it "parses defaults, repeated origins, and all options" $ do
            isRight (parsed []) `shouldBe` True
            opts <- requireParsed ["--database-url", "postgresql://x", "--schema", "tenant", "--pool-size", "2", "--port", "0", "--cors-origin", "http://a", "--cors-origin", "http://b", "--no-cors-allow-credentials", "--ws-max-connections", "3"]
            opts.databaseUrl `shouldBe` Just "postgresql://x"
            opts.schema `shouldBe` Just "tenant"
            opts.poolSize `shouldBe` Just 2
            opts.port `shouldBe` Just 0
            opts.corsOrigins `shouldBe` ["http://a", "http://b"]
            opts.corsAllowCredentials `shouldBe` Just False
            opts.wsMaxConnections `shouldBe` Just 3
        it "rejects signed, non-ASCII, overflowing and out-of-range CLI numbers and conflicting flags" $ do
            forM_ ["-1", "+1", "", "１", "18446744073709551616", "65536"] $ \value -> isLeft (parsed ["--port", value]) `shouldBe` True
            forM_ ["--pool-size", "--ws-max-connections"] $ \flag -> isLeft (parsed [flag, "0"]) `shouldBe` True
            isLeft (parsed ["--cors-allow-credentials", "--no-cors-allow-credentials"]) `shouldBe` True
        it "resolves environment defaults and reports a missing or empty database/schema" $ do
            opts <- requireParsed []
            isLeft (resolveInspectOptions [] opts) `shouldBe` True
            rt <- resolved [("DATABASE_URL", "postgresql://env")] opts
            rt.databaseUrl `shouldBe` "postgresql://env"
            rt.schema `shouldBe` "kiroku"
            rt.poolSize `shouldBe` (Store.defaultConnectionSettings "").poolSize
            rt.port `shouldBe` 9091
            rt.cors `shouldBe` corsDisabled
            rt.wsMaxConnections `shouldBe` 100
            forM_ [["--database-url", ""], ["--database-url", "x", "--schema", " "]] $ \args -> requireParsed args >>= \o -> isLeft (resolveInspectOptions [] o) `shouldBe` True
        it "valid flags override malformed environment values including explicit credentials False" $ do
            opts <- requireParsed ["--database-url", "flag", "--port", "0", "--pool-size", "1", "--schema", "tenant", "--ws-max-connections", "1", "--cors-origin", "http://a", "--no-cors-allow-credentials"]
            rt <- resolved [("DATABASE_URL", "env"), ("KIROKU_INSPECT_PORT", "bad"), ("KIROKU_INSPECT_POOL_SIZE", "bad"), ("KIROKU_INSPECT_SCHEMA", "bad"), ("KIROKU_INSPECT_WS_MAX_CONNECTIONS", "bad"), ("KIROKU_INSPECT_CORS_ORIGINS", "*"), ("KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS", "bad")] opts
            rt.databaseUrl `shouldBe` "flag"
            rt.port `shouldBe` 0
            rt.schema `shouldBe` "tenant"
            rt.cors.allowCredentials `shouldBe` False
            rt2 <- resolved [("KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS", "true")] opts
            rt2.cors.allowCredentials `shouldBe` False
        it "validates environment numbers and booleans, normalizes origins and refuses wildcard" $ do
            opts <- requireParsed ["--database-url", "x"]
            forM_ ["KIROKU_INSPECT_POOL_SIZE", "KIROKU_INSPECT_WS_MAX_CONNECTIONS", "KIROKU_INSPECT_PORT"] $ \name ->
                forM_ ["abc", "-1", "+1", "９", "18446744073709551616"] $ \value -> isLeft (resolveInspectOptions [(name, value)] opts) `shouldBe` True
            isLeft (resolveInspectOptions [("KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS", "yes")] opts) `shouldBe` True
            rt <- resolved [("KIROKU_INSPECT_CORS_ORIGINS", "https://Ops.example.com/, http://localhost:5173"), ("KIROKU_INSPECT_CORS_ALLOW_CREDENTIALS", "true")] opts
            map renderAllowedOrigin rt.cors.allowedOrigins `shouldBe` ["https://ops.example.com", "http://localhost:5173"]
            rt.cors.allowCredentials `shouldBe` True
            wild <- requireParsed ["--database-url", "x", "--cors-origin", "*"]
            either (T.isInfixOf "wildcard") (const False) (resolveInspectOptions [] wild) `shouldBe` True
            empty <- resolved [("KIROKU_INSPECT_PORT", ""), ("KIROKU_INSPECT_SCHEMA", "")] opts
            empty.port `shouldBe` 9091
            empty.schema `shouldBe` "kiroku"
    describe "Kiroku.Metrics.Standalone (end to end)" $ do
        it "serves durable reads, an empty live registry, CORS, and real event tail from a database URL" $
            withMigratedTestDatabase $ \url -> do
                rt <- runtime url
                ready <- newEmptyMVar
                done <- newEmptyMVar
                let hooks = InspectHooks (\port caps -> putMVar ready (port, caps)) (takeMVar done)
                Async.withAsync (runInspect hooks rt) $ \server -> do
                    (port, caps) <- bounded (takeMVar ready)
                    caps.routes `shouldBe` RouteAvailability True True True True True True True True True
                    caps.corsIsEnabled `shouldBe` True
                    Store.withStore (Store.defaultConnectionSettings url) $ \writer -> do
                        append writer "orders-1" 3
                        response <- get port "/capabilities" []
                        A.eitherDecode (HTTP.responseBody response) `shouldBe` Right caps
                        LBSC.putStrLn ("standalone discovery capture: " <> HTTP.responseBody response)
                        streams <- get port "/streams?category=orders" []
                        HTTP.responseStatus streams `shouldBe` status200
                        (A.decode (HTTP.responseBody streams) >>= key "items") `shouldSatisfy` maybe False (\case A.Array rows -> any (\row -> key "name" row == Just (A.String "orders-1")) rows; _ -> False)
                        live <- get port "/subscriptions" []
                        A.decode (HTTP.responseBody live) `shouldBe` Just (A.toJSON ([] :: [A.Value]))
                        inventory <- get port "/subscription-checkpoints" []
                        case A.eitherDecode (HTTP.responseBody inventory) of
                            Right (CheckpointInventoryResponse pos rows) -> do
                                pos `shouldSatisfy` (>= 3)
                                rows `shouldBe` []
                            Left err -> expectationFailure err
                        forM_ ["/health/ready", "/subscriptions/missing/dead-letters", "/events", "/categories"] $ \path -> HTTP.responseStatus <$> get port path [] `shouldReturn` status200
                        forM_ [("http://localhost:5173", Just "http://localhost:5173"), ("http://evil.example", Nothing)] $ \(origin, expected) -> do
                            response2 <- get port "/metrics" [("Origin", origin)]
                            lookup "Access-Control-Allow-Origin" (HTTP.responseHeaders response2) `shouldBe` expected
                            (A.decode (HTTP.responseBody response2) >>= key "subscriptions") `shouldBe` Just (A.object [])
                        bounded $ WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
                            WS.sendTextData conn (A.encode (A.object ["type" A..= ("subscribe_events" :: Text)]))
                            void (frame conn "event_stream_started")
                            append writer "orders-2" 1
                            ev <- frame conn "event"
                            (key "event" ev >>= key "original_stream_name") `shouldBe` Just (A.String "orders-2")
                            (key "event" ev >>= key "eventType") `shouldBe` Just (A.String "OrderCreated")
                    putMVar done ()
                    bounded (Async.wait server)
                    assertReleased port
        it "releases its listener on immediate shutdown, hook exception and cancellation" $
            withMigratedTestDatabase $ \url -> do
                rt <- runtime url
                forM_ [False, True] $ \shouldFail -> do
                    portRef <- newIORef 0
                    let hooks = InspectHooks (\port _ -> writeIORef portRef port >> if shouldFail then throwIO (userError "hook failed") else pure ()) (pure ())
                    result <- bounded (try (runInspect hooks rt) :: IO (Either SomeException ()))
                    result `shouldSatisfy` (if shouldFail then isLeft else isRight)
                    readIORef portRef >>= assertReleased
                ready <- newEmptyMVar
                never <- newEmptyMVar
                Async.withAsync (runInspect (InspectHooks (\port _ -> putMVar ready port) (takeMVar never)) rt) $ \server -> do
                    port <- bounded (takeMVar ready)
                    bounded (Async.cancel server)
                    assertReleased port
        it "does not call onListening on an occupied port" $
            withMigratedTestDatabase $ \url -> do
                rt <- runtime url
                withOccupiedPort $ \port -> do
                    called <- newIORef False
                    result <- bounded (try (runInspect (InspectHooks (\_ _ -> writeIORef called True) (pure ())) (InspectRuntime rt.databaseUrl rt.schema rt.poolSize port rt.cors rt.wsMaxConnections)) :: IO (Either SomeException ()))
                    result `shouldSatisfy` isLeft
                    readIORef called `shouldReturn` False
    describe "kiroku-inspect (executable)" $ do
        it "exits 2 for usage/resolution errors and redacts runtime connection failures" $ do
            exe <- executable
            env <- cleanEnvironment
            forM_ [[], ["--unknown"], ["--database-url", "x", "--cors-origin", "*"]] $ \args -> do
                (exit, _, _) <- bounded (Process.readCreateProcessWithExitCode (Process.proc exe args){Process.env = Just env} "")
                exit `shouldBe` ExitFailure 2
            (exit, out, err) <- bounded (Process.readCreateProcessWithExitCode (Process.proc exe ["--database-url", "postgresql://user:secret@127.0.0.1:1/db?connect_timeout=1"]){Process.env = Just env} "")
            exit `shouldBe` ExitFailure 1
            out `shouldBe` ""
            T.pack err `shouldSatisfy` (not . T.isInfixOf "secret")
        it "prints no success banner and exits 1 on bind failure" $
            withMigratedTestDatabase $ \url -> withOccupiedPort $ \port -> do
                exe <- executable
                env <- cleanEnvironment
                (exit, out, err) <- bounded (Process.readCreateProcessWithExitCode (Process.proc exe ["--database-url", T.unpack url, "--port", show port]){Process.env = Just env} "")
                exit `shouldBe` ExitFailure 1
                out `shouldBe` ""
                err `shouldSatisfy` (not . null)
        it "exits 0 after SIGINT or SIGTERM, including repeated signals" $
            withMigratedTestDatabase $ \url -> do
                exe <- executable
                env <- cleanEnvironment
                forM_ [sigINT, sigTERM] $ \signal ->
                    bracket (Process.createProcess (Process.proc exe ["--database-url", T.unpack url, "--port", "0"]){Process.env = Just env, Process.std_out = Process.CreatePipe, Process.std_err = Process.CreatePipe}) Process.cleanupProcess $ \(_, out, _, process) -> do
                        handle <- maybe (fail "No stdout") pure out
                        first <- bounded (hGetLine handle)
                        first `shouldSatisfy` (T.isInfixOf "listening on port" . T.pack)
                        void (bounded (hGetLine handle))
                        void (bounded (hGetLine handle))
                        pid <- Process.getPid process >>= maybe (fail "No PID") pure
                        signalProcess signal pid
                        signalProcess signal pid
                        shutting <- bounded (hGetLine handle)
                        shutting `shouldBe` "kiroku-inspect: shutting down"
                        bounded (Process.waitForProcess process) `shouldReturn` ExitSuccess

parsed :: [String] -> Either String InspectOptions
parsed args = maybe (Left "Parse failed") Right (O.getParseResult (O.execParserPure O.defaultPrefs inspectParserInfo args))

requireParsed :: [String] -> IO InspectOptions
requireParsed = either fail pure . parsed

resolved :: [(String, String)] -> InspectOptions -> IO InspectRuntime
resolved env opts = either (fail . T.unpack) pure (resolveInspectOptions env opts)

runtime :: Text -> IO InspectRuntime
runtime url = requireParsed ["--database-url", T.unpack url, "--port", "0", "--cors-origin", "http://localhost:5173"] >>= resolved []

key :: Text -> A.Value -> Maybe A.Value
key name (A.Object o) = KM.lookup (K.fromText name) o
key _ _ = Nothing

frame :: WS.Connection -> Text -> IO A.Value
frame conn wanted = do
    raw <- WS.receiveData conn :: IO LBS.ByteString
    case A.decode raw of
        Just value | key "type" value == Just (A.String wanted) -> pure value
        _ -> frame conn wanted

get :: Int -> String -> RequestHeaders -> IO (HTTP.Response LBS.ByteString)
get port path headers = do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    req <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
    HTTP.httpLbs req{HTTP.requestHeaders = headers} manager

append :: Store.KirokuStore -> Text -> Int -> IO ()
append store name count = do
    result <- Store.runStoreIO store (Store.appendToStream (Store.StreamName name) Store.NoStream (replicate count (Store.EventData Nothing (Store.EventType "OrderCreated") A.Null Nothing Nothing Nothing)))
    result `shouldSatisfy` isRight

bounded :: IO a -> IO a
bounded action = timeout 15_000_000 action >>= maybe (fail "Timed out") pure

assertReleased :: Int -> IO ()
assertReleased port =
    bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
        Socket.setSocketOption socket Socket.ReuseAddr 1
        Socket.bind socket (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (0, 0, 0, 0)))
        Socket.listen socket 1

withOccupiedPort :: (Int -> IO a) -> IO a
withOccupiedPort action = do
    (port, reserved) <- Warp.openFreePort
    Socket.close reserved
    bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \ipv4 ->
        bracket (Socket.socket Socket.AF_INET6 Socket.Stream Socket.defaultProtocol) Socket.close $ \ipv6 -> do
            Socket.bind ipv4 (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (0, 0, 0, 0)))
            Socket.listen ipv4 1
            Socket.setSocketOption ipv6 Socket.IPv6Only 1
            Socket.bind ipv6 (Socket.SockAddrInet6 (fromIntegral port) 0 (0, 0, 0, 0) 0)
            Socket.listen ipv6 1
            action port

executable :: IO FilePath
executable = findExecutable "kiroku-inspect" >>= maybe (fail "Cabal build-tool-depends did not supply kiroku-inspect") pure

cleanEnvironment :: IO [(String, String)]
cleanEnvironment = filter (\(name, _) -> name /= "DATABASE_URL" && not ("KIROKU_INSPECT_" `T.isPrefixOf` T.pack name)) <$> getEnvironment
