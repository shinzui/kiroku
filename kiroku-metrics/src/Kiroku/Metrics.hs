{- | Umbrella re-export for the @kiroku-metrics@ package. Importing
@Kiroku.Metrics@ brings the in-process metrics collector and the
JSON-encodable snapshot type into scope.
-}
module Kiroku.Metrics (
    module Kiroku.Metrics.Types,
    module Kiroku.Metrics.Collector,
) where

import Kiroku.Metrics.Collector
import Kiroku.Metrics.Types
