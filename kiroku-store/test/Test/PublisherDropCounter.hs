{-# LANGUAGE OverloadedRecordDot #-}

module Test.PublisherDropCounter (spec) where

import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.Aeson (object)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Vector qualified as V
import Kiroku.Store
import Kiroku.Store.Subscription.EventPublisher qualified as Pub
import System.Timeout (timeout)
import Test.Helpers (makeEvent, waitForPublisher, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "publisher drop counter" $ do
    it "counts drops, keeps the newest batch and preserves the idempotent wrapper" $ withTestStore $ \store -> do
        baseline <- IntMap.size <$> readTVarIO (Pub.subscribers store.publisher)
        bracket (atomically (Pub.subscribePublisherWith store.publisher 1 DropOldest)) Pub.unsubscribe $ \sub -> do
            appendAndWait store "drop-a" 1
            readTVarIO sub.subscriptionDropped `shouldReturn` 0
            appendAndWait store "drop-b" 2
            readTVarIO sub.subscriptionDropped `shouldReturn` 1
            readTVarIO sub.subscriptionStatus `shouldReturn` Pub.Active
            newest sub.subscriptionQueue `shouldReturn` [GlobalPosition 2]
            bracket (atomically (Pub.subscribePublisher store.publisher 1 DropOldest)) (\(_, _, stop) -> stop) $ \(queue, _, stop) -> do
                appendAndWait store "drop-c" 3
                appendAndWait store "drop-d" 4
                newest queue `shouldReturn` [GlobalPosition 4]
                stop >> stop
            Pub.unsubscribe sub >> Pub.unsubscribe sub
        (IntMap.size <$> readTVarIO (Pub.subscribers store.publisher)) `shouldReturn` baseline
    it "does not count PauseAndResume or DropSubscription overflow" $ withTestStore $ \store ->
        mapM_
            ( \policy -> bracket (atomically (Pub.subscribePublisherWith store.publisher 1 policy)) Pub.unsubscribe $ \sub -> do
                Right pos <- runStoreIO store (appendToStream (StreamName "policies-a") AnyVersion [makeEvent "E" (object [])])
                bounded (waitForPublisher store pos.globalPosition)
                Right pos2 <- runStoreIO store (appendToStream (StreamName "policies-a") AnyVersion [makeEvent "E" (object [])])
                bounded (waitForPublisher store pos2.globalPosition)
                readTVarIO sub.subscriptionDropped `shouldReturn` 0
                readTVarIO sub.subscriptionStatus `shouldReturn` (if policy == PauseAndResume then Pub.Paused else Pub.Overflowed)
            )
            [PauseAndResume, DropSubscription]

appendAndWait :: KirokuStore -> Text -> Int -> IO ()
appendAndWait store name n = do
    Right _ <- runStoreIO store (appendToStream (StreamName name) NoStream [makeEvent "E" (object [])])
    bounded (waitForPublisher store (GlobalPosition (fromIntegral n)))

bounded :: IO a -> IO a
bounded action = timeout 5_000_000 action >>= maybe (fail "publisher timeout") pure

newest :: TBQueue DecodedBatch -> IO [GlobalPosition]
newest queue = do
    Just (UnchangedBatch events) <- atomically (tryReadTBQueue queue)
    atomically (isEmptyTBQueue queue) `shouldReturn` True
    pure (map (.globalPosition) (V.toList events))
