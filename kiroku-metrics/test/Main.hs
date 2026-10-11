module Main (main) where

import Test.Hspec (hspec)

import Kiroku.Test.Postgres (withSharedMigratedPostgres)
import Test.BrowseSpec qualified as BrowseSpec
import Test.CheckpointsSpec qualified as CheckpointsSpec
import Test.CollectorSpec qualified as CollectorSpec
import Test.CorsSpec qualified as CorsSpec
import Test.DeadLettersSpec qualified as DeadLettersSpec
import Test.IntegrationSpec qualified as IntegrationSpec
import Test.ServerSpec qualified as ServerSpec
import Test.SubscriptionsSpec qualified as SubscriptionsSpec
import Test.WebSocketConvergenceSpec qualified as WebSocketConvergenceSpec
import Test.WebSocketSpec qualified as WebSocketSpec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
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
