module Kiroku.Store.Subscription.Worker (
    runWorker,
) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, TVar, atomically, check, readTBQueue, readTVar)
import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionStopReason (..),
 )
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (StoreSettings, decodeEvents)
import Kiroku.Store.Subscription.EventPublisher (SubscriberStatus (..))
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))

{- | Run the subscription worker loop. Two phases:

Phase 1 (catch-up): queries database directly until reaching publisherPosition.
Phase 2 (live): for AllStreams, reads from the bounded TBQueue the publisher
delivers to; for Category, re-queries the database whenever the publisher
advances (the broadcast TBQueue is unused for category subscriptions).

Runs until the handler returns 'Stop', the thread is cancelled, or the
publisher signals overflow on the subscriber's status TVar (in which
case 'Kiroku.Store.Subscription.Types.SubscriptionOverflowed' is thrown
and surfaces through 'Async.waitCatch').

If an 'eventHandler' callback is supplied, the worker emits:

* 'Kiroku.Store.Observability.KirokuEventSubscriptionStarted' once at
  startup, after the checkpoint has been read.
* 'Kiroku.Store.Observability.KirokuEventSubscriptionCaughtUp' when
  catch-up completes and the worker switches to live mode.
* 'Kiroku.Store.Observability.KirokuEventSubscriptionDbError' in the
  three database-error swallowing sites: 'loadCheckpoint', 'fetchBatch',
  and 'saveCheckpoint'. The worker still degrades safely; the event is
  the operator's structured signal.
* 'Kiroku.Store.Observability.KirokuEventSubscriptionStopped' when the
  worker exits, with a reason discriminating handler-stop, cancel,
  overflow, and worker-crash.
-}
runWorker ::
    (MonadIO m) =>
    Pool ->
    TBQueue (Vector RecordedEvent) ->
    TVar SubscriberStatus ->
    TVar GlobalPosition ->
    SubscriptionConfig ->
    -- | optional event handler for subscription observability
    Maybe (KirokuEvent -> IO ()) ->
    {- | interpreter-level event hooks; 'Kiroku.Store.Settings.decodeHook'
    runs on the catch-up fetch path, mirroring the publisher's
    application in live mode.
    -}
    StoreSettings ->
    m ()
runWorker pool liveQueue statusVar pubPosVar config mHandler stSettings = liftIO $ do
    let emit evt = for_ mHandler ($ evt)
        subName = name config
    posRef <- newIORef (GlobalPosition 0)

    let body = do
            checkpoint <- loadCheckpoint pool config emit
            writeIORef posRef checkpoint
            emit (KirokuEventSubscriptionStarted subName checkpoint)
            -- Phase 1: catch-up (returns Nothing if handler said Stop)
            result <- catchUp pool config checkpoint pubPosVar emit posRef stSettings
            case result of
                Nothing -> pure () -- Handler said Stop during catch-up; exit
                Just finalPos -> do
                    writeIORef posRef finalPos
                    emit (KirokuEventSubscriptionCaughtUp subName finalPos)
                    -- Phase 2: live. Two strategies depending on target:
                    --   * AllStreams: read pre-broadcast events from `liveQueue`.
                    --     The publisher delivers every appended event.
                    --   * Category:  bypass the broadcast and re-query the database
                    --     with `readCategoryForwardStmt` whenever `lastPublished`
                    --     advances. The broadcast carries unfiltered $all events;
                    --     filtering them in-process would require a stream-id ->
                    --     category map and a cache invalidation story (EP-3 F18
                    --     Decision Log). The DB-driven loop reuses the catch-up
                    --     query and avoids both.
                    case target config of
                        AllStreams -> liveLoop pool liveQueue statusVar config emit posRef finalPos
                        Category{} -> liveLoopCategoryDriven pool config pubPosVar emit posRef finalPos stSettings

    result <- try body
    pos <- readIORef posRef
    case result of
        Right () -> emit (KirokuEventSubscriptionStopped subName pos StopHandlerRequested)
        Left (e :: SomeException) -> do
            emit (KirokuEventSubscriptionStopped subName pos (classifyStopReason e))
            throwIO e

