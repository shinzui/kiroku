module Main where

import Codd (ApplyResult, CoddSettings (..))
import Codd.Extras.Cli (CheckMode, MigrationCliConfig (..), migrationCliMain)
import Data.Time (DiffTime, secondsToDiffTime)
import Kiroku.Store.Migrations qualified as Migrations
import Kiroku.Store.Migrations.New qualified as New

main :: IO ()
main =
    migrationCliMain
        MigrationCliConfig
            { programName = "kiroku-store-migrate"
            , migrationsDirEnv = "KIROKU_MIGRATIONS_DIR"
            , defaultMigrationsDir = New.defaultMigrationsDir
            , newMigrationFile = New.newMigrationFile
            , runUp = runUpMigrations
            , verifySchema = Migrations.verifySchema
            , migrationStatus = \settings timeout ->
                Migrations.migrationStatus (migsConnString settings) timeout
            , connectTimeout = secondsToDiffTime 5
            , noCheckEnv = Nothing
            , embedRefreshHint =
                "Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
            }

runUpMigrations :: CheckMode -> CoddSettings -> DiffTime -> IO ApplyResult
runUpMigrations _ settings timeout =
    Migrations.runKirokuMigrationsNoCheck settings timeout
