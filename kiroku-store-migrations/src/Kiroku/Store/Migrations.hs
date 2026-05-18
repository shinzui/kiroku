{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Migrations (
    kirokuMigrations,
    runKirokuMigrations,
    runKirokuMigrationsNoCheck,
) where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Streaming.Prelude qualified as Streaming

-- | Kiroku's embedded SQL migrations, ordered by timestamped filename.
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
runKirokuMigrations settings connectTimeout verifySchemas =
    runCoddLogger $ do
        migrations <- kirokuMigrations
        applyMigrations settings (Just migrations) connectTimeout verifySchemas

{- | Run Kiroku's embedded migrations through codd without expected-schema
verification.

This is the right entry point until the caller owns a codd expected-schema
snapshot. Use 'runKirokuMigrations' when schema verification is configured.
-}
runKirokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKirokuMigrationsNoCheck settings connectTimeout =
    runCoddLogger $ do
        migrations <- kirokuMigrations
        applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")
