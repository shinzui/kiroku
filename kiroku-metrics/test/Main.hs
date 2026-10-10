module Main (main) where

import Test.Hspec (hspec)

import Kiroku.Test.Postgres (withSharedMigratedPostgres)
import Test.CheckpointsSpec qualified as CheckpointsSpec
import Test.CollectorSpec qualified as CollectorSpec
import Test.CorsSpec qualified as CorsSpec
import Test.IntegrationSpec qualified as IntegrationSpec
import Test.ServerSpec qualified as ServerSpec
import Test.SubscriptionsSpec qualified as SubscriptionsSpec
import Test.WebSocketSpec qualified as WebSocketSpec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    CheckpointsSpec.spec
    CorsSpec.spec
    CollectorSpec.spec
    IntegrationSpec.spec
    ServerSpec.spec
    WebSocketSpec.spec
    SubscriptionsSpec.spec
