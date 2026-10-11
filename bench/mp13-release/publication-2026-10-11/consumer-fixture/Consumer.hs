{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

module Main (main, consume) where

import Control.Monad (void)
import Kiroku.Metrics
import Kiroku.Metrics.Config qualified as Config
import Kiroku.Store qualified as Store

main :: IO ()
main = print kirokuMetricsVersion

-- This fixture is compiled before publication and reused from a fresh
-- exact-version project afterward. Compilation alone is not publication proof.
consume :: Store.KirokuStore -> KirokuMetrics -> Store.EventId -> IO ()
consume store metrics eventId = do
    size <- either (fail . show) pure (Store.mkBrowsePageSize 11)
    limits <- either (fail . show) pure (mkBrowseLimits 10 100)
    letterLimit <- either (fail . show) pure (Store.mkSubscriptionDeadLetterLimit 10)
    let query = Store.SubscriptionDeadLetterQuery (Store.SubscriptionName "probe") Nothing Nothing letterLimit
        cfg = defaultConfig{Config.port = 0, Config.cors = corsDisabled}
        settings = Store.defaultStoreSettings{Store.decodeHook = Just (pure . Right)}
    void (pure settings)
    void (Store.runStoreIO store (Store.listStreams Nothing Nothing Nothing size))
    void (Store.runStoreIO store (Store.listCategories Nothing size))
    void (Store.runStoreIO store (Store.getEvent eventId))
    void (Store.runStoreIO store (Store.subscriptionDeadLetters query))
    wiring <- storeServerProviders cfg metrics store
    let providers = ServerProviders wiring.webSocketServer (Just (storeSubscriptionStatus store)) (Just (storeCheckpointInventory store)) (Just (storeBrowserWith limits store)) (Just (storeDeadLetters store)) storeWebSocketChannels
    withMetricsServerWithProviders cfg metrics [] providers (\_ -> pure ())
