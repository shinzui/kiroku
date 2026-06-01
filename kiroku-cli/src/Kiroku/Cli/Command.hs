module Kiroku.Cli.Command (
    KirokuCommand (..),
    OutputFormat (..),
    RemoteEndpoint (..),
    StatusOptions (..),
    SubscriptionCommand (..),
) where

import Data.Text (Text)

data KirokuCommand
    = KirokuNoCommand
    | KirokuSubscriptions SubscriptionCommand
    deriving stock (Eq, Show)

data SubscriptionCommand
    = SubscriptionStatus StatusOptions
    deriving stock (Eq, Show)

{- | The base URL of a running worker's @kiroku-metrics@ server (e.g.
@http://worker:9091@), used to query its @\/subscriptions@ endpoint.
-}
newtype RemoteEndpoint = RemoteEndpoint Text
    deriving stock (Eq, Show)

data StatusOptions = StatusOptions
    { outputFormat :: !OutputFormat
    , endpoint :: !(Maybe RemoteEndpoint)
    {- ^ 'Nothing' = read the in-process registry (embeddable library); 'Just' =
    query a remote worker over HTTP.
    -}
    }
    deriving stock (Eq, Show)

data OutputFormat
    = OutputTable
    | OutputJson
    deriving stock (Eq, Show)
