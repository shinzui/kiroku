{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Test.HistoryRetention (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime, secondsToDiffTime)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable, unpreparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Test.Helpers (countEvents, makeEvent, withTestStore, withTestStoreSettings)
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

    it "emits committed effect transitions once and no false repeated-release event" $ do
        observed <- newIORef ([] :: [KirokuEvent])
        withTestStoreSettings
            (& #eventHandler .~ Just (\event -> modifyIORef' observed (event :)))
            $ \store -> do
                Right lease <- runStoreIO store $ acquireHistoryRetentionLease (request "events" "not-a-label" 60)
                Right (Right _) <-
                    runStoreIO store $
                        renewHistoryRetentionLease (leaseHandle lease) (validatedDuration 120)
                Right HistoryRetentionReleased{} <-
                    runStoreIO store $
                        releaseHistoryRetentionLease (leaseHandle lease)
                Right HistoryRetentionAlreadyReleased{} <-
                    runStoreIO store $
                        releaseHistoryRetentionLease (leaseHandle lease)
                cutoff <- addUTCTime 1 <$> getCurrentTime
                Right (HistoryRetentionPruneResult 0 1) <-
                    runStoreIO store $
                        pruneHistoryRetentionLeases cutoff
                pure ()
        events <- readIORef observed
        length [() | KirokuEventHistoryRetentionLeaseAcquired{} <- events] `shouldBe` 1
        length [() | KirokuEventHistoryRetentionLeaseRenewed{} <- events] `shouldBe` 1
        length [() | KirokuEventHistoryRetentionLeaseReleased{} <- events] `shouldBe` 1
        length [() | KirokuEventHistoryRetentionLeasesPruned{} <- events] `shouldBe` 1

    it "returns and emits a typed hard-delete conflict without changing history while any lease is active" $ do
        observed <- newIORef ([] :: [KirokuEvent])
        withTestStoreSettings
            (& #eventHandler .~ Just (\event -> modifyIORef' observed (event :)))
            $ \store -> do
                let stream = StreamName "history-retention-hard-delete"
                Right _ <- runStoreIO store $ appendToStream stream NoStream [makeEvent "Protected" (Aeson.object [])]
                countBefore <- countEvents store
                Right first <- runStoreIO store $ acquireHistoryRetentionLease (request "first" "protect" 60)
                Right second <- runStoreIO store $ acquireHistoryRetentionLease (request "second" "protect" 60)
                blocked <- runStoreIO store $ hardDeleteStream stream
                case blocked of
                    Left (HistoryRetentionActive actual HistoryRetentionConflict{activeLeaseCount}) -> do
                        actual `shouldBe` stream
                        activeLeaseCount `shouldBe` 2
                    other -> expectationFailure ("expected typed retention conflict, got " <> show other)
                countEvents store `shouldReturn` countBefore
                Right (Just _) <- runStoreIO store $ getStream stream
                Right HistoryRetentionReleased{} <- runStoreIO store $ releaseHistoryRetentionLease (leaseHandle first)
                stillBlocked <- runStoreIO store $ hardDeleteStream stream
                stillBlocked `shouldSatisfy` \case Left HistoryRetentionActive{} -> True; _ -> False
                Right HistoryRetentionReleased{} <- runStoreIO store $ releaseHistoryRetentionLease (leaseHandle second)
                deleted <- runStoreIO store (hardDeleteStream stream)
                deleted `shouldSatisfy` \case Right (Just _) -> True; _ -> False
        events <- readIORef observed
        let conflictCounts =
                [ activeLeaseCount
                | KirokuEventHardDeleteHistoryRetentionConflict _ HistoryRetentionConflict{activeLeaseCount} <- reverse events
                ]
        conflictCounts `shouldBe` [2, 1]

    describe "history retention raw SQL" $ do
        it "serializes lease-first acquisition ahead of raw deletion" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "raw-race-lease-first") NoStream [makeEvent "Raw" (Aeson.object [])]
                countBefore <- countStreamEvents store
                acquisition <- Async.async $ runStoreIO store $ runTransaction $ do
                    lease <- acquireHistoryRetentionLeaseTx (request "raw-race" "lease-first" 60)
                    _ <- Tx.statement () holdCoordinatorStmt
                    pure lease
                waitForCoordinatorPhase store 100
                deletion <- Async.async (runRawDestruction store rawDeleteStreamEventsStmt)
                threadDelay 50_000
                Async.poll deletion >>= \case
                    Nothing -> pure ()
                    Just _ -> expectationFailure "raw deletion completed while lease acquisition held the coordinator"
                acquired <- waitWithin "lease-first acquisition" acquisition
                acquired `shouldSatisfy` \case Right HistoryRetentionLease{} -> True; _ -> False
                rejected <- waitWithin "lease-first raw deletion" deletion
                rejected `shouldSatisfy` hasSqlState "KR001"
                countStreamEvents store `shouldReturn` countBefore

        it "serializes delete-first maintenance ahead of post-delete acquisition" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "raw-race-delete-first") NoStream [makeEvent "Raw" (Aeson.object [])]
                deletion <- Async.async (runRawDestructionHeld store rawDeleteStreamEventsStmt)
                waitForCoordinatorPhase store 100
                acquisition <- Async.async $ runStoreIO store $ acquireHistoryRetentionLease (request "raw-race" "delete-first" 60)
                threadDelay 50_000
                Async.poll acquisition >>= \case
                    Nothing -> pure ()
                    Just _ -> expectationFailure "lease acquisition completed while raw deletion held the coordinator"
                waitWithin "delete-first raw deletion" deletion `shouldReturn` Right ()
                acquired <- waitWithin "delete-first acquisition" acquisition
                acquired `shouldSatisfy` \case Right HistoryRetentionLease{} -> True; _ -> False
                countStreamEvents store `shouldReturn` 0

        it "rejects GUC-enabled DELETE with KR001 and permits it after release" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "raw-delete") NoStream (replicate 2 (makeEvent "Raw" (Aeson.object [])))
                countBefore <- countStreamEvents store
                Right lease <- runStoreIO store $ acquireHistoryRetentionLease (request "raw" "delete" 60)
                rejected <- runRawDestruction store rawDeleteStreamEventsStmt
                rejected `shouldSatisfy` hasSqlState "KR001"
                countStreamEvents store `shouldReturn` countBefore
                Right HistoryRetentionReleased{} <- runStoreIO store $ releaseHistoryRetentionLease (leaseHandle lease)
                runRawDestruction store rawDeleteStreamEventsStmt `shouldReturn` Right ()
                countStreamEvents store `shouldReturn` 0

        it "rejects GUC-enabled TRUNCATE with KR001 and permits it after release" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "raw-truncate") NoStream [makeEvent "Raw" (Aeson.object [])]
                countBefore <- countEvents store
                Right lease <- runStoreIO store $ acquireHistoryRetentionLease (request "raw" "truncate" 60)
                rejected <- runRawDestruction store rawTruncateDataStmt
                rejected `shouldSatisfy` hasSqlState "KR001"
                countEvents store `shouldReturn` countBefore
                Right HistoryRetentionReleased{} <- runStoreIO store $ releaseHistoryRetentionLease (leaseHandle lease)
                runRawDestruction store rawTruncateDataStmt `shouldReturn` Right ()
                countEvents store `shouldReturn` 0

        it "permits GUC-enabled maintenance after passive expiry" $
            withTestStore $ \store -> do
                Right _ <- runStoreIO store $ appendToStream (StreamName "raw-expiry") NoStream [makeEvent "Raw" (Aeson.object [])]
                Right _ <- runStoreIO store $ acquireHistoryRetentionLease (request "raw" "expiry" 1)
                threadDelay 1_100_000
                runRawDestruction store rawDeleteStreamEventsStmt `shouldReturn` Right ()

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

