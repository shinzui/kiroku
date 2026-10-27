{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Use the owner's actual interval algorithm and frozen policy, not a local approximation.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict', encodeFile, object, (.=))
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kenshou.Measure.Compare (compareMetricPairs)
import Kenshou.Measure.Compare.Policy (MetricRule (..), Policy (..), decodePolicy)
import System.Environment (getArgs)

main :: IO ()
main = do
  [policyPath, pairsPath, output] <- getArgs
  bytes <- BS.readFile policyPath
  policy <- either (fail . show) pure (decodePolicy bytes)
  pairs <- eitherDecodeFileStrict' pairsPath >>= either fail pure :: IO (Map.Map Text [(Double, Double)])
  let compare rule = do
        values <- maybe (fail "missing policy metric") pure (Map.lookup rule.match pairs)
        unless (length values >= policy.minimumPairs) (fail "insufficient pairs")
        pure (rule.match, compareMetricPairs policy rule.match (if rule.match == "op.append.throughput" then "events/s" else "us") rule values)
  metrics <- Map.fromList <$> traverse compare policy.metricRules
  encodeFile output (object ["policy" .= policy, "algorithm" .= ("paired-bootstrap-t-envelope/v1; Kenshou.Measure.Compare.compareMetricPairs" :: Text), "metrics" .= metrics])
