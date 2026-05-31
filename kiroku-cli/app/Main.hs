module Main where

import Control.Exception (SomeException, try)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Kiroku.Cli.Standalone (resolveStandaloneOptions, runStandaloneCommand, standaloneParserInfo)
import Options.Applicative (execParser)
import System.Environment (getEnvironment)
import System.Exit (exitFailure)
import System.IO (stderr)

main :: IO ()
main = do
    opts <- execParser standaloneParserInfo
    env <- getEnvironment
    case resolveStandaloneOptions env opts of
        Left err -> do
            TIO.hPutStrLn stderr err
            exitFailure
        Right runtime -> do
            result <- try (runStandaloneCommand runtime)
            case result of
                Left (err :: SomeException) -> do
                    TIO.hPutStrLn stderr ("kiroku: " <> T.pack (show err))
                    exitFailure
                Right output -> TIO.putStrLn output
