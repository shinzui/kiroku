module Kiroku.Store.Link (
    linkToStream,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

{- | Link existing events into a target stream.

Creates the target stream if it does not exist; otherwise appends
links to the existing target. Linking does not duplicate the event
payload — the @events@ row is shared, and only a new junction row in
@stream_events@ is created. Linked events keep their original
'Kiroku.Store.Types.GlobalPosition' and 'Kiroku.Store.Types.RecordedEvent.originalStreamId' /
'originalVersion' fields; the target's 'Kiroku.Store.Types.RecordedEvent.streamVersion'
reflects the link's position in the target.

Preconditions:

* Every supplied 'Kiroku.Store.Types.EventId' must reference an event
  that currently exists. Linking an unknown id (a typo, or an id that
  was hard-deleted) rejects the entire batch atomically — the target
  stream is left in its pre-call state. (See EP-1 F3.)
* The target must not be soft-deleted. Linking to a soft-deleted target
  fails with 'Kiroku.Store.Error.StreamNotFound'. (See EP-1 F5.)
* Linking the same event into the same target stream twice fails with
  a primary-key violation on the junction's @(stream_id, event_id)@
  uniqueness.

Returns the target's 'Kiroku.Store.Types.LinkResult' — its id and the
position of the /last/ linked event in the target.

Empty input @[]@ is a no-op programming mistake; do not call.
-}
linkToStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    [EventId] ->
    Eff es LinkResult
linkToStream targetStream eventIds = send (LinkToStream targetStream eventIds)
