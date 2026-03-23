module Kiroku.Store.Error (
    AppendError (..),
    -- Internal helpers used by Append module
    mapUsageError,
    emptyResultError,
) where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Hasql.Errors qualified as Errors
import Hasql.Pool (UsageError (..))
import Kiroku.Store.Types

-- | Errors that can occur during an append operation.
data AppendError
    = WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
    | StreamNotFound !StreamName
    | StreamAlreadyExists !StreamName
    | DuplicateEvent !EventId
    | -- | An unexpected error from the database that doesn't map to a known append error.
      UnexpectedError !Text
    deriving stock (Eq, Show, Generic)

{- | Map a hasql UsageError to an AppendError.

Pattern matches on the error hierarchy:
  UsageError -> SessionUsageError -> StatementSessionError -> ServerStatementError -> ServerError

PostgreSQL error code mapping:
  23505 (unique_violation) + events_pkey          -> DuplicateEvent
  23505 (unique_violation) + ix_streams_stream_name -> StreamAlreadyExists
  23505 (unique_violation) + other                  -> WrongExpectedVersion
  23503 (foreign_key_violation)                     -> StreamNotFound
-}
mapUsageError :: Text -> ExpectedVersion -> UsageError -> AppendError
mapUsageError streamName expected = \case
    SessionUsageError sessionErr ->
        mapSessionError streamName expected sessionErr
    ConnectionUsageError connErr ->
        UnexpectedError ("Connection error: " <> T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        UnexpectedError "Connection pool acquisition timeout"

mapSessionError :: Text -> ExpectedVersion -> Errors.SessionError -> AppendError
mapSessionError streamName expected = \case
    Errors.StatementSessionError _ _ _ _ _ stmtErr ->
        mapStatementError streamName expected stmtErr
    other ->
        UnexpectedError ("Session error: " <> T.pack (show other))

mapStatementError :: Text -> ExpectedVersion -> Errors.StatementError -> AppendError
mapStatementError streamName expected = \case
    Errors.ServerStatementError serverErr ->
        mapServerError streamName expected serverErr
    other ->
        UnexpectedError ("Statement error: " <> T.pack (show other))

mapServerError :: Text -> ExpectedVersion -> Errors.ServerError -> AppendError
mapServerError streamName expected (Errors.ServerError code _message detail _hint _position)
    | code == "23505" = mapUniqueViolation streamName expected detail
    | code == "23503" = StreamNotFound (StreamName streamName)
    | otherwise = UnexpectedError ("Server error " <> code <> ": " <> T.pack (show detail))

mapUniqueViolation :: Text -> ExpectedVersion -> Maybe Text -> AppendError
mapUniqueViolation streamName expected detail =
    case detail of
        Just d
            | "events_pkey" `T.isInfixOf` d ->
                -- TODO: extract event_id from detail if possible
                DuplicateEvent (EventId (error "TODO: extract event_id from constraint detail"))
            | "ix_streams_stream_name" `T.isInfixOf` d ->
                StreamAlreadyExists (StreamName streamName)
        _ ->
            -- Generic unique violation — treat as version conflict
            WrongExpectedVersion (StreamName streamName) expected (StreamVersion 0)

{- | Infer the appropriate error from an empty CTE result.

When the CTE returns 0 rows (no ServerError raised), the version check
or existence check failed silently. Map based on the ExpectedVersion:
  ExactVersion v -> WrongExpectedVersion (version mismatch)
  StreamExists   -> StreamNotFound (stream doesn't exist)
  NoStream       -> StreamAlreadyExists (stream already exists)
  AnyVersion     -> should never happen
-}
emptyResultError :: Text -> ExpectedVersion -> AppendError
emptyResultError streamName = \case
    ExactVersion v ->
        WrongExpectedVersion (StreamName streamName) (ExactVersion v) (StreamVersion 0)
    StreamExists ->
        StreamNotFound (StreamName streamName)
    NoStream ->
        StreamAlreadyExists (StreamName streamName)
    AnyVersion ->
        UnexpectedError "AnyVersion append returned empty result (unexpected)"
