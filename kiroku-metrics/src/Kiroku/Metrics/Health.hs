{- | Kubernetes-style health checks derived from the metrics snapshot.

* Liveness — can we read a snapshot within a time budget? (Is the process and
  collector responsive?)
* Readiness — is the store ready to serve: no subscription overflow-stopped, no
  subscription lagging beyond 'Kiroku.Metrics.Config.readinessMaxLag', and all
  configured 'DependencyCheck's passing?
* Detailed health — the readiness verdict plus the full snapshot, for humans.

The built-in 'postgresPing' dependency check issues @SELECT 1@ through the
store's pool. Other dependency checks are arbitrary @IO 'DependencyStatus'@
actions the caller supplies.

The lag signal is an /upper bound/: the collector observes a subscription's
position only at lifecycle callback points (see the collector's limitation), so
readiness may briefly report a caught-up subscription as lagging until its next
lifecycle event.
-}
module Kiroku.Metrics.Health (
    DependencyCheck,
    DependencyStatus (..),
    LivenessStatus (..),
    ReadinessStatus (..),
    checkLiveness,
    checkReadiness,
    checkDetailedHealth,
    postgresPing,
) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import System.Timeout (timeout)

import Kiroku.Metrics.Collector (KirokuMetrics, snapshotMetrics)
import Kiroku.Metrics.Config (MetricsServerConfig (..))
import Kiroku.Metrics.Types (
    MetricsSnapshot (..),
    SubscriptionMetrics (..),
 )
import Kiroku.Store (KirokuStore (..))

-- | A dependency check is an IO action returning that dependency's status.
type DependencyCheck = IO DependencyStatus

-- | Status of one external dependency.
data DependencyStatus = DependencyStatus
    { name :: !Text
    , healthy :: !Bool
    , latencyMs :: !(Maybe Int)
    , errorMsg :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance ToJSON DependencyStatus where
    toJSON ds =
        object
            [ "name" .= ds.name
            , "healthy" .= ds.healthy
            , "latency_ms" .= ds.latencyMs
            , "error" .= ds.errorMsg
            ]

-- | Liveness verdict.
newtype LivenessStatus = LivenessStatus {alive :: Bool}
    deriving stock (Eq, Show)

instance ToJSON LivenessStatus where
    toJSON s = object ["alive" .= s.alive]

-- | Readiness verdict and its components.
data ReadinessStatus = ReadinessStatus
    { ready :: !Bool
    , lagOk :: !Bool
    , noOverflow :: !Bool
    , dependencies :: ![DependencyStatus]
    }
    deriving stock (Eq, Show)

instance ToJSON ReadinessStatus where
    toJSON s =
        object
            [ "ready" .= s.ready
            , "lag_ok" .= s.lagOk
            , "no_overflow" .= s.noOverflow
            , "dependencies" .= s.dependencies
            ]

{- | Liveness: can we take a snapshot within 'livenessTimeoutUs'? Proves the
collector and store @TVar@s are reachable within the budget.
-}
checkLiveness :: MetricsServerConfig -> KirokuMetrics -> IO LivenessStatus
checkLiveness cfg m = do
    result <- timeout cfg.livenessTimeoutUs (snapshotMetrics m)
    pure (LivenessStatus{alive = isJust result})

{- | Readiness: no subscription overflow-stopped, none lagging beyond
'readinessMaxLag', and all dependency checks healthy.
-}
checkReadiness :: MetricsServerConfig -> KirokuMetrics -> [DependencyCheck] -> IO ReadinessStatus
checkReadiness cfg m depChecks = do
    snap <- snapshotMetrics m
    deps <- sequence depChecks
    let subs = Map.elems snap.subscriptions
        noOverflow = not (any ((== Just "overflow") . (.lastStopReason)) subs)
        lagOk = all ((<= cfg.readinessMaxLag) . (.lag)) subs
        depsOk = all (.healthy) deps
    pure
        ReadinessStatus
            { ready = noOverflow && lagOk && depsOk
            , lagOk
            , noOverflow
            , dependencies = deps
            }

-- | Detailed health: the readiness verdict plus the full snapshot.
checkDetailedHealth ::
    MetricsServerConfig ->
    KirokuMetrics ->
    [DependencyCheck] ->
    IO (ReadinessStatus, MetricsSnapshot)
checkDetailedHealth cfg m depChecks = do
    readiness <- checkReadiness cfg m depChecks
    snap <- snapshotMetrics m
    pure (readiness, snap)

{- | Built-in dependency check: time a @SELECT 1@ through the store's pool. A
@Right@ result is healthy; a @Left@ 'Pool.UsageError' is unhealthy with the
error rendered into 'errorMsg'.
-}
postgresPing :: KirokuStore -> DependencyCheck
postgresPing store = do
    t0 <- getMonotonicTimeNSec
    result <- Pool.use store.pool (Session.script "SELECT 1")
    t1 <- getMonotonicTimeNSec
    let ms = fromIntegral ((t1 - t0) `div` 1_000_000)
    pure $ case result of
        Right () -> DependencyStatus "postgres" True (Just ms) Nothing
        Left e -> DependencyStatus "postgres" False (Just ms) (Just (T.pack (show e)))
