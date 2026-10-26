{-# LANGUAGE CPP #-}

-- Kenshou owns measurement health, recording, and the cell run contract.
-- The shared producer and separate observer retain the inspection oracle.
module Workload (bundle) where

import Control.Monad (when)
import Data.Aeson qualified as Json
import Data.Text qualified as Text
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context qualified as Core
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario
import Kenshou.Measure.Phase qualified as Phase
import Kenshou.Measure.Recorder qualified as Recorder
import Kenshou.Measure.Session qualified as Measure
import Metadata qualified
import Probe qualified
import System.Directory (doesFileExist)
import System.Environment (setEnv)
import System.FilePath ((</>))

bundle :: LayerBundle
bundle = Metadata.bundle {scenarios = [Metadata.scenario {run = runWorkload}]}

arm :: String
#ifdef EP54_NAMESPACE
arm = "candidate"
#else
arm = "control"
#endif

runWorkload :: Core.RunContext -> IO ScenarioReport
runWorkload context = do
  let name = either (error . show) id (mkKnobName "ep54.mode")
      mode = Text.unpack (knobText context.knobs name)
      output = context.outDir </> "namespace-trial.json"
  setEnv "MP13_DATABASE_URL" (Text.unpack (Core.requirePostgres context).connectionString)
  setEnv "MP13_SQL_STATS_REQUIRED" "1"
  setEnv "MP13_WARMUP_SECONDS" (show (floor context.phases.warmUpSeconds :: Int))
  setEnv "MP13_MEASUREMENT_SECONDS" (show (floor context.phases.steadySeconds :: Int))
  setEnv "EP54_NAMESPACE" "1"
  config <- either (fail . Text.unpack) pure (Measure.measureConfigFromKnobs context (Measure.phasePlanFromCore context.phases))
  (_, report) <- Measure.withMeasurement context config $ \measurement -> do
    handle <- Recorder.registerOp (Measure.measurementRecorder measurement) (Recorder.OpName "append")
    workers <- mapM (Recorder.newWorkerRecorder handle) [0 .. 3]
    let record worker start finish _ = Recorder.recordOp (workers !! worker) start start finish (Recorder.OpOk 1)
        phase steady action = do
          Phase.enterPhase (Measure.measurementPhaseClock measurement) (if steady then Phase.Steady else Phase.WarmUp)
          result <- Core.withPhase context (if steady then CorePhase.Steady else CorePhase.WarmUp) action
          when steady $ Phase.enterPhase (Measure.measurementPhaseClock measurement) Phase.Drain
          pure result
    Probe.trialWith record phase arm mode output
    Phase.enterPhase (Measure.measurementPhaseClock measurement) Phase.Drain
    Core.withPhase context CorePhase.Drain (pure ())
  trial <- Json.eitherDecodeFileStrict' output >>= either fail pure
  Core.putSummary context Core.Measurements "namespace-comparison" (trial :: Json.Value)
  Core.declareMediaType context "namespace-trial.json" "application/json"
  observer <- doesFileExist (output <> ".observer.json")
  when observer $ Core.declareMediaType context "namespace-trial.json.observer.json" "application/json"
  pure (passed {outcome = Measure.measuredOutcome report passed.outcome})
