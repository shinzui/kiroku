module Kiroku.Cli.Standalone (
    StandaloneOptions (..),
    StandaloneRuntime (..),
    standaloneOptionsParser,
    standaloneParserInfo,
    resolveStandaloneOptions,
    runStandaloneCommand,
) where

import Control.Applicative (optional, (<|>))
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Kiroku.Cli.Command (KirokuCommand (..), OutputFormat (..), StatusOptions (..), SubscriptionCommand (..))
import Kiroku.Cli.Parser (kirokuCommandParser)
import Kiroku.Cli.Subscription.Status (renderSubscriptionStatusRows, subscriptionStatusRows)
import Kiroku.Store (ConnectionSettings, KirokuStore, defaultConnectionSettings, withStore)
import Kiroku.Store.Subscription (subscriptionStates)
import Options.Applicative (
    Parser,
    ParserInfo,
    auto,
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
    value,
    (<**>),
 )

data StandaloneOptions = StandaloneOptions
    { databaseUrl :: !(Maybe Text)
    , schema :: !Text
    , poolSize :: !Int
    , command :: !KirokuCommand
    }
    deriving stock (Generic, Eq, Show)

data StandaloneRuntime = StandaloneRuntime
    { settings :: !ConnectionSettings
    , command :: !KirokuCommand
    }
    deriving stock (Generic)

standaloneParserInfo :: ParserInfo StandaloneOptions
standaloneParserInfo =
    info
        (standaloneOptionsParser <**> helper)
        ( fullDesc
            <> progDesc "Run Kiroku operator commands against a store opened by this process. Subscription status reads this process-local live registry."
            <> header "kiroku - operator commands for Kiroku event stores"
        )

standaloneOptionsParser :: Parser StandaloneOptions
standaloneOptionsParser =
    StandaloneOptions
        <$> optional
            ( strOption
                ( long "database-url"
                    <> metavar "URL"
                    <> help "PostgreSQL connection string. Defaults to KIROKU_DATABASE_URL."
                )
            )
        <*> strOption
            ( long "schema"
                <> metavar "SCHEMA"
                <> value "kiroku"
                <> help "PostgreSQL schema that owns Kiroku objects."
            )
        <*> option
            auto
            ( long "pool-size"
                <> metavar "INT"
                <> value 2
                <> help "Connection pool size for this operator command."
            )
        <*> kirokuCommandParser

resolveStandaloneOptions :: [(String, String)] -> StandaloneOptions -> Either Text StandaloneRuntime
resolveStandaloneOptions env opts
    | opts ^. #poolSize <= 0 = Left "kiroku: --pool-size must be greater than zero"
    | otherwise = do
        conn <- case opts ^. #databaseUrl <|> (T.pack <$> lookup "KIROKU_DATABASE_URL" env) of
            Just connString | not (T.null connString) -> Right connString
            _ -> Left "kiroku: missing database connection string; pass --database-url or set KIROKU_DATABASE_URL"
        pure
            StandaloneRuntime
                { settings =
                    defaultConnectionSettings conn
                        & #schema .~ (opts ^. #schema)
                        & #poolSize .~ (opts ^. #poolSize)
                , command = opts ^. #command
                }

runStandaloneCommand :: StandaloneRuntime -> IO Text
runStandaloneCommand runtime =
    withStore (runtime ^. #settings) $ \store ->
        renderStandaloneCommand store (runtime ^. #command)

renderStandaloneCommand :: KirokuStore -> KirokuCommand -> IO Text
renderStandaloneCommand _ KirokuNoCommand =
    pure "No Kiroku operator command was selected."
renderStandaloneCommand store (KirokuSubscriptions (SubscriptionStatus (StatusOptions format))) = do
    snapshot <- subscriptionStates store
    let rows = subscriptionStatusRows snapshot
        rendered = renderSubscriptionStatusRows format rows
    pure $
        case (format, rows) of
            (OutputTable, []) ->
                rendered
                    <> "No live subscriptions in this process-local registry. Standalone status cannot inspect subscriptions running in another service process."
            _ -> rendered
