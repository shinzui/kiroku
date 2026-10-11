{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE PackageImports #-}

-- Harness-only replacement for ephemeral provisioning. Workload and gates are unchanged.
module Kiroku.Test.Postgres (withSharedMigratedPostgres, withMigratedTestDatabase) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (getEnv)
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcessWithExitCode)
import "kiroku-test-support" Kiroku.Test.Postgres qualified as Original

{-# NOINLINE counter #-}
counter :: IORef Int
counter = unsafePerformIO (newIORef 0)

withSharedMigratedPostgres :: IO a -> IO a
withSharedMigratedPostgres = id

withMigratedTestDatabase :: (Text -> IO a) -> IO a
withMigratedTestDatabase action = do
    connection <- getEnv "MP13_DATABASE_URL"
    -- The cell publishes keyword/value conninfo, not a URI.
    unless ("host=" `T.isPrefixOf` T.pack connection) (fail "expected cell keyword conninfo")
    n <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
    let database = "mp13_gate_" <> show n
        execute sql = do
            (code, _, err) <- readProcessWithExitCode "psql" ["-X", "-v", "ON_ERROR_STOP=1", "-d", connection, "-c", sql] ""
            unless (code == ExitSuccess) (fail err)
        target = T.unwords (filter (not . T.isPrefixOf "dbname=") (T.words (T.pack connection)) <> ["dbname=" <> T.pack database])
    bracket
        (execute ("CREATE DATABASE " <> database <> " TEMPLATE template0"))
        (\() -> execute ("DROP DATABASE " <> database <> " WITH (FORCE)"))
        (\() -> Original.migrateTestDatabase target >> action target)
