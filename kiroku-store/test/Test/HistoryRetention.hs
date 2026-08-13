{-# LANGUAGE NumericUnderscores #-}

module Test.HistoryRetention (spec) where

import Control.Concurrent (threadDelay)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime, secondsToDiffTime)
import Data.Vector qualified as Vector
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "history retention" $ do
    it "validates UTF-8 byte lengths, duration bounds, and inventory bounds" $ do
        mkHistoryRetentionLeaseOwner "" `shouldBe` Left HistoryRetentionLeaseOwnerEmpty
        mkHistoryRetentionLeaseOwner (Text.replicate 256 "é") `shouldSatisfy` either (const False) (const True)
        mkHistoryRetentionLeaseOwner (Text.replicate 257 "é")
            `shouldBe` Left (HistoryRetentionLeaseOwnerTooLong 514)
        mkHistoryRetentionLeaseReason "" `shouldBe` Left HistoryRetentionLeaseReasonEmpty
        mkHistoryRetentionLeaseReason (Text.replicate 2049 "x")
            `shouldBe` Left (HistoryRetentionLeaseReasonTooLong 2049)
        mkHistoryRetentionLeaseDuration (secondsToDiffTime 0) `shouldSatisfy` isLeft
        mkHistoryRetentionLeaseDuration (secondsToDiffTime 1) `shouldSatisfy` either (const False) (const True)
        mkHistoryRetentionLeaseDuration (secondsToDiffTime 3600) `shouldSatisfy` either (const False) (const True)
        mkHistoryRetentionLeaseDuration (secondsToDiffTime 3601) `shouldSatisfy` isLeft
        mkHistoryRetentionInventoryLimit 0 `shouldBe` Left (HistoryRetentionInventoryLimitOutOfRange 0)
        mkHistoryRetentionInventoryLimit 1000 `shouldSatisfy` either (const False) (const True)
        mkHistoryRetentionInventoryLimit 1001 `shouldBe` Left (HistoryRetentionInventoryLimitOutOfRange 1001)

    it "captures the authoritative frontier and database-derived expiry" $
        withTestStore $ \store -> do
            Right appended <-
                runStoreIO store $
                    appendToStream
                        (StreamName "history-retention-frontier")
                        NoStream
                        [ makeEvent "One" (Aeson.object [])
                        , makeEvent "Two" (Aeson.object [])
                        , makeEvent "Three" (Aeson.object [])
                        ]
            lease <- runTx store (acquireHistoryRetentionLeaseTx (request "rebuild" "frontier" 60))
            lease ^. #protectedThrough `shouldBe` appended ^. #globalPosition
            realToFrac (diffUTCTime (lease ^. #expiresAt) (lease ^. #createdAt))
                `shouldBe` secondsToDiffTime 60
            lease ^. #state `shouldBe` HistoryRetentionLeaseActive
            rows <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 10))
            rows `shouldBe` Vector.singleton lease

    it "rolls back acquisition when the surrounding transaction is condemned" $
        withTestStore $ \store -> do
            _ <- runTx store $ do
                lease <- acquireHistoryRetentionLeaseTx (request "rollback" "condemned" 60)
                Tx.condemn
                pure lease
            rows <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 10))
            rows `shouldBe` Vector.empty

    it "renews only the matching active owner and never shortens expiry" $
        withTestStore $ \store -> do
            lease <- runTx store (acquireHistoryRetentionLeaseTx (request "owner-a" "renew" 30))
            let handle = leaseHandle lease
                wrongHandle = HistoryRetentionLeaseHandle (lease ^. #leaseId) (validatedOwner "owner-b")
            mismatch <- runTx store (renewHistoryRetentionLeaseTx wrongHandle (validatedDuration 60))
            mismatch `shouldBe` Left HistoryRetentionRenewalOwnerMismatch
            renewed <- runTx store (renewHistoryRetentionLeaseTx handle (validatedDuration 60))
            case renewed of
                Left err -> expectationFailure ("renewal failed: " <> show err)
                Right value -> do
                    value ^. #expiresAt `shouldSatisfy` (> lease ^. #expiresAt)
                    value ^. #renewedAt `shouldSatisfy` (>= lease ^. #renewedAt)

    it "derives expiry without a worker and refuses resurrection" $
        withTestStore $ \store -> do
            lease <- runTx store (acquireHistoryRetentionLeaseTx (request "crashed" "expiry" 1))
            threadDelay 1_100_000
            rows <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 10))
            fmap (^. #state) (Vector.toList rows) `shouldBe` [HistoryRetentionLeaseExpired]
            renewed <- runTx store (renewHistoryRetentionLeaseTx (leaseHandle lease) (validatedDuration 60))
            renewed `shouldBe` Left HistoryRetentionRenewalExpired
            released <- runTx store (releaseHistoryRetentionLeaseTx (leaseHandle lease))
            case released of
                HistoryRetentionReleaseExpired expiredLease ->
                    expiredLease ^. #state `shouldBe` HistoryRetentionLeaseExpired
                other -> expectationFailure ("expected expired release result, got " <> show other)

    it "releases idempotently and leaves another simultaneous lease active" $
        withTestStore $ \store -> do
            first <- runTx store (acquireHistoryRetentionLeaseTx (request "first" "release" 60))
            second <- runTx store (acquireHistoryRetentionLeaseTx (request "second" "release" 60))
            released <- runTx store (releaseHistoryRetentionLeaseTx (leaseHandle first))
            released `shouldSatisfy` \case HistoryRetentionReleased{} -> True; _ -> False
            repeated <- runTx store (releaseHistoryRetentionLeaseTx (leaseHandle first))
            repeated `shouldSatisfy` \case HistoryRetentionAlreadyReleased{} -> True; _ -> False
            rows <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 10))
            fmap (^. #state) (Vector.toList rows)
                `shouldBe` [HistoryRetentionLeaseReleased, HistoryRetentionLeaseActive]
            Vector.last rows ^. #leaseId `shouldBe` second ^. #leaseId

    it "bounds inventory and prunes only terminal rows older than the cutoff" $
        withTestStore $ \store -> do
            first <- runTx store (acquireHistoryRetentionLeaseTx (request "first" "prune" 60))
            _ <- runTx store (acquireHistoryRetentionLeaseTx (request "second" "keep" 60))
            _ <- runTx store (releaseHistoryRetentionLeaseTx (leaseHandle first))
            bounded <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 1))
            Vector.length bounded `shouldBe` 1
            cutoff <- addUTCTime 1 <$> getCurrentTime
            pruned <- runTx store (pruneHistoryRetentionLeasesTx cutoff)
            pruned `shouldBe` HistoryRetentionPruneResult 0 1
            remaining <- runTx store (historyRetentionLeaseInventoryTx (inventoryQuery 10))
            fmap (^. #state) (Vector.toList remaining) `shouldBe` [HistoryRetentionLeaseActive]

runTx :: KirokuStore -> Tx.Transaction value -> IO value
runTx store transaction = do
    result <- runStoreIO store (runTransaction transaction)
    case result of
        Left err -> expectationFailure ("history retention transaction failed: " <> show err) >> error "unreachable"
        Right value -> pure value

request :: Text.Text -> Text.Text -> Integer -> HistoryRetentionLeaseRequest
request ownerText reasonText seconds =
    HistoryRetentionLeaseRequest
        { owner = validatedOwner ownerText
        , reason = either (error . show) (\value -> value) (mkHistoryRetentionLeaseReason reasonText)
        , duration = validatedDuration seconds
        }

validatedOwner :: Text.Text -> HistoryRetentionLeaseOwner
validatedOwner = either (error . show) (\value -> value) . mkHistoryRetentionLeaseOwner

validatedDuration :: Integer -> HistoryRetentionLeaseDuration
validatedDuration = either (error . show) (\value -> value) . mkHistoryRetentionLeaseDuration . secondsToDiffTime

inventoryQuery :: Int32 -> HistoryRetentionInventoryQuery
inventoryQuery = HistoryRetentionInventoryQuery . either (error . show) (\value -> value) . mkHistoryRetentionInventoryLimit

leaseHandle :: HistoryRetentionLease -> HistoryRetentionLeaseHandle
leaseHandle lease = HistoryRetentionLeaseHandle (lease ^. #leaseId) (lease ^. #owner)
