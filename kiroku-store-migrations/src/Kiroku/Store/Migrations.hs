{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    appliedLedgerMigrations,
    detectMigrationLedger,
    embeddedMigrationNames,
    embeddedMigrationSources,
    kirokuMigrations,
    migrationStatus,
    migrationStatusFor,
    missingMigrations,
    migrationAdvisoryLockKey,
    runKirokuMigrations,
    runKirokuMigrationsNoCheck,
    verifySchema,
    withMigrationLock,
) where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings (..), VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Codd.Query (queryServerMajorAndFullVersion)
import Codd.Representations (logSchemasComparison, readRepsFromDisk)
import Codd.Representations.Database (readRepsFromDbWithNewTxn)
import Codd.Types (ConnectionString, libpqConnString, singleTryPolicy)
import Control.Exception (bracket)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Data.Time.Clock (UTCTime)
import Database.PostgreSQL.Simple qualified as DB
import Kiroku.Store.Migrations.ExpectedSchema (withMaterializedExpectedSchema)
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

data LedgerSchema
    = CoddLedger
    | CoddSchemaLedger
    deriving stock (Eq, Show)

data MigrationStatus = MigrationStatus
    { statusLedgerSchema :: Maybe LedgerSchema
    , statusApplied :: [(FilePath, UTCTime)]
    , statusPending :: [FilePath]
    }
    deriving stock (Eq, Show)

data VerifyOutcome
    = VerifySucceeded
    | VerifyFailed
    | VerifyPending [FilePath]
    deriving stock (Eq, Show)

verifySchema :: CoddSettings -> DiffTime -> IO VerifyOutcome
verifySchema settings _connectTimeout =
    bracket (DB.connectPostgreSQL (libpqConnString (migsConnString settings))) DB.close $ \conn -> do
        pending <- statusPending <$> migrationStatusForConnection embeddedMigrationNames conn
        if null pending
            then verifyRepresentations conn
            else pure (VerifyPending pending)
  where
    verifyRepresentations conn =
        withMaterializedExpectedSchema $ \expectedSchemaDir ->
            runCoddLogger $ do
                (pgMajor, _) <- queryServerMajorAndFullVersion conn
                live <- readRepsFromDbWithNewTxn settings conn
                expected <- readRepsFromDisk pgMajor expectedSchemaDir
                logSchemasComparison live expected
                pure $
                    if live == expected
                        then VerifySucceeded
                        else VerifyFailed

missingMigrations :: ConnectionString -> DiffTime -> IO [FilePath]
missingMigrations connString connectTimeout =
    statusPending <$> migrationStatus connString connectTimeout

migrationStatus :: ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatus = migrationStatusFor embeddedMigrationNames

migrationStatusFor :: [FilePath] -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatusFor expectedNames connString _connectTimeout =
    bracket (DB.connectPostgreSQL (libpqConnString connString)) DB.close (migrationStatusForConnection expectedNames)

migrationStatusForConnection :: [FilePath] -> DB.Connection -> IO MigrationStatus
migrationStatusForConnection expectedNames conn = do
    ledgerSchema <- detectMigrationLedger conn
    applied <- maybe (pure []) (appliedLedgerMigrations conn) ledgerSchema
    let appliedNames = map fst applied
        pending = filter (`notElem` appliedNames) (sort expectedNames)
    pure
        MigrationStatus
            { statusLedgerSchema = ledgerSchema
            , statusApplied = applied
            , statusPending = pending
            }

detectMigrationLedger :: DB.Connection -> IO (Maybe LedgerSchema)
detectMigrationLedger conn = do
    [(hasCodd, hasCoddSchema)] <-
        DB.query_
            conn
            "SELECT to_regclass('codd.sql_migrations') IS NOT NULL, to_regclass('codd_schema.sql_migrations') IS NOT NULL"
    pure $
        if hasCodd
            then Just CoddLedger
            else
                if hasCoddSchema
                    then Just CoddSchemaLedger
                    else Nothing

appliedLedgerMigrations :: DB.Connection -> LedgerSchema -> IO [(FilePath, UTCTime)]
appliedLedgerMigrations conn schema =
    DB.query_ conn query
  where
    query =
        case schema of
            CoddLedger -> "SELECT name, migration_timestamp FROM codd.sql_migrations ORDER BY name"
            CoddSchemaLedger -> "SELECT name, migration_timestamp FROM codd_schema.sql_migrations ORDER BY name"

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
    -- codd v0.1.8 retries re-read migration streams, but embedded in-memory
    -- streams fail with "Re-reading in-memory streams is not yet implemented".
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
