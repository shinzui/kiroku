{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_, replicateM_, unless, void)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as B
import Data.IORef
import Data.Int (Int32, Int64)
import Data.List (nub)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement (preparable)
import Kiroku.Store
import Kiroku.Test.Postgres
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Adapter.Kiroku qualified as Adapter
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

main :: IO ()
main = withMigratedTestDatabase $ \conn -> do
    live <- newIORef False
    batches <- newIORef (0 :: Int)
    let observe KirokuEventSubscriptionCaughtUp{} = writeIORef live True
        observe KirokuEventSubscriptionDelivered{} = atomicModifyIORef' batches (\n -> (n + 1, ()))
        observe _ = pure ()
    withStore ((defaultConnectionSettings conn){poolSize = 10, eventHandler = Just observe}) $ \store -> do
        let run :: S.Session a -> IO a
            run s = Pool.use store.pool s >>= either (fail . show) pure
            count = run $ S.statement () $ preparable "SELECT n_tup_upd FROM pg_stat_user_tables WHERE schemaname='kiroku' AND relname='subscriptions'" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))
            flush delay = Async.replicateConcurrently 10 $ run $ do
                pid <- S.statement () $ preparable "SELECT pg_backend_pid()" E.noParams (D.singleRow (D.column (D.nonNullable D.int4)))
                S.script ("SELECT pg_stat_force_next_flush(); SELECT pg_sleep(" <> delay <> ")")
                pure (pid :: Int32)
            waitFor label predicate = timeout 30_000_000 (let loop = predicate >>= \ok -> unless ok (threadDelay 1000 >> loop) in loop) >>= maybe (fail label) pure
            durable = do
                Right inventory <- runStoreIO store subscriptionCheckpointInventory
                pure $ V.length inventory.checkpoints == 1 && all (\row -> row.checkpointPosition >= inventory.storePosition) (V.toList inventory.checkpoints)
            event = EventData Nothing (EventType "Probe") (object ["body" .= Text.replicate 512 "x"]) Nothing Nothing Nothing
            writes = Async.mapConcurrently_ (\writer -> replicateM_ 250 $ runStoreIO store (appendMultiStream [(StreamName ("probe-" <> Text.pack (show writer)), AnyVersion, [event])]) >>= either (fail . show) (const $ pure ())) [0 .. 3 :: Int]
        forM_ [0 .. 3 :: Int] $ \writer -> void $ runStoreIO store $ appendMultiStream [(StreamName ("probe-" <> Text.pack (show writer)), AnyVersion, [event])]
        delivered <- newIORef (0 :: Int)
        runEff $ runTracingNoop $ do
            adapter <- kirokuAdapter store $ (defaultKirokuAdapterConfig (SubscriptionName "probe") AllStreams){Adapter.missingCheckpointPolicy = FromCurrentHead, Adapter.batchSize = either (error . show) Prelude.id (mkBatchSize 1)}
            app <- runApp defaultAppConfig [(ProcessorId "probe", mkProcessor adapter (\_ -> liftIO (atomicModifyIORef' delivered (\n -> (n + 1, ()))) >> pure AckOk))]
            case app of
                Left err -> liftIO $ fail (show err)
                Right handle -> do
                    liftIO $ do
                        waitFor "live" (readIORef live)
                        forM_ [1 .. 6 :: Int] $ \trial -> do
                            waitFor "durable start" durable
                            pids0 <- flush "0.2"
                            before <- count
                            writeIORef delivered 0
                            writeIORef batches 0
                            writes
                            waitFor "delivered" ((== 1000) <$> readIORef delivered)
                            waitFor "durable finish" durable
                            pids <- flush "0.2"
                            immediate <- count
                            threadDelay 1_100_000
                            settled <- count
                            _ <- flush "1.1"
                            final <- count
                            batchCount <- readIORef batches
                            B.putStrLn $ encode $ object ["delivery_batches" .= batchCount, "trial" .= trial, "expected_updates" .= (1000 :: Int), "before" .= (before :: Int64), "old_flush_delta" .= (immediate - before), "after_idle_delta" .= (settled - before), "long_flush_delta" .= (final - before), "start_unique_backends" .= length (nub pids0), "end_unique_backends" .= length (nub pids)]
                    stopApp handle
