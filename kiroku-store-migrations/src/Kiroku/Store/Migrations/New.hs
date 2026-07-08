module Kiroku.Store.Migrations.New (
    newMigrationFile,
    defaultMigrationsDir,
    migrationFileName,
    migrationSlug,
    migrationTemplate,
) where

import Codd.Extras.New qualified as New
import Data.Time (UTCTime)

defaultMigrationsDir :: FilePath
defaultMigrationsDir = New.defaultMigrationsDir

newMigrationFile :: FilePath -> String -> IO FilePath
newMigrationFile = New.newMigrationFile migrationFileConfig

migrationFileName :: UTCTime -> String -> FilePath
migrationFileName = New.migrationFileName migrationFileConfig

migrationSlug :: String -> String
migrationSlug = New.migrationSlug Nothing

migrationTemplate :: String -> String
migrationTemplate description =
    unlines
        [ "-- " <> description
        , "--"
        , "-- Kiroku incremental migration. codd applies this file exactly once,"
        , "-- keyed by filename, and records it in codd_schema.sql_migrations."
        , "-- Keep every statement idempotent (IF NOT EXISTS / IF EXISTS) so a"
        , "-- partial re-run is safe, and hard-qualify every object with the"
        , "-- kiroku schema. Do NOT pin the schema search path; always write"
        , "-- kiroku.<name> explicitly, as the incremental migrations do."
        , ""
        , "CREATE TABLE IF NOT EXISTS kiroku.example ("
        , "    example_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY"
        , ");"
        , ""
        , "-- Index name is bare; the ON target is schema-qualified."
        , "CREATE INDEX IF NOT EXISTS ix_example_id"
        , "    ON kiroku.example (example_id);"
        , ""
        , "-- TODO: replace the example above with the real DDL for this migration."
        ]

migrationFileConfig :: New.MigrationFileConfig
migrationFileConfig =
    New.MigrationFileConfig
        { New.migrationSlugPrefix = Nothing
        , New.migrationTemplate = migrationTemplate
        }
