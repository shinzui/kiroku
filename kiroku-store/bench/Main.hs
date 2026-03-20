module Main where

import Test.Tasty.Bench

main :: IO ()
main =
    defaultMain
        [ bgroup
            "placeholder"
            [ bench "noop" $ nf id ()
            ]
        ]
