{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations.LegacyCodd (runLegacyKirokuMigrations) where

import Codd (ApplyResult, CoddSettings)
import Codd.Extras.MigrationSet (MigrationSet)
import Codd.Extras.MigrationSet qualified as MigrationSet
import Data.FileEmbed (embedDir)
import Data.List (isSuffixOf)
import Data.Time (DiffTime)

runLegacyKirokuMigrations :: CoddSettings -> DiffTime -> IO ApplyResult
runLegacyKirokuMigrations settings connectTimeout =
    MigrationSet.applyMigrationSetNoCheck settings connectTimeout legacyMigrationSet

legacyMigrationSet :: MigrationSet
legacyMigrationSet =
    MigrationSet.MigrationSet
        { MigrationSet.label = "Kiroku legacy expected-schema tool"
        , MigrationSet.files = filter ((".sql" `isSuffixOf`) . fst) $(embedDir "migrations")
        }
