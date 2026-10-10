module Test.BrowseQueryPlans (spec) where

import Control.Exception (bracket_)
import Control.Lens ((^.))
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Hasql.Statement qualified as Statement
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Postgres (migrateTestDatabase, withMigratedTestDatabase)
import Test.Helpers (withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "browse reads prepared query work" $ do
    around withTestStore $ it "bounds production generic and custom index seeks on a 40000-stream catalog" preparedChecks
    it "uses the same bounded production statements in an English ICU database" $ withIcuStore $ \store -> do
        preparedChecks store
        Right _ <- runStoreIO store $ appendToStream (StreamName "orders-éclair") NoStream [EventData Nothing (EventType "Created") (Aeson.object []) Nothing Nothing Nothing]
        Right _ <- runStoreIO store $ appendToStream (StreamName "orders-éclair") NoStream [EventData Nothing (EventType "Created") (Aeson.object []) Nothing Nothing Nothing]
        let page = either (error . show) (\size -> size) (mkBrowsePageSize 11)
        Right rows <- runStoreIO store $ listStreams (Just (CategoryName "orders")) (Just "orders-é") Nothing page
        map (\row -> row ^. #name) (V.toList rows) `shouldBe` [StreamName "orders-éclair"]

preparedChecks :: KirokuStore -> IO ()
preparedChecks store = do
    seeded <-
        Pool.use (store ^. #pool) $
            Session.script
                "INSERT INTO streams(stream_name) SELECT c || '-' || lpad(n::text,10,'0') FROM unnest(ARRAY['orders','noise']) c CROSS JOIN generate_series(1,20000) n; ANALYZE streams;"
    seeded `shouldBe` Right ()
    forM_ ["force_generic_plan", "force_custom_plan"] $ \mode -> do
        forM_ [(SQL.InclusiveLower, "'orders-', 'orders.', 11"), (SQL.ExclusiveLower, "'orders-0000019990', 'orders.', 11"), (SQL.InclusiveLower, "'absent', 'absenu', 11"), (SQL.InclusiveLower, "'', NULL, 11")] $ \(bound, args) -> do
            plan <- explainPrepared store mode "text,text,int4" args (SQL.listStreamsRangeStmt bound)
            expectBounded plan 11
        plan <- explainPrepared store mode "text,text,text,text,int4" "'orders', NULL, 'orders-', 'orders.', 11" (SQL.listStreamsPairStmt SQL.ExactName SQL.InclusiveLower)
        expectBounded plan 22
        forM_ [(False, "NULL, 11"), (True, "'orders', 11")] $ \(hasCursor, args) -> do
            categoryPlan <- explainPrepared store mode "text,int4" args (SQL.listCategoriesStmt hasCursor)
            indexNames categoryPlan `shouldContain` ["ix_streams_category"]
            -- Each loose-index seek returns at most one distinct category.
            scannedRows categoryPlan `shouldSatisfy` (<= 12)

explainPrepared :: KirokuStore -> Text -> Text -> Text -> Statement p r -> IO Value
explainPrepared store mode types args statement = do
    result <- Pool.use (store ^. #pool) $ do
        Session.script ("SET plan_cache_mode=" <> mode <> "; PREPARE mp13_browse(" <> types <> ") AS " <> Statement.toSql statement)
        bytes <- Session.statement () (unpreparable ("EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) EXECUTE mp13_browse(" <> args <> ")") E.noParams (D.singleRow (D.column (D.nonNullable (D.jsonBytes Right)))))
        Session.script "DEALLOCATE mp13_browse; RESET plan_cache_mode"
        pure bytes
    case result of
        Left err -> expectationFailure (show err) >> fail "EXPLAIN failed"
        Right bytes -> decodePlan bytes
  where
    decodePlan :: ByteString -> IO Value
    decodePlan bytes = either fail pure (Aeson.eitherDecodeStrict' bytes)

expectBounded :: Value -> Double -> Expectation
expectBounded plan budget = do
    indexNames plan `shouldContain` ["ix_streams_browse_name"]
    scannedRows plan `shouldSatisfy` (<= budget)
    case plan of
        Array entries
            | Object entry <- V.head entries
            , Just (Object top) <- KM.lookup "Plan" entry ->
                number "Shared Hit Blocks" top + number "Shared Read Blocks" top `shouldSatisfy` (<= 64)
        _ -> expectationFailure (show plan)

-- Count rows examined at relation scans (including filters), not only results.
scannedRows :: Value -> Double
scannedRows (Object fields) = current + sum (map scannedRows (KM.elems fields))
  where
    current = case KM.lookup "Relation Name" fields of
        Just (String "streams") -> (number "Actual Rows" fields + number "Rows Removed by Filter" fields + number "Rows Removed by Index Recheck" fields) * number "Actual Loops" fields
        _ -> 0
scannedRows (Array values) = sum (map scannedRows (foldr (:) [] values))
scannedRows _ = 0
indexNames :: Value -> [Text]
indexNames (Object fields) = [name | Just (String name) <- [KM.lookup "Index Name" fields]] <> concatMap indexNames (KM.elems fields)
indexNames (Array values) = concatMap indexNames (foldr (:) [] values)
indexNames _ = []
number :: Aeson.Key -> Aeson.Object -> Double
number key fields = case KM.lookup key fields of Just (Number n) -> realToFrac n; _ -> 0

-- A separately migrated database verifies production SQL under locale ordering,
-- rather than altering existing columns or using a different hand-written query.
withIcuStore :: (KirokuStore -> IO ()) -> IO ()
withIcuStore action = withMigratedTestDatabase $ \connection ->
    withStore (defaultConnectionSettings connection) $ \admin -> do
        let sql command = Pool.use (admin ^. #pool) (Session.script command) >>= either (fail . show) pure
            newConnection = T.unwords (filter (not . T.isPrefixOf "dbname=") (T.words connection) <> ["dbname=mp13_browse_icu"])
        bracket_
            (sql "CREATE DATABASE mp13_browse_icu TEMPLATE template0 LOCALE_PROVIDER icu ICU_LOCALE 'en'")
            (sql "DROP DATABASE mp13_browse_icu")
            $ do
                migrateTestDatabase newConnection
                withStore (defaultConnectionSettings newConnection) action
