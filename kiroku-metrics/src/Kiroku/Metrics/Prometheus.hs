{- | Prometheus text-exposition endpoint (@GET /metrics/prometheus@).

Hand-rolled (no @prometheus-client@ dependency, no global registry): the
snapshot is the single source of truth and is rendered straight to the
text-exposition format that @promtool check metrics@ accepts. Metric names are a
public contract for dashboards — keep them stable once shipped (EP-4 documents
the full list).
-}
module Kiroku.Metrics.Prometheus (
    prometheusApp,
    renderPrometheus,
) where

import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Network.HTTP.Types (hContentType, status200)
import Network.Wai (Application, responseLBS)

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Types (
    LifecycleCounters (..),
    MetricsSnapshot (..),
    StoreGauges (..),
    SubscriptionMetrics (..),
 )

-- | WAI application for the Prometheus endpoint.
prometheusApp :: KirokuMetrics -> Application
prometheusApp m _req respond = do
    snap <- snapshotMetrics m
    respond $
        responseLBS
            status200
            [(hContentType, "text/plain; version=0.0.4; charset=utf-8")]
            (renderPrometheus snap)

-- | Render a snapshot as Prometheus text-exposition format.
renderPrometheus :: MetricsSnapshot -> LBS.ByteString
renderPrometheus snap = B.toLazyByteString (storeSection snap.store <> counterSection snap.counters <> subSection snap.subscriptions)

storeSection :: StoreGauges -> B.Builder
storeSection g =
    mconcat
        [ metric "kiroku_events_appended_total" "counter" "Total events appended store-wide (gap-free global position)." (g.globalPosition)
        , metricI "kiroku_active_subscribers" "gauge" "Currently registered subscribers." g.activeSubscribers
        , help "kiroku_pool_connections" "Pool connections by state."
        , typ "kiroku_pool_connections" "gauge"
        , labelledI "kiroku_pool_connections" "state" "connecting" g.poolConnecting
        , labelledI "kiroku_pool_connections" "state" "ready" g.poolReady
        , labelledI "kiroku_pool_connections" "state" "in_use" g.poolInUse
        , metric "kiroku_pool_established_total" "counter" "Pool connections established." (g.poolEstablishedTotal)
        , metric "kiroku_pool_terminated_total" "counter" "Pool connections terminated." (g.poolTerminatedTotal)
        ]

counterSection :: LifecycleCounters -> B.Builder
counterSection c =
    mconcat
        [ metric "kiroku_notifier_reconnecting_total" "counter" "Notifier reconnection attempts started." c.notifierReconnecting
        , metric "kiroku_notifier_reconnected_total" "counter" "Notifier reconnections completed." c.notifierReconnected
        , metric "kiroku_publisher_pool_errors_total" "counter" "EventPublisher read-query pool errors." c.publisherPoolErrors
        , help "kiroku_subscription_db_errors_by_phase_total" "Subscription database errors by phase."
        , typ "kiroku_subscription_db_errors_by_phase_total" "counter"
        , labelled "kiroku_subscription_db_errors_by_phase_total" "phase" "load" c.subscriptionDbErrorsLoad
        , labelled "kiroku_subscription_db_errors_by_phase_total" "phase" "fetch" c.subscriptionDbErrorsFetch
        , labelled "kiroku_subscription_db_errors_by_phase_total" "phase" "save" c.subscriptionDbErrorsSave
        , metric "kiroku_subscriptions_started_total" "counter" "Subscription workers started." c.subscriptionsStarted
        , metric "kiroku_subscriptions_caught_up_total" "counter" "Subscriptions that reached live mode." c.subscriptionsCaughtUp
        , metric "kiroku_subscriptions_paused_total" "counter" "Subscription pauses (backpressure)." c.subscriptionsPaused
        , metric "kiroku_subscriptions_resumed_total" "counter" "Subscription resumes after pause." c.subscriptionsResumed
        , metric "kiroku_subscriptions_reconnecting_total" "counter" "Subscription live-fetch reconnects." c.subscriptionsReconnecting
        , metric "kiroku_subscriptions_retrying_total" "counter" "Subscription event redeliveries." c.subscriptionsRetrying
        , metric "kiroku_subscriptions_dead_lettered_total" "counter" "Events written to dead letters." c.subscriptionsDeadLettered
        , help "kiroku_subscriptions_stopped_total" "Subscription stops by reason."
        , typ "kiroku_subscriptions_stopped_total" "counter"
        , labelled "kiroku_subscriptions_stopped_total" "reason" "handler" c.subscriptionsStoppedHandler
        , labelled "kiroku_subscriptions_stopped_total" "reason" "cancelled" c.subscriptionsStoppedCancelled
        , labelled "kiroku_subscriptions_stopped_total" "reason" "overflow" c.subscriptionsStoppedOverflow
        , labelled "kiroku_subscriptions_stopped_total" "reason" "crashed" c.subscriptionsStoppedCrashed
        , metric "kiroku_live_fetches_total" "counter" "Live-mode database fetches." c.liveFetches
        , metric "kiroku_batches_delivered_total" "counter" "Non-empty batches delivered to handlers." c.batchesDelivered
        , metric "kiroku_events_delivered_total" "counter" "Events delivered to handlers." c.eventsDelivered
        , metric "kiroku_hard_deletes_total" "counter" "Hard-delete transactions issued." c.hardDeletesIssued
        ]

