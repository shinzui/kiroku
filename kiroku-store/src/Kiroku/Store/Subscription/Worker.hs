module Kiroku.Store.Subscription.Worker (
    runWorker,
) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, TVar, atomically, check, orElse, readTBQueue, readTVar, registerDelay)
import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Word (Word64)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Observability (
    KirokuEvent (..),
    SubscriptionDbPhase (..),
    SubscriptionGroupContext (..),
    SubscriptionStopReason (..),
 )
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (StoreSettings, decodeEvents)
import Kiroku.Store.Subscription.EventPublisher (SubscriberStatus (..))
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (CategoryName (..), GlobalPosition (..), RecordedEvent (..))

-- Mirror 'Kiroku.Store.Subscription.EventPublisher.safetyPollMicros': an idle
-- category re-checks at most this often, reconciling NOTIFYs lost while the
-- listener connection was reconnecting. An idle category therefore costs at most
-- one empty fetch per safety interval, not per global publisher tick.
categorySafetyPollMicros :: Int
categorySafetyPollMicros = 30_000_000

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
    {- | per-category wake counter from the Notifier; the @Category@ live loop
    blocks on this category's entry rather than busy-polling the global position.
    -}
    TVar (Map Text Word64) ->
    SubscriptionConfig ->
    -- | optional event handler for subscription observability
    Maybe (KirokuEvent -> IO ()) ->
    {- | interpreter-level event hooks; 'Kiroku.Store.Settings.decodeHook'
    runs on the catch-up fetch path, mirroring the publisher's
    application in live mode.
    -}
    StoreSettings ->
    m ()
runWorker pool liveQueue statusVar pubPosVar catGenVar config mHandler stSettings = liftIO $ do
    let emit evt = for_ mHandler ($ evt)
        subName = name config
        groupCtx = groupCtxOf config
    posRef <- newIORef (GlobalPosition 0)

    let body = do
            -- Optional startup guardrail: when consumerGroupGuard is on, fail fast
            -- if another holder currently holds this (name, member)'s advisory lock.
            case (consumerGroupGuard config, consumerGroup config) of
                (True, Just (ConsumerGroup m _)) -> guardMember pool subName m
                _ -> pure ()
            checkpoint <- loadCheckpoint pool config emit
            writeIORef posRef checkpoint
            emit (KirokuEventSubscriptionStarted subName checkpoint groupCtx)
            -- Phase 1: catch-up (returns Nothing if handler said Stop)
            result <- catchUp pool config checkpoint pubPosVar emit posRef stSettings
            case result of
                Nothing -> pure () -- Handler said Stop during catch-up; exit
                Just finalPos -> do
                    writeIORef posRef finalPos
                    emit (KirokuEventSubscriptionCaughtUp subName finalPos groupCtx)
                    -- Phase 2: live. The strategy depends on (group, target):
                    --   * Non-group AllStreams: read pre-broadcast events from
                    --     `liveQueue`; the publisher delivers every appended event.
                    --   * Non-group Category: block on this category's NOTIFY-driven
                    --     generation counter and re-query only when *this* category
                    --     changes, so an idle category does zero DB work while other
                    --     categories receive traffic (see liveLoopCategoryNotify).
                    --   * Any group (Category or AllStreams): the DB-driven loop,
                    --     gated on the last observed global position. A partitioned
                    --     member must see only the events whose originating stream
                    --     hashes to its slot; the broadcast `liveQueue` carries
                    --     unfiltered $all events and there is no in-process
                    --     stream-id -> member map to filter them with (mirrors the
                    --     EP-3 F18 rationale), and the member's partition is a
                    --     Postgres hash the worker cannot derive from the NOTIFY
                    --     payload. The partition predicate lives in the SQL, so
                    --     re-querying with the partitioned statement when the global
                    --     position advances is the correct fit.
                    case (consumerGroup config, target config) of
                        (Nothing, AllStreams) ->
                            liveLoop pool liveQueue statusVar config emit posRef finalPos
                        (Nothing, Category (CategoryName cat)) ->
                            liveLoopCategoryNotify pool config catGenVar cat emit posRef finalPos stSettings
                        (Just _, _) ->
                            liveLoopDbDriven pool config pubPosVar emit posRef finalPos stSettings

    result <- try body
    pos <- readIORef posRef
    case result of
        Right () -> emit (KirokuEventSubscriptionStopped subName pos StopHandlerRequested groupCtx)
        Left (e :: SomeException) -> do
            emit (KirokuEventSubscriptionStopped subName pos (classifyStopReason e) groupCtx)
            throwIO e

-- The consumer-group context for this config's lifecycle events: 'NonGroup' for
-- an ordinary subscription, @GroupMember member size@ for a group member.
groupCtxOf :: SubscriptionConfig -> SubscriptionGroupContext
groupCtxOf config = maybe NonGroup (\(ConsumerGroup m n) -> GroupMember m n) (consumerGroup config)

