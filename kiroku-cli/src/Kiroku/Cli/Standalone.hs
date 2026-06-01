module Kiroku.Cli.Standalone (
    StandaloneOptions (..),
    StandaloneRuntime (..),
    standaloneOptionsParser,
    standaloneParserInfo,
    resolveStandaloneOptions,
    runStandaloneCommand,
) where

import Control.Applicative ((<|>))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Kiroku.Cli.Command (
    KirokuCommand (..),
    RemoteEndpoint (..),
    StatusOptions (..),
    SubscriptionCommand (..),
 )
import Kiroku.Cli.Parser (kirokuCommandParser)
import Kiroku.Cli.Subscription.Status (renderRemoteSubscriptionStatus)
import Options.Applicative (
    Parser,
    ParserInfo,
    fullDesc,
    header,
    helper,
    info,
    progDesc,
    (<**>),
 )

{- | Options for the standalone @kiroku@ binary. The binary is a pure remote
client: it carries only the parsed command (whose @--remote-url@ lives inside
'StatusOptions'); it never opens a store.
-}
newtype StandaloneOptions = StandaloneOptions
    { command :: KirokuCommand
    }
    deriving stock (Generic, Eq, Show)

{- | The resolved command, with any subscription-status endpoint filled in from
@--remote-url@ or @KIROKU_REMOTE_URL@.
-}
newtype StandaloneRuntime = StandaloneRuntime
    { command :: KirokuCommand
    }
    deriving stock (Generic)

standaloneParserInfo :: ParserInfo StandaloneOptions
standaloneParserInfo =
    info
        (standaloneOptionsParser <**> helper)
        ( fullDesc
            <> progDesc
                "Inspect a running Kiroku worker over HTTP. Subscription status queries the worker's \
                \kiroku-metrics /subscriptions endpoint (--remote-url or KIROKU_REMOTE_URL); the binary \
                \opens no store of its own."
            <> header "kiroku - remote operator client for Kiroku event stores"
        )

standaloneOptionsParser :: Parser StandaloneOptions
standaloneOptionsParser =
    StandaloneOptions <$> kirokuCommandParser

{- | Resolve the parsed options into a runnable command. For a subscription-status
command, the endpoint is taken from @--remote-url@ or, failing that, the
@KIROKU_REMOTE_URL@ environment variable; if neither is present, fail with
guidance. Commands that need no endpoint pass through unchanged.
-}
resolveStandaloneOptions :: [(String, String)] -> StandaloneOptions -> Either Text StandaloneRuntime
resolveStandaloneOptions env (StandaloneOptions cmd) =
    case cmd of
        KirokuNoCommand -> Right (StandaloneRuntime KirokuNoCommand)
        KirokuSubscriptions (SubscriptionStatus (StatusOptions format mEndpoint)) ->
            case mEndpoint <|> envEndpoint of
                Just ep ->
                    Right
                        ( StandaloneRuntime
                            (KirokuSubscriptions (SubscriptionStatus (StatusOptions format (Just ep))))
                        )
                Nothing -> Left noEndpointMessage
  where
    envEndpoint =
        case T.pack <$> lookup "KIROKU_REMOTE_URL" env of
            Just url | not (T.null url) -> Just (RemoteEndpoint url)
            _ -> Nothing
    noEndpointMessage =
        "kiroku: no worker endpoint; pass --remote-url or set KIROKU_REMOTE_URL. \
        \The standalone binary inspects a running worker over HTTP; it cannot see \
        \in-process subscriptions because it runs none."

runStandaloneCommand :: StandaloneRuntime -> IO Text
runStandaloneCommand (StandaloneRuntime cmd) =
    case cmd of
        KirokuNoCommand -> pure "No Kiroku operator command was selected."
        KirokuSubscriptions (SubscriptionStatus (StatusOptions format (Just ep))) ->
            renderRemoteSubscriptionStatus ep format
        KirokuSubscriptions (SubscriptionStatus (StatusOptions _ Nothing)) ->
            -- Unreachable: resolveStandaloneOptions fills the endpoint or fails.
            pure
                "kiroku: no worker endpoint; pass --remote-url or set KIROKU_REMOTE_URL."
