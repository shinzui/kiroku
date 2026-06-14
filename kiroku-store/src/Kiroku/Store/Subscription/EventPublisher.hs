{- | The centralized @$all@ broadcaster shared by queue-consuming live clients.

A single 'EventPublisher' reads new events from the global stream once when at
least one 'Subscriber' is registered and fans them out through each
subscriber's bounded 'Control.Concurrent.STM.TBQueue'. When the registry is
empty, it does not fetch full event rows; it advances 'lastPublished' from the
@$all@ tail with a single-row query so DB-driven subscriptions can still use the
position as their live gate. 'startPublisher' launches the loop,
'subscribePublisher' registers a subscriber (returning its queue, a status
'TVar', and an unsubscribe action), 'publisherPosition' reports the last
published cursor, and 'stopPublisher' tears the loop down.

When a subscriber's queue fills, the publisher applies that subscriber's
'Kiroku.Store.Subscription.Types.OverflowPolicy' by setting its
'SubscriberStatus': under the default @PauseAndResume@ it marks the subscriber
'Paused' and stops pushing (the worker drains and re-catches-up losslessly),
under @DropSubscription@ it marks it 'Overflowed', and under @DropOldest@ it
evicts the oldest batch. The publisher itself never blocks on a slow consumer.
-}
module Kiroku.Store.Subscription.EventPublisher (
    EventPublisher (..),
    Subscriber (..),
    SubscriberStatus (..),
    startPublisher,
    stopPublisher,
    subscribePublisher,
    publisherPosition,
) where

import Control.Concurrent.Async (Async)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (
    STM,
    TBQueue,
    TChan,
    TVar,
    atomically,
    dupTChan,
    isFullTBQueue,
    modifyTVar',
    newTBQueue,
    newTVar,
    newTVarIO,
    readTChan,
    readTVar,
    readTVarIO,
    registerDelay,
    tryReadTBQueue,
    tryReadTChan,
    writeTBQueue,
    writeTVar,
 )
