module Kiroku.Store.Error (
    StoreError (..),

    -- * Append-precondition conflicts (Tx-flavored)
    AppendConflict (..),
    appendConflictToStoreError,
    emptyResultConflict,
    -- Internal helpers used by Effect module
    mapGenericUsageError,
    mapLinkUsageError,
    mapUsageError,
    emptyResultError,
    attributeMultiStreamError,
    isTransientSerializationError,
    -- Internal pure helper exposed for unit testing
    extractStreamNameFromDetail,
) where

import Control.Exception (Exception)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Hasql.Errors qualified as Errors
import Hasql.Pool (UsageError (..))
import Kiroku.Store.Types

{- | Errors that can occur during store operations.

The constructor set is designed for additive evolution: new failure modes
are added rather than changing existing constructors. Pattern matches that
do not handle a new constructor will surface as @-Wincomplete-patterns@
warnings, never as silent misclassification.

The 'ConnectionError' catch-all is retained for backward compatibility:
anything not matched by a more specific constructor falls through to it.
Consumers should match on the specific constructors first when they want
to make retry-vs-escalate decisions.

'StoreError' derives 'Exception' so it can be thrown with 'throwIO' from
any 'IO' or 'MonadIO' context. The standard pattern for store callers
remains @runStoreIO :: IO (Either StoreError a)@; the 'Exception' instance
is for callers who prefer the exception-based idiom (e.g., when bridging
to libraries that expect 'SomeException').
-}
data StoreError
    = {- | The actual stream version did not match the caller's
      'ExactVersion' expectation. The third field is the actual
      version placeholder. The append statement returns zero rows on a
      version mismatch and the store does not issue an extra read to
      recover the live version, so this field is 'StreamVersion' 0 on
      every empty-CTE rejection. Callers needing the live version must
      read the stream, for example with 'Kiroku.Store.Read.getStream'.
      -}
      WrongExpectedVersion !StreamName !ExpectedVersion !StreamVersion
    | {- | The caller supplied an empty event batch to an append surface.

      Appending zero events is always a programming mistake: before this
      guard existed, an empty batch silently took the global @$all@ row
      lock, fired NOTIFY triggers, and under 'NoStream' even created an
      empty stream. The interpreter rejects it before any pool work.
      -}
      EmptyAppendBatch !StreamName
    | -- | The named stream does not exist (or has been soft-deleted).
      StreamNotFound !StreamName
    | {- | The named stream is reserved for store internals and cannot be
      used as an application stream target. For now this applies only
      to @$all@, which is the global read stream backed by the seeded
      @streams.stream_id = 0@ row.
      -}
      ReservedStreamName !StreamName
    | {- | The named stream already exists. Returned for 'NoStream'
      expectations against an existing stream and for 'linkToStream'
      targets that already exist with conflicting state.
      -}
      StreamAlreadyExists !StreamName
    | {- | A caller-supplied @event_id@ collides with an existing event.

      The constructor carries 'Just' the id when the PostgreSQL detail
      string could be parsed, 'Nothing' otherwise. A 'Nothing' payload
      is rare in practice; it occurs when the server's locale changes
      the detail-string format. Consumers that want to surface the
      offending id to the user should match on 'Just'.
      -}
      DuplicateEvent !(Maybe EventId)
    | {- | A 'Kiroku.Store.Link.linkToStream' call tried to link an
      event into a target stream that already contains it.

      Maps the @23505@ unique violation on @stream_events_pkey@, whose
      key is @(event_id, stream_id)@. Carries 'Just' the offending event
      id when PostgreSQL's detail string is parseable.
      -}
      EventAlreadyLinked !StreamName !(Maybe EventId)
    | {- | A 'Kiroku.Store.Link.linkToStream' call referenced an event id
      that does not exist. The link CTE surfaces this as a @23502@
      not-null violation on @stream_events.original_stream_id@ and the
      whole batch rolls back.
      -}
      LinkSourceEventMissing !StreamName
    | {- | The connection pool timed out acquiring a connection. Almost
      always retryable after a small backoff; sustained timeouts
      indicate that the pool is undersized for the offered load or
      that the database is unreachable.
      -}
      PoolAcquisitionTimeout
    | {- | A network or session-level error tore down the connection
      mid-operation. The 'Text' carries the underlying hasql error
      description for diagnostics. Retryable in most cases.
      -}
      ConnectionLost !Text
    | {- | PostgreSQL raised a server error whose @SQLSTATE@ code is
      outside the set this store recognises (currently @23505@
      unique violation and @23503@ foreign key violation). The first
      'Text' is the @SQLSTATE@ code, the second is the human-readable
      message. This is *not* generally retryable — investigate.
      -}
      UnexpectedServerError !Text !Text
    | {- | Catch-all for everything not matched by a more specific
      constructor above. Retained for backward compatibility with
      consumers that already pattern-match on it; new code should
      prefer the specific constructors.
      -}
      ConnectionError !Text
    deriving stock (Eq, Show, Generic)
    deriving anyclass (Exception)

