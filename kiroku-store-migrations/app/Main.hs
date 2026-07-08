module Main where

import Codd (ApplyResult, CoddSettings (..))
import Codd.Extras.Cli (CheckMode, MigrationCliConfig (..), migrationCliMain)
import Data.Time (DiffTime, secondsToDiffTime)
import Kiroku.Store.Migrations (
    migrationStatus,
    runKirokuMigrationsNoCheck,
    verifySchema,
 )
import Kiroku.Store.Migrations.New (defaultMigrationsDir, newMigrationFile)

main :: IO ()
main =
    migrationCliMain
        MigrationCliConfig
            { cliProgramName = "kiroku-store-migrate"
            , cliMigrationsDirEnv = "KIROKU_MIGRATIONS_DIR"
            , cliDefaultMigrationsDir = defaultMigrationsDir
            , cliNewMigrationFile = newMigrationFile
            , cliRunUp = runUp
            , cliVerifySchema = verifySchema
            , cliMigrationStatus = \settings connectTimeout ->
                migrationStatus (migsConnString settings) connectTimeout
            , cliConnectTimeout = secondsToDiffTime 5
            , cliNoCheckEnv = Nothing
            , cliEmbedRefreshHint =
                "Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
            }

runUp :: CheckMode -> CoddSettings -> DiffTime -> IO ApplyResult
runUp _ settings connectTimeout =
    runKirokuMigrationsNoCheck settings connectTimeout
