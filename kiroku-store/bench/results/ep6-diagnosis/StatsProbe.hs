{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_, replicateM_, unless)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as B
import Data.Int (Int32, Int64)
import Data.List (nub)
import Data.Text (Text)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement (preparable)
import Kiroku.Store
import Kiroku.Test.Postgres

main :: IO ()
main = withMigratedTestDatabase $ \conn -> withStore ((defaultConnectionSettings conn){poolSize = 10}) $ \store -> do
    let run :: S.Session a -> IO a
        run s = Pool.use store.pool s >>= either (fail . show) pure
        count = run $ S.statement () $ preparable "SELECT n_tup_upd FROM pg_stat_user_tables WHERE schemaname='public' AND relname='mp12_stats_probe'" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))
        flush delay = Async.replicateConcurrently 10 $ run $ do
            pid <- S.statement () $ preparable "SELECT pg_backend_pid()" E.noParams (D.singleRow (D.column (D.nonNullable D.int4)))
            S.script ("SELECT pg_stat_force_next_flush(); SELECT pg_sleep(" <> delay <> ")")
            pure (pid :: Int32)
    run $ S.script "CREATE TABLE public.mp12_stats_probe (id int primary key, value int); INSERT INTO public.mp12_stats_probe SELECT x,0 FROM generate_series(1,4) x"
    forM_ [1 .. 3 :: Int] $ \trial -> do
        _ <- flush "1.1"
        before <- count
        Async.mapConcurrently_ (\writer -> replicateM_ 300 $ run $ S.statement writer $ preparable "UPDATE public.mp12_stats_probe SET value=value+1 WHERE id=$1" (E.param (E.nonNullable E.int4)) D.noResult) [1 .. 4 :: Int32]
        pids <- flush "0.2"
        immediate <- count
        threadDelay 1_100_000
        settled <- count
        pidsAfter <- flush "1.1"
        final <- count
        B.putStrLn $ encode $ object ["trial" .= trial, "expected_updates" .= (1200 :: Int), "before" .= (before :: Int64), "old_flush_delta" .= (immediate - before), "after_idle_delta" .= (settled - before), "long_flush_delta" .= (final - before), "old_unique_backends" .= length (nub pids), "new_unique_backends" .= length (nub pidsAfter)]
        unless (final - before == 1200) $ fail "even settled statistics disagree"
