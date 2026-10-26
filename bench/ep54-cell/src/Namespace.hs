{-# LANGUAGE CPP #-}

-- Optional plan-54 diagnostic. The identical producer/observer code builds
-- against the original control without referring to the new constructor.
module Namespace (withNamespace) where

import Data.Aeson qualified as A
import Kiroku.Store qualified as S
#ifdef EP54_NAMESPACE
import Kiroku.Store.Subscription.Fsm qualified as Fsm
#endif
#ifdef EP54_NAMESPACE
import Data.Aeson.KeyMap qualified as KM
import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.IORef
import Data.Int (Int64)
import Data.List (sort)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (preparable)
import System.Timeout (timeout)
#endif

withNamespace :: S.KirokuStore -> Bool -> (IO A.Value -> IO a) -> IO a
#ifdef EP54_NAMESPACE
withNamespace store True action = do
    positions <- newIORef ([] :: [Int64])
    lags <- newIORef ([] :: [Double])
    started <- getMonotonicTimeNSec
    let handler event = do
            now <- getMonotonicTimeNSec
            let S.GlobalPosition position = event.globalPosition
            sent <- case event.payload of
                A.Object fields | Just value <- KM.lookup "sent_ns" fields ->
                    case A.fromJSON value of
                        A.Success timestamp -> pure (timestamp :: Int64)
                        A.Error error' -> fail error'
                _ -> fail "namespace payload lacks timestamp"
            atomicModifyIORef' positions (\xs -> (position : xs, ()))
            atomicModifyIORef' lags (\xs -> (fromIntegral (fromIntegral now - sent :: Int64) / 1000 : xs, ()))
            pure S.Continue
        config = S.defaultSubscriptionConfig (S.SubscriptionName "ep54-namespace") (S.CategoryNamespace "ns") handler
    S.withSubscription store config $ \handle -> do
        bounded $ let ready = handle.currentState >>= \case
                        Just Fsm.Live {} -> pure ()
                        _ -> threadDelay 1000 >> ready
                  in ready
        caughtUp <- getMonotonicTimeNSec
        action $ do
            expected <- query "SELECT stream_version FROM stream_events WHERE stream_id=0 AND (category='ns' OR starts_with(category,'ns:')) ORDER BY stream_version" (D.rowList (D.column (D.nonNullable D.int8)))
            bounded $ let complete = do
                            actual <- reverse <$> readIORef positions
                            if actual == expected then pure () else threadDelay 1000 >> complete
                      in complete
            actual <- reverse <$> readIORef positions
            unless (actual == expected && actual == sort actual) (fail "namespace delivery mismatch")
            checkpoint <- bounded $ let saved = do
                                         position <- query "SELECT last_seen FROM subscriptions WHERE subscription_name='ep54-namespace' AND consumer_group_member=0" (D.singleRow (D.column (D.nonNullable D.int8)))
                                         if null expected || position >= last expected then pure position else threadDelay 1000 >> saved
                                   in saved
            samples <- readIORef lags
            pure (A.object ["exact_ordered_delivery" A..= True, "matched" A..= length actual,
                "checkpoint" A..= checkpoint, "catchup_us" A..= (fromIntegral (caughtUp-started)/1000 :: Double),
                "raw_lag_us" A..= samples])
  where
    bounded io = timeout 30_000_000 io >>= maybe (fail "namespace diagnostic deadline") pure
    query :: T.Text -> D.Result a -> IO a
    query sql decoder = Pool.use store.pool (Session.statement () (preparable sql E.noParams decoder)) >>= either (fail . show) pure
withNamespace _ False action = action (pure A.Null)
#else
withNamespace _ _ action = action (pure A.Null)
#endif
