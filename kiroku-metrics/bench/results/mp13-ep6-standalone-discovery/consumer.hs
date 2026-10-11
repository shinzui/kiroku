{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Kiroku.Metrics
import Kiroku.Metrics.Config qualified as Config

main :: IO ()
main = do
    let cfg = defaultConfig{Config.port = 0}
        presence = providerPresence defaultServerProviders
    print (capabilitiesFor cfg presence).routes.websocketEvents
