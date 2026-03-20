module Kiroku.Store.Schema (
    initializeSchema,
) where

import Data.Text (Text)
import Hasql.Pool (Pool)

{- | Initialize the event store schema in the given PostgreSQL schema.
Idempotent — safe to call on every startup.
-}
initializeSchema :: Pool -> Text -> IO ()
initializeSchema _pool _schema =
    -- TODO: Execute DDL from DESIGN.md, parameterized by schema name
    pure ()
