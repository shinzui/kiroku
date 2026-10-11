module Test.StreamHeadIsolation (spec) where

import Control.Monad (forM_)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Hasql.Statement qualified as Statement
import Kiroku.Store.SQL qualified as SQL
import Paths_kiroku_store (getDataFileName)
import Test.Hspec

spec :: Spec
spec = describe "stream head legacy isolation" $ do
    forM_ statements $ \(name, actual) ->
        it ("preserves " <> name <> " byte for byte") $ do
            path <- getDataFileName ("test/fixtures/stream-head-isolation/" <> name <> ".sql")
            expected <- T.readFile path
            T.strip actual `shouldBe` expected
    it "keeps the six metadata and eleven event result columns" $ do
        columnCount (Statement.toSql SQL.getStreamStmt) `shouldBe` 6
        columnCount (Statement.toSql SQL.readAllForwardStmt) `shouldBe` 11
  where
    columnCount = length . T.splitOn "," . fst . T.breakOn "FROM" . snd . T.breakOn "SELECT"
    statements =
        [ ("getStreamStmt", Statement.toSql SQL.getStreamStmt)
        , ("readStreamForwardStmt", Statement.toSql SQL.readStreamForwardStmt)
        , ("readStreamBackwardStmt", Statement.toSql SQL.readStreamBackwardStmt)
        , ("readAllForwardStmt", Statement.toSql SQL.readAllForwardStmt)
        , ("readAllBackwardStmt", Statement.toSql SQL.readAllBackwardStmt)
        , ("readCategoryForwardStmt", Statement.toSql SQL.readCategoryForwardStmt)
        , ("readCategoryForwardConsumerGroupStmt", Statement.toSql SQL.readCategoryForwardConsumerGroupStmt)
        , ("appendExpectedVersion", Statement.toSql SQL.appendExpectedVersion)
        , ("appendStreamExists", Statement.toSql SQL.appendStreamExists)
        , ("appendNoStream", Statement.toSql SQL.appendNoStream)
        , ("appendAnyVersion", Statement.toSql SQL.appendAnyVersion)
        , ("linkToStreamStmt", Statement.toSql SQL.linkToStreamStmt)
        ]
