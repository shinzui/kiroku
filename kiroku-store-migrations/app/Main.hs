module Main where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrationsNoCheck)

main :: IO ()
main = do
    settings <- getCoddSettings
    _ <- runKirokuMigrationsNoCheck settings (secondsToDiffTime 5)
    pure ()
