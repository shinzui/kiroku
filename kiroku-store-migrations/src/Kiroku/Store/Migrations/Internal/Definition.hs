{-# LANGUAGE TemplateHaskell #-}
-- GHC 9.12 has no Template Haskell directory-dependency API, so a sibling SQL
-- file that is added or removed without being listed in the manifest leaves this
-- module looking up to date and silently skips manifest membership validation.
-- The plugin forces GHC to reconsider this module on every build it runs.
-- Note this cannot help when no Haskell source changes at all: cabal then
-- reports "Up to date" and never invokes GHC. A clean build revalidates.
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

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
