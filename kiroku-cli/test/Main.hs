module Main where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Int (Int32, Int64)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Kiroku.Cli (KirokuCommand (..), kirokuParserInfo, kirokuSubparser, renderKirokuCommandWithStore)
import Kiroku.Cli.Command (OutputFormat (..), StatusOptions (..), SubscriptionCommand (..))
import Kiroku.Cli.Subscription.Status (SubscriptionStatusRow (..), renderSubscriptionStatusRows, subscriptionStatusRows)
import Kiroku.Store
import Kiroku.Store.Subscription.Fsm (SubscriptionState (..))
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import Options.Applicative (
    Parser,
    ParserInfo,
    ParserResult (..),
    command,
    defaultPrefs,
    execParserPure,
    fullDesc,
    helper,
    info,
    progDesc,
    renderFailure,
    subparser,
    (<**>),
 )
import Test.Hspec

data HostCommand
    = HostOnly
    | HostKiroku KirokuCommand
    deriving stock (Eq, Show)

main :: IO ()
main =
    hspec $ do
        describe "kirokuParserInfo" $ do
            it "renders top-level help" $ do
                let result = execParserPure defaultPrefs kirokuParserInfo ["--help"]
                renderedHelp result `shouldSatisfy` isInfixOf "operator commands for Kiroku"

            it "parses subscriptions status with the default table format" $ do
                case execParserPure defaultPrefs kirokuParserInfo ["subscriptions", "status"] of
                    Success parsed ->
                        parsed `shouldBe` KirokuSubscriptions (SubscriptionStatus (StatusOptions OutputTable))
                    other -> expectationFailure ("expected parser success, got " <> renderedHelp other)

            it "parses subscriptions status with JSON output" $ do
                case execParserPure defaultPrefs kirokuParserInfo ["subscriptions", "status", "--format", "json"] of
                    Success parsed ->
                        parsed `shouldBe` KirokuSubscriptions (SubscriptionStatus (StatusOptions OutputJson))
                    other -> expectationFailure ("expected parser success, got " <> renderedHelp other)

            it "renders status help" $ do
                let result = execParserPure defaultPrefs kirokuParserInfo ["subscriptions", "status", "--help"]
                renderedHelp result `shouldSatisfy` isInfixOf "List live subscription phases"

        describe "kirokuSubparser" $ do
            it "parses as a nested host command" $ do
                case execParserPure defaultPrefs hostParserInfo ["kiroku"] of
                    Success parsed -> parsed `shouldBe` HostKiroku KirokuNoCommand
                    other -> expectationFailure ("expected parser success, got " <> renderedHelp other)

            it "renders nested help under a host command parser" $ do
                let result = execParserPure defaultPrefs hostParserInfo ["kiroku", "--help"]
                renderedHelp result `shouldSatisfy` isInfixOf "Run Kiroku operator commands."

        describe "subscriptionStatusRows" $ do
            it "sorts rows and extracts public scalar fields" $ do
                subscriptionStatusRows
                    ( Map.fromList
                        [ ((SubscriptionName "beta", 1), view "beta" 1 "live" 42)
                        , ((SubscriptionName "alpha", 0), view "alpha" 0 "catching_up" 7)
                        ]
                    )
                    `shouldBe` [ SubscriptionStatusRow "alpha" 0 "catching_up" 7
                               , SubscriptionStatusRow "beta" 1 "live" 42
                               ]

        describe "renderSubscriptionStatusRows" $ do
            it "renders a header for an empty table" $ do
                renderSubscriptionStatusRows OutputTable []
                    `shouldBe` "SUBSCRIPTION  MEMBER  PHASE  GLOBAL_POSITION\n"

            it "renders table rows" $ do
                renderSubscriptionStatusRows OutputTable [SubscriptionStatusRow "alpha" 0 "live" 12]
                    `shouldSatisfy` T.isInfixOf "alpha         0       live   12"

            it "renders script-friendly JSON" $ do
                Aeson.eitherDecodeStrictText (renderSubscriptionStatusRows OutputJson [SubscriptionStatusRow "alpha" 0 "live" 12])
                    `shouldBe` Right
                        [ Aeson.object
                            [ "subscription" Aeson..= ("alpha" :: Text)
                            , "member" Aeson..= (0 :: Int)
                            , "phase" Aeson..= ("live" :: Text)
                            , "global_position" Aeson..= (12 :: Int)
                            ]
                        ]

        describe "renderKirokuCommandWithStore" $ do
            it "renders status from a live KirokuStore registry" $
                withTestStore $ \store -> do
                    let name = SubscriptionName "cli-registry"
                    Right _ <- runStoreIO store $ appendToStream (StreamName "cli-registry-1") NoStream [makeEvent "A" (Aeson.object [])]
                    handle <- subscribe store (defaultSubscriptionConfig name AllStreams (\_ -> pure Continue))
                    live <- waitUntilPhase 5_000_000 store (name, 0) "live"
                    live `shouldBe` True
                    output <-
                        renderKirokuCommandWithStore
                            store
                            (KirokuSubscriptions (SubscriptionStatus (StatusOptions OutputTable)))
                    output `shouldSatisfy` T.isInfixOf "cli-registry"
                    output `shouldSatisfy` T.isInfixOf "live"
                    output `shouldSatisfy` T.isInfixOf "0"
                    cancel handle

hostParserInfo :: ParserInfo HostCommand
hostParserInfo =
    info
        (hostCommandParser <**> helper)
        (fullDesc <> progDesc "Fake host CLI used to prove parser embedding.")

hostCommandParser :: Parser HostCommand
hostCommandParser =
    subparser
        ( command
            "host"
            (info (pure HostOnly) (progDesc "Run a host-only command."))
            <> kirokuSubparser HostKiroku
        )

renderedHelp :: ParserResult a -> String
renderedHelp (Failure failure) =
    fst (renderFailure failure "test")
renderedHelp (Success _) =
    ""
renderedHelp (CompletionInvoked _) =
    ""

view :: Text -> Int32 -> Text -> Int64 -> SubscriptionStateView
view name member phase position =
    SubscriptionStateView
        { subscriptionName = SubscriptionName name
        , member = member
        , state = Live (GlobalPosition position)
        , statePhase = phase
        , cursor = GlobalPosition position
        }

withTestStore :: (KirokuStore -> IO ()) -> IO ()
withTestStore action =
    withMigratedTestDatabase $ \connStr ->
        withStore (defaultConnectionSettings connStr) action

makeEvent :: Text -> Aeson.Value -> EventData
makeEvent typ payload =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = payload
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }

waitUntilPhase :: Int -> KirokuStore -> (SubscriptionName, Int32) -> Text -> IO Bool
waitUntilPhase budget store key phase
    | budget <= 0 = pure False
    | otherwise = do
        snapshot <- subscriptionStates store
        case Map.lookup key snapshot of
            Just status | statePhase status == phase -> pure True
            _ -> do
                threadDelay 20_000
                waitUntilPhase (budget - 20_000) store key phase
