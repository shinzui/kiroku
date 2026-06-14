{-# LANGUAGE OverloadedStrings #-}

module Test.PublisherIdleAdvance (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, tryPutMVar)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (bracket)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.List (sort)
import Data.String (fromString)
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import Test.Helpers (caughtUpEventHandler, makeEvent, waitForPublisher, waitForSubscriptionLive, withTestStoreSettings)
import Test.Hspec

timeoutMicros :: Int
timeoutMicros = 10_000_000

within :: String -> IO a -> IO a
within label action = do
    result <- Async.race (threadDelay timeoutMicros) action
    case result of
        Left () -> fail ("timed out waiting for " <> label)
        Right a -> pure a

countingSettings :: IORef Int -> ConnectionSettings -> ConnectionSettings
countingSettings counter settings =
    settings
        & #storeSettings
            .~ defaultStoreSettings
                { decodeHook =
                    Just $ \event -> do
                        atomicModifyIORef' counter (\n -> (n + 1, ()))
                        pure event
                }

appendEvents :: KirokuStore -> Int -> String -> IO GlobalPosition
appendEvents store n prefix = do
    results <-
        traverse
            ( \i ->
                runStoreIO store $
                    appendToStream
                        (StreamName (fromString (prefix <> "-" <> show i)))
                        NoStream
                        [makeEvent (fromString ("E" <> show i)) (Aeson.object [])]
            )
            [1 .. n]
    case sequence results of
        Left err -> fail ("append failed: " <> show err)
        Right [] -> fail "appendEvents called with zero events"
        Right xs -> pure (last xs ^. #globalPosition)

publisherSubscriberCount :: KirokuStore -> IO Int
publisherSubscriberCount store =
    IntMap.size <$> readTVarIO (Pub.subscribers (store ^. #publisher))

spec :: Spec
spec = describe "publisher idle advance" $ do
    it "advances lastPublished without decoding any rows when no subscriber is registered" $ do
        counter <- newIORef 0
        withTestStoreSettings (countingSettings counter) $ \store -> do
            tailPos <- appendEvents store 25 "pubidle-empty"
            waitForPublisher store tailPos
            readIORef counter `shouldReturn` 0

    it "does not fetch full rows while only a category subscriber exists" $ do
        counter <- newIORef 0
        caughtUp <- newEmptyMVar
        delivered <- newEmptyMVar
        let subName = SubscriptionName "pubidle-category"
            observe = caughtUpEventHandler subName caughtUp Nothing
            handler event = do
                case event ^. #eventType of
                    EventType "Wake" -> () <$ tryPutMVar delivered ()
                    _ -> pure ()
                pure Continue
            tweak settings =
                countingSettings counter settings
                    & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store ->
            bracket
                (subscribe store (defaultSubscriptionConfig subName (Category (CategoryName "pubidlea")) handler))
                cancel
                $ \_handle -> do
                    within "category subscription live" (waitForSubscriptionLive caughtUp)
                    before <- readIORef counter
                    tailPos <- appendEvents store 30 "pubidleb"
                    waitForPublisher store tailPos
                    after <- readIORef counter
                    (after - before) `shouldBe` 0
                    publisherSubscriberCount store `shouldReturn` 0

                    Right wakePos <-
                        runStoreIO store $
                            appendToStream
                                (StreamName "pubidlea-1")
                                NoStream
                                [makeEvent "Wake" (Aeson.object [])]
                    waitForPublisher store (wakePos ^. #globalPosition)
                    within "category wake event" (waitForSubscriptionLive delivered)

    it "switches from cheap advance to all-stream delivery without gaps" $ do
        counter <- newIORef 0
        caughtUp <- newEmptyMVar
        seenRef <- newIORef ([] :: [GlobalPosition])
        seenEnough <- newEmptyMVar
        let subName = SubscriptionName "pubidle-transition"
            observe = caughtUpEventHandler subName caughtUp Nothing
            handler event = do
                let pos = event ^. #globalPosition
                count <-
                    atomicModifyIORef' seenRef $ \old ->
                        let new = pos : old
                         in (new, length new)
                when (count >= 35) (() <$ tryPutMVar seenEnough ())
                pure Continue
            tweak settings =
                countingSettings counter settings
                    & #eventHandler .~ Just observe
        withTestStoreSettings tweak $ \store -> do
            tailBefore <- appendEvents store 20 "pubidle-before"
            waitForPublisher store tailBefore
            bracket
                (subscribe store (defaultSubscriptionConfig subName AllStreams handler))
                cancel
                $ \_handle -> do
                    within "all-stream subscription live" (waitForSubscriptionLive caughtUp)
                    tailAfter <- appendEvents store 15 "pubidle-after"
                    waitForPublisher store tailAfter
                    within "all-stream events" (waitForSubscriptionLive seenEnough)
                    seen <- sort <$> readIORef seenRef
                    seen `shouldBe` fmap GlobalPosition [1 .. 35]
