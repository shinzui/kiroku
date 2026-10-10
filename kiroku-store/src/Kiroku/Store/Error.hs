module Kiroku.Store.Error (
    StoreError (..),
    maxStreamNameBytes,
    validateStreamName,

    -- * Append-precondition conflicts (Tx-flavored)
    AppendConflict (..),
    appendConflictToStoreError,
    emptyResultConflict,
    -- Internal helpers used by Effect module
    mapGenericUsageError,
    mapLinkUsageError,
    mapTransactionUsageError,
    mapUsageError,
    emptyResultError,
    attributeMultiStreamError,
    isTransientSerializationError,
    -- Internal pure helper exposed for unit testing
    extractStreamNameFromDetail,
) where

import Control.Applicative ((<|>))
import Control.Exception (Exception)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)
import Hasql.Errors qualified as Errors
import Hasql.Pool (UsageError (..))
import Kiroku.Store.HistoryRetention.Types (HistoryRetentionConflict)
import Kiroku.Store.Settings (DecodeFailure)
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
    | {- | A supported hard delete found one or more active replay-history
      retention leases and committed no destructive work.
      -}
      HistoryRetentionActive !StreamName !HistoryRetentionConflict
    | {- | The named stream is reserved for store internals and cannot be
      used as an application stream target. For now this applies only
      to @$all@, which is the global read stream backed by the seeded
      @streams.stream_id = 0@ row.
      -}
      ReservedStreamName !StreamName
    | {- | The stream name exceeds 'maxStreamNameBytes' bytes of UTF-8.

      The append notification payload embeds the stream name, and
      PostgreSQL rejects @pg_notify@ payloads of 8,000 bytes or more.
      Enforcing a much smaller byte bound before any database work
      prevents an oversized stream name from failing late as an opaque
      trigger/server error. The second field is the offending UTF-8
      byte length.
      -}
      StreamNameTooLong !StreamName !Int
    | {- | The named stream already exists. Returned for 'NoStream'
      expectations against an existing stream and for 'linkToStream'
      targets that already exist with conflicting state.
      -}
      StreamAlreadyExists !StreamName
    | {- | A caller-supplied @event_id@ collides with an existing event.

      Append maps both @events_pkey@ and the composite
      @stream_events_pkey@ to this constructor.

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
    | {- | PostgreSQL aborted the transaction with a class-40
      (transaction rollback) @SQLSTATE@: @40001@ serialization_failure
      or @40P01@ deadlock_detected. The first 'Text' is the @SQLSTATE@
      code, the second is the human-readable message.

      __Retryable.__ PostgreSQL rolled the transaction back completely
      and expects the client to run it again; nothing was committed.
      The store already retries an append once on these codes before
      surfacing them, so reaching a caller means the conflict repeated
      — retry with backoff rather than escalating.

      Appends are safe to retry when the caller supplies
      'Kiroku.Store.Types.EventData.eventId' values, which makes the
      retry idempotent; see the "Idempotent retries" note on
      'Kiroku.Store.Append.appendToStream'.
      -}
      TransientTransactionFailure !Text !Text
    | {- | PostgreSQL raised a server error whose @SQLSTATE@ code is
      outside the set this store recognises, or an append violated
      @ux_stream_events_stream_version@ (@23505@), indicating an
      internal stream-version invariant failure. The
      first 'Text' is the @SQLSTATE@ code, the second is the
      human-readable message. This is *not* generally retryable —
      investigate.
      -}
      UnexpectedServerError !Text !Text
    | {- | Catch-all for everything not matched by a more specific
      constructor above. Retained for backward compatibility with
      consumers that already pattern-match on it; new code should
      prefer the specific constructors.
      -}
      ConnectionError !Text
    | -- | A decode hook refused an event; the read returns no partial result.
      EventDecodeFailed !DecodeFailure
    deriving stock (Eq, Show, Generic)
    deriving anyclass (Exception)

-- | Maximum stream-name length in UTF-8 bytes.
maxStreamNameBytes :: Int
maxStreamNameBytes = 512

-- | Validate application stream names before any database work.
validateStreamName :: StreamName -> Either StoreError ()
validateStreamName sn@(StreamName name)
    | name == "$all" = Left (ReservedStreamName sn)
    | byteLength > maxStreamNameBytes = Left (StreamNameTooLong sn byteLength)
    | otherwise = Right ()
  where
    byteLength = BS.length (TE.encodeUtf8 name)

{- | Map a hasql 'UsageError' to a 'StoreError'.

Pattern matches on the error hierarchy:
  UsageError -> SessionUsageError -> StatementSessionError -> ServerStatementError -> ServerError

PostgreSQL error code mapping:
  23505 (unique_violation) + events_pkey            -> 'DuplicateEvent'
  23505 (unique_violation) + stream_events_pkey     -> 'DuplicateEvent'
  23505 + ux_stream_events_stream_version          -> 'UnexpectedServerError'
  23505 (unique_violation) + ix_streams_stream_name -> 'StreamAlreadyExists'
  23505 (unique_violation) + other                  -> 'WrongExpectedVersion'
  23503 (foreign_key_violation)                     -> 'StreamNotFound'
  40001 / 40P01                                    -> 'TransientTransactionFailure'
  any other server code                             -> 'UnexpectedServerError'

Constraint names are compared exactly, with the quoted message taking
precedence over a delimiter-aware detail fallback. Matching depends on the
four literal names above. If a future schema migration renames a
constraint, the @23505@ branch falls through to the generic
'WrongExpectedVersion' mapping; keep the names stable in
@kiroku-store-migrations/migrations@.
-}
mapUsageError :: Text -> ExpectedVersion -> UsageError -> StoreError
mapUsageError streamName expected = \case
    SessionUsageError sessionErr ->
        mapSessionError streamName expected sessionErr
    ConnectionUsageError connErr ->
        ConnectionLost (T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        PoolAcquisitionTimeout

{- | Map a hasql 'UsageError' raised inside an opaque transaction body.

The body has no stream context, so append duplicate violations are mapped
directly to 'DuplicateEvent'. Every other failure uses the generic mapper so
its SQLSTATE and server message survive without inventing stream context.
-}
mapTransactionUsageError :: UsageError -> StoreError
mapTransactionUsageError usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError "23505" message detail _ _)
            | uniqueConstraintName message detail == Just "events_pkey" ->
                DuplicateEvent (EventId <$> (detail >>= extractUuidFromDetail))
            | uniqueConstraintName message detail == Just "stream_events_pkey" ->
                DuplicateEvent (EventId <$> (detail >>= extractFirstUuidFromCompositeDetail))
        _ ->
            mapGenericUsageError usageErr

-- | Generic, non-append-shaped mapping for hasql pool usage errors.
mapGenericUsageError :: UsageError -> StoreError
mapGenericUsageError = \case
    ConnectionUsageError connErr ->
        ConnectionLost (T.pack (show connErr))
    AcquisitionTimeoutUsageError ->
        PoolAcquisitionTimeout
    SessionUsageError sessionErr ->
        case extractServerError (SessionUsageError sessionErr) of
            Just (Errors.ServerError code message _ _ _)
                | isTransientTransactionCode code ->
                    TransientTransactionFailure code message
                | otherwise ->
                    UnexpectedServerError code message
            Nothing ->
                ConnectionError ("Session error: " <> T.pack (show sessionErr))

-- | Map link-specific hasql failures to typed link errors.
mapLinkUsageError :: StreamName -> UsageError -> StoreError
mapLinkUsageError target usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError "23505" message detail _ _)
            | uniqueConstraintName message detail == Just "stream_events_pkey" ->
                EventAlreadyLinked target (extractCompositeEventId detail)
        Just (Errors.ServerError "23502" _ _ _ _) ->
            LinkSourceEventMissing target
        _ ->
            mapGenericUsageError usageErr
  where
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
    | isTransientTransactionCode code = TransientTransactionFailure code message
    | otherwise = UnexpectedServerError code message

