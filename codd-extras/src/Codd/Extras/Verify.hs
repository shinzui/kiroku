module Codd.Extras.Verify (
    verifySchemaWith,
)
where

import Codd (CoddSettings (..))
import Codd.Extras.ExpectedSchema (withMaterializedExpectedSchema)
import Codd.Extras.Ledger (MigrationStatus (..), VerifyOutcome (..), migrationStatusForConnection)
import Codd.Logging (runCoddLogger)
import Codd.Query (queryServerMajorAndFullVersion)
import Codd.Representations (logSchemasComparison, readRepsFromDisk)
import Codd.Representations.Database (readRepsFromDbWithNewTxn)
import Codd.Types (libpqConnString)
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Time (DiffTime)
import Database.PostgreSQL.Simple qualified as DB

verifySchemaWith ::
    [FilePath] ->
    [(FilePath, ByteString)] ->
    String ->
    CoddSettings ->
    DiffTime ->
    IO VerifyOutcome
verifySchemaWith expectedNames expectedSchemaFiles tempLabel settings _connectTimeout =
    bracket (DB.connectPostgreSQL (libpqConnString (migsConnString settings))) DB.close $ \conn -> do
        pending <- statusPending <$> migrationStatusForConnection expectedNames conn
        if null pending
            then verifyRepresentations conn
            else pure (VerifyPending pending)
  where
    verifyRepresentations conn =
        withMaterializedExpectedSchema tempLabel expectedSchemaFiles $ \expectedSchemaDir ->
            runCoddLogger $ do
                (pgMajor, _) <- queryServerMajorAndFullVersion conn
                live <- readRepsFromDbWithNewTxn settings conn
                expected <- readRepsFromDisk pgMajor expectedSchemaDir
                logSchemasComparison live expected
                pure $
                    if live == expected
                        then VerifySucceeded
                        else VerifyFailed