runRawDestruction :: KirokuStore -> Statement () () -> IO (Either Pool.UsageError ())
runRawDestruction store statement =
    Pool.use (store ^. #pool) $
        TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
            Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
            Tx.statement () statement

runRawDestructionHeld :: KirokuStore -> Statement () () -> IO (Either Pool.UsageError ())
runRawDestructionHeld store statement =
    Pool.use (store ^. #pool) $
        TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write $ do
            Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'"
            Tx.statement () statement
            _ <- Tx.statement () holdCoordinatorStmt
            pure ()

waitForCoordinatorPhase :: KirokuStore -> Int -> IO ()
waitForCoordinatorPhase _ 0 = expectationFailure "coordinator holder never reached its held phase"
waitForCoordinatorPhase store attempts = do
    result <- Pool.use (store ^. #pool) (Session.statement () coordinatorActiveStmt)
    case result of
        Right True -> pure ()
        Right False -> threadDelay 10_000 >> waitForCoordinatorPhase store (attempts - 1)
        Left err -> expectationFailure ("could not observe coordinator phase: " <> show err)

waitWithin :: String -> Async.Async value -> IO value
waitWithin label action = do
    result <- Async.race (threadDelay 2_000_000) (Async.wait action)
    case result of
        Left () -> do
            Async.cancel action
            expectationFailure (label <> " timed out")
            error "unreachable"
        Right value -> pure value

hasSqlState :: Text.Text -> Either Pool.UsageError value -> Bool
hasSqlState expected = \case
    Left
        ( Pool.SessionUsageError
                ( Errors.StatementSessionError
                        _
                        _
                        _
                        _
                        _
                        (Errors.ServerStatementError (Errors.ServerError actual _ _ _ _))
                    )
            ) -> actual == expected
    _ -> False

countStreamEvents :: KirokuStore -> IO Int64
countStreamEvents store = do
    result <- Pool.use (store ^. #pool) (TxSessions.transaction TxSessions.ReadCommitted TxSessions.Read (Tx.statement () countStreamEventsStmt))
    case result of
        Left err -> expectationFailure ("could not count stream junctions: " <> show err) >> error "unreachable"
        Right value -> pure value

countStreamEventsStmt :: Statement () Int64
countStreamEventsStmt =
    unpreparable
        "SELECT count(*) FROM stream_events"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))

rawDeleteStreamEventsStmt :: Statement () ()
rawDeleteStreamEventsStmt =
    unpreparable
        "DELETE FROM stream_events"
        E.noParams
        D.noResult

rawTruncateDataStmt :: Statement () ()
rawTruncateDataStmt =
    unpreparable
        "TRUNCATE dead_letters, stream_events, events"
        E.noParams
        D.noResult

holdCoordinatorStmt :: Statement () Bool
holdCoordinatorStmt =
    preparable
        "SELECT pg_sleep(0.4) IS NULL /* history-retention-coordinator-race */"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

coordinatorActiveStmt :: Statement () Bool
coordinatorActiveStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE state = 'active'
            AND query = 'SELECT pg_sleep(0.4) IS NULL /* history-retention-coordinator-race */'
        )
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))
