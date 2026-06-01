module Main (main) where

import Test.Hspec (hspec)

import Test.CollectorSpec qualified as CollectorSpec

main :: IO ()
main = hspec $ do
    CollectorSpec.spec
