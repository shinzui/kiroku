-- Registry metadata shared with the dedicated payload. The historical cohort
-- cannot implement the new APIs; a matched payload supplies the run function.
-- mori://shinzui/kiroku/plans/54-add-prefix-matching-subscription-target-for-fan-in-subscriptions
module Metadata (scenario, bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Kenshou.Core.Dimension
import Kenshou.Core.Env
import Kenshou.Core.Id (Kind (..), Layer (..), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase qualified as CorePhase
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (measureKnobs)

name :: Text -> KnobName
name = either (error . show) id . mkKnobName

bundle :: LayerBundle
bundle = LayerBundle Kiroku [scenario] []

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/benchmark/category-namespace"),
      revision = 1,
      summary = "Compares cumulative durable writes and inspection with namespace delivery disabled or active.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs =
        measureKnobs Benchmark
          <> [KnobSpec (name "ep54.mode") "Namespace comparison case" KnobText (VText "disabled") (OneOf (VText "disabled" :| [VText "active"])) []],
      dimensions =
        DimensionSupport
          (Supported (Support (TracingOff :| []) TracingOff))
          (Supported (Support (MetricsOff :| []) MetricsOff))
          (Supported (Support (PgDurable :| []) PgDurable))
          (Supported (Support (Pg18 :| [Pg17]) Pg18)),
      phases = CorePhase.PhasePlan 10 30 30,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [("shared_preload_libraries", "'pg_stat_statements'")] False)},
      knownDefect = Nothing,
      run = \_ -> pure (infrastructureFailureBecause "requires the matched Plan 54 cell payload")
    }
