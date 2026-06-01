module Main (main) where

import Test.Hspec (hspec)

import Kiroku.Test.Postgres (withSharedMigratedPostgres)
import Test.CollectorSpec qualified as CollectorSpec
import Test.IntegrationSpec qualified as IntegrationSpec
import Test.ServerSpec qualified as ServerSpec
import Test.SubscriptionsSpec qualified as SubscriptionsSpec
import Test.WebSocketSpec qualified as WebSocketSpec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    CollectorSpec.spec
    IntegrationSpec.spec
    ServerSpec.spec
    WebSocketSpec.spec
    SubscriptionsSpec.spec
