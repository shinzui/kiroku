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
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import Kiroku.Metrics qualified as M
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Store qualified as S
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode)
import Network.WebSockets qualified as WS
import System.Environment (getArgs)
import System.Timeout (timeout)

main :: IO ()
main = do
    [arm, mode, output] <- getArgs
    unless (arm `elem` ["control", "candidate"] && mode `elem` ["disabled", "active"]) (fail "invalid probe arguments")
    withMigratedTestDatabase $ \url -> S.withStore (S.defaultConnectionSettings url) $ \store -> do
        -- Non-empty inventory and historical-member dead-letter pages, plus a
        -- catalog large enough to distinguish bounded reads from full scans.
        void (right =<< S.runStoreIO store (S.appendToStream (S.StreamName "seed-1") S.NoStream [S.EventData Nothing (S.EventType "Seed") A.Null Nothing Nothing Nothing]))
        right =<< Pool.use store.pool (Session.script "INSERT INTO streams(stream_name,stream_version) SELECT 'catalog-' || lpad(n::text,8,'0'),0 FROM generate_series(1,10000) n; INSERT INTO dead_letters(subscription_name,consumer_group_member,global_position,event_id,reason,reason_summary,attempt_count) SELECT 'probe',m,n,(SELECT event_id FROM events LIMIT 1),'{}','fixture',1 FROM unnest(ARRAY[0,1,9]) m CROSS JOIN generate_series(1,2000) n; INSERT INTO subscriptions(subscription_name,last_seen,target_kind) SELECT 'inventory-' || n,0,'all' FROM generate_series(1,100) n; ANALYZE streams; ANALYZE dead_letters")
        -- Keep this local probe durable; cached ephemeral defaults are not
        -- assumed to be production durability settings.
        forM_ ["ALTER SYSTEM SET fsync=on", "ALTER SYSTEM SET synchronous_commit=on", "ALTER SYSTEM SET full_page_writes=on", "SELECT pg_reload_conf()"] $ \sql -> void (right =<< Pool.use store.pool (Session.script sql))
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
            seen <- newTVarIO (Set.empty :: Set.Set Integer)
            names <- newTVarIO (Set.empty :: Set.Set T.Text)
            errors <- newTVarIO ([] :: [A.Value])
            started <- newEmptyTMVarIO
            polls <- newIORef ([] :: [(String, Int)])
            let tailClient = WS.runClient "127.0.0.1" port "/ws/events" $ \conn -> do
                    WS.sendTextData conn (A.encode (A.object ["type" A..= ("subscribe_events" :: T.Text)]))
                    forever $ do
                        raw <- WS.receiveData conn :: IO LBS.ByteString
                        value <- maybe (fail "invalid frame") pure (A.decode raw)
                        case field "type" value of
                            Just (A.String "event_stream_started") -> atomically $ void (tryPutTMVar started ())
                            Just (A.String "event") -> case field "event" value >>= field "globalPosition" of
                                Just (A.Number pos) -> atomically $ do
                                    modifyTVar' seen (Set.insert (round pos))
                                    case field "event" value >>= field "original_stream_name" of
                                        Just (A.String name) -> modifyTVar' names (Set.insert name)
                                        _ -> when (arm == "candidate") (error "missing resolved name")
                                _ -> fail "missing event position"
                            Just (A.String "error") -> atomically $ modifyTVar' errors (value :)
                            _ -> pure ()
                polling = forever $ do
                    forM_ ["/streams?category=catalog&prefix=catalog-00009&limit=10", "/categories?limit=10", "/subscriptions/probe/dead-letters?limit=10", "/subscription-checkpoints"] $ \path -> do
                        response <- get manager port path
                        let status = statusCode (HTTP.responseStatus response)
                        unless (status == if arm == "candidate" then 200 else 404) (fail ("unexpected polling status: " <> show status))
                        atomicModifyIORef' polls (\xs -> ((path, status) : xs, ()))
                    threadDelay 1_000_000
                run = do
                    when (mode == "active") $ bounded (atomically $ takeTMVar started)
                    total <- newIORef (0 :: Int)
                    let phase seconds record = do
                            begin <- getMonotonicTimeNSec
                            sampleLists <- Async.mapConcurrently (writer store total begin seconds record) [0 .. 3]
                            end <- getMonotonicTimeNSec
                            pure (concat sampleLists, fromIntegral (end - begin) / 1e9 :: Double)
                    void (phase 2 False)
                    (samples, elapsed) <- phase 10 True
                    count <- readIORef total
                    durable <- scalarJSON store "SELECT to_jsonb(count(*)) FROM events"
                    unless (durable == A.toJSON (count + 1)) (fail "durable append count mismatch")
                    when (mode == "active") $ bounded $ atomically $ readTVar seen >>= check . (== count) . Set.size
                    frames <- readTVarIO seen
                    uniqueNames <- readTVarIO names
                    failures <- readTVarIO errors
                    unless (null failures) (fail ("tail errors: " <> show failures))
                    when (mode == "active" && arm == "candidate") $ unless (Set.size uniqueNames > 4096) (fail "probe did not exercise distinct-name cache eviction")
                    polled <- readIORef polls
                    let sorted = sort samples
                        percentile :: Double -> Double
                        percentile fraction = sorted !! min (length sorted - 1) (floor (fraction * fromIntegral (length sorted - 1)))
                    A.encodeFile output (A.object ["arm" A..= arm, "mode" A..= mode, "database" A..= database, "durable_events" A..= durable, "seconds" A..= elapsed, "measured_appends" A..= length samples, "total_appends" A..= count, "throughput" A..= (fromIntegral (length samples) / elapsed), "p50_us" A..= percentile 0.50, "p95_us" A..= percentile 0.95, "p99_us" A..= percentile 0.99, "raw_latency_us" A..= samples, "tail_events" A..= Set.size frames, "resolved_names" A..= Set.size uniqueNames, "poll_responses" A..= polled, "tail_errors" A..= failures])
            if mode == "active"
                then Async.withAsync tailClient $ \tailWorker -> Async.withAsync polling $ \pollWorker -> do
                    Async.link tailWorker
                    Async.link pollWorker
                    run
                else run

writer :: S.KirokuStore -> IORef Int -> Word64 -> Int -> Bool -> Int -> IO [Double]
writer store total begin seconds record worker = go 0 []
  where
    event = S.EventData Nothing (S.EventType "Probe") (A.object ["body" A..= T.replicate 512 "x"]) Nothing Nothing Nothing
    go :: Int -> [Double] -> IO [Double]
    go n samples = do
        start <- getMonotonicTimeNSec
        if start - begin >= fromIntegral seconds * 1_000_000_000
            then pure samples
            else do
                -- Interleave warm streams and new names in the same workload.
                let name = if even n then "warm-" <> T.pack (show worker) else "fresh-" <> T.pack (show worker) <> "-" <> T.pack (show begin) <> "-" <> T.pack (show n)
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
