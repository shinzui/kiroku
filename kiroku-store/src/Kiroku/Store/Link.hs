module Kiroku.Store.Link (
    linkToStream,
) where

import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

-- | Link existing events into a target stream (creates stream if it does not exist).
linkToStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    [EventId] ->
    Eff es LinkResult
linkToStream targetStream eventIds = send (LinkToStream targetStream eventIds)
