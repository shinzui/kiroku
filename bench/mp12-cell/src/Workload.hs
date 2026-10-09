{-# LANGUAGE CPP #-}

-- Controlled hardening workload; production APIs are the only varying code.
-- mori://shinzui/keiro-runtime-kenshou/packages/kenshou-measure
module Workload (bundle) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Json
import Data.IORef
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store hiding (id)
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Adapter.Kiroku qualified as Adapter
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Mem (performMajorGC)
import System.Timeout (timeout)

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (Layer (..))
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario
import Kenshou.Measure.Load.Series qualified as LoadSeries
import Kenshou.Measure.Phase qualified as Phase
import Kenshou.Measure.Recorder qualified as Recorder
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session qualified as Measure
import Kenshou.Suite.Kiroku.Bench.Hardening qualified as Hardening

data Workload = Workload
    { seconds :: !Int
    , mode :: !String
    , width :: !Int
    , appendBatch :: !Int
    , checkpointBatch :: !Int32
    , fresh :: !Bool
    , offered :: !Int
    , warmupSeconds :: !Int
    , maxBacklog :: !Int
    }

bundle :: LayerBundle
bundle = LayerBundle Kiroku [scenario] []

scenario :: Scenario
scenario = Hardening.scenario{run = runWorkload}

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runWorkload :: Core.RunContext -> IO ScenarioReport
runWorkload context = do
    let integer :: (Integral n) => Text -> n
        integer key = fromIntegral (knobInt context.knobs (knobName key))
        workload =
            Workload
                (floor context.phases.steadySeconds)
                (Text.unpack (knobText context.knobs (knobName "mp12.mode")))
                (integer "mp12.width")
                (integer "mp12.append-batch")
                (integer "mp12.checkpoint-batch")
                (knobBool context.knobs (knobName "mp12.fresh"))
                (integer "mp12.offered")
                (floor context.phases.warmUpSeconds)
                (integer "mp12.max-backlog")
    unless (workload.seconds >= 60 && workload.warmupSeconds >= 2) (fail "benchmark requires >=60s steady and >=2s warmup")
    live <- newIORef (0 :: Int)
    failures <- newIORef (0 :: Int)
    batches <- newIORef (0 :: Int)
    let observe = \case
            KirokuEventSubscriptionCaughtUp{} -> atomicModifyIORef' live (\n -> (n + 1, ()))
            KirokuEventSubscriptionDbError{} -> atomicModifyIORef' failures (\n -> (n + 1, ()))
            KirokuEventSubscriptionDelivered{} -> atomicModifyIORef' batches (\n -> (n + 1, ()))
            _ -> pure ()
        settings = (defaultConnectionSettings ((Core.requirePostgres context).connectionString)){poolSize = 10, eventHandler = Just observe}
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
                    , consumerGroup = if workload.mode `elem` ["group-all", "group-category"] then Just (membership m) else Nothing
                    }
            members = if workload.mode `elem` ["group-all", "group-category"] then [0, 1, 2, 3] else [0]
            native = bracket (mapM (subscribe store . config) members) (mapM_ cancel) $ \_ -> measure context workload store event delivered live failures batches (length members)
        case workload.mode of
            "none" -> measure context workload store event delivered live failures batches 0
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
                        report <- liftIO $ measure context workload store event delivered live failures batches 1
                        stopApp handle
                        pure report
            _ -> native

membership :: Int32 -> ConsumerGroup
#ifdef LEGACY_TOPOLOGY
membership m = ConsumerGroup m 4
#else
membership m = either (error . show) Prelude.id (mkConsumerGroupSize 4 >>= mkConsumerGroup m)
#endif

workloadTarget :: Workload -> SubscriptionTarget
workloadTarget workload = if workload.mode `elem` ["category", "group-category"] then Category (CategoryName "probe") else AllStreams

stream :: Int -> Int -> Int -> Bool -> StreamName
stream writer slot iteration fresh = StreamName ("probe-" <> Text.pack (show writer <> "-" <> show slot <> if fresh then "-" <> show iteration else ""))

append :: KirokuStore -> [(StreamName, ExpectedVersion, [EventData])] -> IO [AppendResult]
append store operations = runStoreIO store (appendMultiStream operations) >>= either (fail . show) pure

