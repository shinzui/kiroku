module Main where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Vector qualified as V
import EphemeralPg qualified as Pg
import Kiroku.Store
import Test.Tasty.Bench

{- | Run @writers@ concurrent appenders, each performing @ops@ appends to
its own unique stream. Used by the structured concurrent-writer
benchmarks (EP-6 F19); replaces the wall-clock @mapConcurrently_@
measurement that previously lived inline in @main@.

The @runCounter@ ref is bumped once per call so stream names are unique
across the many iterations tasty-bench runs.
-}
runConcurrentWriters :: KirokuStore -> IORef Int -> Int -> Int -> IO ()
runConcurrentWriters store runCounter writers ops = do
    runId <- atomicModifyIORef' runCounter (\m -> (m + 1, m))
    mapConcurrently_
        (\tid -> mapM_ (appendOne tid runId) [1 .. ops])
        [1 .. writers]
  where
    appendOne :: Int -> Int -> Int -> IO ()
    appendOne tid runId i = do
        let sn = StreamName ("conc-" <> T.pack (show runId) <> "-" <> T.pack (show tid) <> "-" <> T.pack (show i))
        r <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "ConcEvent"]
        forceAppend r

-- | Force evaluation of an append result or fail the benchmark.
forceAppend :: Either StoreError AppendResult -> IO ()
forceAppend (Right r) = (r ^. #streamVersion) `seq` (r ^. #globalPosition) `seq` pure ()
forceAppend (Left e) = error ("Benchmark append failed: " <> show e)

-- | Force evaluation of a read result or fail the benchmark.
forceRead :: Either StoreError (V.Vector RecordedEvent) -> IO ()
forceRead (Right v) = V.length v `seq` pure ()
forceRead (Left e) = error ("Benchmark read failed: " <> show e)

main :: IO ()
main = do
    -- Start ephemeral PostgreSQL once for all benchmarks
    result <- Pg.withCached $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings $ \store -> do
            -- Counter for unique stream names across benchmarks
            counter <- newIORef (0 :: Int)
            let nextStream :: Text -> IO StreamName
                nextStream prefix = do
                    n <- atomicModifyIORef' counter (\n -> (n + 1, n))
                    pure (StreamName (prefix <> "-" <> T.pack (show n)))

            -- Pre-populate streams for category benchmarks (B10)
            -- 100 categories × 10 streams × 100 events = 100K events
            putStrLn "\n--- Pre-populating category data (100 cats × 10 streams × 100 events) ---"
            catT0 <- getCurrentTime
            mapM_
                ( \cat -> do
                    mapM_
                        ( \s -> do
                            let sn = StreamName ("cat" <> T.pack (show cat) <> "-" <> T.pack (show s))
                            let evts = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream evts
                            forceAppend r'
                        )
                        [1 .. 10 :: Int]
                )
                [1 .. 100 :: Int]
            catT1 <- getCurrentTime
            let catElapsed = realToFrac (diffUTCTime catT1 catT0) :: Double
            putStrLn $ "  Setup time: " <> show catElapsed <> "s (100K events)"

            -- Pre-populate streams for read benchmarks
            -- B4: Single stream with 1000 events
            let readStreamName = StreamName "bench-read-stream"
            let readEvents = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 1000 :: Int]
            r <- runStoreIO store $ appendToStream readStreamName NoStream readEvents
            forceAppend r

            -- B5: 10 streams with 100 events each for $all reads (1000 total)
            mapM_
                ( \s -> do
                    let sn = StreamName ("bench-all-" <> T.pack (show s))
                    let evts = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                    r' <- runStoreIO store $ appendToStream sn NoStream evts
                    forceAppend r'
                )
                [1 .. 10 :: Int]

            -- B9: Pool saturation benchmark (64 concurrent writers, 100 appends each)
            putStrLn "\n--- B9: Pool saturation (64 writers × 100 appends, pool size 10) ---"
            satCounter <- newIORef (0 :: Int)
            let nextSatStream :: Int -> Int -> StreamName
                nextSatStream tid i = StreamName ("sat-" <> T.pack (show tid) <> "-" <> T.pack (show i))
            t0 <- getCurrentTime
            mapConcurrently_
                ( \tid -> do
                    mapM_
                        ( \i -> do
                            let sn = nextSatStream tid i
                            r' <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "SatEvent"]
                            forceAppend r'
                            atomicModifyIORef' satCounter (\n -> (n + 1, ()))
                        )
                        [1 .. 100 :: Int]
                )
                [1 .. 64 :: Int]
            t1 <- getCurrentTime
            totalOps <- readIORef satCounter
            let elapsed = realToFrac (diffUTCTime t1 t0) :: Double
            let throughput = fromIntegral totalOps / elapsed
            let avgLatency = elapsed / fromIntegral totalOps * 1000 -- ms
            putStrLn $ "  Total appends: " <> show totalOps
            putStrLn $ "  Elapsed: " <> show elapsed <> "s"
            putStrLn $ "  Throughput: " <> show (round throughput :: Int) <> " ops/s"
            putStrLn $ "  Avg latency: " <> show avgLatency <> " ms"
            putStrLn "---"

            -- Counter shared by the concurrent-writer benchmarks so each
            -- iteration uses a fresh stream-name run-id.
            concCounter <- newIORef (0 :: Int)

            defaultMain
                [ bgroup
                    "append"
                    [ bgroup
                        "single-event"
                        [ bench "NoStream (new stream)" $ whnfIO $ do
                            sn <- nextStream "bench-single"
                            r' <- runStoreIO store $ appendToStream sn NoStream [makeEvent "BenchEvent"]
                            forceAppend r'
                        , bench "AnyVersion (new stream)" $ whnfIO $ do
                            sn <- nextStream "bench-any"
                            r' <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "BenchEvent"]
                            forceAppend r'
                        ]
                    , bgroup
                        "batch-10"
                        [ bench "NoStream" $ whnfIO $ do
                            sn <- nextStream "bench-b10"
                            let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 10 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream events
                            forceAppend r'
                        ]
                    , bgroup
                        "batch-100"
                        [ bench "NoStream" $ whnfIO $ do
                            sn <- nextStream "bench-b100"
                            let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream events
                            forceAppend r'
                        ]
                    , bgroup
                        "sequential"
                        [ bench "10 appends to same stream" $ whnfIO $ do
                            sn <- nextStream "bench-seq"
                            r0 <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Init"]
                            forceAppend r0
                            let Right res0 = r0
                            let go _ 0 = pure ()
                                go v n = do
                                    r' <- runStoreIO store $ appendToStream sn (ExactVersion v) [makeEvent "Seq"]
                                    case r' of
                                        Right res -> go (res ^. #streamVersion) (n - 1 :: Int)
                                        Left e -> error ("Sequential append failed: " <> show e)
                            go (res0 ^. #streamVersion) 9
                        ]
                    ]
                , bgroup
                    "read"
                    [ bench "stream forward (100-event page)" $ whnfIO $ do
                        r' <- runStoreIO store $ readStreamForward readStreamName (StreamVersion 0) 100
                        forceRead r'
                    , bench "$all forward (100-event page)" $ whnfIO $ do
                        r' <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                        forceRead r'
                    ]
                , bgroup
                    "category"
                    [ bench "category forward (100-event page)" $ whnfIO $ do
                        -- Read from cat1 category (has 10 streams × 100 events = 1000 events)
                        r' <- runStoreIO store $ readCategory (CategoryName "cat1") (GlobalPosition 0) 100
                        forceRead r'
                    , bench "$all forward (100-event page, baseline)" $ whnfIO $ do
                        r' <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                        forceRead r'
                    ]
                , -- F19 — Concurrent-writer stress as structured benchmarks.
                  -- The legacy ad-hoc B9 measurement (still present above
                  -- for historical comparability) prints throughput and
                  -- latency once; these bgroup entries surface the same
                  -- workload through tasty-bench so it participates in the
                  -- baseline-regression workflow (Justfile bench-regression).
                  bgroup
                    "concurrent"
                    [ bench "8 writers x 10 appends" $ whnfIO $ runConcurrentWriters store concCounter 8 10
                    , bench "32 writers x 10 appends" $ whnfIO $ runConcurrentWriters store concCounter 32 10
                    ]
                ]
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()

makeEvent :: Text -> EventData
makeEvent typ =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = Aeson.object [("benchmark", Aeson.Bool True)]
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }
