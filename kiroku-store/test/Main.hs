module Main where

import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "Kiroku.Store" $ do
        it "placeholder" $ do
            True `shouldBe` True
