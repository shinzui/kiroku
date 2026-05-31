module Kiroku.Cli.Parser (
    kirokuCommandParser,
    kirokuParserInfo,
    kirokuSubparser,
) where

import Kiroku.Cli.Command (KirokuCommand (..))
import Options.Applicative (
    CommandFields,
    Mod,
    Parser,
    ParserInfo,
    command,
    fullDesc,
    header,
    helper,
    info,
    progDesc,
    (<**>),
 )

kirokuCommandParser :: Parser KirokuCommand
kirokuCommandParser =
    pure KirokuNoCommand

kirokuParserInfo :: ParserInfo KirokuCommand
kirokuParserInfo =
    info
        (kirokuCommandParser <**> helper)
        ( fullDesc
            <> progDesc "Run Kiroku operator commands."
            <> header "kiroku - operator commands for Kiroku event stores"
        )

kirokuSubparser :: (KirokuCommand -> command) -> Mod CommandFields command
kirokuSubparser wrap =
    command
        "kiroku"
        ( info
            (wrap <$> kirokuCommandParser <**> helper)
            ( fullDesc
                <> progDesc "Run Kiroku operator commands."
            )
        )
