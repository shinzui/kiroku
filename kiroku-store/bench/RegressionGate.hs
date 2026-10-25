{-# LANGUAGE MultilineStrings #-}

module Main where

import Control.Lens ((^.))
import Control.Monad (forM, replicateM_, unless)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (intercalate)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as V
import GHC.Clock (getMonotonicTime)
import Hasql.Decoders qualified as D
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Store.Subscription.EventPublisher qualified as Publisher
import Kiroku.Test.Fixtures.CategoryScaling (categoryScalingFixtureSql, categoryScalingHead)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import System.Environment (lookupEnv)
import System.Mem (performGC)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  mode <- lookupEnv "KIROKU_GATE_DIAGNOSE"
  withSharedMigratedPostgres $
    withMigratedTestDatabase $ \controlConnectionString ->
      withMigratedTestDatabase $ \candidateConnectionString ->
        withStore (defaultConnectionSettings controlConnectionString) $ \controlStore ->
          withStore (defaultConnectionSettings candidateConnectionString) $ \candidateStore ->
            withAppendCategoryStores $ \appendControlStore appendCandidateStore appendWarmStore ->
              withCategoryScalingStore $ \scalingStore -> do
                let fourStreams = namedStreams "workload-gate-4" 4
                    eightStreams = namedStreams "workload-gate-8" 8
                seedStreams controlStore (fourStreams <> eightStreams)
                seedStreams candidateStore (fourStreams <> eightStreams)

                runSequentialMultiAppend controlStore fourStreams
                runProductionMultiAppend candidateStore fourStreams
                runSequentialMultiAppend controlStore eightStreams
                runProductionMultiAppend candidateStore eightStreams

                (controlStatement, candidateStatement) <- diagnosticStatements mode appendControlStore appendCandidateStore
                appendWarmCounter <- newIORef 0
                appendControlCounter <- newIORef 0
                appendCandidateCounter <- newIORef 0
                -- Prime each growing table before ANALYZE so prepared plans
                -- see a populated store rather than the empty migration template.
                mapM_
                  ( \_ -> do
                      runAppendWorkload controlStatement appendControlStore appendControlCounter
                      runAppendWorkload candidateStatement appendCandidateStore appendCandidateCounter
                      runAppendWorkload SQL.appendAnyVersion appendWarmStore appendWarmCounter
                  )
                  [1 .. 20 :: Int]

                -- Settle fixture writes and refresh plans before measurement.
                runSetupScript scalingStore "CHECKPOINT"
                mapM_
                  (\store -> runSetupScript store "VACUUM (ANALYZE)")
                  [controlStore, candidateStore, appendControlStore, appendCandidateStore, appendWarmStore, scalingStore]

                case mode of
                  Nothing ->
                    defaultMain
                      [ -- BUG-2 / plan 91 G4: carrying the category onto each $all
                        -- row (migration 0012) adds a column and one partial-index
                        -- insert per event. The control runs the pre-0012 append on
                        -- a database without the index or CHECK.
                        localOption WallTime $
                          bgroup
                            "append-category-column"
                            [ -- Keep this group first: the disposable cell absorbs
                              -- post-setup effects without growing either append arm.
                              bench "warm-append-40" $
                                whnfIO (runAppendWorkload SQL.appendAnyVersion appendWarmStore appendWarmCounter),
                              bench "control-append-40" $
                                whnfIO (runAppendWorkload controlStatement appendControlStore appendControlCounter),
                              bcompareWithin 0.5 1.05 "control-append-40" $
                                bench "candidate-append-40" $
                                  whnfIO (runAppendWorkload candidateStatement appendCandidateStore appendCandidateCounter)
                            ],
                        localOption WallTime $
                          bgroup
                            "append-multi-stream"
                            [ bench "sequential-control-4" $
                                whnfIO (runSequentialMultiAppend controlStore fourStreams),
                              bcompareWithin 0.5 0.90 "sequential-control-4" $
                                bench "production-pipeline-4" $
                                  whnfIO (runProductionMultiAppend candidateStore fourStreams),
                              bench "sequential-control-8" $
                                whnfIO (runSequentialMultiAppend controlStore eightStreams),
                              bcompareWithin 0.5 0.90 "sequential-control-8" $
                                bench "production-pipeline-8" $
                                  whnfIO (runProductionMultiAppend candidateStore eightStreams)
                            ],
                        -- BUG-2 / plan 91 G3: the index-range category reads against
                        -- the LATERAL statements they replaced, on one database seeded
                        -- with the category-scaling fixture. The unpartitioned read
                        -- must not be slower where LATERAL was already cheap, and both
                        -- caught-up polls on 20,000 streams must be 5x faster.
                        localOption WallTime $
                          bgroup
                            "category-read"
                            [ bench "control-exhausted-category" $
                                whnfIO (runPlainReads lateralCategoryRead scalingStore "performance" categoryScalingHead),
                              bcompareWithin 0 1.05 "control-exhausted-category" $
                                bench "candidate-exhausted-category" $
                                  whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "performance" categoryScalingHead),
                              bench "control-page-200-streams-from-0" $
                                whnfIO (runPlainReads lateralCategoryRead scalingStore "performance" 0),
                              bcompareWithin 0 1.05 "control-page-200-streams-from-0" $
                                bench "candidate-page-200-streams-from-0" $
                                  whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "performance" 0),
                              bench "control-page-20000-streams-from-0" $
                                whnfIO (runPlainReads lateralCategoryRead scalingStore "idle" 0),
                              bcompareWithin 0 1.05 "control-page-20000-streams-from-0" $
                                bench "candidate-page-20000-streams-from-0" $
                                  whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "idle" 0),
                              bench "control-plain-caught-up-20000-streams" $
                                whnfIO (runPlainReads lateralCategoryRead scalingStore "idle" categoryScalingHead),
                              bcompareWithin 0 0.20 "control-plain-caught-up-20000-streams" $
                                bench "candidate-plain-caught-up-20000-streams" $
                                  whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "idle" categoryScalingHead),
                              bench "control-group-caught-up-20000-streams" $
                                whnfIO (runGroupReads lateralCategoryGroupRead scalingStore "idle" categoryScalingHead),
                              bcompareWithin 0 0.20 "control-group-caught-up-20000-streams" $
                                bench "candidate-group-caught-up-20000-streams" $
                                  whnfIO (runGroupReads SQL.readCategoryForwardConsumerGroupStmt scalingStore "idle" categoryScalingHead)
                            ]
                      ]
                  Just "explain-combined-links" -> runAppendExplainDiagnostic True controlStatement candidateStatement appendControlStore appendCandidateStore
                  Just "explain" -> runAppendExplainDiagnostic False controlStatement candidateStatement appendControlStore appendCandidateStore
                  Just label -> runPairedAppendDiagnostic label controlStatement candidateStatement appendControlStore appendCandidateStore appendControlCounter appendCandidateCounter

