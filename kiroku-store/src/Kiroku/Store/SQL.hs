{-# LANGUAGE MultilineStrings #-}

module Kiroku.Store.SQL (
    AppendParams (..),
    appendExpectedVersion,
    appendStreamExists,
    appendNoStream,
    appendAnyVersion,
) where

import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Kiroku.Store.Types

-- | Parameters for append CTE variants (the 7 parallel arrays + stream name).
data AppendParams = AppendParams
    { eventIds :: !(Vector UUID)
    , eventTypes :: !(Vector Text)
    , causationIds :: !(Vector (Maybe UUID))
    , correlationIds :: !(Vector (Maybe UUID))
    , payloads :: !(Vector Value)
    , metadatas :: !(Vector (Maybe Value))
    , createdAts :: !(Vector UTCTime)
    , streamName :: !Text
    }
    deriving stock (Show, Generic)

-- | Encoder for the common 8 parameters shared by all append variants.
appendParamsEncoder :: E.Params AppendParams
appendParamsEncoder =
    ((^. #eventIds) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.uuid))))
        <> ((^. #eventTypes) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.text))))
        <> ((^. #causationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #correlationIds) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.uuid))))
        <> ((^. #payloads) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.jsonb))))
        <> ((^. #metadatas) >$< E.param (E.nonNullable (E.foldableArray (E.nullable E.jsonb))))
        <> ((^. #createdAts) >$< E.param (E.nonNullable (E.foldableArray (E.nonNullable E.timestamptz))))
        <> ((^. #streamName) >$< E.param (E.nonNullable E.text))

-- | Encoder for append_expected_version: base params + expected version (Int64).
appendExpectedEncoder :: E.Params (AppendParams, Int64)
appendExpectedEncoder =
    (fst >$< appendParamsEncoder)
        <> (snd >$< E.param (E.nonNullable E.int8))

{- | Decoder for append results: stream_id, stream_version, global_position.
Returns Nothing if the CTE produced 0 rows (version conflict / stream not found).
-}
appendResultDecoder :: D.Result (Maybe AppendResult)
appendResultDecoder =
    D.rowMaybe $
        AppendResult
            <$> (StreamId <$> D.column (D.nonNullable D.int8))
            <*> (StreamVersion <$> D.column (D.nonNullable D.int8))
            <*> (GlobalPosition <$> D.column (D.nonNullable D.int8))

{- | Append with exact expected version (optimistic concurrency).
Returns Nothing if the stream doesn't exist or version doesn't match.
-}
appendExpectedVersion :: Statement (AppendParams, Int64) (Maybe AppendResult)
appendExpectedVersion =
    preparable
        appendExpectedVersionSQL
        appendExpectedEncoder
        appendResultDecoder

{- | Append to an existing stream at any version.
Returns Nothing if the stream doesn't exist.
-}
appendStreamExists :: Statement AppendParams (Maybe AppendResult)
appendStreamExists =
    preparable
        appendStreamExistsSQL
        appendParamsEncoder
        appendResultDecoder

{- | Append to a new stream (must not already exist).
Returns Nothing if the stream already exists.
-}
appendNoStream :: Statement AppendParams (Maybe AppendResult)
appendNoStream =
    preparable
        appendNoStreamSQL
        appendParamsEncoder
        appendResultDecoder

{- | Append to a stream, creating it if it doesn't exist.
Should always return Just (unless duplicate event ID constraint violation).
-}
appendAnyVersion :: Statement AppendParams (Maybe AppendResult)
appendAnyVersion =
    preparable
        appendAnyVersionSQL
        appendParamsEncoder
        appendResultDecoder

-- ---------------------------------------------------------------------------
-- SQL Templates
-- ---------------------------------------------------------------------------

-- | CTE with exact version check: UPDATE streams WHERE stream_version = $9.
appendExpectedVersionSQL :: Text
appendExpectedVersionSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_name = $8
          AND stream_version = $9
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_update)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_update su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_update)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_update su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_update su
    CROSS JOIN all_update au
    """

-- | CTE without version check: UPDATE streams WHERE stream_name = $8 (no $9).
appendStreamExistsSQL :: Text
appendStreamExistsSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_name = $8
        RETURNING stream_id, stream_version - (SELECT count(*) FROM new_events) AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_update)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, su.stream_id, su.initial_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_update su
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_update)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, su.stream_id, su.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_update su
      )
    SELECT su.stream_id,
           su.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_update su
    CROSS JOIN all_update au
    """

-- | CTE for new stream creation: INSERT INTO streams ... ON CONFLICT DO NOTHING.
appendNoStreamSQL :: Text
appendNoStreamSQL =
    """
    WITH
      new_events AS (
        SELECT *
        FROM unnest($1::uuid[], $2::text[], $3::uuid[], $4::uuid[], $5::jsonb[], $6::jsonb[], $7::timestamptz[])
        WITH ORDINALITY AS t(event_id, event_type, causation_id, correlation_id, data, metadata, created_at, idx)
      ),
      stream_insert AS (
        INSERT INTO streams (stream_name, stream_version)
        VALUES ($8, (SELECT count(*) FROM new_events))
        ON CONFLICT (stream_name) DO NOTHING
        RETURNING stream_id, 0::bigint AS initial_version
      ),
      inserted_events AS (
        INSERT INTO events (event_id, event_type, causation_id, correlation_id, data, metadata, created_at)
        SELECT event_id, event_type, causation_id, correlation_id, data, metadata, created_at
        FROM new_events
        WHERE EXISTS (SELECT 1 FROM stream_insert)
        ORDER BY idx
      ),
      source_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, si.stream_id, si.initial_version + ne.idx, si.stream_id, si.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN stream_insert si
      ),
      all_update AS (
        UPDATE streams
        SET stream_version = stream_version + (SELECT count(*) FROM new_events)
        WHERE stream_id = 0
          AND EXISTS (SELECT 1 FROM stream_insert)
        RETURNING stream_version - (SELECT count(*) FROM new_events) AS initial_global_version
      ),
      all_links AS (
        INSERT INTO stream_events (event_id, stream_id, stream_version, original_stream_id, original_stream_version)
        SELECT ne.event_id, 0, au.initial_global_version + ne.idx, si.stream_id, si.initial_version + ne.idx
        FROM new_events ne
        CROSS JOIN all_update au
        CROSS JOIN stream_insert si
      )
    SELECT si.stream_id,
           si.initial_version + (SELECT count(*) FROM new_events),
           au.initial_global_version + (SELECT count(*) FROM new_events)
    FROM stream_insert si
    CROSS JOIN all_update au
    """

{- | CTE for create-or-append using INSERT ... ON CONFLICT DO UPDATE (upsert).
A plain INSERT + separate UPDATE in the same CTE won't work because
data-modifying CTEs cannot see each other's changes. Instead, we use
a single upsert that both creates the stream and bumps its version atomically.
-}
appendAnyVersionSQL :: Text
appendAnyVersionSQL =
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
