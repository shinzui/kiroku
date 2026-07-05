module Kiroku.Store.Migrations.New (
    newMigrationFile,
    defaultMigrationsDir,
    migrationFileName,
    migrationSlug,
    migrationTemplate,
) where

import Control.Monad (when)
import Data.Char (isAlphaNum, toLower)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

-- | Default directory into which migrations are scaffolded, relative to the
-- working directory. Overridden by the @KIROKU_MIGRATIONS_DIR@ environment
-- variable in the executable.
defaultMigrationsDir :: FilePath
defaultMigrationsDir = "sql-migrations"

-- | Scaffold a new migration file in @dir@ from a human description, stamped
-- with the real current UTC time to the second. Returns the path written.
-- Refuses to clobber an existing file, and rejects a description with no
-- alphanumeric character (which would produce an empty slug).
newMigrationFile :: FilePath -> String -> IO FilePath
newMigrationFile dir description = do
    when (not (any isAlphaNum description)) $
        ioError (userError "migration description must contain at least one letter or digit")
    now <- getCurrentTime
    let path = dir </> migrationFileName now description
    createDirectoryIfMissing True dir
    exists <- doesFileExist path
    when exists $
        ioError (userError ("refusing to overwrite existing migration: " <> path))
    writeFile path (migrationTemplate description)
    pure path

-- | Build the migration filename from a timestamp and a description:
-- @YYYY-MM-DD-HH-MM-SS-<slug>.sql@. The timestamp is formatted to the second so
-- filenames sort in true authoring order and never collide in codd's ledger.
migrationFileName :: UTCTime -> String -> FilePath
migrationFileName now description =
    formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S" now
        <> "-"
        <> migrationSlug description
        <> ".sql"

-- | Turn a free-text description into a filename slug: lower-case, every run of
-- non-alphanumeric characters collapsed to a single dash, and leading/trailing
-- dashes trimmed. Unlike keiro's scaffolder, kiroku slugs carry NO prefix.
migrationSlug :: String -> String
migrationSlug raw =
    trimDashes (collapseDashes (map normalise raw))
  where
    normalise c = if isAlphaNum c then toLower c else '-'
    collapseDashes ('-' : '-' : rest) = collapseDashes ('-' : rest)
    collapseDashes (c : rest) = c : collapseDashes rest
    collapseDashes [] = []
    trimDashes = f . f where f = reverse . dropWhile (== '-')

-- | The SQL skeleton written into a scaffolded migration: a header comment plus
-- a schema-qualified, idempotent example and a TODO. kiroku's incremental
-- migrations hard-qualify @kiroku.<table>@ and never pin @search_path@; this
-- template follows that style (NOT the bootstrap's one-time @SET search_path@).
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
