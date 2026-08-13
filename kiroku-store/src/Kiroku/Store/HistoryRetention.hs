{- | Durable replay-history retention and transaction-scoped stream guards.

A lease protects the retained global event set from Kiroku hard delete and
authorized direct SQL deletion until its database-derived expiry. Transaction
combinators persist durable evidence but cannot emit process-local observability
events from inside an opaque caller-owned transaction.

When one transaction needs both a lease operation and a stream-history guard,
perform the lease operation first. This preserves Kiroku's coordinator-before-
stream-row lock order.
-}
module Kiroku.Store.HistoryRetention (
    module Kiroku.Store.HistoryRetention.Types,
    acquireHistoryRetentionLeaseTx,
    renewHistoryRetentionLeaseTx,
    releaseHistoryRetentionLeaseTx,
    historyRetentionLeaseInventoryTx,
    pruneHistoryRetentionLeasesTx,
    acquireHistoryRetentionLease,
    renewHistoryRetentionLease,
    releaseHistoryRetentionLease,
    historyRetentionLeaseInventory,
    pruneHistoryRetentionLeases,
) where

import Data.Time.Clock (UTCTime)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.HistoryRetention.Internal qualified as Internal
import Kiroku.Store.HistoryRetention.Types

-- | Acquire a new lease and atomically capture the authoritative @$all@ frontier.
acquireHistoryRetentionLeaseTx :: HistoryRetentionLeaseRequest -> Tx.Transaction HistoryRetentionLease
acquireHistoryRetentionLeaseTx = Internal.acquireHistoryRetentionLeaseTx

-- | Renew a still-active lease without shortening its current expiry.
renewHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseHandle ->
    HistoryRetentionLeaseDuration ->
    Tx.Transaction (Either HistoryRetentionRenewalError HistoryRetentionLease)
renewHistoryRetentionLeaseTx = Internal.renewHistoryRetentionLeaseTx

-- | Release a live lease. Repetition is typed and does not rewrite the row.
releaseHistoryRetentionLeaseTx ::
    HistoryRetentionLeaseHandle ->
    Tx.Transaction HistoryRetentionReleaseResult
releaseHistoryRetentionLeaseTx = Internal.releaseHistoryRetentionLeaseTx

-- | Read a deterministic, database-time-derived, bounded inventory.
historyRetentionLeaseInventoryTx ::
    HistoryRetentionInventoryQuery ->
    Tx.Transaction (Vector HistoryRetentionLease)
historyRetentionLeaseInventoryTx = Internal.historyRetentionLeaseInventoryTx

-- | Remove terminal rows strictly older than the supplied cutoff.
pruneHistoryRetentionLeasesTx :: UTCTime -> Tx.Transaction HistoryRetentionPruneResult
pruneHistoryRetentionLeasesTx = Internal.pruneHistoryRetentionLeasesTx

-- | Acquire a lease through the mockable 'Store' effect.
acquireHistoryRetentionLease :: (Store :> es) => HistoryRetentionLeaseRequest -> Eff es HistoryRetentionLease
acquireHistoryRetentionLease request = send (AcquireHistoryRetentionLease request)

-- | Renew a lease through the mockable 'Store' effect.
renewHistoryRetentionLease ::
    (Store :> es) =>
    HistoryRetentionLeaseHandle ->
    HistoryRetentionLeaseDuration ->
    Eff es (Either HistoryRetentionRenewalError HistoryRetentionLease)
renewHistoryRetentionLease handle duration = send (RenewHistoryRetentionLease handle duration)

-- | Release a lease through the mockable 'Store' effect.
releaseHistoryRetentionLease ::
    (Store :> es) =>
    HistoryRetentionLeaseHandle ->
    Eff es HistoryRetentionReleaseResult
releaseHistoryRetentionLease handle = send (ReleaseHistoryRetentionLease handle)

-- | Read the bounded durable inventory through the mockable 'Store' effect.
historyRetentionLeaseInventory ::
    (Store :> es) =>
    HistoryRetentionInventoryQuery ->
    Eff es (Vector HistoryRetentionLease)
historyRetentionLeaseInventory query = send (GetHistoryRetentionLeaseInventory query)

-- | Prune terminal rows through the mockable 'Store' effect.
pruneHistoryRetentionLeases ::
    (Store :> es) =>
    UTCTime ->
    Eff es HistoryRetentionPruneResult
pruneHistoryRetentionLeases cutoff = send (PruneHistoryRetentionLeases cutoff)
