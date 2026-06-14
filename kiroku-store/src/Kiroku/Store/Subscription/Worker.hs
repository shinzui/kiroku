{- | The subscription worker: the impure driver behind a running subscription.

'runWorker' is the long-lived loop spawned by
'Kiroku.Store.Subscription.subscribe'. It is the interpreter for the pure state
machine in "Kiroku.Store.Subscription.Fsm": it supplies inputs (a batch was
fetched, the queue overflowed, the pool errored, the handler returned a
disposition) and carries out the resulting effects (deliver a batch, save the
checkpoint, back off, emit a @KirokuEvent@, halt). The worker walks the named
states — @CatchingUp@, @Live@, @Paused@ (recoverable backpressure),
@Reconnecting@ (re-catch-up after a live fetch loses the pool), @Retrying@, and
@Stopped@ — and writes each transition to the @TVar@ exposed through
'Kiroku.Store.Subscription.Types.currentState'.

Per-event delivery (including the worker-side
'Kiroku.Store.Subscription.Types.eventTypeFilter' \/
'Kiroku.Store.Subscription.Types.selector' check applied /before/ the handler,
and the bounded-retry \/ dead-letter disposition mechanics) is concentrated in
the single delivery primitive shared by every live path, so behaviour is
identical for @AllStreams@, @Category@, and consumer-group subscriptions.

'withFetchBatchHookForTest' and 'withLoadCheckpointHookForTest' are test-only
seams for injecting fetch and checkpoint-load failures.
-}
module Kiroku.Store.Subscription.Worker (
    LiveSource (..),
    runWorker,
    configMember,
    withFetchBatchHookForTest,
    withLoadCheckpointHookForTest,
) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, TVar, atomically, check, orElse, readTBQueue, readTVar, registerDelay, tryReadTBQueue, writeTVar)
import Control.Exception (SomeException, bracket, fromException, throwIO, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
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
    SubscriptionDeliveryPhase (..),
    SubscriptionGroupContext (..),
    SubscriptionStopReason (..),
    emitOrDrop,
 )
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Settings (StoreSettings, decodeEvents)
import Kiroku.Store.Subscription.EventPublisher (SubscriberStatus)
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Store.Subscription.Fsm (
    Effect (..),
    Input (..),
    SubscriptionState (..),
    stateCursor,
    step,
 )
import Kiroku.Store.Subscription.Types
import Kiroku.Store.Types (CategoryName (..), EventId (..), GlobalPosition (..), RecordedEvent (..))
import System.IO.Unsafe (unsafePerformIO)

-- Mirror 'Kiroku.Store.Subscription.EventPublisher.safetyPollMicros': an idle
-- category re-checks at most this often, reconciling NOTIFYs lost while the
-- listener connection was reconnecting. An idle category therefore costs at most
-- one empty fetch per safety interval, not per global publisher tick.
categorySafetyPollMicros :: Int
categorySafetyPollMicros = 30_000_000

type FetchBatchHook =
    SubscriptionConfig ->
    GlobalPosition ->
    IO (Maybe (Either Pool.UsageError (Vector RecordedEvent)))

type LoadCheckpointHook =
    SubscriptionConfig ->
    IO (Maybe (Either Pool.UsageError (Maybe Int64)))

