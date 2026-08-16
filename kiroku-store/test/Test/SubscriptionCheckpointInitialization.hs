{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeApplications #-}

module Test.SubscriptionCheckpointInitialization (spec) where

import Control.Concurrent.Async qualified as Async
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "subscription checkpoint initialization" $ do
    it "materializes position zero for FromBeginning" $
        withTestStore $ \store -> do
            let name = SubscriptionName "initialize-from-beginning"
                key = SubscriptionCheckpointKey name 0
            result <- initialize store name 0 FromBeginning
            result `shouldBe` Right (InitializedCheckpoint FromBeginning key (GlobalPosition 0))
            inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 0)]

    it "atomically materializes the current store head for FromCurrentHead" $
        withTestStore $ \store -> do
            appendEvents store "initialize-current-head-events" 3
            let name = SubscriptionName "initialize-current-head"
                key = SubscriptionCheckpointKey name 0
            result <- initialize store name 0 FromCurrentHead
            result `shouldBe` Right (InitializedCheckpoint FromCurrentHead key (GlobalPosition 3))
            inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 3)]

    it "returns a typed missing result without creating a row for FailIfMissing" $
        withTestStore $ \store -> do
            let name = SubscriptionName "initialize-fail-if-missing"
                key = SubscriptionCheckpointKey name 0
            result <- initialize store name 0 FailIfMissing
            result `shouldBe` Left (SubscriptionCheckpointMissing key)
            inventoryKeys <$> inventory store `shouldReturn` []

    it "preserves an existing row for every configured policy" $
        withTestStore $ \store -> do
            appendEvents store "initialize-existing-events" 5
            let name = SubscriptionName "initialize-existing"
                key = SubscriptionCheckpointKey name 0
            initialize store name 0 FromCurrentHead
                `shouldReturn` Right (InitializedCheckpoint FromCurrentHead key (GlobalPosition 5))
            mapM_ (assertExisting store key) [FromBeginning, FromCurrentHead, FailIfMissing]
            inventoryKeys <$> inventory store `shouldReturn` [(name, 0, GlobalPosition 5)]

    it "isolates checkpoint initialization by consumer-group member" $
        withTestStore $ \store -> do
            appendEvents store "initialize-member-events" 4
            let name = SubscriptionName "initialize-members"
            initialize store name 0 FromBeginning
                `shouldReturn` Right (InitializedCheckpoint FromBeginning (SubscriptionCheckpointKey name 0) (GlobalPosition 0))
            initialize store name 1 FromCurrentHead
                `shouldReturn` Right (InitializedCheckpoint FromCurrentHead (SubscriptionCheckpointKey name 1) (GlobalPosition 4))
            inventoryKeys <$> inventory store
                `shouldReturn` [ (name, 0, GlobalPosition 0)
                               , (name, 1, GlobalPosition 4)
                               ]

    it "converges concurrent initializers on one durable winner" $
        withTestStore $ \store -> do
            appendEvents store "initialize-race-events" 7
            let name = SubscriptionName "initialize-race"
                policies = take 20 (cycle [FromBeginning, FromCurrentHead])
            results <- Async.mapConcurrently (initialize store name 3) policies
            let successes = [initialization | Right initialization <- results]
                positions = fmap checkpointInitializationPosition successes
                initializedCount = length [() | InitializedCheckpoint{} <- successes]
            length successes `shouldBe` length policies
            initializedCount `shouldBe` 1
            positions `shouldSatisfy` \case
                [] -> False
                first : rest -> all (== first) rest
            case positions of
                [] -> expectationFailure "expected concurrent initialization results"
                winner : _ ->
                    inventoryKeys <$> inventory store
                        `shouldReturn` [(name, 3, winner)]

    it "runs through the resource-backed Store interpreter" $
        withTestStore $ \store -> do
            let name = SubscriptionName "initialize-resource"
                key = SubscriptionCheckpointKey name 2
            result <-
                runEff
                    . runErrorNoCallStack @StoreError
                    . runKirokuStoreWith store
                    . runStoreResource
                    $ initializeSubscriptionCheckpoint name 2 FromBeginning
            result `shouldBe` Right (Right (InitializedCheckpoint FromBeginning key (GlobalPosition 0)))

assertExisting :: KirokuStore -> SubscriptionCheckpointKey -> MissingCheckpointPolicy -> IO ()
assertExisting store key@(SubscriptionCheckpointKey name member) policy =
    initialize store name member policy
        `shouldReturn` Right (ExistingCheckpoint key (GlobalPosition 5))

initialize ::
    KirokuStore ->
    SubscriptionName ->
    Int32 ->
    MissingCheckpointPolicy ->
    IO (Either SubscriptionCheckpointMissing CheckpointInitialization)
initialize store name member policy = do
    result <- runStoreIO store (initializeSubscriptionCheckpoint name member policy)
    case result of
        Left err -> expectationFailure ("checkpoint initialization failed: " <> show err) >> error "unreachable"
        Right initialized -> pure initialized

inventory :: KirokuStore -> IO SubscriptionCheckpointInventory
inventory store = do
    result <- runStoreIO store subscriptionCheckpointInventory
    case result of
        Left err -> expectationFailure ("checkpoint inventory failed: " <> show err) >> error "unreachable"
        Right rows -> pure rows

inventoryKeys :: SubscriptionCheckpointInventory -> [(SubscriptionName, Int32, GlobalPosition)]
inventoryKeys (SubscriptionCheckpointInventory _ rows) =
    [ (name, member, position)
    | SubscriptionCheckpoint name member position _ <- V.toList rows
    ]

appendEvents :: KirokuStore -> Text -> Int -> IO ()
appendEvents store stream count = do
    let events = [makeEvent ("Initialize" <> T.pack (show i)) (Aeson.object []) | i <- [1 .. count]]
    result <- runStoreIO store $ appendToStream (StreamName stream) NoStream events
    case result of
        Left err -> expectationFailure ("append failed: " <> show err)
        Right _ -> pure ()
