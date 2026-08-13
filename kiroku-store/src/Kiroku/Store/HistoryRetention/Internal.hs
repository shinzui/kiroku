module Kiroku.Store.HistoryRetention.Internal (
    acquireHistoryRetentionLeaseTx,
    renewHistoryRetentionLeaseTx,
    releaseHistoryRetentionLeaseTx,
    historyRetentionLeaseInventoryTx,
    pruneHistoryRetentionLeasesTx,
    lockHistoryRetentionCoordinatorTx,
    activeHistoryRetentionConflictTx,
    lockAffectedStreamsForHardDeleteTx,
) where

import Data.Int (Int64)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.HistoryRetention.SQL qualified as SQL
import Kiroku.Store.HistoryRetention.Types

acquireHistoryRetentionLeaseTx :: HistoryRetentionLeaseRequest -> Tx.Transaction HistoryRetentionLease
acquireHistoryRetentionLeaseTx HistoryRetentionLeaseRequest{owner, reason, duration} =
    Tx.statement
        ( historyRetentionLeaseOwnerText owner
        , historyRetentionLeaseReasonText reason
        , historyRetentionLeaseDurationValue duration
        )
        SQL.acquireLeaseStmt

renewHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseHandle ->
    HistoryRetentionLeaseDuration ->
    Tx.Transaction (Either HistoryRetentionRenewalError HistoryRetentionLease)
renewHistoryRetentionLeaseTx HistoryRetentionLeaseHandle{leaseId, owner = requestedOwner} duration = do
    lockHistoryRetentionCoordinatorTx
    current <- Tx.statement (leaseUuid leaseId) SQL.readLeaseForUpdateStmt
    case current of
        Nothing -> pure (Left HistoryRetentionRenewalUnknown)
        Just lease@HistoryRetentionLease{owner = actualOwner, state}
            | actualOwner /= requestedOwner -> pure (Left HistoryRetentionRenewalOwnerMismatch)
            | state == HistoryRetentionLeaseReleased -> pure (Left HistoryRetentionRenewalReleased)
            | state == HistoryRetentionLeaseExpired -> pure (Left HistoryRetentionRenewalExpired)
            | otherwise ->
                Right
                    <$> Tx.statement
                        (leaseUuid leaseId, historyRetentionLeaseDurationValue duration)
                        SQL.renewLeaseStmt

releaseHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseHandle ->
    Tx.Transaction HistoryRetentionReleaseResult
releaseHistoryRetentionLeaseTx HistoryRetentionLeaseHandle{leaseId, owner = requestedOwner} = do
    lockHistoryRetentionCoordinatorTx
    current <- Tx.statement (leaseUuid leaseId) SQL.readLeaseForUpdateStmt
    case current of
        Nothing -> pure HistoryRetentionReleaseUnknown
        Just lease@HistoryRetentionLease{owner = actualOwner, state}
            | actualOwner /= requestedOwner -> pure HistoryRetentionReleaseOwnerMismatch
            | state == HistoryRetentionLeaseReleased -> pure (HistoryRetentionAlreadyReleased lease)
            | state == HistoryRetentionLeaseExpired -> pure (HistoryRetentionReleaseExpired lease)
            | otherwise ->
                HistoryRetentionReleased
                    <$> Tx.statement (leaseUuid leaseId) SQL.releaseLeaseStmt

historyRetentionLeaseInventoryTx ::
    HistoryRetentionInventoryQuery ->
    Tx.Transaction (Vector HistoryRetentionLease)
historyRetentionLeaseInventoryTx HistoryRetentionInventoryQuery{limit} =
    Tx.statement (historyRetentionInventoryLimitValue limit) SQL.leaseInventoryStmt

pruneHistoryRetentionLeasesTx ::
    UTCTime ->
    Tx.Transaction HistoryRetentionPruneResult
pruneHistoryRetentionLeasesTx cutoff = do
    lockHistoryRetentionCoordinatorTx
    Tx.statement cutoff SQL.pruneLeasesStmt

lockHistoryRetentionCoordinatorTx :: Tx.Transaction ()
lockHistoryRetentionCoordinatorTx = do
    _ <- Tx.statement () SQL.lockCoordinatorStmt
    pure ()

activeHistoryRetentionConflictTx :: Tx.Transaction (Maybe HistoryRetentionConflict)
activeHistoryRetentionConflictTx = Tx.statement () SQL.activeConflictStmt

lockAffectedStreamsForHardDeleteTx :: Int64 -> Tx.Transaction ()
lockAffectedStreamsForHardDeleteTx streamId = do
    _ <- Tx.statement streamId SQL.lockAffectedStreamsForHardDeleteStmt
    pure ()

leaseUuid :: HistoryRetentionLeaseId -> UUID
leaseUuid (HistoryRetentionLeaseId value) = value
