{-# LANGUAGE ScopedTypeVariables #-}

module Codd.Extras.Embedded (
    embeddedMigrationNames,
    parseEmbeddedMigrations,
)
where

import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Text.Encoding qualified as TE
import Streaming.Prelude qualified as Streaming

parseEmbeddedMigrations ::
    forall m.
    (MonadFail m, EnvVars m) =>
    String ->
    [(FilePath, ByteString)] ->
    m [AddedSqlMigration m]
parseEmbeddedMigrations label =
    traverse parseEmbeddedMigration
  where
    parseEmbeddedMigration :: (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
        let stream :: PureStream m
            stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
        result <- parseAddedSqlMigration name stream
        case result of
            Left err -> fail ("Invalid " <> label <> " migration " <> name <> ": " <> err)
            Right migration -> pure migration

embeddedMigrationNames :: [(FilePath, ByteString)] -> [FilePath]
embeddedMigrationNames = sort . map fst
