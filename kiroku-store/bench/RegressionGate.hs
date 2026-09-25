{-# LANGUAGE MultilineStrings #-}

module Main where

import Control.Lens ((^.))
import Control.Monad (forM, unless)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Int (Int32, Int64)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Vector qualified as V
import Hasql.Decoders qualified as D
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Kiroku.Store.SQL qualified as SQL
import Kiroku.Test.Fixtures.CategoryScaling (categoryScalingFixtureSql, categoryScalingHead)
import Kiroku.Test.Postgres (withMigratedTestDatabase, withSharedMigratedPostgres)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main =
    withSharedMigratedPostgres $
        withMigratedTestDatabase $ \controlConnectionString ->
            withMigratedTestDatabase $ \candidateConnectionString ->
                withStore (defaultConnectionSettings controlConnectionString) $ \controlStore ->
                    withStore (defaultConnectionSettings candidateConnectionString) $ \candidateStore ->
                        withAppendCategoryStores $ \appendControlStore appendCandidateStore ->
                            withCategoryScalingStore $ \scalingStore -> do
                                let fourStreams = namedStreams "workload-gate-4" 4
                                    eightStreams = namedStreams "workload-gate-8" 8
                                seedStreams controlStore (fourStreams <> eightStreams)
                                seedStreams candidateStore (fourStreams <> eightStreams)

                                runSequentialMultiAppend controlStore fourStreams
                                runProductionMultiAppend candidateStore fourStreams
                                runSequentialMultiAppend controlStore eightStreams
                                runProductionMultiAppend candidateStore eightStreams

                                appendControlCounter <- newIORef 0
                                appendCandidateCounter <- newIORef 0
                                runAppendWorkload preCategoryAppendAnyVersion appendControlStore appendControlCounter
                                runAppendWorkload SQL.appendAnyVersion appendCandidateStore appendCandidateCounter

                                defaultMain
                                    [ localOption WallTime $
                                        bgroup
                                            "append-multi-stream"
                                            [ bench "sequential-control-4" $
                                                whnfIO (runSequentialMultiAppend controlStore fourStreams)
                                            , bcompareWithin 0 0.90 "sequential-control-4" $
                                                bench "production-pipeline-4" $
                                                    whnfIO (runProductionMultiAppend candidateStore fourStreams)
                                            , bench "sequential-control-8" $
                                                whnfIO (runSequentialMultiAppend controlStore eightStreams)
                                            , bcompareWithin 0 0.90 "sequential-control-8" $
                                                bench "production-pipeline-8" $
                                                    whnfIO (runProductionMultiAppend candidateStore eightStreams)
                                            ]
                                    , -- BUG-2 / plan 91 G4: carrying the category onto each $all
                                      -- row (migration 0012) adds a column and one partial-index
                                      -- insert per event. The control runs the pre-0012 append on
                                      -- a database without the index or CHECK.
                                      localOption WallTime $
                                        bgroup
                                            "append-category-column"
                                            [ bench "control-append-40" $
                                                whnfIO (runAppendWorkload preCategoryAppendAnyVersion appendControlStore appendControlCounter)
                                            , bcompareWithin 0 1.05 "control-append-40" $
                                                bench "candidate-append-40" $
                                                    whnfIO (runAppendWorkload SQL.appendAnyVersion appendCandidateStore appendCandidateCounter)
                                            ]
                                    , -- BUG-2 / plan 91 G3: the index-range category reads against
                                      -- the LATERAL statements they replaced, on one database seeded
                                      -- with the category-scaling fixture. The unpartitioned read
                                      -- must not be slower where LATERAL was already cheap, and both
                                      -- caught-up polls on 20,000 streams must be 5x faster.
                                      localOption WallTime $
                                        bgroup
                                            "category-read"
                                            [ bench "control-exhausted-category" $
                                                whnfIO (runPlainReads lateralCategoryRead scalingStore "performance" categoryScalingHead)
                                            , bcompareWithin 0 1.05 "control-exhausted-category" $
                                                bench "candidate-exhausted-category" $
                                                    whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "performance" categoryScalingHead)
                                            , bench "control-page-200-streams-from-0" $
                                                whnfIO (runPlainReads lateralCategoryRead scalingStore "performance" 0)
                                            , bcompareWithin 0 1.05 "control-page-200-streams-from-0" $
                                                bench "candidate-page-200-streams-from-0" $
                                                    whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "performance" 0)
                                            , bench "control-page-20000-streams-from-0" $
                                                whnfIO (runPlainReads lateralCategoryRead scalingStore "idle" 0)
                                            , bcompareWithin 0 1.05 "control-page-20000-streams-from-0" $
                                                bench "candidate-page-20000-streams-from-0" $
                                                    whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "idle" 0)
                                            , bench "control-plain-caught-up-20000-streams" $
                                                whnfIO (runPlainReads lateralCategoryRead scalingStore "idle" categoryScalingHead)
                                            , bcompareWithin 0 0.20 "control-plain-caught-up-20000-streams" $
                                                bench "candidate-plain-caught-up-20000-streams" $
                                                    whnfIO (runPlainReads SQL.readCategoryForwardStmt scalingStore "idle" categoryScalingHead)
                                            , bench "control-group-caught-up-20000-streams" $
                                                whnfIO (runGroupReads lateralCategoryGroupRead scalingStore "idle" categoryScalingHead)
                                            , bcompareWithin 0 0.20 "control-group-caught-up-20000-streams" $
                                                bench "candidate-group-caught-up-20000-streams" $
                                                    whnfIO (runGroupReads SQL.readCategoryForwardConsumerGroupStmt scalingStore "idle" categoryScalingHead)
                                            ]
                                    ]

-- | A migrated store seeded with 'categoryScalingFixtureSql'.
withCategoryScalingStore :: (KirokuStore -> IO a) -> IO a
withCategoryScalingStore action =
    withMigratedTestDatabase $ \connectionString ->
        withStore (defaultConnectionSettings connectionString) $ \store -> do
            seeded <- Pool.use (store ^. #pool) (Session.script categoryScalingFixtureSql)
            case seeded of
                Left err -> error ("category-read gate setup failed: " <> show err)
                Right () -> action store

{- | Ten executions of an unpartitioned category read (limit 100). Ten, not a
hundred: a LATERAL control poll on 20,000 streams costs about 15 ms, and a
hundred per iteration exceeds tasty-bench's timeout.
-}
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

{- | Two freshly migrated stores for the append-category-column gate. The
control database has the category index and CHECK from migration 0012
dropped, so it pays exactly the pre-0012 write cost when driven by
'preCategoryAppendAnyVersion'; the candidate is left as migrated.
-}
withAppendCategoryStores :: (KirokuStore -> KirokuStore -> IO a) -> IO a
withAppendCategoryStores action =
    withMigratedTestDatabase $ \controlConnectionString ->
        withMigratedTestDatabase $ \candidateConnectionString ->
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
                        Right () -> action controlStore candidateStore

{- | One gate iteration: 20 single-event appends to fresh streams, then 20 to
one hot stream. Each store gets its own counter, so control and candidate
create the same stream names and do the same work.
-}
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
    [ ( StreamName (prefix <> "-" <> T.pack (show index))
      , "WorkloadGate" <> T.pack (show index)
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
        { eventId = Nothing
        , eventType = EventType eventType
        , payload = Aeson.object [("workloadGate", Aeson.Bool True)]
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
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
