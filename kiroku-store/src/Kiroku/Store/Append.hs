module Kiroku.Store.Append (
    appendToStream,
    appendMultiStream,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

-- | Append events to a stream with the given expected version.
appendToStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    ExpectedVersion ->
    [EventData] ->
    Eff es AppendResult
appendToStream name expected events = send (AppendToStream name expected events)

-- | Atomically append events to multiple streams in a single transaction.
appendMultiStream ::
    (HasCallStack, Store :> es) =>
    [(StreamName, ExpectedVersion, [EventData])] ->
    Eff es [AppendResult]
appendMultiStream ops = send (AppendMultiStream ops)
