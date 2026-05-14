{- | Smart constructors for the causation- and correlation-walking reads.

These wrap the 'Kiroku.Store.Effect.FindEvents' constructor with a filter
suited to a specific question:

* 'findCausationDescendants' — walk the causation graph forward from a
  trigger event and return every event that descended from it.
* 'findCausationAncestors' — walk the causation graph backward from a
  leaf event and return every event reachable by following
  @causation_id@ upward.
* 'findByCorrelation' — return every event whose @correlation_id@ equals
  the input.

All three reuse the existing partial indexes @ix_events_causation_id@ and
@ix_events_correlation_id@ on the @events@ table, so they do not require
any schema change.
-}
module Kiroku.Store.Causation (
    findCausationDescendants,
    findCausationAncestors,
    findByCorrelation,
) where

import Data.UUID (UUID)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

{- | Return the seed event and every event whose @causation_id@ chain leads
back to it, in ascending @global_position@ order. The seed event is
included as the depth-0 row when it exists; otherwise the result is
empty.

Uses the @ix_events_causation_id@ partial index. Cost is
@O(depth * log n)@ where @depth@ is the length of the longest chain
rooted at the seed and @n@ is the total event count.
-}
findCausationDescendants ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)
findCausationDescendants eid = send (FindEvents (FilterCausationDescendants eid))

{- | Return the seed event and every ancestor reachable via @causation_id@,
in depth-ascending order (the seed is first, its immediate cause is
second, etc.). The seed event is included as the depth-0 row when it
exists; otherwise the result is empty.
-}
findCausationAncestors ::
    (HasCallStack, Store :> es) =>
    EventId ->
    Eff es (Vector RecordedEvent)
findCausationAncestors eid = send (FindEvents (FilterCausationAncestors eid))

{- | Return every event whose @correlation_id@ equals the input, in
ascending @global_position@ order. Uses the @ix_events_correlation_id@
partial index.
-}
findByCorrelation ::
    (HasCallStack, Store :> es) =>
    UUID ->
    Eff es (Vector RecordedEvent)
findByCorrelation cid = send (FindEvents (FilterCorrelation cid))
