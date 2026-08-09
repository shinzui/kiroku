{-# LANGUAGE NumericUnderscores #-}

module Test.SubscriptionCheckpointInventory (spec) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import System.Timeout (timeout)
import Test.Helpers (caughtUpEventHandler, insertDeadLetterForEvent, makeEvent, waitForPublisher, waitForSubscriptionLive, waitWithTimeout, withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = describe "SubscriptionCheckpointInventory" $ do
    it "returns position zero and no rows for an empty migrated store" $
        withTestStore $ \store -> do
            SubscriptionCheckpointInventory captured rows <- readInventory store
            captured `shouldBe` GlobalPosition 0
            rows `shouldBe` V.empty

    it "returns the exact store position and a member-zero checkpoint" $
        withTestStore $ \store -> do
            appendEvents store "inventory-single" 3
            saveCheckpoint store "single" 0 2

            SubscriptionCheckpointInventory captured rows <- readInventory store
            captured `shouldBe` GlobalPosition 3
            checkpointKeys rows `shouldBe` [("single", 0, 2)]
            now <- getCurrentTime
            case V.toList rows of
                [SubscriptionCheckpoint _ _ _ updatedAt] -> updatedAt `shouldSatisfy` (<= now)
                _ -> expectationFailure "expected exactly one checkpoint"

    it "returns multiple names and members in deterministic key order" $
        withTestStore $ \store -> do
            appendEvents store "inventory-many" 20
            saveCheckpoint store "zeta" 2 7
            saveCheckpoint store "alpha" 10 3
            saveCheckpoint store "alpha" 2 5

            SubscriptionCheckpointInventory captured rows <- readInventory store
            captured `shouldBe` GlobalPosition 20
            checkpointKeys rows
                `shouldBe` [ ("alpha", 2, 5)
                           , ("alpha", 10, 3)
                           , ("zeta", 2, 7)
                           ]

    it "preserves monotonic checkpoints and observes later commits on a fresh read" $
        withTestStore $ \store -> do
            appendEvents store "inventory-monotonic" 10
            saveCheckpoint store "monotonic" 0 8
            saveCheckpoint store "monotonic" 0 4

            first <- readInventory store
            inventoryKeys first `shouldBe` [("monotonic", 0, 8)]

            saveCheckpoint store "monotonic" 0 9
            second <- readInventory store
            inventoryKeys second `shouldBe` [("monotonic", 0, 9)]

    it "retains a durable row after the worker stops and leaves live state" $
        withTestStore $ \store -> do
            appendEvents store "inventory-stopped" 1
            waitForPublisher store (GlobalPosition 1)
            let name = SubscriptionName "stopped"
            handle <- subscribe store (defaultSubscriptionConfig name AllStreams (\_ -> pure Stop))
            waitClean handle

            states <- subscriptionStates store
            Map.member (name, 0) states `shouldBe` False
            inventory <- readInventory store
            inventoryKeys inventory `shouldBe` [("stopped", 0, 1)]

    it "does not expose in-flight live handler progress before checkpoint commit" $ do
        caughtUp <- newEmptyMVar
        enteredHandler <- newEmptyMVar
        releaseHandler <- newEmptyMVar
        let name = SubscriptionName "in-flight"
            observe = caughtUpEventHandler name caughtUp Nothing
            handler _ = do
                putMVar enteredHandler ()
                takeMVar releaseHandler
                pure Stop
            config = defaultSubscriptionConfig name AllStreams handler
        withTestStoreSettings (& #eventHandler .~ Just observe) $ \store -> do
            appendEvents store "inventory-live" 1
            saveCheckpoint store "in-flight" 0 1
            waitForPublisher store (GlobalPosition 1)
            handle <- subscribe store config
            waitForSubscriptionLive caughtUp

            appendEventsExisting store "inventory-live" 1
            waitForMVar "live handler did not receive the event" enteredHandler
            beforeCommit <- readInventory store
            inventoryKeys beforeCommit `shouldBe` [("in-flight", 0, 1)]

            putMVar releaseHandler ()
            waitClean handle
            afterCommit <- readInventory store
            inventoryKeys afterCommit `shouldBe` [("in-flight", 0, 2)]

    it "observes the checkpoint advanced by a dead-letter transaction" $
        withTestStore $ \store -> do
            appendEvents store "inventory-dead-letter" 1
            Right events <- runStoreIO store $ readAllForward (GlobalPosition 0) 10
            let event = V.head events
            insertDeadLetterForEvent store "dead-lettered" event

            inventory <- readInventory store
            inventoryKeys inventory `shouldBe` [("dead-lettered", 0, 1)]

    it "captures a head at or beyond every normally written checkpoint" $
        withTestStore $ \store -> do
            appendEvents store "inventory-bounds" 6
            saveCheckpoint store "bounds-a" 0 2
            saveCheckpoint store "bounds-b" 1 6

            SubscriptionCheckpointInventory (GlobalPosition captured) rows <- readInventory store
            let positions = [position | SubscriptionCheckpoint _ _ (GlobalPosition position) _ <- V.toList rows]
            positions `shouldSatisfy` all (<= captured)

readInventory :: KirokuStore -> IO SubscriptionCheckpointInventory
readInventory store = do
    result <- runStoreIO store subscriptionCheckpointInventory
    case result of
        Left err -> error ("subscriptionCheckpointInventory failed: " <> show err)
        Right inventory -> pure inventory

saveCheckpoint :: KirokuStore -> Text -> Int32 -> Int64 -> IO ()
saveCheckpoint store name member position = do
    result <- Pool.use (store ^. #pool) $ Session.statement (name, member, position) SQL.saveCheckpointMemberStmt
    case result of
        Left err -> error ("saveCheckpoint failed: " <> show err)
        Right () -> pure ()

appendEvents :: KirokuStore -> Text -> Int -> IO ()
appendEvents store stream count = do
    let events = [makeEvent ("E" <> T.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
    result <- runStoreIO store $ appendToStream (StreamName stream) NoStream events
    case result of
        Left err -> error ("appendEvents failed: " <> show err)
        Right _ -> pure ()

appendEventsExisting :: KirokuStore -> Text -> Int -> IO ()
appendEventsExisting store stream count = do
    let events = [makeEvent ("Live" <> T.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
    result <- runStoreIO store $ appendToStream (StreamName stream) StreamExists events
    case result of
        Left err -> error ("appendEventsExisting failed: " <> show err)
        Right _ -> pure ()

waitClean :: SubscriptionHandle -> IO ()
waitClean handle = do
    result <- waitWithTimeout 20_000_000 handle
    case result of
        Left message -> expectationFailure message
        Right (Left err) -> expectationFailure ("subscription failed: " <> show err)
        Right (Right ()) -> pure ()

waitForMVar :: String -> MVar () -> IO ()
waitForMVar failureMessage var = do
    result <- timeout 5_000_000 (takeMVar var)
    case result of
        Nothing -> expectationFailure failureMessage
        Just () -> pure ()

inventoryKeys :: SubscriptionCheckpointInventory -> [(Text, Int32, Int64)]
inventoryKeys (SubscriptionCheckpointInventory _ rows) = checkpointKeys rows

checkpointKeys :: V.Vector SubscriptionCheckpoint -> [(Text, Int32, Int64)]
checkpointKeys rows =
    [ (name, member, position)
    | SubscriptionCheckpoint (SubscriptionName name) member (GlobalPosition position) _ <- V.toList rows
    ]
