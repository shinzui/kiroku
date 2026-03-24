{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Schema (
    SchemaInitError (..),
    initializeSchema,
) where

import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Hasql.Pool (Pool, UsageError)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session

-- | Exception thrown when schema initialization fails.
newtype SchemaInitError = SchemaInitError UsageError
    deriving stock (Show)
    deriving anyclass (Exception)

{- | Initialize the event store schema in the given PostgreSQL schema.
Idempotent — safe to call on every startup.
-}
initializeSchema :: (MonadIO m) => Pool -> Text -> m ()
initializeSchema pool _schema = liftIO $ do
    result <- Pool.use pool (Session.script schemaDDL)
    case result of
        Left err -> throwIO (SchemaInitError err)
        Right () -> pure ()

-- | Schema DDL embedded at compile time from sql/schema.sql.
schemaDDLBytes :: ByteString
schemaDDLBytes = $(embedFile "sql/schema.sql")

schemaDDL :: Text
schemaDDL = TE.decodeUtf8 schemaDDLBytes
