module Main where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import EphemeralPg qualified as Pg
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Kiroku.Store
import Test.Tasty.Bench

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
        let poolConfig =
                Pool.Config.settings
                    [ Pool.Config.staticConnectionSettings (Pg.connectionSettings db)
                    , Pool.Config.size 10
                    ]
        pool <- Pool.acquire poolConfig
        initializeSchema pool "public"
        let store = KirokuStore{pool = pool, schema = "public"}

        -- Counter for unique stream names across benchmarks
        counter <- newIORef (0 :: Int)
        let nextStream :: Text -> IO StreamName
            nextStream prefix = do
                n <- atomicModifyIORef' counter (\n -> (n + 1, n))
                pure (StreamName (prefix <> "-" <> T.pack (show n)))

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
            ]

        Pool.release pool
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