import Control.Concurrent.STM qualified as STM
import Control.Exception (SomeAsyncException, SomeException, asyncExceptionFromException, catch, throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.Int (Int32, Int64)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Vector (Vector)
import Data.Vector qualified as V
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store.Observability (KirokuEvent (..), emitOrDrop)
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (StoreSettings, decodeEvents)
import Kiroku.Store.Subscription.Types (OverflowPolicy (..))
import Kiroku.Store.Types (GlobalPosition (..), RecordedEvent (..))
import Numeric.Natural (Natural)

{- | The centralized EventPublisher. With registered subscribers, reads events
from the database once per notification and fans them out to a registry of
bounded per-subscriber queues. With an empty registry, fetches only the current
@$all@ tail to keep 'lastPublished' moving without decoding event rows.
-}
data EventPublisher = EventPublisher
    { subscribers :: !(TVar (IntMap Subscriber))
    -- ^ Active subscriber registry, keyed by an internal id.
    , nextSubscriberId :: !(TVar Int)
    , publisherThread :: !(Async ())
    , lastPublished :: !(TVar GlobalPosition)
    -- ^ Last-published position; workers read this to know when catch-up is done
    }

{- | A registered subscriber. The publisher owns one of these per
'Kiroku.Store.Subscription.subscribe' call. The worker reads from
'subQueue' under normal operation; on overflow under 'DropSubscription'
the publisher flips 'subStatus' to 'Overflowed' and the worker
terminates the subscription with 'SubscriptionOverflowed'.
-}
data Subscriber = Subscriber
    { subQueue :: !(TBQueue (Vector RecordedEvent))
    , subStatus :: !(TVar SubscriberStatus)
    , subPolicy :: !OverflowPolicy
    }

-- | Subscriber lifecycle status as observed by its worker.
data SubscriberStatus
    = -- | Healthy; worker reads from the queue normally.
      Active
    | {- | Recoverable backpressure under 'PauseAndResume': the queue was full
      so the publisher stopped pushing and set this flag. The worker observes
      it, drains the stale queue, clears the flag back to 'Active', and
      re-catches-up from its checkpoint to recover any skipped events.
      -}
      Paused
    | {- | Publisher signalled overflow under 'DropSubscription'; worker should
      surface a structured error.
      -}
      Overflowed
    deriving stock (Eq, Show)

{- | Publisher batch size — larger than subscriber batch size because the
Publisher serves all subscribers.
-}
publisherBatchSize :: Int32
publisherBatchSize = 1000

-- | Safety poll interval in microseconds (30 seconds).
safetyPollMicros :: Int
safetyPollMicros = 30_000_000

{- | Start the EventPublisher. Spawns a thread that waits for ticks from the
Notifier (or a 30-second safety poll timeout). With at least one registered
subscriber, the thread queries full event rows and delivers them to every active
subscriber; with an empty registry, it advances 'lastPublished' from the @$all@
tail using a single-row query and fetches no payload rows. Per-subscriber
overflow handling is determined by each subscription's 'OverflowPolicy'.

If an 'eventHandler' callback is supplied, the publisher emits
'Kiroku.Store.Observability.KirokuEventPublisherPoolError' when its read
query returns a 'Pool.UsageError'. The publisher continues to run on the
30-second safety poll regardless of the event firing; the event is the
operator's only structured signal that pool exhaustion or a server
error stalled the broadcast.
-}
startPublisher ::
    (MonadIO m) =>
    Pool ->
    TChan () ->
    -- | optional event handler for publisher-side observability
    Maybe (KirokuEvent -> IO ()) ->
    {- | interpreter-level event hooks; 'Kiroku.Store.Settings.decodeHook'
    runs once per fetched batch before fan-out to subscribers.
    -}
    StoreSettings ->
    m EventPublisher
startPublisher pool notifierChan mHandler stSettings = liftIO $ do
    subsVar <- newTVarIO IntMap.empty
    nextIdVar <- newTVarIO 0
    -- Duplicate the notifier channel before reading the tail so ticks arriving
    -- during startup are redundant rather than lost until the safety poll.
    tickChan <- atomically (dupTChan notifierChan)
    tailResult <- Pool.use pool (Session.statement () SQL.currentGlobalPositionStmt)
    tailPos <- either throwIO pure tailResult
    pos <- newTVarIO (GlobalPosition tailPos)
    thread <- Async.async (publisherLoop pool tickChan subsVar pos mHandler stSettings)
    pure
        EventPublisher
            { subscribers = subsVar
            , nextSubscriberId = nextIdVar
            , publisherThread = thread
            , lastPublished = pos
            }

-- | Stop the EventPublisher thread.
stopPublisher :: (MonadIO m) => EventPublisher -> m ()
stopPublisher pub = liftIO $ do
    Async.cancel (publisherThread pub)
    () <$ Async.waitCatch (publisherThread pub)

{- | Register a new subscriber with the given queue capacity and overflow
policy. Returns the bounded queue, the subscriber's status TVar, and an
@unsubscribe@ action that the caller must invoke when the subscription
ends (worker exits, cancellation). Failing to unsubscribe causes the
publisher to keep delivering to a queue with no reader, which will fill
and trigger the configured policy unnecessarily.
-}
subscribePublisher ::
    EventPublisher ->
    -- | Queue capacity (number of batches)
    Natural ->
    OverflowPolicy ->
    STM (TBQueue (Vector RecordedEvent), TVar SubscriberStatus, IO ())
subscribePublisher pub cap policy = do
    queue <- newTBQueue cap
    status <- newTVar Active
    sid <- readTVar (nextSubscriberId pub)
    writeTVar (nextSubscriberId pub) (sid + 1)
    let sub = Subscriber{subQueue = queue, subStatus = status, subPolicy = policy}
    modifyTVar' (subscribers pub) (IntMap.insert sid sub)
    let unsubscribe =
            atomically $
                modifyTVar' (subscribers pub) (IntMap.delete sid)
    pure (queue, status, unsubscribe)

-- | Read the last-published global position.
publisherPosition :: EventPublisher -> STM GlobalPosition
publisherPosition pub = readTVar (lastPublished pub)

-- Internal: the publisher loop.
publisherLoop ::
    Pool ->
    TChan () ->
    TVar (IntMap Subscriber) ->
    TVar GlobalPosition ->
    Maybe (KirokuEvent -> IO ()) ->
    StoreSettings ->
    IO ()
publisherLoop pool tickChan subsVar posVar mHandler stSettings = loop
  where
    loop = do
        -- Wait for a tick OR safety poll timeout
        waitForWakeup tickChan
        -- Drain all pending ticks (debouncing)
        drainTicks tickChan
        -- Fetch and broadcast. If a synchronous callback failure occurs after
        -- partial delivery, lastPublished is not advanced, so the next tick
        -- re-fetches under Kiroku's at-least-once delivery contract.
        fetchAndBroadcast `catch` \(e :: SomeException) ->
            case asyncExceptionFromException e of
                Just (ae :: SomeAsyncException) -> throwIO ae
                Nothing -> emitOrDrop mHandler (KirokuEventPublisherLoopError e)
        loop

    fetchAndBroadcast = do
        subs <- readTVarIO subsVar
        if IntMap.null subs
            then cheapAdvance
            else fullFetch

    cheapAdvance = do
        result <- Pool.use pool (Session.statement () SQL.currentGlobalPositionStmt)
        case result of
            Left err -> do
                -- Surface the pool error so operators see why the publisher
                -- position has stalled; the 30-second safety poll will retry.
                emitOrDrop mHandler (KirokuEventPublisherPoolError err)
            Right tailPos -> do
                -- Re-check registry emptiness in the same STM transaction as
                -- the position write. If a queue subscriber registered after
                -- our snapshot, fall through to a full fetch so no event skips
                -- a queue that now exists.
                raced <- atomically $ do
                    subs' <- readTVar subsVar
                    if IntMap.null subs'
                        then do
                            GlobalPosition cur <- readTVar posVar
                            writeTVar posVar (GlobalPosition (max cur tailPos))
                            pure False
                        else pure True
                when raced fullFetch

    fullFetch = do
        GlobalPosition pos <- readTVarIO posVar
        result <- Pool.use pool (Session.statement (pos, publisherBatchSize) SQL.readAllForwardStmt)
        case result of
            Left err -> do
                -- Surface the pool error so operators see why broadcast
                -- has stalled; the 30-second safety poll will retry.
                emitOrDrop mHandler (KirokuEventPublisherPoolError err)
            Right rawEvents
                | V.null rawEvents -> pure ()
                | otherwise -> do
                    -- Apply the decodeHook once per batch — every subscriber
                    -- observes the same transformed view, and the cost is
                    -- paid in one place instead of per-subscriber.
                    events <- decodeEvents stSettings rawEvents
                    let lastEvent = V.last events
                        newPos = globalPosition lastEvent
                    -- Snapshot the current subscriber set, then deliver outside
                    -- the snapshot's STM transaction. Each delivery is its own
                    -- atomic step so a slow subscriber under DropSubscription
                    -- cannot rollback another's enqueue.
                    subs <- readTVarIO subsVar
                    for_ (IntMap.elems subs) (deliverBatch events)
                    -- Advance posVar only after attempting delivery to the
                    -- snapshot cohort. In the same transaction, re-read the
                    -- registry and offer the in-flight batch to subscribers that
                    -- registered after the snapshot. This closes the attach race:
                    -- every subscriber either received the batch before the
                    -- advance or registered after the advanced position was
                    -- visible and will cover the range through SQL catch-up.
                    atomically $ do
                        subs' <- readTVar subsVar
                        for_ (IntMap.elems (subs' `IntMap.difference` subs)) (deliverBatchSTM events)
                        writeTVar posVar newPos
                    -- If we got a full batch, there may be more — loop immediately
                    if V.length events >= fromIntegral publisherBatchSize
                        then fullFetch
                        else pure ()

    deliverBatch events sub = atomically $ do
        deliverBatchSTM events sub

    deliverBatchSTM events sub = do
        full <- isFullTBQueue (subQueue sub)
        if not full
            then do
                -- There is space again: clear a prior 'PauseAndResume' pause so
                -- the worker (which also clears it on resume) is not left waiting.
                -- Never clear a terminal 'DropSubscription' overflow.
                status <- readTVar (subStatus sub)
                case status of
                    Paused -> writeTVar (subStatus sub) Active
                    Active -> pure ()
                    Overflowed -> pure ()
                writeTBQueue (subQueue sub) events
            else case subPolicy sub of
                -- Recoverable: signal the pause and stop pushing. Do not drop;
                -- the worker re-reads the skipped events from its checkpoint.
                PauseAndResume -> writeTVar (subStatus sub) Paused
                DropSubscription -> writeTVar (subStatus sub) Overflowed
                DropOldest -> do
                    _ <- tryReadTBQueue (subQueue sub)
                    writeTBQueue (subQueue sub) events

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
