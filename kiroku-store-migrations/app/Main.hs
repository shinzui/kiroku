module Main where

import Codd (CoddSettings (..))
import Codd.Environment (getCoddSettings)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.List (isSuffixOf, sort)
import Data.Maybe (fromMaybe)
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, secondsToDiffTime)
import Kiroku.Store.Migrations (
    LedgerSchema (..),
    MigrationStatus (..),
    VerifyOutcome (..),
    migrationStatus,
    runKirokuMigrationsNoCheck,
    verifySchema,
 )
import Kiroku.Store.Migrations.Guards (renderChecksumManifest)
import Kiroku.Store.Migrations.New (defaultMigrationsDir, newMigrationFile)
import System.Directory (listDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> migrate
        ["up"] -> migrate
        ["verify"] -> verify
        ["status"] -> status
        ("new" : rest) -> generate (unwords rest)
        ("lock" : _) -> writeLock
        other -> usage other

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

writeLock :: IO ()
writeLock = do
    dir <- fromMaybe defaultMigrationsDir <$> lookupEnv "KIROKU_MIGRATIONS_DIR"
    names <- filter (".sql" `isSuffixOf`) <$> listDirectory dir
    sources <- traverse (\name -> (\bytes -> (name, bytes)) <$> BS.readFile (dir <> "/" <> name)) (sort names)
    TIO.writeFile "migrations.lock" (renderChecksumManifest sources)
    putStrLn ("Wrote migrations.lock (" <> show (length sources) <> " migrations)")

status :: IO ()
status = do
    settings <- getCoddSettings
    migrationStatus (migsConnString settings) (secondsToDiffTime 5) >>= printStatus

verify :: IO ()
verify = do
    settings <- getCoddSettings
    outcome <- verifySchema settings (secondsToDiffTime 5)
    case outcome of
        VerifySucceeded -> putStrLn "Schema matches expected snapshot."
        VerifyFailed -> exitWith (ExitFailure 1)
        VerifyPending pending -> do
            hPutStrLn stderr "Cannot verify while migrations are pending:"
            traverse_ (hPutStrLn stderr . ("  " <>)) pending
            exitWith (ExitFailure 2)

printStatus :: MigrationStatus -> IO ()
printStatus MigrationStatus{statusLedgerSchema, statusApplied, statusPending} = do
    putStrLn ("Ledger: " <> maybe "not found" renderLedgerSchema statusLedgerSchema)
    putStrLn ("Applied (" <> show (length statusApplied) <> "):")
    traverse_ printApplied statusApplied
    putStrLn ("Pending (" <> show (length statusPending) <> "):")
    traverse_ (putStrLn . ("  " <>)) statusPending
    putStrLn ("applied " <> show (length statusApplied) <> ", pending " <> show (length statusPending))

renderLedgerSchema :: LedgerSchema -> String
renderLedgerSchema CoddLedger = "codd.sql_migrations"
renderLedgerSchema CoddSchemaLedger = "codd_schema.sql_migrations"

printApplied :: (FilePath, UTCTime) -> IO ()
printApplied (name, timestamp) =
    putStrLn ("  " <> name <> "   " <> show timestamp)

usage :: [String] -> IO ()
usage args = do
    hPutStrLn stderr ("unknown kiroku-store-migrate arguments: " <> unwords args)
    hPutStrLn stderr "usage: kiroku-store-migrate [up | verify | status | new <description> | lock]"
    exitWith (ExitFailure 2)