{- | Map a hasql 'UsageError' to a 'StoreError'.

Pattern matches on the error hierarchy:
  UsageError -> SessionUsageError -> StatementSessionError -> ServerStatementError -> ServerError

PostgreSQL error code mapping:
  23505 (unique_violation) + events_pkey            -> 'DuplicateEvent'
  23505 (unique_violation) + ix_streams_stream_name -> 'StreamAlreadyExists'
  23505 (unique_violation) + other                  -> 'WrongExpectedVersion'
  23503 (foreign_key_violation)                     -> 'StreamNotFound'
  any other server code                             -> 'UnexpectedServerError'

The constraint-name matching depends on the literal strings @events_pkey@
and @ix_streams_stream_name@. If a future schema migration renames a
constraint, the @23505@ branch falls through to the generic
'WrongExpectedVersion' mapping; keep the names stable in
@kiroku-store-migrations/sql-migrations@.
-}
mapUsageError :: Text -> ExpectedVersion -> UsageError -> StoreError
mapUsageError streamName expected = \case
    SessionUsageError sessionErr ->
        mapSessionError streamName expected sessionErr
    ConnectionUsageError connErr ->
        ConnectionLost (T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        PoolAcquisitionTimeout

-- | Generic, non-append-shaped mapping for hasql pool usage errors.
mapGenericUsageError :: UsageError -> StoreError
mapGenericUsageError = \case
    ConnectionUsageError connErr ->
        ConnectionLost (T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        PoolAcquisitionTimeout
    SessionUsageError sessionErr ->
        case extractServerError (SessionUsageError sessionErr) of
            Just (Errors.ServerError code message _ _ _) ->
                UnexpectedServerError code message
            Nothing ->
                ConnectionError ("Session error: " <> T.pack (show sessionErr))

-- | Map link-specific hasql failures to typed link errors.
mapLinkUsageError :: StreamName -> UsageError -> StoreError
mapLinkUsageError target usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError "23505" message detail _ _)
            | containsConstraint "stream_events_pkey" message detail ->
                EventAlreadyLinked target (extractCompositeEventId detail)
        Just (Errors.ServerError "23502" _ _ _ _) ->
            LinkSourceEventMissing target
        _ ->
            mapGenericUsageError usageErr
  where
    containsConstraint name message detail =
        name `T.isInfixOf` message || maybe False (T.isInfixOf name) detail

    extractCompositeEventId (Just d) = EventId <$> extractFirstUuidFromCompositeDetail d
    extractCompositeEventId Nothing = Nothing

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
    | otherwise = UnexpectedServerError code message

{- | Map a unique_violation (23505) to an StoreError.

PostgreSQL reports constraint violations with:
  - message: "duplicate key value violates unique constraint \"events_pkey\""
  - detail: "Key (event_id)=(uuid-value) already exists."

We check both message and detail for the constraint name.

When the events_pkey case fires but the detail string cannot be parsed
(e.g., the server's locale produced an unexpected format), the
'DuplicateEvent' constructor carries 'Nothing' rather than a fabricated
all-zeroes UUID — see 'extractEventId'.
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
    extractEventId (Just d) = EventId <$> extractUuidFromDetail d
    extractEventId Nothing = Nothing

{- | Append-precondition failures observable inside a
'Hasql.Transaction.Transaction' body.

'Kiroku.Store.Transaction.appendToStreamTx' returns
@'Either' 'AppendConflict' 'AppendResult'@ rather than throwing, because
'Hasql.Transaction.Transaction' has no exception channel — the caller
decides whether to call 'Hasql.Transaction.condemn', branch around the
conflict, or recover. Reserved-stream rejection is /not/ part of this
sum because callers of 'Kiroku.Store.Transaction.appendToStreamTx' are
expected to validate the stream name themselves before entering the
transaction body (the high-level wrapper
'Kiroku.Store.Transaction.runTransactionAppending' does so prior to
opening the transaction and surfaces 'ReservedStreamName' as a
'StoreError' instead).

The constructors are 1:1 with the corresponding 'StoreError' variants —
see 'appendConflictToStoreError'.
-}
data AppendConflict
    = {- | Mirror of 'WrongExpectedVersion'. The third field is the
      stream-version placeholder. The append statement returns zero
      rows on a version mismatch and the store does not issue an extra
      read to recover the live version, so this field is
      @'StreamVersion' 0@ on every empty-CTE rejection.
      -}
      WrongExpectedVersionConflict !StreamName !ExpectedVersion !StreamVersion
    | -- | Mirror of 'EmptyAppendBatch'.
      EmptyAppendBatchConflict !StreamName
    | -- | Mirror of 'StreamNotFound'.
      StreamNotFoundConflict !StreamName
    | -- | Mirror of 'StreamAlreadyExists'.
      StreamAlreadyExistsConflict !StreamName
    deriving stock (Eq, Show, Generic)

{- | Project an 'AppendConflict' onto the corresponding 'StoreError'
constructor. Used by 'Kiroku.Store.Transaction.runTransactionAppending'
when surfacing conflicts at the @Eff@ boundary.
-}
appendConflictToStoreError :: AppendConflict -> StoreError
appendConflictToStoreError = \case
    WrongExpectedVersionConflict sn ev sv -> WrongExpectedVersion sn ev sv
    EmptyAppendBatchConflict sn -> EmptyAppendBatch sn
    StreamNotFoundConflict sn -> StreamNotFound sn
    StreamAlreadyExistsConflict sn -> StreamAlreadyExists sn

{- | Infer the appropriate 'AppendConflict' from an empty CTE result.

Mirror of 'emptyResultError' for the 'AppendConflict' surface. When the
CTE returns 0 rows, the version check or existence check failed
silently — the constructor depends on the supplied 'ExpectedVersion':

  ExactVersion v -> WrongExpectedVersionConflict (version mismatch or
                    soft-deleted)
  StreamExists   -> StreamNotFoundConflict (missing or soft-deleted)
  NoStream       -> StreamAlreadyExistsConflict
  AnyVersion     -> StreamNotFoundConflict (only happens when the
                    existing row is soft-deleted and the upsert's DO
                    UPDATE WHERE filter rejects it)
-}
emptyResultConflict :: StreamName -> ExpectedVersion -> AppendConflict
emptyResultConflict sn = \case
    ExactVersion v ->
        WrongExpectedVersionConflict sn (ExactVersion v) (StreamVersion 0)
    StreamExists ->
        StreamNotFoundConflict sn
    NoStream ->
        StreamAlreadyExistsConflict sn
    AnyVersion ->
        StreamNotFoundConflict sn

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
emptyResultError streamName expected =
    appendConflictToStoreError
        (emptyResultConflict (StreamName streamName) expected)

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

{- | Extract the first UUID from a PostgreSQL composite-key detail string like:
"Key (event_id, stream_id)=(01234567-89ab-7def-8012-34567890abcd, 42) already exists."
-}
extractFirstUuidFromCompositeDetail :: Text -> Maybe UUID
extractFirstUuidFromCompositeDetail detail =
    case T.breakOn "=(" detail of
        (_, rest)
            | not (T.null rest) ->
                let afterParen = T.drop 2 rest -- skip "=("
                    uuidText = T.strip (T.takeWhile (\c -> c /= ',' && c /= ')') afterParen)
                 in UUID.fromText uuidText
        _ -> Nothing

{- | Extract a stream name from a PostgreSQL unique-violation detail string
like @"Key (stream_name)=(orders-1) already exists."@.

Returns @Nothing@ when the format is unrecognized — most commonly because
the server emitted a non-English locale variant or because a future schema
change altered the constraint's column. Callers should use a sensible
fallback (e.g., the first stream in a multi-stream operation) rather than
treat 'Nothing' as a fatal condition.
-}
extractStreamNameFromDetail :: Text -> Maybe Text
extractStreamNameFromDetail detail =
    case T.breakOn "=(" detail of
        (_, rest)
            | not (T.null rest) ->
                let afterParen = T.drop 2 rest -- skip "=("
                    inner = T.takeWhile (/= ')') afterParen
                 in if T.null inner then Nothing else Just inner
        _ -> Nothing

{- | For 'appendMultiStream' errors, recover the offending stream from the
PostgreSQL detail string when possible.

The multi-stream interpreter's transaction returns a single
@Either UsageError result@; per-statement attribution is not visible at the
@hasql@ layer. When the failure is a @23505@ unique violation on
@ix_streams_stream_name@, the PostgreSQL detail string carries the
offending stream name (e.g., @"Key (stream_name)=(multi-c) already exists."@)
and we look up the matching op to recover its 'ExpectedVersion'.

When the detail cannot be parsed (any other failure mode, including
@events_pkey@ violations whose 'DuplicateEvent' constructor carries no
stream attribution, generic server errors, and connection errors), we fall
back to attributing against the first stream in the input list and let
'mapUsageError' map the rest.

This is defensive — the current SQL paths in @kiroku-store/src/Kiroku/Store/SQL.hs@
do not raise @ix_streams_stream_name@ violations because every append CTE
uses @ON CONFLICT DO NOTHING@/@DO UPDATE@ — but a future schema change could
introduce a path that does, and the attribution should be correct from day
one.
-}
attributeMultiStreamError ::
    {- | The (name, expected) pairs from the multi-stream ops, in the order
    the caller supplied them.
    -}
    [(StreamName, ExpectedVersion)] ->
    UsageError ->
    StoreError
attributeMultiStreamError [] usageErr =
    -- Defensive: an empty multi-stream call should not reach the
    -- transaction layer, but if it somehow does, surface the raw error.
    ConnectionError ("Empty multi-stream usage error: " <> T.pack (show usageErr))
attributeMultiStreamError ops@((StreamName firstName, firstExpected) : _) usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError "23505" message (Just detail) _ _)
            | "ix_streams_stream_name" `T.isInfixOf` message
                || "ix_streams_stream_name" `T.isInfixOf` detail
            , Just sn <- extractStreamNameFromDetail detail
            , Just (StreamName name, expected) <- lookupStream sn ops ->
                mapUsageError name expected usageErr
        _ ->
            mapUsageError firstName firstExpected usageErr
  where
    lookupStream tgt = lookup' tgt
    lookup' _ [] = Nothing
    lookup' tgt (op@(StreamName n, _) : rest)
        | n == tgt = Just op
        | otherwise = lookup' tgt rest

-- | Walk a 'UsageError' down to the underlying 'Errors.ServerError', if any.
extractServerError :: UsageError -> Maybe Errors.ServerError
extractServerError = \case
    SessionUsageError (Errors.StatementSessionError _ _ _ _ _ stmtErr) ->
        case stmtErr of
            Errors.ServerStatementError serverErr -> Just serverErr
            _ -> Nothing
    _ -> Nothing

-- | True for PostgreSQL transient transaction aborts retried by hasql-transaction.
isTransientSerializationError :: UsageError -> Bool
isTransientSerializationError usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError code _ _ _ _) ->
            code == "40001" || code == "40P01"
        Nothing ->
            False
