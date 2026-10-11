{-# LANGUAGE PackageImports #-}

{- | Cell-only fixture adapter. Databases are precreated and later cleaned by
the owning cell protocol; benchmark actions remain the repository originals.
-}
module Kiroku.Test.Postgres (withSharedMigratedPostgres, withMigratedTestDatabase) where

import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (getEnv)
import System.IO.Unsafe (unsafePerformIO)
import "kiroku-test-support" Kiroku.Test.Postgres qualified as Local

{-# NOINLINE nextDatabase #-}
nextDatabase :: IORef Int
nextDatabase = unsafePerformIO (newIORef 0)

withSharedMigratedPostgres :: IO a -> IO a
withSharedMigratedPostgres action = writeIORef nextDatabase 0 >> action

withMigratedTestDatabase :: (Text -> IO a) -> IO a
withMigratedTestDatabase action = do
    base <- T.pack <$> getEnv "EP97_DATABASE_URL"
    index <- atomicModifyIORef' nextDatabase (\n -> (n + 1, n))
    if index > 4 then fail "cell fixture exhausted its five isolated databases" else pure ()
    let database = if index == 0 then "benchmark" else "ep97_" <> T.pack (show index)
        connection = T.unwords (filter (not . T.isPrefixOf "dbname=") (T.words base) <> ["dbname=" <> database])
    Local.migrateTestDatabase connection
    action connection
