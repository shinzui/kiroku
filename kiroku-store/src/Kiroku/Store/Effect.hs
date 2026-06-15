{-# LANGUAGE TypeFamilies #-}

module Kiroku.Store.Effect (
    -- * The Store effect
    Store (..),

    -- * Interpreters
    runStorePool,
    runStoreResource,
    runStoreIO,

    -- * Internal building blocks

    --
    -- $internal
    PreparedEvent,
    prepareEvents,
    buildAppendParams,
    appendDispatchTx,
) where

import Control.Lens ((^.))
import Control.Monad.Except qualified as Except
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V7 qualified as V7
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pipeline qualified as Pipeline
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Error (StoreError (..), attributeMultiStreamError, emptyResultError, isTransientSerializationError, mapLinkUsageError, mapTransactionUsageError, mapUsageError, validateStreamName)
import Kiroku.Store.Observability (KirokuEvent (..))
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (decodeEvents, enrichEvents)
import Kiroku.Store.Types

-- ---------------------------------------------------------------------------
-- Store effect
-- ---------------------------------------------------------------------------

-- | The Store effect — dynamically dispatched, mockable.
data Store :: Effect where
    AppendToStream :: StreamName -> ExpectedVersion -> [EventData] -> Store m AppendResult
    ReadStreamForward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
    ReadStreamBackward :: StreamName -> StreamVersion -> Int32 -> Store m (Vector RecordedEvent)
    ReadAllForward :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    ReadAllBackward :: GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    GetStream :: StreamName -> Store m (Maybe StreamInfo)
    {- | Resolve a 'StreamName' to its surrogate 'StreamId' without
    materializing the full 'StreamInfo' row. Mirrors 'GetStream'\'s
    soft-delete semantics: returns 'Just' for both live and soft-deleted
    streams, 'Nothing' for hard-deleted or never-created streams.

    Cheaper than 'GetStream' — decodes one @int8@ column instead of five.
    Surfaced as 'Kiroku.Store.Read.lookupStreamId'.
    -}
    LookupStreamId :: StreamName -> Store m (Maybe StreamId)
    {- | Check whether an event id exists in a live stream without materializing
    stream events. Soft-deleted streams behave as nonexistent, mirroring
    'Kiroku.Store.Read.readStreamForward'.

    Surfaced as 'Kiroku.Store.Read.eventExistsInStream'.
    -}
    EventExistsInStream :: StreamName -> EventId -> Store m Bool
    {- | Resolve a batch of surrogate 'StreamId's to their 'StreamName's in a
    single round trip. The result 'Map' contains an entry only for ids that
    name an existing stream (live or soft-deleted); hard-deleted or unknown ids
    are absent.

    The primary use is recovering source stream names from the
    'RecordedEvent.originalStreamId' of events obtained via fan-in reads
    (@$all@, categories, causation/correlation queries, subscriptions): collect
    the distinct ids from a batch and resolve them once, rather than per event.
    Surfaced as 'Kiroku.Store.Read.lookupStreamNames' (and the singular
    'Kiroku.Store.Read.lookupStreamName').
    -}
    LookupStreamNames :: [StreamId] -> Store m (Map StreamId StreamName)
    LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    AppendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Store m [AppendResult]
    {- | Fetch a set of 'RecordedEvent' rows that match an 'EventFilter'.
    Surfaced to consumers as the smart constructors in
    "Kiroku.Store.Causation": 'Kiroku.Store.Causation.findByCorrelation',
    'Kiroku.Store.Causation.findCausationDescendants', and
    'Kiroku.Store.Causation.findCausationAncestors'.

    The filter is a closed sum ('EventFilter'); mock interpreters can
    pattern-match exhaustively.
    -}
    FindEvents :: EventFilter -> Store m (Vector RecordedEvent)
    SoftDeleteStream :: StreamName -> Store m (Maybe StreamId)
    HardDeleteStream :: StreamName -> Store m (Maybe StreamId)
    UndeleteStream :: StreamName -> Store m (Maybe StreamId)
    {- | Run an arbitrary @hasql-transaction@ value in a 'BEGIN'/'COMMIT'
    block on a single pool connection. Escape hatch from the abstract
    'Store' effect into the underlying SQL world; mock interpreters are
    expected to reject this constructor.
    -}
    RunTransaction :: Tx.Transaction a -> Store m a
    {- | Like 'RunTransaction' but uses
    'Hasql.Transaction.Sessions.transactionNoRetry' under the hood —
    the body is run exactly once even on PostgreSQL serialization
    conflicts.
    -}
    RunTransactionNoRetry :: Tx.Transaction a -> Store m a

type instance DispatchOf Store = Dynamic

-- ---------------------------------------------------------------------------
-- PostgreSQL interpreter
-- ---------------------------------------------------------------------------

-- | Interpret Store operations against PostgreSQL via hasql-pool.
runStorePool ::
    (IOE :> es, Error StoreError :> es) =>
    KirokuStore ->
    Eff (Store : es) a ->
    Eff es a
runStorePool store = interpret_ $ \case
    AppendToStream (StreamName name) expected events -> do
        rejectInvalidApplicationStream name
        case events of
            [] -> throwError (EmptyAppendBatch (StreamName name))
            _ -> pure ()
        events' <- liftIO $ enrichEvents (store ^. #storeSettings) events
        now <- liftIO getCurrentTime
        prepared <- prepareEvents events'
        let params = buildAppendParams name now prepared
        let runOnce =
                Pool.use (store ^. #pool) $ case expected of
                    ExactVersion (StreamVersion v) ->
                        Session.statement (params, v) SQL.appendExpectedVersion
                    StreamExists ->
                        Session.statement params SQL.appendStreamExists
                    NoStream ->
                        Session.statement params SQL.appendNoStream
                    AnyVersion ->
                        Session.statement params SQL.appendAnyVersion
        firstAttempt <- liftIO runOnce
        result <- case firstAttempt of
            -- Match hasql-transaction's retryable SQLSTATE set, but only once:
            -- PostgreSQL rolls back the victim transaction and event ids were
            -- prepared before the first attempt, so this retry is idempotent.
            Left usageErr
                | isTransientSerializationError usageErr ->
                    liftIO runOnce
            _ ->
                pure firstAttempt
        case result of
            Left usageErr ->
                throwError (mapUsageError name expected usageErr)
            Right Nothing ->
                throwError (emptyResultError name expected)
            Right (Just r) ->
                pure r
    ReadStreamForward (StreamName name) (StreamVersion startVer) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (name, startVer, limit) SQL.readStreamForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ReadStreamBackward (StreamName name) (StreamVersion startVer) limit -> do
        let cursor = if startVer == 0 then maxBound else startVer
        evs <-
            usePool (store ^. #pool) $
                Session.statement (name, cursor, limit) SQL.readStreamBackwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ReadAllForward (GlobalPosition startPos) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (startPos, limit) SQL.readAllForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ReadAllBackward (GlobalPosition startPos) limit -> do
        let cursor = if startPos == 0 then maxBound else startPos
        evs <-
            usePool (store ^. #pool) $
                Session.statement (cursor, limit) SQL.readAllBackwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    GetStream (StreamName name) ->
        usePool (store ^. #pool) $
            Session.statement name SQL.getStreamStmt
    LookupStreamId (StreamName name) ->
        fmap (fmap StreamId) $
            usePool (store ^. #pool) $
                Session.statement name SQL.findStreamIdStmt
    EventExistsInStream (StreamName name) (EventId eid) ->
        usePool (store ^. #pool) $
            Session.statement (name, eid) SQL.eventExistsInStreamStmt
    LookupStreamNames [] ->
        pure Map.empty
    LookupStreamNames sids ->
        fmap
            (Map.fromList . map (\(s, nm) -> (StreamId s, StreamName nm)) . V.toList)
            ( usePool (store ^. #pool) $
                Session.statement [s | StreamId s <- sids] SQL.lookupStreamNamesStmt
            )
    LinkToStream (StreamName name) eventIds -> do
        rejectInvalidApplicationStream name
        let uuids = V.fromList [uid | EventId uid <- eventIds]
        result <-
            liftIO $
                Pool.use (store ^. #pool) $
                    Session.statement (uuids, name) SQL.linkToStreamStmt
        case result of
            Left usageErr -> throwError (mapLinkUsageError (StreamName name) usageErr)
            Right Nothing -> throwError (StreamNotFound (StreamName name))
            Right (Just r) -> pure r
    ReadCategoryForward (CategoryName cat) (GlobalPosition startPos) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (startPos, cat, limit) SQL.readCategoryForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    AppendMultiStream [] ->
        pure []
    AppendMultiStream ops -> do
        case firstStreamNameError ops of
            Just err -> throwError err
            Nothing -> pure ()
        case find (\(_, _, evts) -> null evts) ops of
            Just (sn, _, _) -> throwError (EmptyAppendBatch sn)
            Nothing -> pure ()
        now <- liftIO getCurrentTime
        -- Prepare all events for all streams
        preparedOps <-
            mapM
                ( \(sn, ev, evts) -> do
                    evts' <- liftIO $ enrichEvents (store ^. #storeSettings) evts
                    prepared <- prepareEvents evts'
                    pure (sn, ev, prepared)
                )
                ops
        let names = V.fromList [n | (StreamName n, _, _) <- ops]
        let runOnce =
                Pool.use (store ^. #pool) $
                    runAppendMultiStreamPipeline names now preparedOps
        firstAttempt <- liftIO runOnce
        result <- case firstAttempt of
            -- Match the single-stream append retry and hasql-transaction's
            -- retryable SQLSTATE set. The failed transaction has rolled back,
            -- and event ids were prepared before the first attempt, so retrying
            -- once is idempotent.
            Left usageErr
                | isTransientSerializationError usageErr ->
                    liftIO runOnce
            _ ->
                pure firstAttempt
        case result of
            Left usageErr ->
                throwError (attributeMultiStreamError [(sn, ev) | (sn, ev, _) <- ops] usageErr)
            Right results -> do
                -- Check for any Nothing results (version conflicts)
                let indexed = zip ops results
                mapM
                    ( \((StreamName sn, ev, _), mResult) ->
                        case mResult of
                            Nothing -> throwError (emptyResultError sn ev)
                            Just r -> pure r
                    )
                    indexed
    FindEvents filt -> do
        evs <- case filt of
            FilterCorrelation cid ->
                usePool (store ^. #pool) $
                    Session.statement cid SQL.findByCorrelationStmt
            FilterCausationDescendants (EventId eid) ->
                usePool (store ^. #pool) $
                    Session.statement eid SQL.findCausationDescendantsStmt
            FilterCausationAncestors (EventId eid) ->
                usePool (store ^. #pool) $
                    Session.statement eid SQL.findCausationAncestorsStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    SoftDeleteStream (StreamName name) -> do
        rejectInvalidApplicationStream name
        usePool (store ^. #pool) $
            Session.statement name SQL.softDeleteStreamStmt
    HardDeleteStream (StreamName name) -> do
        rejectInvalidApplicationStream name
        let txn = do
                Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
                mSid <- Tx.statement name SQL.findStreamIdStmt
                case mSid of
                    Nothing -> pure Nothing
                    Just sid -> do
                        originated <- Tx.statement sid SQL.deleteAllRowsForOriginStmt
                        Tx.statement originated SQL.deleteJunctionsByEventIdsStmt
                        linkedIn <- Tx.statement sid SQL.deleteStreamOwnJunctionsStmt
                        let affected = originated <> linkedIn
                        Tx.statement affected SQL.deleteDeadLettersForOrphanedEventsStmt
                        Tx.statement affected SQL.deleteOrphanedEventsStmt
                        Tx.statement sid SQL.deleteStreamRowStmt
                        pure (Just (StreamId sid))
        result <-
            usePool (store ^. #pool) $
                TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
        -- Emit a fail-safe audit signal when the delete actually removed
        -- rows. Compliance-grade audit should still record an
        -- application-level event before calling hardDeleteStream — see
        -- docs/PRODUCTION-DEPLOYMENT.md.
        case result of
            Just sid -> liftIO $ for_ (store ^. #eventHandler) ($ KirokuEventHardDeleteIssued (StreamName name) sid)
            Nothing -> pure ()
        pure result
    UndeleteStream (StreamName name) -> do
        rejectInvalidApplicationStream name
        usePool (store ^. #pool) $
            Session.statement name SQL.undeleteStreamStmt
    RunTransaction tx ->
        runTxOnPool (store ^. #pool) TxSessions.transaction tx
    RunTransactionNoRetry tx ->
        runTxOnPool (store ^. #pool) TxSessions.transactionNoRetry tx

-- | Convenience: run a Store computation to IO.
runStoreIO ::
    KirokuStore ->
    Eff '[Store, Error StoreError, IOE] a ->
    IO (Either StoreError a)
runStoreIO store = runEff . runErrorNoCallStack . runStorePool store

-- | Interpret Store by reading the store handle from 'KirokuStoreResource'.
runStoreResource ::
    (IOE :> es, Error StoreError :> es, KirokuStoreResource :> es) =>
    Eff (Store : es) a ->
    Eff es a
runStoreResource action = do
    store <- getKirokuStore
    runStorePool store action

-- ---------------------------------------------------------------------------
-- Internal pool helper
-- ---------------------------------------------------------------------------

-- | Run a hasql session against the pool, mapping pool errors to 'StoreError'.
usePool ::
    (IOE :> es, Error StoreError :> es) =>
    Pool ->
    Session.Session a ->
    Eff es a
usePool pool session = do
    result <- liftIO (Pool.use pool session)
    case result of
        Left usageErr -> throwError (ConnectionError (T.pack (show usageErr)))
        Right a -> pure a

{- | Run a 'Tx.Transaction' against the pool using the supplied entry
point ('TxSessions.transaction' or 'TxSessions.transactionNoRetry'),
mapping pool errors to 'StoreError'. The isolation level and access
mode mirror 'appendMultiStream' / 'HardDeleteStream'.
-}
runTxOnPool ::
    (IOE :> es, Error StoreError :> es) =>
    Pool ->
    (TxSessions.IsolationLevel -> TxSessions.Mode -> Tx.Transaction a -> Session.Session a) ->
    Tx.Transaction a ->
    Eff es a
runTxOnPool pool entry tx = do
    result <-
        liftIO $
            Pool.use pool $
                entry TxSessions.ReadCommitted TxSessions.Write tx
    case result of
        Left usageErr -> throwError (mapTransactionUsageError usageErr)
        Right a -> pure a

rejectInvalidApplicationStream ::
    (Error StoreError :> es) =>
    Text ->
    Eff es ()
rejectInvalidApplicationStream name =
    either throwError pure (validateStreamName (StreamName name))

firstStreamNameError :: [(StreamName, ExpectedVersion, [EventData])] -> Maybe StoreError
firstStreamNameError ops =
    case find (isLeft . validateStreamName . streamNameOf) ops of
        Just (sn, _, _) -> either Just (const Nothing) (validateStreamName sn)
        Nothing -> Nothing
  where
    streamNameOf (sn, _, _) = sn
    isLeft = either (const True) (const False)

-- ---------------------------------------------------------------------------
-- Internal helpers (moved from Append)
-- ---------------------------------------------------------------------------

-- | An event with a guaranteed event ID (pre-generated if needed).
data PreparedEvent = PreparedEvent
    { peEventId :: !UUID
    , peEventType :: !EventType
    , pePayload :: !Value
    , peMetadata :: !(Maybe Value)
    , peCausationId :: !(Maybe UUID)
    , peCorrelationId :: !(Maybe UUID)
    }
    deriving stock (Generic)

{- | Prepare events by generating UUIDv7s for any event that doesn't
have a caller-supplied event ID.
-}
prepareEvents :: (MonadIO m) => [EventData] -> m [PreparedEvent]
prepareEvents evts = liftIO $ do
    let needCount = length (filter (\(EventData eid _ _ _ _ _) -> isNothing eid) evts)
    newIds <-
        if needCount > 0
            then V7.genUUIDs (fromIntegral needCount)
            else pure []
    pure (assign evts newIds)
  where
    assign :: [EventData] -> [UUID] -> [PreparedEvent]
    assign [] _ = []
    assign (EventData mEid eType ePayload eMeta eCaus eCorr : es) ids =
        case mEid of
            Just (EventId uid) ->
                PreparedEvent uid eType ePayload eMeta eCaus eCorr
                    : assign es ids
            Nothing -> case ids of
                (uid : rest) ->
                    PreparedEvent uid eType ePayload eMeta eCaus eCorr
                        : assign es rest
                [] -> error "prepareEvents: ran out of pre-generated UUIDs (bug)"

-- | Build SQL parameters from prepared events.
buildAppendParams :: Text -> UTCTime -> [PreparedEvent] -> SQL.AppendParams
buildAppendParams name now prepared =
    SQL.AppendParams
        { eventIds = V.fromList (map (^. #peEventId) prepared)
        , eventTypes = V.fromList (map (\e -> let EventType t = e ^. #peEventType in t) prepared)
        , causationIds = V.fromList (map (^. #peCausationId) prepared)
        , correlationIds = V.fromList (map (^. #peCorrelationId) prepared)
        , payloads = V.fromList (map (^. #pePayload) prepared)
        , metadatas = V.fromList (map (^. #peMetadata) prepared)
        , createdAts = V.fromList (replicate (length prepared) now)
        , streamName = name
        }

multiAppendBeginStmt :: Statement () ()
multiAppendBeginStmt = unpreparable "BEGIN" E.noParams D.noResult

multiAppendCommitStmt :: Statement () ()
multiAppendCommitStmt = unpreparable "COMMIT" E.noParams D.noResult

multiAppendRollbackStmt :: Statement () ()
multiAppendRollbackStmt = unpreparable "ROLLBACK" E.noParams D.noResult

runAppendMultiStreamPipeline ::
    Vector Text ->
    UTCTime ->
    [(StreamName, ExpectedVersion, [PreparedEvent])] ->
    Session.Session [Maybe AppendResult]
runAppendMultiStreamPipeline names now preparedOps =
    Except.catchError body $ \err -> do
        Session.statement () multiAppendRollbackStmt
        Except.throwError err
  where
    body = do
        results <-
            Session.pipeline $
                Pipeline.statement () multiAppendBeginStmt
                    -- Pre-lock the user-named streams in deterministic (stream_id)
                    -- order to avoid row-lock deadlocks between concurrent
                    -- multi-stream txns touching overlapping streams in different
                    -- user orders. See EP-1 F4.
                    *> Pipeline.statement names SQL.lockStreamsForMultiStmt
                    *> traverse appendPrepared preparedOps
        Session.statement () $
            if any isNothing results
                then multiAppendRollbackStmt
                else multiAppendCommitStmt
        pure results

    appendPrepared (StreamName name, expected, prepared) =
        appendDispatchPipeline expected (buildAppendParams name now prepared)

appendDispatchPipeline :: ExpectedVersion -> SQL.AppendParams -> Pipeline.Pipeline (Maybe AppendResult)
appendDispatchPipeline expected params = case expected of
    ExactVersion (StreamVersion v) ->
        Pipeline.statement (params, v) SQL.appendExpectedVersion
    StreamExists ->
        Pipeline.statement params SQL.appendStreamExists
    NoStream ->
        Pipeline.statement params SQL.appendNoStream
    AnyVersion ->
        Pipeline.statement params SQL.appendAnyVersion

{- | Dispatch the four 'SQL.append*' statements through 'Tx.statement',
selecting the right one based on the supplied 'ExpectedVersion'.

This is the shared building block used by 'AppendMultiStream'\'s
interpreter branch and by 'Kiroku.Store.Transaction.appendToStreamTx'.
'AppendToStream' keeps its 'Session.statement'-flavored dispatch — see
the M2 entry in the Decision Log on plan 11 for why a 'Tx.Transaction'
wrapping a single statement was rejected as a refactoring target.

@'Nothing'@ comes back when the underlying CTE returns 0 rows — i.e.
the precondition failed silently. Callers map that to either
'Kiroku.Store.Error.AppendConflict' (the Tx surface) or
'Kiroku.Store.Error.StoreError' (the @Eff@ surface).
-}
appendDispatchTx :: ExpectedVersion -> SQL.AppendParams -> Tx.Transaction (Maybe AppendResult)
appendDispatchTx expected params = case expected of
    ExactVersion (StreamVersion v) ->
        Tx.statement (params, v) SQL.appendExpectedVersion
    StreamExists ->
        Tx.statement params SQL.appendStreamExists
    NoStream ->
        Tx.statement params SQL.appendNoStream
    AnyVersion ->
        Tx.statement params SQL.appendAnyVersion

{- $internal
These bindings are intentionally exposed so that
"Kiroku.Store.Transaction" can compose appends with arbitrary
'Tx.Transaction' work without re-implementing UUID prep, parameter
packing, or per-version dispatch. They are not part of the supported
public surface and may change without notice.
-}
