module Kiroku.Cli.Parser (
    kirokuCommandParser,
    kirokuParserInfo,
    kirokuSubparser,
) where

import Control.Applicative (optional)
import Kiroku.Cli.Command (KirokuCommand (..))
import Kiroku.Cli.Command qualified as Command
import Options.Applicative (
    CommandFields,
    Mod,
    Parser,
    ParserInfo,
    command,
    eitherReader,
    fullDesc,
    header,
    help,
    helper,
    info,
    long,
    metavar,
    option,
    progDesc,
    subparser,
    value,
    (<**>),
 )

kirokuCommandParser :: Parser KirokuCommand
kirokuCommandParser =
    maybe KirokuNoCommand id
        <$> optional
            ( subparser
                ( command
                    "subscriptions"
                    ( info
                        (KirokuSubscriptions <$> subscriptionCommandParser)
                        (fullDesc <> progDesc "Inspect live subscriptions in this process's KirokuStore registry.")
                    )
                )
            )

subscriptionCommandParser :: Parser Command.SubscriptionCommand
subscriptionCommandParser =
    subparser
        ( command
            "status"
            ( info
                (Command.SubscriptionStatus <$> statusOptionsParser <**> helper)
                (fullDesc <> progDesc "List live subscription phases and global cursor positions.")
            )
        )

statusOptionsParser :: Parser Command.StatusOptions
statusOptionsParser =
    Command.StatusOptions
        <$> option
            (eitherReader parseOutputFormat)
            ( long "format"
                <> metavar "table|json"
                <> value Command.OutputTable
                <> help "Render as a human table or script-friendly JSON."
            )

parseOutputFormat :: String -> Either String Command.OutputFormat
parseOutputFormat "table" = Right Command.OutputTable
parseOutputFormat "json" = Right Command.OutputJson
parseOutputFormat other = Left ("unsupported output format " <> show other <> "; expected table or json")

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
