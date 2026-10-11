-- Benchmark-only delivery oracle. Positions in this isolated fixture are contiguous.
module Delivery (Delivery (..), initialDelivery, acceptPosition, completeDelivery) where

import Data.Int (Int64)

data Delivery = Delivery {lastPosition :: !Int64, frameCount :: !Int}
    deriving stock (Eq, Show)

initialDelivery :: Delivery
initialDelivery = Delivery 1 0

acceptPosition :: Int64 -> Delivery -> Either String Delivery
acceptPosition position previous
    | position /= previous.lastPosition + 1 = Left "duplicate, gap, or out-of-order event position"
    | otherwise = Right (Delivery position (previous.frameCount + 1))

completeDelivery :: Int -> Delivery -> Bool
completeDelivery expected state = state.frameCount == expected && state.lastPosition == fromIntegral expected + 1
