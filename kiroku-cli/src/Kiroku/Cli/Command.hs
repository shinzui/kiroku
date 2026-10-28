module Kiroku.Cli.Command
  ( KirokuCommand (..),
    OutputFormat (..),
    RemoteEndpoint (..),
    StatusOptions (..),
    SubscriptionCommand (..),
    CompactionCommand (..),
    StoreCommand (..),
    ManifestPath (..),
    CompactionOptions (..),
    ApplyOptions (..),
    LedgerOptions (..),
    IdentityOptions (..),
  )
where

import Data.Int (Int32)
import Data.Text (Text)

data KirokuCommand
  = KirokuNoCommand
  | KirokuSubscriptions SubscriptionCommand
  | KirokuCompaction CompactionCommand
  | KirokuStore StoreCommand
  deriving stock (Eq, Show)

data SubscriptionCommand
  = SubscriptionStatus StatusOptions
  deriving stock (Eq, Show)

-- | The base URL of a running worker's @kiroku-metrics@ server (e.g.
-- @http://worker:9091@), used to query its @\/subscriptions@ endpoint.
newtype RemoteEndpoint = RemoteEndpoint Text
  deriving stock (Eq, Show)

data StatusOptions = StatusOptions
  { outputFormat :: !OutputFormat,
    -- | 'Nothing' = read the in-process registry (embeddable library); 'Just' =
    --     query a remote worker over HTTP.
    endpoint :: !(Maybe RemoteEndpoint)
  }
  deriving stock (Eq, Show)

data OutputFormat
  = OutputTable
  | OutputJson
  deriving stock (Eq, Show)

-- | Maintenance commands run only in a host that owns a live store.
data CompactionCommand
  = CompactionPreview CompactionOptions
  | CompactionApply ApplyOptions
  | CompactionLedger LedgerOptions
  deriving stock (Eq, Show)

data StoreCommand = ShowStoreIdentity IdentityOptions
  deriving stock (Eq, Show)

newtype ManifestPath = ManifestPath FilePath
  deriving stock (Eq, Show)

data CompactionOptions = CompactionOptions
  {manifestPath :: !ManifestPath, outputFormat :: !OutputFormat}
  deriving stock (Eq, Show)

data ApplyOptions = ApplyOptions
  {manifestPath :: !ManifestPath, confirmDigest :: !Text, outputFormat :: !OutputFormat}
  deriving stock (Eq, Show)

data LedgerOptions = LedgerOptions
  {limit :: !Int32, outputFormat :: !OutputFormat}
  deriving stock (Eq, Show)

newtype IdentityOptions = IdentityOptions {outputFormat :: OutputFormat}
  deriving stock (Eq, Show)
