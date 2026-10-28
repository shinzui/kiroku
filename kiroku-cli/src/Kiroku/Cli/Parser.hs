module Kiroku.Cli.Parser
  ( kirokuCommandParser,
    kirokuParserInfo,
    kirokuSubparser,
  )
where

import Control.Applicative (optional)
import Data.Text qualified as T
import Kiroku.Cli.Command (KirokuCommand (..))
import Kiroku.Cli.Command qualified as Command
import Options.Applicative
  ( CommandFields,
    Mod,
    Parser,
    ParserInfo,
    auto,
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
    strOption,
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
              <> command "compaction" (info (KirokuCompaction <$> compactionCommandParser) (fullDesc <> progDesc "Preview, apply, or audit a selective compaction manifest (embeddable only)."))
              <> command "store" (info (KirokuStore <$> storeCommandParser) (fullDesc <> progDesc "Inspect the live store identity (embeddable only)."))
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
    <*> optional
      ( Command.RemoteEndpoint . T.pack
          <$> strOption
            ( long "remote-url"
                <> metavar "URL"
                <> help
                  "Query a running worker's kiroku-metrics /subscriptions endpoint \
                  \(e.g. http://worker:9091) instead of this process's local registry."
            )
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

compactionCommandParser :: Parser Command.CompactionCommand
compactionCommandParser =
  subparser
    ( command "preview" (info (Command.CompactionPreview <$> (Command.CompactionOptions <$> manifestPathParser <*> outputFormatParser) <**> helper) (progDesc "Validate a manifest without changing any rows."))
        <> command "apply" (info (Command.CompactionApply <$> (Command.ApplyOptions <$> manifestPathParser <*> (T.pack <$> strOption (long "confirm-digest" <> metavar "HEX" <> help "Reviewed manifest digest; must match the file.")) <*> outputFormatParser) <**> helper) (progDesc "Apply an explicitly confirmed manifest atomically."))
        <> command "ledger" (info (Command.CompactionLedger <$> (Command.LedgerOptions <$> option auto (long "limit" <> metavar "N" <> value 50 <> help "Newest records to show (1–1000).") <*> outputFormatParser) <**> helper) (progDesc "List durable compaction audit records."))
    )

storeCommandParser :: Parser Command.StoreCommand
storeCommandParser = subparser (command "identity" (info (Command.ShowStoreIdentity . Command.IdentityOptions <$> outputFormatParser <**> helper) (progDesc "Read this store's immutable identity.")))

manifestPathParser :: Parser Command.ManifestPath
manifestPathParser = Command.ManifestPath <$> strOption (long "manifest" <> metavar "FILE" <> help "Digest-sealed compaction manifest JSON file.")

outputFormatParser :: Parser Command.OutputFormat
outputFormatParser = option (eitherReader parseOutputFormat) (long "format" <> metavar "table|json" <> value Command.OutputTable <> help "Render a human table or JSON.")
