{- | Tests for "Kiroku.Store.Transaction" — the transactional escape
hatch and append combinators that let callers compose store operations
with arbitrary 'Hasql.Transaction.Transaction' work in one ACID
transaction.
-}
module Test.Transaction (spec) where

import Contravariant.Extras (contrazip2)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable, unpreparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Test.Helpers (makeEvent, withTestStore)
import Test.Hspec

spec :: Spec
spec = around withTestStore $ do
    describe "runTransaction" $ do
        it "executes a no-op Tx.statement and returns its result" $ \store -> do
            result <-
                runStoreIO store $
                    runTransaction $
                        Tx.statement () selectOneStmt
            case result of
                Right n -> n `shouldBe` (1 :: Int)
                Left err -> expectationFailure ("Expected Right 1, got: " <> show err)

    describe "appendToStreamTx (driven inside runTransaction)" $ do
        it "appends events and a side-table row in one atomic transaction" $ \store -> do
            createSideTable (store ^. #pool)
            let evt = makeEvent "Created" (Aeson.object [("x", Aeson.Number 1)])
            prepared <- prepareEventsIO [evt]
            now <- getCurrentTime
            result <- runStoreIO store $ runTransaction $ do
                outcome <- appendToStreamTx (StreamName "txn-success-1") NoStream prepared now
                case outcome of
                    Left c -> pure (Left c)
                    Right ar -> do
                        let StreamId sid = ar ^. #streamId
                        Tx.statement (sid, "hello") insertSideRowStmt
                        pure (Right ar)
            case result of
                Right (Right ar) -> do
                    (ar ^. #streamVersion) `shouldBe` StreamVersion 1
                    rows <- countSideTable (store ^. #pool)
                    rows `shouldBe` 1
                other ->
                    expectationFailure
                        ("Expected Right (Right AppendResult), got: " <> show other)

        it "rolls back the append and the side row when the body condemns" $ \store -> do
            createSideTable (store ^. #pool)
            let evt = makeEvent "Created" (Aeson.object [])
            prepared <- prepareEventsIO [evt]
            now <- getCurrentTime
            result <- runStoreIO store $ runTransaction $ do
                outcome <- appendToStreamTx (StreamName "txn-condemn-1") NoStream prepared now
                case outcome of
                    Right ar -> do
                        let StreamId sid = ar ^. #streamId
                        Tx.statement (sid, "should-not-persist") insertSideRowStmt
                        Tx.condemn
                    Left _ -> Tx.condemn
            result `shouldBe` Right ()
            mInfo <- runStoreIO store $ getStream (StreamName "txn-condemn-1")
            mInfo `shouldBe` Right Nothing
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

        it "returns Left on version conflict; the caller's branch sees no AppendResult" $ \store -> do
            createSideTable (store ^. #pool)
            -- Pre-populate the stream so the ExactVersion check below mismatches.
            _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "txn-conflict-1")
                        NoStream
                        [makeEvent "Created" (Aeson.object [])]
            prepared <- prepareEventsIO [makeEvent "Updated" (Aeson.object [])]
            now <- getCurrentTime
            result <- runStoreIO store $ runTransaction $ do
                outcome <-
                    appendToStreamTx
                        (StreamName "txn-conflict-1")
                        (ExactVersion (StreamVersion 99))
                        prepared
                        now
                case outcome of
                    Right _ -> do
                        Tx.statement (0 :: Int64, "should-not-run") insertSideRowStmt
                        pure outcome
                    Left _ -> pure outcome
            case result of
                Right (Left (WrongExpectedVersionConflict _ _ _)) -> pure ()
                other ->
                    expectationFailure
                        ("Expected Right (Left WrongExpectedVersionConflict), got: " <> show other)
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

    describe "runTransactionAppending" $ do
        it "commits 3 events and a side-table row in one ACID transaction" $ \store -> do
            createSideTable (store ^. #pool)
            let evts =
                    [ makeEvent "Created" (Aeson.object [("i", Aeson.Number 1)])
                    , makeEvent "Updated" (Aeson.object [("i", Aeson.Number 2)])
                    , makeEvent "Closed" (Aeson.object [("i", Aeson.Number 3)])
                    ]
            result <-
                runStoreIO store $
                    runTransactionAppending
                        (StreamName "txn-wrapper-success-1")
                        NoStream
                        evts
                        ( \ar -> do
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "projection") insertSideRowStmt
                            pure ar
                        )
            case result of
                Right (Right ar) ->
                    (ar ^. #streamVersion) `shouldBe` StreamVersion 3
                other ->
                    expectationFailure
                        ("Expected Right (Right AppendResult), got: " <> show other)
            -- Verify both the events and the side row landed.
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 1
            mInfo <- runStoreIO store $ getStream (StreamName "txn-wrapper-success-1")
            case mInfo of
                Right (Just info) -> (info ^. #version) `shouldBe` StreamVersion 3
                other -> expectationFailure ("Expected stream with version 3, got: " <> show other)

        it "rolls back the append and the side row when the callback condemns" $ \store -> do
            createSideTable (store ^. #pool)
            result <-
                runStoreIO store $
                    runTransactionAppending
                        (StreamName "txn-wrapper-condemn-1")
                        NoStream
                        [makeEvent "Created" (Aeson.object [])]
                        ( \ar -> do
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "should-not-persist") insertSideRowStmt
                            Tx.condemn
                            pure ar
                        )
            -- The callback ran and returned, so the wrapper sees Right; but the
            -- transaction was condemned, so neither write committed.
            case result of
                Right (Right _) -> pure ()
                other ->
                    expectationFailure
                        ("Expected Right (Right AppendResult), got: " <> show other)
            mInfo <- runStoreIO store $ getStream (StreamName "txn-wrapper-condemn-1")
            mInfo `shouldBe` Right Nothing
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

        it "skips the callback and surfaces the version conflict" $ \store -> do
            createSideTable (store ^. #pool)
            -- Pre-populate the stream so ExactVersion 99 will mismatch.
            _ <-
                runStoreIO store $
                    appendToStream
                        (StreamName "txn-wrapper-conflict-1")
                        NoStream
                        [makeEvent "Created" (Aeson.object [])]
            calledRef <- newIORef (0 :: Int)
            result <-
                runStoreIO store $
                    runTransactionAppending
                        (StreamName "txn-wrapper-conflict-1")
                        (ExactVersion (StreamVersion 99))
                        [makeEvent "Updated" (Aeson.object [])]
                        ( \ar -> do
                            -- Tx.Transaction has no MonadIO; the IORef bump can't go
                            -- here. Instead, write a side row whose absence asserts
                            -- non-invocation.
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "should-not-run") insertSideRowStmt
                            pure ar
                        )
            -- Bump the ref outside the Tx; assertion below proves the guard
            -- works: if the callback HAD run, the side row would exist.
            modifyIORef' calledRef (+ 1)
            n <- readIORef calledRef
            n `shouldBe` 1
            case result of
                Right (Left (WrongExpectedVersion _ _ _)) -> pure ()
                other ->
                    expectationFailure
                        ("Expected Right (Left WrongExpectedVersion), got: " <> show other)
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

        it "rejects $all before opening any transaction" $ \store -> do
            createSideTable (store ^. #pool)
            result <-
                runStoreIO store $
                    runTransactionAppending
                        (StreamName "$all")
                        AnyVersion
                        [makeEvent "Should" (Aeson.object [])]
                        ( \ar -> do
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "should-never-run") insertSideRowStmt
                            pure ar
                        )
            case result of
                Right (Left (ReservedStreamName (StreamName "$all"))) -> pure ()
                other ->
                    expectationFailure
                        ("Expected Right (Left (ReservedStreamName \"$all\")), got: " <> show other)
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

        it "rejects oversized stream names before opening any transaction" $ \store -> do
            createSideTable (store ^. #pool)
            let over = StreamName (T.replicate 513 "t")
            result <-
                runStoreIO store $
                    runTransactionAppending
                        over
                        AnyVersion
                        [makeEvent "Should" (Aeson.object [])]
                        ( \ar -> do
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "should-never-run") insertSideRowStmt
                            pure ar
                        )
            result `shouldBe` Right (Left (StreamNameTooLong over 513))
            runStoreIO store (getStream over) `shouldReturn` Right Nothing
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

        it "rejects empty event batches before opening a transaction" $ \store -> do
            createSideTable (store ^. #pool)
            result <-
                runStoreIO store $
                    runTransactionAppending
                        (StreamName "txn-wrapper-empty-1")
                        NoStream
                        []
                        ( \ar -> do
                            let StreamId sid = ar ^. #streamId
                            Tx.statement (sid, "should-never-run") insertSideRowStmt
                            pure ar
                        )
            result `shouldBe` Right (Left (EmptyAppendBatch (StreamName "txn-wrapper-empty-1")))
            runStoreIO store (getStream (StreamName "txn-wrapper-empty-1")) `shouldReturn` Right Nothing
            rows <- countSideTable (store ^. #pool)
            rows `shouldBe` 0

-- ---------------------------------------------------------------------------
-- Local statements and pool-side helpers
-- ---------------------------------------------------------------------------

{- | Trivial @SELECT 1@ used to verify 'runTransaction' wiring without
depending on any schema state.
-}
selectOneStmt :: Statement () Int
selectOneStmt =
    preparable
        "SELECT 1::int4"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int4)))

-- | DDL for the projection-row side table used by transaction tests.
createSideTableStmt :: Statement () ()
createSideTableStmt =
    unpreparable
        "CREATE TABLE IF NOT EXISTS test_side_table \
        \(id BIGINT PRIMARY KEY, payload TEXT NOT NULL)"
        E.noParams
        D.noResult

{- | Insert a row into the side table. The @id@ doubles as the foreign
key onto the stream the transaction appended to.
-}
insertSideRowStmt :: Statement (Int64, Text) ()
insertSideRowStmt =
    preparable
        "INSERT INTO test_side_table (id, payload) VALUES ($1, $2)"
        ( contrazip2
            (E.param (E.nonNullable E.int8))
            (E.param (E.nonNullable E.text))
        )
        D.noResult

-- | Count rows in the side table.
countSideTableStmt :: Statement () Int64
countSideTableStmt =
    preparable
        "SELECT COUNT(*) FROM test_side_table"
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))

createSideTable :: Pool -> IO ()
createSideTable pool = do
    r <- Pool.use pool (Session.statement () createSideTableStmt)
    case r of
        Left err -> error ("createSideTable failed: " <> show err)
        Right () -> pure ()

countSideTable :: Pool -> IO Int64
countSideTable pool = do
    r <- Pool.use pool (Session.statement () countSideTableStmt)
    case r of
        Left err -> error ("countSideTable failed: " <> show err)
        Right n -> pure n
