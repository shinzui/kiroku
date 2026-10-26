module Main (main) where

import Kenshou.Cli.Registry qualified as Registry
import Kenshou.Core.Cli (runCli)
import Metadata (bundle)
import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main = getArgs >>= runCli (bundle : Registry.bundles) Registry.commands Registry.topics >>= exitWith
