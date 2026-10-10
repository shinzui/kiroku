{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Kiroku.Cli ()
import Kiroku.Metrics ()
import Kiroku.Otel.Subscription ()
import Kiroku.Store.Migrations ()
import Kiroku.Store.Observability (KirokuEvent (KirokuEventSubscriptionHandlerStalled))
import Kiroku.Store.Settings (StoreSettings (..), defaultStoreSettings)
import Kiroku.Store.Subscription.Checkpoint (rebindSubscriptionTargetTx, resizeConsumerGroupTx)
import Kiroku.Store.Subscription.Stream (mkStreamBufferSize)
import Kiroku.Store.Subscription.Types (SomeSubscriptionStartupFailure (..), defaultRetryPolicy, mkBatchSize, mkConsumerGroupSize)
import Shibuya.Adapter.Kiroku (KirokuAdapterConfig (..), SubscriptionName (..), SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuProcessor)

typedHook :: StoreSettings
typedHook = defaultStoreSettings{decodeHook = Just (pure . Right)}

adapter :: KirokuAdapterConfig
adapter =
    (defaultKirokuAdapterConfig (SubscriptionName "release-verification") AllStreams)
        { retryPolicy = defaultRetryPolicy
        , handlerStallWarnAfter = Nothing
        }

main :: IO ()
main = putStrLn "Published hardening cohort APIs compiled."
