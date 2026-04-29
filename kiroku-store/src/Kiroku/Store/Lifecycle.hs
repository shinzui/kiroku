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

{- | Mark a stream as deleted without removing its rows.

Soft-deleted streams are invisible to 'Kiroku.Store.Read.readStreamForward'
(returns empty), to 'Kiroku.Store.Read.readStreamBackward', and to
'Kiroku.Store.Append.appendToStream' (returns
'Kiroku.Store.Error.StreamNotFound' or
'Kiroku.Store.Error.StreamAlreadyExists' depending on
'Kiroku.Store.Types.ExpectedVersion'). They remain visible in the
@$all@ stream — the global event log is append-only — and to
'Kiroku.Store.Read.readCategory'. Use 'undeleteStream' to restore.

Returns @Just streamId@ on success, or @Nothing@ if the stream did not
exist or was already soft-deleted. Reverse with 'undeleteStream' or
'hardDeleteStream'.
-}
softDeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
softDeleteStream name = send (SoftDeleteStream name)

{- | Permanently remove a stream, its events (where they are not
referenced by other streams), and its links.

Hard delete is gated by a session-local PostgreSQL GUC
(@kiroku.enable_hard_deletes@) that the interpreter sets inside its
transaction. Direct @DELETE@ or @TRUNCATE@ against the underlying
tables without setting that GUC raises an exception via the
@protect_deletion@ trigger. The interpreter cleans up junction rows
('stream_events') first, then deletes orphaned 'events' rows — events
still linked to other streams from this one's hard-deleted source
junctions are removed; events linked to streams /not/ owned by this
deletion are preserved.

Returns @Just streamId@ on success, @Nothing@ if the stream did not
exist. There is no \"undo\" — for reversible deletes use
'softDeleteStream' instead.
-}
hardDeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
hardDeleteStream name = send (HardDeleteStream name)

{- | Restore a soft-deleted stream by clearing its @deleted_at@ row.

Reads of the restored stream return its full event history. Subsequent
appends behave as if the soft-delete never happened. Returns
@Just streamId@ on success, @Nothing@ if the stream is missing or was
not soft-deleted (already live).
-}
undeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
undeleteStream name = send (UndeleteStream name)
