module Kiroku.Cli (
    KirokuCommand (..),
    kirokuCommandParser,
    kirokuParserInfo,
    kirokuSubparser,
    runKirokuCommand,
) where

import Kiroku.Cli.Command (KirokuCommand (..))
import Kiroku.Cli.Parser (kirokuCommandParser, kirokuParserInfo, kirokuSubparser)
import Kiroku.Cli.Run (runKirokuCommand)
