module Main (main) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (bracket)
import Control.Monad (void)
import InspectSignals (withInspectSignals)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import Test.Hspec (hspec)

import Kiroku.Test.Postgres (withSharedMigratedPostgres)
import Test.BrowseSpec qualified as BrowseSpec
import Test.CapabilitiesSpec qualified as CapabilitiesSpec
import Test.CheckpointsSpec qualified as CheckpointsSpec
import Test.CollectorSpec qualified as CollectorSpec
import Test.CorsSpec qualified as CorsSpec
import Test.DeadLettersSpec qualified as DeadLettersSpec
import Test.IntegrationSpec qualified as IntegrationSpec
import Test.ServerSpec qualified as ServerSpec
import Test.StandaloneSpec qualified as StandaloneSpec
import Test.SubscriptionsSpec qualified as SubscriptionsSpec
import Test.WebSocketConvergenceSpec qualified as WebSocketConvergenceSpec
import Test.WebSocketSpec qualified as WebSocketSpec

main :: IO ()
main = do
  args <- getArgs
  if args == ["--inspect-signal-fixture"] then signalFixture else runSpecs

signalFixture :: IO ()
signalFixture = do
  done <- newEmptyMVar
  never <- newEmptyMVar
  withInspectSignals (void (tryPutMVar done ())) $
    bracket
      (putStrLn "READY" >> hFlush stdout)
      (\() -> putStrLn "SHUTTING_DOWN" >> hFlush stdout >> takeMVar never)
      (\() -> takeMVar done)

runSpecs :: IO ()
runSpecs = withSharedMigratedPostgres $ hspec $ do
  StandaloneSpec.spec
  CapabilitiesSpec.spec
  BrowseSpec.spec
  CheckpointsSpec.spec
  DeadLettersSpec.spec
  CorsSpec.spec
  CollectorSpec.spec
  IntegrationSpec.spec
  ServerSpec.spec
  WebSocketConvergenceSpec.spec
  WebSocketSpec.spec
  SubscriptionsSpec.spec
