module Main (main) where

import Codd.Extras.WriteSchema (writeExpectedSchemaToDisk)
import Control.Monad (void)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)
import System.Environment (getArgs)

main :: IO ()
main = do
    outputDir <- parseArgs =<< getArgs
    writeExpectedSchemaToDisk "kiroku" ["kiroku"] outputDir $ \settings ->
        void (runKirokuMigrationsNoCheck settings (secondsToDiffTime 5))

parseArgs :: [String] -> IO FilePath
parseArgs [] = pure "kiroku-store-migrations/expected-schema"
parseArgs [outputDir] = pure outputDir
parseArgs _ = fail "usage: cabal run kiroku-write-expected-schema -- [output-dir]"
