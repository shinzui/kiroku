module Kiroku.Cli.Command (
    KirokuCommand (..),
    OutputFormat (..),
    StatusOptions (..),
    SubscriptionCommand (..),
) where

data KirokuCommand
    = KirokuNoCommand
    | KirokuSubscriptions SubscriptionCommand
    deriving stock (Eq, Show)

data SubscriptionCommand
    = SubscriptionStatus StatusOptions
    deriving stock (Eq, Show)

newtype StatusOptions = StatusOptions
    { outputFormat :: OutputFormat
    }
    deriving stock (Eq, Show)

data OutputFormat
    = OutputTable
    | OutputJson
    deriving stock (Eq, Show)
