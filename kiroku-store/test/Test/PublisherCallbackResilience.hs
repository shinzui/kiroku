{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.PublisherCallbackResilience (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Data (Typeable)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Kiroku.Store
import Test.Helpers (caughtUpEventHandler, makeEvent, waitForSubscriptionLive, waitWithTimeout, withTestStoreSettings)
import Test.Hspec

data CallbackBoom = CallbackBoom
    deriving stock (Show, Typeable)
    deriving anyclass (Exception)

timeoutMicros :: Int
timeoutMicros = 10_000_000

within :: String -> IO a -> IO a
within label action = do
    result <- Async.race (threadDelay timeoutMicros) action
    case result of
        Left () -> fail ("timed out waiting for " <> label)
        Right a -> pure a

spec :: Spec
spec = describe "publisher callback resilience" $ do
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
                        then pure event
                        else throwIO CallbackBoom
                | otherwise = pure event
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
