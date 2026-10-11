{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Legacy (legacy) where

import Control.Concurrent.Async (wait)
import Kiroku.Metrics
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Store (KirokuStore)

legacy :: KirokuMetrics -> KirokuStore -> IO ()
legacy metrics store = do
    let cfg = defaultConfig{Config.port = 0}
        ws = defaultServerProviders.webSocketServer
        status = storeSubscriptionStatus store
        finish acquire = acquire >>= stopMetricsServer
    finish (startMetricsServer cfg metrics [])
    finish (startMetricsServerWith cfg metrics [] ws)
    finish (startMetricsServerWith' cfg metrics [] (Just status) ws)
    finish (startMetricsServerWithStore cfg metrics store [])
    withMetricsServer cfg metrics [] (\_ -> pure ())
    withMetricsServerWithStore cfg metrics store [] (\_ -> pure ())
    withMetricsServerSubscriptions cfg metrics [] status (\_ -> pure ())
    -- Also pin the exported server thread handle's existing type.
    finish (startMetricsServer cfg metrics [])
    let supervise :: MetricsServer -> IO ()
        supervise server = wait server.serverThread
    pure supervise >> pure ()
