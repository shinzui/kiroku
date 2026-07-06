{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations (
    embeddedMigrationNames,
    embeddedMigrationSources,
    kirokuMigrations,
    migrationAdvisoryLockKey,
    runKirokuMigrations,
    runKirokuMigrationsNoCheck,
    withMigrationLock,
) where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings (..), VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Codd.Types (ConnectionString, libpqConnString, singleTryPolicy)
import Control.Exception (bracket)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Database.PostgreSQL.Simple qualified as DB
import Streaming.Prelude qualified as Streaming

{- | Kiroku's embedded SQL migrations, embedded from @sql-migrations@ and
ordered by timestamped filename.

When adding a migration file, this module must be rebuilt so Template Haskell's
'embedDir' captures the new directory contents during local validation. Touch:
2026-07-06 integrity guard embed refresh.
-}
kirokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kirokuMigrations =
    traverse parseEmbeddedMigration embeddedMigrationFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
        let stream :: PureStream m
            stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
        result <-
            parseAddedSqlMigration
                name
                stream
        case result of
            Left err -> fail ("Invalid Kiroku migration " <> name <> ": " <> err)
            Right migration -> pure migration

-- | Run Kiroku's embedded migrations through codd.
runKirokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKirokuMigrations settings connectTimeout verifySchemas = do
    let settings' = forceSingleTryPolicy settings
    warnRetryPolicyOverride settings
    withMigrationLock (migsConnString settings') connectTimeout $
        runCoddLogger $ do
            migrations <- kirokuMigrations
            applyMigrations settings' (Just migrations) connectTimeout verifySchemas

{- | Run Kiroku's embedded migrations through codd without expected-schema
verification.

This is the right entry point until the caller owns a codd expected-schema
snapshot. Use 'runKirokuMigrations' when schema verification is configured.
-}
runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKirokuMigrationsNoCheck settings connectTimeout = do
    let settings' = forceSingleTryPolicy settings
    warnRetryPolicyOverride settings
    withMigrationLock (migsConnString settings') connectTimeout $
        runCoddLogger $ do
            migrations <- kirokuMigrations
            applyMigrationsNoCheck settings' (Just migrations) connectTimeout (const (pure SchemasNotVerified))

-- | Shared advisory-lock key for all Kiroku/Keiro framework migration applies.
migrationAdvisoryLockKey :: Int64
migrationAdvisoryLockKey = 0x6B69726F6B754D67

withMigrationLock :: ConnectionString -> DiffTime -> IO a -> IO a
withMigrationLock connString _connectTimeout action =
    bracket acquire DB.close (const action)
  where
    acquire = do
        conn <- DB.connectPostgreSQL (libpqConnString connString)
        _ <- DB.query conn "SELECT pg_advisory_lock(?)" (DB.Only migrationAdvisoryLockKey) :: IO [DB.Only ()]
        pure conn

forceSingleTryPolicy :: CoddSettings -> CoddSettings
forceSingleTryPolicy settings =
    settings{retryPolicy = singleTryPolicy}

warnRetryPolicyOverride :: CoddSettings -> IO ()
warnRetryPolicyOverride settings =
    when (retryPolicy settings /= singleTryPolicy) $
        putStrLn "Ignoring CODD_RETRY_POLICY for embedded migrations; codd v0.1.8 cannot retry in-memory migration streams."

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")

embeddedMigrationSources :: [(FilePath, ByteString)]
embeddedMigrationSources = embeddedMigrationFiles

embeddedMigrationNames :: [FilePath]
embeddedMigrationNames = sort (map fst embeddedMigrationFiles)
