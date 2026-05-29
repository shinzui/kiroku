{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MultilineStrings #-}

module Main where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V7 qualified as V7
import Data.Vector qualified as V
import EphemeralPg qualified as Pg
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kiroku.Store
import Test.Tasty.Bench

data RawAppendParams = RawAppendParams
    { eventId :: !UUID
    , eventType :: !Text
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    , payload :: !Aeson.Value
    , metadata :: !(Maybe Aeson.Value)
    , createdAt :: !UTCTime
    , streamName :: !Text
    }
    deriving stock (Generic)

data RawProductionAppendParams = RawProductionAppendParams
    { productionEventIds :: !(V.Vector UUID)
    , productionEventTypes :: !(V.Vector Text)
    , productionCausationIds :: !(V.Vector (Maybe UUID))
    , productionCorrelationIds :: !(V.Vector (Maybe UUID))
    , productionPayloads :: !(V.Vector Aeson.Value)
    , productionMetadatas :: !(V.Vector (Maybe Aeson.Value))
    , productionCreatedAts :: !(V.Vector UTCTime)
    , productionStreamName :: !Text
    }
    deriving stock (Generic)

type RawAppendResult = (Int64, Int64, Int64)

rawAppendParamsEncoder :: E.Params RawAppendParams
rawAppendParamsEncoder =
    ((^. #eventId) >$< E.param (E.nonNullable E.uuid))
        <> ((^. #eventType) >$< E.param (E.nonNullable E.text))
        <> ((^. #causationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #correlationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #payload) >$< E.param (E.nonNullable E.jsonb))
        <> ((^. #metadata) >$< E.param (E.nullable E.jsonb))
        <> ((^. #createdAt) >$< E.param (E.nonNullable E.timestamptz))
        <> ((^. #streamName) >$< E.param (E.nonNullable E.text))

rawProductionAppendParamsEncoder :: E.Params RawProductionAppendParams
rawProductionAppendParamsEncoder =
    ((^. #productionEventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((^. #productionEventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((^. #productionCausationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #productionCorrelationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #productionPayloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((^. #productionMetadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((^. #productionCreatedAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((^. #productionStreamName) >$< E.param (E.nonNullable E.text))

rawAppendResultDecoder :: D.Result (Maybe RawAppendResult)
rawAppendResultDecoder =
    D.rowMaybe $
        (,,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.int8)

rawScalarAppendAnyVersion :: Statement RawAppendParams (Maybe RawAppendResult)
rawScalarAppendAnyVersion =
    preparable
        rawScalarAppendAnyVersionSQL
        rawAppendParamsEncoder
        rawAppendResultDecoder

rawProductionAppendAnyVersion :: Statement RawProductionAppendParams (Maybe RawAppendResult)
rawProductionAppendAnyVersion =
    preparable
        rawProductionAppendAnyVersionSQL
        rawProductionAppendParamsEncoder
        rawAppendResultDecoder

rawScalarAppendAnyVersionSQL :: Text
rawScalarAppendAnyVersionSQL =
    """
    WITH
      new_event AS (
        SELECT $1::uuid AS event_id,
               $2::text AS event_type,
               $3::uuid AS causation_id,
               $4::uuid AS correlation_id,
               $5::jsonb AS data,
               $6::jsonb AS metadata,
               $7::timestamptz AS created_at
      ),
      stream_upsert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($8, 1)
        ON CONFLICT (stream_name)
        DO UPDATE SET stream_version = streams.stream_version + 1
          WHERE streams.deleted_at IS NULL
        RETURNING stream_id, stream_version - 1 AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_event
        WHERE EXISTS (SELECT 1 FROM stream_upsert)
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + 1, su.stream_id, su.initial_version + 1
        FROM new_event ne
        CROSS JOIN stream_upsert su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + 1
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_upsert)
        RETURNING stream_version - 1 AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + 1, su.stream_id, su.initial_version + 1
        FROM new_event ne
        CROSS JOIN all_update au
        CROSS JOIN stream_upsert su
      )
    SELECT su.stream_id,
           su.initial_version + 1,
           au.initial_global_version + 1
    FROM stream_upsert su
    CROSS JOIN all_update au
    """

rawProductionAppendAnyVersionSQL :: Text
rawProductionAppendAnyVersionSQL =
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

-- Two-round-trip variants: the proof-of-concept that the plan-23 restructure
-- is structurally faster than the production arrays/unnest CTE. The resolve
-- query reads (stream_id, stream_version, deleted_at) by stream_name; one of
-- two append CTEs then runs keyed on the resolved stream_id (existing) or on
-- the stream_name with no ON CONFLICT (new).

data RawResolution = RawResolution
    { resStreamId :: !Int64
    , resStreamVersion :: !Int64
    , resDeletedAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic)

rawResolveStreamStmt :: Statement Text (Maybe RawResolution)
rawResolveStreamStmt =
    preparable
        rawResolveStreamSQL
        (E.param (E.nonNullable E.text))
        ( D.rowMaybe $
            RawResolution
                <$> D.column (D.nonNullable D.int8)
                <*> D.column (D.nonNullable D.int8)
                <*> D.column (D.nullable D.timestamptz)
        )

rawResolveStreamSQL :: Text
rawResolveStreamSQL =
    """
    SELECT stream_id, stream_version, deleted_at
    FROM streams
    WHERE stream_name = $1
    """

-- | Append params for the two-round-trip "existing" path: stream_id is known.
data RawAppendExistingParams = RawAppendExistingParams
    { existingStreamId :: !Int64
    , existingEventId :: !UUID
    , existingEventType :: !Text
    , existingCausationId :: !(Maybe UUID)
    , existingCorrelationId :: !(Maybe UUID)
    , existingPayload :: !Aeson.Value
    , existingMetadata :: !(Maybe Aeson.Value)
    , existingCreatedAt :: !UTCTime
    }
    deriving stock (Generic)

rawAppendExistingEncoder :: E.Params RawAppendExistingParams
rawAppendExistingEncoder =
    ((^. #existingStreamId) >$< E.param (E.nonNullable E.int8))
        <> ((^. #existingEventId) >$< E.param (E.nonNullable E.uuid))
        <> ((^. #existingEventType) >$< E.param (E.nonNullable E.text))
        <> ((^. #existingCausationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #existingCorrelationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #existingPayload) >$< E.param (E.nonNullable E.jsonb))
        <> ((^. #existingMetadata) >$< E.param (E.nullable E.jsonb))
        <> ((^. #existingCreatedAt) >$< E.param (E.nonNullable E.timestamptz))

rawAppendUpdateExisting :: Statement RawAppendExistingParams (Maybe RawAppendResult)
rawAppendUpdateExisting =
    preparable
        rawAppendUpdateExistingSQL
        rawAppendExistingEncoder
        rawAppendResultDecoder

{- | Update an existing stream keyed on integer stream_id. No version check,
no soft-delete check, no EXISTS gating, no count(*) — Haskell-side
validation has already done all of that.
-}
rawAppendUpdateExistingSQL :: Text
rawAppendUpdateExistingSQL =
    """
    WITH
      stream_update AS (
        UPDATE streams
        SET stream_version = stream_version + 1
        WHERE stream_id = $1::bigint
        RETURNING stream_id, stream_version - 1 AS initial_version
      ),
      inserted_event AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        VALUES ($2::uuid, $3::text, $4::uuid, $5::uuid, $6::jsonb, $7::jsonb, $8::timestamptz)
      ),
      source_link AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT $2::uuid, su.stream_id, su.initial_version + 1, su.stream_id, su.initial_version + 1
        FROM stream_update su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + 1
        WHERE stream_id = 0
        RETURNING stream_version - 1 AS initial_global_version
      ),
      all_link AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT $2::uuid, 0, au.initial_global_version + 1, su.stream_id, su.initial_version + 1
        FROM all_update au
        CROSS JOIN stream_update su
      )
    SELECT su.stream_id,
           su.initial_version + 1,
           au.initial_global_version + 1
    FROM stream_update su
    CROSS JOIN all_update au
    """

-- | Append params for the two-round-trip "new stream" path: stream_name only.
data RawAppendNewParams = RawAppendNewParams
    { newStreamName :: !Text
    , newEventId :: !UUID
    , newEventType :: !Text
    , newCausationId :: !(Maybe UUID)
    , newCorrelationId :: !(Maybe UUID)
    , newPayload :: !Aeson.Value
    , newMetadata :: !(Maybe Aeson.Value)
    , newCreatedAt :: !UTCTime
    }
    deriving stock (Generic)

rawAppendNewEncoder :: E.Params RawAppendNewParams
rawAppendNewEncoder =
    ((^. #newStreamName) >$< E.param (E.nonNullable E.text))
        <> ((^. #newEventId) >$< E.param (E.nonNullable E.uuid))
        <> ((^. #newEventType) >$< E.param (E.nonNullable E.text))
        <> ((^. #newCausationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #newCorrelationId) >$< E.param (E.nullable E.uuid))
        <> ((^. #newPayload) >$< E.param (E.nonNullable E.jsonb))
        <> ((^. #newMetadata) >$< E.param (E.nullable E.jsonb))
        <> ((^. #newCreatedAt) >$< E.param (E.nonNullable E.timestamptz))

rawAppendCreateNew :: Statement RawAppendNewParams (Maybe RawAppendResult)
rawAppendCreateNew =
    preparable
        rawAppendCreateNewSQL
        rawAppendNewEncoder
        rawAppendResultDecoder

{- | Create a new stream and append one event. No ON CONFLICT — Haskell-side
validation already proved the stream is absent; a race-loser hits the
ix_streams_stream_name unique constraint and surfaces as a usage error.
-}
rawAppendCreateNewSQL :: Text
rawAppendCreateNewSQL =
    """
    WITH
      stream_insert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($1::text, 1)
        RETURNING stream_id, 0::bigint AS initial_version
      ),
      inserted_event AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        VALUES ($2::uuid, $3::text, $4::uuid, $5::uuid, $6::jsonb, $7::jsonb, $8::timestamptz)
      ),
      source_link AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT $2::uuid, si.stream_id, si.initial_version + 1, si.stream_id, si.initial_version + 1
        FROM stream_insert si
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + 1
        WHERE stream_id = 0
        RETURNING stream_version - 1 AS initial_global_version
      ),
      all_link AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT $2::uuid, 0, au.initial_global_version + 1, si.stream_id, si.initial_version + 1
        FROM all_update au
        CROSS JOIN stream_insert si
      )
    SELECT si.stream_id,
           si.initial_version + 1,
           au.initial_global_version + 1
    FROM stream_insert si
    CROSS JOIN all_update au
    """

mkRawAppendParams :: Text -> IO RawAppendParams
mkRawAppendParams name = do
    eventUuid <- oneUuid
    now <- getCurrentTime
    pure
        RawAppendParams
            { eventId = eventUuid
            , eventType = "RawBenchEvent"
            , causationId = Nothing
            , correlationId = Nothing
            , payload = Aeson.object [("benchmark", Aeson.Bool True)]
            , metadata = Nothing
            , createdAt = now
            , streamName = name
            }

mkRawProductionAppendParams :: RawAppendParams -> RawProductionAppendParams
mkRawProductionAppendParams params =
    RawProductionAppendParams
        { productionEventIds = V.singleton (params ^. #eventId)
        , productionEventTypes = V.singleton (params ^. #eventType)
        , productionCausationIds = V.singleton (params ^. #causationId)
        , productionCorrelationIds = V.singleton (params ^. #correlationId)
        , productionPayloads = V.singleton (params ^. #payload)
        , productionMetadatas = V.singleton (params ^. #metadata)
        , productionCreatedAts = V.singleton (params ^. #createdAt)
        , productionStreamName = params ^. #streamName
        }

oneUuid :: IO UUID
oneUuid = do
    generated <- V7.genUUIDs 1
    case generated of
        uuid : _ -> pure uuid
        [] -> error "oneUuid: UUID generator returned no IDs"

runRawScalarAppendAnyVersionNewStream :: KirokuStore -> IORef Int -> IO ()
runRawScalarAppendAnyVersionNewStream store counter = do
    streamId <- atomicModifyIORef' counter (\n -> (n + 1, n))
    params <- mkRawAppendParams ("raw-scalar-new-" <> T.pack (show streamId))
    result <- Pool.use (store ^. #pool) $ Session.statement params rawScalarAppendAnyVersion
    forceRawAppend result

runRawProductionAppendAnyVersionNewStream :: KirokuStore -> IORef Int -> IO ()
runRawProductionAppendAnyVersionNewStream store counter = do
    streamId <- atomicModifyIORef' counter (\n -> (n + 1, n))
    params <- mkRawProductionAppendParams <$> mkRawAppendParams ("raw-production-new-" <> T.pack (show streamId))
    result <- Pool.use (store ^. #pool) $ Session.statement params rawProductionAppendAnyVersion
    forceRawAppend result

runRawScalarAppendAnyVersionHotStream :: KirokuStore -> IO ()
runRawScalarAppendAnyVersionHotStream store = do
    params <- mkRawAppendParams "raw-scalar-hot"
    result <- Pool.use (store ^. #pool) $ Session.statement params rawScalarAppendAnyVersion
    forceRawAppend result

runRawProductionAppendAnyVersionHotStream :: KirokuStore -> IO ()
runRawProductionAppendAnyVersionHotStream store = do
    params <- mkRawProductionAppendParams <$> mkRawAppendParams "raw-production-hot"
    result <- Pool.use (store ^. #pool) $ Session.statement params rawProductionAppendAnyVersion
    forceRawAppend result

{- | Two-round-trip hot-stream variant: resolve stream by name, then UPDATE
the existing row keyed on integer stream_id. Both statements run on the
same pooled connection in a Session, each in its own implicit transaction
(no explicit BEGIN/COMMIT). This mirrors eventstore's small-batch path
(`EventStore.Streams.Stream.append_to_stream/5` at < 1000 events), which
runs two Postgrex.query calls without a transaction wrapper and relies on
the stream_events (stream_id, stream_version) unique constraint to detect
races. Wrapping in an explicit BEGIN/COMMIT adds two extra round-trips
and pessimises this path; that variant is measured separately below.
-}
runRawTwoRoundtripAppendExistingHotStream :: KirokuStore -> IO ()
runRawTwoRoundtripAppendExistingHotStream store = do
    base <- mkRawAppendParams "raw-two-roundtrip-hot"
    result <- Pool.use (store ^. #pool) $ do
        mRes <- Session.statement (base ^. #streamName) rawResolveStreamStmt
        case mRes of
            Nothing -> pure (Left "two-roundtrip hot bench: stream not pre-created")
            Just res -> do
                let params = mkRawAppendExistingParams (res ^. #resStreamId) base
                fmap Right (Session.statement params rawAppendUpdateExisting)
    forceTwoRoundtripResult result

{- | Two-round-trip new-stream variant. Same shape as the existing-stream
variant: two implicit-transaction round-trips on a pooled connection,
no explicit transaction wrapper.
-}
runRawTwoRoundtripAppendNewStream :: KirokuStore -> IORef Int -> IO ()
runRawTwoRoundtripAppendNewStream store counter = do
    streamId <- atomicModifyIORef' counter (\n -> (n + 1, n))
    base <- mkRawAppendParams ("raw-two-roundtrip-new-" <> T.pack (show streamId))
    result <- Pool.use (store ^. #pool) $ do
        mRes <- Session.statement (base ^. #streamName) rawResolveStreamStmt
        case mRes of
            Just _ -> pure (Left "two-roundtrip new bench: stream already exists")
            Nothing -> do
                let params = mkRawAppendNewParams base
                fmap Right (Session.statement params rawAppendCreateNew)
    forceTwoRoundtripResult result

{- | Two-round-trip hot-stream variant wrapped in an explicit
read-committed transaction. Provided as a separate benchmark to quantify
the BEGIN/COMMIT round-trip overhead so we can decide whether the live
append path can safely drop the transaction wrapper.
-}
runRawTwoRoundtripAppendExistingHotStreamTx :: KirokuStore -> IO ()
runRawTwoRoundtripAppendExistingHotStreamTx store = do
    base <- mkRawAppendParams "raw-two-roundtrip-hot"
    let txn = do
            mRes <- Tx.statement (base ^. #streamName) rawResolveStreamStmt
            case mRes of
                Nothing -> pure (Left "two-roundtrip hot tx bench: stream not pre-created")
                Just res -> do
                    let params = mkRawAppendExistingParams (res ^. #resStreamId) base
                    fmap Right (Tx.statement params rawAppendUpdateExisting)
    result <-
        Pool.use (store ^. #pool) $
            TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
    forceTwoRoundtripResult result

-- | Two-round-trip new-stream variant wrapped in an explicit transaction.
runRawTwoRoundtripAppendNewStreamTx :: KirokuStore -> IORef Int -> IO ()
runRawTwoRoundtripAppendNewStreamTx store counter = do
    streamId <- atomicModifyIORef' counter (\n -> (n + 1, n))
    base <- mkRawAppendParams ("raw-two-roundtrip-new-tx-" <> T.pack (show streamId))
    let txn = do
            mRes <- Tx.statement (base ^. #streamName) rawResolveStreamStmt
            case mRes of
                Just _ -> pure (Left "two-roundtrip new tx bench: stream already exists")
                Nothing -> do
                    let params = mkRawAppendNewParams base
                    fmap Right (Tx.statement params rawAppendCreateNew)
    result <-
        Pool.use (store ^. #pool) $
            TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write txn
    forceTwoRoundtripResult result

mkRawAppendExistingParams :: Int64 -> RawAppendParams -> RawAppendExistingParams
mkRawAppendExistingParams sid base =
    RawAppendExistingParams
        { existingStreamId = sid
        , existingEventId = base ^. #eventId
        , existingEventType = base ^. #eventType
        , existingCausationId = base ^. #causationId
        , existingCorrelationId = base ^. #correlationId
        , existingPayload = base ^. #payload
        , existingMetadata = base ^. #metadata
        , existingCreatedAt = base ^. #createdAt
        }

mkRawAppendNewParams :: RawAppendParams -> RawAppendNewParams
mkRawAppendNewParams base =
    RawAppendNewParams
        { newStreamName = base ^. #streamName
        , newEventId = base ^. #eventId
        , newEventType = base ^. #eventType
        , newCausationId = base ^. #causationId
        , newCorrelationId = base ^. #correlationId
        , newPayload = base ^. #payload
        , newMetadata = base ^. #metadata
        , newCreatedAt = base ^. #createdAt
        }

forceTwoRoundtripResult ::
    Either Pool.UsageError (Either String (Maybe RawAppendResult)) -> IO ()
forceTwoRoundtripResult (Left e) =
    error ("Two-round-trip bench pool error: " <> show e)
forceTwoRoundtripResult (Right (Left msg)) =
    error ("Two-round-trip bench precondition failed: " <> msg)
forceTwoRoundtripResult (Right (Right inner)) =
    forceRawAppend (Right inner)

{- | Run @writers@ concurrent appenders, each performing @ops@ appends to
its own unique stream. Used by the structured concurrent-writer
benchmarks (EP-6 F19); replaces the wall-clock @mapConcurrently_@
measurement that previously lived inline in @main@.

The @runCounter@ ref is bumped once per call so stream names are unique
across the many iterations tasty-bench runs.
-}
runConcurrentWriters :: KirokuStore -> IORef Int -> Int -> Int -> IO ()
runConcurrentWriters store runCounter writers ops = do
    runId <- atomicModifyIORef' runCounter (\m -> (m + 1, m))
    mapConcurrently_
        (\tid -> mapM_ (appendOne tid runId) [1 .. ops])
        [1 .. writers]
  where
    appendOne :: Int -> Int -> Int -> IO ()
    appendOne tid runId i = do
        let sn = StreamName ("conc-" <> T.pack (show runId) <> "-" <> T.pack (show tid) <> "-" <> T.pack (show i))
        r <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "ConcEvent"]
        forceAppend r

-- | Exercise the hot stream named in the focused reliability audit.
runHotInvoicePayment :: KirokuStore -> Int -> IO ()
runHotInvoicePayment store ops =
    mapM_
        ( \i -> do
            r <- runStoreIO store $ appendToStream (StreamName "invoice-payment") AnyVersion [makeEvent ("InvoicePayment" <> T.pack (show i))]
            forceAppend r
        )
        [1 .. ops]

-- | Exercise appendMultiStream against existing streams.
runAppendMultiStream :: KirokuStore -> IO ()
runAppendMultiStream store = do
    r <-
        runStoreIO store $
            appendMultiStream
                [ (StreamName "bench-multi-a", AnyVersion, [makeEvent "MultiA"])
                , (StreamName "bench-multi-b", AnyVersion, [makeEvent "MultiB"])
                , (StreamName "bench-multi-c", AnyVersion, [makeEvent "MultiC"])
                ]
    forceAppendList r

-- | Exercise subscription catch-up over a compact category-local backlog.
runSubscriptionCatchup :: KirokuStore -> IORef Int -> IO ()
runSubscriptionCatchup store runCounter = do
    runId <- atomicModifyIORef' runCounter (\m -> (m + 1, m))
    let cat = "benchsub" <> T.pack (show runId)
        sn = StreamName (cat <> "-stream")
        subName = SubscriptionName ("bench-sub-" <> T.pack (show runId))
        events = map (\i -> makeEvent ("SubCatchup" <> T.pack (show i))) [1 .. 100 :: Int]
    r <- runStoreIO store $ appendToStream sn NoStream events
    forceAppend r
    seenRef <- newIORef (0 :: Int)
    let handler _ = do
            n <- atomicModifyIORef' seenRef (\m -> let m' = m + 1 in (m', m'))
            pure $ if n >= 100 then Stop else Continue
        cfg =
            SubscriptionConfig
                { name = subName
                , target = Category (CategoryName cat)
                , handler = handler
                , batchSize = 100
                , queueCapacity = 16
                , overflowPolicy = DropSubscription
                , consumerGroup = Nothing
                , consumerGroupGuard = False
                , retryPolicy = defaultRetryPolicy
                }
    handle <- subscribe store cfg
    result <- wait handle
    case result of
        Right () -> pure ()
        Left e -> error ("Subscription catch-up benchmark failed: " <> show e)

-- | Force evaluation of an append result or fail the benchmark.
forceAppend :: Either StoreError AppendResult -> IO ()
forceAppend (Right r) = (r ^. #streamVersion) `seq` (r ^. #globalPosition) `seq` pure ()
forceAppend (Left e) = error ("Benchmark append failed: " <> show e)

-- | Force evaluation of multi-stream append results or fail the benchmark.
forceAppendList :: Either StoreError [AppendResult] -> IO ()
forceAppendList (Right rs) = mapM_ (\r -> (r ^. #streamVersion) `seq` (r ^. #globalPosition) `seq` pure ()) rs
forceAppendList (Left e) = error ("Benchmark appendMultiStream failed: " <> show e)

-- | Force evaluation of a raw append shape result or fail the benchmark.
forceRawAppend :: Either Pool.UsageError (Maybe RawAppendResult) -> IO ()
forceRawAppend (Right (Just (!streamId, !streamVersion, !globalPosition))) =
    streamId `seq` streamVersion `seq` globalPosition `seq` pure ()
forceRawAppend (Right Nothing) = error "Raw append benchmark produced no result"
forceRawAppend (Left e) = error ("Raw append benchmark failed: " <> show e)

-- | Force evaluation of a read result or fail the benchmark.
forceRead :: Either StoreError (V.Vector RecordedEvent) -> IO ()
forceRead (Right v) = V.length v `seq` pure ()
forceRead (Left e) = error ("Benchmark read failed: " <> show e)

main :: IO ()
main = do
    -- Start ephemeral PostgreSQL once for all benchmarks
    result <- Pg.withCached $ \db -> do
        let settings = defaultConnectionSettings (Pg.connectionString db)
        withStore settings $ \store -> do
            -- Counter for unique stream names across benchmarks
            counter <- newIORef (0 :: Int)
            let nextStream :: Text -> IO StreamName
                nextStream prefix = do
                    n <- atomicModifyIORef' counter (\n -> (n + 1, n))
                    pure (StreamName (prefix <> "-" <> T.pack (show n)))

            -- Pre-populate streams for category benchmarks (B10)
            -- 100 categories × 10 streams × 100 events = 100K events
            putStrLn "\n--- Pre-populating category data (100 cats × 10 streams × 100 events) ---"
            catT0 <- getCurrentTime
            mapM_
                ( \cat -> do
                    mapM_
                        ( \s -> do
                            let sn = StreamName ("cat" <> T.pack (show cat) <> "-" <> T.pack (show s))
                            let evts = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream evts
                            forceAppend r'
                        )
                        [1 .. 10 :: Int]
                )
                [1 .. 100 :: Int]
            catT1 <- getCurrentTime
            let catElapsed = realToFrac (diffUTCTime catT1 catT0) :: Double
            putStrLn $ "  Setup time: " <> show catElapsed <> "s (100K events)"

            -- Pre-populate streams for read benchmarks
            -- B4: Single stream with 1000 events
            let readStreamName = StreamName "bench-read-stream"
            let readEvents = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 1000 :: Int]
            r <- runStoreIO store $ appendToStream readStreamName NoStream readEvents
            forceAppend r

            -- B5: 10 streams with 100 events each for $all reads (1000 total)
            mapM_
                ( \s -> do
                    let sn = StreamName ("bench-all-" <> T.pack (show s))
                    let evts = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                    r' <- runStoreIO store $ appendToStream sn NoStream evts
                    forceAppend r'
                )
                [1 .. 10 :: Int]

            -- Pre-create fixed streams for appendMultiStream benchmark iterations.
            mapM_
                ( \sn -> do
                    r' <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Init"]
                    forceAppend r'
                )
                [StreamName "bench-multi-a", StreamName "bench-multi-b", StreamName "bench-multi-c"]

            -- Pre-create the hot stream targeted by the two-round-trip raw
            -- shape variant. rawAppendUpdateExisting requires the row to
            -- exist (no ON CONFLICT), so without this warmup the first
            -- iteration would fail. The scalar-singleton and production
            -- variants already create their hot stream on first iteration
            -- via ON CONFLICT — pre-creating them here would change the
            -- existing benchmark contract, so we only seed the two-round-trip
            -- target.
            do
                r' <- runStoreIO store $ appendToStream (StreamName "raw-two-roundtrip-hot") AnyVersion [makeEvent "Init"]
                forceAppend r'

            -- B9: Pool saturation benchmark (64 concurrent writers, 100 appends each)
            putStrLn "\n--- B9: Pool saturation (64 writers × 100 appends, pool size 10) ---"
            satCounter <- newIORef (0 :: Int)
            let nextSatStream :: Int -> Int -> StreamName
                nextSatStream tid i = StreamName ("sat-" <> T.pack (show tid) <> "-" <> T.pack (show i))
            t0 <- getCurrentTime
            mapConcurrently_
                ( \tid -> do
                    mapM_
                        ( \i -> do
                            let sn = nextSatStream tid i
                            r' <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "SatEvent"]
                            forceAppend r'
                            atomicModifyIORef' satCounter (\n -> (n + 1, ()))
                        )
                        [1 .. 100 :: Int]
                )
                [1 .. 64 :: Int]
            t1 <- getCurrentTime
            totalOps <- readIORef satCounter
            let elapsed = realToFrac (diffUTCTime t1 t0) :: Double
            let throughput = fromIntegral totalOps / elapsed
            let avgLatency = elapsed / fromIntegral totalOps * 1000 -- ms
            putStrLn $ "  Total appends: " <> show totalOps
            putStrLn $ "  Elapsed: " <> show elapsed <> "s"
            putStrLn $ "  Throughput: " <> show (round throughput :: Int) <> " ops/s"
            putStrLn $ "  Avg latency: " <> show avgLatency <> " ms"
            putStrLn "---"

            -- Counter shared by the concurrent-writer benchmarks so each
            -- iteration uses a fresh stream-name run-id.
            concCounter <- newIORef (0 :: Int)
            rawCounter <- newIORef (0 :: Int)
            subCounter <- newIORef (0 :: Int)

            defaultMain
                [ bgroup
                    "append"
                    [ bgroup
                        "single-event"
                        [ bench "NoStream (new stream)" $ whnfIO $ do
                            sn <- nextStream "bench-single"
                            r' <- runStoreIO store $ appendToStream sn NoStream [makeEvent "BenchEvent"]
                            forceAppend r'
                        , bench "AnyVersion (new stream)" $ whnfIO $ do
                            sn <- nextStream "bench-any"
                            r' <- runStoreIO store $ appendToStream sn AnyVersion [makeEvent "BenchEvent"]
                            forceAppend r'
                        ]
                    , bgroup
                        "batch-10"
                        [ bench "NoStream" $ whnfIO $ do
                            sn <- nextStream "bench-b10"
                            let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 10 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream events
                            forceAppend r'
                        ]
                    , bgroup
                        "batch-100"
                        [ bench "NoStream" $ whnfIO $ do
                            sn <- nextStream "bench-b100"
                            let events = map (\i -> makeEvent ("E" <> T.pack (show i))) [1 .. 100 :: Int]
                            r' <- runStoreIO store $ appendToStream sn NoStream events
                            forceAppend r'
                        ]
                    , bgroup
                        "sequential"
                        [ bench "10 appends to same stream" $ whnfIO $ do
                            sn <- nextStream "bench-seq"
                            r0 <- runStoreIO store $ appendToStream sn NoStream [makeEvent "Init"]
                            forceAppend r0
                            let Right res0 = r0
                            let go _ 0 = pure ()
                                go v n = do
                                    r' <- runStoreIO store $ appendToStream sn (ExactVersion v) [makeEvent "Seq"]
                                    case r' of
                                        Right res -> go (res ^. #streamVersion) (n - 1 :: Int)
                                        Left e -> error ("Sequential append failed: " <> show e)
                            go (res0 ^. #streamVersion) 9
                        ]
                    ]
                , bgroup
                    "raw-append-shape"
                    [ bgroup
                        "AnyVersion"
                        [ bench "scalar singleton (new stream)" $
                            whnfIO $
                                runRawScalarAppendAnyVersionNewStream store rawCounter
                        , bench "production arrays/unnest (new stream)" $
                            whnfIO $
                                runRawProductionAppendAnyVersionNewStream store rawCounter
                        , bench "two-roundtrip (new stream)" $
                            whnfIO $
                                runRawTwoRoundtripAppendNewStream store rawCounter
                        , bench "two-roundtrip + BEGIN/COMMIT (new stream)" $
                            whnfIO $
                                runRawTwoRoundtripAppendNewStreamTx store rawCounter
                        , bench "scalar singleton (hot stream)" $
                            whnfIO $
                                runRawScalarAppendAnyVersionHotStream store
                        , bench "production arrays/unnest (hot stream)" $
                            whnfIO $
                                runRawProductionAppendAnyVersionHotStream store
                        , bench "two-roundtrip (hot stream)" $
                            whnfIO $
                                runRawTwoRoundtripAppendExistingHotStream store
                        , bench "two-roundtrip + BEGIN/COMMIT (hot stream)" $
                            whnfIO $
                                runRawTwoRoundtripAppendExistingHotStreamTx store
                        ]
                    ]
                , bgroup
                    "read"
                    [ bench "stream forward (100-event page)" $ whnfIO $ do
                        r' <- runStoreIO store $ readStreamForward readStreamName (StreamVersion 0) 100
                        forceRead r'
                    , bench "$all forward (100-event page)" $ whnfIO $ do
                        r' <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                        forceRead r'
                    ]
                , bgroup
                    "category"
                    [ bench "category forward (100-event page)" $ whnfIO $ do
                        -- Read from cat1 category (has 10 streams × 100 events = 1000 events)
                        r' <- runStoreIO store $ readCategory (CategoryName "cat1") (GlobalPosition 0) 100
                        forceRead r'
                    , bench "exhausted-category" $ whnfIO $ do
                        -- cat1 events are inserted early in setup; a high cursor proves
                        -- category reads do not scan the rest of $all looking for matches.
                        r' <- runStoreIO store $ readCategory (CategoryName "cat1") (GlobalPosition 90_000) 100
                        forceRead r'
                    , bench "$all forward (100-event page, baseline)" $ whnfIO $ do
                        r' <- runStoreIO store $ readAllForward (GlobalPosition 0) 100
                        forceRead r'
                    ]
                , -- F19 — Concurrent-writer stress as structured benchmarks.
                  -- The legacy ad-hoc B9 measurement (still present above
                  -- for historical comparability) prints throughput and
                  -- latency once; these bgroup entries surface the same
                  -- workload through tasty-bench so it participates in the
                  -- baseline-regression workflow (Justfile bench-regression).
                  bgroup
                    "concurrent"
                    [ bench "8 writers x 10 appends" $ whnfIO $ runConcurrentWriters store concCounter 8 10
                    , bench "32 writers x 10 appends" $ whnfIO $ runConcurrentWriters store concCounter 32 10
                    ]
                , bgroup
                    "reliability-audit"
                    [ bench "hot invoice-payment 10 AnyVersion appends" $ whnfIO $ runHotInvoicePayment store 10
                    , bench "appendMultiStream 3 existing streams" $ whnfIO $ runAppendMultiStream store
                    , bench "subscription category catch-up 100 events" $ whnfIO $ runSubscriptionCatchup store subCounter
                    ]
                ]
    case result of
        Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
        Right () -> pure ()

makeEvent :: Text -> EventData
makeEvent typ =
    EventData
        { eventId = Nothing
        , eventType = EventType typ
        , payload = Aeson.object [("benchmark", Aeson.Bool True)]
        , metadata = Nothing
        , causationId = Nothing
        , correlationId = Nothing
        }
