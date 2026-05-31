module Main where

import Data.List (isInfixOf)
import Kiroku.Cli (KirokuCommand (..), kirokuParserInfo, kirokuSubparser)
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

        describe "kirokuSubparser" $ do
            it "parses as a nested host command" $ do
                case execParserPure defaultPrefs hostParserInfo ["kiroku"] of
                    Success parsed -> parsed `shouldBe` HostKiroku KirokuNoCommand
                    other -> expectationFailure ("expected parser success, got " <> renderedHelp other)

            it "renders nested help under a host command parser" $ do
                let result = execParserPure defaultPrefs hostParserInfo ["kiroku", "--help"]
                renderedHelp result `shouldSatisfy` isInfixOf "Run Kiroku operator commands."

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
