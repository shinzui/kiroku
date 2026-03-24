{- | Kiroku Store — high-performance PostgreSQL event store.

Public API re-exports.
-}
module Kiroku.Store (
    module Kiroku.Store.Types,
    module Kiroku.Store.Connection,
    module Kiroku.Store.Effect,
    module Kiroku.Store.Error,
    module Kiroku.Store.Append,
    module Kiroku.Store.Lifecycle,
    module Kiroku.Store.Link,
    module Kiroku.Store.Read,

    -- * Pool observation types (re-exported from hasql-pool)
    Observation (..),
    ConnectionStatus (..),
    ConnectionReadyForUseReason (..),
    ConnectionTerminationReason (..),
) where

import Hasql.Pool.Observation (ConnectionReadyForUseReason (..), ConnectionStatus (..), ConnectionTerminationReason (..), Observation (..))
import Kiroku.Store.Append
import Kiroku.Store.Connection
import Kiroku.Store.Effect
import Kiroku.Store.Error
import Kiroku.Store.Lifecycle
import Kiroku.Store.Link
import Kiroku.Store.Read
import Kiroku.Store.Types
