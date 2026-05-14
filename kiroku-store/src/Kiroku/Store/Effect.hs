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
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.List (find)
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
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store.Connection (KirokuStore (..))
import Kiroku.Store.Effect.Resource (KirokuStoreResource, getKirokuStore)
import Kiroku.Store.Error (StoreError (..), attributeMultiStreamError, emptyResultError, mapUsageError)
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
    LinkToStream :: StreamName -> [EventId] -> Store m LinkResult
    ReadCategoryForward :: CategoryName -> GlobalPosition -> Int32 -> Store m (Vector RecordedEvent)
    AppendMultiStream :: [(StreamName, ExpectedVersion, [EventData])] -> Store m [AppendResult]
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
        rejectReservedApplicationStream name
        events' <- liftIO $ enrichEvents (store ^. #storeSettings) events
        now <- liftIO getCurrentTime
        prepared <- prepareEvents events'
        let params = buildAppendParams name now prepared
        result <- liftIO $ Pool.use (store ^. #pool) $ case expected of
            ExactVersion (StreamVersion v) ->
                Session.statement (params, v) SQL.appendExpectedVersion
            StreamExists ->
                Session.statement params SQL.appendStreamExists
            NoStream ->
                Session.statement params SQL.appendNoStream
            AnyVersion ->
                Session.statement params SQL.appendAnyVersion
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
        evs <-
            usePool (store ^. #pool) $
                Session.statement (name, startVer, limit) SQL.readStreamBackwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ReadAllForward (GlobalPosition startPos) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (startPos, limit) SQL.readAllForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    ReadAllBackward (GlobalPosition startPos) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (startPos, limit) SQL.readAllBackwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    GetStream (StreamName name) ->
        usePool (store ^. #pool) $
            Session.statement name SQL.getStreamStmt
    LinkToStream (StreamName name) eventIds -> do
        rejectReservedApplicationStream name
        let uuids = V.fromList [uid | EventId uid <- eventIds]
        result <-
            usePool (store ^. #pool) $
                Session.statement (uuids, name) SQL.linkToStreamStmt
        case result of
            Nothing -> throwError (StreamNotFound (StreamName name))
            Just r -> pure r
    ReadCategoryForward (CategoryName cat) (GlobalPosition startPos) limit -> do
        evs <-
            usePool (store ^. #pool) $
                Session.statement (startPos, cat, limit) SQL.readCategoryForwardStmt
        liftIO $ decodeEvents (store ^. #storeSettings) evs
    AppendMultiStream ops -> do
        case find (\(StreamName name, _, _) -> isReservedApplicationStream name) ops of
            Just (sn, _, _) -> throwError (ReservedStreamName sn)
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
        let txn = do
                -- Pre-lock the user-named streams in deterministic (stream_id)
                -- order to avoid row-lock deadlocks between concurrent
                -- multi-stream txns touching overlapping streams in different
                -- user orders. See EP-1 F4.
                Tx.statement names SQL.lockStreamsForMultiStmt
                results <-
                    mapM
                        ( \(StreamName name, expected, prepared) -> do
                            let params = buildAppendParams name now prepared
                            appendDispatchTx expected params
                        )
                        preparedOps
                -- If any result is Nothing (version conflict), condemn the transaction
                case any isNothing results of
                    True -> Tx.condemn >> pure results
                    False -> pure results
        result <-
            liftIO $
                Pool.use (store ^. #pool) $
                    TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
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
    SoftDeleteStream (StreamName name) -> do
        rejectReservedApplicationStream name
        usePool (store ^. #pool) $
            Session.statement name SQL.softDeleteStreamStmt
    HardDeleteStream (StreamName name) -> do
        rejectReservedApplicationStream name
        let txn = do
                Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
                mSid <- Tx.statement name SQL.findStreamIdStmt
                case mSid of
                    Nothing -> pure Nothing
                    Just sid -> do
                        affected <- Tx.statement sid SQL.deleteStreamJunctionsStmt
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
        rejectReservedApplicationStream name
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
        Left usageErr -> throwError (ConnectionError (T.pack (show usageErr)))
        Right a -> pure a

-- | The seeded $all row is the global read stream, not an application stream.
isReservedApplicationStream :: Text -> Bool
isReservedApplicationStream = (== "$all")

rejectReservedApplicationStream ::
    (Error StoreError :> es) =>
    Text ->
    Eff es ()
rejectReservedApplicationStream name
    | isReservedApplicationStream name = throwError (ReservedStreamName (StreamName name))
    | otherwise = pure ()

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