-- Map an exception to the 'SubscriptionStopReason' the operator should see.
classifyStopReason :: SomeException -> SubscriptionStopReason
classifyStopReason e
    | Just (_ :: SubscriptionOverflowed) <- fromException e = StopOverflowed
    | Just (_ :: Async.AsyncCancelled) <- fromException e = StopCancelled
    | otherwise = StopWorkerCrashed e

-- The consumer-group member index for this config, or 0 for a non-group
-- subscription. We always route checkpoints through the member-aware
-- statements with member 0 for the non-group case, so there is a single code
-- path: EP-1's schema guarantees pre-existing rows are consumer_group_member = 0,
-- so a non-group worker reads and writes the same (name, 0) row it always did.
configMember :: SubscriptionConfig -> Int32
configMember config = maybe 0 member (consumerGroup config)

-- Load the checkpoint from the database, defaulting to 0.
-- Surfaces a database error through the event handler before falling
-- back to the safe default; without the event the operator has no signal
-- that a transient pool error caused a silent re-process from position 0.
-- Keyed by (subscription_name, member) so each group member resumes from its
-- own saved position.
loadCheckpoint ::
    Pool ->
    SubscriptionConfig ->
    (KirokuEvent -> IO ()) ->
    IO GlobalPosition
loadCheckpoint pool config emit = do
    let subName@(SubscriptionName name') = name config
        mem = configMember config
    result <- Pool.use pool (Session.statement (name', mem) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError subName LoadCheckpoint err)
            pure (GlobalPosition 0)
        Right Nothing -> pure (GlobalPosition 0)
        Right (Just pos) -> pure (GlobalPosition pos)

-- Phase 1: catch-up. Queries the database directly in batches until we
-- reach the EventPublisher's current position. Returns Nothing if the
-- handler said Stop, or Just position if catch-up completed normally.
catchUp ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    TVar GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    StoreSettings ->
    IO (Maybe GlobalPosition)
catchUp pool config startPos pubPosVar emit posRef stSettings = go startPos
  where
    go cursor = do
        writeIORef posRef cursor
        pubPos <- atomically (readTVar pubPosVar)
        if cursor >= pubPos
            then pure (Just cursor)
            else do
                events <- fetchBatch pool config cursor emit stSettings
                if V.null events
                    then pure (Just cursor)
                    else do
                        result <- processEvents pool config events emit posRef
                        case result of
                            Nothing -> pure Nothing -- handler said Stop
                            Just newPos -> go newPos

-- Phase 2: live (AllStreams). Reads from the bounded TBQueue the publisher
-- delivers to. Atomically observes the subscriber's status and surfaces
-- 'SubscriptionOverflowed' if the publisher signalled overflow under
-- 'DropSubscription'.
liveLoop ::
    Pool ->
    TBQueue (Vector RecordedEvent) ->
    TVar SubscriberStatus ->
    SubscriptionConfig ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    IO ()
liveLoop pool liveQueue statusVar config emit posRef startPos = go startPos
  where
    go cursor = do
        writeIORef posRef cursor
        next <- atomically $ do
            status <- readTVar statusVar
            case status of
                Overflowed -> pure (Left ())
                Active -> Right <$> readTBQueue liveQueue
        case next of
            Left () -> throwIO (SubscriptionOverflowed (name config))
            Right events
                | V.null freshEvents -> go cursor
                | otherwise -> do
                    result <- processEvents pool config freshEvents emit posRef
                    case result of
                        Nothing -> pure () -- handler said Stop
                        Just newPos -> go newPos
              where
                -- A subscription registers its live queue before catch-up begins.
                -- Events appended during catch-up may therefore be both fetched
                -- from SQL by catch-up and already waiting in the live queue.
                -- Drop those stale queue entries so live mode cannot replay them
                -- or move the checkpoint backward.
                freshEvents = V.filter ((> cursor) . globalPosition) events

-- Phase 2: live (Category). Bypasses the broadcast and re-queries the database
-- whenever `lastPublished` advances. This guarantees correct category filtering
-- (the SQL `readCategoryForwardStmt` filters at source) at the cost of one DB
-- round-trip per publisher tick. See EP-3 F18 Decision Log for the rationale
-- versus extending RecordedEvent or maintaining an in-process category cache.
liveLoopCategoryDriven ::
    Pool ->
    SubscriptionConfig ->
    TVar GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO ()
liveLoopCategoryDriven pool config pubPosVar emit posRef startPos stSettings = go startPos
  where
    go cursor = do
        writeIORef posRef cursor
        -- Wait until the publisher has advanced past our cursor.
        atomically $ do
            pubPos <- readTVar pubPosVar
            check (pubPos > cursor)
        events <- fetchBatch pool config cursor emit stSettings
        if V.null events
            then go cursor
            else do
                result <- processEvents pool config events emit posRef
                case result of
                    Nothing -> pure () -- handler said Stop
                    Just newPos -> go newPos

-- Fetch a batch of events from the database based on subscription target.
-- Surfaces a database error through the event handler before falling back
-- to an empty vector; without the event the catch-up loop sees the empty
-- vector as "no more events" and silently switches to live mode at a stale
-- cursor.
fetchBatch ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    StoreSettings ->
    IO (Vector RecordedEvent)
fetchBatch pool config (GlobalPosition pos) emit stSettings =
    case (consumerGroup config, target config) of
        (Nothing, AllStreams) -> do
            result <- Pool.use pool (Session.statement (pos, batchSize config) SQL.readAllForwardStmt)
            handle result
        (Nothing, Category (CategoryName cat)) -> do
            result <- Pool.use pool (Session.statement (pos, cat, batchSize config) SQL.readCategoryForwardStmt)
            handle result
        (Just (ConsumerGroup m n), AllStreams) -> do
            result <- Pool.use pool (Session.statement (pos, m, n, batchSize config) SQL.readAllForwardConsumerGroupStmt)
            handle result
        (Just (ConsumerGroup m n), Category (CategoryName cat)) -> do
            result <- Pool.use pool (Session.statement (pos, cat, m, n, batchSize config) SQL.readCategoryForwardConsumerGroupStmt)
            handle result
  where
    handle = \case
        Left err -> do
            emit (KirokuEventSubscriptionDbError (name config) FetchBatch err)
            pure V.empty
        -- Apply decodeHook on the catch-up path so catch-up batches are
        -- transformed identically to live batches (which the publisher
        -- transforms once before fan-out).
        Right events -> decodeEvents stSettings events

-- Process a batch of events through the handler. Returns the new cursor
-- position if all events were processed (handler returned Continue for all),
-- or Nothing if the handler returned Stop.
processEvents ::
    Pool ->
    SubscriptionConfig ->
    Vector RecordedEvent ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    IO (Maybe GlobalPosition)
processEvents pool config events emit posRef = go 0
  where
    go i
        | i >= V.length events = do
            let lastEvent = V.last events
                newPos = globalPosition lastEvent
            writeIORef posRef newPos
            saveCheckpoint pool config newPos emit
            pure (Just newPos)
        | otherwise = do
            let event = events V.! i
                evtPos = globalPosition event
            writeIORef posRef evtPos
            result <- handler config event
            case result of
                Stop -> do
                    -- Save checkpoint up to the event we just processed
                    saveCheckpoint pool config evtPos emit
                    pure Nothing
                Continue -> go (i + 1)

-- Save a checkpoint to the database. Surfaces a database error through
-- the event handler; the worker continues running but the next restart
-- with the same name re-processes events the handler has already seen.
-- Keyed by (subscription_name, member) so each group member persists its own
-- position; non-group subscriptions use member 0 (see 'configMember').
saveCheckpoint ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    IO ()
saveCheckpoint pool config (GlobalPosition pos) emit = do
    let subName@(SubscriptionName name') = name config
        mem = configMember config
    result <- Pool.use pool (Session.statement (name', mem, pos) SQL.saveCheckpointMemberStmt)
    case result of
        Left err -> emit (KirokuEventSubscriptionDbError subName SaveCheckpoint err)
        Right () -> pure ()
