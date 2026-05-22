{-# LANGUAGE TemplateHaskell #-}

module Kiroku.Store.Schema (
    SchemaInitError (..),
    initializeSchema,
    quoteIdentifier,
) where

import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text qualified as T
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

The @Text@ argument is the target schema name. @sql\/schema.sql@ contains
a @__KIROKU_SCHEMA__@ token in its @CREATE SCHEMA@ and @SET search_path@
statements; this function replaces every occurrence with the supplied
name, quoted as a SQL identifier, before running the script. The result
is that the Kiroku tables, indexes, functions, and triggers are created
inside that schema (the @kiroku@ schema by default), and the rest of the
unqualified DDL resolves through the @search_path@ this script sets. See
'Kiroku.Store.Connection.ConnectionSettings.schema'.
-}
initializeSchema :: (MonadIO m) => Pool -> Text -> m ()
initializeSchema pool schema = liftIO $ do
    let ddl = T.replace schemaPlaceholder (quoteIdentifier schema) schemaDDL
    result <- Pool.use pool (Session.script ddl)
    case result of
        Left err -> throwIO (SchemaInitError err)
        Right () -> pure ()

{- | The token used in @sql\/schema.sql@ wherever the configured schema name
must be interpolated (the @CREATE SCHEMA@ and @SET search_path@ statements).
'initializeSchema' replaces it with the quoted schema identifier.
-}
schemaPlaceholder :: Text
schemaPlaceholder = "__KIROKU_SCHEMA__"

{- | Quote a 'Text' as a PostgreSQL identifier: wrap it in double quotes and
double any embedded double quote. Used to interpolate the configured schema
name into @search_path@ and @CREATE SCHEMA@ statements without risking SQL
injection from a hostile schema setting.

>>> quoteIdentifier "kiroku"
"\"kiroku\""

>>> quoteIdentifier "weird\"name"
"\"weird\"\"name\""
-}
quoteIdentifier :: Text -> Text
quoteIdentifier ident = "\"" <> T.replace "\"" "\"\"" ident <> "\""

-- | Schema DDL embedded at compile time from sql/schema.sql.
schemaDDLBytes :: ByteString
schemaDDLBytes = $(embedFile "sql/schema.sql")

schemaDDL :: Text
schemaDDL = TE.decodeUtf8 schemaDDLBytes
