{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.Subscription.CheckpointInventory.SQL (
    getSubscriptionCheckpointInventoryStmt,
) where

import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Statement qualified as Statement
import Kiroku.Store.Subscription.Types (
    SubscriptionCheckpoint (..),
    SubscriptionCheckpointInventory (..),
    SubscriptionName (..),
 )
import Kiroku.Store.Types (GlobalPosition (..))

data InventoryRow = InventoryRow
    { rowStorePosition :: !Int64
    , rowSubscriptionName :: !(Maybe Text)
    , rowConsumerGroupMember :: !(Maybe Int32)
    , rowCheckpointPosition :: !(Maybe Int64)
    , rowCheckpointUpdatedAt :: !(Maybe UTCTime)
    }

getSubscriptionCheckpointInventoryStmt :: Statement () SubscriptionCheckpointInventory
getSubscriptionCheckpointInventoryStmt =
    Statement.refineResult finalizeInventory $
        preparable
            """
            SELECT store_head.stream_version,
                   checkpoint.subscription_name,
                   checkpoint.consumer_group_member,
                   checkpoint.last_seen,
                   checkpoint.updated_at
            FROM streams AS store_head
            LEFT JOIN subscriptions AS checkpoint ON TRUE
            WHERE store_head.stream_id = 0
            ORDER BY checkpoint.subscription_name ASC,
                     checkpoint.consumer_group_member ASC
            """
            E.noParams
            (D.rowVector inventoryRow)

inventoryRow :: D.Row InventoryRow
inventoryRow =
    InventoryRow
        <$> D.column (D.nonNullable D.int8)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nullable D.int4)
        <*> D.column (D.nullable D.int8)
        <*> D.column (D.nullable D.timestamptz)

finalizeInventory :: Vector InventoryRow -> Either Text SubscriptionCheckpointInventory
finalizeInventory rows = case V.uncons rows of
    Nothing -> Left "subscription checkpoint inventory: missing $all stream row"
    Just (firstRow, remainingRows) ->
        let capturedPosition = rowStorePosition firstRow
         in case checkpointColumns firstRow of
                EmptyCheckpoint
                    | V.null remainingRows ->
                        Right $
                            SubscriptionCheckpointInventory
                                (GlobalPosition capturedPosition)
                                V.empty
                    | otherwise ->
                        Left "subscription checkpoint inventory: empty checkpoint row was not the only result"
                PartialCheckpoint ->
                    Left "subscription checkpoint inventory: partially null checkpoint row"
                CompleteCheckpoint ->
                    SubscriptionCheckpointInventory (GlobalPosition capturedPosition)
                        <$> V.mapM (decodeCheckpoint capturedPosition) rows

data CheckpointColumns
    = EmptyCheckpoint
    | PartialCheckpoint
    | CompleteCheckpoint

checkpointColumns :: InventoryRow -> CheckpointColumns
checkpointColumns row =
    case ( rowSubscriptionName row
         , rowConsumerGroupMember row
         , rowCheckpointPosition row
         , rowCheckpointUpdatedAt row
         ) of
        (Nothing, Nothing, Nothing, Nothing) -> EmptyCheckpoint
        (Just _, Just _, Just _, Just _) -> CompleteCheckpoint
        _ -> PartialCheckpoint

decodeCheckpoint :: Int64 -> InventoryRow -> Either Text SubscriptionCheckpoint
decodeCheckpoint capturedPosition row
    | rowStorePosition row /= capturedPosition =
        Left "subscription checkpoint inventory: inconsistent repeated store position"
    | otherwise =
        case ( rowSubscriptionName row
             , rowConsumerGroupMember row
             , rowCheckpointPosition row
             , rowCheckpointUpdatedAt row
             ) of
            (Just name, Just member, Just position, Just updatedAt) ->
                Right $
                    SubscriptionCheckpoint
                        (SubscriptionName name)
                        member
                        (GlobalPosition position)
                        updatedAt
            (Nothing, Nothing, Nothing, Nothing) ->
                Left "subscription checkpoint inventory: unexpected empty checkpoint row"
            _ -> Left "subscription checkpoint inventory: partially null checkpoint row"