subSection :: Map Text SubscriptionMetrics -> B.Builder
subSection subs =
    mconcat
        [ help "kiroku_subscription_position" "Last-known global position per subscription."
        , typ "kiroku_subscription_position" "gauge"
        , Map.foldMapWithKey (\n sm -> labelled "kiroku_subscription_position" "subscription" n sm.lastKnownPosition) subs
        , help "kiroku_subscription_lag" "Lag behind the global position per subscription (upper bound)."
        , typ "kiroku_subscription_lag" "gauge"
        , Map.foldMapWithKey (\n sm -> labelled "kiroku_subscription_lag" "subscription" n sm.lag) subs
        , help "kiroku_subscription_db_errors_total" "Database errors per subscription."
        , typ "kiroku_subscription_db_errors_total" "counter"
        , Map.foldMapWithKey (\n sm -> labelled "kiroku_subscription_db_errors_total" "subscription" n sm.dbErrorCount) subs
        ]

-- | A single unlabelled metric: HELP, TYPE, and one sample (Int64-valued).
metric :: Text -> Text -> Text -> Int64 -> B.Builder
metric n t h v = help n h <> typ n t <> name n <> B.char8 ' ' <> B.int64Dec v <> B.char8 '\n'

-- | A single unlabelled metric with an 'Int'-valued sample.
metricI :: Text -> Text -> Text -> Int -> B.Builder
metricI n t h v = metric n t h (fromIntegral v)

help :: Text -> Text -> B.Builder
help n h = "# HELP " <> name n <> B.char8 ' ' <> text h <> B.char8 '\n'

typ :: Text -> Text -> B.Builder
typ n t = "# TYPE " <> name n <> B.char8 ' ' <> text t <> B.char8 '\n'

-- | A labelled sample line (Int64-valued).
labelled :: Text -> Text -> Text -> Int64 -> B.Builder
labelled n labelKey labelVal v =
    name n
        <> B.char8 '{'
        <> text labelKey
        <> "=\""
        <> text (escapeLabel labelVal)
        <> "\"} "
        <> B.int64Dec v
        <> B.char8 '\n'

-- | A labelled sample line (Int-valued).
labelledI :: Text -> Text -> Text -> Int -> B.Builder
labelledI n labelKey labelVal v = labelled n labelKey labelVal (fromIntegral v)

name :: Text -> B.Builder
name = text

text :: Text -> B.Builder
text = B.byteString . T.encodeUtf8

-- | Escape a Prometheus label value: backslash, double-quote, and newline.
escapeLabel :: Text -> Text
escapeLabel = T.concatMap $ \case
    '\\' -> "\\\\"
    '"' -> "\\\""
    '\n' -> "\\n"
    ch -> T.singleton ch
