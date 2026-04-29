module Kiroku.Store.Subscription.Worker (
    runWorker,
) where

import Control.Concurrent.STM (TBQueue, TVar, atomically, check, readTBQueue, readTVar)
import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Int (Int64)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.SQL qualified as SQL
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
-}
runWorker ::
    (MonadIO m) =>
    Pool ->
    TBQueue (Vector RecordedEvent) ->
    TVar SubscriberStatus ->
    TVar GlobalPosition ->
    SubscriptionConfig ->
    m ()
runWorker pool liveQueue statusVar pubPosVar config = liftIO $ do
    -- Read checkpoint from database
    checkpoint <- loadCheckpoint pool (name config)
    -- Phase 1: catch-up (returns Nothing if handler said Stop)
    result <- catchUp pool config checkpoint pubPosVar
    case result of
        Nothing -> pure () -- Handler said Stop during catch-up; exit
        Just finalPos ->
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
                AllStreams -> liveLoop pool liveQueue statusVar config finalPos
                Category{} -> liveLoopCategoryDriven pool config pubPosVar finalPos

-- Load the checkpoint from the database, defaulting to 0.
loadCheckpoint :: Pool -> SubscriptionName -> IO GlobalPosition
loadCheckpoint pool (SubscriptionName subName) = do
    result <- Pool.use pool (Session.statement subName SQL.getCheckpointStmt)
    case result of
        Left _err -> pure (GlobalPosition 0)
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
    IO (Maybe GlobalPosition)
catchUp pool config startPos pubPosVar = go startPos
  where
    go cursor = do
        pubPos <- atomically (readTVar pubPosVar)
        if cursor >= pubPos
            then pure (Just cursor)
            else do
                events <- fetchBatch pool config cursor
                if V.null events
                    then pure (Just cursor)
                    else do
                        result <- processEvents pool config events
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
    GlobalPosition ->
    IO ()
liveLoop pool liveQueue statusVar config startPos = go startPos
  where
    go _cursor = do
        next <- atomically $ do
            status <- readTVar statusVar
            case status of
                Overflowed -> pure (Left ())
                Active -> Right <$> readTBQueue liveQueue
        case next of
            Left () -> throwIO (SubscriptionOverflowed (name config))
            Right events
                | V.null events -> go _cursor
                | otherwise -> do
                    result <- processEvents pool config events
                    case result of
                        Nothing -> pure () -- handler said Stop
                        Just newPos -> go newPos

-- Phase 2: live (Category). Bypasses the broadcast and re-queries the database
-- whenever `lastPublished` advances. This guarantees correct category filtering
-- (the SQL `readCategoryForwardStmt` filters at source) at the cost of one DB
-- round-trip per publisher tick. See EP-3 F18 Decision Log for the rationale
-- versus extending RecordedEvent or maintaining an in-process category cache.
liveLoopCategoryDriven ::
    Pool ->
    SubscriptionConfig ->
    TVar GlobalPosition ->
    GlobalPosition ->
    IO ()
liveLoopCategoryDriven pool config pubPosVar startPos = go startPos
  where
    go cursor = do
        -- Wait until the publisher has advanced past our cursor.
        atomically $ do
            pubPos <- readTVar pubPosVar
            check (pubPos > cursor)
        events <- fetchBatch pool config cursor
        if V.null events
            then go cursor
            else do
                result <- processEvents pool config events
                case result of
                    Nothing -> pure () -- handler said Stop
                    Just newPos -> go newPos

-- Fetch a batch of events from the database based on subscription target.
fetchBatch ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    IO (Vector RecordedEvent)
fetchBatch pool config (GlobalPosition pos) =
    case target config of
        AllStreams -> do
            result <- Pool.use pool (Session.statement (pos, batchSize config) SQL.readAllForwardStmt)
            case result of
                Left _err -> pure V.empty
                Right events -> pure events
        Category (CategoryName cat) -> do
            result <- Pool.use pool (Session.statement (pos, cat, batchSize config) SQL.readCategoryForwardStmt)
            case result of
                Left _err -> pure V.empty
                Right events -> pure events

-- Process a batch of events through the handler. Returns the new cursor
-- position if all events were processed (handler returned Continue for all),
-- or Nothing if the handler returned Stop.
processEvents ::
    Pool ->
    SubscriptionConfig ->
    Vector RecordedEvent ->
    IO (Maybe GlobalPosition)
processEvents pool config events = go 0
  where
    go i
        | i >= V.length events = do
            let lastEvent = V.last events
                newPos = globalPosition lastEvent
            saveCheckpoint pool (name config) newPos
            pure (Just newPos)
        | otherwise = do
            let event = events V.! i
            result <- handler config event
            case result of
                Stop -> do
                    -- Save checkpoint up to the event we just processed
                    saveCheckpoint pool (name config) (globalPosition event)
                    pure Nothing
                Continue -> go (i + 1)

-- Save a checkpoint to the database.
saveCheckpoint :: Pool -> SubscriptionName -> GlobalPosition -> IO ()
saveCheckpoint pool (SubscriptionName subName) (GlobalPosition pos) =
    () <$ Pool.use pool (Session.statement (subName, pos) SQL.saveCheckpointStmt)
