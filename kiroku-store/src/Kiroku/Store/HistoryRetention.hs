{- | Durable replay-history retention and transaction-scoped stream guards.

A lease protects the retained global event set from Kiroku hard delete and
authorized direct SQL deletion until its database-derived expiry. Transaction
combinators persist durable evidence but cannot emit process-local observability
events from inside an opaque caller-owned transaction.

Lease duration is one second through one hour. Expiry is passive: a crashed
owner blocks destructive work only until PostgreSQL time reaches @expiresAt@.
The owner is an accidental-mutation guard, not an authorization credential;
database roles and grants remain the security boundary. Direct destructive SQL
receives SQLSTATE @KR001@ while any lease is active.

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
    lockStreamHistoryForReplayTx,
    readStreamForwardTx,
) where

import Data.Int (Int32)
import Data.Time.Clock (UTCTime)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.HistoryRetention.Internal qualified as Internal
import Kiroku.Store.HistoryRetention.SQL qualified as HistoryRetentionSQL
import Kiroku.Store.HistoryRetention.Types
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Types (RecordedEvent, StreamInfo, StreamName (..), StreamVersion (..))

{- | Acquire a new lease and atomically capture the authoritative @$all@
frontier as the inclusive @protectedThrough@ rebuild ceiling. PostgreSQL
supplies every timestamp. Rollback leaves no lease row.
-}
acquireHistoryRetentionLeaseTx :: HistoryRetentionLeaseRequest -> Tx.Transaction HistoryRetentionLease
acquireHistoryRetentionLeaseTx = Internal.acquireHistoryRetentionLeaseTx

{- | Renew a still-active lease without shortening its current expiry.
Unknown, wrong-owner, expired, and released leases return distinct typed
errors and are never resurrected.
-}
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

{- | Read a deterministic, database-time-derived, bounded inventory. Active,
expired, and released state is derived at statement time; no expiry worker is
required.
-}
historyRetentionLeaseInventoryTx ::
    HistoryRetentionInventoryQuery ->
    Tx.Transaction (Vector HistoryRetentionLease)
historyRetentionLeaseInventoryTx = Internal.historyRetentionLeaseInventoryTx

-- | Remove only expired or released rows strictly older than the supplied cutoff.
pruneHistoryRetentionLeasesTx :: UTCTime -> Tx.Transaction HistoryRetentionPruneResult
pruneHistoryRetentionLeasesTx = Internal.pruneHistoryRetentionLeasesTx

{- | Acquire a lease through the mockable 'Store' effect. The production
interpreter emits the committed acquisition event after the transaction ends.
-}
acquireHistoryRetentionLease :: (Store :> es) => HistoryRetentionLeaseRequest -> Eff es HistoryRetentionLease
acquireHistoryRetentionLease request = send (AcquireHistoryRetentionLease request)

-- | Renew a lease through the mockable 'Store' effect and emit only a committed success.
renewHistoryRetentionLease ::
    (Store :> es) =>
    HistoryRetentionLeaseHandle ->
    HistoryRetentionLeaseDuration ->
    Eff es (Either HistoryRetentionRenewalError HistoryRetentionLease)
renewHistoryRetentionLease handle duration = send (RenewHistoryRetentionLease handle duration)

-- | Release a lease through the mockable 'Store' effect. Repeated release emits no false transition.
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

{- | Lock one application's stream row in share mode until the surrounding
transaction ends. The returned metadata includes soft-delete and logical
truncate state so a repair can reject incomplete history before mutating its
target. @$all@ is reserved.

When composing this guard with a lease operation, acquire or renew the lease
first and take this guard second.
-}
lockStreamHistoryForReplayTx ::
    StreamName ->
    Tx.Transaction (Either StreamHistoryUnavailable StreamInfo)
lockStreamHistoryForReplayTx stream@(StreamName name)
    | name == "$all" = pure (Left (StreamHistoryReserved stream))
    | otherwise = do
        locked <- Tx.statement name HistoryRetentionSQL.lockStreamHistoryStmt
        pure $ maybe (Left (StreamHistoryNotFound stream)) Right locked

{- | Read a page inside the caller's transaction using the production
exclusive-lower cursor and ascending-order statement. This function deliberately
does not run 'Kiroku.Store.Settings.decodeHook': 'Tx.Transaction' has no 'IO'.
The caller must take 'lockStreamHistoryForReplayTx' earlier in the same
transaction when stable one-stream history is required.
-}
readStreamForwardTx ::
    StreamName ->
    StreamVersion ->
    Int32 ->
    Tx.Transaction (Vector RecordedEvent)
readStreamForwardTx (StreamName name) (StreamVersion cursor) limit =
    Tx.statement (name, cursor, limit) SQL.readStreamForwardStmt
