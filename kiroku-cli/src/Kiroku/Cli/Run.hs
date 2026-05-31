module Kiroku.Cli.Run (
    runKirokuCommand,
) where

import Kiroku.Cli.Command (KirokuCommand (..))

runKirokuCommand :: KirokuCommand -> IO ()
runKirokuCommand KirokuNoCommand =
    putStrLn "No Kiroku operator command was selected."