runSetupScript :: KirokuStore -> Text -> IO ()
runSetupScript store script = do
  result <- Pool.use (store ^. #pool) (Session.script script)
  case result of
    Left err -> error ("workload gate quiescence failed: " <> show err)
    Right () -> pure ()

-- | Diagnostic comparisons retain the default gate's SQL and bounds. Each
-- invocation gets fresh stores. The A/A mode tests the harness with identical
-- SQL and schema; the other modes separate column/statement from index/CHECK cost.
diagnosticStatements ::
  Maybe String ->
  KirokuStore ->
  KirokuStore ->
  IO (Statement SQL.AppendParams (Maybe AppendResult), Statement SQL.AppendParams (Maybe AppendResult))
diagnosticStatements mode _control candidate = case mode of
  Nothing -> pure (preCategoryAppendAnyVersion, SQL.appendAnyVersion)
  Just "paired" -> pure (preCategoryAppendAnyVersion, SQL.appendAnyVersion)
  Just "explain" -> pure (preCategoryAppendAnyVersion, SQL.appendAnyVersion)
  Just "paired-aa" -> do
    runSetupScript candidate dropCategoryIndexAndCheck
    pure (preCategoryAppendAnyVersion, preCategoryAppendAnyVersion)
  Just "paired-column" -> do
    runSetupScript candidate dropCategoryIndexAndCheck
    pure (preCategoryAppendAnyVersion, SQL.appendAnyVersion)
  Just "paired-index-check" -> pure (SQL.appendAnyVersion, SQL.appendAnyVersion)
  Just "paired-no-publisher" -> do
    runSetupScript _control fullCategoryIndexAndCheck
    -- Diagnostic upper bound only: there are no subscribers in this fixture.
    -- Stopping this worker is not a production optimization or valid subscriber mode.
    Publisher.stopPublisher (candidate ^. #publisher)
    pure (SQL.appendAnyVersion, SQL.appendAnyVersion)
  Just "paired-combined-links" -> do
    -- Both arms retain the fully migrated schema for an optimization comparison.
    runSetupScript _control fullCategoryIndexAndCheck
    pure (SQL.appendAnyVersion, combinedLinksAppend)
  Just "explain-combined-links" -> do
    runSetupScript _control fullCategoryIndexAndCheck
    pure (SQL.appendAnyVersion, combinedLinksAppend)
  Just invalid -> error ("unknown KIROKU_GATE_DIAGNOSE mode: " <> invalid)
  where
    fullCategoryIndexAndCheck =
      "ALTER TABLE kiroku.stream_events ADD CONSTRAINT ck_stream_events_all_category CHECK (stream_id <> 0 OR category IS NOT NULL); CREATE INDEX ix_stream_events_all_by_category ON kiroku.stream_events (category, stream_version) INCLUDE (original_stream_id) WHERE stream_id = 0;"
    dropCategoryIndexAndCheck =
      "DROP INDEX kiroku.ix_stream_events_all_by_category; ALTER TABLE kiroku.stream_events DROP CONSTRAINT ck_stream_events_all_category;"

-- | Benchmark-only hypothesis: one junction INSERT instead of two. This
-- preserves the production bind parameters, row values and result decoder.
combinedLinksAppend :: Statement SQL.AppendParams (Maybe AppendResult)
combinedLinksAppend = Statement.preparable sql SQL.appendParamsEncoder SQL.appendResultDecoder
  where
    production = Statement.toSql SQL.appendAnyVersion
    -- The exact production SQL is extracted below using stable CTE boundaries;
    -- fail rather than silently producing a different candidate after an edit.
    sql = combineJunctionInserts production

combineJunctionInserts :: Text -> Text
combineJunctionInserts production =
  let (beforeSource, sourceAndRest) = T.breakOn "  source_links AS (" production
      (_, allUpdateAndRest) = T.breakOn "  all_update AS (" sourceAndRest
      (allUpdate, allLinksAndResult) = T.breakOn "  all_links AS (" allUpdateAndRest
      (_, result) = T.breakOn "SELECT su.stream_id," allLinksAndResult
      combined =
        """
        event_links AS (
          INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version, category)
          SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx, NULL::text
          FROM new_events ne
          CROSS JOIN stream_upsert su
          UNION ALL
          SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx, su.category
          FROM new_events ne
          CROSS JOIN all_update au
          CROSS JOIN stream_upsert su
        )
        """
   in if T.null beforeSource || T.null allUpdate || T.null result
        then error "combined-links prototype could not identify production CTE boundaries"
        else beforeSource <> allUpdate <> combined <> "\n" <> result

-- | Twelve alternating pairs of equal-sized, growing workloads. Every round
-- starts at the same logical stream/event counts in both databases. These are
-- diagnostic samples, never a substitute passing result for the tasty gate.
runPairedAppendDiagnostic ::
  String ->
  Statement SQL.AppendParams (Maybe AppendResult) ->
  Statement SQL.AppendParams (Maybe AppendResult) ->
  KirokuStore ->
  KirokuStore ->
  IORef Int ->
  IORef Int ->
  IO ()
runPairedAppendDiagnostic label controlStatement candidateStatement control candidate controlCounter candidateCounter = do
  putStrLn "PAIR,variant,pair,first,control_ns,candidate_ns,control_before,candidate_before,control_after,candidate_after,pre_gc"
  mapM_ runPair [1 .. 12 :: Int]
  verifyCounts "control" control controlCounter
  verifyCounts "candidate" candidate candidateCounter
  where
    iterations = 32
    timed :: IO () -> IO Integer
    timed action = do
      -- Match tasty-bench: collect before the timer, rather than letting setup
      -- garbage fall unpredictably into one arm of this diagnostic comparison.
      performGC
      start <- getMonotonicTime
      action
      end <- getMonotonicTime
      pure (round ((end - start) * 1e9) :: Integer)
    controlAction = replicateM_ iterations (runAppendWorkload controlStatement control controlCounter)
    candidateAction = replicateM_ iterations (runAppendWorkload candidateStatement candidate candidateCounter)
    runPair pair = do
      beforeControl <- readIORef controlCounter
      beforeCandidate <- readIORef candidateCounter
      unless (beforeControl == beforeCandidate) $ error "diagnostic arms start at unequal workload counts"
      (controlNs, candidateNs) <-
        if odd pair
          then do
            c <- timed controlAction
            n <- timed candidateAction
            pure (c, n)
          else do
            n <- timed candidateAction
            c <- timed controlAction
            pure (c, n)
      afterControl <- readIORef controlCounter
      afterCandidate <- readIORef candidateCounter
      unless (afterControl == beforeControl + iterations && afterCandidate == beforeCandidate + iterations) $
        error "diagnostic arms did not complete equal work"
      putStrLn $
        intercalate
          ","
          [ "PAIR",
            label,
            show pair,
            if odd pair then "control" else "candidate",
            show controlNs,
            show candidateNs,
            show beforeControl,
            show beforeCandidate,
            show afterControl,
            show afterCandidate,
            "1"
          ]
    verifyCounts arm store counter = do
      completed <- readIORef counter
      let expectedEvents = fromIntegral (40 * completed) :: Int64
          expectedStreams = fromIntegral (20 * completed + 2) :: Int64
      result <- Pool.use (store ^. #pool) (Session.statement () diagnosticCounts)
      case result of
        Right counts@(streams, events, links, hotVersion, globalVersion) -> do
          unless (counts == (expectedStreams, expectedEvents, 2 * expectedEvents, expectedEvents `div` 2, expectedEvents)) $
            error ("diagnostic database counts differ for " <> arm <> ": " <> show counts)
          putStrLn $ intercalate "," ["COUNTS", label, arm, show streams, show events, show links, show hotVersion, show globalVersion]
        Left err -> error ("diagnostic count verification failed: " <> show err)

-- | Use the exact statements under comparison, rather than a copied EXPLAIN
-- query. These four plans show structure/buffers/WAL, not a latency estimate.
runAppendExplainDiagnostic ::
  Bool ->
  Statement SQL.AppendParams (Maybe AppendResult) ->
  Statement SQL.AppendParams (Maybe AppendResult) ->
  KirokuStore ->
  KirokuStore ->
  IO ()
runAppendExplainDiagnostic timings controlStatement candidateStatement control candidate = do
  mapM_
    ( \(arm, statement, store) -> do
        mapM_ (explainOne arm statement store) [("fresh", "append-gate-explain-fresh"), ("hot", "append-gate-hot")]
        rows <- Pool.use (store ^. #pool) (Session.statement () physicalRows)
        case rows of
          Right value -> putStrLn ("PHYSICAL," <> arm <> "," <> T.unpack value)
          Left err -> error ("diagnostic physical row query failed: " <> show err)
    )
    [("control", controlStatement, control), ("candidate", candidateStatement, candidate)]
  where
    jsonText = D.singleRow (D.column (D.nonNullable (D.jsonBytes (Right . decodeUtf8Lenient))))
    physicalRows =
      Statement.unpreparable
        "SELECT json_agg(row_to_json(x)) FROM (SELECT stream_id = 0 AS all_row, category IS NULL AS category_is_null, pg_column_size(se) AS row_bytes, count(*) AS samples FROM stream_events se GROUP BY 1,2,3 ORDER BY 1,2,3) x"
        mempty
        jsonText
    explainOne arm statement store (kind, name) = do
      enriched <- enrichEvents (store ^. #storeSettings) [makeEvent "AppendCategoryGate"]
      prepared <- prepareEvents enriched
      now <- getCurrentTime
      let explain =
            Statement.unpreparable
              ("EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING " <> (if timings then "ON" else "OFF") <> ", FORMAT JSON) " <> Statement.toSql statement)
              SQL.appendParamsEncoder
              jsonText
      result <- Pool.use (store ^. #pool) (Session.statement (buildAppendParams name now prepared) explain)
      case result of
        Right value -> putStrLn ("PLAN," <> arm <> "," <> kind <> "," <> T.unpack value)
        Left err -> error ("diagnostic EXPLAIN failed: " <> show err)

diagnosticCounts :: Statement () (Int64, Int64, Int64, Int64, Int64)
diagnosticCounts =
  Statement.unpreparable
    "SELECT (SELECT count(*) FROM streams), (SELECT count(*) FROM events), (SELECT count(*) FROM stream_events), (SELECT stream_version FROM streams WHERE stream_name = 'append-gate-hot'), (SELECT stream_version FROM streams WHERE stream_id = 0)"
    mempty
    (D.singleRow ((,,,,) <$> int8 <*> int8 <*> int8 <*> int8 <*> int8))
  where
    int8 = D.column (D.nonNullable D.int8)

-- | A migrated store seeded with 'categoryScalingFixtureSql'.
withCategoryScalingStore :: (KirokuStore -> IO a) -> IO a
withCategoryScalingStore action =
  withMigratedTestDatabase $ \connectionString ->
    withStore (defaultConnectionSettings connectionString) $ \store -> do
      seeded <- Pool.use (store ^. #pool) (Session.script categoryScalingFixtureSql)
      case seeded of
        Left err -> error ("category-read gate setup failed: " <> show err)
        Right () -> action store

-- | Ten executions of an unpartitioned category read (limit 100). Ten, not a
-- hundred: a LATERAL control poll on 20,000 streams costs about 15 ms, and a
-- hundred per iteration exceeds tasty-bench's timeout.
runPlainReads ::
  Statement (Int64, Text, Int32) (V.Vector RecordedEvent) ->
  KirokuStore ->
  Text ->
  Int64 ->
  IO ()
runPlainReads statement store category cursor =
  mapM_
    (\_ -> Pool.use (store ^. #pool) (Session.statement (cursor, category, 100) statement) >>= forceReads)
    [1 .. 10 :: Int]

-- | Ten executions of a consumer-group category read, member 1 of 2 (limit 100).
runGroupReads ::
  Statement (Int64, Text, Int32, Int32, Int32) (V.Vector RecordedEvent) ->
  KirokuStore ->
  Text ->
  Int64 ->
  IO ()
runGroupReads statement store category cursor =
  mapM_
    (\_ -> Pool.use (store ^. #pool) (Session.statement (cursor, category, 1, 2, 100) statement) >>= forceReads)
    [1 .. 10 :: Int]

forceReads :: Either Pool.UsageError (V.Vector RecordedEvent) -> IO ()
forceReads (Right events) = V.length events `seq` pure ()
forceReads (Left err) = error ("category-read gate read failed: " <> show err)

-- | 'SQL.readCategoryForwardStmt' as it was before plan 91 (git 12d50d5).
lateralCategoryRead :: Statement (Int64, Text, Int32) (V.Vector RecordedEvent)
lateralCategoryRead =
  Statement.preparable
    lateralCategoryReadSQL
    SQL.readCategoryEncoder
    (D.rowVector SQL.recordedEventRow)

-- | 'SQL.readCategoryForwardConsumerGroupStmt' as it was before plan 91 (git 12d50d5).
lateralCategoryGroupRead :: Statement (Int64, Text, Int32, Int32, Int32) (V.Vector RecordedEvent)
lateralCategoryGroupRead =
  Statement.preparable
    lateralCategoryGroupReadSQL
    SQL.readCategoryConsumerGroupEncoder
    (D.rowVector SQL.recordedEventRow)

lateralCategoryReadSQL :: Text
lateralCategoryReadSQL =
  """
  SELECT e.event_id, e.event_type,
         se.stream_version, se.stream_version AS global_position,
         se.original_stream_id, se.original_stream_version,
         e.data, e.metadata, e.causation_id, e.correlation_id,
         e.created_at
  FROM streams s
  JOIN LATERAL (
    SELECT se.*
    FROM stream_events se
    WHERE se.stream_id = 0
      AND se.original_stream_id = s.stream_id
      AND se.stream_version > $1
    ORDER BY se.stream_version ASC
    LIMIT $3
  ) se ON true
  JOIN events e ON e.event_id = se.event_id
  WHERE s.category = $2
  ORDER BY se.stream_version ASC
  LIMIT $3
  """

lateralCategoryGroupReadSQL :: Text
lateralCategoryGroupReadSQL =
  """
  SELECT e.event_id, e.event_type,
         se.stream_version, se.stream_version AS global_position,
         se.original_stream_id, se.original_stream_version,
         e.data, e.metadata, e.causation_id, e.correlation_id,
         e.created_at
  FROM streams s
  JOIN LATERAL (
    SELECT se.*
    FROM stream_events se
    WHERE se.stream_id = 0
      AND se.original_stream_id = s.stream_id
      AND se.stream_version > $1
    ORDER BY se.stream_version ASC
    LIMIT $5
  ) se ON true
  JOIN events e ON e.event_id = se.event_id
  WHERE s.category = $2
    AND (((hashtextextended(s.stream_id::text, 0) % $4) + $4) % $4) = $3
  ORDER BY se.stream_version ASC
  LIMIT $5
  """

-- | Three freshly migrated stores for the append-category-column gate. The
-- control database has the category index and CHECK from migration 0012
-- dropped, so it pays exactly the pre-0012 write cost when driven by
-- 'preCategoryAppendAnyVersion'; candidate and disposable warm-up stores remain migrated.
withAppendCategoryStores :: (KirokuStore -> KirokuStore -> KirokuStore -> IO a) -> IO a
withAppendCategoryStores action =
  withMigratedTestDatabase $ \controlConnectionString ->
    withMigratedTestDatabase $ \candidateConnectionString ->
      withMigratedTestDatabase $ \warmConnectionString ->
        withStore (defaultConnectionSettings warmConnectionString) $ \warmStore ->
          withStore (defaultConnectionSettings controlConnectionString) $ \controlStore ->
            withStore (defaultConnectionSettings candidateConnectionString) $ \candidateStore -> do
              dropped <-
                Pool.use
                  (controlStore ^. #pool)
                  ( Session.script
                      """
                      DROP INDEX kiroku.ix_stream_events_all_by_category;
                      ALTER TABLE kiroku.stream_events DROP CONSTRAINT ck_stream_events_all_category;
                      """
                  )
              case dropped of
                Left err -> error ("append-category control setup failed: " <> show err)
                Right () -> action controlStore candidateStore warmStore

-- | One gate iteration: 20 single-event appends to fresh streams, then 20 to
-- one hot stream. Each store gets its own counter, so control and candidate
-- create the same stream names and do the same work.
runAppendWorkload ::
  Statement SQL.AppendParams (Maybe AppendResult) ->
  KirokuStore ->
  IORef Int ->
  IO ()
runAppendWorkload statement store counter = do
  iteration <- atomicModifyIORef' counter (\n -> (n + 1, n))
  now <- getCurrentTime
  let freshNames =
        [ "append-gate-" <> T.pack (show iteration) <> "-" <> T.pack (show index)
        | index <- [1 .. 20 :: Int]
        ]
      names = freshNames <> replicate 20 "append-gate-hot"
  mapM_
    ( \name -> do
        enriched <- enrichEvents (store ^. #storeSettings) [makeEvent "AppendCategoryGate"]
        prepared <- prepareEvents enriched
        result <-
          Pool.use (store ^. #pool) $
            Session.statement (buildAppendParams name now prepared) statement
        case result of
          Right (Just appendResult) -> forceAppendResults [appendResult]
          Right Nothing -> error "append-category gate append returned no row"
          Left err -> error ("append-category gate append failed: " <> show err)
    )
    names

-- | 'SQL.appendAnyVersion' as it was before migration 0012 (git 12d50d5).
preCategoryAppendAnyVersion :: Statement SQL.AppendParams (Maybe AppendResult)
preCategoryAppendAnyVersion =
  Statement.preparable
    preCategoryAppendAnyVersionSQL
    SQL.appendParamsEncoder
    SQL.appendResultDecoder

preCategoryAppendAnyVersionSQL :: Text
preCategoryAppendAnyVersionSQL =
  """
  WITH
    new_events AS (
      SELECT *
      FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
      WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
    ),
    stream_upsert AS (
      INSERT INTO streams (stream_name, stream_version)
      VALUES ($8, (SELECT count(*) FROM new_events))
      ON CONFLICT (stream_name)
      DO UPDATE SET stream_version = streams.stream_version + (SELECT count(*) FROM new_events)
        WHERE streams.deleted_at IS NULL
      RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
    ),
    inserted_events AS (
      INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
      SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
      FROM new_events
      WHERE EXISTS (SELECT 1 FROM stream_upsert)
      ORDER BY idx
    ),
    source_links AS (
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
      FROM new_events ne
      CROSS JOIN stream_upsert su
    ),
    all_update AS (
      UPDATE streams
      SET stream_version = stream_version + (SELECT count(*) FROM new_events)
      WHERE stream_id = 0
        AND EXISTS (SELECT 1 FROM stream_upsert)
      RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
    ),
    all_links AS (
      INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
      SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
      FROM new_events ne
      CROSS JOIN all_update au
      CROSS JOIN stream_upsert su
    )
  SELECT su.stream_id,
         su.initial_version + (SELECT count(*) FROM new_events),
         au.initial_global_version + (SELECT count(*) FROM new_events)
  FROM stream_upsert su
  CROSS JOIN all_update au
  """

namedStreams :: Text -> Int -> [(StreamName, Text)]
namedStreams prefix count =
  [ ( StreamName (prefix <> "-" <> T.pack (show index)),
      "WorkloadGate" <> T.pack (show index)
    )
  | index <- [1 .. count]
  ]

seedStreams :: KirokuStore -> [(StreamName, Text)] -> IO ()
seedStreams store streams =
  mapM_
    ( \(streamName, eventType) -> do
        result <- runStoreIO store $ appendToStream streamName NoStream [makeEvent (eventType <> "Seed")]
        forceStoreResults "seed append" (fmap pure result)
    )
    streams

runProductionMultiAppend :: KirokuStore -> [(StreamName, Text)] -> IO ()
runProductionMultiAppend store streams = do
  result <-
    runStoreIO store $
      appendMultiStream
        [ (streamName, AnyVersion, [makeEvent eventType])
        | (streamName, eventType) <- streams
        ]
  forceStoreResults "production appendMultiStream" result

runSequentialMultiAppend :: KirokuStore -> [(StreamName, Text)] -> IO ()
runSequentialMultiAppend store streams = do
  now <- getCurrentTime
  preparedOps <-
    forM streams $ \(streamName@(StreamName name), eventType) -> do
      enriched <- enrichEvents (store ^. #storeSettings) [makeEvent eventType]
      prepared <- prepareEvents enriched
      pure (streamName, name, buildAppendParams name now prepared)
  let names = V.fromList [name | (_, name, _) <- preparedOps]
      transaction = do
        Tx.statement names SQL.lockStreamsForMultiStmt
        results <-
          forM preparedOps $ \(_, _, params) ->
            appendDispatchTx AnyVersion params
        if any isNothing results
          then Tx.condemn >> pure results
          else pure results
  result <-
    Pool.use (store ^. #pool) $
      TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write transaction
  case result of
    Left err -> error ("sequential appendMultiStream control failed: " <> show err)
    Right maybeResults -> do
      unless (all isJustAppend maybeResults) $
        error "sequential appendMultiStream control returned an empty append result"
      forceAppendResults [appendResult | Just appendResult <- maybeResults]

makeEvent :: Text -> EventData
makeEvent eventType =
  EventData
    { eventId = Nothing,
      eventType = EventType eventType,
      payload = Aeson.object [("workloadGate", Aeson.Bool True)],
      metadata = Nothing,
      causationId = Nothing,
      correlationId = Nothing
    }

isJustAppend :: Maybe AppendResult -> Bool
isJustAppend (Just _) = True
isJustAppend Nothing = False

forceStoreResults :: String -> Either StoreError [AppendResult] -> IO ()
forceStoreResults _ (Right results) = forceAppendResults results
forceStoreResults label (Left err) = error (label <> " failed: " <> show err)

forceAppendResults :: [AppendResult] -> IO ()
forceAppendResults =
  mapM_ $ \result ->
    (result ^. #streamId) `seq`
      (result ^. #streamVersion) `seq`
        (result ^. #globalPosition) `seq`
          pure ()
