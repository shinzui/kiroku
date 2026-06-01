module Main (main) where

import Test.Hspec (hspec)

import Kiroku.Test.Postgres (withSharedMigratedPostgres)
import Test.CollectorSpec qualified as CollectorSpec
import Test.IntegrationSpec qualified as IntegrationSpec

main :: IO ()
main = withSharedMigratedPostgres $ hspec $ do
    CollectorSpec.spec
    IntegrationSpec.spec
