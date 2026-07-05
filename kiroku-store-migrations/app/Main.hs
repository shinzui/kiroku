module Main where

import Codd.Environment (getCoddSettings)
import Data.Maybe (fromMaybe)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import Kiroku.Store.Migrations.New (defaultMigrationsDir, newMigrationFile)
import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("new" : rest) -> generate (unwords rest)
        _ -> migrate

{- | The existing apply behavior, preserved verbatim from before the `new`
subcommand was added: read codd settings from the environment and apply the
embedded migrations without expected-schema verification.
-}
migrate :: IO ()
migrate = do
    settings <- getCoddSettings
    _ <- runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)
    pure ()

{- | Scaffold a new migration from a free-text description. Writes into
@KIROKU_MIGRATIONS_DIR@ if set, else 'defaultMigrationsDir'.
-}
generate :: String -> IO ()
generate description
    | all (== ' ') description =
        ioError (userError "usage: kiroku-store-migrate new <description>")
    | otherwise = do
        dir <- fromMaybe defaultMigrationsDir <$> lookupEnv "KIROKU_MIGRATIONS_DIR"
        path <- newMigrationFile dir description
        putStrLn ("Created " <> path)
        putStrLn
            "Next: touch the embed comment in src/Kiroku/Store/Migrations.hs so embedDir picks it up (or run `cabal clean`)."
