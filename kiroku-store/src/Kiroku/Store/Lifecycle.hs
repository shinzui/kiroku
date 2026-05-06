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

The exact stream name @$all@ is reserved for the global read stream.
Lifecycle operations reject it with
'Kiroku.Store.Error.ReservedStreamName' so callers cannot hide, remove,
or restore the internal global stream row.

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

== Authorization model

Hard delete is gated by a session-local PostgreSQL GUC
(@kiroku.enable_hard_deletes@) that the interpreter sets inside its
transaction. Direct @DELETE@ or @TRUNCATE@ against the underlying
tables without setting that GUC raises an exception via the
@protect_deletion@ and @protect_truncation@ triggers in
@kiroku-store/sql/schema.sql@.

/The GUC is an advisory protection, not a security boundary./ Any
PostgreSQL session with @DELETE@ privilege on @events@,
@stream_events@, and @streams@ can issue @SET LOCAL
kiroku.enable_hard_deletes = \'on\'@ before its own @DELETE@ —
PostgreSQL grants @SET LOCAL@ to every session. The trigger exists
to make accidental issuance of @DELETE@ (a typo, an ad-hoc operator
query, an ORM that does not know the table is meant to be
append-only) fail loudly rather than to enforce role-based access
control.

In practice the model is "applications running with full @DELETE@
privilege on the data tables are trusted to call hard-delete
correctly". Production deployments that need stricter control should:

* Run the application as a low-privileged role with only @INSERT,
  UPDATE, SELECT@ on the data tables (not @DELETE@); soft-delete
  via 'softDeleteStream' is unaffected. Issue hard-deletes from a
  separate, more privileged role gated by your own access controls.

* /Or/ wrap calls to 'hardDeleteStream' in your application's
  authorization layer before they reach this function. Reading the
  @protect_deletion@ trigger as a security boundary is incorrect.

== Event preservation semantics

The interpreter cleans up junction rows ('stream_events') first,
then deletes orphaned 'events' rows — events still linked to other
streams from this one's hard-deleted source junctions are removed;
events linked to streams /not/ owned by this deletion are preserved.

== Result

Returns @Just streamId@ on success, @Nothing@ if the stream did not
exist. The exact stream name @$all@ is rejected with
'Kiroku.Store.Error.ReservedStreamName'. There is no \"undo\" — for reversible deletes use
'softDeleteStream' instead. The deletion emits no in-band audit row;
operators relying on an audit log must capture hard-deletes through
the connection-pool observation handler (see
'Kiroku.Store.Connection.ConnectionSettings.observationHandler') or
record an application-level event /before/ calling this function.
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
not soft-deleted (already live). The exact stream name @$all@ is
rejected with 'Kiroku.Store.Error.ReservedStreamName'.
-}
undeleteStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
undeleteStream name = send (UndeleteStream name)
