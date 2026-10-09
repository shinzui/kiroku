{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedRecordDot #-}

{- | MP-12's durable append/subscription comparison probe. Build this identical
workload against the original control and candidate; only the legacy group
constructor needs a compatibility branch. No production instrumentation.
-}
module Main (main) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Bytes
import Data.IORef
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import EphemeralPg qualified as Pg
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Test.Postgres (ephemeralConfig, migrateTestDatabase)
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Adapter.Kiroku qualified as Adapter
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Workload = Workload
    { seconds :: !Int
    , mode :: !String
    , width :: !Int
    , appendBatch :: !Int
    , checkpointBatch :: !Int32
    , fresh :: !Bool
    , offered :: !Int
    }

main :: IO ()
main = do
    args <- getArgs
    workload <- case args of
        [duration, mode, width, batch, checkpoint, fresh, offered] ->
            Workload <$> number duration <*> pure mode <*> number width <*> number batch <*> number checkpoint <*> number fresh <*> number offered
        _ -> fail "usage: write-probe SECONDS MODE WIDTH APPEND_BATCH CHECKPOINT_BATCH FRESH OFFERED_CALLS_PER_SEC (MODE=none|all|category|group|adapter)"
    unless (workload.seconds > 0 && workload.width > 0 && workload.appendBatch > 0 && workload.checkpointBatch > 0 && workload.offered >= 0 && workload.mode `elem` ["none", "all", "category", "group", "adapter"]) (fail "invalid workload")
    original <- ephemeralConfig
    let overridden = ["fsync", "full_page_writes", "synchronous_commit", "shared_buffers", "wal_level"]
        durable = original{Pg.postgresSettings = filter (\(key, _) -> key `notElem` overridden) original.postgresSettings ++ [("fsync", "on"), ("synchronous_commit", "on"), ("full_page_writes", "on"), ("shared_buffers", "128MB"), ("wal_level", "replica")]}
    result <- Pg.withCachedConfig durable Pg.defaultCacheConfig $ \database -> do
        migrateTestDatabase (Pg.connectionString database)
        live <- newIORef (0 :: Int)
        failures <- newIORef (0 :: Int)
        batches <- newIORef (0 :: Int)
        let observe = \case
                KirokuEventSubscriptionCaughtUp{} -> atomicModifyIORef' live (\n -> (n + 1, ()))
                KirokuEventSubscriptionDbError{} -> atomicModifyIORef' failures (\n -> (n + 1, ()))
                KirokuEventSubscriptionDelivered{} -> atomicModifyIORef' batches (\n -> (n + 1, ()))
                _ -> pure ()
            settings = (defaultConnectionSettings (Pg.connectionString database)){poolSize = 10, eventHandler = Just observe}
        withStore settings $ \store -> do
            let event = EventData Nothing (EventType "Probe") (object ["body" .= Text.replicate 512 "x"]) Nothing Nothing Nothing
            -- Identical existing-stream fixtures and explicit future-only live entry.
            forM_ [0 .. 3] $ \writer -> forM_ [0 .. workload.width - 1] $ \slot ->
                void $ append store [(stream writer slot 0 False, AnyVersion, [event])]
            delivered <- newIORef (0 :: Int)
            let handler _ = atomicModifyIORef' delivered (\n -> (n + 1, ())) >> pure Continue
                config m =
                    (defaultSubscriptionConfig (SubscriptionName "probe") (workloadTarget workload) handler)
                        { missingCheckpointPolicy = FromCurrentHead
                        , batchSize = workload.checkpointBatch
                        , consumerGroup = if workload.mode == "group" then Just (membership m) else Nothing
                        }
                members = if workload.mode == "group" then [0, 1, 2, 3] else [0]
                native = bracket (mapM (subscribe store . config) members) (mapM_ cancel) $ \_ -> measure workload store event delivered live failures batches (length members)
            case workload.mode of
                "none" -> measure workload store event delivered live failures batches 0
                "adapter" -> runEff $ runTracingNoop $ do
                    adapter <-
                        kirokuAdapter store $
                            (defaultKirokuAdapterConfig (SubscriptionName "probe") AllStreams)
                                { Adapter.missingCheckpointPolicy = FromCurrentHead
                                , Adapter.batchSize = workload.checkpointBatch
                                }
                    app <- runApp defaultAppConfig [(ProcessorId "probe", mkProcessor adapter (\_ -> liftIO (atomicModifyIORef' delivered (\n -> (n + 1, ()))) >> pure AckOk))]
                    case app of
                        Left err -> liftIO $ fail (show err)
                        Right handle -> do
                            liftIO $ measure workload store event delivered live failures batches 1
                            stopApp handle
                _ -> native
    either (fail . show) pure result
  where
    number text = maybe (fail ("invalid argument " <> text)) pure (readMaybe text)

membership :: Int32 -> ConsumerGroup
#ifdef LEGACY_TOPOLOGY
membership m = ConsumerGroup m 4
#else
membership m = either (error . show) Prelude.id (mkConsumerGroupSize 4 >>= mkConsumerGroup m)
#endif

workloadTarget :: Workload -> SubscriptionTarget
workloadTarget workload = if workload.mode == "category" || workload.mode == "group" then Category (CategoryName "probe") else AllStreams

stream :: Int -> Int -> Int -> Bool -> StreamName
stream writer slot iteration fresh = StreamName ("probe-" <> Text.pack (show writer <> "-" <> show slot <> if fresh then "-" <> show iteration else ""))

append :: KirokuStore -> [(StreamName, ExpectedVersion, [EventData])] -> IO [AppendResult]
append store operations = runStoreIO store (appendMultiStream operations) >>= either (fail . show) pure

measure :: Workload -> KirokuStore -> EventData -> IORef Int -> IORef Int -> IORef Int -> IORef Int -> Int -> IO ()
measure workload store event delivered live failures batches members = do
    when (members > 0) $ await "live entry" (fmap (>= members) (readIORef live))
    -- Warm up the same append shape for two seconds, then fully drain before
    -- measuring. The output contains only the declared measurement interval.
    void $ writers 2
    when (members > 0) $ await "warmup checkpoint drain" durable
    flushStats store
    writeIORef delivered 0
    writeIORef batches 0
    performMajorGC
    stats0 <- getRTSStats
    wal0 <- scalar store "SELECT pg_current_wal_insert_lsn()::text"
    tables0 <- tableStats store
    start <- getMonotonicTimeNSec
    samples <- writers workload.seconds
    finish <- getMonotonicTimeNSec
    let calls = sum [length latencies | (latencies, _) <- samples]
        events = calls * workload.width * workload.appendBatch
        elapsed = secondsBetween start finish
        sorted = sort (concat [latencies | (latencies, _) <- samples])
    when (members > 0) $ do
        await "delivery drain" (fmap (== events) (readIORef delivered))
        await "durable progress drain" durable
    performMajorGC
    stats1 <- getRTSStats
    errors <- readIORef failures
    unless (errors == 0) (fail "database errors during workload")
    flushStats store
    wal1 <- scalar store "SELECT pg_current_wal_insert_lsn()::text"
    walBytes <- scalarInt store ("SELECT pg_wal_lsn_diff('" <> wal1 <> "'::pg_lsn, '" <> wal0 <> "'::pg_lsn)::bigint")
    tables1 <- tableStats store
    count <- readIORef delivered
    batchCount <- readIORef batches
    server <- scalar store "SELECT version()"
    durability <- scalar store "SELECT current_setting('fsync') || ',' || current_setting('synchronous_commit') || ',' || current_setting('full_page_writes')"
    let (saves0, hot0) = tables0
        (saves1, hot1) = tables1
    Bytes.putStrLn $
        encode $
            object
                [ "workload" .= object ["mode" .= workload.mode, "width" .= workload.width, "append_batch" .= workload.appendBatch, "checkpoint_batch" .= workload.checkpointBatch, "fresh" .= workload.fresh, "offered" .= workload.offered, "seconds" .= workload.seconds]
                , "server" .= server
                , "durability" .= durability
                , "calls" .= calls
                , "events" .= events
                , "elapsed" .= elapsed
                , "events_per_second" .= (fromIntegral events / elapsed :: Double)
                , "append_p50_ms" .= percentile sorted 0.50
                , "append_p95_ms" .= percentile sorted 0.95
                , "append_p99_ms" .= percentile sorted 0.99
                , "delivered" .= count
                , "delivery_batches" .= batchCount
                , "durable_drained" .= True
                , "wal_bytes" .= walBytes
                , "checkpoint_updates" .= (saves1 - saves0)
                , "checkpoint_hot_updates" .= (hot1 - hot0)
                , "allocated_bytes" .= (stats1.allocated_bytes - stats0.allocated_bytes)
                , "gc_cpu_ns" .= (stats1.gc_cpu_ns - stats0.gc_cpu_ns)
                , "gc_elapsed_ns" .= (stats1.gc_elapsed_ns - stats0.gc_elapsed_ns)
                , "max_live_bytes" .= stats1.max_live_bytes
                ]
  where
    durable = do
        Right inventory <- runStoreIO store subscriptionCheckpointInventory
        -- Group members have sparse partitions, so their own final event may
        -- precede the global head; verify against the last matching fetch below.
        if workload.mode /= "group"
            then pure (all (\row -> row.checkpointPosition >= inventory.storePosition) (Vector.toList inventory.checkpoints))
            else
                and
                    <$> mapM
                        ( \row -> do
                            n <- runSession store $ Session.statement (let { GlobalPosition p = row.checkpointPosition } in p, row.consumerGroupMember) groupRemaining
                            pure (n == 0)
                        )
                        (Vector.toList inventory.checkpoints)
    writers duration = do
        begin <- getMonotonicTimeNSec
        let end = begin + fromIntegral duration * 1_000_000_000
        Async.mapConcurrently (writer begin end) [0 .. 3]
    writer begin end writerId = loop 0 []
      where
        spacing = if workload.offered == 0 then 0 else 4_000_000_000 `div` fromIntegral workload.offered
        loop i collected = do
            now <- getMonotonicTimeNSec
            let scheduled = if spacing == 0 then now else begin + fromIntegral i * spacing
            if now >= end || scheduled >= end
                then pure (collected, ())
                else do
                    when (scheduled > now) (threadDelay (fromIntegral ((scheduled - now) `div` 1000)))
                    void $ append store [(stream writerId slot (i + fromIntegral begin) workload.fresh, AnyVersion, replicate workload.appendBatch event) | slot <- [0 .. workload.width - 1]]
                    completed <- getMonotonicTimeNSec
                    loop (i + 1) (fromIntegral (completed - scheduled) / 1_000_000 : collected)

secondsBetween :: Word64 -> Word64 -> Double
secondsBetween start finish = fromIntegral (finish - start) / 1_000_000_000

percentile :: [Double] -> Double -> Double
percentile [] _ = 0
percentile values quantile = values !! min (length values - 1) (floor (quantile * fromIntegral (length values - 1)))

await :: String -> IO Bool -> IO ()
await label predicate = timeout 30_000_000 loop >>= maybe (fail (label <> " timed out")) pure
  where
    loop = predicate >>= \ok -> unless ok (threadDelay 1_000 >> loop)

runSession :: KirokuStore -> Session.Session a -> IO a
runSession store session = Pool.use store.pool session >>= either (fail . show) pure

scalar :: KirokuStore -> Text -> IO Text
scalar store sql = runSession store (Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.text)))))

scalarInt :: KirokuStore -> Text -> IO Int64
scalarInt store sql = runSession store (Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))))

tableStats :: KirokuStore -> IO (Int64, Int64)
tableStats store = runSession store $ Session.statement () (preparable "SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE schemaname = 'kiroku' AND relname = 'subscriptions'" E.noParams (D.singleRow ((,) <$> D.column (D.nonNullable D.int8) <*> D.column (D.nonNullable D.int8))))

groupRemaining :: Statement (Int64, Int32) Int64
groupRemaining =
    preparable
        "SELECT count(*) FROM kiroku.stream_events WHERE stream_id = 0 AND category = 'probe' AND stream_version > $1 AND (((hashtextextended(original_stream_id::text, 0) % 4) + 4) % 4) = $2"
        (contrazip2 (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int4)))
        (D.singleRow (D.column (D.nonNullable D.int8)))

-- Flush backend-local table statistics outside the timed interval. Ten
-- concurrent sessions occupy the ten pool slots, including idle writer and
-- checkpoint connections; otherwise an idle backend's warmup updates can leak
-- into the measured HOT-update deltas.
flushStats :: KirokuStore -> IO ()
flushStats store =
    Async.replicateConcurrently_ 10 $
        runSession store $
            Session.script "SELECT pg_stat_force_next_flush(); SELECT pg_sleep(0.2)"
