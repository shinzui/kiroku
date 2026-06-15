module Kiroku.Store.Read (
    readStreamForward,
    readStreamForwardStream,
    readStreamBackward,
    readAllForward,
    readAllBackward,
    readCategory,
    getStream,
    lookupStreamId,
    eventExistsInStream,
    lookupStreamName,
    lookupStreamNames,
) where

import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Read events from a named stream in forward (ascending version)
order.

The cursor is exclusive: events with @streamVersion > startVer@ are
returned. To read the entire stream from the beginning, pass
@'StreamVersion' 0@. Returns an empty vector for nonexistent or
soft-deleted streams. The @limit@ caps the batch size; pass a large
value for \"read everything\".
-}
readStreamForward ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readStreamForward name startVer limit = send (ReadStreamForward name startVer limit)

{- | Forward read a single stream as a constant-memory Streamly 'Stream'.

The streaming sibling of 'readStreamForward'. Identical SQL path and identical
error semantics: this function dispatches 'readStreamForward' repeatedly with
the supplied @pageSize@ as the per-call limit, advancing the exclusive
'StreamVersion' cursor across pages until a page comes back shorter than
@pageSize@. If the stream length is an exact multiple of @pageSize@, one
final empty-page probe is still required because the wrapper does not know
the total stream length up front.

The exclusive-cursor convention is preserved end-to-end: passing
@'StreamVersion' 0@ reads from the first event in the stream. Empty and
nonexistent streams terminate the stream immediately with zero elements.

The recommended @pageSize@ is @256@. Callers reading very wide events (large
payloads / metadata) should pass a smaller value to keep per-page memory
bounded; callers reading very long streams of small events may pass a larger
value to reduce round-trip count.
-}
readStreamForwardStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Stream (Eff es) RecordedEvent
readStreamForwardStream name startVer pageSize =
    Stream.concatMap fromVector pages
  where
    pages = Stream.unfoldrM nextPage (Just startVer)
    nextPage Nothing = pure Nothing
    nextPage (Just cursor) = do
        events <- readStreamForward name cursor pageSize
        if V.null events
            then pure Nothing
            else do
                let nextState
                        | V.length events < fromIntegral pageSize = Nothing
                        | otherwise = Just (V.last events ^. #streamVersion)
                pure (Just (events, nextState))

    fromVector :: Vector a -> Stream (Eff es) a
    fromVector v = Stream.unfoldr (\i -> fmap (\x -> (x, i + 1)) (v V.!? i)) 0

{- | Read events from a named stream in backward (descending version)
order.

The cursor is exclusive: events with @streamVersion < startVer@ are
returned (events older than the cursor). To read the entire stream from
the latest event backward, pass @'StreamVersion' 0@. The interpreter maps
0 to the maximum cursor value, so it never collides with a real stream
version; versions start at 1. Returns an empty vector for nonexistent or
soft-deleted streams.
-}
readStreamBackward ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readStreamBackward name startVer limit = send (ReadStreamBackward name startVer limit)

{- | Read events from the global @$all@ stream in forward
('GlobalPosition'-ascending) order.

Cursor exclusive: events with @globalPosition > startPos@ are returned.
@$all@ contains every event ever appended (including events from
soft-deleted streams; they survive in @$all@ even after their owning
stream is hidden). Hard-deleted streams' events do /not/ appear in
@$all@. The seed row at @globalPosition = 0@ is internal and is never
returned.
-}
readAllForward ::
    (HasCallStack, Store :> es) =>
    GlobalPosition ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readAllForward startPos limit = send (ReadAllForward startPos limit)

{- | Read events from the global @$all@ stream in backward
('GlobalPosition'-descending) order.

Cursor exclusive. To start from the most recent event, pass
@'GlobalPosition' 0@. The interpreter maps 0 to the maximum cursor value,
so it never collides with a real global position; positions start at 1.
-}
readAllBackward ::
    (HasCallStack, Store :> es) =>
    GlobalPosition ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readAllBackward startPos limit = send (ReadAllBackward startPos limit)

{- | Read events whose source stream's category prefix matches the given
'CategoryName', in 'GlobalPosition' order.

The category is the substring of a 'StreamName' before the first @-@:
@StreamName "orders-1"@ has @CategoryName "orders"@. Linked events
appear at their /source/ position; the category is the source's
category, not the link target's.
-}
readCategory ::
    (HasCallStack, Store :> es) =>
    CategoryName ->
    GlobalPosition ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readCategory cat startPos limit = send (ReadCategoryForward cat startPos limit)

{- | Query stream metadata.

Returns 'Just' for both live and soft-deleted streams (with @deletedAt@
populated). Returns 'Nothing' for hard-deleted streams and streams that
have never been created.
-}
getStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamInfo)
getStream name = send (GetStream name)

{- | Look up a stream's surrogate id by name.

Returns 'Just' the 'StreamId' for both live and soft-deleted streams (mirroring
'getStream'\'s soft-delete behavior). Returns 'Nothing' for streams that have
never been created and for streams that have been hard-deleted.

This is a lighter-weight alternative to 'getStream' when the caller only needs
the surrogate id: it decodes one @int8@ column instead of the five columns
that 'StreamInfo' carries. Equivalent to projecting @info ^. #id@ from a
successful 'getStream' result, but cheaper.
-}
lookupStreamId ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamId)
lookupStreamId name = send (LookupStreamId name)

{- | Return 'True' when the supplied event id is linked into the supplied live
stream, and 'False' when the event id is absent, belongs only to another stream,
or the stream is nonexistent or soft-deleted.

This is a point lookup for idempotency checks. Prefer it over scanning a stream
when the caller already has the event id it is looking for.
-}
eventExistsInStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    EventId ->
    Eff es Bool
eventExistsInStream name eid = send (EventExistsInStream name eid)

{- | Resolve a batch of surrogate 'StreamId's to their 'StreamName's in a single
round trip, returning a 'Map' that omits any id which does not name an existing
stream (hard-deleted or never created). Live and soft-deleted streams are
included, mirroring 'lookupStreamId'.

This is the inverse of 'lookupStreamId' and the supported way to recover the
human-readable source stream for events obtained from /fan-in/ reads — the
global @$all@ stream, 'readCategory', the "Kiroku.Store.Causation" queries, and
subscriptions — where each 'RecordedEvent' carries only its surrogate
@originalStreamId@. Collect the distinct ids from a batch and resolve them once,
rather than paying a round trip per event:

@
let ids = 'Data.List.nub' (map (^. #originalStreamId) events)
names <- 'lookupStreamNames' ids
-- names '!?' (event '^.' #originalStreamId) :: Maybe StreamName
@

Passing @[]@ returns an empty map without any database round trip because
the interpreter short-circuits.
-}
lookupStreamNames ::
    (HasCallStack, Store :> es) =>
    [StreamId] ->
    Eff es (Map StreamId StreamName)
lookupStreamNames sids = send (LookupStreamNames sids)

{- | Resolve a single surrogate 'StreamId' to its 'StreamName', or 'Nothing' if
no such stream exists. A convenience wrapper over 'lookupStreamNames'; prefer
the batch form when resolving the ids of a whole read batch, to avoid one round
trip per id.
-}
lookupStreamName ::
    (HasCallStack, Store :> es) =>
    StreamId ->
    Eff es (Maybe StreamName)
lookupStreamName sid = Map.lookup sid <$> lookupStreamNames [sid]
