{- | In-process metrics collector for a running Kiroku store.

A 'KirokuMetrics' is an opaque handle holding STM counters, a pool
connection-status map, and a per-subscription accumulation map. It is driven
entirely by the store's existing public callback seams — wrap
'metricsEventHandler' and 'metricsObservationHandler' into the
'Kiroku.Store.Connection.ConnectionSettings' @eventHandler@/@observationHandler@
fields /before/ opening the store, and the collector will see every event. Call
'snapshotMetrics' at any time for an immutable, JSON-encodable
'MetricsSnapshot'.

All callback updates are plain non-blocking STM ('modifyTVar''); they perform no
I/O. This matters because the store invokes the callbacks synchronously on the
emit-site thread (notifier loop, publisher loop, subscription worker, store
interpreter), so a slow callback would stall that loop.
-}
module Kiroku.Metrics.Collector (
    KirokuMetrics,
    newKirokuMetrics,
    newKirokuMetricsWith,
    metricsEventHandler,
    metricsObservationHandler,
    snapshotMetrics,
) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.UUID (UUID)
import Kiroku.Metrics.Types (
    LifecycleCounters (..),
    MetricsSnapshot (..),
    StoreGauges (..),
    SubscriptionMetrics (..),
 )
import Kiroku.Store (
    ConnectionReadyForUseReason (..),
    ConnectionStatus (..),
    KirokuEvent (..),
    KirokuStore (..),
    Observation (..),
    SubscriptionDbPhase (..),
    SubscriptionStopReason (..),
 )
import Kiroku.Store.Subscription.EventPublisher (
    EventPublisher (..),
    publisherPosition,
 )
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (GlobalPosition (..))

-- | Opaque collector handle. Construct with 'newKirokuMetrics'.
data KirokuMetrics = KirokuMetrics
    { kmCounters :: !(TVar LifecycleCounters)
    , kmPool :: !(TVar PoolMutable)
    , kmSubs :: !(TVar (Map Text SubMutable))
    , kmPosition :: !(STM GlobalPosition)
    -- ^ Reads the store's global position at snapshot time.
    , kmSubscribers :: !(STM Int)
    -- ^ Reads the store's active-subscriber count at snapshot time.
    }

-- | Mutable pool state: per-connection status plus cumulative lifecycle counts.
data PoolMutable = PoolMutable
    { pmStatuses :: !(Map UUID ConnectionStatus)
    , pmEstablishedTotal :: !Int64
    , pmTerminatedTotal :: !Int64
    }

-- | Mutable per-subscription accumulation.
data SubMutable = SubMutable
    { smLastKnownPosition :: !Int64
    , smDbErrorCount :: !Int64
    , smLastStopReason :: !(Maybe Text)
    }

emptyCounters :: LifecycleCounters
emptyCounters =
    LifecycleCounters
        { notifierReconnecting = 0
        , notifierReconnected = 0
        , publisherPoolErrors = 0
        , publisherLoopErrors = 0
        , subscriptionDbErrorsLoad = 0
        , subscriptionDbErrorsFetch = 0
        , subscriptionDbErrorsSave = 0
        , subscriptionsStarted = 0
        , subscriptionsCaughtUp = 0
        , subscriptionsPaused = 0
        , subscriptionsResumed = 0
        , subscriptionsReconnecting = 0
        , subscriptionsRetrying = 0
        , subscriptionsDeadLettered = 0
        , subscriptionsStoppedHandler = 0
        , subscriptionsStoppedCancelled = 0
        , subscriptionsStoppedOverflow = 0
        , subscriptionsStoppedCrashed = 0
        , liveFetches = 0
        , batchesDelivered = 0
        , eventsDelivered = 0
        , hardDeletesIssued = 0
        }

emptySub :: SubMutable
emptySub = SubMutable{smLastKnownPosition = 0, smDbErrorCount = 0, smLastStopReason = Nothing}

{- | Construct a collector for a live store. The two store-level gauges
(global position and active-subscriber count) are read from the store's
'EventPublisher' at snapshot time.
-}
newKirokuMetrics :: KirokuStore -> IO KirokuMetrics
newKirokuMetrics store =
    newKirokuMetricsWith
        (publisherPosition store.publisher)
        (IntMap.size <$> readTVar (subscribers store.publisher))

{- | Construct a collector from explicit STM readers for the two store-level
gauges. This is the test seam: a unit test passes @pure (GlobalPosition n)@ and
@pure k@ to avoid needing a real store, and an integration test can defer the
store with a @TVar (Maybe KirokuStore)@ (STM readers cannot read an 'IORef').
-}
newKirokuMetricsWith :: STM GlobalPosition -> STM Int -> IO KirokuMetrics
newKirokuMetricsWith readPosition readSubscribers = do
    kmCounters <- newTVarIO emptyCounters
    kmPool <- newTVarIO (PoolMutable Map.empty 0 0)
    kmSubs <- newTVarIO Map.empty
    pure
        KirokuMetrics
            { kmCounters
            , kmPool
            , kmSubs
            , kmPosition = readPosition
            , kmSubscribers = readSubscribers
            }

{- | Wrap the collector into the store's @eventHandler@ seam, composing with an
optional user passthrough. The collector's STM update runs first, then the
passthrough is invoked with the same event.
-}
metricsEventHandler :: KirokuMetrics -> Maybe (KirokuEvent -> IO ()) -> (KirokuEvent -> IO ())
metricsEventHandler km mPassthrough event = do
    atomically (applyEvent km event)
    for_ mPassthrough ($ event)

{- | Wrap the collector into the store's @observationHandler@ seam, composing
with an optional user passthrough. The collector's STM update runs first.
-}
metricsObservationHandler :: KirokuMetrics -> Maybe (Observation -> IO ()) -> (Observation -> IO ())
metricsObservationHandler km mPassthrough obs = do
    atomically (applyObservation km obs)
    for_ mPassthrough ($ obs)

-- | Apply a single 'KirokuEvent' to the collector state.
applyEvent :: KirokuMetrics -> KirokuEvent -> STM ()
applyEvent km = \case
    KirokuEventNotifierReconnecting _ _ ->
        bumpCounters km (\c -> c{notifierReconnecting = c.notifierReconnecting + 1})
    KirokuEventNotifierReconnected ->
        bumpCounters km (\c -> c{notifierReconnected = c.notifierReconnected + 1})
    KirokuEventPublisherPoolError _ ->
        bumpCounters km (\c -> c{publisherPoolErrors = c.publisherPoolErrors + 1})
    KirokuEventPublisherLoopError _ ->
        bumpCounters km (\c -> c{publisherLoopErrors = c.publisherLoopErrors + 1})
    KirokuEventSubscriptionDbError name phase _ _ -> do
        bumpCounters km (bumpDbPhase phase)
        touchSub km name (\s -> s{smDbErrorCount = s.smDbErrorCount + 1})
    KirokuEventSubscriptionStarted name pos _ -> do
        bumpCounters km (\c -> c{subscriptionsStarted = c.subscriptionsStarted + 1})
        recordPosition km name pos
    KirokuEventSubscriptionCaughtUp name pos _ -> do
        bumpCounters km (\c -> c{subscriptionsCaughtUp = c.subscriptionsCaughtUp + 1})
        recordPosition km name pos
    KirokuEventSubscriptionStopped name pos reason _ -> do
        bumpCounters km (bumpStopReason reason)
        recordPosition km name pos
        touchSub km name (\s -> s{smLastStopReason = Just (stopReasonText reason)})
    KirokuEventSubscriptionPaused name pos _ -> do
        bumpCounters km (\c -> c{subscriptionsPaused = c.subscriptionsPaused + 1})
        recordPosition km name pos
    KirokuEventSubscriptionResumed name pos _ -> do
        bumpCounters km (\c -> c{subscriptionsResumed = c.subscriptionsResumed + 1})
        recordPosition km name pos
    KirokuEventSubscriptionReconnecting name _ _ -> do
        bumpCounters km (\c -> c{subscriptionsReconnecting = c.subscriptionsReconnecting + 1})
        touchSub km name id
    KirokuEventSubscriptionFetched name _ _ -> do
        bumpCounters km (\c -> c{liveFetches = c.liveFetches + 1})
        touchSub km name id
    KirokuEventSubscriptionDelivered name n _ _ -> do
        bumpCounters
            km
            ( \c ->
                c
                    { batchesDelivered = c.batchesDelivered + 1
                    , eventsDelivered = c.eventsDelivered + fromIntegral n
                    }
            )
        touchSub km name id
    KirokuEventSubscriptionRetrying name pos _ _ -> do
        bumpCounters km (\c -> c{subscriptionsRetrying = c.subscriptionsRetrying + 1})
        recordPosition km name pos
    KirokuEventSubscriptionDeadLettered name pos _ _ -> do
        bumpCounters km (\c -> c{subscriptionsDeadLettered = c.subscriptionsDeadLettered + 1})
        recordPosition km name pos
    KirokuEventHardDeleteIssued _ _ ->
        bumpCounters km (\c -> c{hardDeletesIssued = c.hardDeletesIssued + 1})

bumpDbPhase :: SubscriptionDbPhase -> LifecycleCounters -> LifecycleCounters
bumpDbPhase phase c = case phase of
    LoadCheckpoint -> c{subscriptionDbErrorsLoad = c.subscriptionDbErrorsLoad + 1}
    FetchBatch -> c{subscriptionDbErrorsFetch = c.subscriptionDbErrorsFetch + 1}
    SaveCheckpoint -> c{subscriptionDbErrorsSave = c.subscriptionDbErrorsSave + 1}

bumpStopReason :: SubscriptionStopReason -> LifecycleCounters -> LifecycleCounters
bumpStopReason reason c = case reason of
    StopHandlerRequested -> c{subscriptionsStoppedHandler = c.subscriptionsStoppedHandler + 1}
    StopCancelled -> c{subscriptionsStoppedCancelled = c.subscriptionsStoppedCancelled + 1}
    StopOverflowed -> c{subscriptionsStoppedOverflow = c.subscriptionsStoppedOverflow + 1}
    StopWorkerCrashed _ -> c{subscriptionsStoppedCrashed = c.subscriptionsStoppedCrashed + 1}

stopReasonText :: SubscriptionStopReason -> Text
stopReasonText = \case
    StopHandlerRequested -> "handler"
    StopCancelled -> "cancelled"
    StopOverflowed -> "overflow"
    StopWorkerCrashed _ -> "crashed"

-- | Apply a single pool 'Observation' to the collector state.
applyObservation :: KirokuMetrics -> Observation -> STM ()
applyObservation km (ConnectionObservation connId status) =
    modifyTVar' (kmPool km) update
  where
    update p = case status of
        TerminatedConnectionStatus _ ->
            p
                { pmStatuses = Map.delete connId p.pmStatuses
                , pmTerminatedTotal = p.pmTerminatedTotal + 1
                }
        ReadyForUseConnectionStatus EstablishedConnectionReadyForUseReason ->
            p
                { pmStatuses = Map.insert connId status p.pmStatuses
                , pmEstablishedTotal = p.pmEstablishedTotal + 1
                }
        _ -> p{pmStatuses = Map.insert connId status p.pmStatuses}

bumpCounters :: KirokuMetrics -> (LifecycleCounters -> LifecycleCounters) -> STM ()
bumpCounters km f = modifyTVar' (kmCounters km) f

-- | Update a subscription's position to the max of its current and the new one.
recordPosition :: KirokuMetrics -> SubscriptionName -> GlobalPosition -> STM ()
recordPosition km name (GlobalPosition pos) =
    touchSub km name (\s -> s{smLastKnownPosition = max s.smLastKnownPosition pos})

-- | Apply @f@ to the named subscription's mutable entry, creating it if absent.
touchSub :: KirokuMetrics -> SubscriptionName -> (SubMutable -> SubMutable) -> STM ()
touchSub km (SubscriptionName name) f =
    modifyTVar' (kmSubs km) (Map.insertWith (\_new old -> f old) name (f emptySub))

{- | Read an atomic, immutable snapshot. Reads the collector's own @TVar@s /and/
the two store readers in a single STM transaction so the result is a coherent
point-in-time view.
-}
snapshotMetrics :: KirokuMetrics -> IO MetricsSnapshot
snapshotMetrics km = atomically $ do
    counters <- readTVar (kmCounters km)
    pool <- readTVar (kmPool km)
    subsMap <- readTVar (kmSubs km)
    GlobalPosition gpos <- kmPosition km
    nSubscribers <- kmSubscribers km
    let gauges =
            StoreGauges
                { globalPosition = gpos
                , activeSubscribers = nSubscribers
                , poolConnecting = countStatuses isConnecting pool
                , poolReady = countStatuses isReady pool
                , poolInUse = countStatuses isInUse pool
                , poolEstablishedTotal = pool.pmEstablishedTotal
                , poolTerminatedTotal = pool.pmTerminatedTotal
                }
    pure
        MetricsSnapshot
            { store = gauges
            , counters
            , subscriptions = Map.map (toSubMetrics gpos) subsMap
            }

countStatuses :: (ConnectionStatus -> Bool) -> PoolMutable -> Int
countStatuses p pool = Map.size (Map.filter p pool.pmStatuses)

isConnecting :: ConnectionStatus -> Bool
isConnecting = \case ConnectingConnectionStatus -> True; _ -> False

isReady :: ConnectionStatus -> Bool
isReady = \case ReadyForUseConnectionStatus _ -> True; _ -> False

isInUse :: ConnectionStatus -> Bool
isInUse = \case InUseConnectionStatus -> True; _ -> False

toSubMetrics :: Int64 -> SubMutable -> SubscriptionMetrics
toSubMetrics gpos s =
    SubscriptionMetrics
        { lastKnownPosition = s.smLastKnownPosition
        , lag = max 0 (gpos - s.smLastKnownPosition)
        , dbErrorCount = s.smDbErrorCount
        , lastStopReason = s.smLastStopReason
        }
