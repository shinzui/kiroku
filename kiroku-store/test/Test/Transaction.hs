{- | Tests for "Kiroku.Store.Transaction" — the transactional escape
hatch and append combinators that let callers compose store operations
with arbitrary 'Hasql.Transaction.Transaction' work in one ACID
transaction.
-}
module Test.Transaction (spec) where

import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text (Text)
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
        ( (fst >$< E.param (E.nonNullable E.int8))
            <> (snd >$< E.param (E.nonNullable E.text))
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
