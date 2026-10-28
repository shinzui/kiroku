-- | Explicit selective physical compaction. Preview is read-only, takes no row
-- locks, and reports discrepancies under one snapshot. Apply revalidates under
-- the retention coordinator and ordered stream locks before deleting anything.
module Kiroku.Store.Compaction
  ( module Kiroku.Store.Compaction.Types,
    previewCompaction,
    previewCompactionTx,
    applyCompaction,
    applyCompactionTx,
    compactionLedger,
    compactionLedgerTx,

    -- * Failure-injection seam
    applyCompactionTxWith,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Compaction.Internal qualified as Internal
import Kiroku.Store.Compaction.Types
import Kiroku.Store.Effect (Store (..))

-- | Read-only preview on one pooled connection and one repeatable-read snapshot.
-- Reports active leases without waiting for them. Causation refusal is a
-- validation-time check: causation IDs have no foreign key and dependents may
-- be appended to unlisted streams after validation.
previewCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionPreview)
previewCompaction = send . PreviewCompaction

-- | Preview inside the caller's transaction. Takes no row locks and writes
-- nothing. The caller chooses isolation; use repeatable read for one snapshot.
previewCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionPreview)
previewCompactionTx = Internal.previewCompactionTx

-- | Apply one manifest atomically. Takes the retention coordinator first,
-- refuses active leases, recognizes recorded digests before locking streams,
-- then locks affected streams by ascending internal ID and revalidates every
-- witness before deletion. Retained rows and stream heads are unchanged; no
-- NOTIFY fires. A repeated recorded manifest returns its original ledger record.
-- Concurrent references abort the whole transaction: re-preview and re-apply.
applyCompaction :: (Store :> es) => CompactionManifest -> Eff es (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
applyCompaction = send . ApplyCompaction

-- | Apply inside the caller's write transaction. Lease work must precede stream
-- guards to preserve the coordinator-before-stream lock order. Count races
-- raise 'Kiroku.Store.Error.CompactionConcurrentMutation'; a concurrent foreign
-- key reference may surface as 'Kiroku.Store.Error.UnexpectedServerError' with
-- SQLSTATE @23503@ for direct composers. Both mean rollback and retry after a
-- fresh preview. Causation refusal is validation-time best-effort.
applyCompactionTx :: CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
applyCompactionTx = Internal.applyCompactionTx

-- | Newest durable audit records first, with a validated limit of 1–1000.
-- Records preserve stored digests verbatim for audit; the ledger omits event IDs.
compactionLedger :: (Store :> es) => CompactionLedgerQuery -> Eff es (Vector CompactionRecord)
compactionLedger = send . GetCompactionLedger

-- | Ledger inventory inside the caller's transaction.
compactionLedgerTx :: CompactionLedgerQuery -> Tx.Transaction (Vector CompactionRecord)
compactionLedgerTx = Internal.compactionLedgerTx

-- | Failure-injection barrier after validation and before the first DELETE.
-- Production 'applyCompactionTx' uses @pure ()@ and adds no statement. A barrier
-- must remain SQL-only when the caller enables automatic transaction retries.
applyCompactionTxWith :: Tx.Transaction () -> CompactionManifest -> Tx.Transaction (Either (NonEmpty CompactionRefusal) CompactionApplyResult)
applyCompactionTxWith = Internal.applyCompactionTxWith
