{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import EphemeralPg qualified as Pg
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Kiroku.Store
import Test.Tasty.Bench

-- | Force evaluation of an append result or fail the benchmark.
forceResult :: Either AppendError AppendResult -> IO ()
forceResult (Right r) = r.streamVersion `seq` r.globalPosition `seq` pure ()
forceResult (Left e) = error ("Benchmark append failed: " <> show e)

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

        defaultMain
            [ bgroup
                "append"
                [ bgroup
                    "single-event"
                    [ bench "NoStream (new stream)" $ whnfIO $ do
                        sn <- nextStream "bench-single"
                        r <- appendToStream store sn NoStream [makeEvent "BenchEvent"]
                        forceResult r
                    , bench "AnyVersion (new stream)" $ whnfIO $ do
                        sn <- nextStream "bench-any"
                        r <- appendToStream store sn AnyVersion [makeEvent "BenchEvent"]
                        forceResult r
                    ]
                , bgroup
                    "batch-10"
                    [ bench "NoStream" $ whnfIO $ do
                        sn <- nextStream "bench-b10"
                        let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 10 :: Int]
                        r <- appendToStream store sn NoStream events
                        forceResult r
                    ]
                , bgroup
                    "batch-100"
                    [ bench "NoStream" $ whnfIO $ do
                        sn <- nextStream "bench-b100"
                        let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                        r <- appendToStream store sn NoStream events
                        forceResult r
                    ]
                , bgroup
                    "sequential"
                    [ bench "10 appends to same stream" $ whnfIO $ do
                        sn <- nextStream "bench-seq"
                        r0 <- appendToStream store sn NoStream [makeEvent "Init"]
                        forceResult r0
                        let Right res0 = r0
                        let go _ 0 = pure ()
                            go v n = do
                                r <- appendToStream store sn (ExactVersion v) [makeEvent "Seq"]
                                case r of
                                    Right res -> go res.streamVersion (n - 1 :: Int)
                                    Left e -> error ("Sequential append failed: " <> show e)
                        go res0.streamVersion 9
                    ]
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
