{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.Monoid (Last (..))
import Database.PostgreSQL.Migrate (defaultRunOptions, runMigrationPlan)
import EphemeralPg qualified as Pg
import Hasql.Connection.Settings qualified as Conn
import Hasql.Transaction qualified as Tx
import Kiroku.Metrics.JSON (storeErrorResponse)
import Kiroku.Store
import Kiroku.Store.Migrations (kirokuMigrationPlan)
import Network.HTTP.Types (status500, status503)
import Network.Wai (responseStatus)
import System.Directory (createDirectoryIfMissing)
import System.Timeout (timeout)

main :: IO ()
main = do
    let root = "/tmp/kiroku-ep98-published-consumer"
    createDirectoryIfMissing True root
    outcome <- timeout 60_000_000 $ Pg.withConfig (Pg.defaultConfig{Pg.temporaryRoot = Last (Just root)}) $ \db -> do
        plan <- either (fail . show) pure kirokuMigrationPlan
        migrated <- runMigrationPlan defaultRunOptions (Conn.connectionString (Pg.connectionString db)) plan
        either (fail . show) (const (pure ())) migrated
        withStore (defaultConnectionSettings (Pg.connectionString db)) $ \store -> do
            let script = Tx.sql "INSERT INTO public.kiroku_script_missing_relation VALUES (1)"
            runStoreIO store (runTransaction script) >>= assertMissing
            runStoreIO store (runTransactionNoRetry script) >>= assertMissing
            forM_ [ConnectionLost "private connection", PoolAcquisitionTimeout, TransientTransactionFailure "40001" "private message", TransientTransactionFailure "40P01" "private message"] $ \err ->
                unless (responseStatus (storeErrorResponse "store_unavailable" err) == status503) $
                    fail "Published metrics lost the unavailable 503 mapping"
            putStrLn "PASS: published store 0.11.0.1 preserves script SQLSTATE 42P01 through both runners"
            putStrLn "PASS: published metrics 0.3.0.1 maps permanent errors to 500 and typed unavailable errors to 503"
    case outcome of
        Just (Right ()) -> putStrLn "PASS: disposable PostgreSQL stopped cleanly"
        Just (Left err) -> fail (show err)
        Nothing -> fail "Published consumer exceeded its 60-second database execution limit"

assertMissing :: Either StoreError () -> IO ()
assertMissing (Left err@(UnexpectedServerError "42P01" _)) =
    unless (responseStatus (storeErrorResponse "store_unavailable" err) == status500) $
        fail "Published metrics lost the permanent-error 500 mapping"
assertMissing other = fail ("Expected UnexpectedServerError 42P01, got " <> show other)
