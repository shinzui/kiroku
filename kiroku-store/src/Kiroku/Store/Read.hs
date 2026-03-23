module Kiroku.Store.Read (
    readStreamForward,
    readStreamBackward,
    readAllForward,
    readAllBackward,
    getStream,
) where

import Data.Int (Int32)
import Data.Vector (Vector)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (send)
import GHC.Stack (HasCallStack)
import Kiroku.Store.Effect (Store (..))
import Kiroku.Store.Types

-- | Read events from a named stream in forward (ascending version) order.
readStreamForward ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readStreamForward name startVer limit = send (ReadStreamForward name startVer limit)

-- | Read events from a named stream in backward (descending version) order.
readStreamBackward ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    StreamVersion ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readStreamBackward name startVer limit = send (ReadStreamBackward name startVer limit)

-- | Read events from the global @$all@ stream in forward order.
readAllForward ::
    (HasCallStack, Store :> es) =>
    GlobalPosition ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readAllForward startPos limit = send (ReadAllForward startPos limit)

-- | Read events from the global @$all@ stream in backward order.
readAllBackward ::
    (HasCallStack, Store :> es) =>
    GlobalPosition ->
    Int32 ->
    Eff es (Vector RecordedEvent)
readAllBackward startPos limit = send (ReadAllBackward startPos limit)

-- | Query stream metadata. Returns 'Nothing' for nonexistent streams.
getStream ::
    (HasCallStack, Store :> es) =>
    StreamName ->
    Eff es (Maybe StreamInfo)
getStream name = send (GetStream name)
