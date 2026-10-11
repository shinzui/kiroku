{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE OverloadedLabels #-}

module Test.DeadLetterQueryPlans (spec) where

import Control.Lens ((^.))
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Hasql.Statement qualified as Statement
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (withTestStore)
import Test.Hspec

spec :: Spec
spec = describe "dead-letter production query plans" $ around withTestStore $ it "bounds historical-member enumeration and first/later pages in generic/custom plans as history grows" $ \store -> do
    execute store "INSERT INTO events(event_id,event_type,data,created_at) VALUES ('00000000-0000-0000-0000-000000000001','E','{}',now())"
    forM_ ["1000", "20000"] $ \history -> do
        execute store ("INSERT INTO dead_letters(subscription_name,consumer_group_member,global_position,event_id,reason,reason_summary,attempt_count) SELECT 'plans',m,n,'00000000-0000-0000-0000-000000000001','{}','fixture',1 FROM unnest(ARRAY[0,1,9]) m CROSS JOIN generate_series(1," <> history <> ") n ON CONFLICT DO NOTHING; ANALYZE dead_letters")
        forM_ ["force_generic_plan", "force_custom_plan"] $ \mode -> do
            memberFirst <- explain store mode "text,int4,int4" "'plans',9,6" SQL.listSubscriptionMemberDeadLettersFromStartStmt
            memberLater <- explain store mode "text,int4,int8,int8,int4" "'plans',9,500,9223372036854775807,6" SQL.listSubscriptionMemberDeadLettersStmt
            allFirst <- explain store mode "text,int4" "'plans',6" SQL.listSubscriptionDeadLettersFromStartStmt
            allLater <- explain store mode "text,int8,int8,int4" "'plans',500,9223372036854775807,6" SQL.listSubscriptionDeadLettersStmt
            forM_ [memberFirst, memberLater] $ \plan -> do
                expect ("index" :: Text) plan ("ix_dead_letters_subscription_position" `elem` texts "Index Name" plan)
                expect "member page work" plan (scanned plan <= 6)
                expect "no member sort" plan ("Sort" `notElem` texts "Node Type" plan)
            forM_ [allFirst, allLater] $ \plan -> do
                -- Three loose member probes plus three bounded lateral scans.
                expect "bounded member enumeration/page" plan (scanned plan <= 24)
                expect "bounded merge input" plan (sum (sortInputs plan) <= 18)
                -- The existing natural-key index has the same (name, member)
                -- prefix and can serve the loose member probes too.
                expect "existing ordered indexes only" plan (all (`elem` ["ix_dead_letters_subscription_position", "dead_letters_subscription_name_consumer_group_member_global_key"]) (texts "Index Name" plan))
                expect "ordered historical member advance" plan (any ("consumer_group_member >" `contains`) (texts "Index Cond" plan))
                expect "recency index for lateral pages" plan ("ix_dead_letters_subscription_position" `elem` texts "Index Name" plan)
                expect "no historical sequential scan" plan ("Seq Scan" `notElem` texts "Node Type" plan)
            forM_ [memberLater, allLater] $ \plan ->
                expect "tuple cursor in index condition" plan (any (\condition -> "ROW(global_position, dead_letter_id)" `contains` condition) (texts "Index Cond" plan))
            forM_ [memberFirst, memberLater, allFirst, allLater] $ \plan ->
                expect "bounded shared buffers" plan (buffers plan <= 128)
            -- Preserve the actual production EXPLAIN evidence in the test log.
            mapM_ (LBS.putStrLn . Aeson.encode) [memberFirst, memberLater, allFirst, allLater]
  where
    contains = Data.Text.isInfixOf

execute :: KirokuStore -> Text -> IO ()
execute store sql = Pool.use (store ^. #pool) (Session.script sql) >>= either (fail . show) pure
explain :: KirokuStore -> Text -> Text -> Text -> Statement p r -> IO Value
explain store mode types args statement = do
    Right bytes <- Pool.use (store ^. #pool) $ do
        Session.script ("SET plan_cache_mode=" <> mode <> "; PREPARE mp13_deadletters(" <> types <> ") AS " <> Statement.toSql statement)
        bytes <- Session.statement () (unpreparable ("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) EXECUTE mp13_deadletters(" <> args <> ")") E.noParams (D.singleRow (D.column (D.nonNullable (D.jsonBytes Right)))))
        Session.script "DEALLOCATE mp13_deadletters; RESET plan_cache_mode"
        pure bytes
    either fail pure (Aeson.eitherDecodeStrict' bytes)
expect :: Text -> Value -> Bool -> Expectation
expect label plan ok = if ok then pure () else expectationFailure (show label <> ": " <> show plan)
texts :: Aeson.Key -> Value -> [Text]
texts key (Object fields) = [s | Just (String s) <- [KM.lookup key fields]] <> concatMap (texts key) (KM.elems fields)
texts key (Array values) = concatMap (texts key) values
texts _ _ = []
number :: Aeson.Key -> Aeson.Object -> Double
number key fields = case KM.lookup key fields of Just (Number n) -> realToFrac n; _ -> 0
scanned :: Value -> Double
scanned (Object fields) = current + sum (map scanned (KM.elems fields))
  where
    current = case KM.lookup "Relation Name" fields of
        Just (String "dead_letters") -> (number "Actual Rows" fields + number "Rows Removed by Filter" fields + number "Rows Removed by Index Recheck" fields) * number "Actual Loops" fields
        _ -> 0
scanned (Array values) = sum (map scanned (foldr (:) [] values))
scanned _ = 0
sortInputs :: Value -> [Double]
sortInputs (Object fields) = current <> concatMap sortInputs (KM.elems fields)
  where
    current = case (KM.lookup "Node Type" fields, KM.lookup "Plans" fields) of
        (Just (String "Sort"), Just (Array children)) -> [number "Actual Rows" child * number "Actual Loops" child | Object child <- foldr (:) [] children]
        _ -> []
sortInputs (Array values) = concatMap sortInputs values
sortInputs _ = []

buffers :: Value -> Double
buffers (Array values) = case foldr (:) [] values of
    Object entry : _ | Just (Object top) <- KM.lookup "Plan" entry -> number "Shared Hit Blocks" top + number "Shared Read Blocks" top
    _ -> 1 / 0
buffers _ = 1 / 0
