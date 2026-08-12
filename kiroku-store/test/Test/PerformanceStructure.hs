{-# LANGUAGE MultilineStrings #-}

module Test.PerformanceStructure (spec) where

import Control.Lens ((^.))
import Control.Monad (unless)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Foldable (foldl')
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, unpreparable)
import Hasql.Statement qualified as Statement
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Test.Helpers (withTestStore, withTestStoreSettings)
import Test.Hspec

spec :: Spec
spec = do
    noOpAppendSpec
    queryPlanSpec

noOpAppendSpec :: Spec
noOpAppendSpec =
    describe "no-op paths use no pooled connection" $ do
        it "rejects an empty appendToStream batch before pool checkout" $ do
            checkouts <- newIORef (0 :: Int)
            withObservedStore checkouts $ \store -> do
                before <- readIORef checkouts
                result <- runStoreIO store $ appendToStream (StreamName "performance-empty-append") AnyVersion []
                after <- readIORef checkouts
                result `shouldBe` Left (EmptyAppendBatch (StreamName "performance-empty-append"))
                after - before `shouldBe` 0

        it "returns an empty appendMultiStream result before pool checkout" $ do
            checkouts <- newIORef (0 :: Int)
            withObservedStore checkouts $ \store -> do
                before <- readIORef checkouts
                result <- runStoreIO store $ appendMultiStream []
                after <- readIORef checkouts
                result `shouldBe` Right []
                after - before `shouldBe` 0
queryPlanSpec :: Spec
queryPlanSpec =
    describe "production query plans" $
        aroundAll withQueryPlanStore $ do
            it "visible global head lookup uses ux_stream_events_stream_version without Sort" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.visibleGlobalHeadPositionStmt
                        []
                expectIndex "ux_stream_events_stream_version" plan
                expectNoNodeType "Sort" plan

            it "category high-cursor reads use ix_stream_events_all_by_origin" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.readCategoryForwardStmt
                        [ ("$3", "100::int4")
                        , ("$2", "'performance'::text")
                        , ("$1", "15000::bigint")
                        ]
                expectIndex "ix_stream_events_all_by_origin" plan

            it "dead-letter reads use ix_dead_letters_subscription_position without Sort" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.readDeadLettersStmt
                        [ ("$2", "0::int4")
                        , ("$1", "'performance-read'::text")
                        ]
                expectIndex "ix_dead_letters_subscription_position" plan
                expectNoNodeType "Sort" plan

            it "orphan dead-letter cleanup uses ix_dead_letters_event_id" $ \store -> do
                plan <-
                    explainProductionStatement
                        store
                        SQL.deleteDeadLettersForOrphanedEventsStmt
                        [("$1", "ARRAY['00000000-0000-0000-0000-000000000001'::uuid]::uuid[]")]
                expectIndex "ix_dead_letters_event_id" plan

withObservedStore :: IORef Int -> (KirokuStore -> IO ()) -> IO ()
withObservedStore checkouts =
    withTestStoreSettings $ \settings ->
        settings
            { observationHandler =
                Just $ \case
                    ConnectionObservation _ InUseConnectionStatus -> modifyIORef' checkouts (+ 1)
                    _ -> pure ()
            }

withQueryPlanStore :: (KirokuStore -> IO ()) -> IO ()
withQueryPlanStore action =
    withTestStore $ \store -> do
        result <- Pool.use (store ^. #pool) (Session.script queryPlanFixture)
        case result of
            Left err -> expectationFailure ("failed to seed performance query-plan fixture: " <> show err)
            Right () -> action store

queryPlanFixture :: Text
queryPlanFixture =
    """
    BEGIN;

    WITH new_streams AS (
      INSERT INTO streams (stream_name, stream_version)
      SELECT 'performance-' || n::text, 100
      FROM generate_series(1, 200) AS n
      RETURNING stream_id
    ), fixture_events AS MATERIALIZED (
      SELECT uuidv7() AS event_id,
             s.stream_id,
             per_stream_position::bigint AS stream_version,
             row_number() OVER (ORDER BY per_stream_position, s.stream_id)::bigint AS global_position
      FROM new_streams AS s
      CROSS JOIN generate_series(1, 100) AS per_stream_position
    ), inserted_events AS (
      INSERT INTO events (event_id, event_type, data)
      SELECT event_id, 'PerformanceFixture', '{}'::jsonb
      FROM fixture_events
      RETURNING event_id
    ), source_links AS (
      INSERT INTO stream_events
        (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT fixture.event_id,
             fixture.stream_id,
             fixture.stream_version,
             fixture.stream_id,
             fixture.stream_version
      FROM fixture_events AS fixture
      JOIN inserted_events USING (event_id)
      RETURNING event_id
    ), all_links AS (
      INSERT INTO stream_events
        (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT fixture.event_id,
             0,
             fixture.global_position,
             fixture.stream_id,
             fixture.stream_version
      FROM fixture_events AS fixture
      JOIN inserted_events USING (event_id)
      RETURNING event_id
    ), advanced_all AS (
      UPDATE streams
      SET stream_version = (SELECT max(global_position) FROM fixture_events)
      WHERE stream_id = 0
      RETURNING stream_id
    ), inserted_dead_letters AS (
      INSERT INTO dead_letters
        (subscription_name, consumer_group_member, global_position, event_id,
         reason, reason_summary, attempt_count)
      SELECT CASE
               WHEN fixture.global_position % 10 = 0 THEN 'performance-read'
               ELSE 'performance-other-' || (fixture.global_position % 9)::text
             END,
             0,
             fixture.global_position,
             fixture.event_id,
             '{}'::jsonb,
             'performance fixture',
             1
      FROM fixture_events AS fixture
      JOIN inserted_events USING (event_id)
      RETURNING dead_letter_id
    )
    SELECT (SELECT count(*) FROM source_links),
           (SELECT count(*) FROM all_links),
           (SELECT count(*) FROM advanced_all),
           (SELECT count(*) FROM inserted_dead_letters);

    COMMIT;
    ANALYZE streams;
    ANALYZE events;
    ANALYZE stream_events;
    ANALYZE dead_letters;
    """

explainProductionStatement ::
    KirokuStore ->
    Statement params result ->
    [(Text, Text)] ->
    IO Value
explainProductionStatement store productionStatement replacements = do
    let productionSql = Statement.toSql productionStatement
        explainedSql =
            "EXPLAIN (FORMAT JSON, COSTS OFF)\n"
                <> foldl' (\sql (placeholder, literal) -> T.replace placeholder literal sql) productionSql replacements
        explainStatement :: Statement () ByteString
        explainStatement =
            unpreparable
                explainedSql
                E.noParams
                (D.singleRow (D.column (D.nonNullable (D.jsonBytes Right))))
    result <- Pool.use (store ^. #pool) (Session.statement () explainStatement)
    bytes <- case result of
        Left err -> expectationFailure ("EXPLAIN failed: " <> show err) >> fail "unreachable"
        Right value -> pure value
    case Aeson.eitherDecodeStrict' bytes of
        Left err -> expectationFailure ("could not decode EXPLAIN JSON: " <> err) >> fail "unreachable"
        Right value -> pure value

data PlanFacts = PlanFacts
    { nodeTypes :: [Text]
    , indexNames :: [Text]
    }
    deriving stock (Show)

instance Semigroup PlanFacts where
    PlanFacts nodeTypesA indexNamesA <> PlanFacts nodeTypesB indexNamesB =
        PlanFacts (nodeTypesA <> nodeTypesB) (indexNamesA <> indexNamesB)

instance Monoid PlanFacts where
    mempty = PlanFacts [] []

collectPlanFacts :: Value -> PlanFacts
collectPlanFacts (Object object) =
    PlanFacts
        { nodeTypes = maybe [] pure (textField "Node Type" object)
        , indexNames = maybe [] pure (textField "Index Name" object)
        }
        <> foldMap collectPlanFacts (KeyMap.elems object)
collectPlanFacts (Array values) = foldMap collectPlanFacts values
collectPlanFacts _ = mempty

textField :: Aeson.Key -> Aeson.Object -> Maybe Text
textField key object = case KeyMap.lookup key object of
    Just (String value) -> Just value
    _ -> Nothing

expectIndex :: Text -> Value -> Expectation
expectIndex expected plan = do
    let facts = collectPlanFacts plan
    unless (expected `elem` indexNames facts) $
        expectationFailure $
            "expected plan to use index "
                <> T.unpack expected
                <> ", but collected "
                <> show facts
                <> " from:\n"
                <> show plan

expectNoNodeType :: Text -> Value -> Expectation
expectNoNodeType forbidden plan = do
    let facts = collectPlanFacts plan
    unless (forbidden `notElem` nodeTypes facts) $
        expectationFailure $
            "expected plan not to contain node type "
                <> T.unpack forbidden
                <> ", but collected "
                <> show facts
                <> " from:\n"
                <> show plan
