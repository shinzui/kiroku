{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE NumericUnderscores #-}

module Test.StreamHistoryGuard (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Lens ((^.))
import Control.Monad (forM_, when)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "stream history guard" $ do
    it "returns exact metadata and pages with production cursor semantics" $
        withTestStore $ \store -> do
            let stream = StreamName "guard-metadata"
            Right _ <- runStoreIO store $ appendToStream stream NoStream (events 3)
            Right _ <- runStoreIO store $ setStreamTruncateBefore stream (StreamVersion 2)
            result <- runTx store $ do
                locked <- lockStreamHistoryForReplayTx stream
                page <- readStreamForwardTx stream (StreamVersion 0) 10
                pure (locked, page)
            case result of
                (Right info, page) -> do
                    info ^. #version `shouldBe` StreamVersion 3
                    info ^. #truncateBefore `shouldBe` StreamVersion 2
                    info ^. #deletedAt `shouldBe` Nothing
                    fmap (^. #streamVersion) (Vector.toList page)
                        `shouldBe` [StreamVersion 2, StreamVersion 3]
                (Left unavailable, _) -> expectationFailure ("guard unexpectedly unavailable: " <> show unavailable)

    it "returns typed unavailable results for missing and reserved streams" $
        withTestStore $ \store -> do
            missing <- runTx store (lockStreamHistoryForReplayTx (StreamName "guard-missing"))
            missing `shouldBe` Left (StreamHistoryNotFound (StreamName "guard-missing"))
            reserved <- runTx store (lockStreamHistoryForReplayTx (StreamName "$all"))
            reserved `shouldBe` Left (StreamHistoryReserved (StreamName "$all"))

    it "returns soft-deleted metadata and blocks undelete until guard completion" $
        withTestStore $ \store -> do
            let stream = StreamName "guard-undelete"
            Right _ <- runStoreIO store $ appendToStream stream NoStream (events 1)
            Right _ <- runStoreIO store $ softDeleteStream stream
            assertBlockedByGuard store stream $ do
                info <- runTx store (lockStreamHistoryForReplayTx stream)
                info `shouldSatisfy` \case Right StreamInfo{deletedAt = Just _} -> True; _ -> False
                runStoreIO store (undeleteStream stream)

    it "blocks append until guard completion" $
        withTestStore $ \store -> do
            let stream = StreamName "guard-append"
            Right _ <- runStoreIO store $ appendToStream stream NoStream (events 1)
            assertBlockedByGuard store stream $
                runStoreIO store (appendToStream stream AnyVersion (events 1))

    it "releases the guard on rollback and lets the blocked append complete" $
        withTestStore $ \store -> do
            let stream = StreamName "guard-rollback"
            Right _ <- runStoreIO store $ appendToStream stream NoStream (events 1)
            assertBlockedByGuardEnding True store stream $
                runStoreIO store (appendToStream stream AnyVersion (events 1))

    it "blocks link into the guarded stream until guard completion" $
        withTestStore $ \store -> do
            let source = StreamName "guard-link-source"
                target = StreamName "guard-link-target"
            Right _ <- runStoreIO store $ appendToStream source NoStream (events 1)
            Right _ <- runStoreIO store $ appendToStream target NoStream (events 1)
            Right sourceRows <- runStoreIO store $ readStreamForward source (StreamVersion 0) 10
            let eventId = Vector.head sourceRows ^. #eventId
            assertBlockedByGuard store target $
                runStoreIO store (linkToStream target [eventId])

    it "blocks soft delete and logical truncate until guard completion" $
        withTestStore $ \store -> do
            let soft = StreamName "guard-soft-delete"
                truncated = StreamName "guard-truncate"
            Right _ <- runStoreIO store $ appendToStream soft NoStream (events 1)
            Right _ <- runStoreIO store $ appendToStream truncated NoStream (events 2)
            assertBlockedByGuard store soft $
                runStoreIO store (softDeleteStream soft)
            assertBlockedByGuard store truncated $
                runStoreIO store (setStreamTruncateBefore truncated (StreamVersion 2))

    it "blocks hard delete of the guarded origin until guard completion" $
        withTestStore $ \store -> do
            let stream = StreamName "guard-hard-delete"
            Right _ <- runStoreIO store $ appendToStream stream NoStream (events 1)
            assertBlockedByGuard store stream $
                runStoreIO store (hardDeleteStream stream)

    it "blocks hard delete of another origin linked into the guarded stream" $
        withTestStore $ \store -> do
            let origin = StreamName "guard-linked-origin"
                guarded = StreamName "guard-linked-target"
            Right _ <- runStoreIO store $ appendToStream origin NoStream (events 1)
            Right _ <- runStoreIO store $ appendToStream guarded NoStream (events 1)
            Right sourceRows <- runStoreIO store $ readStreamForward origin (StreamVersion 0) 10
            Right _ <- runStoreIO store $ linkToStream guarded [Vector.head sourceRows ^. #eventId]
            assertBlockedByGuard store guarded $
                runStoreIO store (hardDeleteStream origin)

    it "keeps opposing hard deletes and multi-stream appends deadlock-free" $
        withTestStore $ \store ->
            forM_ [1 .. 5 :: Int] $ \index -> do
                let suffix = Text.pack (show index)
                    first = StreamName ("guard-race-a-" <> suffix)
                    second = StreamName ("guard-race-b-" <> suffix)
                Right _ <- runStoreIO store $ appendToStream first NoStream (events 1)
                Right _ <- runStoreIO store $ appendToStream second NoStream (events 1)
                operations <-
                    Async.async $
                        Async.concurrently
                            (runStoreIO store $ hardDeleteStream first)
                            ( runStoreIO store $
                                appendMultiStream
                                    [ (first, AnyVersion, events 1)
                                    , (second, AnyVersion, events 1)
                                    ]
                            )
                _ <- waitWithin "hard-delete/multi-append race" operations
                pure ()

assertBlockedByGuard :: KirokuStore -> StreamName -> IO result -> IO ()
assertBlockedByGuard = assertBlockedByGuardEnding False

assertBlockedByGuardEnding :: Bool -> KirokuStore -> StreamName -> IO result -> IO ()
assertBlockedByGuardEnding rollBack store stream mutation = do
    guard <- Async.async $ runStoreIO store $ runTransaction $ do
        locked <- lockStreamHistoryForReplayTx stream
        _ <- Tx.statement () holdGuardStmt
        when rollBack Tx.condemn
        pure locked
    waitForGuardPhase store 100
    waiter <- Async.async mutation
    threadDelay 50_000
    Async.poll waiter >>= \case
        Nothing -> pure ()
        Just _ -> expectationFailure "mutation completed while the stream-history guard was held"
    guardResult <- waitWithin "guard transaction" guard
    guardResult `shouldSatisfy` \case Right (Right _) -> True; _ -> False
    _ <- waitWithin "blocked mutation" waiter
    pure ()

waitForGuardPhase :: KirokuStore -> Int -> IO ()
waitForGuardPhase _ 0 = expectationFailure "guard never reached its held phase"
waitForGuardPhase store attempts = do
    result <- Pool.use (store ^. #pool) (Session.statement () guardActiveStmt)
    case result of
        Right True -> pure ()
        Right False -> threadDelay 10_000 >> waitForGuardPhase store (attempts - 1)
        Left err -> expectationFailure ("could not observe guard phase: " <> show err)

waitWithin :: String -> Async.Async value -> IO value
waitWithin label action = do
    result <- Async.race (threadDelay 2_000_000) (Async.wait action)
    case result of
        Left () -> do
            Async.cancel action
            expectationFailure (label <> " timed out")
            error "unreachable"
        Right value -> pure value

runTx :: KirokuStore -> Tx.Transaction value -> IO value
runTx store transaction = do
    result <- runStoreIO store (runTransaction transaction)
    case result of
        Left err -> expectationFailure ("guard transaction failed: " <> show err) >> error "unreachable"
        Right value -> pure value

events :: Int -> [EventData]
events count =
    [makeEvent "Guarded" (Aeson.object [("n", Aeson.toJSON n)]) | n <- [1 .. count]]

holdGuardStmt :: Statement () Bool
holdGuardStmt =
    preparable
        "SELECT pg_sleep(0.4) IS NULL"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))

guardActiveStmt :: Statement () Bool
guardActiveStmt =
    preparable
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_stat_activity
          WHERE state = 'active'
            AND query = 'SELECT pg_sleep(0.4) IS NULL'
        )
        """
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.bool)))
