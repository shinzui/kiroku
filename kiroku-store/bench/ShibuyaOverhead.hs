{- | Benchmark measuring the overhead of the Shibuya adapter layer
compared to bare kiroku subscriptions. Three layers are measured:

1. Bare subscribe: handler receives events directly from the subscription worker
2. subscriptionStream: events pass through a TBQueue bridge to a Streamly stream
3. Shibuya adapter: events flow through subscriptionStream → morphInner → Shibuya pipeline

The bare subscribe handler processes events synchronously (one at a time),
while the stream-based approaches decouple the producer from the consumer
via a TBQueue, allowing the subscription worker to batch-fetch ahead.
This means subscriptionStream and Shibuya can be *faster* for catch-up —
the relevant overhead comparison is shibuya vs subscriptionStream.
-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, registerDelay, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import EphemeralPg qualified as Pg
import Kiroku.Store
import Kiroku.Store.Subscription (subscribe)
import Kiroku.Store.Subscription.Stream (subscriptionStream)
import Kiroku.Store.Subscription.Types (OverflowPolicy (..), SubscriptionConfigM (..), SubscriptionHandleM (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (ProcessorId (..), SupervisionStrategy (..), mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.IO (hFlush, stdout)
import Text.Printf (printf)

iterations :: Int
iterations = 5

main :: IO ()
main = do
    result <- Pg.withCached $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings $ \store -> do
            putStrLn "=== Kiroku Shibuya Adapter Overhead Benchmark ==="
            printf "    %d iterations per measurement\n\n" iterations

            mapM_ (runBenchmarkSuite store) [100, 1000, 5000]

    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()

runBenchmarkSuite :: KirokuStore -> Int -> IO ()
runBenchmarkSuite store n = do
    printf "--- %d events ---\n\n" n

    -- Pre-populate events
    counter <- newIORef (0 :: Int)
    let nextId = atomicModifyIORef' counter (\i -> (i + 1, i))

    let streamPrefix = "bench-" <> T.pack (show n) <> "-"
    let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. n]
    let chunked = chunksOf 10 events
    mapM_
        ( \(idx, chunk) -> do
            let sn = StreamName (streamPrefix <> T.pack (show idx))
            Right _ <- runStoreIO store $ appendToStream sn AnyVersion chunk
            pure ()
        )
        (zip [(0 :: Int) ..] chunked)
    threadDelay 500_000

    -- Run each benchmark multiple times
    bareTimes <- sequence [benchBareSubscribe store n nextId | _ <- [1 .. iterations]]
    streamTimes <- sequence [benchSubscriptionStream store n nextId | _ <- [1 .. iterations]]
    shibuyaTimes <- sequence [benchShibuyaAdapter store n nextId | _ <- [1 .. iterations]]

    let bareMedian = median bareTimes
        streamMedian = median streamTimes
        shibuyaMedian = median shibuyaTimes

    putRow "  bare subscribe" n bareTimes
    putRow "  subscriptionStream" n streamTimes
    putRow "  shibuya adapter" n shibuyaTimes

    putStrLn ""
    let streamVsBare = (streamMedian - bareMedian) / bareMedian * 100
        shibuyaVsBare = (shibuyaMedian - bareMedian) / bareMedian * 100
        shibuyaVsStream = (shibuyaMedian - streamMedian) / streamMedian * 100
    printf "  stream vs bare:    %s\n" (showPct streamVsBare)
    printf "  shibuya vs bare:   %s\n" (showPct shibuyaVsBare)
    printf "  shibuya vs stream: %s  (adapter + framework overhead)\n" (showPct shibuyaVsStream)
    putStrLn ""

-- | Benchmark: bare subscribe with IO handler
benchBareSubscribe :: KirokuStore -> Int -> IO Int -> IO Double
benchBareSubscribe store n nextId = do
    subId <- nextId
    let subName = SubscriptionName ("bare-bench-" <> T.pack (show subId))
    countVar <- newTVarIO (0 :: Int)

    t0 <- getCurrentTime
    let handler _evt = do
            atomically $ do
                c <- readTVar countVar
                writeTVar countVar (c + 1)
            pure Continue
    let cfg =
            SubscriptionConfig
                { name = subName
                , target = AllStreams
                , handler = handler
                , batchSize = 500
                , queueCapacity = 16
                , overflowPolicy = DropSubscription
                , consumerGroup = Nothing
                , consumerGroupGuard = False
                , retryPolicy = defaultRetryPolicy
                , eventTypeFilter = AllEventTypes
                }
    handle <- subscribe store cfg
    waitForCount countVar n 30_000_000
    cancel handle
    t1 <- getCurrentTime
    pure (realToFrac (diffUTCTime t1 t0))

-- | Benchmark: subscriptionStream consumed via Streamly fold
benchSubscriptionStream :: KirokuStore -> Int -> IO Int -> IO Double
benchSubscriptionStream store n nextId = do
    subId <- nextId
    let subName = SubscriptionName ("stream-bench-" <> T.pack (show subId))

    let cfg =
            SubscriptionConfig
                { name = subName
                , target = AllStreams
                , handler = \_ -> pure Continue
                , batchSize = 500
                , queueCapacity = 16
                , overflowPolicy = DropSubscription
                , consumerGroup = Nothing
                , consumerGroupGuard = False
                , retryPolicy = defaultRetryPolicy
                , eventTypeFilter = AllEventTypes
                }

    t0 <- getCurrentTime
    (stream, cancelStream) <- subscriptionStream store cfg 256
    Stream.fold Fold.drain (Stream.take n stream)
    cancelStream
    t1 <- getCurrentTime
    pure (realToFrac (diffUTCTime t1 t0))

-- | Benchmark: Shibuya adapter with runApp
benchShibuyaAdapter :: KirokuStore -> Int -> IO Int -> IO Double
benchShibuyaAdapter store n nextId = do
    subId <- nextId
    let subName = SubscriptionName ("shibuya-bench-" <> T.pack (show subId))
    countVar <- newTVarIO (0 :: Int)

    t0 <- getCurrentTime
    runEff $ runTracingNoop $ do
        let cfg =
                SubscriptionConfig
                    { name = subName
                    , target = AllStreams
                    , handler = \_ -> pure Continue
                    , batchSize = 500
                    , queueCapacity = 16
                    , overflowPolicy = DropSubscription
                    , consumerGroup = Nothing
                    , consumerGroupGuard = False
                    , retryPolicy = defaultRetryPolicy
                    , eventTypeFilter = AllEventTypes
                    }

        (ioStream, cancelAction) <- liftIO $ subscriptionStream store cfg 256

        let effStream = Stream.morphInner liftIO ioStream
            ingestedStream = fmap (mkIngested cancelAction) effStream

        let adapter =
                Adapter
                    { adapterName = "kiroku-bench"
                    , source = ingestedStream
                    , shutdown = liftIO cancelAction
                    }

        let handler :: (IOE :> es) => Ingested es RecordedEvent -> Eff es AckDecision
            handler _ingested = do
                liftIO $ atomically $ do
                    c <- readTVar countVar
                    writeTVar countVar (c + 1)
                pure AckOk

        res <- runApp IgnoreFailures 100 [(ProcessorId "bench", mkProcessor adapter handler)]
        case res of
            Left err -> liftIO $ error ("runApp failed: " <> show err)
            Right appHandle -> do
                liftIO $ waitForCount countVar n 30_000_000
                stopApp appHandle

    t1 <- getCurrentTime
    pure (realToFrac (diffUTCTime t1 t0))

-- Helpers

mkIngested :: (IOE :> es) => IO () -> RecordedEvent -> Ingested es RecordedEvent
mkIngested cancelAction event =
    Ingested
        { envelope =
            Envelope
                { messageId = MessageId (T.pack (show (event ^. #globalPosition)))
                , cursor = let GlobalPosition pos = event ^. #globalPosition in Just (CursorInt (fromIntegral pos))
                , partition = Nothing
                , enqueuedAt = Just (event ^. #createdAt)
                , traceContext = Nothing
                , attempt = Nothing
                , attributes = HashMap.empty
                , payload = event
                }
        , ack =
            AckHandle
                { finalize = \case
                    AckHalt _ -> liftIO cancelAction
                    _ -> pure ()
                }
        , lease = Nothing
        }

waitForCount :: STM.TVar Int -> Int -> Int -> IO ()
waitForCount countVar target timeoutMicros = do
    timeoutVar <- registerDelay timeoutMicros
    ok <-
        atomically $
            (readTVar countVar >>= \c -> STM.check (c >= target) >> pure True)
                `STM.orElse` (readTVar timeoutVar >>= STM.check >> pure False)
    actual <- readTVarIO countVar
    if ok
        then pure ()
        else error ("Timed out: expected " <> show target <> " events, got " <> show actual)

median :: [Double] -> Double
median xs =
    let sorted = sort xs
        len = length sorted
     in if even len
            then (sorted !! (len `div` 2 - 1) + sorted !! (len `div` 2)) / 2
            else sorted !! (len `div` 2)

putRow :: String -> Int -> [Double] -> IO ()
putRow label n times = do
    let med = median times
        lo = minimum times
        hi = maximum times
        throughput = fromIntegral n / med :: Double
        perEvent = med / fromIntegral n * 1_000_000 :: Double
    printf
        "%s:  median %s  [%s .. %s]  (%d events/s, %s/event)\n"
        label
        (showMs med)
        (showMs lo)
        (showMs hi)
        (round throughput :: Int)
        (showUs perEvent)
    hFlush stdout

showMs :: Double -> String
showMs s
    | ms < 1 = printf "%.1f ms" ms
    | ms < 100 = printf "%.0f ms" ms
    | otherwise = printf "%.0f ms" ms
  where
    ms = s * 1000

showUs :: Double -> String
showUs us
    | us >= 1000 = printf "%.1f ms" (us / 1000)
    | us >= 1 = printf "%.0f μs" us
    | otherwise = printf "%.1f μs" us

showPct :: Double -> String
showPct p
    | p >= 0 = printf "+%.0f%%" p
    | otherwise = printf "%.0f%%" p

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf k xs = let (h, t) = splitAt k xs in h : chunksOf k t

makeEvent :: Text -> EventData
makeEvent typ =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = Aeson.object [("benchmark", Aeson.Bool True)]
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }
