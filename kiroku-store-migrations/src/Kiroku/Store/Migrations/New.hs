module Kiroku.Store.Migrations.New (
    AuthoringError,
    defaultMigrationsDir,
    newMigrationFile,
    migrationTemplate,
) where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Embed (
    AuthoringError,
    newMigration,
    newMigrationOptions,
 )
import System.FilePath ((</>))

defaultMigrationsDir :: FilePath
defaultMigrationsDir = "migrations"

newMigrationFile :: FilePath -> String -> IO (Either AuthoringError FilePath)
newMigrationFile migrationsDirectory description =
    case newMigrationOptions manifestPath Nothing (migrationTemplate description) of
        Left definitionError -> pure (Left definitionError)
        Right options -> newMigration options
  where
    manifestPath = migrationsDirectory </> "manifest"

migrationTemplate :: String -> ByteString
migrationTemplate description =
    Text.Encoding.encodeUtf8
        ( Text.unlines
            [ "-- " <> Text.pack description
            , ""
            , "-- Kiroku migrations are forward-only and applied exactly once by pg-migrate."
            , "-- Qualify every object with the kiroku schema and append corrections"
            , "-- as new manifest entries instead of editing released payloads."
            , ""
            ]
        )
