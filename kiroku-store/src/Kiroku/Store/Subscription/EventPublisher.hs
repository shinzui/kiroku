module Kiroku.Store.Subscription.EventPublisher (
    EventPublisher (..),
    startPublisher,
    stopPublisher,
    subscribePublisher,
    publisherPosition,
) where

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (
    STM,
    TChan,
    TVar,
    atomically,
    dupTChan,
    newBroadcastTChanIO,
    newTVarIO,
    readTChan,
    readTVar,
    registerDelay,
    tryReadTChan,
    writeTChan,
    writeTVar,
 )
import Control.Concurrent.STM qualified as STM
import Data.Int (Int32, Int64)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..))

{- | The centralized EventPublisher. Reads events from the database once per
notification and broadcasts them to all subscribers via a broadcast TChan.
This eliminates the thundering herd problem: 30+ subscribers = 1 query.
-}
data EventPublisher = EventPublisher
    { broadcastChan :: !(TChan (Vector RecordedEvent))
    -- ^ Broadcast channel; subscribers get personal copies via dupTChan
    , publisherThread :: !(Async ())
    , lastPublished :: !(TVar GlobalPosition)
    -- ^ Last-published position; workers read this to know when catch-up is done
    }

{- | Publisher batch size — larger than subscriber batch size because the
Publisher serves all subscribers.
-}
publisherBatchSize :: Int32
publisherBatchSize = 1000

-- | Safety poll interval in microseconds (30 seconds).
safetyPollMicros :: Int
safetyPollMicros = 30_000_000

{- | Start the EventPublisher. Spawns a thread that waits for ticks from the
Notifier (or a 30-second safety poll timeout), queries the database for
new events, and broadcasts them to all subscribers.
-}
startPublisher :: Pool -> TChan () -> IO EventPublisher
startPublisher pool notifierChan = do
    bChan <- newBroadcastTChanIO
    pos <- newTVarIO (GlobalPosition 0)
    -- Get a personal copy of the notifier's broadcast channel
    tickChan <- atomically (dupTChan notifierChan)
    thread <- Async.async (publisherLoop pool tickChan bChan pos)
    pure
        EventPublisher
            { broadcastChan = bChan
            , publisherThread = thread
            , lastPublished = pos
            }

-- | Stop the EventPublisher thread.
stopPublisher :: EventPublisher -> IO ()
stopPublisher pub = do
    Async.cancel (publisherThread pub)
    () <$ Async.waitCatch (publisherThread pub)

-- | Get a personal TChan for receiving broadcast events.
subscribePublisher :: EventPublisher -> STM (TChan (Vector RecordedEvent))
subscribePublisher pub = dupTChan (broadcastChan pub)

-- | Read the last-published global position.
publisherPosition :: EventPublisher -> STM GlobalPosition
publisherPosition pub = readTVar (lastPublished pub)

-- Internal: the publisher loop.
publisherLoop :: Pool -> TChan () -> TChan (Vector RecordedEvent) -> TVar GlobalPosition -> IO ()
publisherLoop pool tickChan bChan posVar = loop
  where
    loop = do
        -- Wait for a tick OR safety poll timeout
        waitForWakeup tickChan
        -- Drain all pending ticks (debouncing)
        drainTicks tickChan
        -- Fetch and broadcast
        fetchAndBroadcast
        loop

    fetchAndBroadcast = do
        GlobalPosition pos <- atomically (readTVar posVar)
        result <- Pool.use pool (Session.statement (pos, publisherBatchSize) SQL.readAllForwardStmt)
        case result of
            Left _err ->
                -- Pool error; safety poll will retry later
                pure ()
            Right events
                | V.null events -> pure ()
                | otherwise -> do
                    let lastEvent = V.last events
                        newPos = globalPosition lastEvent
                    atomically $ do
                        writeTChan bChan events
                        writeTVar posVar newPos
                    -- If we got a full batch, there may be more — loop immediately
                    if V.length events >= fromIntegral publisherBatchSize
                        then fetchAndBroadcast
                        else pure ()

-- Wait for either a tick or a 30-second timeout (safety poll).
waitForWakeup :: TChan () -> IO ()
waitForWakeup tickChan = do
    timerVar <- registerDelay safetyPollMicros
    atomically $
        (readTChan tickChan)
            `STM.orElse` (readTVar timerVar >>= STM.check)

-- Drain all pending ticks from the channel (debouncing).
drainTicks :: TChan () -> IO ()
drainTicks tickChan = atomically go
  where
    go = do
        mTick <- tryReadTChan tickChan
        case mTick of
            Nothing -> pure ()
            Just () -> go
