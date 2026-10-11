{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.Async (concurrently, withAsync)
import Control.Concurrent.STM
import Control.Exception (evaluate)
import Control.Monad (forM, replicateM_)
import Data.Aeson (encode, object)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.List (sort)
import Data.Maybe (fromJust)
import Data.Text qualified as T
import Data.Time.Clock
import Data.Vector qualified as V
import Kiroku.Metrics.WebSocket
import Kiroku.Store hiding (cancel, id)
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Kiroku.Test.Postgres (withMigratedTestDatabase)
import System.Timeout (timeout)

main :: IO ()
main = withMigratedTestDatabase $ \conn -> withStore (defaultConnectionSettings conn) $ \store -> do
    -- Setup and publication complete before the fixed comparison.
    mapM_ (\n -> append store (StreamName ("names-" <> T.pack (show n))) 1) [1 .. 500 :: Int]
    append store (StreamName "appender") 1
    bounded (atomically (Pub.publisherPosition store.publisher >>= check . (>= GlobalPosition 501)))
    Right events <- runStoreIO store (readAllForward (GlobalPosition 0) 500)
    putStrLn "Focused local tail delivery: 500 distinct names, 50 batches/trial, 5 paired rounds."
    putStrLn "Each case concurrently appends 50 batches of 10 events to the same existing stream."
    putStrLn "Control uses frozen encoder, warm caches pre-resolve, cold starts one cache per trial. No remote acceptance inference."
    samples <- forM [0 .. 4 :: Int] $ \roundNumber -> do
        let modes = if even roundNumber then ["control", "warm", "cold"] else ["cold", "warm", "control"]
        measured <- traverse (runCase store events) modes
        pure [(mode, result) | (mode, result) <- zip modes measured]
    mapM_
        ( \name -> do
            let xs = map (fromJust . lookup name) samples
            putStrLn (name <> " raw (tail ms, append ms, lookups, retained map/FIFO): " <> show xs)
            putStrLn (name <> " medians tail/append ms: " <> show (median [t | (t, _, _, _) <- xs], median [a | (_, a, _, _) <- xs]))
        )
        ["control", "warm", "cold"]
    finalHead <- runStoreIO store visibleGlobalHeadPosition
    case finalHead of
        Right (GlobalPosition 8001) -> putStrLn "Verified 501 seeded + 7500 concurrently appended events; final visible head 8001."
        other -> fail ("unexpected final head: " <> show other)

runCase :: KirokuStore -> V.Vector RecordedEvent -> String -> IO (Double, Double, Int, (Int, Int))
runCase store events mode = do
    cache <- newStreamNameCache
    calls <- newIORef (0 :: Int)
    count <- newTVarIO (0 :: Int)
    sub <- Pub.PublisherSubscription <$> newTBQueueIO 1 <*> newTVarIO Pub.Active <*> newTVarIO 0 <*> pure (pure ())
    let lookupBatch ids = do
            modifyIORef' calls (+ 1)
            either (error . show) id <$> runStoreIO store (lookupStreamNames ids)
        send msg = do
            _ <- evaluate (LBS.length (encode msg))
            case msg of
                Event _ -> atomically (modifyTVar' count (+ 1))
                _ -> fail "unexpected loss/error"
        worker =
            if mode == "control"
                then replicateM_ 50 $ do
                    UnchangedBatch batch <- atomically (readTBQueue sub.subscriptionQueue)
                    V.mapM_ (send . Event . recordedEventToJSON) (V.filter (const True) batch)
                    -- Reproduce the original loop's post-delivery status sample.
                    _ <- atomically (readTVar sub.subscriptionStatus)
                    pure ()
                else broadcastEventsWith send cache lookupBatch sub (const True)
    if mode == "warm" then resolveEventNames cache lookupBatch events >> writeIORef calls 0 else pure ()
    withAsync worker $ \_ -> do
        (tailMs, appendMs) <-
            concurrently
                ( timed $ do
                    replicateM_ 50 (atomically (writeTBQueue sub.subscriptionQueue (UnchangedBatch events)))
                    bounded (atomically (readTVar count >>= check . (== 25000)))
                )
                (timed $ replicateM_ 50 (append store (StreamName "appender") 10))
        lookups <- readIORef calls
        retained <- streamNameCacheSize cache
        if mode == "control"
            then pure ()
            else do
                if lookups == (if mode == "warm" then 0 else 1) && retained == (500, 500) then pure () else fail "cache invariant failed"
        pure (tailMs, appendMs, lookups, retained)

append :: KirokuStore -> StreamName -> Int -> IO ()
append store name n = do
    result <- runStoreIO store (appendToStream name AnyVersion (replicate n (EventData Nothing (EventType "Bench") (object []) Nothing Nothing Nothing)))
    either (fail . show) (const (pure ())) result

timed :: IO a -> IO Double
timed action = do
    t0 <- getCurrentTime
    _ <- action
    t1 <- getCurrentTime
    pure (realToFrac (diffUTCTime t1 t0) * 1000 :: Double)

bounded :: IO a -> IO a
bounded action = timeout 30_000_000 action >>= maybe (fail "focused tail timeout") pure
median :: [Double] -> Double
median xs = sort xs !! (length xs `div` 2)
