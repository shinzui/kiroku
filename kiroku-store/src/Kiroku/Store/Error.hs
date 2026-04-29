module Kiroku.Store.Error (
    StoreError (..),
    -- Internal helpers used by Effect module
    mapUsageError,
    emptyResultError,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Hasql.Errors qualified as Errors
import Hasql.Pool (UsageError (..))
import Kiroku.Store.Types

-- | Errors that can occur during store operations.
data StoreError
    = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
    | StreamNotFound !StreamName
    | StreamAlreadyExists !StreamName
    | DuplicateEvent !EventId
    | -- | A connection or database error.
      ConnectionError !Text
    deriving stock (Eq, Show, Generic)

{- | Map a hasql UsageError to an StoreError.

Pattern matches on the error hierarchy:
  UsageError -> SessionUsageError -> StatementSessionError -> ServerStatementError -> ServerError

PostgreSQL error code mapping:
  23505 (unique_violation) + events_pkey          -> DuplicateEvent
  23505 (unique_violation) + ix_streams_stream_name -> StreamAlreadyExists
  23505 (unique_violation) + other                  -> WrongExpectedVersion
  23503 (foreign_key_violation)                     -> StreamNotFound
-}
mapUsageError :: Text -> ExpectedVersion -> UsageError -> StoreError
mapUsageError streamName expected = \case
    SessionUsageError sessionErr ->
        mapSessionError streamName expected sessionErr
    ConnectionUsageError connErr ->
        ConnectionError ("Connection error: " <> T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        ConnectionError "Connection pool acquisition timeout"

mapSessionError :: Text -> ExpectedVersion -> Errors.SessionError -> StoreError
mapSessionError streamName expected = \case
    Errors.StatementSessionError _ _ _ _ _ stmtErr ->
        mapStatementError streamName expected stmtErr
    other ->
        ConnectionError ("Session error: " <> T.pack (show other))

mapStatementError :: Text -> ExpectedVersion -> Errors.StatementError -> StoreError
mapStatementError streamName expected = \case
    Errors.ServerStatementError serverErr ->
        mapServerError streamName expected serverErr
    other ->
        ConnectionError ("Statement error: " <> T.pack (show other))

mapServerError :: Text -> ExpectedVersion -> Errors.ServerError -> StoreError
mapServerError streamName expected (Errors.ServerError code message detail _hint _position)
    | code == "23505" = mapUniqueViolation streamName expected message detail
    | code == "23503" = StreamNotFound (StreamName streamName)
    | otherwise = ConnectionError ("Server error " <> code <> ": " <> message)

{- | Map a unique_violation (23505) to an StoreError.

PostgreSQL reports constraint violations with:
  - message: "duplicate key value violates unique constraint \"events_pkey\""
  - detail: "Key (event_id)=(uuid-value) already exists."

We check both message and detail for the constraint name.
-}
mapUniqueViolation :: Text -> ExpectedVersion -> Text -> Maybe Text -> StoreError
mapUniqueViolation streamName expected message detail
    | containsConstraint "events_pkey" = DuplicateEvent (extractEventId detail)
    | containsConstraint "ix_streams_stream_name" = StreamAlreadyExists (StreamName streamName)
    | otherwise =
        -- Generic unique violation — treat as version conflict
        WrongExpectedVersion (StreamName streamName) expected (StreamVersion 0)
  where
    containsConstraint name =
        name `T.isInfixOf` message || maybe False (T.isInfixOf name) detail

    -- Try to extract event_id from detail like "Key (event_id)=(uuid) already exists."
    extractEventId (Just d) = case extractUuidFromDetail d of
        Just uid -> EventId uid
        Nothing -> EventId nilUUID
    extractEventId Nothing = EventId nilUUID

    nilUUID = UUID.nil

{- | Infer the appropriate error from an empty CTE result.

When the CTE returns 0 rows (no ServerError raised), the version check
or existence check failed silently. Map based on the ExpectedVersion:
  ExactVersion v -> WrongExpectedVersion (version mismatch, or soft-deleted)
  StreamExists   -> StreamNotFound (stream doesn't exist, or soft-deleted)
  NoStream       -> StreamAlreadyExists (stream already exists)
  AnyVersion     -> StreamNotFound (only happens when the existing row is
                    soft-deleted and the upsert's DO UPDATE WHERE filter
                    rejects it; the soft-delete CTE filter was added in
                    EP-1 F2, so this branch is the soft-deleted-stream case)
-}
emptyResultError :: Text -> ExpectedVersion -> StoreError
emptyResultError streamName = \case
    ExactVersion v ->
        WrongExpectedVersion (StreamName streamName) (ExactVersion v) (StreamVersion 0)
    StreamExists ->
        StreamNotFound (StreamName streamName)
    NoStream ->
        StreamAlreadyExists (StreamName streamName)
    AnyVersion ->
        StreamNotFound (StreamName streamName)

{- | Extract a UUID from a PostgreSQL detail string like:
"Key (event_id)=(01234567-89ab-7def-8012-34567890abcd) already exists."
-}
extractUuidFromDetail :: Text -> Maybe UUID
extractUuidFromDetail detail =
    case T.breakOn "=(" detail of
        (_, rest)
            | not (T.null rest) ->
                let afterParen = T.drop 2 rest -- skip "=("
                    uuidText = T.takeWhile (/= ')') afterParen
                 in UUID.fromText uuidText
        _ -> Nothing
