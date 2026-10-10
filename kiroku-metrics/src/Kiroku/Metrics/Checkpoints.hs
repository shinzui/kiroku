-- | Read-only durable checkpoint inventory, independent of the live registry.
module Kiroku.Metrics.Checkpoints (
    CheckpointInventoryProvider,
    storeCheckpointInventory,
    CheckpointInventoryResponse (..),
    CheckpointRow (..),
    checkpointInventoryResponse,
    checkpointsPath,
    checkpointsApp,
    checkpointsNotConfiguredApp,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), encode, object, withObject, (.:), (.=))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Vector qualified as V
import Network.HTTP.Types (status200, status404, status405)
import Network.Wai (Application, Response, mapResponseHeaders, pathInfo, requestMethod, responseHeaders, responseLBS, responseStatus)

import Kiroku.Metrics.JSON (errorResponse, jsonResponse, storeErrorResponse)
import Kiroku.Store (GlobalPosition (..), KirokuStore, StoreError, SubscriptionCheckpoint (..), SubscriptionCheckpointInventory (..), SubscriptionName (..), runStoreIO, subscriptionCheckpointInventory)

{- | One call reads the frontier and all checkpoint rows in one SQL snapshot.
Inventory work is proportional to row count; clients should not overlap polls.
-}
type CheckpointInventoryProvider = IO (Either StoreError SubscriptionCheckpointInventory)

storeCheckpointInventory :: KirokuStore -> CheckpointInventoryProvider
storeCheckpointInventory store = runStoreIO store subscriptionCheckpointInventory

data CheckpointRow = CheckpointRow
    { subscription :: !Text
    , member :: !Int32
    , checkpointPosition :: !Int64
    , updatedAt :: !UTCTime
    }
    deriving stock (Eq, Show)

data CheckpointInventoryResponse = CheckpointInventoryResponse
    { storePosition :: !Int64
    , checkpoints :: ![CheckpointRow]
    }
    deriving stock (Eq, Show)

instance ToJSON CheckpointRow where
    toJSON row = object ["subscription" .= row.subscription, "member" .= row.member, "checkpoint_position" .= row.checkpointPosition, "updated_at" .= row.updatedAt]

instance FromJSON CheckpointRow where
    parseJSON = withObject "CheckpointRow" $ \o -> CheckpointRow <$> o .: "subscription" <*> o .: "member" <*> o .: "checkpoint_position" <*> o .: "updated_at"

instance ToJSON CheckpointInventoryResponse where
    toJSON inventory = object ["store_position" .= inventory.storePosition, "checkpoints" .= inventory.checkpoints]

instance FromJSON CheckpointInventoryResponse where
    parseJSON = withObject "CheckpointInventoryResponse" $ \o -> CheckpointInventoryResponse <$> o .: "store_position" <*> o .: "checkpoints"

checkpointInventoryResponse :: SubscriptionCheckpointInventory -> CheckpointInventoryResponse
checkpointInventoryResponse (SubscriptionCheckpointInventory (GlobalPosition position) rows) =
    CheckpointInventoryResponse position (map toRow (V.toList rows))
  where
    toRow (SubscriptionCheckpoint (SubscriptionName name) index (GlobalPosition cp) updated) = CheckpointRow name index cp updated

checkpointsPath :: [Text]
checkpointsPath = ["subscription-checkpoints"]

{- | GET and HEAD only. Unknown query parameters are ignored. Expected store
failures are sanitized; thrown exceptions (including cancellation) propagate.
-}
checkpointsApp :: CheckpointInventoryProvider -> Application
checkpointsApp provider = checkpointsResponseApp $ either (storeErrorResponse "checkpoint_inventory_unavailable") (jsonResponse status200 . encode . checkpointInventoryResponse) <$> provider

-- | Same method and HEAD behavior when a server has no inventory provider.
checkpointsNotConfiguredApp :: Application
checkpointsNotConfiguredApp = checkpointsResponseApp $ pure $ errorResponse status404 "checkpoint_inventory_not_configured" "Durable checkpoint inventory is not configured." Nothing

checkpointsResponseApp :: IO Response -> Application
checkpointsResponseApp readResponse req respond = do
    response <-
        if pathInfo req /= checkpointsPath
            then pure $ errorResponse status404 "not_found" "Not found" Nothing
            else
                if requestMethod req `notElem` ["GET", "HEAD"]
                    then pure $ mapResponseHeaders (("Allow", "GET, HEAD") :) $ errorResponse status405 "method_not_allowed" "Use GET or HEAD." Nothing
                    else readResponse
    respond $
        if requestMethod req == "HEAD"
            then responseLBS (responseStatus response) (responseHeaders response) ""
            else response
