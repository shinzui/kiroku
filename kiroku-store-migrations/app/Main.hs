module Main where

import Codd (VerifySchemas (LaxCheck))
import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Kiroku.Store.Migrations (runKirokuMigrations)

main :: IO ()
main = do
    settings <- getCoddSettings
    _ <- runKirokuMigrations settings (secondsToDiffTime 5) LaxCheck
    pure ()
