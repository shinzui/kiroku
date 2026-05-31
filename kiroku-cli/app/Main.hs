module Main where

import Kiroku.Cli (kirokuParserInfo, runKirokuCommand)
import Options.Applicative (execParser)

main :: IO ()
main =
    execParser kirokuParserInfo >>= runKirokuCommand
