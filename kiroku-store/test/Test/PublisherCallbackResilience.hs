{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.PublisherCallbackResilience (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception, fromException, throwIO)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.State.Static.Local qualified as State
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.Effect qualified as SubEff
import Kiroku.Store.Subscription.Fsm (SubscriptionState (..))
import Test.Helpers (caughtUpEventHandler, makeEvent, validConsumerGroup, waitForPublisher, waitForSubscriptionLive, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

data CallbackBoom = CallbackBoom
    deriving stock (Show)
    deriving anyclass (Exception)

timeoutMicros :: Int
timeoutMicros = 10_000_000

within :: String -> IO a -> IO a
within label action = do
    result <- Async.race (threadDelay timeoutMicros) action
    case result of
        Left () -> fail ("timed out waiting for " <> label)
        Right a -> pure a

failureOf :: RecordedEvent -> DecodeFailure
failureOf event = DecodeFailure (event ^. #eventId) "cannot decrypt"

poisonHook :: RecordedEvent -> IO (Either DecodeFailure RecordedEvent)
poisonHook event =
    pure $
        if event ^. #eventType == EventType "Boom" then Left (failureOf event) else Right event

appendTypes :: KirokuStore -> Text -> [Text] -> IO ()
appendTypes store stream types = do
    Right _ <- runStoreIO store $ appendToStream (StreamName stream) NoStream (map (\typ -> makeEvent typ (Aeson.object [])) types)
    pure ()

expectCleanStop :: SubscriptionHandle -> IO ()
expectCleanStop handle =
    within "clean subscription stop" (wait handle) >>= \case
        Right () -> pure ()
        Left err -> expectationFailure ("expected clean stop, got " <> show err)

expectDecodeStop :: SubscriptionHandle -> IO DecodeFailure
expectDecodeStop handle =
    within "typed decode stop" (wait handle) >>= \case
        Left err | Just (SubscriptionUndecodable failure) <- fromException err -> pure failure
        other -> fail ("expected SubscriptionUndecodable, got " <> show other)

readCheckpoint :: KirokuStore -> Text -> IO (Maybe Int64)
readCheckpoint store name' = do
    Right value <- Pool.use (store ^. #pool) (Session.statement (name', 0) SQL.getCheckpointMemberStmt)
    pure value

readDeadLetters :: KirokuStore -> Text -> IO [SQL.DeadLetterRecord]
readDeadLetters store name' = do
    Right values <- Pool.use (store ^. #pool) (Session.statement (name', 0) SQL.readDeadLettersStmt)
    pure (V.toList values)

awaitCheckpoint :: KirokuStore -> Text -> Int64 -> IO ()
awaitCheckpoint store name' expected = within "durable checkpoint" loop
  where
    loop = do
        value <- readCheckpoint store name'
        if value == Just expected then pure () else threadDelay 1_000 >> loop

spec :: Spec
spec = describe "publisher callback resilience" $ do
    it "stops only the default subscriber while a sibling dead-letters and continues live" $ do
        defaultLive <- newEmptyMVar
        siblingLive <- newEmptyMVar
        siblingDone <- newEmptyMVar
        attempts <- newIORef []
        defaultSeen <- newIORef ([] :: [EventType])
        siblingSeen <- newIORef ([] :: [EventType])
        publisherFailures <- newTVarIO (0 :: Int)
        retryEvents <- newTVarIO (0 :: Int)
        stopped <- newIORef Nothing
        let defaultName = SubscriptionName "decode-default-live"
            siblingName = SubscriptionName "decode-sibling-live"
            hook event
                | event ^. #eventType == EventType "Boom" = do
                    now <- getMonotonicTimeNSec
                    modifyIORef' attempts (now :)
                    pure (Left (failureOf event))
                | otherwise = pure (Right event)
            observe event = do
                caughtUpEventHandler defaultName defaultLive Nothing event
                caughtUpEventHandler siblingName siblingLive Nothing event
                case event of
                    KirokuEventPublisherDecodeFailed{} -> atomically $ modifyTVar' publisherFailures (+ 1)
                    KirokuEventSubscriptionRetrying name' _ _ _ | name' == defaultName -> atomically $ modifyTVar' retryEvents (+ 1)
                    KirokuEventSubscriptionStopped name' _ (StopUndecodable failure) _ | name' == defaultName -> modifyIORef' stopped (const (Just failure))
                    _ -> pure ()
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}
                    & #eventHandler .~ Just observe
            record ref event = modifyIORef' ref ((event ^. #eventType) :) >> pure Continue
            siblingHandler event = do
                result <- record siblingSeen event
                when (event ^. #eventType == EventType "After") $ () <$ tryPutMVar siblingDone ()
                pure result
        withTestStoreSettings tweak $ \store -> do
            defaultHandle <- subscribe store ((defaultSubscriptionConfig defaultName AllStreams (record defaultSeen)){retryPolicy = RetryPolicy 3})
            sibling <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig siblingName AllStreams siblingHandler)
                        { undecodableHandler = Just (\_ failure -> pure (DeadLetter (DeadLetterDecodeFailure failure)))
                        }
                    )
            waitForSubscriptionLive defaultLive
            waitForSubscriptionLive siblingLive
            appendTypes store "decode-live" ["Before", "Boom", "After"]
            failure <- expectDecodeStop defaultHandle
            decodeFailureReason failure `shouldBe` "cannot decrypt"
            readIORef stopped `shouldReturn` Just failure
            atomically (readTVar retryEvents) `shouldReturn` 2
            within "healthy sibling delivery" (waitForSubscriptionLive siblingDone)
            awaitCheckpoint store "decode-sibling-live" 3
            waitForPublisher store (GlobalPosition 3)
            atomically (readTVar publisherFailures) `shouldReturn` 1
            reverse <$> readIORef defaultSeen `shouldReturn` [EventType "Before"]
            reverse <$> readIORef siblingSeen `shouldReturn` [EventType "Before", EventType "After"]
            readCheckpoint store "decode-default-live" >>= (`shouldSatisfy` maybe False (< 2))
            (map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-default-live") `shouldReturn` []
            letters <- readDeadLetters store "decode-sibling-live"
            map SQL.deadLetterGlobalPosition letters `shouldBe` [2]
            map SQL.deadLetterReasonSummary letters `shouldBe` ["decode failure: cannot decrypt"]
            map SQL.deadLetterReason letters `shouldBe` [Aeson.object ["kind" .= ("decode_failure" :: Text), "event_id" .= (case decodeFailureEventId failure of EventId eid -> show eid), "detail" .= ("cannot decrypt" :: Text)]]
            times <- reverse <$> readIORef attempts
            length times `shouldBe` 3
            zipWith (-) (drop 1 times) times `shouldSatisfy` all (>= 900_000_000)
            currentState sibling >>= \case
                Just Live{} -> pure ()
                other -> expectationFailure ("expected healthy sibling, got " <> show other)
            currentState defaultHandle >>= (`shouldSatisfy` isNothing)
            cancel sibling

    it "shares successful live decoding across subscribers" $ do
        firstLive <- newEmptyMVar
        secondLive <- newEmptyMVar
        calls <- newIORef (0 :: Int)
        let firstName = SubscriptionName "decode-fanout-first"
            secondName = SubscriptionName "decode-fanout-second"
            hook event = modifyIORef' calls (+ 1) >> pure (Right event)
            observe event = do
                caughtUpEventHandler firstName firstLive Nothing event
                caughtUpEventHandler secondName secondLive Nothing event
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}
                    & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            first <- subscribe store (defaultSubscriptionConfig firstName AllStreams (\_ -> pure Stop))
            second <- subscribe store (defaultSubscriptionConfig secondName AllStreams (\_ -> pure Stop))
            waitForSubscriptionLive firstLive
            waitForSubscriptionLive secondLive
            appendTypes store "decode-fanout" ["Good"]
            expectCleanStop first
            expectCleanStop second
            readIORef calls `shouldReturn` 1

    forM_ [(Category (CategoryName "decode"), Nothing), (AllStreams, Just (validConsumerGroup 0 1))] $ \(target', group) ->
        it ("handles an undecodable event after confirmed DB-driven live transition for " <> show (target', group)) $ do
            caughtUp <- newEmptyMVar
            seen <- newIORef ([] :: [EventType])
            let subName = SubscriptionName "decode-db-live"
                tweak settings =
                    settings
                        & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
                        & #eventHandler .~ Just (caughtUpEventHandler subName caughtUp Nothing)
                handler event = modifyIORef' seen ((event ^. #eventType) :) >> pure Stop
            withTestStoreSettings tweak $ \store -> do
                handle <-
                    subscribe
                        store
                        ( (defaultSubscriptionConfig subName target' handler)
                            { consumerGroup = group
                            , undecodableHandler = Just (\_ failure -> pure (DeadLetter (DeadLetterDecodeFailure failure)))
                            }
                        )
                waitForSubscriptionLive caughtUp
                appendTypes store "decode-db-live" ["Boom", "After"]
                expectCleanStop handle
                readIORef seen `shouldReturn` [EventType "After"]
                readCheckpoint store "decode-db-live" `shouldReturn` Just 2
                map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-db-live" `shouldReturn` [1]

    it "does not apply an undecodable disposition to an explicitly filtered-out event" $ do
        let tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-filter" ["Boom", "After"]
            waitForPublisher store (GlobalPosition 2)
            handle <-
                subscribe
                    store
                    ( ( defaultSubscriptionConfig
                            (SubscriptionName "decode-filter")
                            AllStreams
                            ( \event -> do
                                event ^. #eventType `shouldBe` EventType "After"
                                pure Stop
                            )
                      )
                        { eventTypeFilter = OnlyEventTypes (Set.singleton (EventType "After"))
                        , retryPolicy = RetryPolicy 1
                        }
                    )
            expectCleanStop handle
            readCheckpoint store "decode-filter" `shouldReturn` Just 2
            map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-filter" `shouldReturn` []

    it "recovers a typed one-shot failure on the default retry without a callback" $ do
        failedOnce <- newIORef False
        caughtUp <- newEmptyMVar
        seen <- newIORef ([] :: [EventType])
        let subName = SubscriptionName "decode-one-shot"
            hook event
                | event ^. #eventType == EventType "Boom" = do
                    already <- atomicModifyIORef' failedOnce (\old -> (True, old))
                    pure (if already then Right event else Left (failureOf event))
                | otherwise = pure (Right event)
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}
                    & #eventHandler .~ Just (caughtUpEventHandler subName caughtUp Nothing)
            handler event = do
                modifyIORef' seen ((event ^. #eventType) :)
                pure (if event ^. #eventType == EventType "After" then Stop else Continue)
        withTestStoreSettings tweak $ \store -> do
            handle <- subscribe store (defaultSubscriptionConfig subName AllStreams handler)
            waitForSubscriptionLive caughtUp
            appendTypes store "decode-recovery" ["Boom", "After"]
            expectCleanStop handle
            reverse <$> readIORef seen `shouldReturn` [EventType "Boom", EventType "After"]
            readCheckpoint store "decode-one-shot" `shouldReturn` Just 2
            (map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-one-shot") `shouldReturn` []

    forM_ [AllStreams, Category (CategoryName "decode")] $ \target' ->
        forM_ [Nothing, Just (validConsumerGroup 0 1)] $ \group ->
            it ("stops a persistent undecodable event during catch-up for " <> show (target', group)) $ do
                let tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
                    handler _ = expectationFailure "undecodable event reached ordinary handler" >> pure Stop
                withTestStoreSettings tweak $ \store -> do
                    appendTypes store "decode-catchup" ["Boom"]
                    waitForPublisher store (GlobalPosition 1)
                    handle <-
                        subscribe
                            store
                            ( (defaultSubscriptionConfig (SubscriptionName "decode-catchup") target' handler)
                                { consumerGroup = group
                                , retryPolicy = RetryPolicy 1
                                }
                            )
                    _ <- expectDecodeStop handle
                    readCheckpoint store "decode-catchup" `shouldReturn` Just 0
                    (map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-catchup") `shouldReturn` []

    forM_ [Continue, Stop, Retry (RetryDelay 0)] $ \disposition ->
        it ("honors an explicit undecodable disposition " <> show disposition) $ do
            callbacks <- newIORef (0 :: Int)
            seen <- newIORef ([] :: [EventType])
            let tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
                handler event = modifyIORef' seen ((event ^. #eventType) :) >> pure Stop
                callback _ _ = modifyIORef' callbacks (+ 1) >> pure disposition
            withTestStoreSettings tweak $ \store -> do
                appendTypes store "decode-disposition" ["Boom", "After"]
                waitForPublisher store (GlobalPosition 2)
                handle <-
                    subscribe
                        store
                        ( (defaultSubscriptionConfig (SubscriptionName "decode-disposition") AllStreams handler)
                            { undecodableHandler = Just callback
                            , retryPolicy = RetryPolicy 3
                            }
                        )
                expectCleanStop handle
                case disposition of
                    Stop -> do
                        readIORef seen `shouldReturn` []
                        readCheckpoint store "decode-disposition" `shouldReturn` Just 1
                        (map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-disposition") `shouldReturn` []
                    Retry _ -> do
                        readIORef callbacks `shouldReturn` 3
                        letters <- readDeadLetters store "decode-disposition"
                        map SQL.deadLetterReasonSummary letters `shouldBe` ["max retry attempts exceeded (3)"]
                        readCheckpoint store "decode-disposition" `shouldReturn` Just 2
                    _ -> do
                        readIORef callbacks `shouldReturn` 1
                        readIORef seen `shouldReturn` [EventType "After"]
                        (map SQL.deadLetterGlobalPosition <$> readDeadLetters store "decode-disposition") `shouldReturn` []

    it "re-applies the hook on a callback Retry and then calls the ordinary handler" $ do
        failedOnce <- newIORef False
        callbacks <- newIORef (0 :: Int)
        seen <- newIORef ([] :: [EventType])
        let hook event = do
                already <- atomicModifyIORef' failedOnce (\old -> (True, old))
                pure (if already then Right event else Left (failureOf event))
            tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}
            handler event = modifyIORef' seen ((event ^. #eventType) :) >> pure Stop
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-callback-retry" ["Boom"]
            waitForPublisher store (GlobalPosition 1)
            handle <-
                subscribe
                    store
                    ( (defaultSubscriptionConfig (SubscriptionName "decode-callback-retry") AllStreams handler)
                        { undecodableHandler = Just (\_ _ -> modifyIORef' callbacks (+ 1) >> pure (Retry (RetryDelay 0)))
                        }
                    )
            expectCleanStop handle
            readIORef callbacks `shouldReturn` 1
            readIORef seen `shouldReturn` [EventType "Boom"]

    it "fails reads with EventDecodeFailed instead of returning a partial vector" $ do
        let tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-read" ["Before", "Boom", "After"]
            forM_
                [ readAllForward (GlobalPosition 0) 10
                , readAllBackward (GlobalPosition 10) 10
                , readStreamForward (StreamName "decode-read") (StreamVersion 0) 10
                , readStreamBackward (StreamName "decode-read") (StreamVersion 10) 10
                , readCategory (CategoryName "decode") (GlobalPosition 0) 10
                ]
                $ \readEvents ->
                    runStoreIO store readEvents >>= \case
                        Left (EventDecodeFailed failure) -> decodeFailureReason failure `shouldBe` "cannot decrypt"
                        other -> expectationFailure ("expected typed read failure, got " <> show other)

    it "cancels promptly while waiting for the default decode retry" $ do
        retrying <- newEmptyMVar
        let subName = SubscriptionName "decode-cancel"
            observe event = case event of
                KirokuEventSubscriptionRetrying{} -> () <$ tryPutMVar retrying ()
                _ -> pure ()
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
                    & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-cancel" ["Boom"]
            waitForPublisher store (GlobalPosition 1)
            handle <- subscribe store (defaultSubscriptionConfig subName AllStreams (\_ -> pure Continue))
            waitForSubscriptionLive retrying
            startedAt <- getMonotonicTimeNSec
            cancel handle
            finishedAt <- getMonotonicTimeNSec
            finishedAt - startedAt `shouldSatisfy` (< 500_000_000)
            currentState handle >>= (`shouldSatisfy` isNothing)
            readCheckpoint store "decode-cancel" `shouldReturn` Just 0

    it "replays the failed event from its durable checkpoint after the hook is fixed" $ do
        repaired <- newIORef False
        seen <- newIORef ([] :: [EventType])
        let subName = SubscriptionName "decode-restart"
            hook event = do
                healthy <- readIORef repaired
                pure (if healthy then Right event else Left (failureOf event))
            tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just hook}
            handler event = modifyIORef' seen ((event ^. #eventType) :) >> pure Stop
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-restart" ["Boom"]
            waitForPublisher store (GlobalPosition 1)
            failed <- subscribe store ((defaultSubscriptionConfig subName AllStreams handler){retryPolicy = RetryPolicy 1})
            _ <- expectDecodeStop failed
            readCheckpoint store "decode-restart" `shouldReturn` Just 0
            writeIORef repaired True
            recovered <- subscribe store (defaultSubscriptionConfig subName AllStreams handler)
            expectCleanStop recovered
            readIORef seen `shouldReturn` [EventType "Boom"]
            readCheckpoint store "decode-restart" `shouldReturn` Just 1

    it "releases a bracketed subscriber during a pending default decode retry" $ do
        retrying <- newEmptyMVar
        let observe event = case event of
                KirokuEventSubscriptionRetrying{} -> () <$ tryPutMVar retrying ()
                _ -> pure ()
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
                    & #eventHandler .~ Just observe
        within "bracketed store/subscription shutdown" $ withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-shutdown" ["Boom"]
            waitForPublisher store (GlobalPosition 1)
            handle <-
                withSubscription
                    store
                    ((defaultSubscriptionConfig (SubscriptionName "decode-shutdown") AllStreams (\_ -> pure Continue)){retryPolicy = RetryPolicy 100})
                    (\h -> waitForSubscriptionLive retrying >> pure h)
            currentState handle >>= (`shouldSatisfy` isNothing)
            within "cancelled worker completion" (wait handle) >>= \case
                Left err | Just Async.AsyncCancelled <- fromException err -> pure ()
                other -> expectationFailure ("expected bracket cancellation, got " <> show other)

    it "unlifts the undecodable callback in the same persistent effect environment as the handler" $ do
        seen <- newIORef ([] :: [Int])
        let tweak settings = settings & #storeSettings .~ defaultStoreSettings{decodeHook = Just poisonHook}
        withTestStoreSettings tweak $ \store -> do
            appendTypes store "decode-effectful" ["Boom", "After"]
            waitForPublisher store (GlobalPosition 2)
            runEff $ SubEff.runSubscription store $ State.evalState (0 :: Int) $ do
                let config =
                        ( defaultSubscriptionConfig
                            (SubscriptionName "decode-effectful")
                            AllStreams
                            ( \_ -> do
                                State.modify @Int (+ 1)
                                count <- State.get @Int
                                liftIO (modifyIORef' seen (count :))
                                pure Stop
                            )
                        )
                            { undecodableHandler = Just (\_ _ -> State.modify @Int (+ 1) >> pure Continue)
                            }
                handle <- SubEff.subscribe config
                liftIO (expectCleanStop handle)
            readIORef seen `shouldReturn` [2]

    it "keeps the publisher alive when decodeHook throws once" $ do
        failedOnce <- newIORef False
        loopErrorSeen <- newEmptyMVar
        caughtUp <- newEmptyMVar
        delivered <- newIORef ([] :: [EventType])
        deliveredCount <- newTVarIO (0 :: Int)

        let subName = SubscriptionName "publisher-decode-hook-resilience"
            decodeOnce event
                | event ^. #eventType == EventType "Boom" = do
                    alreadyFailed <- atomicModifyIORef' failedOnce (\old -> (True, old))
                    if alreadyFailed
                        then pure (Right event)
                        else throwIO CallbackBoom
                | otherwise = pure (Right event)
            observe evt = do
                case evt of
                    KirokuEventPublisherLoopError{} -> () <$ tryPutMVar loopErrorSeen ()
                    _ -> pure ()
                caughtUpEventHandler subName caughtUp Nothing evt
            tweak settings =
                settings
                    & #storeSettings .~ defaultStoreSettings{decodeHook = Just decodeOnce}
                    & #eventHandler .~ Just observe
            handler event = do
                modifyIORef' delivered ((event ^. #eventType) :)
                atomically $ do
                    n <- readTVar deliveredCount
                    let n' = n + 1
                    writeTVar deliveredCount n'
                    pure $ if n' >= 2 then Stop else Continue

        withTestStoreSettings tweak $ \store -> do
            handle <- subscribe store (defaultSubscriptionConfig subName AllStreams handler)
            waitForSubscriptionLive caughtUp
            Right _ <- runStoreIO store $ appendToStream (StreamName "publisher-decode-boom") NoStream [makeEvent "Boom" (Aeson.object [])]
            within "publisher loop error event" (waitForSubscriptionLive loopErrorSeen)
            Right _ <- runStoreIO store $ appendToStream (StreamName "publisher-decode-ok") NoStream [makeEvent "Ok" (Aeson.object [])]
            result <- waitWithTimeout timeoutMicros handle
            case result of
                Right (Right ()) -> pure ()
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected clean stop, got: " <> show e)

        seen <- reverse <$> readIORef delivered
        seen `shouldBe` [EventType "Boom", EventType "Ok"]

    it "drops throwing eventHandler exceptions without killing publisher or worker" $ do
        deliveredCount <- newTVarIO (0 :: Int)
        let tweak settings = settings & #eventHandler .~ Just (\_ -> throwIO CallbackBoom)
            handler _ = do
                atomically $ do
                    n <- readTVar deliveredCount
                    let n' = n + 1
                    writeTVar deliveredCount n'
                    pure $ if n' >= 3 then Stop else Continue

        withTestStoreSettings tweak $ \store -> do
            handle <- subscribe store (defaultSubscriptionConfig (SubscriptionName "throwing-event-handler-resilience") AllStreams handler)
            Right _ <- runStoreIO store $ appendToStream (StreamName "throwing-handler-1") NoStream [makeEvent "One" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "throwing-handler-2") NoStream [makeEvent "Two" (Aeson.object [])]
            Right _ <- runStoreIO store $ appendToStream (StreamName "throwing-handler-3") NoStream [makeEvent "Three" (Aeson.object [])]
            result <- waitWithTimeout timeoutMicros handle
            case result of
                Right (Right ()) -> pure ()
                Left timeout -> expectationFailure timeout
                Right (Left e) -> expectationFailure ("expected clean stop, got: " <> show e)

        finalCount <- atomically (readTVar deliveredCount)
        finalCount `shouldBe` 3
