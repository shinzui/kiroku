-- A focused local diagnostic using only APIs shared with the released control.
-- It deliberately makes no statistical equivalence or benchmark-grade claim.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Monad (forM_, forever, unless, void, when)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Int (Int64)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word64)
import Delivery
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Kiroku.Metrics qualified as M
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Store qualified as S
import Kiroku.Store.Subscription.EventPublisher (publisherPosition)
import Kiroku.Test.Postgres (migrateTestDatabase, withMigratedTestDatabase)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode)
import Network.WebSockets qualified as WS
import System.Environment (getArgs, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hFlush, hGetLine, hPutStrLn, stdin, stdout)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import System.Timeout (timeout)

main :: IO ()
main =
    getArgs >>= \case
        ["self-test"] -> do
            one <- either fail pure (acceptPosition 2 initialDelivery)
            unless (completeDelivery 1 one && not (completeDelivery 2 one)) (fail "completion oracle")
            forM_ [1, 2, 4] $ \bad -> case acceptPosition bad one of
                Left _ -> pure ()
                Right _ -> fail "oracle accepted duplicate, reversal, or gap"
            putStrLn "delivery oracle: duplicate, gap, reversal and incomplete delivery rejected"
        ["observer", arm, port, output] -> observer arm (read port) output
        [arm, mode, output] -> trial arm mode output
        _ -> fail "usage: inspection-probe control|candidate disabled|active OUTPUT; or self-test"

trial :: String -> String -> FilePath -> IO ()
trial arm mode output = do
    unless (arm `elem` ["control", "candidate"] && mode `elem` ["disabled", "active"]) (fail "invalid probe arguments")
    withDatabase $ \url -> S.withStore (S.defaultConnectionSettings url) $ \store -> do
        -- Non-empty inventory and historical-member dead-letter pages, plus a
        -- catalog large enough to distinguish bounded reads from full scans.
        void (right =<< S.runStoreIO store (S.appendToStream (S.StreamName "seed-1") S.NoStream [S.EventData Nothing (S.EventType "Seed") A.Null Nothing Nothing Nothing]))
        right =<< Pool.use store.pool (Session.script "INSERT INTO streams(stream_name,stream_version) SELECT 'catalog-' || lpad(n::text,8,'0'),0 FROM generate_series(1,10000) n; INSERT INTO dead_letters(subscription_name,consumer_group_member,global_position,event_id,reason,reason_summary,attempt_count) SELECT 'probe',m,n,(SELECT event_id FROM events LIMIT 1),'{}','fixture',1 FROM unnest(ARRAY[0,1,9]) m CROSS JOIN generate_series(1,2000) n; INSERT INTO subscriptions(subscription_name,last_seen,target_kind) SELECT 'inventory-' || n,0,'all' FROM generate_series(1,100) n; ANALYZE streams; ANALYZE dead_letters")
        -- Keep this local probe durable; cached ephemeral defaults are not
        -- assumed to be production durability settings.
        external <- lookupEnv "MP13_DATABASE_URL"
        when (external == Nothing) $
            forM_ ["ALTER SYSTEM SET fsync=on", "ALTER SYSTEM SET synchronous_commit=on", "ALTER SYSTEM SET full_page_writes=on", "SELECT pg_reload_conf()"] $
                \sql -> void (right =<< Pool.use store.pool (Session.script sql))
        when (external /= Nothing) $ void (right =<< Pool.use store.pool (Session.script "CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public"))
        threadDelay 50_000
        database <- scalarJSON store "SELECT jsonb_build_object('version',current_setting('server_version'),'fsync',current_setting('fsync'),'synchronous_commit',current_setting('synchronous_commit'),'full_page_writes',current_setting('full_page_writes'))"
        forM_ ["fsync", "synchronous_commit", "full_page_writes"] $ \key -> unless (field key database == Just (A.String "on")) (fail "database durability setting not applied")
        unless (maybe False (\case A.String version -> "18." `T.isPrefixOf` version; _ -> False) (field "version" database)) (fail "probe requires PostgreSQL 18")
        metrics <- M.newKirokuMetrics store
        M.withMetricsServerWithStore Config.defaultConfig{Config.port = 0, Config.enableWebSocket = mode == "active"} metrics store [] $ \server -> do
            -- The old starter returns before binding; make both arms wait.
            manager <- HTTP.newManager HTTP.defaultManagerSettings
            let port = server.serverPort
            bounded $ ready manager port
            bounded $ atomically $ publisherPosition store.publisher >>= check . (>= S.GlobalPosition 1)
            let run finishObserver = do
                    total <- newIORef (0 :: Int)
                    warmup <- secondsEnv "MP13_WARMUP_SECONDS" 2
                    measurement <- secondsEnv "MP13_MEASUREMENT_SECONDS" 10
                    let phase seconds record = do
                            begin <- getMonotonicTimeNSec
                            sampleLists <- Async.mapConcurrently (writer store total begin seconds record) [0 .. 3]
                            end <- getMonotonicTimeNSec
                            pure (concat sampleLists, fromIntegral (end - begin) / 1e9 :: Double)
                    void (phase warmup False)
                    statsBefore <- statementStats store
                    before <- scalarJSON store "SELECT to_jsonb(pg_current_wal_insert_lsn()::text)"
                    (samples, elapsed) <- phase measurement True
                    after <- scalarJSON store "SELECT to_jsonb(pg_current_wal_insert_lsn()::text)"
                    statsAfter <- statementStats store
                    count <- readIORef total
                    durable <- scalarJSON store "SELECT to_jsonb(count(*)) FROM events"
                    unless (durable == A.toJSON (count + 1)) (fail "durable append count mismatch")
                    observation <- finishObserver count
                    A.encodeFile output (A.object ["schema" A..= ("mp13.inspection-trial/v2" :: String), "arm" A..= arm, "mode" A..= mode, "database" A..= database, "durable_events" A..= durable, "seconds" A..= elapsed, "warmup_seconds" A..= warmup, "measurement_seconds" A..= measurement, "measured_appends" A..= length samples, "total_appends" A..= count, "throughput" A..= (fromIntegral (length samples) / elapsed), "p50_us" A..= percentile 0.50 samples, "p95_us" A..= percentile 0.95 samples, "p99_us" A..= percentile 0.99 samples, "raw_latency_us" A..= samples, "wal_lsn_before" A..= before, "wal_lsn_after" A..= after, "sql_before" A..= statsBefore, "sql_after" A..= statsAfter, "observer" A..= observation])
            if mode == "active"
                then do
                    exe <- getExecutablePath
                    let childOutput = output <> ".observer.json"
                    withCreateProcess (proc exe ["observer", arm, show port, childOutput]){std_in = CreatePipe, std_out = CreatePipe} $ \input childStdout _ child -> case (input, childStdout) of
                        (Just send, Just receive) -> do
                            message <- bounded (hGetLine receive)
                            unless (message == "READY") (fail "observer did not become ready")
                            run $ \count -> do
                                hPutStrLn send (show count)
                                hFlush send
                                code <- bounded (waitForProcess child)
                                unless (code == ExitSuccess) (fail "observer rejected delivery")
                                A.eitherDecodeFileStrict' childOutput >>= either fail pure
                        _ -> fail "observer pipe setup failed"
                else run (const (pure A.Null))

