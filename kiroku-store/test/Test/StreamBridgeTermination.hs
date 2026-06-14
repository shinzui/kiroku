{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.StreamBridgeTermination (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, putTMVar)
import Control.Exception (Exception, SomeException, finally, fromException, throwIO, try)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Data (Typeable)
import Data.Generics.Labels ()
import Hasql.Pool qualified as Pool
import Kiroku.Store
import Kiroku.Store.Subscription.Stream (AckItem (..), subscriptionAckStream)
import Kiroku.Store.Subscription.Worker (withFetchBatchHookForTest)
import Streamly.Data.Stream qualified as Stream
import Test.Helpers (makeEvent, waitForPublisher, withTestStore)
import Test.Hspec

data TestBoom = TestBoom
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

appendOne :: KirokuStore -> StreamName -> EventType -> IO GlobalPosition
appendOne store streamName (EventType eventType') = do
    Right r <- runStoreIO store $ appendToStream streamName NoStream [makeEvent eventType' (Aeson.object [])]
    pure (r ^. #globalPosition)

spec :: Spec
spec = describe "stream bridge termination" $ do
    it "rethrows the worker exception to the consumer when the worker dies" $
        withTestStore $ \store -> do
            pos <- appendOne store (StreamName "bridge-crash") (EventType "BridgeCrash")
            waitForPublisher store pos
            let cfg = defaultSubscriptionConfig (SubscriptionName "bridge-crash-sub") AllStreams (\_ -> pure Continue)
                injectBoom _ _ = throwIO TestBoom
            withFetchBatchHookForTest injectBoom $ do
                (stream, cancelStream) <- subscriptionAckStream store cfg 16
                pulled <- within "stream pull to throw TestBoom" (try (Stream.uncons stream))
                cancelStream
                case pulled of
                    Left e
                        | Just TestBoom <- fromException (e :: SomeException) -> pure ()
                    Left e -> expectationFailure ("expected TestBoom, got: " <> show e)
                    Right _ -> expectationFailure "expected stream pull to throw TestBoom"

    it "ends the stream after a clean worker stop" $
        withTestStore $ \store -> do
            let cfg = defaultSubscriptionConfig (SubscriptionName "bridge-clean-stop-sub") AllStreams (\_ -> pure Continue)
            (stream0, cancelStream) <- subscriptionAckStream store cfg 16
            finally
                ( do
                    pos <- appendOne store (StreamName "bridge-clean-stop") (EventType "BridgeCleanStop")
                    waitForPublisher store pos
                    mFirst <- within "first bridge item" (Stream.uncons stream0)
                    (stream1, item) <- case mFirst of
                        Nothing -> fail "expected one bridge item before clean stop"
                        Just (firstItem, rest) -> pure (rest, firstItem)
                    atomically (putTMVar (ackReply item) Stop)
                    mNext <- within "stream end after clean stop" (Stream.uncons stream1)
                    case mNext of
                        Nothing -> pure ()
                        Just _ -> expectationFailure "expected stream to end after clean stop"
                )
                cancelStream

    it "cancelAction returns promptly even when the bridge queue is full" $
        withTestStore $ \store -> do
            let cfg = defaultSubscriptionConfig (SubscriptionName "bridge-full-cancel-sub") AllStreams (\_ -> pure Continue)
            (stream0, cancelStream) <- subscriptionAckStream store cfg 1
            pos1 <- appendOne store (StreamName "bridge-full-cancel-1") (EventType "BridgeFullCancel1")
            pos2 <- appendOne store (StreamName "bridge-full-cancel-2") (EventType "BridgeFullCancel2")
            waitForPublisher store pos2

            within "non-blocking cancelAction with a full queue" cancelStream

            mFirst <- within "drained item after cancel" (Stream.uncons stream0)
            case mFirst of
                Nothing -> pure ()
                Just (item, stream1) -> do
                    atomically (putTMVar (ackReply item) Continue)
                    mNext <- within "stream end after cancel" (Stream.uncons stream1)
                    case mNext of
                        Nothing -> pure ()
                        Just _ -> expectationFailure "expected stream to end after cancel"
