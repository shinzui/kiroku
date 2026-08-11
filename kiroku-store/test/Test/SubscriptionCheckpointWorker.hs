{-# LANGUAGE NumericUnderscores #-}

module Test.SubscriptionCheckpointWorker (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, finally, fromException, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Kiroku.Store
import Kiroku.Store.Subscription.Effect qualified as SubEff
import Kiroku.Store.Subscription.Stream (subscriptionAckStream)
import Streamly.Data.Stream qualified as Stream
import Test.Helpers (makeEvent, waitForPublisher, waitWithTimeout, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "subscription checkpoint worker policies" $ do
    it "starts a non-group worker FromBeginning and reports the durable seed" $ do
        eventsRef <- newIORef []
        resolutionsRef <- newIORef []
        let name = SubscriptionName "worker-from-beginning"
            observe evt = case evt of
                KirokuEventSubscriptionCheckpointResolved initialization NonGroup ->
                    modifyIORef' resolutionsRef (initialization :)
                _ -> pure ()
            tweak settings = settings & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            appendBatch store "worker-from-beginning-events" 3
            waitForPublisher store (GlobalPosition 3)
            let handler event = do
                    modifyIORef' eventsRef (event ^. #globalPosition :)
                    seen <- length <$> readIORef eventsRef
                    pure (if seen >= 3 then Stop else Continue)
                config =
                    (defaultSubscriptionConfig name AllStreams handler)
                        { missingCheckpointPolicy = FromBeginning
                        }
            handle <- subscribe store config
            expectClean handle

            reverse <$> readIORef eventsRef
                `shouldReturn` fmap GlobalPosition [1, 2, 3]
            inventoryPositions store
                `shouldReturn` [(SubscriptionCheckpointKey name 0, GlobalPosition 3)]

        readIORef resolutionsRef
            `shouldReturn` [InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 0) (GlobalPosition 0)]

    it "forms a clean FromCurrentHead cut while appends race startup" $ do
        initializationReady <- newEmptyMVar
        deliveredRef <- newIORef []
        let name = SubscriptionName "worker-current-head-race"
            key = SubscriptionCheckpointKey name 0
            observe evt = case evt of
                KirokuEventSubscriptionCheckpointResolved initialization NonGroup
                    | initializationKey initialization == key ->
                        void (tryPutMVar initializationReady initialization)
                _ -> pure ()
            tweak settings = settings & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            appendBatch store "worker-current-head-race-events" 10
            waitForPublisher store (GlobalPosition 10)
            gate <- newEmptyMVar
            let handler event = do
                    modifyIORef' deliveredRef (event ^. #globalPosition :)
                    pure $ if event ^. #eventType == EventType "RaceSentinel" then Stop else Continue
                config =
                    (defaultSubscriptionConfig name AllStreams handler)
                        { missingCheckpointPolicy = FromCurrentHead
                        , batchSize = 3
                        }
            subscribeThread <- Async.async (takeMVar gate >> subscribe store config)
            appendThread <- Async.async $ do
                takeMVar gate
                forM [1 .. 20 :: Int] $ \i ->
                    appendExisting store "worker-current-head-race-events" ("Racing" <> T.pack (show i))
            putMVar gate ()
            putMVar gate ()
            handle <- Async.wait subscribeThread
            initialization <- waitMVar "checkpoint resolution" initializationReady
            racePositions <- Async.wait appendThread
            raceTail <- case reverse racePositions of
                [] -> expectationFailure "expected racing appends" >> error "unreachable"
                position : _ -> pure position
            let seed = checkpointInitializationPosition initialization
            waitForPublisher store raceTail
            finalPosition <- appendExisting store "worker-current-head-race-events" "RaceSentinel"
            waitForPublisher store finalPosition
            expectClean handle

            initialization `shouldBe` InitializedCheckpoint FromCurrentHead key seed
            delivered <- reverse <$> readIORef deliveredRef
            delivered `shouldBe` positionsAfter seed finalPosition

    it "initializes each consumer-group member independently at the current head" $ do
        resolutionsVar <- newTVarIO []
        handlerCalled <- newTVarIO False
        let name = SubscriptionName "worker-current-head-members"
            observe evt = case evt of
                KirokuEventSubscriptionCheckpointResolved initialization GroupMember{} ->
                    atomically (modifyTVar' resolutionsVar (initialization :))
                _ -> pure ()
            tweak settings = settings & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            appendBatch store "worker-current-head-members-events" 6
            waitForPublisher store (GlobalPosition 6)
            let config member =
                    ( defaultSubscriptionConfig name AllStreams $ \_ -> do
                        atomically (writeTVar handlerCalled True)
                        pure Continue
                    )
                        { consumerGroup = Just (ConsumerGroup member 2)
                        , missingCheckpointPolicy = FromCurrentHead
                        }
            handles <- mapM (subscribe store . config) [0, 1]
            atomically $ do
                resolutions <- readTVar resolutionsVar
                check (length resolutions >= 2)
            mapM_ cancel handles
            mapM_ wait handles

            resolutions <- sortOn initializationKey <$> readTVarIO resolutionsVar
            resolutions
                `shouldBe` [ InitializedCheckpoint FromCurrentHead (SubscriptionCheckpointKey name 0) (GlobalPosition 6)
                           , InitializedCheckpoint FromCurrentHead (SubscriptionCheckpointKey name 1) (GlobalPosition 6)
                           ]
            readTVarIO handlerCalled `shouldReturn` False
            inventoryPositions store
                `shouldReturn` [ (SubscriptionCheckpointKey name 0, GlobalPosition 6)
                               , (SubscriptionCheckpointKey name 1, GlobalPosition 6)
                               ]

    it "preserves FailIfMissing through the bracketed plain-IO entry point" $
        withTestStore $ \store -> do
            let name = SubscriptionName "worker-bracketed-missing"
                key = SubscriptionCheckpointKey name 0
                config =
                    (defaultSubscriptionConfig name AllStreams (\_ -> pure Continue))
                        { missingCheckpointPolicy = FailIfMissing
                        }
            outcome <- withSubscription store config wait
            case outcome of
                Left err
                    | Just (SubscriptionCheckpointMissing actual) <- fromException err ->
                        actual `shouldBe` key
                other -> expectationFailure ("expected bracketed missing refusal, got: " <> show other)

    it "preserves FromCurrentHead through the higher-order effect entry point" $ do
        initializationReady <- newEmptyMVar
        deliveredRef <- newIORef []
        let name = SubscriptionName "worker-effect-current-head"
            key = SubscriptionCheckpointKey name 0
            observe evt = case evt of
                KirokuEventSubscriptionCheckpointResolved initialization NonGroup
                    | initializationKey initialization == key ->
                        void (tryPutMVar initializationReady initialization)
                _ -> pure ()
            tweak settings = settings & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            appendBatch store "worker-effect-current-head-events" 5
            waitForPublisher store (GlobalPosition 5)
            runEff $ SubEff.runSubscription store $ do
                let config =
                        ( defaultSubscriptionConfig name AllStreams $ \event -> do
                            liftIO (modifyIORef' deliveredRef (event ^. #globalPosition :))
                            pure Stop
                        )
                            { missingCheckpointPolicy = FromCurrentHead
                            }
                handle <- SubEff.subscribe config
                initialization <- liftIO (waitMVar "effect checkpoint resolution" initializationReady)
                liftIO $ initialization `shouldBe` InitializedCheckpoint FromCurrentHead key (GlobalPosition 5)
                position <- liftIO $ appendExisting store "worker-effect-current-head-events" "EffectFuture"
                liftIO (waitForPublisher store position)
                liftIO (expectClean handle)
            reverse <$> readIORef deliveredRef `shouldReturn` [GlobalPosition 6]

    it "preserves FailIfMissing through the Streamly bridge" $
        withTestStore $ \store -> do
            let name = SubscriptionName "worker-streamly-missing"
                key = SubscriptionCheckpointKey name 0
                config =
                    (defaultSubscriptionConfig name AllStreams (\_ -> pure Continue))
                        { missingCheckpointPolicy = FailIfMissing
                        }
            (stream, cancelStream) <- subscriptionAckStream store config 1
            pulled <- finally (try (Stream.uncons stream)) cancelStream
            case pulled of
                Left err
                    | Just (SubscriptionCheckpointMissing actual) <- fromException (err :: SomeException) ->
                        actual `shouldBe` key
                Left err -> expectationFailure ("expected typed Streamly refusal, got: " <> show err)
                Right _ -> expectationFailure "expected Streamly bridge startup to fail"

initializationKey :: CheckpointInitialization -> SubscriptionCheckpointKey
initializationKey = \case
    ExistingCheckpoint key _ -> key
    InitializedCheckpoint _ key _ -> key

positionsAfter :: GlobalPosition -> GlobalPosition -> [GlobalPosition]
positionsAfter (GlobalPosition start) (GlobalPosition end) =
    fmap GlobalPosition [start + 1 .. end]

inventoryPositions :: KirokuStore -> IO [(SubscriptionCheckpointKey, GlobalPosition)]
inventoryPositions store = do
    Right (SubscriptionCheckpointInventory _ rows) <- runStoreIO store subscriptionCheckpointInventory
    pure
        [ (SubscriptionCheckpointKey name member, position)
        | SubscriptionCheckpoint name member position _ <- V.toList rows
        ]

appendBatch :: KirokuStore -> Text -> Int -> IO GlobalPosition
appendBatch store stream count = do
    let events = [makeEvent ("History" <> T.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
    Right result <- runStoreIO store $ appendToStream (StreamName stream) NoStream events
    pure (result ^. #globalPosition)

appendExisting :: KirokuStore -> Text -> Text -> IO GlobalPosition
appendExisting store stream typ = do
    Right result <-
        runStoreIO store $
            appendToStream (StreamName stream) StreamExists [makeEvent typ (Aeson.object [])]
    pure (result ^. #globalPosition)

expectClean :: SubscriptionHandle -> IO ()
expectClean handle = do
    result <- waitWithTimeout 15_000_000 handle
    case result of
        Left message -> expectationFailure message
        Right (Left err) -> expectationFailure ("subscription failed: " <> show err)
        Right (Right ()) -> pure ()

waitMVar :: String -> MVar a -> IO a
waitMVar label var = do
    result <- Async.race (threadDelay 10_000_000) (takeMVar var)
    case result of
        Left () -> expectationFailure ("timed out waiting for " <> label) >> error "unreachable"
        Right value -> pure value
