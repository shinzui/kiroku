module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeAsyncException, SomeException, fromException, tryJust)
import Control.Monad (forM_, void)
import Data.Text.IO qualified as TIO
import Options.Applicative (execParser)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hFlush, stderr, stdout)
import System.Posix.Signals (Handler (..), installHandler, sigINT, sigTERM)

import Kiroku.Metrics.Standalone

main :: IO ()
main = do
    opts <- execParser inspectParserInfo
    env <- getEnvironment
    case resolveInspectOptions env opts of
        Left err -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
        Right rt -> do
            done <- newEmptyMVar
            forM_ [sigINT, sigTERM] $ \signal ->
                void (installHandler signal (Catch (void (tryPutMVar done ()))) Nothing)
            let hooks =
                    InspectHooks
                        { onListening = \port caps -> mapM_ TIO.putStrLn (renderStartupBanner rt port caps) >> hFlush stdout
                        , waitForShutdown = takeMVar done >> TIO.putStrLn "kiroku-inspect: shutting down"
                        }
            result <- tryJust synchronousException (runInspect hooks rt)
            case result of
                Left _ -> TIO.hPutStrLn stderr "kiroku-inspect: startup or server failure (details redacted)" >> exitFailure
                Right () -> pure ()

synchronousException :: SomeException -> Maybe SomeException
synchronousException err = case fromException err :: Maybe SomeAsyncException of
    Just _ -> Nothing
    Nothing -> Just err