measure :: Core.RunContext -> Workload -> KirokuStore -> EventData -> IORef Int -> IORef Int -> IORef Int -> IORef Int -> Int -> IO ScenarioReport
measure context workload store event delivered live failures batches members = do
    appended <- newIORef (0 :: Int)
    backlog <- newIORef []
    when (members > 0) $ await "live entry" (fmap (>= members) (readIORef live))
    config0 <- either (fail . Text.unpack) pure (Measure.measureConfigFromKnobs context (Measure.phasePlanFromCore context.phases))
    let config = (config0{Measure.postgres = fmap (\pg -> (pg{relations = ["kiroku.subscriptions", "kiroku.stream_events"]} :: PgSamplerConfig)) config0.postgres} :: Measure.MeasureConfig)
    ((_result, _), report) <- Measure.withMeasurement context config $ \measurement -> do
        bracket (LoadSeries.openLoadSeries measurement) LoadSeries.closeLoadSeries $ \series -> do
            offeredCalls <- newIORef 0
            startedCalls <- newIORef 0
            completedCalls <- newIORef 0
            failedCalls <- newIORef 0
            maxLag <- newIORef 0
            let sample = LoadSeries.sampleLoadSeries series measurement offeredCalls startedCalls completedCalls failedCalls maxLag
                clock = Measure.measurementPhaseClock measurement
            handle <- Recorder.registerOp (Measure.measurementRecorder measurement) (Recorder.OpName "append")
            recorders <- mapM (Recorder.newWorkerRecorder handle) [0 .. 3]
            Async.withAsync (sampleBacklog appended delivered backlog sample (if members == 0 then pure Nothing else Just <$> scalarInt store pendingSQL)) $ \sampler -> do
                Async.link sampler
                Phase.enterPhase clock Phase.WarmUp
                sample
                void $ Core.withPhase context CorePhase.WarmUp (writers appended (offeredCalls, startedCalls, completedCalls, maxLag) recorders workload.warmupSeconds)
                when (members > 0) $ await "warmup checkpoint drain" durable
                flushStats store
                writeIORef appended 0
                writeIORef backlog []
                writeIORef delivered 0
                writeIORef batches 0
                performMajorGC
                sql0 <- checkpointStatementStats store
                stats0 <- getRTSStats
                wal0 <- scalar store "SELECT pg_current_wal_insert_lsn()::text"
                tables0 <- tableStats store
                start <- getMonotonicTimeNSec
                Phase.enterPhase clock Phase.Steady
                sample
                samples <- Core.withPhase context CorePhase.Steady $ do
                    result <- writers appended (offeredCalls, startedCalls, completedCalls, maxLag) recorders workload.seconds
                    -- Capacity includes the outstanding durable work in its
                    -- elapsed time. Fixed-load latency retains its arrival window.
                    when (workload.offered == 0 && members > 0) $ await "capacity durable drain" durable
                    pure result
                Phase.enterPhase clock Phase.Drain
                sample
                finish <- getMonotonicTimeNSec
                let calls = sum [length latencies | (latencies, _) <- samples]
                    events = calls * workload.width * workload.appendBatch
                    elapsed = secondsBetween start finish
                    sorted = sort (concat [latencies | (latencies, _) <- samples])
                Core.withPhase context CorePhase.Drain $ when (members > 0) $ do
                    await "delivery drain" (fmap (== events) (readIORef delivered))
                    await "durable progress drain" durable
                performMajorGC
                stats1 <- getRTSStats
                sql1 <- checkpointStatementStats store
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
                unless (durability == "on,on,on") (fail "cell PostgreSQL durability is disabled")
                backlogRows <- readIORef backlog
                unless (length backlogRows >= workload.seconds * 5) (fail "handler backlog sampling is incomplete")
                when (members > 0) $ unless (length [() | (_, _, _, Just _) <- backlogRows] >= workload.seconds `div` 2) (fail "durable backlog sampling is incomplete")
                let peak = if members == 0 then 0 else maximum (0 : [max 0 (issued - handled) | (_, issued, handled, _) <- backlogRows])
                    peakDurable = maximum (0 : [pending | (_, _, _, Just pending) <- backlogRows])
                unless (peak <= workload.maxBacklog && peakDurable <= fromIntegral workload.maxBacklog) (fail "subscriber backlog exceeded the predeclared limit")
                unless (workload.offered == 0 || calls == workload.offered * workload.seconds) (fail "fixed-load schedule did not complete every declared arrival")
                Core.putSummary context Core.Measurements "backlog" (object ["peakHandlerPending" .= peak, "peakDurablePending" .= peakDurable, "limit" .= workload.maxBacklog, "samples" .= reverse backlogRows])
                let (saves0, hot0) = tables0
                    (saves1, hot1) = tables1
                when (members > 0) $ do
                    let updates = saves1 - saves0
                        minimumUpdates = (fromIntegral events + fromIntegral workload.checkpointBatch - 1) `div` fromIntegral workload.checkpointBatch
                    unless (updates >= minimumUpdates && updates <= fromIntegral events) (fail "checkpoint frequency differs from the declared batch policy")
                Core.putSummary context Core.Measurements "write-probe" $
                    object
                        [ "workload" .= object ["mode" .= workload.mode, "width" .= workload.width, "append_batch" .= workload.appendBatch, "checkpoint_batch" .= workload.checkpointBatch, "fresh" .= workload.fresh, "offered" .= workload.offered, "seconds" .= workload.seconds, "warmup_seconds" .= workload.warmupSeconds]
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
                        , "checkpoint_sql_before" .= sql0
                        , "checkpoint_sql_after" .= sql1
                        , "checkpoint_updates" .= (saves1 - saves0)
                        , "checkpoint_hot_updates" .= (hot1 - hot0)
                        , "allocated_bytes" .= (stats1.allocated_bytes - stats0.allocated_bytes)
                        , "gc_cpu_ns" .= (stats1.gc_cpu_ns - stats0.gc_cpu_ns)
                        , "gc_elapsed_ns" .= (stats1.gc_elapsed_ns - stats0.gc_elapsed_ns)
                        , "max_live_bytes" .= stats1.max_live_bytes
                        ]
                pure ((), ())
    pure (passed{outcome = Measure.measuredOutcome report passed.outcome})
  where
    pendingSQL = "SELECT count(*) FROM kiroku.stream_events se JOIN kiroku.subscriptions s ON s.subscription_name='probe' WHERE se.stream_id=0 AND se.stream_version>s.last_seen" <> if workload.mode `elem` ["group-all", "group-category"] then " AND (((hashtextextended(se.original_stream_id::text,0)%4)+4)%4)=s.consumer_group_member" else ""
    durable = do
        Right inventory <- runStoreIO store subscriptionCheckpointInventory
        unless (Vector.length inventory.checkpoints == members) (fail "durable checkpoint row count does not match the declared subscribers")
        -- Group members have sparse partitions, so their own final event may
        -- precede the global head; verify against the last matching fetch below.
        if workload.mode `notElem` ["group-all", "group-category"]
            then pure (all (\row -> row.checkpointPosition >= inventory.storePosition) (Vector.toList inventory.checkpoints))
            else
                and
                    <$> mapM
                        ( \row -> do
                            n <- runSession store $ Session.statement (let { GlobalPosition p = row.checkpointPosition } in p, row.consumerGroupMember) groupRemaining
                            pure (n == 0)
                        )
                        (Vector.toList inventory.checkpoints)
    writers appended counters recorders duration = do
        begin <- getMonotonicTimeNSec
        let end = begin + fromIntegral duration * 1_000_000_000
        Async.mapConcurrently (writer appended counters recorders begin end) [0 .. 3]
    writer appended (offeredCalls, startedCalls, completedCalls, maxLag) recorders begin end writerId = loop 0 []
      where
        capacityWait = do
            issued <- readIORef appended
            handled <- readIORef delivered
            now <- getMonotonicTimeNSec
            let limit = min (workload.maxBacklog `div` 2) (max (workload.width * workload.appendBatch) (fromIntegral workload.checkpointBatch * members * 2))
            when (issued - handled >= max 1 limit && now < end) $ threadDelay 200 >> capacityWait
        loop i collected = do
            when (workload.offered == 0 && members > 0) $ capacityWait
            now <- getMonotonicTimeNSec
            let scheduled = if workload.offered == 0 then now else begin + (fromIntegral (4 * i + writerId) * 1_000_000_000) `div` fromIntegral workload.offered
            if now >= end || scheduled >= end
                then pure (collected, ())
                else do
                    when (scheduled > now) (threadDelay (fromIntegral ((scheduled - now) `div` 1000)))
                    atomicModifyIORef' offeredCalls (\n -> (n + 1, ()))
                    actual <- getMonotonicTimeNSec
                    atomicModifyIORef' startedCalls (\n -> (n + 1, ()))
                    atomicModifyIORef' maxLag (\n -> (max n (actual - scheduled), ()))
                    void $ append store [(stream writerId slot (i + fromIntegral begin) workload.fresh, AnyVersion, replicate workload.appendBatch event) | slot <- [0 .. workload.width - 1]]
                    completed <- getMonotonicTimeNSec
                    atomicModifyIORef' completedCalls (\n -> (n + 1, ()))
                    atomicModifyIORef' appended (\n -> (n + workload.width * workload.appendBatch, ()))
                    Recorder.recordOp (recorders !! writerId) scheduled actual completed (Recorder.OpOk (workload.width * workload.appendBatch))
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

