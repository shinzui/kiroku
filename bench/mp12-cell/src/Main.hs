-- A narrow cell executable using the shared Kenshou executor and run contract.
-- mori://shinzui/keiro-runtime-kenshou/packages/kenshou-remote
module Main (main) where

import Data.Aeson qualified as Json
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Kenshou.Core.Bundle (mkRegistry)
import Kenshou.Core.Id (parseRunId)
import Kenshou.Core.Run (RunOutput (..), RunnerConfig (..), executeRun)
import Kenshou.Core.RunResult (RunResult (..))
import Kenshou.Core.RunSpec qualified as Spec
import Kenshou.Remote.Cell.Exec (cellExec)
import System.Environment (getArgs, getEnv)
import System.Exit (ExitCode (..), exitWith)
import Workload (bundle)

main :: IO ()
main = do
    registry <- either (fail . show) pure (mkRegistry [bundle])
    args <- getArgs
    code <- case args of
        ["cell", "exec", work, out] -> cellExec registry work out
        "run" : options -> do
            let option key = case dropWhile (/= key) options of
                    _ : value : _ -> pure value
                    _ -> fail ("missing " <> key)
            spec <- option "--spec" >>= readJson
            out <- option "--out"
            identifier <- option "--run-id" >>= either (fail . Text.unpack) pure . parseRunId . Text.pack
            cohort <- getEnv "KENSHOU_COHORT_IDENTITY" >>= readJson
            fingerprint <- case dropWhile (/= "--cell-fingerprint") options of
                _ : file : _ -> Just <$> readJson file
                _ -> pure Nothing
            result <- executeRun (RunnerConfig registry out cohort fingerprint False True args) (spec{Spec.runId = Just identifier})
            case result of
                Left errors -> fail (show (NonEmpty.toList errors))
                Right output -> pure (if output.result.exitCode == 0 then ExitSuccess else ExitFailure output.result.exitCode)
        _ -> fail "usage: kenshou cell exec WORK OUT | kenshou run --spec FILE --out DIR --run-id UUID"
    exitWith code

readJson :: (Json.FromJSON a) => FilePath -> IO a
readJson file = Json.eitherDecodeFileStrict' file >>= either fail pure
