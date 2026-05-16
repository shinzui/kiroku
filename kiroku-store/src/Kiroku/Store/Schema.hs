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

{- | Initialize the event store schema by running the embedded
@kiroku-store/sql/schema.sql@ DDL script against the supplied pool.

The DDL is /idempotent for additive changes only/. Specifically:

* 'CREATE TABLE IF NOT EXISTS', 'CREATE INDEX IF NOT EXISTS', and
  'CREATE OR REPLACE FUNCTION' are safe to re-run.
* 'DROP TRIGGER IF EXISTS' followed by 'CREATE TRIGGER' is safe in
  practice (PostgreSQL serialises catalog updates).
* @INSERT INTO streams ... ON CONFLICT DO NOTHING@ and
  @SELECT setval(..., GREATEST(...))@ are idempotent.

It is /not/ safe under backwards-incompatible changes — renaming a
column, changing a column type, removing a column, or adding a
constraint without 'IF NOT EXISTS' would produce a half-applied
state on the second start. Once a non-trivial DDL change is
required, extract a dedicated migration tool (see the parked plan
at @docs\/plans\/partition-ready-schema.md@ and the
@project_schema_migration.md@ memory note) rather than evolve
@schema.sql@ in place.

Required privileges of the connecting user: @CREATE@ on the target
schema (for the table\/index\/function creation), @TRIGGER@ on the
created tables, and @INSERT, UPDATE, SELECT@ on @streams@ (for the
seed row and @setval@). Production deployments should prefer the
@kiroku-store-migrate@ executable or
'Kiroku.Store.Migrations.runKirokuMigrations' under a more privileged
migration role, then open 'Kiroku.Store.withStore' with
'Kiroku.Store.Connection.SkipSchemaInitialization' under the
lower-privileged runtime role; see @docs\/PRODUCTION-DEPLOYMENT.md@.

The @Text@ argument is unused. It was previously intended to be the
target schema name, but the SQL is unqualified and resolves through
@search_path@; see 'Kiroku.Store.Connection.ConnectionSettings.schema'.
The argument is retained for forward compatibility with a future
migration story; pass any value (the field's value is conventional).
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
