-- | EP-45 live Kiroku performance, retained-memory, and restart fixture.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forever, unless, when)
import Data.Aeson (encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import Effectful (liftIO, runEff)
import EphemeralPg qualified as Pg
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Kiroku.Store
import Kiroku.Test.Postgres (ephemeralConfig, migrateTestDatabase)
import Shibuya.Adapter.Kiroku (defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (
    ProcessorId (..),
    ShutdownConfig (drainTimeout, totalShutdownTimeout),
    defaultAppConfig,
    defaultShutdownConfig,
    mkProcessor,
    runApp,
    stopAppGracefully,
 )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (Handle, IOMode (..), hFlush, hPutStrLn, withFile)
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

data Config = Config
    { durationSecs :: !Int
    , messagesPerSecond :: !Int
    , sampleIntervalSecs :: !Int
    , outputCsv :: !FilePath
    , outputLedger :: !FilePath
    , runId :: !String
    , restartAtSecs :: !Int
    , shutdownDrainSecs :: !Int
    , shutdownTotalSecs :: !Int
    }

data Sample = Sample
    { timestamp :: !UTCTime
    , elapsedSecs :: !Int
    , messagesProduced :: !Int
    , messagesProcessed :: !Int
    , messagesFailed :: !Int
    , queueDepth :: !Int64
    , retainedBytes :: !Word64
    , maxLiveBytes :: !Word64
    }

data DeliveryLedger = DeliveryLedger
    { producedIds :: !(IORef (Set Int))
    , processedIds :: !(IORef (Set Int))
    , duplicateIds :: !(IORef (Set Int))
    , malformedDeliveries :: !(IORef Int)
    }

main :: IO ()
main = do
    config <- loadConfig
    let suffix = Text.pack (filter validResourceChar config.runId)
        streamName = StreamName ("ep45-" <> suffix)
        subscriptionName = SubscriptionName ("ep45-" <> suffix)
    putStrLn "=== Shibuya Kiroku lifecycle live fixture ==="
    putStrLn $ "Duration: " <> show config.durationSecs <> " seconds"
    putStrLn $ "Target rate: " <> show config.messagesPerSecond <> " msg/s"
    putStrLn $ "Restart at: " <> show config.restartAtSecs <> " seconds"
    pgConfig <- ephemeralConfig
    result <- Pg.withCachedConfig pgConfig Pg.defaultCacheConfig $ \database -> do
        let connectionString = Pg.connectionString database
        migrateTestDatabase connectionString
        withStore (defaultConnectionSettings connectionString) $ \store ->
            runFixture config store streamName subscriptionName
    case result of
        Left err -> error $ "Failed to start ephemeral PostgreSQL: " <> show err
        Right () -> pure ()
  where
    validResourceChar char =
        ('a' <= char && char <= 'z')
            || ('A' <= char && char <= 'Z')
            || ('0' <= char && char <= '9')
            || char == '-'

loadConfig :: IO Config
loadConfig = do
    duration <- envInt "DURATION_SECS" 1800
    rate <- envInt "MESSAGES_PER_SECOND" 100
    interval <- envInt "SAMPLE_INTERVAL_SECS" 30
    output <- envString "OUTPUT_CSV" "kiroku-lifecycle.csv"
    ledger <- envString "OUTPUT_LEDGER" (output <> ".ledger.json")
    now <- getCurrentTime
    identifier <- envString "LIFECYCLE_RUN_ID" (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now)
    restart <- envInt "RESTART_AT_SECS" (duration `div` 2)
    shutdownDrain <- envInt "SHUTDOWN_DRAIN_SECS" 30
    shutdownTotal <- envInt "SHUTDOWN_TOTAL_SECS" 60
    pure
        Config
            { durationSecs = duration
            , messagesPerSecond = rate
            , sampleIntervalSecs = interval
            , outputCsv = output
            , outputLedger = ledger
            , runId = identifier
            , restartAtSecs = max 1 (min (duration - 1) restart)
            , shutdownDrainSecs = shutdownDrain
            , shutdownTotalSecs = shutdownTotal
            }

envString :: String -> String -> IO String
envString key fallback = maybe fallback (\value -> value) <$> lookupEnv key

envInt :: String -> Int -> IO Int
envInt key fallback = maybe fallback (\value -> value) . (>>= readMaybe) <$> lookupEnv key

runFixture :: Config -> KirokuStore -> StreamName -> SubscriptionName -> IO ()
runFixture config store streamName subscriptionName = do
    producedVar <- newTVarIO (0 :: Int)
    processedRef <- newIORef (0 :: Int)
    failedRef <- newIORef (0 :: Int)
    ledger <- newDeliveryLedger
    stopVar <- newTVarIO False
    startTime <- getCurrentTime

    withFile config.outputCsv WriteMode $ \handle -> do
        hPutStrLn handle csvHeader
        producerThread <- Async.async $ runProducer config store streamName producedVar failedRef ledger stopVar
        samplerThread <- Async.async $ runSampler config store subscriptionName startTime producedVar processedRef failedRef handle

        runConsumerSegment config store subscriptionName processedRef failedRef ledger $ do
            threadDelay (config.restartAtSecs * 1_000_000)
            putStrLn "Graceful midpoint stop"

        putStrLn "Restarting with the same durable subscription"
        runConsumerSegment config store subscriptionName processedRef failedRef ledger $ do
            threadDelay ((config.durationSecs - config.restartAtSecs) * 1_000_000)
            atomically $ writeTVar stopVar True
            Async.wait producerThread
            waitForDrain producedVar processedRef 60
            waitForCheckpointDrain store subscriptionName 30

        Async.cancel samplerThread
        finalSample <- sampleMetrics store subscriptionName startTime producedVar processedRef failedRef
        hPutStrLn handle $ sampleToCsv finalSample
        hFlush handle

        ledgerPassed <- writeDeliveryLedger config ledger

        let passed =
                finalSample.messagesFailed == 0
                    && finalSample.messagesProcessed == finalSample.messagesProduced
                    && finalSample.queueDepth == 0
                    && ledgerPassed
        putStrLn $ "Produced: " <> show finalSample.messagesProduced
        putStrLn $ "Processed: " <> show finalSample.messagesProcessed
        putStrLn $ "Durable backlog: " <> show finalSample.queueDepth
        unless passed exitFailure

runProducer :: Config -> KirokuStore -> StreamName -> TVar Int -> IORef Int -> DeliveryLedger -> TVar Bool -> IO ()
runProducer config store streamName producedVar failedRef ledger stopVar = loop (0 :: Int)
  where
    delayMicros = 1_000_000 `div` max 1 config.messagesPerSecond
    loop index = do
        shouldStop <- readTVarIO stopVar
        unless shouldStop $ do
            let event =
                    EventData
                        { eventId = Nothing
                        , eventType = EventType "Ep45Lifecycle"
                        , payload = object ["sequence" .= index]
                        , metadata = Nothing
                        , causationId = Nothing
                        , correlationId = Nothing
                        }
            result <- runStoreIO store $ appendToStream streamName AnyVersion [event]
            case result of
                Left _ -> atomicModifyIORef' failedRef $ \count -> (count + 1, ())
                Right _ -> do
                    atomically $ modifyTVar' producedVar (+ 1)
                    recordProduced ledger index
            when (delayMicros > 0) $ threadDelay delayMicros
            loop (index + 1)

runConsumerSegment :: Config -> KirokuStore -> SubscriptionName -> IORef Int -> IORef Int -> DeliveryLedger -> IO () -> IO ()
runConsumerSegment config store subscriptionName processedRef failedRef ledger action =
    runEff $ runTracingNoop $ do
        adapter <- kirokuAdapter store (defaultKirokuAdapterConfig subscriptionName AllStreams)
        result <- runApp defaultAppConfig [(ProcessorId "kiroku-ep45", mkProcessor adapter handler)]
        case result of
            Left err -> liftIO $ error $ "runApp failed: " <> show err
            Right appHandle -> do
                liftIO action
                let shutdownConfig =
                        defaultShutdownConfig
                            { drainTimeout = fromIntegral config.shutdownDrainSecs
                            , totalShutdownTimeout = fromIntegral config.shutdownTotalSecs
                            }
                drained <- stopAppGracefully shutdownConfig appHandle
                unless drained $ liftIO $ error "Shibuya application required forced shutdown"
  where
    handler message = do
        let Message{envelope = Envelope{payload = recorded}} = message
            sequenceNumber = parseMaybe (withObject "EP-45 event" (.: "sequence")) recorded.payload
        case sequenceNumber of
            Nothing -> do
                liftIO $ do
                    atomicModifyIORef' failedRef $ \count -> (count + 1, ())
                    atomicModifyIORef' ledger.malformedDeliveries $ \count -> (count + 1, ())
                pure $ AckDeadLetter (InvalidPayload "EP-45 ledger sequence missing")
            Just value -> do
                liftIO $ do
                    atomicModifyIORef' processedRef $ \count -> (count + 1, ())
                    recordProcessed ledger value
                pure AckOk

newDeliveryLedger :: IO DeliveryLedger
newDeliveryLedger =
    DeliveryLedger
        <$> newIORef Set.empty
        <*> newIORef Set.empty
        <*> newIORef Set.empty
        <*> newIORef 0

recordProduced :: DeliveryLedger -> Int -> IO ()
recordProduced ledger value =
    atomicModifyIORef' ledger.producedIds $ \values -> (Set.insert value values, ())

recordProcessed :: DeliveryLedger -> Int -> IO ()
recordProcessed ledger value = do
    duplicate <- atomicModifyIORef' ledger.processedIds $ \values ->
        (Set.insert value values, Set.member value values)
    when duplicate $
        atomicModifyIORef' ledger.duplicateIds $
            \values -> (Set.insert value values, ())

writeDeliveryLedger :: Config -> DeliveryLedger -> IO Bool
writeDeliveryLedger config ledger = do
    produced <- readIORef ledger.producedIds
    processed <- readIORef ledger.processedIds
    duplicates <- readIORef ledger.duplicateIds
    malformed <- readIORef ledger.malformedDeliveries
    let missing = produced `Set.difference` processed
        unexpected = processed `Set.difference` produced
        passed = Set.null missing && Set.null unexpected && Set.null duplicates && malformed == 0
        artifact =
            object
                [ "schemaVersion" .= (1 :: Int)
                , "adapter" .= ("kiroku" :: String)
                , "runId" .= config.runId
                , "status" .= if passed then ("pass" :: String) else "fail"
                , "producedIds" .= Set.toAscList produced
                , "processedIds" .= Set.toAscList processed
                , "duplicateIds" .= Set.toAscList duplicates
                , "missingIds" .= Set.toAscList missing
                , "unexpectedIds" .= Set.toAscList unexpected
                , "malformedDeliveries" .= malformed
                ]
    LBS.writeFile config.outputLedger (encode artifact)
    putStrLn $ "Delivery ledger: " <> config.outputLedger <> " (" <> if passed then "pass)" else "fail)"
    pure passed

runSampler :: Config -> KirokuStore -> SubscriptionName -> UTCTime -> TVar Int -> IORef Int -> IORef Int -> Handle -> IO ()
runSampler config store subscriptionName startTime producedVar processedRef failedRef handle = forever $ do
    threadDelay (config.sampleIntervalSecs * 1_000_000)
    sample <- sampleMetrics store subscriptionName startTime producedVar processedRef failedRef
    hPutStrLn handle $ sampleToCsv sample
    hFlush handle
    putStrLn $
        "["
            <> show sample.elapsedSecs
            <> "s] produced="
            <> show sample.messagesProduced
            <> " processed="
            <> show sample.messagesProcessed
            <> " backlog="
            <> show sample.queueDepth
            <> " retained="
            <> show sample.retainedBytes

sampleMetrics :: KirokuStore -> SubscriptionName -> UTCTime -> TVar Int -> IORef Int -> IORef Int -> IO Sample
sampleMetrics store subscriptionName startTime producedVar processedRef failedRef = do
    now <- getCurrentTime
    produced <- readTVarIO producedVar
    processed <- readIORef processedRef
    failed <- readIORef failedRef
    backlog <- checkpointBacklog store subscriptionName
    (retained, highWater) <- getMemoryBytes
    pure
        Sample
            { timestamp = now
            , elapsedSecs = round $ diffUTCTime now startTime
            , messagesProduced = produced
            , messagesProcessed = processed
            , messagesFailed = failed
            , queueDepth = backlog
            , retainedBytes = retained
            , maxLiveBytes = highWater
            }

checkpointBacklog :: KirokuStore -> SubscriptionName -> IO Int64
checkpointBacklog store subscriptionName = do
    result <- runStoreIO store subscriptionCheckpointInventory
    inventory <- case result of
        Left err -> error $ "Checkpoint inventory failed: " <> show err
        Right value -> pure value
    let GlobalPosition storePosition = inventory.storePosition
        checkpointPosition =
            case Vector.find isTargetCheckpoint inventory.checkpoints of
                Nothing -> 0
                Just checkpoint ->
                    let GlobalPosition position = checkpoint.checkpointPosition
                     in position
    pure $ max 0 (storePosition - checkpointPosition)
  where
    isTargetCheckpoint (SubscriptionCheckpoint name member _ _) =
        name == subscriptionName && member == 0

getMemoryBytes :: IO (Word64, Word64)
getMemoryBytes = do
    enabled <- getRTSStatsEnabled
    if enabled
        then do
            performMajorGC
            stats <- getRTSStats
            pure (gcdetails_live_bytes stats.gc, max_live_bytes stats)
        else pure (0, 0)

waitForDrain :: TVar Int -> IORef Int -> Int -> IO ()
waitForDrain producedVar processedRef timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
        produced <- readTVarIO producedVar
        processed <- readIORef processedRef
        if processed >= produced
            then pure ()
            else
                if remaining > 0
                    then threadDelay 100_000 >> loop (remaining - 1)
                    else error $ "Timed out draining produced events: produced=" <> show produced <> " processed=" <> show processed

waitForCheckpointDrain :: KirokuStore -> SubscriptionName -> Int -> IO ()
waitForCheckpointDrain store subscriptionName timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
        backlog <- checkpointBacklog store subscriptionName
        if backlog <= 0
            then pure ()
            else
                if remaining > 0
                    then threadDelay 100_000 >> loop (remaining - 1)
                    else error $ "Timed out draining Kiroku checkpoint backlog: backlog=" <> show backlog

csvHeader :: String
csvHeader = "timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes"

sampleToCsv :: Sample -> String
sampleToCsv sample =
    Text.unpack $
        Text.intercalate
            ","
            [ Text.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" sample.timestamp
            , Text.pack $ show sample.elapsedSecs
            , Text.pack $ show sample.messagesProduced
            , Text.pack $ show sample.messagesProcessed
            , Text.pack $ show sample.messagesFailed
            , Text.pack $ show sample.queueDepth
            , Text.pack $ show sample.retainedBytes
            , Text.pack $ show sample.maxLiveBytes
            ]