{-# NOINLINE fetchBatchHookRef #-}
fetchBatchHookRef :: IORef (Maybe FetchBatchHook)
fetchBatchHookRef = unsafePerformIO (newIORef Nothing)

{-# NOINLINE loadCheckpointHookRef #-}
loadCheckpointHookRef :: IORef (Maybe LoadCheckpointHook)
loadCheckpointHookRef = unsafePerformIO (newIORef Nothing)

{- | Install a process-local fetch hook for tests that need deterministic
subscription-worker fault injection. Production code leaves the hook unset.
-}
withFetchBatchHookForTest :: FetchBatchHook -> IO a -> IO a
withFetchBatchHookForTest hook action =
    bracket
        ( do
            previous <- readIORef fetchBatchHookRef
            writeIORef fetchBatchHookRef (Just hook)
            pure previous
        )
        (writeIORef fetchBatchHookRef)
        (const action)

{- | Install a process-local checkpoint-load hook for tests that need
deterministic subscription-startup fault injection. Production code leaves the
hook unset.
-}
withLoadCheckpointHookForTest :: LoadCheckpointHook -> IO a -> IO a
withLoadCheckpointHookForTest hook action =
    bracket
        ( do
            previous <- readIORef loadCheckpointHookRef
            writeIORef loadCheckpointHookRef (Just hook)
            pure previous
        )
        (writeIORef loadCheckpointHookRef)
        (const action)

fetchRetryDelayMicros :: Int -> Int
fetchRetryDelayMicros attempt =
    min categorySafetyPollMicros (100_000 * (2 ^ min attempt 9 :: Int))

{- | How a worker obtains live-mode batches, fixed at 'subscribe' time from the
config's (consumerGroup, target) shape.

Only 'LiveFromPublisherQueue' owns a registration with the EventPublisher. The
other shapes are DB-driven and the publisher must do no fan-out work for them.
-}
data LiveSource
    = {- | Non-group AllStreams: read the publisher's bounded queue; the status
      TVar carries Paused/Overflowed backpressure signals.
      -}
      LiveFromPublisherQueue !(TBQueue (Vector RecordedEvent)) !(TVar SubscriberStatus)
    | {- | Non-group Category: wake on the named category's NOTIFY generation
      counter and re-query the database.
      -}
      LiveFromCategoryNotify !Text
    | {- | Consumer-group member, for either target: wake when the global
      position advances and re-query with the partition predicate.
      -}
      LiveFromGroupPolling

{- | Run the subscription worker loop. Two phases:

Phase 1 (catch-up): queries database directly until reaching publisherPosition.
Phase 2 (live): for 'LiveFromPublisherQueue', reads from the bounded TBQueue
the publisher delivers to; for 'LiveFromCategoryNotify' and
'LiveFromGroupPolling', re-queries the database, and no publisher queue exists.

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
  subscription database phases: 'loadCheckpoint', 'fetchBatch', and
  'saveCheckpoint'. 'fetchBatch' errors are retried at the same cursor;
  the event is the operator's structured signal.
* 'Kiroku.Store.Observability.KirokuEventSubscriptionStopped' when the
  worker exits, with a reason discriminating handler-stop, cancel,
  overflow, and worker-crash.
-}
runWorker ::
    (MonadIO m) =>
    Pool ->
    LiveSource ->
    {- | the worker's current FSM state, written on every transition so callers
    can read it through 'Kiroku.Store.Subscription.Types.currentState'.
    -}
    TVar SubscriptionState ->
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
runWorker pool liveSource stateVar pubPosVar catGenVar config mHandler stSettings = liftIO $ do
    let emit = emitOrDrop mHandler
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
            -- Drive the explicit FSM from the catch-up state. The pure 'step'
            -- (Kiroku.Store.Subscription.Fsm) decides every lifecycle transition;
            -- this driver supplies the inputs (what just happened) and interprets
            -- the effects (deliver a batch, emit an event, back off, halt). The
            -- three live strategies remain the *mechanism* for obtaining the next
            -- batch within the 'Live' state; the FSM governs the lifecycle.
            loop (CatchingUp checkpoint 0)

        -- One driver iteration: publish the current state for observability
        -- ('currentState'), discover the next 'Input' by performing the state's
        -- natural (possibly blocking) action, then hand it to 'feed'. Recording
        -- the state at loop entry means the value read while the worker blocks in
        -- 'nextInput' (e.g. waiting on the live queue) is the state it is blocked in.
        loop :: SubscriptionState -> IO ()
        loop st = do
            atomically (writeTVar stateVar st)
            nextInput st >>= feed st

        -- Apply 'step' to the (state, input) pair, interpret the resulting
        -- effects, and continue. An effect (delivery, a gate) may itself produce
        -- a follow-up 'Input' (e.g. the handler returned 'Stop'); that is fed back
        -- to 'step' immediately. Otherwise: stop when the new state is terminal,
        -- else loop on the new state.
        feed :: SubscriptionState -> Input -> IO ()
        feed st inp = do
            let (st', effs) = step st inp
            follow <- runEffects st' effs
            case follow of
                Just fInp -> feed st' fInp
                Nothing -> case st' of
                    Stopped _ -> pure ()
                    _ -> loop st'

        -- Produce the next 'Input' for a state by performing its blocking action.
        --   * CatchingUp: if caught up, 'CaughtUp'; else fetch one history batch,
        --     mapping the result to 'BatchFetched' / 'FetchEmpty' (caught up) /
        --     'FetchFailed' (the catch-up retry, escalated by the state's attempt).
        --   * Live (AllStreams, non-group): read the publisher's bounded queue;
        --     'QueueOverflowed' when the publisher signalled overflow, else the
        --     stale-filtered batch ('FetchEmpty' if all stale).
        --   * Live (Category / consumer-group): run the existing live loop to its
        --     natural termination (handler 'Stop'), then report 'HandlerStopped'.
        --     These loops retain their own NOTIFY-generation / global-position
        --     gates and per-fetch retry, exactly as before.
        nextInput :: SubscriptionState -> IO Input
        nextInput = \case
            CatchingUp c _ -> do
                writeIORef posRef c
                pubPos <- atomically (readTVar pubPosVar)
                if c >= pubPos
                    then pure CaughtUp
                    else do
                        fetchResult <- fetchBatch pool config c emit stSettings
                        case fetchResult of
                            Left err -> pure (FetchFailed err)
                            Right events
                                | V.null events -> pure CaughtUp
                                | otherwise -> pure (BatchFetched events)
            Live c -> case liveSource of
                LiveFromPublisherQueue liveQueue statusVar -> do
                    writeIORef posRef c
                    atomically $ do
                        status <- readTVar statusVar
                        case status of
                            Pub.Overflowed -> pure QueueOverflowed
                            Pub.Paused -> pure QueueBackpressured
                            Pub.Active -> do
                                -- A subscription registers its live queue before
                                -- catch-up begins, so events appended during
                                -- catch-up may be both fetched from SQL and waiting
                                -- in the queue. Drop those stale entries so live
                                -- mode cannot replay them or rewind the checkpoint.
                                events <- readTBQueue liveQueue
                                let fresh = V.filter ((> c) . globalPosition) events
                                pure (if V.null fresh then FetchEmpty else BatchFetched fresh)
                LiveFromCategoryNotify cat ->
                    liveExitToInput =<< liveLoopCategoryNotify pool config stateVar catGenVar cat emit posRef c stSettings
                LiveFromGroupPolling ->
                    liveExitToInput =<< liveLoopDbDriven pool config stateVar pubPosVar emit posRef c stSettings
            -- Recoverable backpressure: the publisher set 'Paused' because this
            -- subscriber's bounded queue filled. Drain the stale queue (those
            -- events are re-read from the database by the re-catch-up that
            -- 'QueueDrained' triggers) and clear the flag back to 'Active' so the
            -- publisher resumes pushing and the worker is not left waiting. The
            -- AllStreams live path's @> cursor@ filter drops any superseded queued
            -- entries once the worker is live again.
            Paused{} -> do
                case liveSource of
                    LiveFromPublisherQueue liveQueue statusVar -> do
                        atomically $ do
                            drainQueue liveQueue
                            writeTVar statusVar Pub.Active
                        pure QueueDrained
                    -- Defensive totality: only the queue branch can produce
                    -- QueueBackpressured, so DB-driven sources should never
                    -- enter Paused.
                    LiveFromCategoryNotify{} -> pure QueueDrained
                    LiveFromGroupPolling -> pure QueueDrained
            -- Reconnecting: re-probe the database from the checkpoint. A success
            -- re-enters catch-up (delivering everything after the cursor); a
            -- failure stays in 'Reconnecting' for another backed-off attempt; an
            -- empty result means there is nothing new, so return to live.
            Reconnecting c _ -> do
                writeIORef posRef c
                fetchResult <- fetchBatch pool config c emit stSettings
                case fetchResult of
                    Left err -> pure (FetchFailed err)
                    Right events
                        | V.null events -> pure FetchEmpty
                        | otherwise -> pure (BatchFetched events)
            Stopped{} -> pure Cancelled

        -- Interpret a transition's effects against the *new* state. Returns a
        -- follow-up 'Input' when an effect produces one (only 'DeliverBatch', when
        -- the handler returns 'Stop'); 'Nothing' otherwise. 'Halt' terminates the
        -- driver: a handler-requested stop returns cleanly (the outer handler
        -- emits the Stopped event), overflow/crash rethrow so the outer 'try'
        -- classifies and re-emits — preserving today's exact event sequence.
        runEffects :: SubscriptionState -> [Effect] -> IO (Maybe Input)
        runEffects st' = go
          where
            go [] = pure Nothing
            go (e : es) = case e of
                EmitCaughtUp -> do
                    emit (KirokuEventSubscriptionCaughtUp subName (stateCursor st') groupCtx)
                    go es
                EmitPaused -> do
                    emit (KirokuEventSubscriptionPaused subName (stateCursor st') groupCtx)
                    go es
                EmitResumed -> do
                    emit (KirokuEventSubscriptionResumed subName (stateCursor st') groupCtx)
                    go es
                EmitReconnecting n -> do
                    emit (KirokuEventSubscriptionReconnecting subName n groupCtx)
                    go es
                Backoff n -> threadDelay (fetchRetryDelayMicros n) >> go es
                WaitForDrain -> go es
                Checkpoint p -> saveCheckpoint pool config p emit >> go es
                FetchHistory _ -> go es
                RunLive -> go es
                DeliverBatch events -> do
                    result <- processEvents pool config stateVar events emit posRef
                    case result of
                        Nothing -> pure (Just (HandlerStopped (lastPosOf events)))
                        Just _ -> go es
                Halt reason -> case reason of
                    StopHandlerRequested -> pure Nothing
                    StopOverflowed -> throwIO (SubscriptionOverflowed subName)
                    StopCancelled -> throwIO Async.AsyncCancelled
                    StopWorkerCrashed ex -> throwIO ex

        lastPosOf events = globalPosition (V.last events)

        -- Map a DB-driven live loop's exit onto the next FSM input: a clean stop
        -- becomes 'HandlerStopped' (at the last processed position); a fetch error
        -- becomes 'ConnectionLost', driving the FSM into 'Reconnecting'.
        liveExitToInput = \case
            LiveHandlerStopped -> HandlerStopped <$> readIORef posRef
            LiveFetchError err -> pure (ConnectionLost err)

        -- Read and discard every batch currently in the live queue (non-blocking).
        -- Used when resuming from 'Paused': the discarded events are re-read from
        -- the database by the subsequent re-catch-up, so nothing is lost.
        drainQueue q = do
            m <- tryReadTBQueue q
            case m of
                Nothing -> pure ()
                Just _ -> drainQueue q

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

-- Load the checkpoint from the database, defaulting to 0 only when no checkpoint
-- row exists. A database error is emitted and rethrown so startup fails loudly
-- instead of silently re-processing from position 0.
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
    mHook <- readIORef loadCheckpointHookRef
    injected <- maybe (pure Nothing) (\hook -> hook config) mHook
    result <- case injected of
        Just hooked -> pure hooked
        Nothing -> Pool.use pool (Session.statement (name', mem) SQL.getCheckpointMemberStmt)
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError subName LoadCheckpoint err (groupCtxOf config))
            throwIO err
        Right Nothing -> pure (GlobalPosition 0)
        Right (Just pos) -> pure (GlobalPosition pos)

-- How a DB-driven live loop ('liveLoopCategoryNotify' / 'liveLoopDbDriven')
-- exited. The driver maps these onto FSM inputs: a clean handler stop becomes
-- 'HandlerStopped'; a fetch error becomes 'ConnectionLost', which drives the FSM
-- into 'Reconnecting' (backoff + re-catch-up from the checkpoint) rather than the
-- old in-loop retry. AllStreams live has no entry here because it reads the
-- publisher's queue and never fetches — its reconnect is the publisher's concern.
data LiveExit
    = -- | The handler returned 'Stop'; the loop exited cleanly.
      LiveHandlerStopped
    | -- | A live-mode database fetch failed; the worker should reconnect.
      LiveFetchError !Pool.UsageError

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
    TVar SubscriptionState ->
    TVar (Map Text Word64) ->
    -- | this subscription's category
    Text ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO LiveExit
liveLoopCategoryNotify pool config stateVar catGenVar cat emit posRef startPos stSettings = go startPos
  where
    readGen = Map.findWithDefault 0 cat <$> readTVar catGenVar
    go cursor = do
        writeIORef posRef cursor
        -- Snapshot the generation BEFORE draining so a NOTIFY landing mid-drain
        -- is not lost: it leaves gen > gen0 and the gate below re-opens at once.
        gen0 <- atomically readGen
        drainResult <- drainTo cursor
        case drainResult of
            Left err -> pure (LiveFetchError err) -- reconnect: driver re-catches-up
            Right Nothing -> pure LiveHandlerStopped -- handler said Stop
            Right (Just c) -> do
                -- Block until this category is notified again OR the safety timer
                -- fires (reconciling NOTIFYs lost across a listener reconnect).
                timer <- registerDelay categorySafetyPollMicros
                atomically $
                    (readGen >>= \g -> check (g > gen0))
                        `orElse` (readTVar timer >>= check)
                go c
      where
        -- A fetch error bubbles out (no in-loop retry); the FSM's 'Reconnecting'
        -- state owns the backoff and re-catch-up. On success drain to empty.
        drainTo c = do
            fetchResult <- fetchBatch pool config c emit stSettings
            case fetchResult of
                Left err -> pure (Left err)
                Right events -> do
                    emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
                    if V.null events
                        then pure (Right (Just c))
                        else do
                            result <- processEvents pool config stateVar events emit posRef
                            case result of
                                Nothing -> pure (Right Nothing) -- handler said Stop
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
    TVar SubscriptionState ->
    TVar GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    GlobalPosition ->
    StoreSettings ->
    IO LiveExit
liveLoopDbDriven pool config stateVar pubPosVar emit posRef startPos stSettings =
    go startPos (GlobalPosition 0)
  where
    go cursor waitFrom = do
        writeIORef posRef cursor
        pubPos <- atomically $ do
            p <- readTVar pubPosVar
            check (p > waitFrom)
            pure p
        -- A fetch error bubbles out (no in-loop retry); the FSM's 'Reconnecting'
        -- state owns the backoff and re-catch-up. On success drain to empty.
        let drainTo c = do
                fetchResult <- fetchBatch pool config c emit stSettings
                case fetchResult of
                    Left err -> pure (Left err)
                    Right events -> do
                        emit (KirokuEventSubscriptionFetched (name config) (V.length events) (groupCtxOf config))
                        if V.null events
                            then pure (Right (Just c))
                            else do
                                result <- processEvents pool config stateVar events emit posRef
                                case result of
                                    Nothing -> pure (Right Nothing) -- handler said Stop
                                    Just newPos -> drainTo newPos
        drainResult <- drainTo cursor
        case drainResult of
            Left err -> pure (LiveFetchError err)
            Right Nothing -> pure LiveHandlerStopped
            Right (Just c) -> go c pubPos

-- Fetch a batch of events from the database based on subscription target.
-- Surfaces a database error through the event handler and returns the error to
-- the caller so catch-up and DB-driven live loops can retry the same cursor.
fetchBatch ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    (KirokuEvent -> IO ()) ->
    StoreSettings ->
    IO (Either Pool.UsageError (Vector RecordedEvent))
fetchBatch pool config cursor@(GlobalPosition pos) emit stSettings = do
    mHook <- readIORef fetchBatchHookRef
    injected <- maybe (pure Nothing) (\hook -> hook config cursor) mHook
    case injected of
        Just result -> handle result
        Nothing ->
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
            pure (Left err)
        -- Apply decodeHook on the catch-up path so catch-up batches are
        -- transformed identically to live batches (which the publisher
        -- transforms once before fan-out).
        Right events -> Right <$> decodeEvents stSettings events

-- Process a batch of events through the handler, resolving each event's
-- disposition. Returns the new cursor position if the batch was fully consumed
-- (every event resolved to 'Continue', 'DeadLetter', or an exhausted 'Retry'),
-- or 'Nothing' if the handler returned 'Stop'.
--
-- This is the single delivery primitive shared by the FSM 'DeliverBatch' effect
-- (catch-up for every target; AllStreams live) and the two DB-driven live loops,
-- so the four dispositions behave identically on every path (EP-2 / MasterPlan 6
-- Decision Log). Checkpointing keeps the existing per-batch model: 'Continue'
-- events advance the checkpoint only at the batch tail; 'Stop' checkpoints at the
-- stopping event; 'DeadLetter' (and exhausted 'Retry') atomically record the
-- event and advance the checkpoint past it via
-- 'SQL.insertDeadLetterAndCheckpointStmt'.
--
-- 'Retry' redelivers the same event after its 'RetryDelay', bounded by the
-- config's 'retryMaxAttempts'; while a redelivery is pending the worker's
-- observable state @TVar@ shows 'Retrying' (restored to the driving state — the
-- value the driver wrote before this batch — once the event resolves).
processEvents ::
    Pool ->
    SubscriptionConfig ->
    TVar SubscriptionState ->
    Vector RecordedEvent ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    IO (Maybe GlobalPosition)
processEvents pool config stateVar events emit posRef = do
    -- The state the driver wrote for this batch (CatchingUp / Live); restored
    -- after each retry so the observable state does not stick on 'Retrying'.
    driving <- atomically (readTVar stateVar)
    -- Emit one centralized per-batch delivery event for *every* target and both
    -- phases. This is the single delivery primitive, so this one emit uniformly
    -- covers catch-up for every target, AllStreams live, and the DB-driven live
    -- loops (which still also emit KirokuEventSubscriptionFetched per fetch).
    let phase = case driving of
            CatchingUp{} -> DeliveredCatchUp
            _ -> DeliveredLive
    emit (KirokuEventSubscriptionDelivered subName (V.length events) phase groupCtx)
    go driving 0
  where
    subName = name config
    groupCtx = groupCtxOf config
    maxAttempts = retryMaxAttempts (retryPolicy config)

    go driving i
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
            if shouldDeliver (eventTypeFilter config) (selector config) event
                then deliver driving i event evtPos 1
                else -- Filtered out by the type filter or the selector: skip the
                -- handler entirely (so a non-matching event never reaches the
                -- bridge and is never retried or dead-lettered), but keep walking
                -- the batch so the batch-tail checkpoint advances the cursor past
                -- it. The subscription never stalls on a long run of filtered-out
                -- events.
                    go driving (i + 1)

    -- Deliver one event; @attempt@ is the 1-based delivery attempt (1 = first).
    deliver driving i event evtPos attempt = do
        result <- handler config event
        case result of
            Continue -> go driving (i + 1)
            Stop -> do
                -- Save checkpoint up to the event we just processed
                saveCheckpoint pool config evtPos emit
                pure Nothing
            DeadLetter reason -> do
                writeDeadLetter pool config evtPos event reason attempt emit
                go driving (i + 1)
            Retry delay
                -- Exhausted the retry budget: dead-letter and advance past it.
                | attempt >= maxAttempts -> do
                    writeDeadLetter pool config evtPos event (DeadLetterMaxAttempts attempt) attempt emit
                    go driving (i + 1)
                -- Redeliver the same event after the requested delay.
                | otherwise -> do
                    atomically (writeTVar stateVar (Retrying evtPos attempt))
                    emit (KirokuEventSubscriptionRetrying subName evtPos attempt groupCtx)
                    threadDelay (retryDelayMicros delay)
                    atomically (writeTVar stateVar driving)
                    deliver driving i event evtPos (attempt + 1)

-- Atomically record an event in @kiroku.dead_letters@ and advance the
-- subscription's checkpoint past it (one statement; the checkpoint does not
-- advance if the insert fails). On a database error the worker surfaces a
-- 'KirokuEventSubscriptionDbError' and rethrows, so the event is neither lost
-- nor silently skipped — it replays from the unadvanced checkpoint on restart.
writeDeadLetter ::
    Pool ->
    SubscriptionConfig ->
    GlobalPosition ->
    RecordedEvent ->
    DeadLetterReason ->
    -- | attempt count to record
    Int ->
    (KirokuEvent -> IO ()) ->
    IO ()
writeDeadLetter pool config gp@(GlobalPosition pos) event reason attempt emit = do
    let subName@(SubscriptionName name') = name config
        mem = configMember config
        EventId uuid = eventId event
        params =
            SQL.DeadLetterParams
                { SQL.dlSubscriptionName = name'
                , SQL.dlMember = mem
                , SQL.dlGlobalPosition = pos
                , SQL.dlEventId = uuid
                , SQL.dlReason = deadLetterReasonJson reason
                , SQL.dlReasonSummary = deadLetterSummary reason
                , SQL.dlAttemptCount = fromIntegral attempt
                }
    result <- Pool.use pool (Session.statement params SQL.insertDeadLetterAndCheckpointStmt)
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError subName SaveCheckpoint err (groupCtxOf config))
            throwIO err
        Right () -> emit (KirokuEventSubscriptionDeadLettered subName gp reason (groupCtxOf config))

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
