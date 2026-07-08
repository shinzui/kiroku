module Main (main) where

import Codd.Extras.WriteSchema (writeExpectedSchemaMain)
import Control.Monad (void)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)

main :: IO ()
main =
    writeExpectedSchemaMain "kiroku" ["kiroku"] "kiroku-store-migrations/expected-schema" $ \settings ->
        void (runKirokuMigrationsNoCheck settings (secondsToDiffTime 5))