-- The observer has its own heap and GC, equally for both arms.
observer :: String -> Int -> FilePath -> IO ()
observer arm port output = do
    delivery <- newTVarIO initialDelivery
    names <- newTVarIO Set.empty
    lags <- newTVarIO ([] :: [Double])
    started <- newEmptyTMVarIO
    polls <- newIORef ([] :: [(String, Int)])
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    let tailClient = WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
            WS.sendTextData conn (A.encode (A.object ["type" A..= ("subscribe_events" :: T.Text)]))
            forever $ do
                raw <- WS.receiveData conn :: IO LBS.ByteString
                value <- maybe (fail "invalid frame") pure (A.decode raw)
                now <- getMonotonicTimeNSec
                case field "type" value of
                    Just (A.String "event_stream_started") -> do
                        unless (field "from_position" value == Just (A.toJSON (1 :: Int))) (fail "unexpected attach frontier")
                        atomically $ void (tryPutTMVar started ())
                    Just (A.String "event") -> do
                        event <- maybe (fail "missing event") pure (field "event" value)
                        position <- integerField "globalPosition" event
                        sid <- integerField "originalStreamId" event
                        payload <- maybe (fail "missing payload") pure (field "payload" event)
                        sent <- integerField "sent_ns" payload
                        expectedName <- maybe (fail "missing expected name") pure (field "source" payload)
                        when (arm == "candidate") $ unless (field "original_stream_name" event == Just expectedName) (fail "incorrect resolved stream name")
                        when (sent > fromIntegral now) (fail "negative event lag")
                        atomically $ do
                            previous <- readTVar delivery
                            next <- either (throwSTM . userError) pure (acceptPosition position previous)
                            writeTVar delivery next
                            modifyTVar' names (Set.insert sid)
                            modifyTVar' lags (fromIntegral (fromIntegral now - sent :: Int64) / 1000 :)
                    Just (A.String "error") -> fail "tail error frame"
                    _ -> pure ()
        polling = forever $ do
            forM_ ["/streams?category=catalog&prefix=catalog-00009&limit=10", "/categories?limit=10", "/subscriptions/probe/dead-letters?limit=10", "/subscription-checkpoints"] $ \path -> do
                response <- get manager port path
                let status = statusCode (HTTP.responseStatus response)
                unless (status == if arm == "candidate" then 200 else 404) (fail "unexpected polling status")
                atomicModifyIORef' polls (\xs -> ((path, status) : xs, ()))
            threadDelay 1_000_000
    Async.withAsync tailClient $ \tailWorker -> Async.withAsync polling $ \pollWorker -> do
        Async.link tailWorker
        Async.link pollWorker
        bounded (atomically $ takeTMVar started)
        putStrLn "READY"
        hFlush stdout
        expected <- read <$> hGetLine stdin
        bounded $ atomically $ readTVar delivery >>= check . completeDelivery expected
        -- Cancel/join before snapshotting; no frames can escape the oracle.
        Async.cancel tailWorker
        Async.cancel pollWorker
        final <- readTVarIO delivery
        observedNames <- readTVarIO names
        lagSamples <- readTVarIO lags
        polled <- readIORef polls
        unless (completeDelivery expected final) (fail "incorrect final frontier")
        unless (Set.size observedNames > 4096) (fail "insufficient distinct-name churn")
        A.encodeFile output (A.object ["ordered_exact_delivery" A..= True, "tail_events" A..= final.frameCount, "last_position" A..= final.lastPosition, "source_streams_seen" A..= Set.size observedNames, "verified_names" A..= (if arm == "candidate" then final.frameCount else 0), "poll_responses" A..= polled, "lag_p99_us" A..= percentile 0.99 lagSamples, "raw_lag_us" A..= lagSamples])

