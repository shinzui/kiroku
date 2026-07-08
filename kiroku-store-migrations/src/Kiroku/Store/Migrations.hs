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

import Codd (ApplyResult, CoddSettings, VerifySchemas)
import Codd.Extras.Apply (applyEmbeddedMigrations, applyEmbeddedMigrationsNoCheck)
import Codd.Extras.Embedded qualified as Embedded
import Codd.Extras.Ledger (LedgerSchema (..), MigrationStatus (..), VerifyOutcome (..), appliedLedgerMigrations, detectMigrationLedger, migrationStatusFor, migrationStatusForConnection)
import Codd.Extras.Ledger qualified as Ledger
import Codd.Extras.Lock (migrationAdvisoryLockKey, withMigrationLock)
import Codd.Extras.Verify (verifySchemaWith)
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
    Embedded.parseEmbeddedMigrations "Kiroku" embeddedMigrationFiles

-- | Run Kiroku's embedded migrations through codd.
runKirokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKirokuMigrations settings connectTimeout verifySchemas =
    applyEmbeddedMigrations settings connectTimeout verifySchemas [("Kiroku", embeddedMigrationFiles)]

{- | Run Kiroku's embedded migrations through codd without expected-schema
verification.

This is the right entry point until the caller owns a codd expected-schema
snapshot. Use 'runKirokuMigrations' when schema verification is configured.
-}
runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKirokuMigrationsNoCheck settings connectTimeout =
    applyEmbeddedMigrationsNoCheck settings connectTimeout [("Kiroku", embeddedMigrationFiles)]

verifySchema :: CoddSettings -> DiffTime -> IO VerifyOutcome
verifySchema =
    verifySchemaWith embeddedMigrationNames expectedSchemaFiles "kiroku-expected-schema"

missingMigrations :: ConnectionString -> DiffTime -> IO [FilePath]
missingMigrations connString connectTimeout =
    Ledger.missingMigrations embeddedMigrationNames connString connectTimeout

migrationStatus :: ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatus = migrationStatusFor embeddedMigrationNames

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")

embeddedMigrationSources :: [(FilePath, ByteString)]
embeddedMigrationSources = embeddedMigrationFiles

embeddedMigrationNames :: [FilePath]
embeddedMigrationNames = Embedded.embeddedMigrationNames embeddedMigrationFiles
