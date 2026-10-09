{- | Explicit mutation operations for durable subscription checkpoints.

Ordinary subscription checkpoint saves are monotonic. This module owns the
separate reset, resize and rebind operations for callers that need to move
persisted progress backward or forward as part of a larger transaction.
-}
module Kiroku.Store.Subscription.Checkpoint (
    SubscriptionCheckpointResetReport (..),
    resetSubscriptionCheckpointsTx,
    ConsumerGroupResizeReport (..),
    resizeConsumerGroupTx,
    SubscriptionTargetRebindReport (..),
    rebindSubscriptionTargetTx,
) where

import Data.Int (Int32)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Subscription.Checkpoint.SQL qualified as SQL
import Kiroku.Store.Subscription.Types (
    ConsumerGroupSize,
    SubscriptionCheckpointKey (..),
    SubscriptionName (..),
    SubscriptionTarget,
    consumerGroupSizeValue,
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

{- | Evidence of explicit topology equalization. Previous sizes are sorted and
distinct; all new members resume from 'resumePosition'. A missing group starts
at zero. A repeat reports the now-equalized topology without moving progress.
-}
data ConsumerGroupResizeReport = ConsumerGroupResizeReport
    { previousSizes :: !(Vector Int32)
    , previousMemberCount :: !Int
    , newSize :: !ConsumerGroupSize
    , resumePosition :: !GlobalPosition
    }
    deriving stock (Eq, Show, Generic)

{- | Stop every worker for the name before calling this operation. Lock its
checkpoint set, rewind every new member to the old minimum, and remove obsolete
members atomically. Existing member identities are retained. A hash-assignment
change also requires this equalization even when the group size is unchanged.
The caller can compose or roll back the resize with application-owned SQL.
-}
resizeConsumerGroupTx ::
    SubscriptionName -> ConsumerGroupSize -> Tx.Transaction ConsumerGroupResizeReport
resizeConsumerGroupTx (SubscriptionName name) newSize = do
    Tx.statement name SQL.lockCheckpointNameStmt
    rows <- Tx.statement name SQL.lockCheckpointRowsStmt
    let position = if Vector.null rows then 0 else Vector.minimum (Vector.map (\(_, _, p, _) -> p) rows)
        previousSizes = Vector.fromList . sort . nub $ [n | (_, n, _, _) <- Vector.toList rows]
    let binding = if Vector.null rows then Nothing else let (_, _, _, b) = Vector.head rows in b
        (kind, category) = SQL.targetColumns binding
    Tx.statement (name, consumerGroupSizeValue newSize, position, kind, category) SQL.resizeCheckpointMembersStmt
    pure
        ConsumerGroupResizeReport
            { previousSizes = previousSizes
            , previousMemberCount = Vector.length rows
            , newSize = newSize
            , resumePosition = GlobalPosition position
            }

-- | Rebind evidence includes every distinct prior binding; Nothing denotes legacy rows.
data SubscriptionTargetRebindReport = SubscriptionTargetRebindReport
    { reboundMemberCount :: !Int
    , previousBindings :: !(Vector (Maybe SubscriptionTarget))
    , reboundTarget :: !SubscriptionTarget
    , reboundPosition :: !GlobalPosition
    }
    deriving stock (Eq, Show)

{- | Stop all workers first. Bind every existing member and explicitly reset its
position in the caller's transaction. A missing name fails the transaction;
repeating the operation leaves target and progress unchanged.
-}
rebindSubscriptionTargetTx ::
    SubscriptionName -> SubscriptionTarget -> GlobalPosition -> Tx.Transaction SubscriptionTargetRebindReport
rebindSubscriptionTargetTx (SubscriptionName name) target position@(GlobalPosition pos) = do
    Tx.statement name SQL.lockCheckpointNameStmt
    rows <- Tx.statement name SQL.lockCheckpointRowsStmt
    let (kind, category) = SQL.targetColumns (Just target)
    count <- Tx.statement (name, kind, category, pos) SQL.rebindCheckpointTargetStmt
    pure
        SubscriptionTargetRebindReport
            { reboundMemberCount = fromIntegral count
            , previousBindings = Vector.fromList . nub $ [binding | (_, _, _, binding) <- Vector.toList rows]
            , reboundTarget = target
            , reboundPosition = position
            }
