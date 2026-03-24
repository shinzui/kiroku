module Kiroku.Store.Subscription.Worker (
    runWorker,
) where

import Control.Concurrent.STM (TChan, TVar, atomically, readTChan, readTVar)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))

{- | Run the subscription worker loop. Two phases:

Phase 1 (catch-up): queries database directly until reaching publisherPosition.
Phase 2 (live): reads from TChan, no database queries.

Runs until the handler returns 'Stop' or the thread is cancelled.
-}
runWorker ::
    Pool ->
    Text ->
    TChan (Vector RecordedEvent) ->
    TVar GlobalPosition ->
    SubscriptionConfig ->
    IO ()
runWorker pool schema liveChan pubPosVar config = do
    -- Read checkpoint from database
    checkpoint <- loadCheckpoint pool (name config)
    -- Phase 1: catch-up (returns Nothing if handler said Stop)
    result <- catchUp pool schema config checkpoint pubPosVar
    case result of
        Nothing -> pure () -- Handler said Stop during catch-up; exit
        Just finalPos -> liveLoop pool liveChan config finalPos

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
    Text ->
    SubscriptionConfig ->
    GlobalPosition ->
    TVar GlobalPosition ->
    IO (Maybe GlobalPosition)
catchUp pool schema config startPos pubPosVar = go startPos
  where
    go cursor = do
        pubPos <- atomically (readTVar pubPosVar)
        if cursor >= pubPos
            then pure (Just cursor)
            else do
                events <- fetchBatch pool schema config cursor
                if V.null events
                    then pure (Just cursor)
                    else do
                        result <- processEvents pool config events
                        case result of
                            Nothing -> pure Nothing -- handler said Stop
                            Just newPos -> go newPos

-- Phase 2: live. Reads from the TChan pushed by the EventPublisher.
liveLoop ::
    Pool ->
    TChan (Vector RecordedEvent) ->
    SubscriptionConfig ->
    GlobalPosition ->
    IO ()
liveLoop pool liveChan config startPos = go startPos
  where
    go _cursor = do
        events <- atomically (readTChan liveChan)
        let filtered = filterEvents config events
        if V.null filtered
            then go _cursor
            else do
                result <- processEvents pool config filtered
                case result of
                    Nothing -> pure () -- handler said Stop
                    Just newPos -> go newPos

-- Fetch a batch of events from the database based on subscription target.
fetchBatch ::
    Pool ->
    Text ->
    SubscriptionConfig ->
    GlobalPosition ->
    IO (Vector RecordedEvent)
fetchBatch pool schema config (GlobalPosition pos) =
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

-- Filter events for category subscriptions during live mode.
-- For AllStreams, all events pass through. For Category, only events
-- from matching streams are retained.
filterEvents :: SubscriptionConfig -> Vector RecordedEvent -> Vector RecordedEvent
filterEvents config events =
    case target config of
        AllStreams -> events
        Category (CategoryName _cat) ->
            -- During live mode, the EventPublisher broadcasts all events from $all.
            -- For category subscriptions, we filter in-process. The category is
            -- determined by the originalStreamId — but we don't have the stream name
            -- in RecordedEvent, only the stream ID. During catch-up we use the SQL
            -- filter. During live, we pass all events through since the EventPublisher
            -- reads from $all. Category filtering in live mode requires joining with
            -- streams table or having stream name in RecordedEvent.
            --
            -- For Phase 2a, category subscriptions always use catch-up mode (the worker
            -- re-queries from the database rather than filtering the broadcast). This
            -- is a simplification; Phase 2b can add in-process category filtering.
            events

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
