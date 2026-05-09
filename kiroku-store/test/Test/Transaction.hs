{- | Tests for "Kiroku.Store.Transaction" — the transactional escape
hatch and append combinators that let callers compose store operations
with arbitrary 'Hasql.Transaction.Transaction' work in one ACID
transaction.
-}
module Test.Transaction (spec) where

import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Kiroku.Store
import Test.Helpers (withTestStore)
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

{- | Trivial @SELECT 1@ used to verify 'runTransaction' wiring without
depending on any schema state.
-}
selectOneStmt :: Statement () Int
selectOneStmt =
    preparable
        "SELECT 1::int4"
        E.noParams
        (D.singleRow (fromIntegral <$> D.column (D.nonNullable D.int4)))