integerField :: A.Key -> A.Value -> IO Int64
integerField key value = case field key value of
    Just number -> case A.fromJSON number of
        A.Success n -> pure n
        A.Error _ -> fail "non-integral or overflowing event field"
    _ -> fail "missing integer event field"

percentile :: Double -> [Double] -> Double
percentile fraction samples = let ordered = sort samples in ordered !! min (length ordered - 1) (floor (fraction * fromIntegral (length ordered - 1)))

secondsEnv :: String -> Int -> IO Int
secondsEnv key fallback = do
    value <- maybe fallback read <$> lookupEnv key
    unless (value >= 1 && value <= 120) (fail "phase duration outside 1..120 seconds")
    pure value

withDatabase :: (T.Text -> IO a) -> IO a
withDatabase action =
    lookupEnv "MP13_DATABASE_URL" >>= \case
        Nothing -> withMigratedTestDatabase action
        Just url -> migrateTestDatabase (T.pack url) >> action (T.pack url)

-- Required on the controlled cell; unavailable local extensions are explicit nulls.
statementStats :: S.KirokuStore -> IO A.Value
statementStats store = do
    required <- (== Just "1") <$> lookupEnv "MP13_SQL_STATS_REQUIRED"
    result <- Pool.use store.pool (Session.statement () (preparable "SELECT coalesce(jsonb_agg(jsonb_build_object('query',query,'calls',calls,'rows',rows,'shared_blks_hit',shared_blks_hit,'shared_blks_read',shared_blks_read,'wal_bytes',wal_bytes)), '[]'::jsonb) FROM public.pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND query NOT LIKE '%pg_stat_statements%'" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))
    case result of
        Right value -> pure value
        Left err | required -> fail (show err)
        Left _ -> pure A.Null

writer :: S.KirokuStore -> IORef Int -> Word64 -> Int -> Bool -> Int -> IO [Double]
writer store total begin seconds record worker = go 0 []
  where
    go :: Int -> [Double] -> IO [Double]
    go n samples = do
        start <- getMonotonicTimeNSec
        if start - begin >= fromIntegral seconds * 1_000_000_000
            then pure samples
            else do
                -- Interleave warm streams and new names in the same workload.
                let name = if even n then "warm-" <> T.pack (show worker) else "fresh-" <> T.pack (show worker) <> "-" <> T.pack (show begin) <> "-" <> T.pack (show n)
                let event = S.EventData Nothing (S.EventType "Probe") (A.object ["body" A..= T.replicate 512 "x", "source" A..= name, "sent_ns" A..= start]) Nothing Nothing Nothing
                void (right =<< S.runStoreIO store (S.appendToStream (S.StreamName name) S.AnyVersion [event]))
                end <- getMonotonicTimeNSec
                atomicModifyIORef' total (\x -> (x + 1, ()))
                go (n + 1) (if record then fromIntegral (end - start) / 1000 : samples else samples)

field :: A.Key -> A.Value -> Maybe A.Value
field key (A.Object fields) = KM.lookup key fields
field _ _ = Nothing

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

scalarJSON :: S.KirokuStore -> T.Text -> IO A.Value
scalarJSON store sql = right =<< Pool.use store.pool (Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))))

get :: HTTP.Manager -> Int -> String -> IO (HTTP.Response LBS.ByteString)
get manager port path = HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path) >>= \req -> HTTP.httpLbs req manager

ready :: HTTP.Manager -> Int -> IO ()
ready manager port = do
    -- HTTP's own connection retry covers the old listener startup race.
    threadDelay 300_000
    response <- get manager port "/metrics"
    unless (statusCode (HTTP.responseStatus response) == 200) (fail "server not ready")

bounded :: IO a -> IO a
bounded action = timeout 30_000_000 action >>= maybe (fail "probe deadline") pure
