module Codd.Extras.WriteSchema (
    writeExpectedSchemaToDisk,
)
where

import Codd (CoddSettings (..))
import Codd.AppCommands.WriteSchema (WriteSchemaOpts (WriteToDisk), writeSchema)
import Codd.Extras.Settings (parseConnString)
import Codd.Types (SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Exception (finally)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import EphemeralPg.Config qualified as PgConfig

writeExpectedSchemaToDisk ::
    Text ->
    [Text] ->
    FilePath ->
    (CoddSettings -> IO ()) ->
    IO ()
writeExpectedSchemaToDisk pgUser schemas outputDir apply = do
    let pgConfig :: Pg.Config
        pgConfig = PgConfig.defaultConfig{PgConfig.user = pgUser}
    started <- Pg.startCached pgConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let settings = coddSettings (Pg.connectionString db)
                apply settings
                writeSchema settings (WriteToDisk (Just outputDir))
                putStrLn ("Wrote expected schema to " <> outputDir)
            )
                `finally` Pg.stop db
  where
    coddSettings connStr =
        CoddSettings
            { migsConnString = parseConnString connStr
            , sqlMigrations = []
            , onDiskReps = Left outputDir
            , namespacesToCheck = IncludeSchemas (map SqlSchema schemas)
            , extraRolesToCheck = []
            , retryPolicy = singleTryPolicy
            , txnIsolationLvl = DbDefault
            , schemaAlgoOpts = SchemaAlgo False False False
            }