{- | Map a unique_violation (23505) to an StoreError.

PostgreSQL reports constraint violations with:
  - message: "duplicate key value violates unique constraint \"events_pkey\""
  - detail: "Key (event_id)=(uuid-value) already exists."

We extract one constraint name, preferring the quoted message over detail,
then compare it exactly. Composite link keys use their first UUID. A
stream-version index violation is an invariant failure, not a precondition
conflict, and preserves the SQLSTATE and original message.

When the events_pkey case fires but the detail string cannot be parsed
(e.g., the server's locale produced an unexpected format), the
'DuplicateEvent' constructor carries 'Nothing' rather than a fabricated
all-zeroes UUID.
-}
mapUniqueViolation :: Text -> ExpectedVersion -> Text -> Maybe Text -> StoreError
mapUniqueViolation streamName expected message detail =
    case uniqueConstraintName message detail of
        Just "events_pkey" -> DuplicateEvent (EventId <$> (detail >>= extractUuidFromDetail))
        Just "stream_events_pkey" -> DuplicateEvent (EventId <$> (detail >>= extractFirstUuidFromCompositeDetail))
        Just "ix_streams_stream_name" -> StreamAlreadyExists (StreamName streamName)
        Just "ux_stream_events_stream_version" -> UnexpectedServerError "23505" message
        _ ->
            -- Generic unique violation — treat as version conflict
            WrongExpectedVersion (StreamName streamName) expected (StreamVersion 0)

{- | PostgreSQL's quoted constraint wins even when it is unknown. Legacy
detail-only errors may name an owned constraint as a complete identifier;
underscores and dollar signs are identifier characters, not delimiters.
This helper is used only after a failed statement has returned SQLSTATE 23505.
-}
uniqueConstraintName :: Text -> Maybe Text -> Maybe Text
uniqueConstraintName message detail =
    quotedConstraint message <|> (detail >>= fromDetail)
  where
    quotedConstraint input =
        case T.breakOn "unique constraint \"" input of
            (_, rest)
                | not (T.null rest) ->
                    let (name, closing) = T.breakOn "\"" (T.drop (T.length "unique constraint \"") rest)
                     in if T.null name || T.null closing then Nothing else Just name
            _ -> Nothing
    fromDetail input =
        quotedConstraint input <|> find (`elem` ownedConstraints) (T.split (not . identifierChar) input)
    identifierChar c = isAlphaNum c || c == '_' || c == '$'
    ownedConstraints = ["events_pkey", "stream_events_pkey", "ix_streams_stream_name", "ux_stream_events_stream_version"]

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
            | uniqueConstraintName message (Just detail) == Just "ix_streams_stream_name"
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

{- | True for PostgreSQL class-40 (transaction rollback) @SQLSTATE@ codes:
@40001@ serialization_failure and @40P01@ deadlock_detected.

These are the codes hasql-transaction retries, and the ones the store maps to
'TransientTransactionFailure'. Kept as one predicate so the retry decision and
the error classification can never drift apart.
-}
isTransientTransactionCode :: Text -> Bool
isTransientTransactionCode code = code == "40001" || code == "40P01"

-- | True for PostgreSQL transient transaction aborts retried by hasql-transaction.
isTransientSerializationError :: UsageError -> Bool
isTransientSerializationError usageErr =
    case extractServerError usageErr of
        Just (Errors.ServerError code _ _ _ _) ->
            isTransientTransactionCode code
        Nothing ->
            False
