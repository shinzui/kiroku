{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations.Internal.Definition (
    embeddedMigrationEntries,
    kirokuMigrations,
) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Database.PostgreSQL.Migrate (
    DefinitionError,
    MigrationComponent,
    migrationComponentFromEmbeddedSql,
 )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)

embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
    $(embedMigrationManifest "migrations/manifest")

kirokuMigrations :: Either DefinitionError MigrationComponent
kirokuMigrations =
    migrationComponentFromEmbeddedSql "kiroku" mempty embeddedMigrationEntries
