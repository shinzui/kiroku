{- | Explicit mutation operations for durable subscription checkpoints.

Ordinary subscription checkpoint saves are monotonic. This module owns the
separate, deliberately named reset operation for callers that need to move
persisted progress backward or forward as part of a larger transaction.
-}
module Kiroku.Store.Subscription.Checkpoint (
    SubscriptionCheckpointResetReport (..),
    resetSubscriptionCheckpointsTx,
) where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Subscription.Checkpoint.SQL qualified as SQL
import Kiroku.Store.Subscription.Types (
    SubscriptionCheckpointKey (..),
    SubscriptionName (..),
 )
import Kiroku.Store.Types (GlobalPosition (..))

{- | Exact result of resetting a non-empty set of subscription names.

'resetCheckpointKeys' contains every persisted @(name, member)@ row that was
updated. 'missingSubscriptionNames' contains requested names for which no row
existed. Both vectors are sorted by subscription name (and then member for
keys); duplicate requested names appear only once in the report.
-}
data SubscriptionCheckpointResetReport = SubscriptionCheckpointResetReport
    { resetCheckpointKeys :: !(Vector SubscriptionCheckpointKey)
    , missingSubscriptionNames :: !(Vector SubscriptionName)
    }
    deriving stock (Eq, Show, Generic)

{- | Set every existing checkpoint member for the requested subscription names
to the exact target position and return complete deterministic evidence.

The operation treats duplicate requested names as one name, updates all
persisted members for each name, and never creates checkpoint rows for missing
names. Unlike ordinary worker saves, this operation can move a checkpoint
backward. It is a 'Tx.Transaction' combinator so a caller can atomically compose
the reset with its own projection fence and target preparation; condemning that
surrounding transaction rolls back all of those writes together.
-}
resetSubscriptionCheckpointsTx ::
    NonEmpty SubscriptionName ->
    GlobalPosition ->
    Tx.Transaction SubscriptionCheckpointResetReport
resetSubscriptionCheckpointsTx names (GlobalPosition position) = do
    rows <-
        Tx.statement
            ( Vector.fromList
                [name | SubscriptionName name <- NonEmpty.toList names]
            , position
            )
            SQL.resetSubscriptionCheckpointsStmt
    pure
        SubscriptionCheckpointResetReport
            { resetCheckpointKeys = Vector.mapMaybe resetKey rows
            , missingSubscriptionNames = Vector.mapMaybe missingName rows
            }
  where
    resetKey (name, Just member) =
        Just (SubscriptionCheckpointKey (SubscriptionName name) member)
    resetKey (_, Nothing) = Nothing
    missingName (name, Nothing) = Just (SubscriptionName name)
    missingName (_, Just _) = Nothing