-- Same SQL snapshots in both arms; query text maps changing query IDs back to
-- checkpoint statements. Deltas expose execution time and WAL per save.
checkpointStatementStats :: KirokuStore -> IO Json.Value
checkpointStatementStats store =
    runSession store $
        Session.statement () $
            preparable
                "SELECT COALESCE(jsonb_agg(jsonb_build_object('queryid', queryid::text, 'query', query, 'calls', calls, 'exec_ms', total_exec_time, 'wal_bytes', wal_bytes)), '[]'::jsonb) FROM public.pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND query ILIKE '%INSERT INTO subscriptions%'"
                E.noParams
                (D.singleRow (D.column (D.nonNullable D.jsonb)))

-- Handler progress at 10 Hz and durable pending work at 1 Hz. The
-- durable query uses the declared hash topology, including the old control
-- whose stored size column was never maintained.
sampleBacklog :: IORef Int -> IORef Int -> IORef [(Word64, Int, Int, Maybe Int64)] -> IO () -> IO (Maybe Int64) -> IO ()
sampleBacklog appended delivered rows sample durablePending = loop (0 :: Int)
  where
    loop iteration = do
        pending <- if iteration `mod` 10 == 0 then durablePending else pure Nothing
        now <- getMonotonicTimeNSec
        issued <- readIORef appended
        handled <- readIORef delivered
        atomicModifyIORef' rows (\values -> ((now, issued, handled, pending) : values, ()))
        sample
        threadDelay 100_000
        loop (iteration + 1)
