{- | Immutable, JSON-encodable snapshot of a running Kiroku store's operational
metrics.

A 'MetricsSnapshot' is produced by
'Kiroku.Metrics.Collector.snapshotMetrics' and is the single source of truth
every endpoint renders. It carries three parts:

* 'StoreGauges' — point-in-time gauges read from the live store handle at
  snapshot time: the gap-free global position (which doubles as the total
  number of events appended store-wide and the high-water mark), the active
  subscriber count, and pool connection gauges/counters.
* 'LifecycleCounters' — monotonic counters accumulated from the store's
  'Kiroku.Store.Observability.KirokuEvent' callback stream.
* a per-subscription map ('SubscriptionMetrics') keyed by subscription name,
  carrying each subscription's last-known position, derived lag, database-error
  count, and last stop reason.

The 'ToJSON' instances are written by hand (not derived) so the wire shape is
stable and documented for downstream consumers (EP-2's JSON/Prometheus
renderers and EP-4's user guide).
-}
module Kiroku.Metrics.Types (
    MetricsSnapshot (..),
    StoreGauges (..),
    LifecycleCounters (..),
    SubscriptionMetrics (..),
) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | A coherent point-in-time view of the store's metrics.
data MetricsSnapshot = MetricsSnapshot
    { store :: !StoreGauges
    , counters :: !LifecycleCounters
    , subscriptions :: !(Map Text SubscriptionMetrics)
    -- ^ Keyed by 'Kiroku.Store.Subscription.Types.SubscriptionName' text.
    }
    deriving stock (Eq, Show)

-- | Gauges read from the live store handle at snapshot time.
data StoreGauges = StoreGauges
    { globalPosition :: !Int64
    -- ^ Total events appended store-wide (gap-free) == high-water mark.
    , activeSubscribers :: !Int
    , poolConnecting :: !Int
    , poolReady :: !Int
    , poolInUse :: !Int
    , poolEstablishedTotal :: !Int64
    , poolTerminatedTotal :: !Int64
    }
    deriving stock (Eq, Show)

{- | Monotonic counters accumulated from the 'KirokuEvent' callback stream.

The constructor set the store emits is richer than counters here name one-to-one:
subscription lifecycle events ('Started', 'CaughtUp', 'Paused', 'Resumed',
'Reconnecting', 'Retrying', 'DeadLettered', 'Stopped' by reason), per-batch
delivery, live fetches, per-phase database errors, notifier reconnects,
publisher pool errors, and hard deletes.
-}
data LifecycleCounters = LifecycleCounters
    { notifierReconnecting :: !Int64
    , notifierReconnected :: !Int64
    , publisherPoolErrors :: !Int64
    , subscriptionDbErrorsLoad :: !Int64
    , subscriptionDbErrorsFetch :: !Int64
    , subscriptionDbErrorsSave :: !Int64
    , subscriptionsStarted :: !Int64
    , subscriptionsCaughtUp :: !Int64
    , subscriptionsPaused :: !Int64
    , subscriptionsResumed :: !Int64
    , subscriptionsReconnecting :: !Int64
    , subscriptionsRetrying :: !Int64
    , subscriptionsDeadLettered :: !Int64
    , subscriptionsStoppedHandler :: !Int64
    , subscriptionsStoppedCancelled :: !Int64
    , subscriptionsStoppedOverflow :: !Int64
    , subscriptionsStoppedCrashed :: !Int64
    , liveFetches :: !Int64
    -- ^ Count of live-mode DB fetches ('KirokuEventSubscriptionFetched').
    , batchesDelivered :: !Int64
    -- ^ Count of non-empty batches delivered ('KirokuEventSubscriptionDelivered').
    , eventsDelivered :: !Int64
    -- ^ Sum of batch row counts across all deliveries.
    , hardDeletesIssued :: !Int64
    }
    deriving stock (Eq, Show)

-- | Per-subscription accumulated metrics.
data SubscriptionMetrics = SubscriptionMetrics
    { lastKnownPosition :: !Int64
    -- ^ Most recent position seen at a lifecycle event (lower bound on true position).
    , lag :: !Int64
    -- ^ @max 0 (globalPosition - lastKnownPosition)@ (upper bound on true lag).
    , dbErrorCount :: !Int64
    , lastStopReason :: !(Maybe Text)
    -- ^ @"handler" | "cancelled" | "overflow" | "crashed"@.
    }
    deriving stock (Eq, Show)

instance ToJSON MetricsSnapshot where
    toJSON s =
        object
            [ "store" .= s.store
            , "counters" .= s.counters
            , "subscriptions" .= s.subscriptions
            ]

instance ToJSON StoreGauges where
    toJSON g =
        object
            [ "global_position" .= g.globalPosition
            , "active_subscribers" .= g.activeSubscribers
            , "pool_connecting" .= g.poolConnecting
            , "pool_ready" .= g.poolReady
            , "pool_in_use" .= g.poolInUse
            , "pool_established_total" .= g.poolEstablishedTotal
            , "pool_terminated_total" .= g.poolTerminatedTotal
            ]

instance ToJSON LifecycleCounters where
    toJSON c =
        object
            [ "notifier_reconnecting" .= c.notifierReconnecting
            , "notifier_reconnected" .= c.notifierReconnected
            , "publisher_pool_errors" .= c.publisherPoolErrors
            , "subscription_db_errors_load" .= c.subscriptionDbErrorsLoad
            , "subscription_db_errors_fetch" .= c.subscriptionDbErrorsFetch
            , "subscription_db_errors_save" .= c.subscriptionDbErrorsSave
            , "subscriptions_started" .= c.subscriptionsStarted
            , "subscriptions_caught_up" .= c.subscriptionsCaughtUp
            , "subscriptions_paused" .= c.subscriptionsPaused
            , "subscriptions_resumed" .= c.subscriptionsResumed
            , "subscriptions_reconnecting" .= c.subscriptionsReconnecting
            , "subscriptions_retrying" .= c.subscriptionsRetrying
            , "subscriptions_dead_lettered" .= c.subscriptionsDeadLettered
            , "subscriptions_stopped_handler" .= c.subscriptionsStoppedHandler
            , "subscriptions_stopped_cancelled" .= c.subscriptionsStoppedCancelled
            , "subscriptions_stopped_overflow" .= c.subscriptionsStoppedOverflow
            , "subscriptions_stopped_crashed" .= c.subscriptionsStoppedCrashed
            , "live_fetches" .= c.liveFetches
            , "batches_delivered" .= c.batchesDelivered
            , "events_delivered" .= c.eventsDelivered
            , "hard_deletes_issued" .= c.hardDeletesIssued
            ]

instance ToJSON SubscriptionMetrics where
    toJSON m =
        object
            [ "last_known_position" .= m.lastKnownPosition
            , "lag" .= m.lag
            , "db_error_count" .= m.dbErrorCount
            , "last_stop_reason" .= m.lastStopReason
            ]
