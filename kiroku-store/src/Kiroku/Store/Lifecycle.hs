module Kiroku.Store.Lifecycle (
    softDeleteStream,
    hardDeleteStream,
    undeleteStream,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

-- | Soft-delete a stream. Returns Just streamId on success, Nothing if stream doesn't exist or is already deleted.
softDeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
softDeleteStream name = send (SoftDeleteStream name)

-- | Hard-delete a stream and all its events. Returns Just streamId on success, Nothing if stream doesn't exist.
hardDeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
hardDeleteStream name = send (HardDeleteStream name)

-- | Restore a soft-deleted stream. Returns Just streamId on success, Nothing if stream doesn't exist or is not deleted.
undeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
undeleteStream name = send (UndeleteStream name)
