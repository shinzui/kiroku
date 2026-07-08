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
    kirokuMigrationSet,
    migrationStatus,
    migrationStatusFor,
    missingMigrations,
    migrationAdvisoryLockKey,
    runKirokuMigrations,
    runKirokuMigrationsNoCheck,
    verifySchema,
    withMigrationLock,
) where

import Codd (ApplyResult, CoddSettings, VerifySchemas)
import Codd.Extras.Ledger (LedgerSchema (..), MigrationStatus (..), VerifyOutcome (..), appliedLedgerMigrations, detectMigrationLedger, migrationStatusFor, migrationStatusForConnection)
import Codd.Extras.Lock (migrationAdvisoryLockKey, withMigrationLock)
import Codd.Extras.MigrationSet (MigrationSet)
import Codd.Extras.MigrationSet qualified as MigrationSet
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Codd.Types (ConnectionString)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Time (DiffTime)
import Kiroku.Store.Migrations.ExpectedSchema (expectedSchemaFiles)

{- | Kiroku's embedded SQL migrations, embedded from @sql-migrations@ and
ordered by timestamped filename.

When adding a migration file, this module must be rebuilt so Template Haskell's
'embedDir' captures the new directory contents during local validation. Touch:
2026-07-06 integrity guard embed refresh.
-}
kirokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kirokuMigrations =
    MigrationSet.parseMigrationSet kirokuMigrationSet

-- | Run Kiroku's embedded migrations through codd.
runKirokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKirokuMigrations settings connectTimeout verifySchemas =
    MigrationSet.applyMigrationSet settings connectTimeout verifySchemas kirokuMigrationSet

{- | Run Kiroku's embedded migrations through codd without expected-schema
verification.

This is the right entry point until the caller owns a codd expected-schema
snapshot. Use 'runKirokuMigrations' when schema verification is configured.
-}
runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKirokuMigrationsNoCheck settings connectTimeout =
    MigrationSet.applyMigrationSetNoCheck settings connectTimeout kirokuMigrationSet

verifySchema :: CoddSettings -> DiffTime -> IO VerifyOutcome
verifySchema =
    MigrationSet.verifyExpectedSchema
        embeddedMigrationNames
        MigrationSet.ExpectedSchema
            { MigrationSet.label = "kiroku-expected-schema"
            , MigrationSet.files = expectedSchemaFiles
            }

missingMigrations :: ConnectionString -> DiffTime -> IO [FilePath]
missingMigrations =
    MigrationSet.missingMigrationsForSet kirokuMigrationSet

migrationStatus :: ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatus =
    MigrationSet.migrationStatusForSet kirokuMigrationSet

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")

kirokuMigrationSet :: MigrationSet
kirokuMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Kiroku"
        , MigrationSet.files = embeddedMigrationFiles
        }

embeddedMigrationSources :: [(FilePath, ByteString)]
embeddedMigrationSources = embeddedMigrationFiles

embeddedMigrationNames :: [FilePath]
embeddedMigrationNames =
    MigrationSet.migrationNames kirokuMigrationSet
