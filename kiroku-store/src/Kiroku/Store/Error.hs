module Kiroku.Store.Error (
    AppendError (..),
) where

import GHC.Generics (Generic)
import Kiroku.Store.Types

-- | Errors that can occur during an append operation.
data AppendError
    = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
    | StreamNotFound !StreamName
    | StreamAlreadyExists !StreamName
    | DuplicateEvent !EventId
    deriving stock (Eq, Show, Generic)
