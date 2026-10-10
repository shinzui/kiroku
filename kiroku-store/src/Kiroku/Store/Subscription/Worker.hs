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

'withFetchBatchHookForTest', 'withLoadCheckpointHookForTest', and
'withSaveCheckpointHookForTest' are test-only seams for controlling fetch,
checkpoint-load, and checkpoint-save boundaries.
-}
module Kiroku.Store.Subscription.Worker (
    LiveSource (..),
    runWorker,
    configMember,
    withFetchBatchHookForTest,
    withLoadCheckpointHookForTest,
    withSaveCheckpointHookForTest,
) where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TBQueue, TVar, atomically, check, newTVarIO, orElse, readTBQueue, readTVar, registerDelay, tryReadTBQueue, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Exception (SomeException, bracket, finally, fromException, mask, throwIO, toException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
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
import Kiroku.Store.Settings (DecodedBatch (..), DecodedEvent (..), StoreSettings, decodeEvent, decodeEvents, decodedBatchLastEvent, decodedBatchLength, decodedEventRecorded, filterDecodedBatch)
import Kiroku.Store.Subscription.Checkpoint.SQL qualified as CheckpointSQL
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
    IO
        ( Maybe
            ( Either
                Pool.UsageError
                (Either SubscriptionCheckpointMissing CheckpointInitialization)
            )
        )

type SaveCheckpointHook =
    SubscriptionConfig ->
    GlobalPosition ->
    IO ()

{-# NOINLINE fetchBatchHookRef #-}
fetchBatchHookRef :: IORef (Maybe FetchBatchHook)
fetchBatchHookRef = unsafePerformIO (newIORef Nothing)

{-# NOINLINE loadCheckpointHookRef #-}
loadCheckpointHookRef :: IORef (Maybe LoadCheckpointHook)
loadCheckpointHookRef = unsafePerformIO (newIORef Nothing)

{-# NOINLINE saveCheckpointHookRef #-}
saveCheckpointHookRef :: IORef (Maybe SaveCheckpointHook)
saveCheckpointHookRef = unsafePerformIO (newIORef Nothing)

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

{- | Install a process-local checkpoint-save boundary hook for lifecycle tests.

The hook runs immediately before the database statement. Production code leaves
it unset.
-}
withSaveCheckpointHookForTest :: SaveCheckpointHook -> IO a -> IO a
withSaveCheckpointHookForTest hook action =
    bracket
        ( do
            previous <- readIORef saveCheckpointHookRef
            writeIORef saveCheckpointHookRef (Just hook)
            pure previous
        )
        (writeIORef saveCheckpointHookRef)
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
      LiveFromPublisherQueue !(TBQueue DecodedBatch) !(TVar SubscriberStatus)
    | {- | Category, plain or consumer-group member: wake on the named
      category's NOTIFY generation counter and re-query the database (with the
      partition predicate, for a member).
      -}
      LiveFromCategoryNotify !Text
    | {- | Consumer-group member of AllStreams: wake when the global position
      advances and re-query with the partition predicate.
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

* 'Kiroku.Store.Observability.KirokuEventSubscriptionCheckpointResolved' once
  when startup resumes or initializes a checkpoint, followed by
  'Kiroku.Store.Observability.KirokuEventSubscriptionStarted'. A refused
  missing checkpoint emits
  'Kiroku.Store.Observability.KirokuEventSubscriptionCheckpointMissing'
  instead and fails before delivery.
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
runWorker pool liveSource stateVar pubPosVar catGenVar config mHandler stSettings = liftIO $
    withHandlerStallDiagnostics config (emitOrDrop mHandler) $ \deliveryConfig ->
        runWorkerBody pool liveSource stateVar pubPosVar catGenVar deliveryConfig mHandler stSettings

-- Select the delivery handler once per worker. The disabled arm returns the
-- original config directly, with no per-delivery diagnostic branch or work.
withHandlerStallDiagnostics :: SubscriptionConfig -> (KirokuEvent -> IO ()) -> (SubscriptionConfig -> IO a) -> IO a
withHandlerStallDiagnostics config emit action = case handlerStallWarnAfter config of
    Nothing -> action config
    Just threshold
        | threshold <= 0 -> throwIO (InvalidHandlerStallWarnAfter threshold)
        | otherwise -> do
            pending <- newTVarIO Nothing
            let tracked event = mask $ \restore -> do
                    started <- getMonotonicTimeNSec
                    let delivery = StalledDelivery (globalPosition event) (eventId event) started
                    atomically (writeTVar pending (Just delivery))
                    restore (handler config event) `finally` atomically (writeTVar pending Nothing)
            Async.withAsync (watchHandler pending threshold) $ \watchdog -> do
                Async.link watchdog
                action config{handler = tracked}
  where
    -- Park while idle. Reuse a pending interval across completed/replaced
    -- invocations, rather than abandoning a registerDelay timer per event.
    watchHandler pending threshold = awaitDelivery
      where
        awaitDelivery = do
            _ <- atomically $ readTVar pending >>= maybe STM.retry pure
            waitInterval threshold
        waitInterval delay = do
            timer <- registerDelay (durationMicros delay)
            atomically (readTVar timer >>= check)
            current <- atomically (readTVar pending)
            case current of
                Nothing -> awaitDelivery
                Just delivery@(StalledDelivery pos eid started) -> do
                    now <- getMonotonicTimeNSec
                    let elapsed = fromRational (fromIntegral (now - started) / 1_000_000_000)
                    if elapsed < threshold
                        then waitInterval (threshold - elapsed)
                        else do
                            stillPending <- atomically ((== Just delivery) <$> readTVar pending)
                            when stillPending $
                                emit (KirokuEventSubscriptionHandlerStalled (name config) pos eid elapsed (groupCtxOf config))
                            waitInterval threshold

-- One cell per enabled worker, not one timer/thread per handler invocation.
data StalledDelivery = StalledDelivery !GlobalPosition !EventId !Word64
    deriving stock (Eq)

-- registerDelay accepts an Int. Cap huge intervals safely and round positive
-- sub-microsecond intervals up instead of creating a zero-delay polling loop.
durationMicros :: NominalDiffTime -> Int
durationMicros duration = fromInteger (max 1 (min (toInteger (maxBound :: Int)) (ceiling (duration * 1_000_000))))

runWorkerBody :: Pool -> LiveSource -> TVar SubscriptionState -> TVar GlobalPosition -> TVar (Map Text Word64) -> SubscriptionConfig -> Maybe (KirokuEvent -> IO ()) -> StoreSettings -> IO ()
runWorkerBody pool liveSource stateVar pubPosVar catGenVar config mHandler stSettings = do
    let emit = emitOrDrop mHandler
        subName = name config
        groupCtx = groupCtxOf config
    posRef <- newIORef (GlobalPosition 0)

    let body = do
            -- Optional startup guardrail: when consumerGroupGuard is on, fail fast
            -- if another holder currently holds this (name, member)'s advisory lock.
            case (consumerGroupGuard config, consumerGroup config) of
                (True, Just cg) -> guardMember pool subName (member cg)
                _ -> pure ()
            resolution <- loadCheckpoint pool config emit
            checkpoint <- case resolution of
                Left missing -> do
                    emit (KirokuEventSubscriptionCheckpointMissing missing groupCtx)
                    throwIO missing
                Right initialization -> do
                    emit (KirokuEventSubscriptionCheckpointResolved initialization groupCtx)
                    pure (checkpointInitializationPosition initialization)
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
                                | decodedBatchLength events == 0 -> pure CaughtUp
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
                                let fresh = filterDecodedBatch ((> c) . globalPosition) events
                                pure (if decodedBatchLength fresh == 0 then FetchEmpty else BatchFetched fresh)
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
                        | decodedBatchLength events == 0 -> pure FetchEmpty
                        | otherwise -> pure (BatchFetched events)
            -- Defensive totality: 'Retrying' is a surfaced observability state
            -- that the delivery primitive writes into the state TVar and then
            -- restores, so it is never a driving state reaching this function.
            -- Mirror 'step''s defensive 'Retrying' clause, which returns to
            -- 'Live' at the same cursor.
            Retrying c _ -> nextInput (Live c)
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
                    result <- processEvents pool config stateVar events emit posRef stSettings
                    case result of
                        Nothing -> pure (Just (HandlerStopped (lastPosOf events)))
                        Just _ -> go es
                Halt reason -> case reason of
                    StopHandlerRequested -> pure Nothing
                    StopOverflowed -> throwIO (SubscriptionOverflowed subName)
                    StopCancelled -> throwIO Async.AsyncCancelled
                    StopWorkerCrashed ex -> throwIO ex
                    StopUndecodable failure -> throwIO (SubscriptionUndecodable failure)

        lastPosOf events = globalPosition (decodedBatchLastEvent events)

        -- Map a DB-driven live loop's exit onto the next FSM input: a clean stop
        -- becomes 'HandlerStopped' (at the last processed position); a fetch error
        -- becomes 'ConnectionLost', driving the FSM into 'Reconnecting'.
        liveExitToInput = \case
            LiveHandlerStopped -> HandlerStopped <$> readIORef posRef
            LiveFetchError err -> do
                position <- readIORef posRef
                pure (ConnectionLost position err)

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
groupCtxOf config = maybe NonGroup (\cg -> GroupMember (member cg) (size cg)) (consumerGroup config)

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
    | Just (SubscriptionUndecodable failure) <- fromException e = StopUndecodable failure
    | otherwise = StopWorkerCrashed e

-- The consumer-group member index for this config, or 0 for a non-group
-- subscription. We always route checkpoints through the member-aware
-- statements with member 0 for the non-group case, so there is a single code
-- path: EP-1's schema guarantees pre-existing rows are consumer_group_member = 0,
-- so a non-group worker reads and writes the same (name, 0) row it always did.
configMember :: SubscriptionConfig -> Int32
configMember config = maybe 0 member (consumerGroup config)

configSize :: SubscriptionConfig -> Int32
configSize config = maybe 1 size (consumerGroup config)

-- Resolve the exact checkpoint key through the shared initializer. A database
-- error is emitted and rethrown so startup fails loudly. A semantic
-- 'FailIfMissing' result remains typed so the caller can emit the distinct
-- refusal event before throwing it. Each group member resolves its own key.
loadCheckpoint ::
    Pool ->
    SubscriptionConfig ->
    (KirokuEvent -> IO ()) ->
    IO (Either SubscriptionCheckpointMissing CheckpointInitialization)
loadCheckpoint pool config emit = do
    let subName = name config
        mem = configMember config
    mHook <- readIORef loadCheckpointHookRef
    injected <- maybe (pure Nothing) (\hook -> hook config) mHook
    result <- case injected of
        Just hooked -> pure (fmap (either (Left . SomeSubscriptionStartupFailure) (Right . (,False))) hooked)
        Nothing ->
            Pool.use pool $
                CheckpointSQL.initializeWorkerCheckpointSession
                    subName
                    mem
                    (configSize config)
                    (target config)
                    (targetBindingPolicy config)
                    (missingCheckpointPolicy config)
    case result of
        Left err -> do
            emit (KirokuEventSubscriptionDbError subName LoadCheckpoint err (groupCtxOf config))
            throwIO err
        Right (Left refusal@(SomeSubscriptionStartupFailure concrete)) ->
            case fromException (toException concrete) of
                Just missing -> pure (Left missing)
                Nothing -> do
                    case fromException (toException concrete) of
                        Just mismatch -> emit (KirokuEventSubscriptionGroupSizeMismatch mismatch (groupCtxOf config))
                        Nothing -> pure ()
                    throwIO refusal
        Right (Right (resolution, adopted)) -> do
            when adopted $ emit (KirokuEventSubscriptionTargetBound subName (target config) (groupCtxOf config))
            pure (Right resolution)

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
-- This loop serves every `Category` subscription, plain or consumer-group. A
-- member cannot tell from a NOTIFY payload whether the stream is in its slice
-- (that is `hashtextextended(stream_id) % size = member`, a Postgres hash), but
-- it can gate on the category: the category generation advances on every append
-- to a stream of the category, a superset of the member's own streams, and
-- `fetchBatch` applies the partition predicate in SQL. So a member of an idle
-- category does no live database work while other categories are busy, and a
-- member whose sibling received the append does one empty fetch.
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
                    emit (KirokuEventSubscriptionFetched (name config) (decodedBatchLength events) (groupCtxOf config))
                    if decodedBatchLength events == 0
                        then pure (Right (Just c))
                        else do
                            result <- processEvents pool config stateVar events emit posRef stSettings
                            case result of
                                Nothing -> pure (Right Nothing) -- handler said Stop
                                Just newPos -> drainTo newPos

-- Phase 2: live (DB-driven, consumer-group members of AllStreams). Bypasses the broadcast
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
                        emit (KirokuEventSubscriptionFetched (name config) (decodedBatchLength events) (groupCtxOf config))
                        if decodedBatchLength events == 0
                            then pure (Right (Just c))
                            else do
                                result <- processEvents pool config stateVar events emit posRef stSettings
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
    IO (Either Pool.UsageError DecodedBatch)
fetchBatch pool config cursor@(GlobalPosition pos) emit stSettings = do
    mHook <- readIORef fetchBatchHookRef
    injected <- maybe (pure Nothing) (\hook -> hook config cursor) mHook
    case injected of
        Just result -> handle result
        Nothing ->
            case (consumerGroup config, target config) of
                (Nothing, AllStreams) -> do
                    result <- Pool.use pool (Session.statement (pos, batchSizeValue (batchSize config)) SQL.readAllForwardStmt)
                    handle result
                (Nothing, Category (CategoryName cat)) -> do
                    result <- Pool.use pool (Session.statement (pos, cat, batchSizeValue (batchSize config)) SQL.readCategoryForwardStmt)
                    handle result
                (Just cg, AllStreams) -> do
                    let m = member cg; n = size cg
                    result <- Pool.use pool (Session.statement (pos, m, n, batchSizeValue (batchSize config)) SQL.readAllForwardConsumerGroupStmt)
                    handle result
                (Just cg, Category (CategoryName cat)) -> do
                    let m = member cg; n = size cg
                    result <- Pool.use pool (Session.statement (pos, cat, m, n, batchSizeValue (batchSize config)) SQL.readCategoryForwardConsumerGroupStmt)
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
    DecodedBatch ->
    (KirokuEvent -> IO ()) ->
    IORef GlobalPosition ->
    StoreSettings ->
    IO (Maybe GlobalPosition)
processEvents pool config stateVar batch emit posRef stSettings = do
    driving <- atomically (readTVar stateVar)
    let phase = case driving of
            CatchingUp{} -> DeliveredCatchUp
            _ -> DeliveredLive
    emit (KirokuEventSubscriptionDelivered subName (decodedBatchLength batch) phase groupCtx)
    -- Choose the vector representation once per batch. The unchanged arm walks
    -- RecordedEvent directly, with no per-event Decoded/Undecodable allocation.
    case batch of
        UnchangedBatch events -> walk events id (\event pos -> deliver driving event pos 1)
        TransformedBatch events -> walk events decodedEventRecorded (\event pos -> dispatch driving event pos 1)
  where
    subName = name config
    groupCtx = groupCtxOf config
    maxAttempts = retryMaxAttempts (retryPolicy config)

    walk :: Vector a -> (a -> RecordedEvent) -> (a -> GlobalPosition -> IO Bool) -> IO (Maybe GlobalPosition)
    walk events rawOf consume = go 0
      where
        go i
            | i >= V.length events = do
                let newPos = globalPosition (rawOf (V.last events))
                writeIORef posRef newPos
                saveCheckpoint pool config newPos emit
                pure (Just newPos)
            | otherwise = do
                let item = events V.! i
                    event = rawOf item
                    evtPos = globalPosition event
                keepGoing <-
                    if shouldDeliver (eventTypeFilter config) (selector config) event
                        then consume item evtPos
                        else pure True
                if keepGoing
                    then writeIORef posRef evtPos >> go (i + 1)
                    else pure Nothing

    deliver driving event evtPos attempt = do
        writeIORef posRef evtPos
        result <- handler config event
        resolve driving event evtPos attempt result (deliver driving event evtPos (attempt + 1))

    dispatch driving outcome evtPos attempt = case outcome of
        Decoded event -> deliver driving event evtPos attempt
        Undecodable raw failure -> case undecodableHandler config of
            Nothing
                | attempt >= maxAttempts -> throwIO (SubscriptionUndecodable failure)
                | otherwise -> do
                    pause driving evtPos attempt (RetryDelay 1)
                    retryDecode driving raw evtPos (attempt + 1)
            Just callback -> do
                result <- callback raw failure
                resolve driving raw evtPos attempt result (retryDecode driving raw evtPos (attempt + 1))

    retryDecode driving raw evtPos attempt = do
        outcome <- decodeEvent stSettings raw
        case outcome of
            Decoded event | not (shouldDeliver (eventTypeFilter config) (selector config) event) -> pure True
            _ -> dispatch driving outcome evtPos attempt

    -- Ordinary and explicitly chosen undecodable dispositions share exactly
    -- one checkpoint/dead-letter/retry resolver. The absent callback never
    -- enters its exhausted-Retry dead-letter branch.
    resolve driving event evtPos attempt result retry = case result of
        Continue -> pure True
        Stop -> do
            writeIORef posRef evtPos
            saveCheckpoint pool config evtPos emit
            pure False
        DeadLetter reason -> do
            writeDeadLetter pool config evtPos event reason attempt emit
            pure True
        Retry delay
            | attempt >= maxAttempts -> do
                writeDeadLetter pool config evtPos event (DeadLetterMaxAttempts attempt) attempt emit
                pure True
            | otherwise -> pause driving evtPos attempt delay >> retry

    pause driving evtPos attempt delay = do
        atomically (writeTVar stateVar (Retrying evtPos attempt))
        emit (KirokuEventSubscriptionRetrying subName evtPos attempt groupCtx)
        threadDelay (retryDelayMicros delay)
        atomically (writeTVar stateVar driving)

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
        (kind, category) = CheckpointSQL.targetColumns (Just (target config))
        EventId uuid = eventId event
        params =
            SQL.DeadLetterParams
                { SQL.dlSubscriptionName = name'
                , SQL.dlMember = mem
                , SQL.dlTargetKind = kind
                , SQL.dlTargetCategory = category
                , SQL.dlGroupSize = configSize config
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
saveCheckpoint pool config position@(GlobalPosition pos) emit = do
    let subName@(SubscriptionName name') = name config
        mem = configMember config
    mHook <- readIORef saveCheckpointHookRef
    mapM_ (\hook -> hook config position) mHook
    result <- Pool.use pool (CheckpointSQL.saveBoundCheckpointSession (target config) name' mem pos (configSize config))
    case result of
        Left err -> emit (KirokuEventSubscriptionDbError subName SaveCheckpoint err (groupCtxOf config))
        Right () -> pure ()
