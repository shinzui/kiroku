{-# LANGUAGE LambdaCase #-}

module Codd.Extras.Ledger (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    appliedLedgerMigrations,
    detectMigrationLedger,
    migrationStatus,
    migrationStatusFor,
    migrationStatusForConnection,
    missingMigrations,
)
where

import Codd.Internal (CoddSchemaVersion (..), detectCoddSchema)
import Codd.Types (ConnectionString, libpqConnString)
import Control.Exception (bracket)
import Data.List (sort)
import Data.Time (DiffTime)
import Data.Time.Clock (UTCTime)
import Database.PostgreSQL.Simple qualified as DB

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

detectMigrationLedger :: DB.Connection -> IO (Maybe LedgerSchema)
detectMigrationLedger conn =
    detectCoddSchema conn >>= \case
        CoddSchemaDoesNotExist -> pure Nothing
        CoddSchemaV5 -> pure (Just CoddLedger)
        CoddSchemaV1 -> pure (Just CoddSchemaLedger)
        CoddSchemaV2 -> pure (Just CoddSchemaLedger)
        CoddSchemaV3 -> pure (Just CoddSchemaLedger)
        CoddSchemaV4 -> pure (Just CoddSchemaLedger)

appliedLedgerMigrations :: DB.Connection -> LedgerSchema -> IO [(FilePath, UTCTime)]
appliedLedgerMigrations conn = \case
    CoddLedger ->
        DB.query_ conn "SELECT name, migration_timestamp FROM codd.sql_migrations WHERE no_txn_failed_at IS NULL ORDER BY name"
    CoddSchemaLedger ->
        detectCoddSchema conn >>= \case
            CoddSchemaV1 ->
                DB.query_ conn "SELECT name, migration_timestamp FROM codd_schema.sql_migrations ORDER BY name"
            CoddSchemaV2 ->
                DB.query_ conn "SELECT name, migration_timestamp FROM codd_schema.sql_migrations ORDER BY name"
            CoddSchemaV3 ->
                DB.query_ conn "SELECT name, migration_timestamp FROM codd_schema.sql_migrations WHERE no_txn_failed_at IS NULL ORDER BY name"
            CoddSchemaV4 ->
                DB.query_ conn "SELECT name, migration_timestamp FROM codd_schema.sql_migrations WHERE no_txn_failed_at IS NULL ORDER BY name"
            CoddSchemaDoesNotExist -> pure []
            CoddSchemaV5 ->
                DB.query_ conn "SELECT name, migration_timestamp FROM codd.sql_migrations WHERE no_txn_failed_at IS NULL ORDER BY name"

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

migrationStatusFor :: [FilePath] -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatusFor expectedNames connString _connectTimeout =
    bracket (DB.connectPostgreSQL (libpqConnString connString)) DB.close (migrationStatusForConnection expectedNames)

migrationStatus :: [FilePath] -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatus = migrationStatusFor

missingMigrations :: [FilePath] -> ConnectionString -> DiffTime -> IO [FilePath]
missingMigrations expectedNames connString connectTimeout =
    statusPending <$> migrationStatus expectedNames connString connectTimeout
