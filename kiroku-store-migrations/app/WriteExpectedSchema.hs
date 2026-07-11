module Main (main) where

import Codd.Extras.WriteSchema (writeExpectedSchemaMain)
import Control.Monad (void)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations.LegacyCodd (runLegacyKirokuMigrations)

main :: IO ()
main =
    writeExpectedSchemaMain "kiroku" ["kiroku"] "kiroku-store-migrations/expected-schema" $ \settings ->
        void (runLegacyKirokuMigrations settings (secondsToDiffTime 5))
