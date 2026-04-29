{-# LANGUAGE TypeFamilies #-}

module Kiroku.Store.Effect (
    -- * The Store effect
    Store (..),

    -- * Interpreters
    runStorePool,
    runStoreResource,
    runStoreIO,
) where

import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
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
import Kiroku.Store.Error (StoreError (..), emptyResultError, mapUsageError)
import Kiroku.Store.SQL qualified as SQL
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
        now <- liftIO getCurrentTime
        prepared <- prepareEvents events
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
    ReadStreamForward (StreamName name) (StreamVersion startVer) limit ->
        usePool (store ^. #pool) $
            Session.statement (name, startVer, limit) SQL.readStreamForwardStmt
    ReadStreamBackward (StreamName name) (StreamVersion startVer) limit ->
        usePool (store ^. #pool) $
            Session.statement (name, startVer, limit) SQL.readStreamBackwardStmt
    ReadAllForward (GlobalPosition startPos) limit ->
        usePool (store ^. #pool) $
            Session.statement (startPos, limit) SQL.readAllForwardStmt
    ReadAllBackward (GlobalPosition startPos) limit ->
        usePool (store ^. #pool) $
            Session.statement (startPos, limit) SQL.readAllBackwardStmt
    GetStream (StreamName name) ->
        usePool (store ^. #pool) $
            Session.statement name SQL.getStreamStmt
    LinkToStream (StreamName name) eventIds -> do
        let uuids = V.fromList [uid | EventId uid <- eventIds]
        usePool (store ^. #pool) $
            Session.statement (uuids, name) SQL.linkToStreamStmt
    ReadCategoryForward (CategoryName cat) (GlobalPosition startPos) limit ->
        usePool (store ^. #pool) $
            Session.statement (startPos, cat, limit) SQL.readCategoryForwardStmt
    AppendMultiStream ops -> do
        now <- liftIO getCurrentTime
        -- Prepare all events for all streams
        preparedOps <-
            mapM
                ( \(sn, ev, evts) -> do
                    prepared <- prepareEvents evts
                    pure (sn, ev, prepared)
                )
                ops
        let txn = do
                results <-
                    mapM
                        ( \(StreamName name, expected, prepared) -> do
                            let params = buildAppendParams name now prepared
                            case expected of
                                ExactVersion (StreamVersion v) ->
                                    Tx.statement (params, v) SQL.appendExpectedVersion
                                StreamExists ->
                                    Tx.statement params SQL.appendStreamExists
                                NoStream ->
                                    Tx.statement params SQL.appendNoStream
                                AnyVersion ->
                                    Tx.statement params SQL.appendAnyVersion
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
            Left usageErr -> case ops of
                ((StreamName firstName, firstExpected, _) : _) ->
                    throwError (mapUsageError firstName firstExpected usageErr)
                [] ->
                    throwError (ConnectionError (T.pack (show usageErr)))
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
    SoftDeleteStream (StreamName name) ->
        usePool (store ^. #pool) $
            Session.statement name SQL.softDeleteStreamStmt
    HardDeleteStream (StreamName name) -> do
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
        usePool (store ^. #pool) $
            TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
    UndeleteStream (StreamName name) ->
        usePool (store ^. #pool) $
            Session.statement name SQL.undeleteStreamStmt

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
