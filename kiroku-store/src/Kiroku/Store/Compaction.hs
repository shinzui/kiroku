-- | Explicit selective physical compaction. Preview is read-only, takes no row
-- locks, and reports discrepancies under one snapshot. Apply revalidates under
-- the retention coordinator and ordered stream locks before deleting anything.
module Kiroku.Store.Compaction
  ( module Kiroku.Store.Compaction.Types,
    previewCompaction,
    previewCompactionTx,
  )
where

import Data.List.NonEmpty (NonEmpty)
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