{- Startup-only conflict probe for the consumer-group guardrail. Uses a
transaction-scoped advisory lock ('pg_try_advisory_xact_lock') which auto-releases
at transaction end, so it only detects a /concurrent/ holder at this instant. The
key is a stable bigint hash of the @name:member@ pair computed in SQL so all
processes agree. NOTE: this does NOT hold the lock for the worker's lifetime; full
mutual exclusion would need a session-level lock on a dedicated connection (the
'Kiroku.Store.Notification.Notifier' pattern), recorded as follow-up in EP-2's
Decision Log. On a database error the probe degrades open (treats it as "no
conflict") so a transient pool error cannot wedge startup. -}
guardMember :: Pool -> SubscriptionName -> Int32 -> IO ()
guardMember pool subName@(SubscriptionName n) mem = do
    let probe :: Statement (Text, Int32) Bool
        probe =
            preparable
                "SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2::text, 0))"
                ( contrazip2
                    (E.param (E.nonNullable E.text))
                    (E.param (E.nonNullable E.int4))
                )
                (D.singleRow (D.column (D.nonNullable D.bool)))
    result <- Pool.use pool (Session.statement (n, mem) probe)
    case result of
        Right True -> pure () -- got the lock; no concurrent holder right now
        Right False -> throwIO (ConsumerGroupGuardConflict subName mem)
        Left _ -> pure () -- DB error: degrade open (do not block startup)

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
            emit (KirokuEventSubscriptionDbError subName LoadCheckpoint err (groupCtxOf config))
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

-- Phase 2: live (Category, NOTIFY-driven). Blocks on this category's generation
-- counter, which the Notifier bumps on every NOTIFY for a stream in the category,
-- so an idle category does ZERO DB work while other categories receive traffic.
-- The generation is snapshotted BEFORE an unconditional drain so a notification
-- that arrives during the drain is never missed (it leaves gen > gen0 and the loop
-- drains again on the next iteration). A safety timeout (matching the publisher's
-- 30s safety poll) reconciles notifications lost while the listener connection is
-- reconnecting, preserving at-least-once delivery with bounded latency.
--
-- This loop serves only non-group `Category` subscriptions. Consumer-group members
-- cannot use the per-category signal: their interest is
-- `hashtextextended(stream_id) % size = member`, a Postgres hash the worker cannot
-- cheaply replicate from the payload, so they stay on `liveLoopDbDriven`.
liveLoopCategoryNotify ::
    Pool ->
    SubscriptionConfig ->
    TVar (Map Text Word64) ->
    -- | this subscription's category
    Text ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO ()
liveLoopCategoryNotify pool config catGenVar cat emit posRef startPos stSettings = go startPos
  where
    readGen = Map.findWithDefault 0 cat <$> readTVar catGenVar
    go cursor = do
        writeIORef posRef cursor
        -- Snapshot the generation BEFORE draining so a NOTIFY landing mid-drain
        -- is not lost: it leaves gen > gen0 and the gate below re-opens at once.
        gen0 <- atomically readGen
        drainResult <- drainTo cursor
        case drainResult of
            Nothing -> pure () -- handler said Stop
            Just c -> do
                -- Block until this category is notified again OR the safety timer
                -- fires (reconciling NOTIFYs lost across a listener reconnect).
                timer <- registerDelay categorySafetyPollMicros
                atomically $
                    (readGen >>= \g -> check (g > gen0))
                        `orElse` (readTVar timer >>= check)
                go c
      where
        drainTo c = do
            events <- fetchBatch pool config c emit stSettings
            emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
            if V.null events
                then pure (Just c)
                else do
                    result <- processEvents pool config events emit posRef
                    case result of
                        Nothing -> pure Nothing -- handler said Stop
                        Just newPos -> drainTo newPos

-- Phase 2: live (DB-driven, consumer-group members only). Bypasses the broadcast
-- and re-queries the database when the publisher's GLOBAL position advances,
-- letting `fetchBatch` apply the partition predicate baked into the consumer-group
-- SQL. A partitioned member cannot read the broadcast `liveQueue` because it
-- carries unfiltered $all events and there is no in-process stream-id -> member map
-- to filter them with. See EP-3 F18 / EP-2 Decision Log for the rationale versus
-- extending RecordedEvent or maintaining an in-process cache.
--
-- The gate waits for the publisher to advance past the LAST OBSERVED global
-- position (not past `cursor`). A member's partition cursor only moves on events in
-- its slice, but `pubPosVar` moves on every append; gating on the cursor busy-loops
-- whenever another partition is ahead (the original defect). Gating on the last
-- observed `pubPos` blocks until genuinely new global work exists. After the gate
-- opens we drain the partition to empty (not stopping at `pubPos`), which
-- guarantees no lost wakeup: the $all position is strictly monotonic, so any later
-- partition event lands at a position strictly greater than the observed `pubPos`
-- and re-opens the gate.
liveLoopDbDriven ::
    Pool ->
    SubscriptionConfig ->
    TVar GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO ()
liveLoopDbDriven pool config pubPosVar emit posRef startPos stSettings =
    go startPos (GlobalPosition 0)
  where
    go cursor waitFrom = do
        writeIORef posRef cursor
        pubPos <- atomically $ do
            p <- readTVar pubPosVar
            check (p > waitFrom)
            pure p
        let drainTo c = do
                events <- fetchBatch pool config c emit stSettings
                emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
                if V.null events
                    then pure (Just c)
                    else do
                        result <- processEvents pool config events emit posRef
                        case result of
                            Nothing -> pure Nothing -- handler said Stop
                            Just newPos -> drainTo newPos
        drainResult <- drainTo cursor
        case drainResult of
            Nothing -> pure ()
            Just c -> go c pubPos

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
            emit (KirokuEventSubscriptionDbError (name config) FetchBatch err (groupCtxOf config))
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
        Left err -> emit (KirokuEventSubscriptionDbError subName SaveCheckpoint err (groupCtxOf config))
        Right () -> pure ()
