{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

{- | Small supplementary EP-2 comparison of the changed checkpoint-save path.
No acceptance threshold: local ratios retain their uncertainty. The control
statement and row layout are from 23a03a1b8b56773a140d0683c4c8d4d34b9d7e36.
-}
module Main where

import Contravariant.Extras (contrazip4)
import Control.Lens ((^.))
import Control.Monad (forM_, replicateM_)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import EphemeralPg qualified as Pg
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Postgres (ephemeralConfig, migrateTestDatabase)

main :: IO ()
main = do
    original <- ephemeralConfig
    let keys = ["fsync", "synchronous_commit", "full_page_writes", "shared_buffers", "wal_level"]
        durable = original{Pg.postgresSettings = filter (\(key, _) -> key `notElem` keys) original.postgresSettings <> [("fsync", "on"), ("synchronous_commit", "on"), ("full_page_writes", "on"), ("shared_buffers", "128MB"), ("wal_level", "replica")]}
    result <- Pg.withCachedConfig durable Pg.defaultCacheConfig $ \database -> do
        let connection = Pg.connectionString database
        migrateTestDatabase connection
        withStore (defaultConnectionSettings connection) measure
    either (fail . show) pure result

measure :: KirokuStore -> IO ()
measure store = do
    settings <- use store $ Session.statement () (preparable "SELECT current_setting('server_version_num')::int4 >= 180000 AND current_setting('server_version_num')::int4 < 190000 AND current_setting('fsync') = 'on' AND current_setting('synchronous_commit') = 'on' AND current_setting('full_page_writes') = 'on'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))
    if settings then pure () else fail "requires durable PostgreSQL 18"
    use store $
        Session.script
            """
            CREATE SCHEMA ep2_control;
            CREATE TABLE ep2_control.subscriptions (
              subscription_id BIGSERIAL PRIMARY KEY,
              subscription_name TEXT NOT NULL,
              stream_name TEXT NOT NULL DEFAULT '$all',
              last_seen BIGINT NOT NULL DEFAULT 0,
              consumer_group_member INT NOT NULL DEFAULT 0,
              consumer_group_size INT NOT NULL DEFAULT 1,
              created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
              updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE UNIQUE INDEX ON ep2_control.subscriptions (subscription_name, consumer_group_member);
            """
    controlCounter <- newIORef 0
    candidateCounter <- newIORef 0
    let save candidate = do
            p <- atomicModifyIORef' (if candidate then candidateCounter else controlCounter) (\n -> (n + 1, n + 1))
            let m = fromIntegral (p `mod` 4)
            if candidate
                then use store $ Session.statement ("target-cost", m, p, 4, "category", Just "performance") SQL.saveCheckpointMemberStmt
                else use store $ Session.statement ("target-cost", m, p, 4) controlSave
        trial pair candidate = do
            walBefore <- use store (Session.statement () walPosition)
            start <- getMonotonicTimeNSec
            replicateM_ 2000 (save candidate)
            end <- getMonotonicTimeNSec
            walAfter <- use store (Session.statement () walPosition)
            putStrLn $ show pair <> "," <> (if candidate then "candidate" else "control") <> ",2000," <> show (fromIntegral (end - start) / 2000 :: Double) <> "," <> show (fromIntegral (walAfter - walBefore) / 2000 :: Double)
    replicateM_ 200 (save False >> save True)
    putStrLn "pair,arm,saves,ns_per_save,wal_bytes_per_save"
    forM_ [1 .. 3 :: Int] $ \pair ->
        if odd pair
            then trial pair False >> trial pair True
            else trial pair True >> trial pair False
    -- Every completed save advances one durable member; both arms do equal work.
    expected <- use store $ Session.statement () (preparable "SELECT count(*) = 4 AND sum(last_seen) = 24794 FROM ep2_control.subscriptions" E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))
    actual <- use store $ Session.statement () (preparable "SELECT count(*) = 4 AND sum(last_seen) = 24794 AND bool_and(target_kind = 'category' AND target_category = 'performance') FROM kiroku.subscriptions WHERE subscription_name = 'target-cost'" E.noParams (D.singleRow (D.column (D.nonNullable D.bool))))
    if expected && actual then putStrLn "durable equal-work checks: passed" else fail "durable equal-work checks failed"

use :: KirokuStore -> Session.Session a -> IO a
use store session = Pool.use (store ^. #pool) session >>= either (fail . show) pure

walPosition :: Statement () Int64
walPosition = preparable "SELECT (pg_current_wal_insert_lsn() - '0/0'::pg_lsn)::bigint" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))

controlSave :: Statement (Text, Int32, Int64, Int32) ()
controlSave =
    preparable
        """
        INSERT INTO ep2_control.subscriptions (subscription_name, consumer_group_member, last_seen, updated_at, consumer_group_size)
        VALUES ($1, $2, $3, now(), $4)
        ON CONFLICT (subscription_name, consumer_group_member)
        DO UPDATE SET last_seen = GREATEST(subscriptions.last_seen, EXCLUDED.last_seen), updated_at = now(), consumer_group_size = EXCLUDED.consumer_group_size
        """
        (contrazip4 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.int4)) (E.param (E.nonNullable E.int8)) (E.param (E.nonNullable E.int4)))
        D.noResult
