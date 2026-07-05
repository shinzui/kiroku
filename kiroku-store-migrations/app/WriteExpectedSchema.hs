module Main (main) where

import Codd (CoddSettings (..))
import Codd.AppCommands.WriteSchema (WriteSchemaOpts (WriteToDisk), writeSchema)
import Codd.Parsing (connStringParser)
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Control.Exception (finally)
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import System.Environment (getArgs)

{- | Pin the throwaway PostgreSQL superuser to a fixed, machine-independent name
so the captured snapshot identity (the connecting role, the db owner, and every
object owner) is deterministic on every machine and in CI. codd always records
the connecting user's role and the database owner, so a non-deterministic user
would make the strict drift gate false-fail off the author's machine.
-}
kirokuPgConfig :: Pg.Config
kirokuPgConfig = Pg.defaultConfig{Pg.user = "kiroku"}

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    -- 'Pg.withCachedConfig' is not exported, so we use 'Pg.startCached' (which
    -- accepts a Config carrying the pinned user) and tear down with 'finally'.
    started <- Pg.startCached kirokuPgConfig Pg.defaultCacheConfig
    case started of
        Left err -> fail ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right db ->
            ( do
                let connStr = Pg.connectionString db
                    settings = coddSettings connStr outputDir
                _ <- runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)
                writeSchema settings (WriteToDisk (Just outputDir))
                putStrLn ("Wrote expected schema to " <> outputDir)
            )
                `finally` Pg.stop db

parseArgs :: [String] -> IO FilePath
parseArgs [] = pure "kiroku-store-migrations/expected-schema"
parseArgs [outputDir] = pure outputDir
parseArgs _ = fail "usage: cabal run kiroku-write-expected-schema -- [output-dir]"

coddSettings :: Text -> FilePath -> CoddSettings
coddSettings connStr expectedSchemaDir =
    CoddSettings
        { migsConnString = parseConnString connStr
        , sqlMigrations = []
        , onDiskReps = Left expectedSchemaDir
        , namespacesToCheck = IncludeSchemas [SqlSchema "kiroku"]
        , extraRolesToCheck = []
        , retryPolicy = singleTryPolicy
        , txnIsolationLvl = DbDefault
        , schemaAlgoOpts = SchemaAlgo False False False
        }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
    case parseOnly (connStringParser <* endOfInput) connStr of
        Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
        Right parsed -> parsed
